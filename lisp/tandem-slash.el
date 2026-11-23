;;; tandem-slash.el --- Slash commands in the chat  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; Keywords: tools, convenience
;; URL: https://github.com/zombieleet/tandem

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Type / at the start of a message and complete a slash command: Claude
;; Code's own (/compact, /context, /usage, /model, /init …), your commands
;; in .claude/commands/ and ~/.claude/commands/, skills and plugins, each
;; with its description.  They run as Claude Code runs them.
;;
;; Two are tandem's own: /clear (also /reset, /new) starts a new chat,
;; the old one staying in M-x tandem-resume, and /resume reopens an
;; earlier chat.  Claude Code's /clear would start a conversation the chat
;; could not follow.
;;
;; The list comes from Claude Code when a chat starts, without calling a
;; model, and M-x tandem-slash-refresh reads it again after you add a
;; command.

;;; Code:

(require 'tandem-chat)
(require 'tandem-resume)
(require 'tandem-rpc)
(require 'seq)
(require 'subr-x)

(defcustom tandem-slash-popup t
  "Non-nil to list the slash commands as soon as you type / to start a message."
  :type 'boolean
  :group 'tandem)

(defvar company-backends)
(defvar company-mode)
(declare-function company-manual-begin "company")

(defvar-local tandem-slash--commands nil
  "The slash commands Claude Code offers in this chat, as plists.")

(defvar-local tandem-slash--loading nil
  "Non-nil while the commands are being read.")

(defconst tandem-slash--own
  '((:name "clear" :description "Start a new chat; this one stays in tandem-resume"
           :aliases ["reset" "new"])
    (:name "resume" :description "Reopen an earlier chat about this project")
    (:name "rewind" :description "Go back to before one of your messages: files and conversation")
    (:name "plan" :description "Claude plans the task without changing anything; you edit the plan in Org"
           :argumentHint "TASK"))
  "Commands tandem runs itself.")

(defun tandem-slash-refresh (&optional buffer)
  "Read again the slash commands Claude Code has for the chat BUFFER.
BUFFER is the current one by default.  The answer comes later; you can
keep typing.  Nothing happens without a connection to the daemon."
  (interactive)
  (let ((buffer (or buffer (current-buffer)))
        (loud (called-interactively-p 'any)))
    (with-current-buffer buffer
      (tandem-chat--check-buffer)
      ;; Only over the open connection: never start or reach a daemon for this.
      (when (and tandem-chat--session-id (not tandem-slash--loading)
                 (tandem-rpc-live-p))
        (setq tandem-slash--loading t)
        (tandem-rpc-async-request
         'session/commands (list :sessionId tandem-chat--session-id)
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq tandem-slash--loading nil
                     tandem-slash--commands (append (plist-get result :commands) nil))
               (when loud
                 (message "tandem: %d slash commands" (length tandem-slash--commands))))))
         (lambda (message)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq tandem-slash--loading nil)))
           (message "tandem: could not list slash commands: %s" message)))))))

(defun tandem-slash--all ()
  "Return the commands to offer: tandem's own first, then Claude Code's."
  (let ((own (mapcar (lambda (c) (plist-get c :name)) tandem-slash--own)))
    (append tandem-slash--own
            (seq-remove (lambda (c) (member (plist-get c :name) own)) tandem-slash--commands))))

(defun tandem-slash--find (name)
  "Return the command called NAME, or with NAME as an alias, or nil."
  (seq-find (lambda (c) (or (equal (plist-get c :name) name)
                            (seq-contains-p (plist-get c :aliases) name)))
            (tandem-slash--all)))

(defun tandem-slash--annotation (name)
  "Return the description shown after the command NAME."
  (when-let* ((command (tandem-slash--find name)))
    (let ((hint (plist-get command :argumentHint))
          (description (or (plist-get command :description) "")))
      (concat (if (and hint (not (string-empty-p hint)))
                  (concat " " (truncate-string-to-width hint 30 nil nil "…"))
                "")
              "   " (truncate-string-to-width (car (split-string description "\n")) 70 nil nil "…")))))

(defun tandem-slash-capf ()
  "Complete a slash command at the start of the chat's composer."
  (when (and (derived-mode-p 'tandem-chat-mode)
             (>= (point) tandem-chat--input))
    (let ((before (buffer-substring-no-properties tandem-chat--input (point))))
      (when (string-match "\\`[ \t\n]*/\\([[:alnum:]:_-]*\\)\\'" before)
        (unless (or tandem-slash--commands tandem-slash--loading)
          (ignore-errors (tandem-slash-refresh)))
        (list (- (point) (length (match-string 1 before))) (point)
              (completion-table-dynamic
               (lambda (_) (mapcar (lambda (c) (plist-get c :name)) (tandem-slash--all))))
              :exclusive 'no
              :annotation-function #'tandem-slash--annotation
              :company-docsig #'tandem-slash--annotation
              :exit-function
              (lambda (name status)
                (when (memq status '(finished sole exact))
                  (let ((hint (plist-get (tandem-slash--find name) :argumentHint)))
                    (when (and hint (not (string-empty-p hint)) (not (eq (char-after) ?\s)))
                      (insert " "))))))))))

(defun tandem-slash--clear ()
  "Start a new chat about this chat's project in place of this one."
  (let* ((old (current-buffer))
         (root tandem-chat--root)
         (new (tandem-chat--create root)))
    (with-current-buffer new
      (tandem-chat--editing-transcript
        (goto-char tandem-chat--output)
        (tandem-chat--draw-notice "New chat.  The earlier one is in M-x tandem-resume.")))
    (tandem-chat--display new)
    (kill-buffer old)
    new))

(defun tandem-slash--send (text)
  "Run TEXT here if it is one of tandem's own commands; return non-nil if so."
  (when (string-match "\\`/\\([[:alnum:]_-]+\\)\\(?:[ \t\n]\\|\\'\\)" text)
    (pcase (match-string 1 text)
      ((or "clear" "reset" "new") (tandem-slash--clear) t)
      ("resume"
       (when (derived-mode-p 'tandem-chat-mode) (tandem-chat--set-input ""))
       (call-interactively #'tandem-resume)
       t))))

(defun tandem-slash--company-first ()
  "Let tandem's completion go first with Company in this chat.
Company asks its backends in order and keeps the first that answers;
the words of your buffers would otherwise answer before the commands."
  (when (and (boundp 'company-backends)
             (not (eq (car company-backends) 'company-capf)))
    (setq-local company-backends (cons 'company-capf (remq 'company-capf company-backends)))))

(defun tandem-slash--popup ()
  "List the slash commands as you type / at the start of a message."
  (when (and tandem-slash-popup
             (eq last-command-event ?/)
             (>= (point) tandem-chat--input)
             (string-match-p "\\`[ \t\n]*/\\'"
                             (buffer-substring-no-properties tandem-chat--input (point))))
    (unless (or tandem-slash--commands tandem-slash--loading)
      (ignore-errors (tandem-slash-refresh)))
    (if (bound-and-true-p company-mode)
        (progn (tandem-slash--company-first)
               (company-manual-begin))
      (completion-at-point))))

(defun tandem-slash--setup ()
  "Set up slash commands in a chat buffer."
  (add-hook 'completion-at-point-functions #'tandem-slash-capf nil t)
  (add-hook 'post-self-insert-hook #'tandem-slash--popup nil t)
  (tandem-slash--company-first))

(add-hook 'tandem-chat-mode-hook #'tandem-slash--setup)
(add-hook 'tandem-chat-send-functions #'tandem-slash--send)
(add-hook 'tandem-chat-session-functions #'tandem-slash-refresh)

(provide 'tandem-slash)
;;; tandem-slash.el ends here
