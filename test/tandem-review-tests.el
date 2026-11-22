;;; tandem-review-tests.el --- Tests for reviewing Claude's edits  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group feeds proposals straight to the review code, with the
;; daemon replaced by a recorder of edit/answer calls.  The second runs
;; edits for real: the fake claude calls edit_file through the daemon's MCP
;; helper, and the proposal appears in a real file buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

;;;; Proposals, without a daemon

(ert-deftest tandem-review-the-new-text-is-real-text-and-the-file-is-untouched ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (let ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (should (equal (buffer-string) "one xy two\n"))
        (should-not (buffer-modified-p))
        (should (equal (tandem-test--disk file) "one x two\n"))
        (let ((faces (mapcar (lambda (ov) (list (overlay-get ov 'face)
                                                (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))
                             (seq-filter (lambda (ov) (overlay-get ov 'face))
                                         (overlays-in (point-min) (point-max))))))
          (should (member '(tandem-review-removed "x") faces))
          (should (member '(tandem-review-added "y") faces)))
        (should (string-match-p "Claude proposes an edit"
                                (overlay-get (tandem-test--overlay-with 'before-string buffer)
                                             'before-string)))
        (goto-char 6)
        (should (looking-at "y two"))
        (should (equal (get-char-property (point) 'tandem-proposal) "e1"))
        (should (tandem-review-pending-p "e1"))
        (should-not tandem-test--answers)
        (tandem-review-reject "e1" "")
        (should (equal (buffer-string) "one x two\n"))
        (should-not (buffer-modified-p))))))

(ert-deftest tandem-review-a-long-proposal-can-be-scrolled-and-read ()
  (tandem-test-with-file ""
    (let ((new (expand-file-name "long.txt" (file-name-directory file)))
          (content (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 200) "")))
      (tandem-test--propose "e1" :kind "write" :filePath new :content content)
      (with-current-buffer (find-buffer-visiting new)
        (should (= (count-lines (point-min) (point-max)) 200))
        (goto-char (point-min))
        (forward-line 149)
        (should (looking-at "line 150$"))
        (should (= (line-number-at-pos) 150))
        (should-not (buffer-modified-p))
        (should-not (file-exists-p new))
        (tandem-review-apply "e1")
        (should (equal (tandem-test--disk new) content))))))

(ert-deftest tandem-review-the-proposed-texts-are-locked ()
  (tandem-test-with-file "one xy two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "xy" :newString "qr")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "one xyqr two\n"))
      (goto-char 6)
      (should-error (insert "z") :type 'text-read-only)
      (should-error (delete-char 1) :type 'text-read-only)
      (goto-char 8)
      (should-error (insert "z") :type 'text-read-only)
      (goto-char 9)
      (insert "!")
      (goto-char (point-min))
      (insert "typed ")
      (should (equal (buffer-string) "typed one xyqr! two\n"))
      (tandem-review-reject "e1" "")
      (should (equal (buffer-string) "typed one xy! two\n"))
      (should (buffer-modified-p)))))

(ert-deftest tandem-review-saving-writes-only-your-text ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (let (seen)
        ;; A save hook (a formatter, say) sees your text alone.
        (add-hook 'before-save-hook (lambda () (setq seen (buffer-string))) nil t)
        (goto-char (point-max))
        (insert "mine\n")
        (let ((save-silently t)) (save-buffer))
        (should (equal seen "one x two\nmine\n")))
      (should (equal (tandem-test--disk file) "one x two\nmine\n"))
      (should (equal (buffer-string) "one xy two\nmine\n"))
      (should-not (buffer-modified-p))
      (should (tandem-review-pending-p "e1"))
      (should (get-text-property 5 'read-only))
      (should (get-text-property 6 'read-only))
      (goto-char 6)
      (should-error (delete-char 1) :type 'text-read-only)
      (tandem-review-apply "e1")
      (should (equal (tandem-test--disk file) "one y two\nmine\n"))
      (should (eq (plist-get (car tandem-test--answers) :saved) t)))))

(ert-deftest tandem-review-changing-major-mode-keeps-saving-safe ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (text-mode)
      (goto-char (point-max))
      (insert "mine\n")
      (let ((save-silently t)) (save-buffer))
      (should (equal (tandem-test--disk file) "one x two\nmine\n"))
      (should (equal (buffer-string) "one xy two\nmine\n")))))

(ert-deftest tandem-review-reverting-drops-the-proposal ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (with-temp-file file (insert "changed on disk\n"))
      (revert-buffer t t t)
      (should (equal (buffer-string) "changed on disk\n"))
      (should-not (tandem-review-pending-p "e1"))
      (should-not (overlays-in (point-min) (point-max)))
      (should (equal (plist-get (car tandem-test--answers) :outcome) "error"))
      (should (string-match-p "reloaded from disk"
                              (plist-get (car tandem-test--answers) :message))))))

(ert-deftest tandem-review-two-proposals-in-one-buffer ()
  (tandem-test-with-file "one x two\nthree\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    ;; Checked against your text: e1's "y" is not seen as part of the file.
    (tandem-test--propose "e2" :kind "edit" :filePath file :oldString "three\n" :newString "y\n")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "one xy two\nthree\ny\n"))
      (should-not (buffer-modified-p))
      (should (tandem-review-pending-p "e2"))
      ;; Applying e1 saves it, without e2's text.
      (tandem-review-apply "e1")
      (should (equal (tandem-test--disk file) "one y two\nthree\n"))
      (should (equal (buffer-string) "one y two\nthree\ny\n"))
      (should-not (buffer-modified-p))
      (tandem-review-reject "e2" "")
      (should (equal (buffer-string) "one y two\nthree\n"))
      (should-not (buffer-modified-p)))))

(ert-deftest tandem-review-overlapping-proposals-are-refused ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x two" :newString "y")
    (tandem-test--propose "e2" :kind "edit" :filePath file :oldString "one x" :newString "z")
    (should-not (tandem-review-pending-p "e2"))
    (should (string-match-p "Another edit to the same text"
                            (plist-get (car tandem-test--answers) :message)))
    (should (tandem-review-pending-p "e1"))))

(ert-deftest tandem-review-your-undo-history-is-untouched ()
  (tandem-test-with-file "one x two\n"
    (with-current-buffer (find-file-noselect file)
      (buffer-enable-undo)
      (goto-char (point-min))
      (insert "AAA")
      (undo-boundary))
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (goto-char (point-max))
      (insert "BBB")
      (undo-boundary)
      (tandem-review-reject "e1" "")
      (should (equal (buffer-string) "AAAone x two\nBBB"))
      (let ((last-command nil)) (undo 2))
      (should (equal (buffer-string) "one x two\n")))))

(ert-deftest tandem-review-no-lock-file-while-proposing ()
  (tandem-test-with-file "one x two\n"
    (let ((create-lockfiles t))
      (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
      (should-not (file-symlink-p (expand-file-name ".#a.txt" (file-name-directory file))))
      (should-not (file-exists-p (expand-file-name ".#a.txt" (file-name-directory file)))))))

(ert-deftest tandem-review-write-creates-a-new-file ()
  (tandem-test-with-file ""
    (let ((new (expand-file-name "sub/dir/b.txt" (file-name-directory file))))
      (tandem-test--propose "e1" :kind "write" :filePath new :content "hello\nworld\n")
      (let ((buffer (find-buffer-visiting new)))
        (with-current-buffer buffer
          (should (equal (buffer-string) "hello\nworld\n"))
          (should-not (buffer-modified-p)))
        (should (string-match-p "this new file"
                                (overlay-get (tandem-test--overlay-with 'before-string buffer)
                                             'before-string)))
        (tandem-review-apply "e1")
        (should (equal (tandem-test--disk new) "hello\nworld\n"))
        (should (equal (car tandem-test--answers)
                       '(:requestId "e1" :outcome "applied" :message "" :saved t :created t)))))))

(ert-deftest tandem-review-write-shows-only-the-changed-lines ()
  (tandem-test-with-file "a\nb\nc\nd\n"
    (tandem-test--propose "e1" :kind "write" :filePath file :content "a\nB\nc\nd\n")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "a\nb\nB\nc\nd\n"))
      (let ((faces (mapcar (lambda (ov) (list (overlay-get ov 'face)
                                              (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))
                           (seq-filter (lambda (ov) (overlay-get ov 'face))
                                       (overlays-in (point-min) (point-max))))))
        (should (member '(tandem-review-removed "b\n") faces))
        (should (member '(tandem-review-added "B\n") faces)))
      (tandem-review-apply "e1")
      (should (equal (buffer-string) "a\nB\nc\nd\n")))))

(ert-deftest tandem-review-a-read-only-buffer-is-reported ()
  (tandem-test-with-file "one x two\n"
    (with-current-buffer (find-file-noselect file) (setq buffer-read-only t))
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (should (equal (plist-get (car tandem-test--answers) :outcome) "error"))
    (should (string-match-p "read-only in Emacs" (plist-get (car tandem-test--answers) :message)))))

(ert-deftest tandem-review-a-failure-while-applying-is-reported ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (cl-letf (((symbol-function 'tandem-review--replace) (lambda (&rest _) (error "Disk on fire"))))
      (tandem-review-apply "e1"))
    (should (equal (car tandem-test--answers)
                   '(:requestId "e1" :outcome "error" :message "Emacs could not apply the edit: Disk on fire"
                                :saved :json-false :created :json-false)))))

(ert-deftest tandem-review-apply-saves-and-is-one-undo-step ()
  (tandem-test-with-file "a x b x c\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "YY"
                               :replaceAll t)
    (with-current-buffer (find-buffer-visiting file)
      (undo-boundary)
      (tandem-review-apply "e1")
      (should (equal (buffer-string) "a YY b YY c\n"))
      (should (equal (tandem-test--disk file) "a YY b YY c\n"))
      (should-not (overlays-in (point-min) (point-max)))
      (should-not (text-property-any (point-min) (point-max) 'read-only
                                     tandem-review--locked-message))
      (should-not (tandem-review-pending-p "e1"))
      (should (equal tandem-test--answers
                     '((:requestId "e1" :outcome "applied" :message "" :saved t :created :json-false))))
      (undo-boundary)
      (let ((last-command nil)) (undo))
      (should (equal (buffer-string) "a x b x c\n")))))

(ert-deftest tandem-review-reject-leaves-the-file-alone ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (tandem-review-reject "e1" "keep x")
      (should (equal (buffer-string) "one x two\n"))
      (should-not (buffer-modified-p))
      (should-not (overlays-in (point-min) (point-max)))
      (goto-char 6)
      (insert "z")
      (should (equal tandem-test--answers
                     '((:requestId "e1" :outcome "rejected" :message "keep x" :saved :json-false
                                   :created :json-false)))))))

(ert-deftest tandem-review-errors-match-the-built-in-edit-tool ()
  (tandem-test-with-file "x and x\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "zzz" :newString "y")
    (tandem-test--propose "e2" :kind "edit" :filePath file :oldString "x" :newString "y")
    (tandem-test--propose "e3" :kind "edit" :filePath file :oldString "" :newString "y")
    (tandem-test--propose "e4" :kind "write" :filePath file :content "x and x\n")
    (let ((messages (mapcar (lambda (a) (plist-get a :message)) (reverse tandem-test--answers))))
      (should (equal (mapcar (lambda (a) (plist-get a :outcome)) tandem-test--answers)
                     '("error" "error" "error" "error")))
      (should (equal (nth 0 messages) "String to replace not found in file.\nString: zzz"))
      (should (string-prefix-p "Found 2 matches of the string to replace, but replace_all is false." (nth 1 messages)))
      (should (string-suffix-p "\nString: x" (nth 1 messages)))
      (should (equal (nth 2 messages) "Cannot create new file - file already exists."))
      (should (equal (nth 3 messages) "No changes to make: the file already has this content.")))
    (with-current-buffer (find-buffer-visiting file)
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest tandem-review-your-unsaved-changes-are-never-saved ()
  (tandem-test-with-file "one x two\n"
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "mine\n"))
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (tandem-review-apply "e1")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "one y two\nmine\n"))
      (should (buffer-modified-p)))
    (should (equal (tandem-test--disk file) "one x two\n"))
    (should (eq (plist-get (car tandem-test--answers) :saved) :json-false))))

(ert-deftest tandem-review-typing-during-review-blocks-the-save ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (goto-char (point-max))
      (insert "mine\n"))
    (tandem-review-apply "e1")
    (should (equal (tandem-test--disk file) "one x two\n"))
    (should (eq (plist-get (car tandem-test--answers) :saved) :json-false))))

(ert-deftest tandem-review-text-changed-underneath-is-not-applied ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (let ((inhibit-read-only t))
        (goto-char 5)
        (delete-char 1)
        (insert "w"))
      (tandem-review-apply "e1")
      (should (equal (buffer-string) "one w two\n")))
    (should (equal (plist-get (car tandem-test--answers) :outcome) "error"))
    (should (string-match-p "changed in Emacs" (plist-get (car tandem-test--answers) :message)))))

(ert-deftest tandem-review-a-stale-buffer-follows-the-disk-first ()
  (tandem-test-with-file "one x two\n"
    (find-file-noselect file)
    (sleep-for 0.01)
    (with-temp-file file (insert "one q two\n"))
    (set-file-times file (time-add nil 2))
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "q" :newString "r")
    (should (tandem-review-pending-p "e1"))
    (tandem-review-apply "e1")
    (should (equal (tandem-test--disk file) "one r two\n"))))

(ert-deftest tandem-review-withdraw-removes-the-proposal ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (tandem-review--withdraw '(:requestId "e1" :reason "The user stopped the turn."))
    (with-current-buffer (find-buffer-visiting file)
      (should-not (overlays-in (point-min) (point-max)))
      (goto-char 6)
      (insert "z"))
    (should-not (tandem-review-pending-p "e1"))
    (should-not tandem-test--answers)))

(ert-deftest tandem-review-killing-the-buffer-rejects ()
  (tandem-test-with-file "one x two\n"
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (kill-buffer (find-buffer-visiting file))
    (should (equal (car tandem-test--answers)
                   '(:requestId "e1" :outcome "rejected" :message "The user closed the buffer."
                                :saved :json-false :created :json-false)))))

(defvar tandem-test--pwned nil "Set by a file-local eval the tests must never run.")

(ert-deftest tandem-review-file-local-eval-never-runs ()
  (tandem-test-with-file "x\n;; Local Variables:\n;; eval: (setq tandem-test--pwned t)\n;; End:\n"
    (setq tandem-test--pwned nil)
    (tandem-test--propose "e1" :kind "edit" :filePath file :oldString "x\n" :newString "y\n")
    (should (tandem-review-pending-p "e1"))
    (should-not tandem-test--pwned)))

;;;; The chat's edit block

(ert-deftest tandem-review-the-chat-block ()
  (tandem-test-with-chat
    (let (calls)
      (cl-letf (((symbol-function 'tandem-review-pending-p) (lambda (_id) t))
                ((symbol-function 'tandem-review-apply) (lambda (id) (push (list 'apply id) calls)))
                ((symbol-function 'tandem-review-reject) (lambda (id r) (push (list 'reject id r) calls)))
                ((symbol-function 'read-string) (lambda (&rest _) "too broad")))
        (tandem-test--feed '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit"
                                        :relPath "src/a.txt"))
        (should (string-match-p "  ✎ Claude wants to edit src/a\\.txt\n    y apply   n reject   d reject with a reason   RET show\n"
                                (tandem-test--transcript)))
        (should (equal tandem-chat--state "reviewing"))
        (should (string-match-p "waiting for your review" (tandem-chat--header-line)))
        (goto-char (point-min))
        (search-forward "Claude wants to edit")
        (should (eq (lookup-key (get-text-property (point) 'keymap) "y") #'tandem-chat-apply-edit))
        (tandem-chat-apply-edit)
        (tandem-chat-reject-edit-with-reason)
        (should (equal (nreverse calls) '((apply "e1") (reject "e1" "too broad"))))
        (tandem-test--feed '(:kind "edit" :state "rejected" :requestId "e1" :message "too broad")))
      (dolist (case '(((:state "applied" :saved t) "✓ Applied and saved")
                      ((:state "applied" :saved :json-false) "✓ Applied, not saved: the buffer has unsaved changes of yours")
                      ((:state "applied" :saved t :created t) "✓ Created and saved")
                      ((:state "rejected" :message "too broad") "✗ Rejected: too broad")
                      ((:state "error" :message "String to replace not found in file.\nString: q")
                       "✗ Not applied: String to replace not found in file\\.")
                      ((:state "withdrawn" :reason "The user stopped the turn.") "Withdrawn: The user stopped the turn\\.")))
        (let ((id (format "e%d" (random 100000))))
          (tandem-test--feed (list :kind "edit" :state "pending" :requestId id :editKind "edit" :relPath "a"))
          (tandem-test--feed (append (list :kind "edit" :requestId id) (car case)))
          (should (string-match-p (cadr case) (tandem-test--transcript)))))
      (should (equal tandem-chat--state "running")))))

;;;; For real, through the daemon, the MCP helper and the fake claude

(ert-deftest tandem-review-apply-for-real ()
  (tandem-test-with-edit-project
    (tandem-test--send buffer (tandem-test--edit-prompt '(:file "a.txt" :old "x" :new "y")))
    (tandem-review-apply (tandem-test--wait-proposal))
    (tandem-test--wait-idle buffer)
    (should (equal (tandem-test--disk (expand-file-name "a.txt" project)) "one y two\n"))
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "✎ Claude wants to edit a\\.txt\n    ✓ Applied and saved\n" text))
        (should-not (let ((case-fold-search nil)) (string-match-p "Edit a\\.txt" text)))
        (should (string-match-p "edit result: The user applied the edit to a\\.txt in Emacs, and it is saved\\." text))))))

(ert-deftest tandem-review-reject-for-real ()
  (tandem-test-with-edit-project
    (tandem-test--send buffer (tandem-test--edit-prompt '(:file "a.txt" :old "x" :new "y")))
    (tandem-review-reject (tandem-test--wait-proposal) "keep x")
    (tandem-test--wait-idle buffer)
    (should (equal (tandem-test--disk (expand-file-name "a.txt" project)) "one x two\n"))
    (with-current-buffer buffer
      (should (string-match-p "Their note: keep x" (tandem-test--transcript))))))

(ert-deftest tandem-review-a-bad-edit-for-real ()
  (tandem-test-with-edit-project
    (tandem-test--say buffer (tandem-test--edit-prompt '(:file "a.txt" :old "nope" :new "y")))
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "✗ Not applied: String to replace not found in file\\." text))
        (should (string-match-p "edit result: String to replace not found in file\\.\nString: nope" text))))))

(ert-deftest tandem-review-an-edit-shows-once-in-the-chat ()
  (tandem-test-with-chat
    (cl-letf (((symbol-function 'tandem-review-pending-p) (lambda (_id) t)))
      (tandem-test--feed
       '(:kind "tool" :id "t1" :name "mcp__emacs__edit_file" :title "Edit a.txt" :status "started")
       '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit" :relPath "a.txt")
       '(:kind "edit" :state "applied" :requestId "e1" :saved t)
       '(:kind "tool" :id "t1" :name "mcp__emacs__edit_file" :title "Edit a.txt" :status "done" :durationMs 4000)
       ;; Refused before any block: the tool line is all there is.
       '(:kind "tool" :id "t2" :name "mcp__emacs__edit_file" :title "Edit /etc/hosts" :status "started")
       '(:kind "tool" :id "t2" :name "mcp__emacs__edit_file" :title "Edit /etc/hosts" :status "error" :durationMs 3)))
    (let ((text (tandem-test--transcript))
          (case-fold-search nil))
      (should-not (string-match-p "Edit a\\.txt" text))
      (should (string-match-p "✎ Claude wants to edit a\\.txt\n    ✓ Applied and saved\n" text))
      (should (string-match-p "^  ✗ Edit /etc/hosts$" text)))
    (should (equal tandem-chat--state "running"))))

(ert-deftest tandem-review-cancel-for-real ()
  (tandem-test-with-edit-project
    (tandem-test--send buffer (tandem-test--edit-prompt '(:file "a.txt" :old "x" :new "y")))
    (tandem-test--wait-proposal)
    (with-current-buffer buffer (tandem-chat-cancel))
    (tandem-test--wait-idle buffer)
    (should (tandem-test--wait-for
             (lambda () (zerop (hash-table-count tandem-review--proposals))) 5))
    (with-current-buffer (find-buffer-visiting (expand-file-name "a.txt" project))
      (should-not (overlays-in (point-min) (point-max))))
    (with-current-buffer buffer
      (should (string-match-p "Withdrawn: The user stopped the turn\\." (tandem-test--transcript))))))

(provide 'tandem-review-tests)
;;; tandem-review-tests.el ends here
