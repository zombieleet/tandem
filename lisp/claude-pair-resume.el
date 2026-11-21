;;; claude-pair-resume.el --- Reopen earlier chats  -*- lexical-binding: t; -*-

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

;; M-x claude-pair-resume lists the project's earlier chats, newest first,
;; with their title, age, number of messages and cost.  The one you pick
;; opens with its conversation drawn again, and Claude goes on where it
;; stopped, remembering all of it.
;;
;; Claude Code keeps every conversation on disk, so the list holds chats
;; from Claude Code in a terminal too.  A chat still running in the daemon,
;; after Emacs restarted, is reattached: \\[claude-pair] does that by itself
;; when the project has no chat open.

;;; Code:

(require 'claude-pair-chat)
(require 'claude-pair-markdown)
(require 'claude-pair-rpc)
(require 'iso8601)
(require 'seq)
(require 'subr-x)

(defcustom claude-pair-resume-limit 50
  "Most earlier chats `claude-pair-resume' lists."
  :type 'natnum
  :group 'claude-pair)

(defun claude-pair-resume--list (root)
  "Return the earlier chats about ROOT, newest first, as plists."
  (append (plist-get (claude-pair-rpc-request
                      'session/list
                      (list :cwd root :env (claude-pair-chat--environment)
                            :limit claude-pair-resume-limit)
                      30)
                     :sessions)
          nil))

(defun claude-pair-resume--age (iso)
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

(defun claude-pair-resume--describe (chat)
  "Return the line describing CHAT after its title."
  (let ((prompts (plist-get chat :prompts))
        (cost (plist-get chat :costUsd)))
    (string-join
     (delq nil (list (claude-pair-resume--age (plist-get chat :modified))
                     (format "%d message%s" prompts (if (eql prompts 1) "" "s"))
                     (and (numberp cost) (> cost 0) (format "$%.2f" cost))
                     (cond ((eq (plist-get chat :busy) t) "running now")
                           ((eq (plist-get chat :running) t) "open in the daemon"))))
     " · ")))

(defun claude-pair-resume--read (chats)
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
                                (concat "   " (propertize (claude-pair-resume--describe
                                                           (cdr (assoc candidate table)))
                                                          'face 'completions-annotations)))))
                      (complete-with-action action table string pred)))
                  nil t)))
    (or (cdr (assoc choice table)) (user-error "No chat chosen"))))

(defun claude-pair-resume--shown (text)
  "Return the part of your message TEXT for the chat to show.
What mentions attached, sent to Claude after your words, is left out."
  (if-let* ((at (string-search "\n\nContext the user attached:" text)))
      (substring text 0 at)
    text))

(defun claude-pair-resume--draw (history)
  "Draw HISTORY, the conversation so far, in the current chat."
  (let ((n 0))
    (seq-doseq (entry history)
      (pcase (plist-get entry :kind)
        ("user"
         (claude-pair-chat--render-markdown t)
         (claude-pair-chat--draw-user (claude-pair-resume--shown (plist-get entry :text))))
        ("text" (claude-pair-chat--draw-text (plist-get entry :text)))
        ("tool"
         (claude-pair-chat--render-markdown t)
         (let ((id (format "history-%d" (setq n (1+ n)))))
           (claude-pair-chat--draw-tool-start id (plist-get entry :title))
           (claude-pair-chat--draw-tool-end id (if (eq (plist-get entry :error) t) "error" "done") nil))))))
  (claude-pair-chat--render-markdown t))

(defun claude-pair-resume-open (session-id root)
  "Reopen the chat SESSION-ID about ROOT and return its buffer."
  (or (let ((buffer (gethash session-id claude-pair-chat--buffers)))
        (and (buffer-live-p buffer) buffer))
      (let* ((params (list :sessionId session-id :cwd root
                           :claudePath (claude-pair-chat--claude-path)
                           :env (claude-pair-chat--environment)
                           :instructions (or claude-pair-instructions "")))
             (result (condition-case err
                         (claude-pair-rpc-request
                          'session/resume
                          (if claude-pair-model (append params (list :model claude-pair-model)) params)
                          30)
                       (jsonrpc-error
                        (user-error "claude-pair: %s" (claude-pair-rpc-error-message err)))))
             (running (eq (plist-get result :running) t))
             (buffer (generate-new-buffer (format "*claude-pair: %s*" (file-name-nondirectory root)))))
        (with-current-buffer buffer
          (claude-pair-chat--setup session-id root)
          (claude-pair-chat--editing-transcript
            (goto-char claude-pair-chat--output)
            (claude-pair-resume--draw (plist-get result :history))
            (claude-pair-chat--draw-notice
             (if running
                 "Reattached: this chat was still open in the daemon."
               "Reopened: Claude remembers the conversation above.")))
          (when (eq (plist-get result :busy) t)
            (setq claude-pair-chat--state "running"
                  claude-pair-chat--replying t)))
        buffer)))

;;;###autoload
(defun claude-pair-resume ()
  "Reopen one of the current project's earlier chats with Claude."
  (interactive)
  (let* ((root (claude-pair-chat--project-root))
         (chats (claude-pair-resume--list root)))
    (unless chats
      (user-error "No earlier chats about %s" (abbreviate-file-name root)))
    (claude-pair-chat--display
     (claude-pair-resume-open (plist-get (claude-pair-resume--read chats) :sessionId) root))))

(defun claude-pair-resume--running (root)
  "Return the newest chat about ROOT still open in the daemon, or nil.
Only one no Emacs buffer shows: one left by an Emacs that restarted."
  (seq-find (lambda (chat)
              (and (eq (plist-get chat :running) t)
                   (not (buffer-live-p (gethash (plist-get chat :sessionId) claude-pair-chat--buffers)))))
            (ignore-errors (claude-pair-resume--list root))))

(defun claude-pair-resume--reattach (root)
  "Return a buffer for the chat about ROOT left open in the daemon, or nil."
  (when-let* ((chat (claude-pair-resume--running root)))
    (claude-pair-resume-open (plist-get chat :sessionId) root)))

(setq claude-pair-chat-reattach-function #'claude-pair-resume--reattach)

(provide 'claude-pair-resume)
;;; claude-pair-resume.el ends here
