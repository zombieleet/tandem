;;; claude-pair-authorship-tests.el --- Tests for the colour of Claude's lines  -*- lexical-binding: t; -*-

;;; Commentary:

;; Claude's text comes from applying a proposed edit; then ordinary edits
;; of yours, undo, yanking and formatters act on it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--five "one\ntwo\nthree\nfour\nfive\n"
  "Five lines.")

(defmacro claude-pair-test-with-claude-lines (&rest body)
  "Run BODY in a buffer where Claude replaced lines two and three.
The buffer reads one / TWO / THREE / four / five."
  (declare (indent 0) (debug t))
  `(claude-pair-test-with-file claude-pair-test--five
     (claude-pair-test--propose "e1" :kind "edit" :filePath file
                                :oldString "two\nthree\n" :newString "TWO\nTHREE\n")
     (with-current-buffer (find-buffer-visiting file)
       (buffer-enable-undo)
       (setq buffer-undo-list nil)
       (claude-pair-review-apply "e1")
       (undo-boundary)
       ,@body)))

(defun claude-pair-test--claude-lines ()
  "Return the numbers of the lines that are Claude's."
  (let (lines)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (claude-pair-authorship-at (point))
          (push (line-number-at-pos) lines))
        (forward-line 1)))
    (nreverse lines)))

(defun claude-pair-test--goto-line (n)
  "Move to the start of line N."
  (goto-char (point-min))
  (forward-line (1- n)))

(ert-deftest claude-pair-authorship-applied-text-is-claudes ()
  (claude-pair-test-with-claude-lines
    (should (equal (buffer-string) "one\nTWO\nTHREE\nfour\nfive\n"))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))
    (let ((record (claude-pair-authorship-record-of (claude-pair-authorship-at (point-min)))))
      (ignore record))
    (let ((record (claude-pair-authorship-record-of
                   (progn (claude-pair-test--goto-line 2) (claude-pair-authorship-at (point))))))
      (should (equal (plist-get record :request) "e1"))
      (should (equal (plist-get record :session) "s1"))
      (should (equal (plist-get record :file) file))
      (should (numberp (plist-get record :time))))
    ;; Saved, and the colour is not in the file.
    (should (equal (claude-pair-test--disk file) "one\nTWO\nTHREE\nfour\nfive\n"))))

(ert-deftest claude-pair-authorship-your-edit-takes-the-colour-off-its-line ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--goto-line 2)
    (end-of-line)
    (insert "!")
    (should (equal (claude-pair-test--claude-lines) '(3)))
    ;; Typing on a line of yours next to Claude's leaves Claude's alone.
    (claude-pair-test--goto-line 4)
    (insert "x")
    (should (equal (claude-pair-test--claude-lines) '(3)))))

(ert-deftest claude-pair-authorship-a-new-line-below-is-not-an-edit ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--goto-line 3)
    (end-of-line)
    (newline)
    (insert "mine")
    (should (equal (buffer-string) "one\nTWO\nTHREE\nmine\nfour\nfive\n"))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))))

(ert-deftest claude-pair-authorship-splitting-a-line-is-an-edit ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--goto-line 2)
    (forward-char 1)
    (newline)
    (should (equal (claude-pair-test--claude-lines) '(4)))))

(ert-deftest claude-pair-authorship-deleting-whole-lines-around-it ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--goto-line 4)
    (delete-region (point) (progn (forward-line 1) (point)))
    (claude-pair-test--goto-line 1)
    (delete-region (point) (progn (forward-line 1) (point)))
    (should (equal (buffer-string) "TWO\nTHREE\nfive\n"))
    (should (equal (claude-pair-test--claude-lines) '(1 2)))))

(ert-deftest claude-pair-authorship-pasted-text-is-yours ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--goto-line 2)
    (kill-ring-save (point) (line-end-position))
    (goto-char (point-max))
    (yank)
    (should (string-suffix-p "five\nTWO" (buffer-string)))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))))

(ert-deftest claude-pair-authorship-undo-brings-the-colour-back ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--goto-line 2)
    (end-of-line)
    (insert "!")
    (undo-boundary)
    (should (equal (claude-pair-test--claude-lines) '(3)))
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) "one\nTWO\nTHREE\nfour\nfive\n"))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))))

(ert-deftest claude-pair-authorship-undoing-the-edit-takes-the-colour-away ()
  (claude-pair-test-with-claude-lines
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) claude-pair-test--five))
    (should-not (claude-pair-test--claude-lines))
    ;; Redo (an undo after breaking the chain): the text comes back with
    ;; its colour.
    (undo-boundary)
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) "one\nTWO\nTHREE\nfour\nfive\n"))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))))

(ert-deftest claude-pair-authorship-whitespace-only-changes-keep-the-colour ()
  (claude-pair-test-with-claude-lines
    (indent-rigidly (point-min) (point-max) 4)
    (should (equal (buffer-string) "    one\n    TWO\n    THREE\n    four\n    five\n"))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))
    ;; A formatter that deletes everything and inserts its output, in one
    ;; command.
    (let ((text (replace-regexp-in-string "^    " "\t" (buffer-string))))
      (erase-buffer)
      (insert text))
    (should (equal (claude-pair-test--claude-lines) '(2 3)))
    ;; A real change is still yours.
    (claude-pair-test--goto-line 3)
    (end-of-line)
    (insert "S")
    (should (equal (claude-pair-test--claude-lines) '(2)))
    ;; A later command does not inherit the memory of removed lines.
    (claude-pair-authorship--forget)
    (erase-buffer)
    (claude-pair-authorship--forget)
    (insert "one\nTWO\nTHREE\n")
    (should-not (claude-pair-test--claude-lines))))

(ert-deftest claude-pair-authorship-without-ignoring-whitespace ()
  (claude-pair-test-with-claude-lines
    (let ((claude-pair-attribution-ignore-whitespace nil))
      (indent-rigidly (point-min) (point-max) 4)
      (should-not (claude-pair-test--claude-lines)))))

(ert-deftest claude-pair-authorship-a-proposal-shown-nearby-is-not-an-edit ()
  (claude-pair-test-with-claude-lines
    (claude-pair-test--propose "e2" :kind "edit" :filePath file :oldString "four\n" :newString "FOUR\n")
    (should (equal (claude-pair-test--claude-lines) '(2 3)))
    (claude-pair-review-reject "e2" "")
    (should (equal (claude-pair-test--claude-lines) '(2 3)))))

(ert-deftest claude-pair-authorship-drawing ()
  (claude-pair-test-with-claude-lines
    (claude-pair-authorship-draw)
    (let ((runs (seq-filter (lambda (ov) (overlay-get ov 'claude-pair-author-run))
                            (overlays-in (point-min) (point-max)))))
      (should (= (length runs) 1))
      (should (eq (overlay-get (car runs) 'face) 'claude-pair-author))
      (should (equal (buffer-substring-no-properties (overlay-start (car runs)) (overlay-end (car runs)))
                     "TWO\nTHREE\n")))
    ;; Your edit on line 2 leaves a run of one line.
    (claude-pair-test--goto-line 2)
    (end-of-line)
    (insert "!")
    (claude-pair-test--goto-line 3)
    (claude-pair-authorship-draw)
    (should (= (length (seq-filter (lambda (ov) (overlay-get ov 'claude-pair-author-run))
                                   (overlays-in (point-min) (point-max))))
               1))))

(ert-deftest claude-pair-authorship-the-tint-follows-the-theme ()
  (should (equal (claude-pair-authorship--blend "#ffffff" "#000000" 0.5) "#808080"))
  (should (equal (claude-pair-authorship--blend "#d97757" "#ffffff" 0.0) "#ffffff"))
  (should-not (claude-pair-authorship--blend "no-such-colour" "#ffffff" 0.5))
  (let ((claude-pair-author-color "#ff0000")
        (claude-pair-author-tint 0.5))
    (cl-letf (((symbol-function 'face-background)
               (lambda (face &rest _) (if (eq face 'default) "#ffffff" "#cccccc"))))
      (claude-pair-authorship-refresh-face)
      (should (equal (face-attribute 'claude-pair-author :background) "#ff8080"))
      ;; The fringe mark is in the colour itself.
      (should (equal (face-attribute 'claude-pair-author-fringe :foreground) "#ff0000")))
    ;; A daemon with no frame yet knows no background: keep the last tint.
    (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "unspecified-bg")))
      (claude-pair-authorship-refresh-face)
      (should (equal (face-attribute 'claude-pair-author :background) "#ff8080"))))
  (should (memq #'claude-pair-authorship-refresh-face after-make-frame-functions))
  (claude-pair-authorship-refresh-face))

(provide 'claude-pair-authorship-tests)
;;; claude-pair-authorship-tests.el ends here
