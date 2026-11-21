;;; claude-pair-markdown.el --- Code in the chat, in colour  -*- lexical-binding: t; -*-

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

;; The chat shows code the way Markdown means it:
;;
;; - `inline code' in a code face, its backticks hidden (they stay in the
;;   text, so copying keeps them);
;; - fenced blocks, ```lang … ```, coloured by that language's major mode
;;   on a block background, the fence lines dimmed.
;;
;; A block is coloured in a hidden buffer per mode, whose mode hooks never
;; run: no language server or linter starts to colour a snippet.  Claude's
;; text is rendered as it streams, whole lines and closed blocks at a time.

;;; Code:

(require 'seq)
(require 'subr-x)

(defface claude-pair-markdown-code
  '((((background dark)) :inherit font-lock-constant-face :background "#2b2b2b")
    (t :inherit font-lock-constant-face :background "#efefef"))
  "Face for `inline code' in the chat."
  :group 'claude-pair)

(defface claude-pair-markdown-block
  '((((background dark)) :background "#222222" :extend t)
    (t :background "#f5f5f5" :extend t))
  "Face under a code block in the chat."
  :group 'claude-pair)

(defface claude-pair-markdown-fence
  '((t :inherit shadow :extend t))
  "Face for the ``` lines around a code block."
  :group 'claude-pair)

(defcustom claude-pair-markdown-modes
  '(("py" . python-mode) ("python" . python-mode)
    ("js" . js-mode) ("javascript" . js-mode) ("jsx" . js-mode)
    ("ts" . typescript-ts-mode) ("typescript" . typescript-ts-mode) ("tsx" . tsx-ts-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode) ("zsh" . sh-mode) ("console" . sh-mode)
    ("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode) ("lisp" . lisp-mode)
    ("c" . c-mode) ("h" . c-mode) ("cpp" . c++-mode) ("c++" . c++-mode) ("cc" . c++-mode)
    ("rs" . rust-mode) ("rust" . rust-mode) ("go" . go-mode) ("golang" . go-mode)
    ("rb" . ruby-mode) ("ruby" . ruby-mode) ("java" . java-mode)
    ("json" . js-json-mode) ("yaml" . yaml-mode) ("yml" . yaml-mode) ("toml" . conf-toml-mode)
    ("html" . html-mode) ("xml" . xml-mode) ("css" . css-mode) ("sql" . sql-mode)
    ("diff" . diff-mode) ("patch" . diff-mode) ("make" . makefile-mode) ("makefile" . makefile-mode)
    ("dockerfile" . dockerfile-mode) ("lua" . lua-mode) ("org" . org-mode) ("md" . markdown-mode)
    ("markdown" . markdown-mode))
  "Major modes for the languages named after ``` in the chat.
A language not listed uses LANG-mode, or LANG-ts-mode, when one exists."
  :type '(alist :key-type string :value-type function)
  :group 'claude-pair)

(defconst claude-pair-markdown--fence "^[ \t]*\\(`\\{3,\\}\\)[ \t]*\\([^` \t\n]*\\)[^`\n]*$"
  "An opening fence: three or more backticks, then perhaps a language.")

(defconst claude-pair-markdown--inline "\\(`\\)\\([^`\n]+\\)\\(`\\)"
  "Inline code: text between single backticks on one line.")

;;;; Colouring a block

(defun claude-pair-markdown--mode (language)
  "Return the major mode for LANGUAGE, or nil."
  (let* ((language (downcase (or language "")))
         (mode (or (cdr (assoc language claude-pair-markdown-modes))
                   (and (not (string-empty-p language)) (intern (concat language "-mode")))))
         (ts (and (not (string-empty-p language)) (intern (concat language "-ts-mode")))))
    (cond
     ((and mode (fboundp mode)) mode)
     ((and ts (fboundp ts) (fboundp 'treesit-language-available-p)
           (treesit-language-available-p (intern language)))
      ts))))

(defun claude-pair-markdown--fontify (code mode)
  "Return CODE coloured by MODE, or nil if that fails.
The colouring happens in a hidden buffer whose mode hooks never run."
  (condition-case nil
      (with-current-buffer (get-buffer-create (format " *claude-pair fontify: %s*" mode))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert code)
          (unless (eq major-mode mode)
            (delay-mode-hooks (funcall mode)))
          (font-lock-ensure)
          (buffer-string)))
    (error nil)))

(defun claude-pair-markdown--paint (beg code)
  "Copy the faces of CODE onto the buffer text of the same length at BEG."
  (let ((pos 0))
    (while (< pos (length code))
      (let ((next (next-single-property-change pos 'face code (length code)))
            (face (get-text-property pos 'face code)))
        (when face
          (put-text-property (+ beg pos) (+ beg next) 'face face)
          (put-text-property (+ beg pos) (+ beg next) 'font-lock-face face))
        (setq pos next)))))

(defun claude-pair-markdown--block (open-beg code-beg code-end close-end language)
  "Render the code block from OPEN-BEG to CLOSE-END.
Its code runs from CODE-BEG to CODE-END; LANGUAGE names its language."
  (let ((dim (lambda (from to)
               (when (< from to)
                 (put-text-property from to 'face 'claude-pair-markdown-fence)
                 (put-text-property from to 'font-lock-face 'claude-pair-markdown-fence)))))
    (funcall dim open-beg code-beg)
    (funcall dim code-end close-end)
    (when (< code-beg code-end)
      (when-let* ((mode (claude-pair-markdown--mode language))
                  (coloured (claude-pair-markdown--fontify
                             (buffer-substring-no-properties code-beg code-end) mode)))
        (claude-pair-markdown--paint code-beg coloured))
      (add-face-text-property code-beg code-end 'claude-pair-markdown-block t)
      (let ((pos code-beg))
        ;; font-lock-face too, for buffers that refontify.
        (while (< pos code-end)
          (let ((next (next-single-property-change pos 'face nil code-end)))
            (put-text-property pos next 'font-lock-face (get-text-property pos 'face))
            (setq pos next)))))))

;;;; Inline code

(defvar claude-pair-markdown--show-ticks nil
  "Non-nil to dim the backticks of inline code instead of hiding them.
Text being typed shows them, so the cursor never jumps over hidden text.")

(defun claude-pair-markdown--inline (beg end)
  "Render `inline code' from BEG to END."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward claude-pair-markdown--inline end t)
      (let ((code-beg (match-beginning 2)) (code-end (match-end 2)))
        (put-text-property code-beg code-end 'face 'claude-pair-markdown-code)
        (put-text-property code-beg code-end 'font-lock-face 'claude-pair-markdown-code)
        (dolist (tick (list (cons (match-beginning 1) (match-end 1))
                            (cons (match-beginning 3) (match-end 3))))
          (if claude-pair-markdown--show-ticks
              (progn (put-text-property (car tick) (cdr tick) 'face 'claude-pair-markdown-fence)
                     (put-text-property (car tick) (cdr tick) 'font-lock-face 'claude-pair-markdown-fence))
            (put-text-property (car tick) (cdr tick) 'invisible t)))))))

;;;; Rendering

(defun claude-pair-markdown-render (beg end final)
  "Render the Markdown code from BEG to END and return where rendering stopped.
Without FINAL, the text may still grow: only whole lines and closed
blocks are rendered.  With FINAL, everything is, an unclosed block up to
END.  Only text properties change."
  (let ((inhibit-read-only t)
        (buffer-undo-list t)
        (inhibit-modification-hooks t)
        (pos (if (markerp beg) (marker-position beg) beg))
        (end (if (markerp end) (marker-position end) end))
        (done nil))
    (save-excursion
      (while (not done)
        (goto-char pos)
        (if (re-search-forward claude-pair-markdown--fence end t)
            (let* ((open-beg (match-beginning 0))
                   (ticks (match-string 1))
                   (language (match-string 2))
                   (code-beg (min end (1+ (match-end 0))))
                   (close (save-excursion
                            (goto-char code-beg)
                            (and (re-search-forward (concat "^[ \t]*" (regexp-quote ticks) "`*[ \t]*$") end t)
                                 (cons (match-beginning 0) (match-end 0))))))
              (claude-pair-markdown--inline pos open-beg)
              (cond
               (close
                (let ((close-end (min end (1+ (cdr close)))))
                  (claude-pair-markdown--block open-beg code-beg (car close) close-end language)
                  (setq pos close-end)))
               (final
                (claude-pair-markdown--block open-beg code-beg end end language)
                (setq pos end done t))
               (t
                ;; Still streaming: wait for its closing fence.
                (setq pos open-beg done t))))
          ;; No more blocks: inline code on whole lines, or all of it at the end.
          (let ((stop (if final end
                        (save-excursion (goto-char end)
                                        (if (bolp) end (max pos (line-beginning-position)))))))
            (claude-pair-markdown--inline pos stop)
            (setq pos stop done t)))))
    pos))

(defun claude-pair-markdown-render-draft (beg end)
  "Render the text being typed from BEG to END afresh.
Earlier rendering there is removed first; backticks stay visible."
  (let ((inhibit-read-only t)
        (buffer-undo-list t)
        (inhibit-modification-hooks t))
    (remove-list-of-text-properties beg end '(face font-lock-face invisible)))
  (let ((claude-pair-markdown--show-ticks t))
    (claude-pair-markdown-render beg end t)))

;;;; Into Org

(defun claude-pair-markdown--org-inline (line)
  "Return LINE with Markdown's inline code, bold and links in Org syntax."
  (let ((case-fold-search nil))
    (thread-last
      line
      (replace-regexp-in-string "`\\([^`\n]+\\)`" "~\\1~")
      (replace-regexp-in-string "\\*\\*\\([^*\n]+\\)\\*\\*" "*\\1*")
      (replace-regexp-in-string "\\[\\([^]\n]+\\)\\](\\([^)\n]+\\))" "[[\\2][\\1]]"))))

(defun claude-pair-markdown-to-org (text &optional level)
  "Return Markdown TEXT as Org, for a subtree at LEVEL (1 by default).
Fenced code becomes source blocks, headings become headings below
LEVEL, bullets become dashes, and inline code, bold and links change
syntax.  Nothing in code blocks changes, and no line of the result can
start a heading of its own by accident."
  (let ((level (or level 1))
        (in-code nil)
        (lines nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match "\\`[ \t]*```+[ \t]*\\([^` \t]*\\)" line)
        (push (if in-code
                  "#+end_src"
                (concat "#+begin_src" (if (string-empty-p (match-string 1 line)) ""
                                         (concat " " (match-string 1 line)))))
              lines)
        (setq in-code (not in-code)))
       (in-code
        ;; Org reads a line starting with * or #+ in a block as its own.
        (push (if (string-match-p "\\`\\(?:\\*\\|#\\+\\)" line) (concat "," line) line) lines))
       ((string-match "\\`\\(#+\\)[ \t]+\\(.*\\)" line)
        (push (concat (make-string (+ level (length (match-string 1 line))) ?*) " "
                      (claude-pair-markdown--org-inline (match-string 2 line)))
              lines))
       ((string-match "\\`\\([ \t]*\\)[*+][ \t]+\\(.*\\)" line)
        (push (concat (match-string 1 line) "- " (claude-pair-markdown--org-inline (match-string 2 line))) lines))
       ((string-match-p "\\`\\*" line)
        (push (concat " " (claude-pair-markdown--org-inline line)) lines))
       (t (push (claude-pair-markdown--org-inline line) lines))))
    (when in-code (push "#+end_src" lines))
    (string-join (nreverse lines) "\n")))

(provide 'claude-pair-markdown)
;;; claude-pair-markdown.el ends here
