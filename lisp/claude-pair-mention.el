;;; claude-pair-mention.el --- Point Claude at files, buffers, regions  -*- lexical-binding: t; -*-

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

;; In the chat, @ points Claude at something you have in Emacs:
;;
;;   @src/geo.py     a file of the project
;;   @buffer         the buffer you were last in
;;   @region         the region you last had there
;;   @diagnostics    that buffer's Flymake or Flycheck diagnostics
;;
;; Type @ and complete (`completion-at-point', so Corfu and Company work
;; too), or press C-c @ for a menu.  Your message stays as you wrote it;
;; Claude also gets what each mention points at, after it: a file's path to
;; read, a region's place and code, a buffer's text when it is not saved
;; in a file, and diagnostics as file:line lines.  In the transcript the
;; mentions are buttons that take you there.

;;; Code:

(require 'cl-lib)
(require 'claude-pair-chat)
(require 'project)
(require 'seq)
(require 'subr-x)

(defcustom claude-pair-mention-max-files 5000
  "Most project files @ completion offers."
  :type 'natnum
  :group 'claude-pair)

(defcustom claude-pair-mention-max-lines 400
  "Most lines of a buffer or region a mention attaches."
  :type 'natnum
  :group 'claude-pair)

(defface claude-pair-mention
  '((t :inherit link :underline nil :weight bold))
  "Face for a mention in your message."
  :group 'claude-pair)

(defconst claude-pair-mention--special '("buffer" "region" "diagnostics")
  "Mentions that are not files.")

(defconst claude-pair-mention--regexp "\\(?:^\\|[ \t\n(]\\)\\(@\\([^ \t\n()]+\\)\\)"
  "A mention: @ at the start of a word, then the name.")

;;;; What a mention points at

(defun claude-pair-mention--source ()
  "Return the buffer you were in before the chat.
It is the one the most recently used window, other than the selected
one, shows."
  (let ((window (get-mru-window nil nil t)))
    (if window (window-buffer window) (other-buffer (current-buffer) t))))

(defun claude-pair-mention--root ()
  "Return the chat's project folder, as a directory name."
  (file-name-as-directory (or claude-pair-chat--root default-directory)))

(defun claude-pair-mention--files ()
  "Return the project's files, relative to the chat's folder."
  (let* ((root (claude-pair-mention--root))
         (project (let ((default-directory root)) (project-current)))
         (files (if project
                    (project-files project)
                  (directory-files-recursively root "" nil
                                               (lambda (dir) (not (string-prefix-p "." (file-name-nondirectory dir))))))))
    (mapcar (lambda (f) (file-relative-name f root))
            (seq-take files claude-pair-mention-max-files))))

(defun claude-pair-mention--fence (code &optional language)
  "Return CODE in a fence longer than any backticks in it, tagged LANGUAGE."
  (let ((longest 2) (start 0))
    (while (string-match "`+" code start)
      (setq longest (max longest (- (match-end 0) (match-beginning 0))) start (match-end 0)))
    (let ((fence (make-string (1+ longest) ?`)))
      (concat fence (or language "") "\n" code (if (string-suffix-p "\n" code) "" "\n") fence))))

(defun claude-pair-mention--language ()
  "Return a name for the current buffer's language, for a code fence."
  (if (derived-mode-p 'prog-mode 'text-mode 'conf-mode)
      (replace-regexp-in-string "\\(-ts\\)?-mode\\'" "" (symbol-name major-mode))
    ""))

(defun claude-pair-mention--limit (text)
  "Return TEXT, cut to `claude-pair-mention-max-lines' lines."
  (let ((lines (split-string text "\n")))
    (if (<= (length lines) claude-pair-mention-max-lines)
        text
      (concat (string-join (last lines claude-pair-mention-max-lines) "\n")
              (format "\n[only the last %d lines]" claude-pair-mention-max-lines)))))

(defun claude-pair-mention--name (buffer root)
  "Return BUFFER's file relative to ROOT, or its name."
  (if-let* ((file (buffer-file-name buffer)))
      (if (file-in-directory-p file root) (file-relative-name file root) (abbreviate-file-name file))
    (buffer-name buffer)))

(defun claude-pair-mention--buffer (source root)
  "Describe the buffer SOURCE for Claude; ROOT is the project."
  (with-current-buffer source
    (let ((name (claude-pair-mention--name source root)))
      (if (and buffer-file-name (not (buffer-modified-p)))
          (format "@buffer is the file %s (saved; read it)." name)
        (format "@buffer is %s%s:\n%s" name
                (if buffer-file-name " with unsaved changes; its text now" "")
                (claude-pair-mention--fence
                 (claude-pair-mention--limit
                  (buffer-substring-no-properties (point-min) (point-max)))
                 (claude-pair-mention--language)))))))

(defun claude-pair-mention--region (source root)
  "Describe the region you last had in SOURCE; ROOT is the project."
  (with-current-buffer source
    (if (not (mark t))
        "@region: there is no region in that buffer."
      (let* ((beg (min (point) (mark t)))
             (end (max (point) (mark t)))
             (first (line-number-at-pos beg))
             (last (line-number-at-pos (max beg (1- end)))))
        (format "@region is %s of %s:\n%s"
                (if (= first last) (format "line %d" first) (format "lines %d-%d" first last))
                (claude-pair-mention--name source root)
                (claude-pair-mention--fence
                 (claude-pair-mention--limit (buffer-substring-no-properties beg end))
                 (claude-pair-mention--language)))))))

(defun claude-pair-mention-diagnostics (buffer)
  "Return BUFFER's diagnostics as (LINE SEVERITY MESSAGE) lists.
They come from Flymake or Flycheck, whichever runs there."
  (with-current-buffer buffer
    (cond
     ((and (bound-and-true-p flymake-mode) (fboundp 'flymake-diagnostics))
      (mapcar (lambda (d)
                (list (line-number-at-pos (flymake-diagnostic-beg d))
                      (pcase (flymake-diagnostic-type d)
                        ((or :error 'eglot-error) "error")
                        ((or :warning 'eglot-warning) "warning")
                        (_ "note"))
                      (flymake-diagnostic-text d)))
              (flymake-diagnostics)))
     ((and (bound-and-true-p flycheck-mode) (boundp 'flycheck-current-errors))
      (mapcar (lambda (e)
                (list (flycheck-error-line e)
                      (symbol-name (flycheck-error-level e))
                      (flycheck-error-message e)))
              (symbol-value 'flycheck-current-errors))))))

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-message "flycheck")

(defun claude-pair-mention--diagnostics (source root)
  "Describe SOURCE's diagnostics for Claude; ROOT is the project."
  (let ((name (claude-pair-mention--name source root))
        (diagnostics (claude-pair-mention-diagnostics source)))
    (if (null diagnostics)
        (format "@diagnostics: %s has none (or no checker runs there)." name)
      (concat (format "@diagnostics of %s:\n" name)
              (mapconcat (lambda (d) (format "%s:%d: %s: %s" name (nth 0 d) (nth 1 d) (nth 2 d)))
                         (sort diagnostics (lambda (a b) (< (car a) (car b))))
                         "\n")))))

(defun claude-pair-mention--describe (name source root)
  "Describe the mention NAME for Claude, or return nil if it names nothing.
SOURCE is the buffer you were in; ROOT the project."
  (pcase name
    ("buffer" (claude-pair-mention--buffer source root))
    ("region" (claude-pair-mention--region source root))
    ("diagnostics" (claude-pair-mention--diagnostics source root))
    (_ (let ((file (expand-file-name name root)))
         (when (file-exists-p file)
           (format "@%s is %s %s in the project (read it as needed)."
                   name (if (file-directory-p file) "the folder" "the file") name))))))

;;;; Sending and showing

(defun claude-pair-mention--names (text)
  "Return the mentions in TEXT, without @, each once, in order."
  (let ((start 0) names)
    (while (string-match claude-pair-mention--regexp text start)
      (cl-pushnew (string-trim-right (match-string 2 text) "[.,;:!?]+") names :test #'equal)
      (setq start (match-end 1)))
    (nreverse names)))

(defun claude-pair-mention-expand (text)
  "Return TEXT with what its mentions point at attached after it."
  (let* ((root (claude-pair-mention--root))
         (source (claude-pair-mention--source))
         (parts (delq nil (mapcar (lambda (name) (claude-pair-mention--describe name source root))
                                  (claude-pair-mention--names text)))))
    (if (null parts)
        text
      (concat text "\n\nContext the user attached:\n\n" (string-join parts "\n\n")))))

(defun claude-pair-mention--jump (name root)
  "Go to what the mention NAME points at; ROOT is the project."
  (let ((file (expand-file-name name root)))
    (cond
     ((file-exists-p file) (find-file-other-window file))
     (t (message "claude-pair: @%s points at what you had when you sent it" name)))))

(defun claude-pair-mention-buttons (text)
  "Return TEXT with its mentions drawn as buttons."
  (let ((text (copy-sequence text))
        (root (claude-pair-mention--root))
        (start 0))
    (while (string-match claude-pair-mention--regexp text start)
      (let* ((beg (match-beginning 1))
             (end (match-end 1))
             (name (string-trim-right (match-string 2 text) "[.,;:!?]+"))
             (map (make-sparse-keymap)))
        (when (or (member name claude-pair-mention--special)
                  (file-exists-p (expand-file-name name root)))
          (let ((jump (lambda () (interactive) (claude-pair-mention--jump name root))))
            (keymap-set map "RET" jump)
            (keymap-set map "<mouse-1>" jump))
          (add-text-properties beg (+ beg 1 (length name))
                               (list 'face 'claude-pair-mention 'mouse-face 'highlight
                                     'keymap map 'help-echo (format "@%s: RET or mouse-1 goes there" name))
                               text))
        (setq start end)))
    text))

;;;; Completion

(defun claude-pair-mention-capf ()
  "Complete a mention after @ in the chat's composer."
  (when (and (derived-mode-p 'claude-pair-chat-mode)
             (>= (point) claude-pair-chat--input))
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t\n()@")
        (when (and (eq (char-before) ?@)
                   (let ((at (1- (point))))
                     (or (= at claude-pair-chat--input)
                         (memq (char-before at) '(?\s ?\t ?\n ?\()))))
          (list (point) end
                (completion-table-dynamic
                 (lambda (_) (append claude-pair-mention--special (claude-pair-mention--files))))
                :exclusive 'no
                :annotation-function
                (lambda (c) (if (member c claude-pair-mention--special) " (what you have in Emacs)" " (file)"))))))))

(defun claude-pair-mention-insert (name)
  "Insert a mention of NAME, chosen from a menu."
  (interactive
   (list (completing-read "Point Claude at: @"
                          (append claude-pair-mention--special (claude-pair-mention--files)))))
  (claude-pair-chat--check-buffer)
  (when (< (point) claude-pair-chat--input)
    (goto-char (point-max)))
  (unless (or (= (point) claude-pair-chat--input) (memq (char-before) '(?\s ?\n ?\t)))
    (insert " "))
  (insert "@" name " "))

(defun claude-pair-mention--setup ()
  "Set up mentions in a chat buffer."
  (add-hook 'completion-at-point-functions #'claude-pair-mention-capf nil t))

(add-hook 'claude-pair-chat-mode-hook #'claude-pair-mention--setup)
(add-hook 'claude-pair-chat-text-functions #'claude-pair-mention-expand)
(setq claude-pair-chat-show-user-function #'claude-pair-mention-buttons)
(keymap-set claude-pair-chat-mode-map "C-c @" #'claude-pair-mention-insert)

(provide 'claude-pair-mention)
;;; claude-pair-mention.el ends here
