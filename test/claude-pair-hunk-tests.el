;;; claude-pair-hunk-tests.el --- Tests for reviewing Claude's edits hunk by hunk  -*- lexical-binding: t; -*-

;;; Commentary:

;; The diff that splits an edit into hunks, deciding hunks one by one, and
;; what Claude and the chat hear about it.  The review tests' helpers
;; (`claude-pair-test-with-file' and friends, in the shared helpers) feed
;; proposals straight in.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

;;;; The diff

(defun claude-pair-test--apply-ranges (a b ranges)
  "Rebuild B from A and the changed RANGES, to check the diff."
  (let ((out nil) (i 0))
    (dolist (r ranges)
      (while (< i (nth 0 r)) (push (aref a i) out) (setq i (1+ i)))
      (dolist (line (append (seq-subseq b (nth 2 r) (nth 3 r)) nil)) (push line out))
      (setq i (nth 1 r)))
    (while (< i (length a)) (push (aref a i) out) (setq i (1+ i)))
    (vconcat (nreverse out))))

(ert-deftest claude-pair-hunk-the-diff-rebuilds-the-new-text ()
  (let ((state (random "claude-pair")))
    (ignore state)
    (dotimes (_ 300)
      (let* ((a (vconcat (cl-loop repeat (random 25) collect (format "%c\n" (+ ?a (random 4))))))
             (b (vconcat (cl-loop repeat (random 25) collect (format "%c\n" (+ ?a (random 4))))))
             (ranges (claude-pair-review--diff a b)))
        (should (equal (claude-pair-test--apply-ranges a b ranges) b))
        ;; Ranges are in order and never empty on both sides.
        (let ((last -1))
          (dolist (r ranges)
            (should (> (nth 0 r) last))
            (should (or (< (nth 0 r) (nth 1 r)) (< (nth 2 r) (nth 3 r))))
            (setq last (nth 1 r))))))))

(ert-deftest claude-pair-hunk-the-diff-finds-separate-changes ()
  (let ((a ["1\n" "2\n" "3\n" "4\n" "5\n" "6\n" "7\n" "8\n"])
        (b ["1\n" "TWO\n" "3\n" "4\n" "5\n" "6\n" "7\n" "8\n" "9\n"]))
    (should (equal (claude-pair-review--diff a b) '((1 2 1 2) (8 8 8 9))))))

(ert-deftest claude-pair-hunk-a-big-rewrite-is-one-hunk ()
  (let* ((claude-pair-review--diff-limit 10)
         (a (vconcat (cl-loop for i below 50 collect (format "a%d\n" i))))
         (b (vconcat (cl-loop for i below 50 collect (format "b%d\n" i)))))
    (should (equal (claude-pair-review--diff a b) '((0 50 0 50))))))

(ert-deftest claude-pair-hunk-close-changes-merge ()
  (let ((claude-pair-review-merge-gap 2))
    (should (equal (length (claude-pair-review--hunk-specs "1\n2\n3\n4\n5\n6\n7\n"
                                                           "1\nX\n3\n4\nY\n6\n7\n"))
                   1))
    (should (equal (length (claude-pair-review--hunk-specs "1\n2\n3\n4\n5\n6\n7\n"
                                                           "X\n2\n3\n4\n5\n6\nY\n"))
                   2))))

(ert-deftest claude-pair-hunk-specs-keep-partial-lines ()
  (should (equal (claude-pair-review--hunk-specs "x" "y") '((0 1 "y"))))
  (should (equal (claude-pair-review--hunk-specs "a\nb" "a\nc") '((2 3 "c")))))

;;;; Deciding hunk by hunk

(defconst claude-pair-test--ten
  (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 10) "")
  "Ten numbered lines.")

(defun claude-pair-test--two-hunks (file)
  "Propose edit e1 to FILE: change lines 2 and 9 of `claude-pair-test--ten'."
  (claude-pair-test--propose
   "e1" :kind "edit" :filePath file
   :oldString claude-pair-test--ten
   :newString (replace-regexp-in-string
               "line 9\n" "NINE\nNINE AND A HALF\n"
               (replace-regexp-in-string "line 2\n" "TWO\n" claude-pair-test--ten))))

(defun claude-pair-test--hunk (n)
  "Return hunk N of edit e1."
  (nth (1- n) (plist-get (gethash "e1" claude-pair-review--proposals) :hunks)))

(defun claude-pair-test--goto-hunk (n)
  "Put point on the new text of hunk N of edit e1."
  (goto-char (nth 0 (claude-pair-review--hunk-entry (claude-pair-test--hunk n)))))

(ert-deftest claude-pair-hunk-an-edit-shows-as-hunks ()
  (claude-pair-test-with-file claude-pair-test--ten
    (claude-pair-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (claude-pair-review-hunk-count "e1") '(2 . 2)))
      (let ((banners (delq nil (mapcar (lambda (ov) (overlay-get ov 'before-string))
                                       (overlays-in (point-min) (point-max))))))
        (should (seq-some (lambda (b) (string-match-p "hunk 1 of 2" b)) banners))
        (should (seq-some (lambda (b) (string-match-p "hunk 2 of 2" b)) banners)))
      (should (equal (buffer-string)
                     (concat "line 1\nline 2\nTWO\nline 3\nline 4\nline 5\nline 6\nline 7\n"
                             "line 8\nline 9\nNINE\nNINE AND A HALF\nline 10\n")))
      (should-not (buffer-modified-p))
      ;; The lines between hunks stay yours to edit.
      (goto-char (point-min))
      (search-forward "line 5")
      (insert "!")
      (should (string-match-p "line 5!" (buffer-string)))
      ;; Hunk text is locked; typing just before the new text is allowed.
      (claude-pair-test--goto-hunk 1)
      (forward-char 1)
      (should-error (insert "z") :type 'text-read-only))))

(ert-deftest claude-pair-hunk-mixed-decisions ()
  (claude-pair-test-with-file claude-pair-test--ten
    (claude-pair-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (claude-pair-test--goto-hunk 1)
      (claude-pair-review-apply-hunk)
      ;; Not finished yet: Claude hears nothing until the last hunk.
      (should-not claude-pair-test--answers)
      (should (equal (claude-pair-review-hunk-count "e1") '(1 . 2)))
      ;; Saved at once: the buffer had no changes of yours.
      (should (string-match-p "TWO" (claude-pair-test--disk file)))
      (should (string-match-p "line 9" (claude-pair-test--disk file)))
      (claude-pair-test--goto-hunk 2)
      (claude-pair-review-reject-hunk nil "keep nine")
      (should (equal (buffer-string)
                     (concat "line 1\nTWO\nline 3\nline 4\nline 5\nline 6\nline 7\n"
                             "line 8\nline 9\nline 10\n")))
      (should (equal (claude-pair-test--disk file) (buffer-string)))
      (should-not (claude-pair-review-pending-p "e1"))
      (let ((answer (car claude-pair-test--answers)))
        (should (equal (plist-get answer :outcome) "partial"))
        (should (eq (plist-get answer :saved) t))
        (should (equal (append (plist-get answer :hunks) nil)
                       '((:index 1 :line 2 :oldLines 1 :newLines 1 :decision "applied" :note "" :saved t)
                         (:index 2 :line 9 :oldLines 1 :newLines 2 :decision "rejected" :note "keep nine"
                                   :saved :json-false))))))))

(ert-deftest claude-pair-hunk-each-applied-hunk-is-one-undo-step ()
  (claude-pair-test-with-file claude-pair-test--ten
    (let ((claude-pair-review-autosave nil))
      (claude-pair-test--two-hunks file)
      (with-current-buffer (find-buffer-visiting file)
        (buffer-enable-undo)
        (claude-pair-test--goto-hunk 1)
        (claude-pair-review-apply-hunk)
        (undo-boundary)
        (claude-pair-test--goto-hunk 2)
        (claude-pair-review-apply-hunk)
        (undo-boundary)
        (should (string-match-p "TWO .*NINE AND A HALF" (replace-regexp-in-string "\n" " " (buffer-string))))
        (let ((last-command nil)) (undo))
        (should (string-match-p "TWO" (buffer-string)))
        (should (string-match-p "line 9\nline 10" (buffer-string)))
        (should-not (string-match-p "NINE" (buffer-string)))
        (should (equal (plist-get (car claude-pair-test--answers) :outcome) "applied"))
        (should (eq (plist-get (car claude-pair-test--answers) :saved) :json-false))))))

(ert-deftest claude-pair-hunk-c-u-applies-every-hunk-and-saves-once ()
  (claude-pair-test-with-file claude-pair-test--ten
    (claude-pair-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (let ((saves 0))
        (add-hook 'after-save-hook (lambda () (setq saves (1+ saves))) nil t)
        (claude-pair-test--goto-hunk 2)
        (claude-pair-review-apply-hunk '(4))
        (should (= saves 1)))
      (should (equal (claude-pair-test--disk file) (buffer-string)))
      (should (string-match-p "TWO" (buffer-string)))
      (should (string-match-p "NINE AND A HALF" (buffer-string)))
      (should (equal (car claude-pair-test--answers)
                     '(:requestId "e1" :outcome "applied" :message "" :saved t :created :json-false))))))

(ert-deftest claude-pair-hunk-rejecting-every-hunk-is-a-rejection ()
  (claude-pair-test-with-file claude-pair-test--ten
    (claude-pair-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (claude-pair-test--goto-hunk 1)
      (claude-pair-review-reject-hunk nil "no")
      (claude-pair-test--goto-hunk 2)
      (claude-pair-review-reject-hunk nil "no")
      (should (equal (buffer-string) claude-pair-test--ten))
      (should-not (buffer-modified-p))
      (let ((answer (car claude-pair-test--answers)))
        (should (equal (plist-get answer :outcome) "rejected"))
        (should (equal (plist-get answer :message) "no"))))))

(ert-deftest claude-pair-hunk-n-and-p-move-between-hunks ()
  (claude-pair-test-with-file claude-pair-test--ten
    (claude-pair-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (claude-pair-test--goto-hunk 1)
      (should (eq (key-binding "n") #'claude-pair-review-next-hunk))
      (claude-pair-review-next-hunk)
      (should (eq (claude-pair-review--hunk-at-point) (claude-pair-test--hunk 2)))
      (claude-pair-review-previous-hunk)
      (should (eq (claude-pair-review--hunk-at-point) (claude-pair-test--hunk 1)))
      (should-error (claude-pair-review-previous-hunk) :type 'user-error)
      ;; On the editable lines between hunks, n is just n.
      (goto-char (point-min))
      (search-forward "line 5")
      (should-not (eq (key-binding "n") #'claude-pair-review-next-hunk)))))

(ert-deftest claude-pair-hunk-saving-with-a-hunk-waiting ()
  (claude-pair-test-with-file claude-pair-test--ten
    (let ((claude-pair-review-autosave nil))
      (claude-pair-test--two-hunks file)
      (with-current-buffer (find-buffer-visiting file)
        (claude-pair-test--goto-hunk 1)
        (claude-pair-review-apply-hunk)
        (let ((save-silently t)) (save-buffer))
        ;; Your save writes the applied hunk, not the waiting one.
        (should (string-match-p "TWO" (claude-pair-test--disk file)))
        (should-not (string-match-p "NINE" (claude-pair-test--disk file)))
        (should (string-match-p "NINE AND A HALF" (buffer-string)))
        (should (claude-pair-review-pending-p "e1"))))))

(ert-deftest claude-pair-hunk-replace-all-gives-a-hunk-per-place ()
  (claude-pair-test-with-file "a x\nb\nc\nd\ne x\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y" :replaceAll t)
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (claude-pair-review-hunk-count "e1") '(2 . 2)))
      (claude-pair-test--goto-hunk 2)
      (claude-pair-review-apply-hunk)
      (claude-pair-test--goto-hunk 1)
      (claude-pair-review-reject-hunk nil "")
      (should (equal (buffer-string) "a x\nb\nc\nd\ne y\n"))
      (should (equal (plist-get (car claude-pair-test--answers) :outcome) "partial")))))

(ert-deftest claude-pair-hunk-closing-the-buffer-rejects-what-waits ()
  (claude-pair-test-with-file claude-pair-test--ten
    (claude-pair-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (claude-pair-test--goto-hunk 1)
      (claude-pair-review-apply-hunk))
    (kill-buffer (find-buffer-visiting file))
    (let ((hunks (append (plist-get (car claude-pair-test--answers) :hunks) nil)))
      (should (equal (plist-get (car claude-pair-test--answers) :outcome) "partial"))
      (should (equal (plist-get (nth 1 hunks) :note) "The user closed the buffer.")))))

;;;; The chat

(ert-deftest claude-pair-hunk-the-chat-tells-the-mixed-outcome ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed
     '(:kind "edit" :state "pending" :requestId "e9" :editKind "edit" :relPath "a.py" :title "Edit a.py")
     '(:kind "edit" :state "partial" :requestId "e9" :saved t
             :hunks [(:index 1 :line 2 :decision "applied" :note "")
                     (:index 2 :line 9 :decision "rejected" :note "keep nine")]))
    (let ((text (claude-pair-test--transcript)))
      (should (string-match-p "◐ Applied 1 of 2 hunks, saved" text))
      (should (string-match-p "✗ hunk 2 (line 9) rejected: keep nine" text)))))

;;;; For real

(ert-deftest claude-pair-hunk-partial-for-real ()
  (claude-pair-test-with-edit-project
    (with-temp-file (expand-file-name "a.txt" project) (insert claude-pair-test--ten))
    (claude-pair-test--send
     buffer (claude-pair-test--edit-prompt
             (list :file "a.txt" :old claude-pair-test--ten
                   :new (replace-regexp-in-string
                         "line 9\n" "NINE\n"
                         (replace-regexp-in-string "line 2\n" "TWO\n" claude-pair-test--ten)))))
    (let ((id (claude-pair-test--wait-proposal)))
      (should (equal (claude-pair-review-hunk-count id) '(2 . 2)))
      (with-current-buffer (find-buffer-visiting (expand-file-name "a.txt" project))
        (let ((hunks (plist-get (gethash id claude-pair-review--proposals) :hunks)))
          (goto-char (nth 0 (claude-pair-review--hunk-entry (car hunks))))
          (claude-pair-review-apply-hunk)
          (goto-char (nth 0 (claude-pair-review--hunk-entry (cadr hunks))))
          (claude-pair-review-reject-hunk nil "keep nine"))))
    (claude-pair-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "· 2 hunks" text))
        (should (string-match-p "◐ Applied 1 of 2 hunks, saved" text))
        (should (string-match-p "applied 1 of its 2 hunks" text))
        (should (string-match-p "Their note: keep nine" text))))))

(provide 'claude-pair-hunk-tests)
;;; claude-pair-hunk-tests.el ends here
