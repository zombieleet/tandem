;;; claude-pair-tools.el --- What Emacs knows, for Claude  -*- lexical-binding: t; -*-

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

;; Tools Claude calls to learn what Emacs knows, beyond the text of files.
;; All of them only read, so Claude uses them without asking you:
;;
;;   diagnostics   a file's errors and warnings from Flymake or Flycheck,
;;                 the language server's included; or every open file's
;;   xref          where a symbol is defined, or every place it is used,
;;                 through Eglot, lsp-mode or the mode's own backend
;;   imenu         a file's outline: classes, functions, sections
;;   selection     where you are: file, line, the lines on screen, and
;;                 the text you have selected
;;
;; A file Claude asks about is opened if it is not, with unsafe local
;; variables ignored, so the mode and its checker can run.

;;; Code:

(require 'claude-pair-layout)
(require 'claude-pair-mention)
(require 'imenu)
(require 'seq)
(require 'subr-x)
(require 'xref)

(defcustom claude-pair-tools-wait 3
  "Seconds a tool waits for a checker that is still running."
  :type 'number
  :group 'claude-pair)

(defcustom claude-pair-tools-max-results 60
  "Most results a tool lists."
  :type 'natnum
  :group 'claude-pair)

(defun claude-pair-tools--buffer (path)
  "Return a buffer visiting PATH, or signal an error for Claude."
  (unless (file-exists-p path)
    (error "There is no file %s" (abbreviate-file-name path)))
  (claude-pair-layout-file-buffer path))

(defun claude-pair-tools--name (file root)
  "Return FILE relative to ROOT when it is inside, else abbreviated."
  (claude-pair-layout--name file root))

(defun claude-pair-tools--cap (lines)
  "Return LINES, at most `claude-pair-tools-max-results' of them, saying so."
  (if (<= (length lines) claude-pair-tools-max-results)
      lines
    (append (seq-take lines claude-pair-tools-max-results)
            (list (format "… and %d more" (- (length lines) claude-pair-tools-max-results))))))

;;;; diagnostics

(defvar flymake-mode)
(defvar flycheck-mode)
(defvar flycheck-last-status-change)
(declare-function flymake-start "flymake")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-reporting-backends "flymake")
(declare-function flycheck-buffer "flycheck")

(defun claude-pair-tools--check (buffer)
  "Run BUFFER's checker and wait up to `claude-pair-tools-wait' seconds.
Return non-nil if a checker runs there."
  (with-current-buffer buffer
    (cond
     ((bound-and-true-p flymake-mode)
      (flymake-start)
      (with-timeout (claude-pair-tools-wait nil)
        (while (seq-difference (flymake-running-backends) (flymake-reporting-backends))
          (accept-process-output nil 0.05)))
      t)
     ((bound-and-true-p flycheck-mode)
      (flycheck-buffer)
      (with-timeout (claude-pair-tools-wait nil)
        (while (not (memq flycheck-last-status-change '(finished errored no-checker suspicious)))
          (accept-process-output nil 0.05)))
      t))))

(defun claude-pair-tools--diagnostic-lines (buffer root)
  "Return BUFFER's diagnostics as file:line: severity: message lines.
File names are relative to ROOT."
  (let ((name (claude-pair-tools--name (buffer-file-name buffer) root)))
    (mapcar (lambda (d) (format "%s:%d: %s: %s" name (nth 0 d) (nth 1 d) (nth 2 d)))
            (sort (claude-pair-mention-diagnostics buffer) (lambda (a b) (< (car a) (car b)))))))

(defun claude-pair-tools-diagnostics (args _session root)
  "Answer Claude's diagnostics call with ARGS in project ROOT."
  (if-let* ((path (plist-get args :path)))
      (let* ((buffer (claude-pair-tools--buffer path))
             (checked (claude-pair-tools--check buffer))
             (lines (claude-pair-tools--diagnostic-lines buffer root))
             (name (claude-pair-tools--name path root)))
        (cons (cond
               ((not checked) (format "No checker (Flymake or Flycheck) runs for %s in Emacs." name))
               ((null lines) (format "%s: no errors or warnings." name))
               (t (string-join (claude-pair-tools--cap lines) "\n")))
              nil))
    (let ((lines (seq-mapcat (lambda (buffer)
                               (when (and (buffer-file-name buffer)
                                          (file-in-directory-p (buffer-file-name buffer) root))
                                 (claude-pair-tools--diagnostic-lines buffer root)))
                             (buffer-list))))
      (cons (if lines
                (string-join (claude-pair-tools--cap lines) "\n")
              "No open file of the project has errors or warnings in Emacs.")
            nil))))

;;;; xref

(defun claude-pair-tools--symbol-at (symbol line)
  "Move to SYMBOL on LINE, else its first appearance; return non-nil if found."
  (let ((case-fold-search nil)
        (regexp (concat "\\_<" (regexp-quote symbol) "\\_>")))
    (goto-char (point-min))
    (or (and line (> line 0)
             (progn (forward-line (1- line))
                    (re-search-forward regexp (line-end-position) t)))
        (progn (goto-char (point-min)) (re-search-forward regexp nil t)))
    (when (match-beginning 0)
      (goto-char (match-beginning 0))
      t)))

(defun claude-pair-tools-xref (args _session root)
  "Answer Claude's xref call with ARGS in project ROOT."
  (let* ((symbol (string-trim (or (plist-get args :symbol) "")))
         (kind (if (equal (plist-get args :kind) "references") "references" "definitions"))
         (buffer (claude-pair-tools--buffer (plist-get args :path))))
    (when (string-empty-p symbol)
      (error "Xref needs a symbol"))
    (with-current-buffer buffer
      (save-excursion
        (let* ((found (claude-pair-tools--symbol-at symbol (plist-get args :line)))
               (backend (xref-find-backend)))
          (cond
           ((or (null backend)
                (and (eq backend 'etags) (not (bound-and-true-p tags-table-list))
                     (not (bound-and-true-p tags-file-name))))
            ;; etags would ask you for a TAGS file.
            (cons (format "Emacs has no language server or tags for %s, so xref cannot look up %s; use grep."
                          (claude-pair-tools--name (buffer-file-name) root) symbol)
                  nil))
           (t
            (let* ((identifier (or (and found (xref-backend-identifier-at-point backend)) symbol))
                   (items (if (equal kind "references")
                              (xref-backend-references backend identifier)
                            (xref-backend-definitions backend identifier)))
                   (lines (mapcar (lambda (item)
                                    (let ((location (xref-item-location item)))
                                      (format "%s:%s: %s"
                                              (claude-pair-tools--name (xref-location-group location) root)
                                              (claude-pair-tools--line location)
                                              (string-trim (substring-no-properties
                                                            (xref-item-summary item))))))
                                  items)))
              (cons (if lines
                        (concat (format "%s of %s (%s):\n" (capitalize kind) symbol backend)
                                (string-join (claude-pair-tools--cap (delete-dups lines)) "\n"))
                      (format "No %s of %s found (%s)." kind symbol backend))
                    nil)))))))))

(defun claude-pair-tools--line (location)
  "Return the line of the xref LOCATION, finding it when the backend does not say."
  (or (xref-location-line location)
      ;; Some backends (Emacs Lisp's) give a place to look, not a line.
      (ignore-errors
        (let ((marker (save-excursion (xref-location-marker location))))
          (with-current-buffer (marker-buffer marker)
            (line-number-at-pos marker t))))
      "?"))

;;;; imenu

(defun claude-pair-tools--imenu-lines (index prefix)
  "Flatten the imenu INDEX into name (line N) lines, nested under PREFIX."
  (seq-mapcat
   (lambda (entry)
     (let ((name (concat prefix (car entry))))
       (cond
        ((string-prefix-p "*" (car entry)) nil)   ; *Rescan* and the like
        ((imenu--subalist-p entry)
         (claude-pair-tools--imenu-lines (cdr entry) (concat name " > ")))
        (t
         (let ((pos (cdr entry)))
           (setq pos (cond ((overlayp pos) (overlay-start pos))
                           ((markerp pos) (marker-position pos))
                           ((consp pos) (car pos))
                           (t pos)))
           (list (format "%s (line %d)" name (line-number-at-pos pos t))))))))
   index))

(defun claude-pair-tools-imenu (args _session root)
  "Answer Claude's imenu call with ARGS in project ROOT."
  (let* ((path (plist-get args :path))
         (buffer (claude-pair-tools--buffer path))
         (name (claude-pair-tools--name path root)))
    (with-current-buffer buffer
      (let* ((index (condition-case nil
                        (save-excursion (imenu--make-index-alist t))
                      (error nil)))
             (lines (save-excursion (claude-pair-tools--imenu-lines index ""))))
        (cons (if lines
                  (concat (format "Outline of %s:\n" name)
                          (string-join (claude-pair-tools--cap lines) "\n"))
                (format "%s has no outline in Emacs (its mode gives none)." name))
              nil)))))

;;;; selection

(defun claude-pair-tools--your-window ()
  "Return the window you work in: the selected one, unless it is a chat."
  (let ((window (selected-window)))
    (if (claude-pair-layout--chat-p window)
        (or (get-mru-window nil nil t) window)
      window)))

(defun claude-pair-tools-selection (_args _session root)
  "Answer Claude's selection call in project ROOT."
  (let* ((window (claude-pair-tools--your-window))
         (buffer (window-buffer window)))
    (with-current-buffer buffer
      (let* ((point (window-point window))
             (name (if buffer-file-name (claude-pair-tools--name buffer-file-name root) (buffer-name)))
             (start (line-number-at-pos (window-start window)))
             (end (line-number-at-pos (max (window-start window)
                                           (min (point-max) (1- (window-end window t))))))
             (region (and (region-active-p) (eq window (selected-window))
                          (cons (region-beginning) (region-end)))))
        (cons
         (concat
          (format "The user is in %s, at line %d, column %d; lines %d-%d are on their screen."
                  name (line-number-at-pos point) (save-excursion (goto-char point) (current-column))
                  start end)
          (when (buffer-modified-p) " The buffer has unsaved changes.")
          (if region
              (let ((first (line-number-at-pos (car region)))
                    (last (line-number-at-pos (max (car region) (1- (cdr region))))))
                (format "\nThey have selected lines %d-%d:\n%s" first last
                        (claude-pair-mention--fence
                         (claude-pair-mention--limit (buffer-substring-no-properties (car region) (cdr region)))
                         (claude-pair-mention--language))))
            "\nThey have nothing selected."))
         nil)))))

(dolist (tool (list (cons "diagnostics" #'claude-pair-tools-diagnostics)
                    (cons "xref" #'claude-pair-tools-xref)
                    (cons "imenu" #'claude-pair-tools-imenu)
                    (cons "selection" #'claude-pair-tools-selection)))
  (setf (alist-get (car tool) claude-pair-layout-tools nil nil #'equal) (cdr tool)))

(provide 'claude-pair-tools)
;;; claude-pair-tools.el ends here
