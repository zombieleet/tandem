;;; tandem-resume.el --- Reopen earlier chats  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience
;; URL: https://github.com/victory/tandem

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

;; M-x tandem-resume lists the project's earlier chats, newest first,
;; with their title, age, number of messages and cost.  The one you pick
;; opens with its conversation drawn again, and Claude goes on where it
;; stopped, remembering all of it.
;;
;; Claude Code keeps every conversation on disk, so the list holds chats
;; from Claude Code in a terminal too.  A chat still running in the daemon,
;; after Emacs restarted, is reattached: \\[tandem] does that by itself
;; when the project has no chat open.

;;; Code:

(require 'tandem-chat)
(require 'tandem-markdown)
(require 'tandem-rpc)
(require 'iso8601)
(require 'seq)
(require 'subr-x)

(defcustom tandem-resume-limit 50
  "Most earlier chats `tandem-resume' lists."
  :type 'natnum
  :group 'tandem)

(defun tandem-resume--list (root)
  "Return the earlier chats about ROOT, newest first, as plists."
  (append (plist-get (tandem-rpc-request
                      'session/list
                      (list :cwd root :env (tandem-chat--environment)
                            :limit tandem-resume-limit)
                      30)
                     :sessions)
          nil))

(defun tandem-resume--age (iso)
  "Return how long ago the time ISO was, in a few words."
  (let ((seconds (condition-case nil
                     (float-time (time-subtract nil (encode-time (iso8601-parse iso))))
                   (error nil))))
    (cond
     ((null seconds) "")
     ((< seconds 60) "just now")
     ((< seconds 3600) (format "%d min ago" (/ seconds 60)))
     ((< seconds 86400) (format "%d h ago" (/ seconds 3600)))
     ((< seconds (* 7 86400)) (format "%d days ago" (/ seconds 86400)))
     (t (format-time-string "%e %b %Y" (encode-time (iso8601-parse iso)))))))

(defun tandem-resume--describe (chat)
  "Return the line describing CHAT after its title."
  (let ((prompts (plist-get chat :prompts))
        (cost (plist-get chat :costUsd)))
    (string-join
     (delq nil (list (tandem-resume--age (plist-get chat :modified))
                     (format "%d message%s" prompts (if (eql prompts 1) "" "s"))
                     (and (numberp cost) (> cost 0) (format "$%.2f" cost))
                     (cond ((eq (plist-get chat :busy) t) "running now")
                           ((eq (plist-get chat :running) t) "open in the daemon"))))
     " · ")))

(defun tandem-resume--read (chats)
  "Ask which of CHATS to reopen; return its plist."
  (let* ((table (mapcar (lambda (chat)
                          (cons (format "%s  %s"
                                        (plist-get chat :title)
                                        (propertize (substring (plist-get chat :sessionId) 0 8)
                                                    'face 'shadow))
                                chat))
                        chats))
         (choice (completing-read
                  "Reopen chat: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        `(metadata
                          (display-sort-function . identity)
                          (annotation-function
                           . ,(lambda (candidate)
                                (concat "   " (propertize (tandem-resume--describe
                                                           (cdr (assoc candidate table)))
                                                          'face 'completions-annotations)))))
                      (complete-with-action action table string pred)))
                  nil t)))
    (or (cdr (assoc choice table)) (user-error "No chat chosen"))))

(defun tandem-resume--shown (text)
  "Return the part of your message TEXT for the chat to show.
What mentions attached, sent to Claude after your words, is left out."
  (if-let* ((at (string-search "\n\nContext the user attached:" text)))
      (substring text 0 at)
    text))

(defun tandem-resume--draw (history)
  "Draw HISTORY, the conversation so far, in the current chat."
  (let ((n 0))
    (seq-doseq (entry history)
      (pcase (plist-get entry :kind)
        ("user"
         (tandem-chat--render-markdown t)
         (tandem-chat--draw-user (tandem-resume--shown (plist-get entry :text))))
        ("text" (tandem-chat--draw-text (plist-get entry :text)))
        ("tool"
         (tandem-chat--render-markdown t)
         (let ((id (format "history-%d" (setq n (1+ n)))))
           (tandem-chat--draw-tool-start id (plist-get entry :title))
           (tandem-chat--draw-tool-end id (if (eq (plist-get entry :error) t) "error" "done") nil))))))
  (tandem-chat--render-markdown t))

(defun tandem-resume-open (session-id root)
  "Reopen the chat SESSION-ID about ROOT and return its buffer."
  (or (let ((buffer (gethash session-id tandem-chat--buffers)))
        (and (buffer-live-p buffer) buffer))
      (let* ((params (list :sessionId session-id :cwd root
                           :claudePath (tandem-chat--claude-path)
                           :env (tandem-chat--environment)
                           :instructions (or tandem-instructions "")))
             (result (condition-case err
                         (tandem-rpc-request
                          'session/resume
                          (if tandem-model (append params (list :model tandem-model)) params)
                          30)
                       (jsonrpc-error
                        (user-error "tandem: %s" (tandem-rpc-error-message err)))))
             (running (eq (plist-get result :running) t))
             (buffer (generate-new-buffer (format "*tandem: %s*" (file-name-nondirectory root)))))
        (with-current-buffer buffer
          (tandem-chat--setup session-id root)
          (tandem-chat--editing-transcript
            (goto-char tandem-chat--output)
            (tandem-resume--draw (plist-get result :history))
            (tandem-chat--draw-notice
             (if running
                 "Reattached: this chat was still open in the daemon."
               "Reopened: Claude remembers the conversation above.")))
          (when (eq (plist-get result :busy) t)
            (setq tandem-chat--state "running"
                  tandem-chat--replying t)))
        (run-hook-with-args 'tandem-chat-session-functions buffer)
        buffer)))

;;;###autoload
(defun tandem-resume ()
  "Reopen one of the current project's earlier chats with Claude."
  (interactive)
  (let* ((root (tandem-chat--project-root))
         (chats (tandem-resume--list root)))
    (unless chats
      (user-error "No earlier chats about %s" (abbreviate-file-name root)))
    (tandem-chat--display
     (tandem-resume-open (plist-get (tandem-resume--read chats) :sessionId) root))))

(defun tandem-resume--running (root)
  "Return the newest chat about ROOT still open in the daemon, or nil.
Only one no Emacs buffer shows: one left by an Emacs that restarted."
  (seq-find (lambda (chat)
              (and (eq (plist-get chat :running) t)
                   (not (buffer-live-p (gethash (plist-get chat :sessionId) tandem-chat--buffers)))))
            (ignore-errors (tandem-resume--list root))))

(defun tandem-resume--reattach (root)
  "Return a buffer for the chat about ROOT left open in the daemon, or nil."
  (when-let* ((chat (tandem-resume--running root)))
    (tandem-resume-open (plist-get chat :sessionId) root)))

(setq tandem-chat-reattach-function #'tandem-resume--reattach)

(provide 'tandem-resume)
;;; tandem-resume.el ends here
