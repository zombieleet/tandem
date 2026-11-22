;;; tandem-authorship-tests.el --- Tests for the colour of Claude's lines  -*- lexical-binding: t; -*-

;;; Commentary:

;; Claude's text comes from applying a proposed edit; then ordinary edits
;; of yours, undo, yanking and formatters act on it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defconst tandem-test--five "one\ntwo\nthree\nfour\nfive\n"
  "Five lines.")

(defmacro tandem-test-with-claude-lines (&rest body)
  "Run BODY in a buffer where Claude replaced lines two and three.
The buffer reads one / TWO / THREE / four / five."
  (declare (indent 0) (debug t))
  `(tandem-test-with-file tandem-test--five
     (tandem-test--propose "e1" :kind "edit" :filePath file
                                :oldString "two\nthree\n" :newString "TWO\nTHREE\n")
     (with-current-buffer (find-buffer-visiting file)
       (buffer-enable-undo)
       (setq buffer-undo-list nil)
       (tandem-review-apply "e1")
       (undo-boundary)
       ,@body)))

(defun tandem-test--claude-lines ()
  "Return the numbers of the lines that are Claude's."
  (let (lines)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (tandem-authorship-at (point))
          (push (line-number-at-pos) lines))
        (forward-line 1)))
    (nreverse lines)))

(defun tandem-test--goto-line (n)
  "Move to the start of line N."
  (goto-char (point-min))
  (forward-line (1- n)))

(ert-deftest tandem-authorship-applied-text-is-claudes ()
  (tandem-test-with-claude-lines
    (should (equal (buffer-string) "one\nTWO\nTHREE\nfour\nfive\n"))
    (should (equal (tandem-test--claude-lines) '(2 3)))
    (let ((record (tandem-authorship-record-of (tandem-authorship-at (point-min)))))
      (ignore record))
    (let ((record (tandem-authorship-record-of
                   (progn (tandem-test--goto-line 2) (tandem-authorship-at (point))))))
      (should (equal (plist-get record :request) "e1"))
      (should (equal (plist-get record :session) "s1"))
      (should (equal (plist-get record :file) file))
      (should (numberp (plist-get record :time))))
    ;; Saved, and the colour is not in the file.
    (should (equal (tandem-test--disk file) "one\nTWO\nTHREE\nfour\nfive\n"))))

(ert-deftest tandem-authorship-your-edit-takes-the-colour-off-its-line ()
  (tandem-test-with-claude-lines
    (tandem-test--goto-line 2)
    (end-of-line)
    (insert "!")
    (should (equal (tandem-test--claude-lines) '(3)))
    ;; Typing on a line of yours next to Claude's leaves Claude's alone.
    (tandem-test--goto-line 4)
    (insert "x")
    (should (equal (tandem-test--claude-lines) '(3)))))

(ert-deftest tandem-authorship-a-new-line-below-is-not-an-edit ()
  (tandem-test-with-claude-lines
    (tandem-test--goto-line 3)
    (end-of-line)
    (newline)
    (insert "mine")
    (should (equal (buffer-string) "one\nTWO\nTHREE\nmine\nfour\nfive\n"))
    (should (equal (tandem-test--claude-lines) '(2 3)))))

(ert-deftest tandem-authorship-splitting-a-line-is-an-edit ()
  (tandem-test-with-claude-lines
    (tandem-test--goto-line 2)
    (forward-char 1)
    (newline)
    (should (equal (tandem-test--claude-lines) '(4)))))

(ert-deftest tandem-authorship-deleting-whole-lines-around-it ()
  (tandem-test-with-claude-lines
    (tandem-test--goto-line 4)
    (delete-region (point) (progn (forward-line 1) (point)))
    (tandem-test--goto-line 1)
    (delete-region (point) (progn (forward-line 1) (point)))
    (should (equal (buffer-string) "TWO\nTHREE\nfive\n"))
    (should (equal (tandem-test--claude-lines) '(1 2)))))

(ert-deftest tandem-authorship-pasted-text-is-yours ()
  (tandem-test-with-claude-lines
    (tandem-test--goto-line 2)
    (kill-ring-save (point) (line-end-position))
    (goto-char (point-max))
    (yank)
    (should (string-suffix-p "five\nTWO" (buffer-string)))
    (should (equal (tandem-test--claude-lines) '(2 3)))))

(ert-deftest tandem-authorship-undo-brings-the-colour-back ()
  (tandem-test-with-claude-lines
    (tandem-test--goto-line 2)
    (end-of-line)
    (insert "!")
    (undo-boundary)
    (should (equal (tandem-test--claude-lines) '(3)))
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) "one\nTWO\nTHREE\nfour\nfive\n"))
    (should (equal (tandem-test--claude-lines) '(2 3)))))

(ert-deftest tandem-authorship-undoing-the-edit-takes-the-colour-away ()
  (tandem-test-with-claude-lines
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) tandem-test--five))
    (should-not (tandem-test--claude-lines))
    ;; Redo (an undo after breaking the chain): the text comes back with
    ;; its colour.
    (undo-boundary)
    (let ((last-command nil)) (undo))
    (should (equal (buffer-string) "one\nTWO\nTHREE\nfour\nfive\n"))
    (should (equal (tandem-test--claude-lines) '(2 3)))))

(ert-deftest tandem-authorship-whitespace-only-changes-keep-the-colour ()
  (tandem-test-with-claude-lines
    (indent-rigidly (point-min) (point-max) 4)
    (should (equal (buffer-string) "    one\n    TWO\n    THREE\n    four\n    five\n"))
    (should (equal (tandem-test--claude-lines) '(2 3)))
    ;; A formatter that deletes everything and inserts its output, in one
    ;; command.
    (let ((text (replace-regexp-in-string "^    " "\t" (buffer-string))))
      (erase-buffer)
      (insert text))
    (should (equal (tandem-test--claude-lines) '(2 3)))
    ;; A real change is still yours.
    (tandem-test--goto-line 3)
    (end-of-line)
    (insert "S")
    (should (equal (tandem-test--claude-lines) '(2)))
    ;; A later command does not inherit the memory of removed lines.
    (tandem-authorship--forget)
    (erase-buffer)
    (tandem-authorship--forget)
    (insert "one\nTWO\nTHREE\n")
    (should-not (tandem-test--claude-lines))))

(ert-deftest tandem-authorship-without-ignoring-whitespace ()
  (tandem-test-with-claude-lines
    (let ((tandem-attribution-ignore-whitespace nil))
      (indent-rigidly (point-min) (point-max) 4)
      (should-not (tandem-test--claude-lines)))))

(ert-deftest tandem-authorship-a-proposal-shown-nearby-is-not-an-edit ()
  (tandem-test-with-claude-lines
    (tandem-test--propose "e2" :kind "edit" :filePath file :oldString "four\n" :newString "FOUR\n")
    (should (equal (tandem-test--claude-lines) '(2 3)))
    (tandem-review-reject "e2" "")
    (should (equal (tandem-test--claude-lines) '(2 3)))))

(ert-deftest tandem-authorship-drawing ()
  (tandem-test-with-claude-lines
    (tandem-authorship-draw)
    (let ((runs (seq-filter (lambda (ov) (overlay-get ov 'tandem-author-run))
                            (overlays-in (point-min) (point-max)))))
      (should (= (length runs) 1))
      (should (eq (overlay-get (car runs) 'face) 'tandem-author))
      (should (equal (buffer-substring-no-properties (overlay-start (car runs)) (overlay-end (car runs)))
                     "TWO\nTHREE\n")))
    ;; Your edit on line 2 leaves a run of one line.
    (tandem-test--goto-line 2)
    (end-of-line)
    (insert "!")
    (tandem-test--goto-line 3)
    (tandem-authorship-draw)
    (should (= (length (seq-filter (lambda (ov) (overlay-get ov 'tandem-author-run))
                                   (overlays-in (point-min) (point-max))))
               1))))

(ert-deftest tandem-authorship-the-tint-follows-the-theme ()
  (should (equal (tandem-authorship--blend "#ffffff" "#000000" 0.5) "#808080"))
  (should (equal (tandem-authorship--blend "#d97757" "#ffffff" 0.0) "#ffffff"))
  (should-not (tandem-authorship--blend "no-such-colour" "#ffffff" 0.5))
  (let ((tandem-author-color "#ff0000")
        (tandem-author-tint 0.5))
    (cl-letf (((symbol-function 'face-background)
               (lambda (face &rest _) (if (eq face 'default) "#ffffff" "#cccccc"))))
      (tandem-authorship-refresh-face)
      (should (equal (face-attribute 'tandem-author :background) "#ff8080"))
      ;; The fringe mark is in the colour itself.
      (should (equal (face-attribute 'tandem-author-fringe :foreground) "#ff0000")))
    ;; A daemon with no frame yet knows no background: keep the last tint.
    (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "unspecified-bg")))
      (tandem-authorship-refresh-face)
      (should (equal (face-attribute 'tandem-author :background) "#ff8080"))))
  (should (memq #'tandem-authorship-refresh-face after-make-frame-functions))
  (tandem-authorship-refresh-face))

;;;; Remembering Claude's lines

(defmacro tandem-test-with-store (&rest body)
  "Run BODY with a private attribution store."
  (declare (indent 0) (debug t))
  `(let ((tandem-attribution-directory
          (expand-file-name "attribution" (tandem-test--private-dir)))
         (tandem-attribution-persist t))
     ,@body))

(defun tandem-test--reopen (file)
  "Kill FILE's buffer and visit FILE again; return the new buffer."
  (let ((buffer (find-buffer-visiting file)))
    (with-current-buffer buffer (set-buffer-modified-p nil))
    (kill-buffer buffer))
  (find-file-noselect file))

(ert-deftest tandem-authorship-colours-survive-closing-the-file ()
  (tandem-test-with-store
    (tandem-test-with-claude-lines
      ;; Applying saved the file, and with it which lines are Claude's.
      (let ((store (tandem-authorship--store file)))
        (should (file-exists-p store))
        (should (= (logand (file-modes store) #o077) 0))
        (should (= (logand (file-modes tandem-attribution-directory) #o077) 0)))
      (with-current-buffer (tandem-test--reopen file)
        (should (equal (tandem-test--claude-lines) '(2 3)))
        (should (string-match-p "Claude wrote this line"
                                (progn (tandem-test--goto-line 2)
                                       (tandem-authorship-describe (tandem-authorship-at (point))))))
        ;; Watched again: your edits still take the colour off.
        (tandem-test--goto-line 3)
        (end-of-line)
        (insert "!")
        (should (equal (tandem-test--claude-lines) '(2)))))))

(ert-deftest tandem-authorship-lines-moved-outside-emacs-keep-their-colour ()
  (tandem-test-with-store
    (tandem-test-with-claude-lines
      (kill-buffer (current-buffer))
      ;; Outside Emacs: two lines added at the top, line THREE changed.
      (with-temp-file file
        (insert "new 1\nnew 2\none\nTWO\nTHREE changed\nfour\nfive\n"))
      (with-current-buffer (find-file-noselect file)
        (should (equal (tandem-test--claude-lines) '(4)))))))

(ert-deftest tandem-authorship-no-claude-lines-no-store ()
  (tandem-test-with-store
    (tandem-test-with-claude-lines
      (let ((store (tandem-authorship--store file)))
        (should (file-exists-p store))
        (tandem-test--goto-line 2)
        (insert "x")
        (tandem-test--goto-line 3)
        (insert "x")
        (let ((save-silently t)) (save-buffer))
        (should-not (file-exists-p store))))))

(ert-deftest tandem-authorship-a-proposal-shown-while-saving-is-not-written-down ()
  (tandem-test-with-store
    (tandem-test-with-claude-lines
      (tandem-test--propose "e2" :kind "edit" :filePath file :oldString "one\n" :newString "ONE\nUNO\n")
      ;; An edit of yours on a line of yours; the proposal's lines shift
      ;; line numbers while it shows.
      (goto-char (point-min))
      (search-forward "four")
      (insert "x")
      (let ((save-silently t)) (save-buffer))
      (tandem-review-reject "e2" "")
      (with-current-buffer (tandem-test--reopen file)
        (should (equal (tandem-test--claude-lines) '(2 3)))))))

(ert-deftest tandem-authorship-not-remembered-when-turned-off ()
  (tandem-test-with-store
    (let ((tandem-attribution-persist nil))
      (tandem-test-with-claude-lines
        (should-not (file-exists-p (tandem-authorship--store file)))))))

(ert-deftest tandem-authorship-blame ()
  (tandem-test-with-claude-lines
    (let ((id (progn (tandem-test--goto-line 2) (tandem-authorship-at (point)))))
      (plist-put (tandem-authorship-record-of id) :model "claude-test")
      (plist-put (tandem-authorship-record-of id) :turn 3)
      (plist-put (tandem-authorship-record-of id) :prompt "shout")
      (let ((text (tandem-authorship-describe id)))
        (should (string-match-p "^Claude (claude-test) wrote this line, in chat s1, turn 3, " text))
        (should (string-match-p "answering: \"shout\"\\.$" text))))
    (should (string-match-p "it is yours" (tandem-authorship-describe nil)))
    (should (equal (mapcar (lambda (r) (list (nth 0 r) (nth 1 r))) (tandem-authorship--runs))
                   '((2 3))))
    (tandem-blame t)
    (with-current-buffer (format "*tandem blame: %s*" (buffer-name))
      (should (string-match-p "lines 2-3  Claude" (buffer-string)))
      (kill-buffer))))

(ert-deftest tandem-authorship-line-map ()
  (let ((table (tandem-authorship--map-lines ["a" "b" "c" "d"] ["x" "a" "b" "C" "d"])))
    (should (equal (gethash 0 table) 1))
    (should (equal (gethash 1 table) 2))
    (should-not (gethash 2 table))
    (should (equal (gethash 3 table) 4))))

(ert-deftest tandem-authorship-moves-the-store-of-the-old-name ()
  (let* ((cache (tandem-test--private-dir))
         (process-environment (cons (concat "XDG_CACHE_HOME=" cache) process-environment))
         (old (expand-file-name "claude-pair/attribution" cache)))
    (unwind-protect
        (progn
          (make-directory old t)
          (with-temp-file (expand-file-name "x.json" old) (insert "{}"))
          ;; The new store exists: nothing moves.
          (let ((tandem-attribution-directory (expand-file-name "tandem/attribution" cache))
                (tandem-authorship--moved nil))
            (make-directory tandem-attribution-directory t)
            (tandem-authorship--store "/tmp/a")
            (should (file-exists-p (expand-file-name "x.json" old)))
            (delete-directory tandem-attribution-directory t))
          ;; It does not: the old one becomes it, once.
          (let ((tandem-attribution-directory (expand-file-name "tandem/attribution" cache))
                (tandem-authorship--moved nil))
            (tandem-authorship--store "/tmp/a")
            (should (file-exists-p (expand-file-name "x.json" tandem-attribution-directory)))
            (should-not (file-exists-p old))))
      (delete-directory cache t))))

(provide 'tandem-authorship-tests)
;;; tandem-authorship-tests.el ends here
