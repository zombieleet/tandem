;;; claude-pair-rewind.el --- Go back to an earlier turn  -*- lexical-binding: t; -*-

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

;; Every turn is a checkpoint.  Just before Emacs applies Claude's first
;; change to a file in a turn, it keeps the file's text.
;;
;; M-x claude-pair-rewind (or /rewind in the chat) asks which of your
;; messages to go back to before.  The files Claude changed from then on
;; return to how they were, Claude forgets that message and everything
;; after it, the chat shows the conversation up to there, and your message
;; is back in the composer to change and send again.
;;
;; Checkpoints live in this Emacs: after Emacs restarts, a rewind takes
;; back the conversation but not the files.  Changes Claude made with
;; shell commands are never taken back.

;;; Code:

(require 'claude-pair-chat)
(require 'claude-pair-resume)
(require 'claude-pair-review)
(require 'claude-pair-rpc)
(require 'iso8601)
(require 'seq)
(require 'subr-x)

(defvar claude-pair-rewind--checkpoints (make-hash-table :test #'equal)
  "From session id to its checkpoints, newest first.
Each is a plist: :path, :started (when its turn began, as from
`float-time'), and :text, the file's text before Claude changed it,
or :absent t for a file Claude created.")

(defun claude-pair-rewind--keep (proposal)
  "Keep the text of PROPOSAL's file, once per file and turn.
Runs in the file's buffer, just before Claude's change is applied."
  (let* ((session (plist-get proposal :session))
         (path (plist-get proposal :path))
         (chat (gethash session claude-pair-chat--buffers))
         (started (or (and (buffer-live-p chat)
                           (buffer-local-value 'claude-pair-chat--turn-started chat))
                      (float-time)))
         (kept (gethash session claude-pair-rewind--checkpoints)))
    (when (and session path
               (not (seq-find (lambda (cp) (and (equal (plist-get cp :path) path)
                                                (equal (plist-get cp :started) started)))
                              kept)))
      (puthash session
               (cons (if (and (plist-get proposal :new-file) (not (file-exists-p path)))
                         (list :path path :started started :absent t)
                       (list :path path :started started
                             :text (claude-pair-review-own-text (current-buffer))))
                     kept)
               claude-pair-rewind--checkpoints))))

(defun claude-pair-rewind--since (session cutoff)
  "Return SESSION's checkpoint for each file, the earliest after CUTOFF.
CUTOFF is a time as from `float-time', or nil for all of them."
  (let ((found nil))
    ;; Oldest first, so the first one seen for a file is the one to use.
    (dolist (cp (reverse (gethash session claude-pair-rewind--checkpoints)))
      (when (and (or (null cutoff) (> (plist-get cp :started) cutoff))
                 (not (assoc (plist-get cp :path) found)))
        (push (cons (plist-get cp :path) cp) found)))
    (nreverse (mapcar #'cdr found))))

(defun claude-pair-rewind--forget (session cutoff)
  "Drop the checkpoints SESSION made after CUTOFF, or all with nil."
  (puthash session
           (seq-remove (lambda (cp) (or (null cutoff) (> (plist-get cp :started) cutoff)))
                       (gethash session claude-pair-rewind--checkpoints))
           claude-pair-rewind--checkpoints))

(defun claude-pair-rewind--restore (checkpoint)
  "Put CHECKPOINT's file back as it was, and save it.
A file Claude created is deleted.  In a buffer, the change is one step
that undo can take back."
  (let ((path (plist-get checkpoint :path)))
    (if (plist-get checkpoint :absent)
        (progn
          (when-let* ((buffer (find-buffer-visiting path)))
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer))
          (when (file-exists-p path)
            (delete-file path)))
      (with-current-buffer (or (find-buffer-visiting path) (claude-pair-layout-file-buffer path))
        (let ((source (generate-new-buffer " *claude-pair rewind*")))
          (unwind-protect
              (progn
                (with-current-buffer source (insert (plist-get checkpoint :text)))
                (save-restriction
                  (widen)
                  ;; The kept text carries its authorship: Claude's lines
                  ;; from before keep their colour.
                  (let ((claude-pair-authorship-claude-editing t))
                    (replace-buffer-contents source)))
                (let ((save-silently t) (inhibit-message t))
                  (save-buffer)))
            (kill-buffer source)))))))

(defun claude-pair-rewind--chat ()
  "Return the chat to rewind: the current buffer's, or the project's."
  (cond
   ((derived-mode-p 'claude-pair-chat-mode) (current-buffer))
   ((claude-pair-chat--buffer-for (claude-pair-chat--project-root)))
   (t (user-error "No chat with Claude about this project"))))

(defun claude-pair-rewind--time (iso)
  "Return the time ISO as from `float-time', or nil."
  (and iso (not (string-empty-p iso))
       (ignore-errors (float-time (encode-time (iso8601-parse iso))))))

(defun claude-pair-rewind--read (messages)
  "Ask which of MESSAGES, your messages with their index, to go back to before."
  (let* ((table (mapcar (lambda (m)
                          (cons (format "%d. %s" (car m)
                                        (truncate-string-to-width
                                         (car (split-string (claude-pair-resume--shown (plist-get (cdr m) :text)) "\n"))
                                         70 nil nil "…"))
                                m))
                        (reverse messages)))
         (choice (completing-read
                  "Go back to before: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (display-sort-function . identity))
                      (complete-with-action action table string pred)))
                  nil t)))
    (or (cdr (assoc choice table)) (user-error "No message chosen"))))

(defun claude-pair-rewind--describe (checkpoints root)
  "Return a sentence on what happens to the files of CHECKPOINTS under ROOT."
  (if checkpoints
      (format "These files go back as they were, your own later changes to them too: %s."
              (mapconcat (lambda (cp) (file-relative-name (plist-get cp :path) root)) checkpoints ", "))
    "No file goes back: Claude changed none in Emacs since then."))

(defun claude-pair-rewind--redraw (history)
  "Draw the chat again with HISTORY, the conversation that remains."
  (let ((id claude-pair-chat--session-id)
        (root claude-pair-chat--root))
    (claude-pair-chat--setup id root)
    (claude-pair-chat--editing-transcript
      (goto-char claude-pair-chat--output)
      (claude-pair-resume--draw history))))

;;;###autoload
(defun claude-pair-rewind ()
  "Go back to before one of your messages: files and conversation.
The files Claude changed in Emacs from then on return to how they were,
Claude forgets that message and what came after, and the message is back
in the composer."
  (interactive)
  (with-current-buffer (claude-pair-rewind--chat)
    (when (claude-pair-chat--busy-p)
      (user-error "Claude is still answering; C-c C-k stops it first"))
    (when (> (claude-pair-review-waiting claude-pair-chat--session-id) 0)
      (user-error "Decide the edits waiting for your review first"))
    (let* ((session claude-pair-chat--session-id)
           (root claude-pair-chat--root)
           (history (append (plist-get (claude-pair-rpc-request
                                        'session/history
                                        (list :sessionId session :env (claude-pair-chat--environment)))
                                       :history)
                            nil))
           (messages (let ((n 0) found)
                       (seq-doseq (entry history)
                         (when (equal (plist-get entry :kind) "user")
                           (push (cons (setq n (1+ n)) entry) found)))
                       (nreverse found))))
      (unless messages
        (user-error "Nothing to go back to: no message was sent yet"))
      (let* ((chosen (claude-pair-rewind--read messages))
             (entry (cdr chosen))
             (before (plist-get entry :before))
             (cutoff (claude-pair-rewind--time (plist-get entry :beforeTime)))
             (checkpoints (claude-pair-rewind--since session cutoff))
             (text (claude-pair-resume--shown (plist-get entry :text))))
        (unless (y-or-n-p (format "%s  Go back to before message %d, which Claude then forgets with all after it?"
                                  (claude-pair-rewind--describe checkpoints root) (car chosen)))
          (user-error "Nothing changed"))
        (mapc #'claude-pair-rewind--restore checkpoints)
        (claude-pair-rewind--forget session cutoff)
        (let ((notice (format "Went back to before message %d.%s" (car chosen)
                              (if checkpoints
                                  (format "  Restored: %s."
                                          (mapconcat (lambda (cp) (file-relative-name (plist-get cp :path) root))
                                                     checkpoints ", "))
                                ""))))
          (if (or (null before) (string-empty-p before))
              ;; Before the first message: a conversation of its own.
              (let ((old (current-buffer))
                    (new (claude-pair-chat--create root)))
                (with-current-buffer new
                  (claude-pair-chat--editing-transcript
                    (goto-char claude-pair-chat--output)
                    (claude-pair-chat--draw-notice notice))
                  (claude-pair-chat--set-input text))
                (claude-pair-chat--display new)
                (kill-buffer old))
            (claude-pair-rpc-request 'session/rewind
                                     (list :sessionId session :before before
                                           :env (claude-pair-chat--environment)))
            (claude-pair-rewind--redraw
             (seq-take-while (lambda (e) (not (eq e entry))) history))
            (claude-pair-chat--editing-transcript
              (goto-char claude-pair-chat--output)
              (claude-pair-chat--draw-notice notice))
            (claude-pair-chat--set-input text)
            (goto-char (point-max))))))))

(defun claude-pair-rewind--send (text)
  "Run /rewind from the chat; return non-nil if TEXT is it."
  (when (string-match-p "\\`/rewind\\(?:[ \t\n]\\|\\'\\)" text)
    (when (derived-mode-p 'claude-pair-chat-mode)
      (claude-pair-chat--set-input ""))
    (call-interactively #'claude-pair-rewind)
    t))

(add-hook 'claude-pair-review-before-apply-functions #'claude-pair-rewind--keep)
(add-hook 'claude-pair-chat-send-functions #'claude-pair-rewind--send)

(provide 'claude-pair-rewind)
;;; claude-pair-rewind.el ends here
