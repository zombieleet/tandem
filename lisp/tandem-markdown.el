;;; tandem-markdown.el --- Code in the chat, in colour  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience
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

(defface tandem-markdown-code
  '((((background dark)) :inherit font-lock-constant-face :background "#2b2b2b")
    (t :inherit font-lock-constant-face :background "#efefef"))
  "Face for `inline code' in the chat."
  :group 'tandem)

(defface tandem-markdown-block
  '((((background dark)) :background "#222222" :extend t)
    (t :background "#f5f5f5" :extend t))
  "Face under a code block in the chat."
  :group 'tandem)

(defface tandem-markdown-fence
  '((t :inherit shadow :extend t))
  "Face for the ``` lines around a code block."
  :group 'tandem)

(defcustom tandem-markdown-modes
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
  :group 'tandem)

(defconst tandem-markdown--fence "^[ \t]*\\(`\\{3,\\}\\)[ \t]*\\([^` \t\n]*\\)[^`\n]*$"
  "An opening fence: three or more backticks, then perhaps a language.")

(defconst tandem-markdown--inline "\\(`\\)\\([^`\n]+\\)\\(`\\)"
  "Inline code: text between single backticks on one line.")

;;;; Colouring a block

(defun tandem-markdown--major-mode-p (mode)
  "Return non-nil if MODE is a major mode that is safe to call.
The language after ``` comes from text Claude wrote, which may come from
a file Claude read: a name like \"server\" must not toggle `server-mode',
nor any other minor mode or command that ends in -mode."
  (and (symbolp mode)
       (fboundp mode)
       (not (memq mode minor-mode-list))
       (not (memq mode global-minor-modes))
       (or (get mode 'derived-mode-parent)
           (rassq mode auto-mode-alist)
           (rassq mode interpreter-mode-alist)
           (memq mode '(fundamental-mode text-mode prog-mode)))))

(defun tandem-markdown--mode (language)
  "Return the major mode for LANGUAGE, or nil."
  (let* ((language (downcase (or language "")))
         (listed (cdr (assoc language tandem-markdown-modes)))
         (guess (and (not (string-empty-p language))
                     (string-match-p "\\`[a-z0-9+#-]+\\'" language)
                     (intern (concat language "-mode"))))
         (ts (and guess (intern (concat language "-ts-mode")))))
    (cond
     ;; Yours, from `tandem-markdown-modes': trusted as they are.
     ((and listed (fboundp listed)) listed)
     ((tandem-markdown--major-mode-p guess) guess)
     ((and ts (tandem-markdown--major-mode-p ts) (fboundp 'treesit-language-available-p)
           (treesit-language-available-p (intern language)))
      ts))))

(defun tandem-markdown--fontify (code mode)
  "Return CODE coloured by MODE, or nil if that fails.
The colouring happens in a hidden buffer whose mode hooks never run."
  (condition-case nil
      (with-current-buffer (get-buffer-create (format " *tandem fontify: %s*" mode))
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert code)
          (unless (eq major-mode mode)
            (delay-mode-hooks (funcall mode)))
          (font-lock-ensure)
          (buffer-string)))
    (error nil)))

(defun tandem-markdown--paint (beg code)
  "Copy the faces of CODE onto the buffer text of the same length at BEG."
  (let ((pos 0))
    (while (< pos (length code))
      (let ((next (next-single-property-change pos 'face code (length code)))
            (face (get-text-property pos 'face code)))
        (when face
          (put-text-property (+ beg pos) (+ beg next) 'face face)
          (put-text-property (+ beg pos) (+ beg next) 'font-lock-face face))
        (setq pos next)))))

(defun tandem-markdown--block (open-beg code-beg code-end close-end language)
  "Render the code block from OPEN-BEG to CLOSE-END.
Its code runs from CODE-BEG to CODE-END; LANGUAGE names its language."
  (let ((dim (lambda (from to)
               (when (< from to)
                 (put-text-property from to 'face 'tandem-markdown-fence)
                 (put-text-property from to 'font-lock-face 'tandem-markdown-fence)))))
    (funcall dim open-beg code-beg)
    (funcall dim code-end close-end)
    (when (< code-beg code-end)
      (when-let* ((mode (tandem-markdown--mode language))
                  (coloured (tandem-markdown--fontify
                             (buffer-substring-no-properties code-beg code-end) mode)))
        (tandem-markdown--paint code-beg coloured))
      (add-face-text-property code-beg code-end 'tandem-markdown-block t)
      (let ((pos code-beg))
        ;; font-lock-face too, for buffers that refontify.
        (while (< pos code-end)
          (let ((next (next-single-property-change pos 'face nil code-end)))
            (put-text-property pos next 'font-lock-face (get-text-property pos 'face))
            (setq pos next)))))))

;;;; Inline code

(defvar tandem-markdown--show-ticks nil
  "Non-nil to dim the backticks of inline code instead of hiding them.
Text being typed shows them, so the cursor never jumps over hidden text.")

(defun tandem-markdown--inline (beg end)
  "Render `inline code' from BEG to END."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward tandem-markdown--inline end t)
      (let ((code-beg (match-beginning 2)) (code-end (match-end 2)))
        (put-text-property code-beg code-end 'face 'tandem-markdown-code)
        (put-text-property code-beg code-end 'font-lock-face 'tandem-markdown-code)
        (dolist (tick (list (cons (match-beginning 1) (match-end 1))
                            (cons (match-beginning 3) (match-end 3))))
          (if tandem-markdown--show-ticks
              (progn (put-text-property (car tick) (cdr tick) 'face 'tandem-markdown-fence)
                     (put-text-property (car tick) (cdr tick) 'font-lock-face 'tandem-markdown-fence))
            (put-text-property (car tick) (cdr tick) 'invisible t)))))))

;;;; Rendering

(defun tandem-markdown-render (beg end final)
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
        (if (re-search-forward tandem-markdown--fence end t)
            (let* ((open-beg (match-beginning 0))
                   (ticks (match-string 1))
                   (language (match-string 2))
                   (code-beg (min end (1+ (match-end 0))))
                   (close (save-excursion
                            (goto-char code-beg)
                            (and (re-search-forward (concat "^[ \t]*" (regexp-quote ticks) "`*[ \t]*$") end t)
                                 (cons (match-beginning 0) (match-end 0))))))
              (tandem-markdown--inline pos open-beg)
              (cond
               (close
                (let ((close-end (min end (1+ (cdr close)))))
                  (tandem-markdown--block open-beg code-beg (car close) close-end language)
                  (setq pos close-end)))
               (final
                (tandem-markdown--block open-beg code-beg end end language)
                (setq pos end done t))
               (t
                ;; Still streaming: wait for its closing fence.
                (setq pos open-beg done t))))
          ;; No more blocks: inline code on whole lines, or all of it at the end.
          (let ((stop (if final end
                        (save-excursion (goto-char end)
                                        (if (bolp) end (max pos (line-beginning-position)))))))
            (tandem-markdown--inline pos stop)
            (setq pos stop done t)))))
    pos))

(defun tandem-markdown-render-draft (beg end)
  "Render the text being typed from BEG to END afresh.
Earlier rendering there is removed first; backticks stay visible."
  (let ((inhibit-read-only t)
        (buffer-undo-list t)
        (inhibit-modification-hooks t))
    (remove-list-of-text-properties beg end '(face font-lock-face invisible)))
  (let ((tandem-markdown--show-ticks t))
    (tandem-markdown-render beg end t)))

;;;; Into Org

(defun tandem-markdown--org-inline (line)
  "Return LINE with Markdown's inline code, bold and links in Org syntax."
  (let ((case-fold-search nil))
    (thread-last
      line
      (replace-regexp-in-string "`\\([^`\n]+\\)`" "~\\1~")
      (replace-regexp-in-string "\\*\\*\\([^*\n]+\\)\\*\\*" "*\\1*")
      ;; Only links to the web, files and mail: an elisp: or shell: link
      ;; from Claude's text must not become one you can click in Org.
      (replace-regexp-in-string "\\[\\([^]\n]+\\)\\](\\(\\(?:https?\\|file\\|mailto\\):[^)\n]+\\))" "[[\\2][\\1]]"))))

(defun tandem-markdown-to-org (text &optional level)
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
                      (tandem-markdown--org-inline (match-string 2 line)))
              lines))
       ((string-match "\\`\\([ \t]*\\)[*+][ \t]+\\(.*\\)" line)
        (push (concat (match-string 1 line) "- " (tandem-markdown--org-inline (match-string 2 line))) lines))
       ((string-match-p "\\`\\*" line)
        (push (concat " " (tandem-markdown--org-inline line)) lines))
       ;; #+INCLUDE, #+SETUPFILE, #+BIND and the like act on the Org file;
       ;; from Claude they are text, shown as it is.
       ((string-match-p "\\`[ \t]*#\\+" line)
        (push (concat ": " line) lines))
       (t (push (tandem-markdown--org-inline line) lines))))
    (when in-code (push "#+end_src" lines))
    (string-join (nreverse lines) "\n")))

(provide 'tandem-markdown)
;;; tandem-markdown.el ends here
