;;; tandem-dashboard-tests.el --- Tests for the dashboard and review styles  -*- lexical-binding: t; -*-

;;; Commentary:

;; The list of waiting hunks, the three review styles, and the chat side
;; of deferred review.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defconst tandem-test--seven
  (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 7) "")
  "Seven numbered lines.")

(defmacro tandem-test-with-two-edits (&rest body)
  "Run BODY with edit e1 (two hunks) on a.txt and e2 (one hunk) on b.txt.
B-FILE is bound to b.txt."
  (declare (indent 0) (debug t))
  `(tandem-test-with-file tandem-test--seven
     (let ((b-file (expand-file-name "b.txt" (file-name-directory file))))
       (with-temp-file b-file (insert "alpha\nbeta\n"))
       (tandem-test--propose
        "e1" :kind "edit" :filePath file :oldString tandem-test--seven
        :newString (replace-regexp-in-string
                    "line 7\n" "SEVEN\n"
                    (replace-regexp-in-string "line 1\n" "ONE\n" tandem-test--seven)))
       (tandem-test--propose "e2" :kind "edit" :filePath b-file :oldString "beta" :newString "BETA")
       (unwind-protect (progn ,@body)
         (when (get-buffer "*tandem review*")
           (kill-buffer "*tandem review*"))))))

(defun tandem-test--rows ()
  "Return the dashboard's rows as lists of strings."
  (with-current-buffer "*tandem review*"
    (mapcar (lambda (entry) (append (cadr entry) nil)) tabulated-list-entries)))

(defun tandem-test--dashboard-goto (file hunk)
  "Put point in the dashboard on the row for FILE's HUNK, like \"1/2\"."
  (with-current-buffer "*tandem review*"
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (let ((row (tabulated-list-get-entry)))
                       (and row (equal (aref row 0) file) (equal (aref row 1) hunk)))))
      (forward-line 1))
    (should-not (eobp))))

;;;; The dashboard

(ert-deftest tandem-dashboard-lists-every-waiting-hunk ()
  (tandem-test-with-two-edits
    (tandem-review)
    (let ((rows (tandem-test--rows)))
      (should (= (length rows) 3))
      (should (member "1/2" (mapcar #'cadr rows)))
      (let ((b (seq-find (lambda (r) (string-suffix-p "b.txt" (car r))) rows)))
        (should (equal (nth 1 b) "1/1"))
        (should (equal (nth 2 b) "2"))
        (should (equal (nth 3 b) "−1 +1"))
        (should (equal (nth 4 b) "s1"))))
    (should (eq (key-binding (kbd "a")) #'tandem-dashboard-apply))))

(ert-deftest tandem-dashboard-decide-from-the-list ()
  (tandem-test-with-two-edits
    (tandem-review)
    (let ((a-name (car (seq-find (lambda (r) (equal (nth 1 r) "2/2")) (tandem-test--rows)))))
      (tandem-test--dashboard-goto a-name "2/2")
      (with-current-buffer "*tandem review*" (tandem-dashboard-apply))
      (should (= (length (tandem-test--rows)) 2))
      (should (string-match-p "SEVEN" (tandem-test--disk file)))
      (tandem-test--dashboard-goto a-name "1/2")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "keep one")))
        (with-current-buffer "*tandem review*" (tandem-dashboard-reject)))
      (should (= (length (tandem-test--rows)) 1))
      (should (equal (plist-get (car tandem-test--answers) :outcome) "partial"))
      ;; A whole edit at once.
      (with-current-buffer "*tandem review*"
        (goto-char (point-min))
        (tandem-dashboard-apply-edit))
      (should (= (length (tandem-test--rows)) 0))
      (should (equal (tandem-test--disk b-file) "alpha\nBETA\n")))))

(ert-deftest tandem-dashboard-follows-decisions-made-in-the-file ()
  (tandem-test-with-two-edits
    (tandem-review)
    (tandem-review-reject "e2" "")
    (tandem-dashboard--refresh)
    (should (= (length (tandem-test--rows)) 2))
    (should-not (seq-find (lambda (r) (string-suffix-p "b.txt" (car r))) (tandem-test--rows)))))

(ert-deftest tandem-dashboard-show-goes-to-the-hunk ()
  (tandem-test-with-two-edits
    (tandem-review)
    (tandem-test--dashboard-goto
     (car (seq-find (lambda (r) (string-suffix-p "b.txt" (car r))) (tandem-test--rows))) "1/1")
    (with-current-buffer "*tandem review*" (tandem-dashboard-show))
    ;; `show' moves you: the selected window shows the hunk.
    (should (eq (window-buffer (selected-window)) (find-buffer-visiting b-file)))
    (with-current-buffer (window-buffer (selected-window))
      (goto-char (window-point (selected-window)))
      (should (equal (tandem-review--hunk-id (tandem-review--hunk-at-point)) "e2")))))

;;;; Review styles

(ert-deftest tandem-dashboard-auto-accept-applies-at-once ()
  (tandem-test-with-file "one x two\n"
    (let ((tandem-review-style 'auto-accept))
      (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
      (should (tandem-test--wait-for (lambda () (not (tandem-review-pending-p "e1"))) 2))
      (should (equal (tandem-test--disk file) "one y two\n"))
      (should (equal (plist-get (car tandem-test--answers) :outcome) "applied"))
      ;; Still Claude's.
      (with-current-buffer (find-buffer-visiting file)
        (should (tandem-authorship-at (point-min)))))))

(ert-deftest tandem-dashboard-deferred-answers-at-once-and-keeps-the-edit ()
  (tandem-test-with-file tandem-test--seven
    (let ((tandem-review-style 'deferred)
          (decided nil))
      (cl-letf* ((tandem-review-deferred-functions
                  (list (lambda (session id text) (push (list session id text) decided)))))
        (tandem-test--propose
         "e1" :kind "edit" :filePath file :oldString tandem-test--seven
         :newString (replace-regexp-in-string
                     "line 7\n" "SEVEN\n"
                     (replace-regexp-in-string "line 1\n" "ONE\n" tandem-test--seven)))
        ;; Claude heard at once, and the edit still waits for you.
        (should (equal (plist-get (car tandem-test--answers) :outcome) "deferred"))
        (should (tandem-review-pending-p "e1"))
        (should (= (tandem-review-waiting "s1") 2))
        (with-current-buffer (find-buffer-visiting file)
          (let ((hunks (plist-get (gethash "e1" tandem-review--proposals) :hunks)))
            (goto-char (nth 0 (tandem-review--hunk-entry (car hunks))))
            (tandem-review-apply-hunk)
            (goto-char (nth 0 (tandem-review--hunk-entry (cadr hunks))))
            (tandem-review-reject-hunk nil "keep seven")))
        ;; No second answer to the daemon: your decision waits for your next message.
        (should (= (length tandem-test--answers) 1))
        (should (equal (car (car decided)) "s1"))
        (should (equal (nth 1 (car decided)) "e1"))
        (should (string-match-p "hunk 1 (line 1) applied; hunk 2 (line 7) rejected (note: keep seven)"
                                (nth 2 (car decided))))))))

(ert-deftest tandem-dashboard-summaries ()
  (tandem-test-with-file "one x two\n"
    (let ((tandem-review-style 'deferred) said)
      (cl-letf* ((tandem-review-deferred-functions (list (lambda (_s _i text) (push text said)))))
        (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
        (tandem-review-apply "e1")
        (should (string-match-p "^Your edit to .*a.txt was applied and saved\\.$" (car said)))
        (tandem-test--propose "e2" :kind "edit" :filePath file :oldString "y" :newString "z")
        (tandem-review-reject "e2" "no z")
        (should (string-match-p "was rejected (note: no z); do not send it again\\.$" (car said)))
        (tandem-test--propose "e3" :kind "edit" :filePath file :oldString "y" :newString "w")
        (with-current-buffer (find-buffer-visiting file)
          (goto-char (point-min))
          (search-forward "w")
          (backward-char)
          (tandem-review-ask-hunk "why w?"))
        (should (string-match-p "the user asks: why w\\? (not applied)$" (car said)))
        (with-current-buffer (find-buffer-visiting file) (tandem-review-dismiss-note))))))

(ert-deftest tandem-dashboard-set-review-style ()
  (let ((tandem-review-style 'blocking))
    (tandem-set-review-style 'deferred)
    (should (eq tandem-review-style 'deferred))))

;;;; The chat side of deferred review

(ert-deftest tandem-dashboard-the-chat-keeps-your-review-for-next-time ()
  (tandem-test-with-chat
    (let ((tandem-chat--buffers (make-hash-table :test #'equal))
          sent)
      (puthash "test-session" (current-buffer) tandem-chat--buffers)
      (tandem-test--feed
       '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit" :relPath "a.txt")
       '(:kind "edit" :state "deferred" :requestId "e1"))
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "⧗ Deferred: Claude carries on" text))
        (should (string-match-p "y apply" text)))
      ;; You decide later.
      (tandem-chat--on-deferred "test-session" "e1" "Your edit to a.txt was applied and saved.")
      (should (string-match-p "Decided; goes to Claude with your next message" (tandem-test--transcript)))
      (should (string-match-p "1 review result for Claude" (tandem-chat--header-line)))
      ;; It goes with your next message.
      (setq tandem-chat--state "idle")
      (cl-letf (((symbol-function 'tandem-rpc-request)
                 (lambda (method params &rest _) (when (eq method 'session/prompt) (setq sent params)) '(:ok t))))
        (goto-char (point-max))
        (insert "now the tests")
        (tandem-chat-send))
      (should (equal (plist-get sent :text)
                     "My review of your earlier edits (deferred review):\n- Your edit to a.txt was applied and saved.\n\nnow the tests"))
      (should-not tandem-chat--review-results)
      (should (string-match-p "Sent with it: your review of 1 deferred edit" (tandem-test--transcript))))))

(ert-deftest tandem-dashboard-c-c-c-r-sends-the-review-alone ()
  (tandem-test-with-chat
    (let (sent)
      (should-error (tandem-chat-send-reviews) :type 'user-error)
      (setq tandem-chat--review-results (list (cons "About your edit to a.txt, it, the user asks: why? (not applied)" "e7"))
            tandem-chat--state "idle")
      (cl-letf (((symbol-function 'tandem-rpc-request)
                 (lambda (method params &rest _) (when (eq method 'session/prompt) (setq sent params)) '(:ok t))))
        (tandem-chat-send-reviews))
      (should (string-match-p "the user asks: why\\?" (plist-get sent :text)))
      (should (string-suffix-p "carry on with it in mind." (plist-get sent :text)))
      ;; A question among them: Claude's answer fills that edit's note.
      (should (equal tandem-chat--answering "e7")))))

(ert-deftest tandem-dashboard-the-header-counts-waiting-hunks ()
  (tandem-test-with-two-edits
    (tandem-test-with-chat
      (setq tandem-chat--session-id "s1")
      (should (string-match-p "3 hunks waiting" (tandem-chat--header-line)))
      (tandem-review-reject "e2" "")
      (should (string-match-p "2 hunks waiting" (tandem-chat--header-line))))))

(provide 'tandem-dashboard-tests)
;;; tandem-dashboard-tests.el ends here
