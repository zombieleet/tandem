;;; claude-pair-slash.el --- Slash commands in the chat  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience
;; URL: https://github.com/victory/claude-pair

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
;; Two are claude-pair's own: /clear (also /reset, /new) starts a new chat,
;; the old one staying in M-x claude-pair-resume, and /resume reopens an
;; earlier chat.  Claude Code's /clear would start a conversation the chat
;; could not follow.
;;
;; The list comes from Claude Code when a chat starts, without calling a
;; model, and M-x claude-pair-slash-refresh reads it again after you add a
;; command.

;;; Code:

(require 'claude-pair-chat)
(require 'claude-pair-resume)
(require 'claude-pair-rpc)
(require 'seq)
(require 'subr-x)

(defvar-local claude-pair-slash--commands nil
  "The slash commands Claude Code offers in this chat, as plists.")

(defvar-local claude-pair-slash--loading nil
  "Non-nil while the commands are being read.")

(defconst claude-pair-slash--own
  '((:name "clear" :description "Start a new chat; this one stays in claude-pair-resume"
           :aliases ["reset" "new"])
    (:name "resume" :description "Reopen an earlier chat about this project"))
  "Commands claude-pair runs itself.")

(defun claude-pair-slash-refresh (&optional buffer)
  "Read again the slash commands Claude Code has for the chat BUFFER.
BUFFER is the current one by default.  The answer comes later; you can
keep typing.  Nothing happens without a connection to the daemon."
  (interactive)
  (let ((buffer (or buffer (current-buffer)))
        (loud (called-interactively-p 'any)))
    (with-current-buffer buffer
      (claude-pair-chat--check-buffer)
      ;; Only over the open connection: never start or reach a daemon for this.
      (when (and claude-pair-chat--session-id (not claude-pair-slash--loading)
                 (claude-pair-rpc-live-p))
        (setq claude-pair-slash--loading t)
        (claude-pair-rpc-async-request
         'session/commands (list :sessionId claude-pair-chat--session-id)
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq claude-pair-slash--loading nil
                     claude-pair-slash--commands (append (plist-get result :commands) nil))
               (when loud
                 (message "claude-pair: %d slash commands" (length claude-pair-slash--commands))))))
         (lambda (message)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq claude-pair-slash--loading nil)))
           (message "claude-pair: could not list slash commands: %s" message)))))))

(defun claude-pair-slash--all ()
  "Return the commands to offer: claude-pair's own first, then Claude Code's."
  (let ((own (mapcar (lambda (c) (plist-get c :name)) claude-pair-slash--own)))
    (append claude-pair-slash--own
            (seq-remove (lambda (c) (member (plist-get c :name) own)) claude-pair-slash--commands))))

(defun claude-pair-slash--find (name)
  "Return the command called NAME, or with NAME as an alias, or nil."
  (seq-find (lambda (c) (or (equal (plist-get c :name) name)
                            (seq-contains-p (plist-get c :aliases) name)))
            (claude-pair-slash--all)))

(defun claude-pair-slash--annotation (name)
  "Return the description shown after the command NAME."
  (when-let* ((command (claude-pair-slash--find name)))
    (let ((hint (plist-get command :argumentHint))
          (description (or (plist-get command :description) "")))
      (concat (if (and hint (not (string-empty-p hint)))
                  (concat " " (truncate-string-to-width hint 30 nil nil "…"))
                "")
              "   " (truncate-string-to-width (car (split-string description "\n")) 70 nil nil "…")))))

(defun claude-pair-slash-capf ()
  "Complete a slash command at the start of the chat's composer."
  (when (and (derived-mode-p 'claude-pair-chat-mode)
             (>= (point) claude-pair-chat--input))
    (let ((before (buffer-substring-no-properties claude-pair-chat--input (point))))
      (when (string-match "\\`[ \t\n]*/\\([[:alnum:]:_-]*\\)\\'" before)
        (unless (or claude-pair-slash--commands claude-pair-slash--loading)
          (ignore-errors (claude-pair-slash-refresh)))
        (list (- (point) (length (match-string 1 before))) (point)
              (completion-table-dynamic
               (lambda (_) (mapcar (lambda (c) (plist-get c :name)) (claude-pair-slash--all))))
              :exclusive 'no
              :annotation-function #'claude-pair-slash--annotation
              :company-docsig #'claude-pair-slash--annotation
              :exit-function
              (lambda (name status)
                (when (memq status '(finished sole exact))
                  (let ((hint (plist-get (claude-pair-slash--find name) :argumentHint)))
                    (when (and hint (not (string-empty-p hint)) (not (eq (char-after) ?\s)))
                      (insert " "))))))))))

(defun claude-pair-slash--clear ()
  "Start a new chat about this chat's project in place of this one."
  (let* ((old (current-buffer))
         (root claude-pair-chat--root)
         (new (claude-pair-chat--create root)))
    (with-current-buffer new
      (claude-pair-chat--editing-transcript
        (goto-char claude-pair-chat--output)
        (claude-pair-chat--draw-notice "New chat.  The earlier one is in M-x claude-pair-resume.")))
    (claude-pair-chat--display new)
    (kill-buffer old)
    new))

(defun claude-pair-slash--send (text)
  "Run TEXT here if it is one of claude-pair's own commands; return non-nil if so."
  (when (string-match "\\`/\\([[:alnum:]_-]+\\)\\(?:[ \t\n]\\|\\'\\)" text)
    (pcase (match-string 1 text)
      ((or "clear" "reset" "new") (claude-pair-slash--clear) t)
      ("resume" (call-interactively #'claude-pair-resume) t))))

(defun claude-pair-slash--setup ()
  "Set up slash commands in a chat buffer."
  (add-hook 'completion-at-point-functions #'claude-pair-slash-capf nil t))

(add-hook 'claude-pair-chat-mode-hook #'claude-pair-slash--setup)
(add-hook 'claude-pair-chat-send-functions #'claude-pair-slash--send)
(add-hook 'claude-pair-chat-session-functions #'claude-pair-slash-refresh)

(provide 'claude-pair-slash)
;;; claude-pair-slash.el ends here
