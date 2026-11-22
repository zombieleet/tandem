;;; tandem-org.el --- Org subtrees as tasks for Claude  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience, outlines
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

;; M-x tandem-org-send-subtree, on an Org heading, sends the subtree
;; to the project's chat as a task.  When Claude finishes, its answer goes
;; under the heading as a new subheading, in Org syntax, so notes and
;; results stay together.  With a prefix argument, Claude plans first (see
;; `tandem-plan').
;;
;; The project is the one the Org file is in; for notes kept elsewhere,
;; you pick it, as for any chat.

;;; Code:

(require 'tandem-chat)
(require 'tandem-markdown)
(require 'org)
(require 'subr-x)

(defcustom tandem-org-answer-heading "Claude's answer"
  "Title of the subheading Claude's answer goes under."
  :type 'string
  :group 'tandem)

(defvar-local tandem-org--waiting nil
  "In a chat buffer: the marker of the Org heading waiting for this turn's answer.")

(defun tandem-org--message (heading file subtree)
  "Return the task message for SUBTREE, titled HEADING, from FILE."
  (format "Here is a task from my Org notes: the subtree \"%s\" in %s.  \
Do what it asks; when you are done, answer with what you did.\n\n#+begin_src org\n%s\n#+end_src"
          heading (abbreviate-file-name file) (string-trim-right subtree)))

(defun tandem-org--insert-answer (marker text)
  "Put TEXT, Claude's answer, under the Org heading at MARKER."
  (when-let* ((buffer (marker-buffer marker)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char marker)
        (let* ((level (org-current-level))
               (stars (make-string (1+ level) ?*)))
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n"))
          (insert stars " " tandem-org-answer-heading " "
                  (format-time-string (org-time-stamp-format t t)) "\n"
                  (tandem-markdown-to-org (string-trim text) (1+ level)) "\n"))))
    (set-marker marker nil)))

(defun tandem-org--on-turn (text result)
  "When a turn ends in a chat, put TEXT under the heading waiting for it.
RESULT says how the turn ended."
  (when-let* ((marker tandem-org--waiting))
    (setq tandem-org--waiting nil)
    (tandem-org--insert-answer
     marker
     (cond
      ((eq (plist-get result :cancelled) t) (concat text "\n\n(You stopped Claude here.)"))
      ((eq (plist-get result :isError) t)
       (concat text "\n\n(Claude stopped: " (or (plist-get result :message) "an error") ")"))
      ((string-blank-p text) "(Claude wrote nothing.)")
      (t text)))))

;;;###autoload
(defun tandem-org-send-subtree (&optional plan)
  "Send the Org subtree at point to Claude as a task.
Claude's answer goes under the heading when it is done.  With PLAN (a
prefix argument), Claude plans first, in an Org buffer you can edit."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (unless buffer-file-name
    (user-error "Save this Org buffer to a file first"))
  (save-excursion
    (org-back-to-heading t)
    (let* ((heading (org-get-heading t t t t))
           (marker (point-marker))
           (subtree (buffer-substring-no-properties
                     (point) (save-excursion (org-end-of-subtree t t) (point))))
           (file buffer-file-name)
           (root (tandem-chat--project-root))
           (chat (or (tandem-chat--buffer-for root) (tandem-chat--create root))))
      (with-current-buffer chat
        (when (tandem-chat--busy-p)
          (set-marker marker nil)
          (user-error "Claude is still answering in that chat"))
        (setq tandem-org--waiting marker)
        (tandem-chat--send-to-claude (tandem-org--message heading file subtree)
                                          (and plan "plan")))
      (tandem-chat--display chat)
      (message "tandem: sent \"%s\"; the answer goes under it" heading)
      chat)))

(add-hook 'tandem-chat-turn-functions #'tandem-org--on-turn)

(provide 'tandem-org)
;;; tandem-org.el ends here
