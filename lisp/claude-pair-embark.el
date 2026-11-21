;;; claude-pair-embark.el --- Ask Claude from Embark  -*- lexical-binding: t; -*-

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

;; With Embark, "@" in its action menu asks Claude about the target:
;;
;;   a file        the question goes to the chat with the file mentioned
;;   a symbol      the question names it and where you are
;;   a region      as M-x claude-pair-ask: the answer also shows above it
;;
;; Loaded by itself once Embark is.

;;; Code:

(require 'claude-pair-ask)
(require 'claude-pair-chat)
(require 'subr-x)

(defvar embark-file-map)
(defvar embark-identifier-map)
(defvar embark-symbol-map)
(defvar embark-region-map)

(defun claude-pair-embark--send (root text)
  "Send TEXT to the chat about ROOT, showing it."
  (let ((chat (or (claude-pair-chat--buffer-for root) (claude-pair-chat--create root))))
    (with-current-buffer chat
      (when (claude-pair-chat--busy-p)
        (user-error "Claude is still answering in that chat"))
      (claude-pair-chat--send-to-claude text))
    (claude-pair-chat--display chat)))

(defun claude-pair-embark-ask-file (file)
  "Ask Claude a question about FILE."
  (interactive "fAsk Claude about file: ")
  (let* ((file (expand-file-name file))
         (default-directory (file-name-directory file))
         (root (claude-pair-chat--project-root))
         (name (if (file-in-directory-p file root) (file-relative-name file root) file))
         (question (read-string (format "Ask Claude about %s: " name))))
    (when (string-blank-p question)
      (user-error "No question"))
    (claude-pair-embark--send root (format "%s @%s" (string-trim question) name))))

(defun claude-pair-embark-ask-symbol (symbol)
  "Ask Claude a question about SYMBOL, where you are."
  (interactive (list (or (thing-at-point 'symbol t) (read-string "Symbol: "))))
  (let* ((root (claude-pair-chat--project-root))
         (where (when buffer-file-name
                  (format " (in %s, line %d)"
                          (if (file-in-directory-p buffer-file-name root)
                              (file-relative-name buffer-file-name root)
                            (abbreviate-file-name buffer-file-name))
                          (line-number-at-pos))))
         (question (read-string (format "Ask Claude about %s: " symbol))))
    (when (string-blank-p question)
      (user-error "No question"))
    (claude-pair-embark--send root (format "%s\n\nAbout `%s`%s." (string-trim question) symbol (or where "")))))

(defun claude-pair-embark-ask-region (beg end)
  "Ask Claude about the region from BEG to END, as `claude-pair-ask' does."
  (interactive "r")
  (goto-char beg)
  (push-mark end t t)
  (call-interactively #'claude-pair-ask))

(keymap-set embark-file-map "@" #'claude-pair-embark-ask-file)
(keymap-set embark-identifier-map "@" #'claude-pair-embark-ask-symbol)
(keymap-set embark-symbol-map "@" #'claude-pair-embark-ask-symbol)
(keymap-set embark-region-map "@" #'claude-pair-embark-ask-region)

(provide 'claude-pair-embark)
;;; claude-pair-embark.el ends here
