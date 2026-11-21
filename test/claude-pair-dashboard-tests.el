;;; claude-pair-dashboard-tests.el --- Tests for the dashboard and review styles  -*- lexical-binding: t; -*-

;;; Commentary:

;; The list of waiting hunks, the three review styles, and the chat side
;; of deferred review.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--seven
  (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 7) "")
  "Seven numbered lines.")

(defmacro claude-pair-test-with-two-edits (&rest body)
  "Run BODY with edit e1 (two hunks) on a.txt and e2 (one hunk) on b.txt.
B-FILE is bound to b.txt."
  (declare (indent 0) (debug t))
  `(claude-pair-test-with-file claude-pair-test--seven
     (let ((b-file (expand-file-name "b.txt" (file-name-directory file))))
       (with-temp-file b-file (insert "alpha\nbeta\n"))
       (claude-pair-test--propose
        "e1" :kind "edit" :filePath file :oldString claude-pair-test--seven
        :newString (replace-regexp-in-string
                    "line 7\n" "SEVEN\n"
                    (replace-regexp-in-string "line 1\n" "ONE\n" claude-pair-test--seven)))
       (claude-pair-test--propose "e2" :kind "edit" :filePath b-file :oldString "beta" :newString "BETA")
       (unwind-protect (progn ,@body)
         (when (get-buffer "*claude-pair review*")
           (kill-buffer "*claude-pair review*"))))))

(defun claude-pair-test--rows ()
  "Return the dashboard's rows as lists of strings."
  (with-current-buffer "*claude-pair review*"
    (mapcar (lambda (entry) (append (cadr entry) nil)) tabulated-list-entries)))

(defun claude-pair-test--dashboard-goto (file hunk)
  "Put point in the dashboard on the row for FILE's HUNK, like \"1/2\"."
  (with-current-buffer "*claude-pair review*"
    (goto-char (point-min))
    (while (and (not (eobp))
                (not (let ((row (tabulated-list-get-entry)))
                       (and row (equal (aref row 0) file) (equal (aref row 1) hunk)))))
      (forward-line 1))
    (should-not (eobp))))

;;;; The dashboard

(ert-deftest claude-pair-dashboard-lists-every-waiting-hunk ()
  (claude-pair-test-with-two-edits
    (claude-pair-review)
    (let ((rows (claude-pair-test--rows)))
      (should (= (length rows) 3))
      (should (member "1/2" (mapcar #'cadr rows)))
      (let ((b (seq-find (lambda (r) (string-suffix-p "b.txt" (car r))) rows)))
        (should (equal (nth 1 b) "1/1"))
        (should (equal (nth 2 b) "2"))
        (should (equal (nth 3 b) "−1 +1"))
        (should (equal (nth 4 b) "s1"))))
    (should (eq (key-binding (kbd "a")) #'claude-pair-dashboard-apply))))

(ert-deftest claude-pair-dashboard-decide-from-the-list ()
  (claude-pair-test-with-two-edits
    (claude-pair-review)
    (let ((a-name (car (seq-find (lambda (r) (equal (nth 1 r) "2/2")) (claude-pair-test--rows)))))
      (claude-pair-test--dashboard-goto a-name "2/2")
      (with-current-buffer "*claude-pair review*" (claude-pair-dashboard-apply))
      (should (= (length (claude-pair-test--rows)) 2))
      (should (string-match-p "SEVEN" (claude-pair-test--disk file)))
      (claude-pair-test--dashboard-goto a-name "1/2")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "keep one")))
        (with-current-buffer "*claude-pair review*" (claude-pair-dashboard-reject)))
      (should (= (length (claude-pair-test--rows)) 1))
      (should (equal (plist-get (car claude-pair-test--answers) :outcome) "partial"))
      ;; A whole edit at once.
      (with-current-buffer "*claude-pair review*"
        (goto-char (point-min))
        (claude-pair-dashboard-apply-edit))
      (should (= (length (claude-pair-test--rows)) 0))
      (should (equal (claude-pair-test--disk b-file) "alpha\nBETA\n")))))

(ert-deftest claude-pair-dashboard-follows-decisions-made-in-the-file ()
  (claude-pair-test-with-two-edits
    (claude-pair-review)
    (claude-pair-review-reject "e2" "")
    (claude-pair-dashboard--refresh)
    (should (= (length (claude-pair-test--rows)) 2))
    (should-not (seq-find (lambda (r) (string-suffix-p "b.txt" (car r))) (claude-pair-test--rows)))))

(ert-deftest claude-pair-dashboard-show-goes-to-the-hunk ()
  (claude-pair-test-with-two-edits
    (claude-pair-review)
    (claude-pair-test--dashboard-goto
     (car (seq-find (lambda (r) (string-suffix-p "b.txt" (car r))) (claude-pair-test--rows))) "1/1")
    (with-current-buffer "*claude-pair review*" (claude-pair-dashboard-show))
    ;; `show' moves you: the selected window shows the hunk.
    (should (eq (window-buffer (selected-window)) (find-buffer-visiting b-file)))
    (with-current-buffer (window-buffer (selected-window))
      (goto-char (window-point (selected-window)))
      (should (equal (claude-pair-review--hunk-id (claude-pair-review--hunk-at-point)) "e2")))))

;;;; Review styles

(ert-deftest claude-pair-dashboard-auto-accept-applies-at-once ()
  (claude-pair-test-with-file "one x two\n"
    (let ((claude-pair-review-style 'auto-accept))
      (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
      (should (claude-pair-test--wait-for (lambda () (not (claude-pair-review-pending-p "e1"))) 2))
      (should (equal (claude-pair-test--disk file) "one y two\n"))
      (should (equal (plist-get (car claude-pair-test--answers) :outcome) "applied"))
      ;; Still Claude's.
      (with-current-buffer (find-buffer-visiting file)
        (should (claude-pair-authorship-at (point-min)))))))

(ert-deftest claude-pair-dashboard-deferred-answers-at-once-and-keeps-the-edit ()
  (claude-pair-test-with-file claude-pair-test--seven
    (let ((claude-pair-review-style 'deferred)
          (decided nil))
      (cl-letf* ((claude-pair-review-deferred-functions
                  (list (lambda (session id text) (push (list session id text) decided)))))
        (claude-pair-test--propose
         "e1" :kind "edit" :filePath file :oldString claude-pair-test--seven
         :newString (replace-regexp-in-string
                     "line 7\n" "SEVEN\n"
                     (replace-regexp-in-string "line 1\n" "ONE\n" claude-pair-test--seven)))
        ;; Claude heard at once, and the edit still waits for you.
        (should (equal (plist-get (car claude-pair-test--answers) :outcome) "deferred"))
        (should (claude-pair-review-pending-p "e1"))
        (should (= (claude-pair-review-waiting "s1") 2))
        (with-current-buffer (find-buffer-visiting file)
          (let ((hunks (plist-get (gethash "e1" claude-pair-review--proposals) :hunks)))
            (goto-char (nth 0 (claude-pair-review--hunk-entry (car hunks))))
            (claude-pair-review-apply-hunk)
            (goto-char (nth 0 (claude-pair-review--hunk-entry (cadr hunks))))
            (claude-pair-review-reject-hunk nil "keep seven")))
        ;; No second answer to the daemon: your decision waits for your next message.
        (should (= (length claude-pair-test--answers) 1))
        (should (equal (car (car decided)) "s1"))
        (should (equal (nth 1 (car decided)) "e1"))
        (should (string-match-p "hunk 1 (line 1) applied; hunk 2 (line 7) rejected (note: keep seven)"
                                (nth 2 (car decided))))))))

(ert-deftest claude-pair-dashboard-summaries ()
  (claude-pair-test-with-file "one x two\n"
    (let ((claude-pair-review-style 'deferred) said)
      (cl-letf* ((claude-pair-review-deferred-functions (list (lambda (_s _i text) (push text said)))))
        (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
        (claude-pair-review-apply "e1")
        (should (string-match-p "^Your edit to .*a.txt was applied and saved\\.$" (car said)))
        (claude-pair-test--propose "e2" :kind "edit" :filePath file :oldString "y" :newString "z")
        (claude-pair-review-reject "e2" "no z")
        (should (string-match-p "was rejected (note: no z); do not send it again\\.$" (car said)))
        (claude-pair-test--propose "e3" :kind "edit" :filePath file :oldString "y" :newString "w")
        (with-current-buffer (find-buffer-visiting file)
          (goto-char (point-min))
          (search-forward "w")
          (backward-char)
          (claude-pair-review-ask-hunk "why w?"))
        (should (string-match-p "the user asks: why w\\? (not applied)$" (car said)))
        (with-current-buffer (find-buffer-visiting file) (claude-pair-review-dismiss-note))))))

(ert-deftest claude-pair-dashboard-set-review-style ()
  (let ((claude-pair-review-style 'blocking))
    (claude-pair-set-review-style 'deferred)
    (should (eq claude-pair-review-style 'deferred))))

;;;; The chat side of deferred review

(ert-deftest claude-pair-dashboard-the-chat-keeps-your-review-for-next-time ()
  (claude-pair-test-with-chat
    (let ((claude-pair-chat--buffers (make-hash-table :test #'equal))
          sent)
      (puthash "test-session" (current-buffer) claude-pair-chat--buffers)
      (claude-pair-test--feed
       '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit" :relPath "a.txt")
       '(:kind "edit" :state "deferred" :requestId "e1"))
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "⧗ Deferred: Claude carries on" text))
        (should (string-match-p "y apply" text)))
      ;; You decide later.
      (claude-pair-chat--on-deferred "test-session" "e1" "Your edit to a.txt was applied and saved.")
      (should (string-match-p "Decided; goes to Claude with your next message" (claude-pair-test--transcript)))
      (should (string-match-p "1 review result for Claude" (claude-pair-chat--header-line)))
      ;; It goes with your next message.
      (setq claude-pair-chat--state "idle")
      (cl-letf (((symbol-function 'claude-pair-rpc-request)
                 (lambda (method params &rest _) (when (eq method 'session/prompt) (setq sent params)) '(:ok t))))
        (goto-char (point-max))
        (insert "now the tests")
        (claude-pair-chat-send))
      (should (equal (plist-get sent :text)
                     "My review of your earlier edits (deferred review):\n- Your edit to a.txt was applied and saved.\n\nnow the tests"))
      (should-not claude-pair-chat--review-results)
      (should (string-match-p "Sent with it: your review of 1 deferred edit" (claude-pair-test--transcript))))))

(ert-deftest claude-pair-dashboard-c-c-c-r-sends-the-review-alone ()
  (claude-pair-test-with-chat
    (let (sent)
      (should-error (claude-pair-chat-send-reviews) :type 'user-error)
      (setq claude-pair-chat--review-results (list (cons "About your edit to a.txt, it, the user asks: why? (not applied)" "e7"))
            claude-pair-chat--state "idle")
      (cl-letf (((symbol-function 'claude-pair-rpc-request)
                 (lambda (method params &rest _) (when (eq method 'session/prompt) (setq sent params)) '(:ok t))))
        (claude-pair-chat-send-reviews))
      (should (string-match-p "the user asks: why\\?" (plist-get sent :text)))
      (should (string-suffix-p "carry on with it in mind." (plist-get sent :text)))
      ;; A question among them: Claude's answer fills that edit's note.
      (should (equal claude-pair-chat--answering "e7")))))

(ert-deftest claude-pair-dashboard-the-header-counts-waiting-hunks ()
  (claude-pair-test-with-two-edits
    (claude-pair-test-with-chat
      (setq claude-pair-chat--session-id "s1")
      (should (string-match-p "3 hunks waiting" (claude-pair-chat--header-line)))
      (claude-pair-review-reject "e2" "")
      (should (string-match-p "2 hunks waiting" (claude-pair-chat--header-line))))))

(provide 'claude-pair-dashboard-tests)
;;; claude-pair-dashboard-tests.el ends here
