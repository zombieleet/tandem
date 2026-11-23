;;; tandem-do.el --- Tell Claude what to do with the code at point  -*- lexical-binding: t; -*-

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

;; M-x tandem-do, in a file: tell Claude what to do with the selection, or
;; else the function at point, or else the line.  Type any instruction, or
;; pick one of `tandem-do-actions': refactor, simplify, document, add type
;; hints, fix, write tests, add error handling.  Claude gets the file, the
;; lines, the code and what Emacs reports there, and changes the code with
;; its edit tool: the change comes to you as hunks in this buffer, to apply
;; or reject, while you stay where you are.  A line above the code says
;; Claude is on it until it is done.  With C-u, Claude plans first.

;;; Code:

(require 'tandem-ask)
(require 'tandem-chat)
(require 'tandem-mention)
(require 'seq)
(require 'subr-x)

(defcustom tandem-do-actions
  '(("Refactor" . "Refactor this code to make it clearer and easier to change, without changing what it does.")
    ("Simplify" . "Simplify this code without changing what it does.")
    ("Document" . "Add or improve the documentation of this code (docstring or doc comment), in the language's usual style.")
    ("Type hints" . "Add type annotations to this code, where the language has them.")
    ("Fix" . "Fix the problems in this code, starting with those Emacs reports.")
    ("Tests" . "Write tests for this code, where this project keeps its tests and with its test framework.")
    ("Error handling" . "Add error handling where this code can fail."))
  "Instructions `tandem-do' offers, as (NAME . INSTRUCTION).
You can always type your own instead."
  :type '(alist :key-type string :value-type string)
  :group 'tandem)

(defface tandem-do-working
  '((t :inherit shadow :slant italic))
  "Face of the line saying Claude is working on some code."
  :group 'tandem)

(defconst tandem-do--how
  (concat "Make the change with your edit tool: the user reviews it in their editor. "
          "Change this code and only what the change needs elsewhere, unless the instruction says more. "
          "When you are done, say in one or two sentences what you changed.")
  "What every instruction from `tandem-do' adds.")

(defvar-local tandem-do--working nil
  "In a chat buffer: the overlays saying Claude is working, for this turn.")

(defun tandem-do--instruction (choice)
  "Return the instruction for CHOICE.
CHOICE is a name from `tandem-do-actions', or an instruction itself."
  (or (cdr (assoc choice tandem-do-actions)) choice))

(defun tandem-do--diagnostics (buffer first last)
  "Return what Emacs reports in BUFFER from line FIRST to LAST, or nil."
  (when-let* ((found (seq-filter (lambda (d) (<= first (nth 0 d) last))
                                 (tandem-mention-diagnostics buffer))))
    (concat "Emacs reports here:\n"
            (mapconcat (lambda (d) (format "line %d: %s: %s" (nth 0 d) (nth 1 d) (nth 2 d)))
                       found "\n"))))

(defun tandem-do--show-working (buffer beg label)
  "Put a line above BEG in BUFFER saying Claude is working on LABEL; return it."
  (with-current-buffer buffer
    (save-excursion
      (goto-char beg)
      (let ((overlay (make-overlay (line-beginning-position) (line-beginning-position))))
        (overlay-put overlay 'before-string
                     (propertize (format "◐ Claude is on it: %s\n" label) 'face 'tandem-do-working))
        (overlay-put overlay 'tandem-do t)
        overlay))))

(defun tandem-do--on-turn (_text _result)
  "When a turn ends in a chat, take away its lines saying Claude is working."
  (mapc #'delete-overlay tandem-do--working)
  (setq tandem-do--working nil))

(defun tandem-do--read (label)
  "Ask what Claude should do with LABEL; return the choice."
  (let ((choice (completing-read
                 (format "Claude, do this with %s: " label)
                 (lambda (string pred action)
                   (if (eq action 'metadata)
                       `(metadata (display-sort-function . identity)
                                  (annotation-function
                                   . ,(lambda (c) (when-let* ((i (cdr (assoc c tandem-do-actions))))
                                                    (propertize (concat "   " i) 'face 'completions-annotations)))))
                     (complete-with-action action (mapcar #'car tandem-do-actions) string pred)))
                 nil nil)))
    (when (string-blank-p choice)
      (user-error "Say what Claude should do"))
    choice))

;;;###autoload
(defun tandem-do (choice &optional plan)
  "Tell Claude to do CHOICE with the region, or the function or line at point.
CHOICE is a name from `tandem-do-actions' or an instruction of your own.
Claude's change comes as hunks in this buffer for you to review.  With
PLAN (\\[universal-argument]), Claude plans first, in an Org buffer you can edit."
  (interactive
   (let* ((bounds (tandem-ask--bounds))
          (first (line-number-at-pos (car bounds)))
          (last (line-number-at-pos (max (car bounds) (1- (cdr bounds))))))
     (list (tandem-do--read (if (= first last) (format "line %d" first) (format "lines %d-%d" first last)))
           current-prefix-arg)))
  (let* ((bounds (tandem-ask--bounds))
         (beg (car bounds))
         (end (cdr bounds))
         (first (line-number-at-pos beg))
         (last (line-number-at-pos (max beg (1- end))))
         (root (tandem-chat--project-root))
         (file (if buffer-file-name
                   (file-relative-name buffer-file-name (file-name-as-directory root))
                 (buffer-name)))
         (code (buffer-substring-no-properties beg end))
         (instruction (string-trim (tandem-do--instruction choice)))
         (reported (tandem-do--diagnostics (current-buffer) first last))
         (text (concat (tandem-ask--message instruction file first last code)
                       (if reported (concat "\n" reported "\n") "")
                       "\n" tandem-do--how))
         (label (if (assoc choice tandem-do-actions)
                    (downcase choice)
                  (truncate-string-to-width (car (split-string instruction "\n")) 50 nil nil "…")))
         (source (current-buffer))
         (chat (or (tandem-chat--buffer-for root) (tandem-chat--create root))))
    (deactivate-mark)
    (with-current-buffer chat
      (when (tandem-chat--busy-p)
        (user-error "Claude is still answering in that chat; try when it is done"))
      (let ((draft (tandem-chat--input-text)))
        (unwind-protect
            (tandem-chat--send-to-claude text (and plan "plan"))
          (tandem-chat--set-input draft)))
      (when (tandem-chat--busy-p)
        (push (tandem-do--show-working source beg label)
              tandem-do--working)))
    (message "tandem: Claude is on it; its change comes here as hunks to review")
    chat))

(add-hook 'tandem-chat-turn-functions #'tandem-do--on-turn)

(provide 'tandem-do)
;;; tandem-do.el ends here
