;;; tandem-hunk-tests.el --- Tests for reviewing Claude's edits hunk by hunk  -*- lexical-binding: t; -*-

;;; Commentary:

;; The diff that splits an edit into hunks, deciding hunks one by one, and
;; what Claude and the chat hear about it.  The review tests' helpers
;; (`tandem-test-with-file' and friends, in the shared helpers) feed
;; proposals straight in.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

;;;; The diff

(defun tandem-test--apply-ranges (a b ranges)
  "Rebuild B from A and the changed RANGES, to check the diff."
  (let ((out nil) (i 0))
    (dolist (r ranges)
      (while (< i (nth 0 r)) (push (aref a i) out) (setq i (1+ i)))
      (dolist (line (append (seq-subseq b (nth 2 r) (nth 3 r)) nil)) (push line out))
      (setq i (nth 1 r)))
    (while (< i (length a)) (push (aref a i) out) (setq i (1+ i)))
    (vconcat (nreverse out))))

(ert-deftest tandem-hunk-the-diff-rebuilds-the-new-text ()
  (let ((state (random "tandem")))
    (ignore state)
    (dotimes (_ 300)
      (let* ((a (vconcat (cl-loop repeat (random 25) collect (format "%c\n" (+ ?a (random 4))))))
             (b (vconcat (cl-loop repeat (random 25) collect (format "%c\n" (+ ?a (random 4))))))
             (ranges (tandem-diff a b)))
        (should (equal (tandem-test--apply-ranges a b ranges) b))
        ;; Ranges are in order and never empty on both sides.
        (let ((last -1))
          (dolist (r ranges)
            (should (> (nth 0 r) last))
            (should (or (< (nth 0 r) (nth 1 r)) (< (nth 2 r) (nth 3 r))))
            (setq last (nth 1 r))))))))

(ert-deftest tandem-hunk-the-diff-finds-separate-changes ()
  (let ((a ["1\n" "2\n" "3\n" "4\n" "5\n" "6\n" "7\n" "8\n"])
        (b ["1\n" "TWO\n" "3\n" "4\n" "5\n" "6\n" "7\n" "8\n" "9\n"]))
    (should (equal (tandem-diff a b) '((1 2 1 2) (8 8 8 9))))))

(ert-deftest tandem-hunk-a-big-rewrite-is-one-hunk ()
  (let* ((tandem-diff-limit 10)
         (a (vconcat (cl-loop for i below 50 collect (format "a%d\n" i))))
         (b (vconcat (cl-loop for i below 50 collect (format "b%d\n" i)))))
    (should (equal (tandem-diff a b) '((0 50 0 50))))))

(ert-deftest tandem-hunk-close-changes-merge ()
  (let ((tandem-review-merge-gap 2))
    (should (equal (length (tandem-review--hunk-specs "1\n2\n3\n4\n5\n6\n7\n"
                                                           "1\nX\n3\n4\nY\n6\n7\n"))
                   1))
    (should (equal (length (tandem-review--hunk-specs "1\n2\n3\n4\n5\n6\n7\n"
                                                           "X\n2\n3\n4\n5\n6\nY\n"))
                   2))))

(ert-deftest tandem-hunk-specs-keep-partial-lines ()
  (should (equal (tandem-review--hunk-specs "x" "y") '((0 1 "y"))))
  (should (equal (tandem-review--hunk-specs "a\nb" "a\nc") '((2 3 "c")))))

;;;; Deciding hunk by hunk

(defconst tandem-test--ten
  (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 10) "")
  "Ten numbered lines.")

(defun tandem-test--two-hunks (file)
  "Propose edit e1 to FILE: change lines 2 and 9 of `tandem-test--ten'."
  (tandem-test--propose
   "e1" :kind "edit" :filePath file
   :oldString tandem-test--ten
   :newString (replace-regexp-in-string
               "line 9\n" "NINE\nNINE AND A HALF\n"
               (replace-regexp-in-string "line 2\n" "TWO\n" tandem-test--ten))))

(defun tandem-test--hunk (n)
  "Return hunk N of edit e1."
  (nth (1- n) (plist-get (gethash "e1" tandem-review--proposals) :hunks)))

(defun tandem-test--goto-hunk (n)
  "Put point on the new text of hunk N of edit e1."
  (goto-char (nth 0 (tandem-review--hunk-entry (tandem-test--hunk n)))))

(ert-deftest tandem-hunk-an-edit-shows-as-hunks ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (tandem-review-hunk-count "e1") '(2 . 2)))
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
      (tandem-test--goto-hunk 1)
      (forward-char 1)
      (should-error (insert "z") :type 'text-read-only))))

(ert-deftest tandem-hunk-mixed-decisions ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (tandem-review-apply-hunk)
      ;; Not finished yet: Claude hears nothing until the last hunk.
      (should-not tandem-test--answers)
      (should (equal (tandem-review-hunk-count "e1") '(1 . 2)))
      ;; Saved at once: the buffer had no changes of yours.
      (should (string-match-p "TWO" (tandem-test--disk file)))
      (should (string-match-p "line 9" (tandem-test--disk file)))
      (tandem-test--goto-hunk 2)
      (tandem-review-reject-hunk nil "keep nine")
      (should (equal (buffer-string)
                     (concat "line 1\nTWO\nline 3\nline 4\nline 5\nline 6\nline 7\n"
                             "line 8\nline 9\nline 10\n")))
      (should (equal (tandem-test--disk file) (buffer-string)))
      (should-not (tandem-review-pending-p "e1"))
      (let ((answer (car tandem-test--answers)))
        (should (equal (plist-get answer :outcome) "partial"))
        (should (eq (plist-get answer :saved) t))
        (should (equal (append (plist-get answer :hunks) nil)
                       '((:index 1 :line 2 :oldLines 1 :newLines 1 :decision "applied" :note "" :saved t)
                         (:index 2 :line 9 :oldLines 1 :newLines 2 :decision "rejected" :note "keep nine"
                                   :saved :json-false))))))))

(ert-deftest tandem-hunk-each-applied-hunk-is-one-undo-step ()
  (tandem-test-with-file tandem-test--ten
    (let ((tandem-review-autosave nil))
      (tandem-test--two-hunks file)
      (with-current-buffer (find-buffer-visiting file)
        (buffer-enable-undo)
        (tandem-test--goto-hunk 1)
        (tandem-review-apply-hunk)
        (undo-boundary)
        (tandem-test--goto-hunk 2)
        (tandem-review-apply-hunk)
        (undo-boundary)
        (should (string-match-p "TWO .*NINE AND A HALF" (replace-regexp-in-string "\n" " " (buffer-string))))
        (let ((last-command nil)) (undo))
        (should (string-match-p "TWO" (buffer-string)))
        (should (string-match-p "line 9\nline 10" (buffer-string)))
        (should-not (string-match-p "NINE" (buffer-string)))
        (should (equal (plist-get (car tandem-test--answers) :outcome) "applied"))
        (should (eq (plist-get (car tandem-test--answers) :saved) :json-false))))))

(ert-deftest tandem-hunk-c-u-applies-every-hunk-and-saves-once ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (let ((saves 0))
        (add-hook 'after-save-hook (lambda () (setq saves (1+ saves))) nil t)
        (tandem-test--goto-hunk 2)
        (tandem-review-apply-hunk '(4))
        (should (= saves 1)))
      (should (equal (tandem-test--disk file) (buffer-string)))
      (should (string-match-p "TWO" (buffer-string)))
      (should (string-match-p "NINE AND A HALF" (buffer-string)))
      (should (equal (car tandem-test--answers)
                     '(:requestId "e1" :outcome "applied" :message "" :saved t :created :json-false))))))

(ert-deftest tandem-hunk-rejecting-every-hunk-is-a-rejection ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (tandem-review-reject-hunk nil "no")
      (tandem-test--goto-hunk 2)
      (tandem-review-reject-hunk nil "no")
      (should (equal (buffer-string) tandem-test--ten))
      (should-not (buffer-modified-p))
      (let ((answer (car tandem-test--answers)))
        (should (equal (plist-get answer :outcome) "rejected"))
        (should (equal (plist-get answer :message) "no"))))))

(ert-deftest tandem-hunk-n-and-p-move-between-hunks ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (should (eq (key-binding "n") #'tandem-review-next-hunk))
      (tandem-review-next-hunk)
      (should (eq (tandem-review--hunk-at-point) (tandem-test--hunk 2)))
      (tandem-review-previous-hunk)
      (should (eq (tandem-review--hunk-at-point) (tandem-test--hunk 1)))
      (should-error (tandem-review-previous-hunk) :type 'user-error)
      ;; On the editable lines between hunks, n is just n.
      (goto-char (point-min))
      (search-forward "line 5")
      (should-not (eq (key-binding "n") #'tandem-review-next-hunk)))))

(ert-deftest tandem-hunk-saving-with-a-hunk-waiting ()
  (tandem-test-with-file tandem-test--ten
    (let ((tandem-review-autosave nil))
      (tandem-test--two-hunks file)
      (with-current-buffer (find-buffer-visiting file)
        (tandem-test--goto-hunk 1)
        (tandem-review-apply-hunk)
        (let ((save-silently t)) (save-buffer))
        ;; Your save writes the applied hunk, not the waiting one.
        (should (string-match-p "TWO" (tandem-test--disk file)))
        (should-not (string-match-p "NINE" (tandem-test--disk file)))
        (should (string-match-p "NINE AND A HALF" (buffer-string)))
        (should (tandem-review-pending-p "e1"))))))

(ert-deftest tandem-hunk-replace-all-gives-a-hunk-per-place ()
  (tandem-test-with-file "a x\nb\nc\nd\ne x\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y" :replaceAll t)
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (tandem-review-hunk-count "e1") '(2 . 2)))
      (tandem-test--goto-hunk 2)
      (tandem-review-apply-hunk)
      (tandem-test--goto-hunk 1)
      (tandem-review-reject-hunk nil "")
      (should (equal (buffer-string) "a x\nb\nc\nd\ne y\n"))
      (should (equal (plist-get (car tandem-test--answers) :outcome) "partial")))))

(ert-deftest tandem-hunk-closing-the-buffer-rejects-what-waits ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (tandem-review-apply-hunk))
    (kill-buffer (find-buffer-visiting file))
    (let ((hunks (append (plist-get (car tandem-test--answers) :hunks) nil)))
      (should (equal (plist-get (car tandem-test--answers) :outcome) "partial"))
      (should (equal (plist-get (nth 1 hunks) :note) "The user closed the buffer.")))))

;;;; The chat

(ert-deftest tandem-hunk-the-chat-tells-the-mixed-outcome ()
  (tandem-test-with-chat
    (tandem-test--feed
     '(:kind "edit" :state "pending" :requestId "e9" :editKind "edit" :relPath "a.py" :title "Edit a.py")
     '(:kind "edit" :state "partial" :requestId "e9" :saved t
             :hunks [(:index 1 :line 2 :decision "applied" :note "")
                     (:index 2 :line 9 :decision "rejected" :note "keep nine")]))
    (let ((text (tandem-test--transcript)))
      (should (string-match-p "◐ Applied 1 of 2 hunks, saved" text))
      (should (string-match-p "✗ hunk 2 (line 9) rejected: keep nine" text)))))

;;;; Asking Claude about a hunk

(ert-deftest tandem-hunk-asking-sends-the-edit-back-with-the-question ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (tandem-review-apply-hunk)
      (tandem-test--goto-hunk 2)
      (should (eq (key-binding (kbd "C-c '")) #'tandem-review-ask-hunk))
      (tandem-review-ask-hunk "why two lines?")
      ;; Decided hunks keep their decision; the asked one is not applied.
      (should (string-match-p "TWO" (buffer-string)))
      (should (string-match-p "line 9\nline 10" (buffer-string)))
      (should-not (tandem-review-pending-p "e1"))
      (let ((answer (car tandem-test--answers)))
        (should (equal (plist-get answer :outcome) "question"))
        (should (equal (plist-get answer :message) "why two lines?"))
        (should (equal (mapcar (lambda (h) (plist-get h :decision)) (plist-get answer :hunks))
                       '("applied" "asked"))))
      ;; A note sits where the hunk was.
      (let ((note (seq-find (lambda (ov) (overlay-get ov 'tandem-note))
                            (overlays-in (point-min) (point-max)))))
        (should note)
        (should (string-match-p "@claude why two lines\\?" (overlay-get note 'before-string)))
        (should (string-match-p "Claude: …" (overlay-get note 'before-string)))
        (should (equal (line-number-at-pos (overlay-start note)) 9))
        ;; Claude's answer streams into it.
        (tandem-review-note-append "e1" "Because the loop needs ")
        (tandem-review-note-append "e1" "its own line.")
        (tandem-review-note-done "e1")
        ;; Lines wrap to the window; read the note as one text.
        (should (string-match-p "Claude: Because the loop needs its own line\\."
                                (replace-regexp-in-string "\n┃ " " " (overlay-get note 'before-string))))
        ;; Not part of the file.
        (should-not (string-match-p "@claude" (buffer-string)))
        (tandem-review-dismiss-note)
        (should-not (overlay-buffer note))))))

(ert-deftest tandem-hunk-asking-leaves-the-other-hunks-undecided ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (tandem-review-ask-hunk "is TWO right?")
      (should (equal (buffer-string) tandem-test--ten))
      (should (equal (mapcar (lambda (h) (plist-get h :decision))
                             (plist-get (car tandem-test--answers) :hunks))
                     '("asked" "undecided")))
      (should-error (tandem-review-ask-hunk "") :type 'user-error)
      (tandem-review-dismiss-note))))

(ert-deftest tandem-hunk-a-note-holds-the-whole-answer ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 1)
      (let ((tandem-review-note-lines 2))
        (tandem-review-ask-hunk "explain")
        (tandem-review-note-append "e1" "one\ntwo\nthree\nfour")
        (let ((text (lambda () (overlay-get (plist-get (gethash "e1" tandem-review--notes) :overlay)
                                            'before-string))))
          ;; All of it, in the editor.
          (should (string-match-p "Claude: one" (funcall text)))
          (should (string-match-p "four" (funcall text)))
          (should-not (string-match-p "in the chat" (funcall text)))
          (should (string-match-p "\\[fold\\]" (funcall text)))
          ;; Folded: the start, and how much more there is.
          (tandem-review-toggle-note "e1")
          (should (string-match-p "two" (funcall text)))
          (should-not (string-match-p "three" (funcall text)))
          (should (string-match-p "… 2 more lines \\[unfold\\]" (funcall text)))
          ;; From the line of the note, without the mouse.
          (goto-char (point-min))
          (forward-line 1)
          (tandem-review-toggle-note)
          (should (string-match-p "four" (funcall text)))))
      (tandem-review-dismiss-note))))

(ert-deftest tandem-hunk-note-lines-wrap-to-the-window ()
  (should (equal (tandem-review--wrap '("aaa bbb ccc ddd") 8) '("aaa bbb" "ccc ddd")))
  ;; Lists keep their indentation; code blocks are never broken.
  (should (equal (tandem-review--wrap '("- one two three four") 12) '("- one two" "  three four")))
  (let ((code "    return some_function(argument_one, argument_two)"))
    (should (equal (tandem-review--wrap (list "```" code "```") 20) (list "```" code "```")))))

(ert-deftest tandem-hunk-the-chat-feeds-the-answer-into-the-note ()
  (tandem-test-with-file tandem-test--ten
    (tandem-test--two-hunks file)
    (with-current-buffer (find-buffer-visiting file)
      (tandem-test--goto-hunk 2)
      (tandem-review-ask-hunk "why?"))
    (tandem-test-with-chat
      (tandem-test--feed
       '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit" :relPath "a.txt")
       '(:kind "edit" :state "question" :requestId "e1" :message "why?"
               :hunks [(:index 1 :line 2 :decision "undecided") (:index 2 :line 9 :decision "asked")])
       '(:kind "text" :delta "Because ")
       '(:kind "text" :delta "it reads better.")
       '(:kind "result" :subtype "success"))
      (should (string-match-p "? You asked about hunk 2 (line 9): why\\?" (tandem-test--transcript)))
      (let ((note (gethash "e1" tandem-review--notes)))
        (should (equal (plist-get note :answer) "Because it reads better."))
        (should (plist-get note :done)))
      ;; After the turn, text no longer goes to the note.
      (tandem-test--feed '(:kind "text" :delta " More."))
      (should (equal (plist-get (gethash "e1" tandem-review--notes) :answer) "Because it reads better.")))
    (with-current-buffer (find-buffer-visiting file)
      (tandem-review-dismiss-note))))

;;;; The chat block, drawn before the edit is shown

(ert-deftest tandem-hunk-a-block-drawn-early-gets-its-keys ()
  (tandem-test-with-chat
    (let ((tandem-chat--buffers (make-hash-table :test #'equal)))
      (puthash "test-session" (current-buffer) tandem-chat--buffers)
      ;; The update arrives before Emacs has shown the edit.
      (tandem-test--feed
       '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit" :relPath "a.txt" :title "Edit a.txt"))
      (should (string-match-p "Waiting for review" (tandem-test--transcript)))
      (let ((chat (current-buffer)))
        (tandem-test-with-file tandem-test--ten
          (tandem-test--two-hunks file)
          (with-current-buffer chat
            (let ((text (tandem-test--transcript)))
              (should (string-match-p "✎ Claude wants to edit a.txt · 2 hunks" text))
              (should (string-match-p "y apply all" text))
              (should-not (string-match-p "Waiting for review" text))
              ;; The keys cover the redrawn block.
              (goto-char (point-min))
              (search-forward "apply all")
              (should (equal (get-text-property (point) 'tandem-edit) "e1")))))))))

;;;; For real

(ert-deftest tandem-hunk-partial-for-real ()
  (tandem-test-with-edit-project
    (with-temp-file (expand-file-name "a.txt" project) (insert tandem-test--ten))
    (tandem-test--send
     buffer (tandem-test--edit-prompt
             (list :file "a.txt" :old tandem-test--ten
                   :new (replace-regexp-in-string
                         "line 9\n" "NINE\n"
                         (replace-regexp-in-string "line 2\n" "TWO\n" tandem-test--ten)))))
    (let ((id (tandem-test--wait-proposal)))
      (should (equal (tandem-review-hunk-count id) '(2 . 2)))
      (with-current-buffer (find-buffer-visiting (expand-file-name "a.txt" project))
        (let ((hunks (plist-get (gethash id tandem-review--proposals) :hunks)))
          (goto-char (nth 0 (tandem-review--hunk-entry (car hunks))))
          (tandem-review-apply-hunk)
          (goto-char (nth 0 (tandem-review--hunk-entry (cadr hunks))))
          (tandem-review-reject-hunk nil "keep nine"))))
    (tandem-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "· 2 hunks" text))
        (should (string-match-p "◐ Applied 1 of 2 hunks, saved" text))
        (should (string-match-p "applied 1 of its 2 hunks" text))
        (should (string-match-p "Their note: keep nine" text))))))

(ert-deftest tandem-hunk-ask-for-real ()
  (tandem-test-with-edit-project
    (with-temp-file (expand-file-name "a.txt" project) (insert tandem-test--ten))
    (tandem-test--send
     buffer (tandem-test--edit-prompt
             (list :file "a.txt" :old tandem-test--ten
                   :new (replace-regexp-in-string
                         "line 9\n" "NINE\n"
                         (replace-regexp-in-string "line 2\n" "TWO\n" tandem-test--ten)))))
    (let ((id (tandem-test--wait-proposal)))
      (with-current-buffer (find-buffer-visiting (expand-file-name "a.txt" project))
        (let ((hunks (plist-get (gethash id tandem-review--proposals) :hunks)))
          (goto-char (nth 0 (tandem-review--hunk-entry (cadr hunks))))
          (tandem-review-ask-hunk "why NINE?")))
      (tandem-test--wait-idle buffer)
      (with-current-buffer buffer
        (let ((text (tandem-test--transcript)))
          (should (string-match-p "? You asked about hunk 2 (line 9): why NINE" text))
          (should (string-match-p "the user asks you a question about hunk 2" text))))
      ;; The fake claude's reply (it echoes the tool result) reached the note.
      (should (string-match-p "the user asks you a question"
                              (plist-get (gethash id tandem-review--notes) :answer)))
      (with-current-buffer (find-buffer-visiting (expand-file-name "a.txt" project))
        (tandem-review-dismiss-note)))))

(provide 'tandem-hunk-tests)
;;; tandem-hunk-tests.el ends here
