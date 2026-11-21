;;; claude-pair-ask.el --- Ask Claude about any code you point at  -*- lexical-binding: t; -*-

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

;; Select some code, or put point in a function, and M-x claude-pair-ask:
;;
;;   @claude (about lines 12-30 of geo.py): explain this
;;
;; The question goes to the project's chat with the file, the lines and
;; the code, so Claude sees exactly what you point at.  Claude's answer
;; streams into the chat and into a note above the code, as for a hunk;
;; [×] dismisses the note.  Asking for a change ("add error handling
;; here") gets you a proposed edit, reviewed as usual.  Asking never moves
;; you: it does not switch tabs, select the chat, or touch a draft you were
;; typing there.

;;; Code:

(require 'claude-pair-chat)
(require 'claude-pair-review)
(require 'subr-x)

(defvar claude-pair-ask--count 0
  "How many questions this Emacs has asked, for the notes' ids.")

(defun claude-pair-ask--bounds ()
  "Return (BEG . END) of what to ask about: the region, the function, or the line."
  (cond
   ((use-region-p) (cons (region-beginning) (region-end)))
   ((bounds-of-thing-at-point 'defun))
   (t (cons (line-beginning-position) (line-end-position)))))

(defun claude-pair-ask--language ()
  "Return a name for the current buffer's language, for a code fence."
  (let ((mode (symbol-name major-mode)))
    (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" mode)))

(defun claude-pair-ask--fence (code)
  "Return a backtick fence longer than any run of backticks in CODE."
  (let ((longest 2) (start 0))
    (while (string-match "`+" code start)
      (setq longest (max longest (- (match-end 0) (match-beginning 0)))
            start (match-end 0)))
    (make-string (1+ longest) ?`)))

(defun claude-pair-ask--message (question file first last code)
  "Return the message asking QUESTION about lines FIRST to LAST of FILE.
CODE is the text of those lines."
  (let ((fence (claude-pair-ask--fence code)))
    (format "%s\n\nIn %s, %s:\n%s%s\n%s%s%s\n"
            question file
            (if (= first last) (format "line %d" first) (format "lines %d-%d" first last))
            fence (claude-pair-ask--language)
            code (if (string-suffix-p "\n" code) "" "\n") fence)))

(defun claude-pair-ask--send (root text note)
  "Send TEXT to the chat about ROOT, starting one if needed.
Claude's answer goes into the note NOTE too.  Keep the chat's draft."
  (let ((chat (or (claude-pair-chat--buffer-for root) (claude-pair-chat--create root))))
    (with-current-buffer chat
      (when (claude-pair-chat--busy-p)
        (user-error "Claude is still answering in that chat; ask when it is done"))
      (let ((draft (claude-pair-chat--input-text)))
        (claude-pair-chat--set-input text)
        (unwind-protect
            (progn
              (claude-pair-chat-send)
              (claude-pair-chat--stop-answering)
              (setq claude-pair-chat--answering note))
          (claude-pair-chat--set-input draft))))
    chat))

;;;###autoload
(defun claude-pair-ask (question)
  "Ask Claude QUESTION about the region, or the function or line at point.
The question goes to the project's chat with the file, the lines and the
code; the answer shows in the chat and in a note above the code."
  (interactive
   (let* ((bounds (claude-pair-ask--bounds))
          (first (line-number-at-pos (car bounds)))
          (last (line-number-at-pos (max (car bounds) (1- (cdr bounds))))))
     (list (read-string (format "@claude (about %s of %s): "
                                (if (= first last) (format "line %d" first) (format "lines %d-%d" first last))
                                (buffer-name))
                        nil nil nil t))))
  (when (string-empty-p (string-trim question))
    (user-error "Type a question for Claude"))
  (let* ((bounds (claude-pair-ask--bounds))
         (beg (car bounds))
         (end (cdr bounds))
         (first (line-number-at-pos beg))
         (last (line-number-at-pos (max beg (1- end))))
         (root (claude-pair-chat--project-root))
         (file (if buffer-file-name
                   (file-relative-name buffer-file-name (file-name-as-directory root))
                 (buffer-name)))
         (code (buffer-substring-no-properties beg end))
         (note (format "ask-%d" (setq claude-pair-ask--count (1+ claude-pair-ask--count)))))
    (deactivate-mark)
    (claude-pair-review-add-note note (current-buffer) beg (string-trim question))
    (condition-case err
        (claude-pair-ask--send root (claude-pair-ask--message (string-trim question) file first last code) note)
      (error
       (claude-pair-review-dismiss-note note)
       (signal (car err) (cdr err))))
    (message "claude-pair: asked Claude; the answer shows above the code and in the chat")))

(provide 'claude-pair-ask)
;;; claude-pair-ask.el ends here
