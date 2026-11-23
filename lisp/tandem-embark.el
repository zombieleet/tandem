;;; tandem-embark.el --- Ask Claude from Embark  -*- lexical-binding: t; -*-

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

;; With Embark, "@" in its action menu asks Claude about the target:
;;
;;   a file        the question goes to the chat with the file mentioned
;;   a symbol      the question names it and where you are
;;   a region      as M-x tandem-ask: the answer also shows above it
;;
;; Turn it on with (tandem-embark-mode 1), after Embark is loaded:
;; Doom's (after! embark (tandem-embark-mode 1)), or
;; (with-eval-after-load 'embark (tandem-embark-mode 1)) elsewhere.

;;; Code:

(require 'tandem-ask)
(require 'tandem-chat)
(require 'subr-x)

(defvar embark-file-map)
(defvar embark-identifier-map)
(defvar embark-symbol-map)
(defvar embark-region-map)

(defun tandem-embark--send (root text)
  "Send TEXT to the chat about ROOT, showing it."
  (let ((chat (or (tandem-chat--buffer-for root) (tandem-chat--create root))))
    (with-current-buffer chat
      (when (tandem-chat--busy-p)
        (user-error "Claude is still answering in that chat"))
      (tandem-chat--send-to-claude text))
    (tandem-chat--display chat)))

(defun tandem-embark-ask-file (file)
  "Ask Claude a question about FILE."
  (interactive "fAsk Claude about file: ")
  (let* ((file (expand-file-name file))
         (default-directory (file-name-directory file))
         (root (tandem-chat--project-root))
         (name (if (file-in-directory-p file root) (file-relative-name file root) file))
         (question (read-string (format "Ask Claude about %s: " name))))
    (when (string-blank-p question)
      (user-error "No question"))
    (tandem-embark--send root (format "%s @%s" (string-trim question) name))))

(defun tandem-embark-ask-symbol (symbol)
  "Ask Claude a question about SYMBOL, where you are."
  (interactive (list (or (thing-at-point 'symbol t) (read-string "Symbol: "))))
  (let* ((root (tandem-chat--project-root))
         (where (when buffer-file-name
                  (format " (in %s, line %d)"
                          (if (file-in-directory-p buffer-file-name root)
                              (file-relative-name buffer-file-name root)
                            (abbreviate-file-name buffer-file-name))
                          (line-number-at-pos))))
         (question (read-string (format "Ask Claude about %s: " symbol))))
    (when (string-blank-p question)
      (user-error "No question"))
    (tandem-embark--send root (format "%s\n\nAbout `%s`%s." (string-trim question) symbol (or where "")))))

(defun tandem-embark-ask-region (beg end)
  "Ask Claude about the region from BEG to END, as `tandem-ask' does."
  (interactive "r")
  (goto-char beg)
  (push-mark end t t)
  (call-interactively #'tandem-ask))

;;;###autoload
(define-minor-mode tandem-embark-mode
  "Put \"@\" in Embark's action menus: ask Claude about the target.
For a file, a symbol, or a region."
  :global t
  :group 'tandem
  (require 'embark)
  (dolist (binding `((,embark-file-map . tandem-embark-ask-file)
                     (,embark-identifier-map . tandem-embark-ask-symbol)
                     (,embark-symbol-map . tandem-embark-ask-symbol)
                     (,embark-region-map . tandem-embark-ask-region)))
    (if tandem-embark-mode
        (keymap-set (car binding) "@" (cdr binding))
      (when (eq (keymap-lookup (car binding) "@") (cdr binding))
        (keymap-unset (car binding) "@" t)))))

(provide 'tandem-embark)
;;; tandem-embark.el ends here
