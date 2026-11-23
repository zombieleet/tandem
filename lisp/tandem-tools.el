;;; tandem-tools.el --- What Emacs knows, for Claude  -*- lexical-binding: t; -*-

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

(require 'tandem-chat)
(require 'tandem-layout)
(require 'tandem-mention)
(require 'imenu)
(require 'seq)
(require 'subr-x)
(require 'xref)

(defcustom tandem-tools-wait 3
  "Seconds a tool waits for a checker that is still running."
  :type 'number
  :group 'tandem)

(defcustom tandem-tools-max-results 60
  "Most results a tool lists."
  :type 'natnum
  :group 'tandem)

(defun tandem-tools--buffer (path)
  "Return a buffer visiting PATH, or signal an error for Claude."
  (unless (file-exists-p path)
    (error "There is no file %s" (abbreviate-file-name path)))
  (tandem-layout-file-buffer path))

(defun tandem-tools--name (file root)
  "Return FILE relative to ROOT when it is inside, else abbreviated."
  (tandem-layout--name file root))

(defun tandem-tools--cap (lines)
  "Return LINES, at most `tandem-tools-max-results' of them, saying so."
  (if (<= (length lines) tandem-tools-max-results)
      lines
    (append (seq-take lines tandem-tools-max-results)
            (list (format "… and %d more" (- (length lines) tandem-tools-max-results))))))

;;;; diagnostics

(defvar flymake-mode)
(defvar flycheck-mode)
(defvar flycheck-last-status-change)
(declare-function flymake-start "flymake")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-reporting-backends "flymake")
(declare-function flycheck-buffer "flycheck")

(defun tandem-tools--check (buffer)
  "Run BUFFER's checker and wait up to `tandem-tools-wait' seconds.
Return non-nil if a checker runs there."
  (with-current-buffer buffer
    (cond
     ((bound-and-true-p flymake-mode)
      (flymake-start)
      (with-timeout (tandem-tools-wait nil)
        (while (seq-difference (flymake-running-backends) (flymake-reporting-backends))
          (accept-process-output nil 0.05)))
      t)
     ((bound-and-true-p flycheck-mode)
      (flycheck-buffer)
      (with-timeout (tandem-tools-wait nil)
        (while (not (memq flycheck-last-status-change '(finished errored no-checker suspicious)))
          (accept-process-output nil 0.05)))
      t))))

(defun tandem-tools--diagnostic-lines (buffer root)
  "Return BUFFER's diagnostics as file:line: severity: message lines.
File names are relative to ROOT."
  (let ((name (tandem-tools--name (buffer-file-name buffer) root)))
    (mapcar (lambda (d) (format "%s:%d: %s: %s" name (nth 0 d) (nth 1 d) (nth 2 d)))
            (sort (tandem-mention-diagnostics buffer) (lambda (a b) (< (car a) (car b)))))))

(defun tandem-tools-diagnostics (args _session root)
  "Answer Claude's diagnostics call with ARGS in project ROOT."
  (if-let* ((path (plist-get args :path)))
      (let* ((buffer (tandem-tools--buffer path))
             (checked (tandem-tools--check buffer))
             (lines (tandem-tools--diagnostic-lines buffer root))
             (name (tandem-tools--name path root)))
        (cons (cond
               ((not checked) (format "No checker (Flymake or Flycheck) runs for %s in Emacs." name))
               ((null lines) (format "%s: no errors or warnings." name))
               (t (string-join (tandem-tools--cap lines) "\n")))
              nil))
    (let ((lines (seq-mapcat (lambda (buffer)
                               (when (and (buffer-file-name buffer)
                                          (file-in-directory-p (buffer-file-name buffer) root))
                                 (tandem-tools--diagnostic-lines buffer root)))
                             (buffer-list))))
      (cons (if lines
                (string-join (tandem-tools--cap lines) "\n")
              "No open file of the project has errors or warnings in Emacs.")
            nil))))

;;;; xref

(defun tandem-tools--symbol-at (symbol line)
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

;;;; Stepping through the places xref found

(defvar compilation-current-error)

(defvar tandem-tools--locations-buffer "*tandem locations*"
  "Name of the buffer listing the places of Claude's last xref lookup.")

(defun tandem-tools--locations (session root title places)
  "List PLACES, Claude's xref result TITLE in ROOT, for `next-error'.
PLACES are (FILE LINE SUMMARY), FILE relative to ROOT.  \\[next-error] and
\\[previous-error] then step through them, each highlighted.  SESSION's
chat says so."
  (require 'grep)
  (let ((buffer (get-buffer-create tandem-tools--locations-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq default-directory (file-name-as-directory root))
        (insert title "\n\n")
        (dolist (place places)
          (insert (format "%s:%d:%s\n" (nth 0 place) (nth 1 place) (nth 2 place))))
        (grep-mode)
        (goto-char (point-min))
        (setq compilation-current-error nil)))
    (setq next-error-last-buffer buffer)
    (when-let* ((chat (gethash session tandem-chat--buffers)))
      (with-current-buffer chat
        (tandem-chat--enqueue
         (cons 'notice (substitute-command-keys
                        (format (if (bound-and-true-p repeat-mode)
                                    "%d places: \\[next-error] goes to the next, then n and p step through them; \
M-x tandem-locations lists them."
                                  "%d places: \\[next-error] and \\[previous-error] step through them, \
M-x tandem-locations lists them.")
                                (length places)))))))
    buffer))

(defun tandem-tools--shown (buffer line _last)
  "Step on from the place Claude showed, if it is one of those listed.
BUFFER is shown at LINE."
  (when-let* ((locations (get-buffer tandem-tools--locations-buffer))
              (file (buffer-file-name buffer)))
    (with-current-buffer locations
      (save-excursion
        (goto-char (point-min))
        (forward-line 2)
        (catch 'found
          (while (not (eobp))
            (when (looking-at "\\(.+\\):\\([0-9]+\\):")
              (when (and (= (string-to-number (match-string 2)) line)
                         (file-equal-p (expand-file-name (match-string 1)) file))
                (setq compilation-current-error (point-marker))
                (setq next-error-last-buffer locations)
                (throw 'found t)))
            (forward-line 1)))))))

(defun tandem-tools--after-next-error ()
  "Highlight the place `next-error' went to, if it is one of Claude's."
  (when (and next-error-last-buffer
             (equal (buffer-name next-error-last-buffer) tandem-tools--locations-buffer))
    (let ((line (line-number-at-pos)))
      (tandem-layout-highlight (current-buffer) line line))))

;;;###autoload
(defun tandem-locations ()
  "Show the places of Claude's last xref lookup."
  (interactive)
  (if-let* ((buffer (get-buffer tandem-tools--locations-buffer)))
      (pop-to-buffer buffer)
    (user-error "Claude has looked nothing up yet")))

(add-hook 'tandem-layout-shown-functions #'tandem-tools--shown)
(add-hook 'next-error-hook #'tandem-tools--after-next-error)

(defun tandem-tools-xref (args session root)
  "Answer Claude's xref call with ARGS for SESSION in project ROOT."
  (let* ((symbol (string-trim (or (plist-get args :symbol) "")))
         (kind (if (equal (plist-get args :kind) "references") "references" "definitions"))
         (buffer (tandem-tools--buffer (plist-get args :path))))
    (when (string-empty-p symbol)
      (error "Xref needs a symbol"))
    (with-current-buffer buffer
      (save-excursion
        (let* ((found (tandem-tools--symbol-at symbol (plist-get args :line)))
               (backend (xref-find-backend)))
          (cond
           ((or (null backend)
                (and (eq backend 'etags) (not (bound-and-true-p tags-table-list))
                     (not (bound-and-true-p tags-file-name))))
            ;; etags would ask you for a TAGS file.
            (cons (format "Emacs has no language server or tags for %s, so xref cannot look up %s; use grep."
                          (tandem-tools--name (buffer-file-name) root) symbol)
                  nil))
           (t
            (let* ((identifier (or (and found (xref-backend-identifier-at-point backend)) symbol))
                   (items (if (equal kind "references")
                              (xref-backend-references backend identifier)
                            (xref-backend-definitions backend identifier)))
                   (places (delete-dups
                                    (mapcar (lambda (item)
                                              (let ((location (xref-item-location item)))
                                                (list (tandem-tools--name (xref-location-group location) root)
                                                      (tandem-tools--line location)
                                                      (string-trim (substring-no-properties
                                                                    (xref-item-summary item))))))
                                            items)))
                   (lines (mapcar (lambda (p) (format "%s:%s: %s" (nth 0 p) (nth 1 p) (nth 2 p))) places)))
              ;; Several places: you can step through them.
              (let ((numbered (seq-uniq (seq-filter (lambda (p) (numberp (nth 1 p))) places)
                                        ;; One stop per line, however many uses are on it.
                                        (lambda (a b) (and (equal (nth 0 a) (nth 0 b))
                                                           (equal (nth 1 a) (nth 1 b)))))))
                (when (cdr numbered)
                  (tandem-tools--locations
                   session root (format "%s of %s" (capitalize kind) symbol) numbered)))
              (cons (if lines
                        (concat (format "%s of %s (%s):\n" (capitalize kind) symbol backend)
                                (string-join (tandem-tools--cap lines) "\n"))
                      (format "No %s of %s found (%s)." kind symbol backend))
                    nil)))))))))

(defun tandem-tools--line (location)
  "Return the line of the xref LOCATION, finding it when the backend does not say."
  (or (xref-location-line location)
      ;; Some backends (Emacs Lisp's) give a place to look, not a line.
      (ignore-errors
        (let ((marker (save-excursion (xref-location-marker location))))
          (with-current-buffer (marker-buffer marker)
            (line-number-at-pos marker t))))
      "?"))

;;;; imenu

(defun tandem-tools--imenu-lines (index prefix)
  "Flatten the imenu INDEX into name (line N) lines, nested under PREFIX."
  (seq-mapcat
   (lambda (entry)
     (let ((name (concat prefix (car entry))))
       (cond
        ((string-prefix-p "*" (car entry)) nil)   ; *Rescan* and the like
        ((imenu--subalist-p entry)
         (tandem-tools--imenu-lines (cdr entry) (concat name " > ")))
        (t
         (let ((pos (cdr entry)))
           (setq pos (cond ((overlayp pos) (overlay-start pos))
                           ((markerp pos) (marker-position pos))
                           ((consp pos) (car pos))
                           (t pos)))
           (list (format "%s (line %d)" name (line-number-at-pos pos t))))))))
   index))

(defun tandem-tools-imenu (args _session root)
  "Answer Claude's imenu call with ARGS in project ROOT."
  (let* ((path (plist-get args :path))
         (buffer (tandem-tools--buffer path))
         (name (tandem-tools--name path root)))
    (with-current-buffer buffer
      (let* ((index (condition-case nil
                        (save-excursion (imenu--make-index-alist t))
                      (error nil)))
             (lines (save-excursion (tandem-tools--imenu-lines index ""))))
        (cons (if lines
                  (concat (format "Outline of %s:\n" name)
                          (string-join (tandem-tools--cap lines) "\n"))
                (format "%s has no outline in Emacs (its mode gives none)." name))
              nil)))))

;;;; selection

(defun tandem-tools--your-window ()
  "Return the window you work in: the selected one, unless it is a chat."
  (let ((window (selected-window)))
    (if (tandem-layout--chat-p window)
        (or (get-mru-window nil nil t) window)
      window)))

(defun tandem-tools-selection (_args _session root)
  "Answer Claude's selection call in project ROOT."
  (let* ((window (tandem-tools--your-window))
         (buffer (window-buffer window)))
    (with-current-buffer buffer
      (let* ((point (window-point window))
             (name (if buffer-file-name (tandem-tools--name buffer-file-name root) (buffer-name)))
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
                        (tandem-mention--fence
                         (tandem-mention--limit (buffer-substring-no-properties (car region) (cdr region)))
                         (tandem-mention--language))))
            "\nThey have nothing selected."))
         nil)))))

(dolist (tool (list (cons "diagnostics" #'tandem-tools-diagnostics)
                    (cons "xref" #'tandem-tools-xref)
                    (cons "imenu" #'tandem-tools-imenu)
                    (cons "selection" #'tandem-tools-selection)))
  (setf (alist-get (car tool) tandem-layout-tools nil nil #'equal) (cdr tool)))

(provide 'tandem-tools)
;;; tandem-tools.el ends here
