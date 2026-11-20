;;; claude-pair-review-tests.el --- Tests for reviewing Claude's edits  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group feeds proposals straight to the review code, with the
;; daemon replaced by a recorder of edit/answer calls.  The second runs
;; edits for real: the fake claude calls edit_file through the daemon's MCP
;; helper, and the proposal appears in a real file buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

;;;; Proposals, without a daemon

(ert-deftest claude-pair-review-the-new-text-is-real-text-and-the-file-is-untouched ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (let ((buffer (find-buffer-visiting file)))
      (with-current-buffer buffer
        (should (equal (buffer-string) "one xy two\n"))
        (should-not (buffer-modified-p))
        (should (equal (claude-pair-test--disk file) "one x two\n"))
        (let ((faces (mapcar (lambda (ov) (list (overlay-get ov 'face)
                                                (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))
                             (seq-filter (lambda (ov) (overlay-get ov 'face))
                                         (overlays-in (point-min) (point-max))))))
          (should (member '(claude-pair-review-removed "x") faces))
          (should (member '(claude-pair-review-added "y") faces)))
        (should (string-match-p "Claude proposes an edit"
                                (overlay-get (claude-pair-test--overlay-with 'before-string buffer)
                                             'before-string)))
        (goto-char 6)
        (should (looking-at "y two"))
        (should (equal (get-char-property (point) 'claude-pair-proposal) "e1"))
        (should (claude-pair-review-pending-p "e1"))
        (should-not claude-pair-test--answers)
        (claude-pair-review-reject "e1" "")
        (should (equal (buffer-string) "one x two\n"))
        (should-not (buffer-modified-p))))))

(ert-deftest claude-pair-review-a-long-proposal-can-be-scrolled-and-read ()
  (claude-pair-test-with-file ""
    (let ((new (expand-file-name "long.txt" (file-name-directory file)))
          (content (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 200) "")))
      (claude-pair-test--propose "e1" :kind "write" :filePath new :content content)
      (with-current-buffer (find-buffer-visiting new)
        (should (= (count-lines (point-min) (point-max)) 200))
        (goto-char (point-min))
        (forward-line 149)
        (should (looking-at "line 150$"))
        (should (= (line-number-at-pos) 150))
        (should-not (buffer-modified-p))
        (should-not (file-exists-p new))
        (claude-pair-review-apply "e1")
        (should (equal (claude-pair-test--disk new) content))))))

(ert-deftest claude-pair-review-the-proposed-texts-are-locked ()
  (claude-pair-test-with-file "one xy two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "xy" :newString "qr")
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
      (claude-pair-review-reject "e1" "")
      (should (equal (buffer-string) "typed one xy! two\n"))
      (should (buffer-modified-p)))))

(ert-deftest claude-pair-review-saving-writes-only-your-text ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (let (seen)
        ;; A save hook (a formatter, say) sees your text alone.
        (add-hook 'before-save-hook (lambda () (setq seen (buffer-string))) nil t)
        (goto-char (point-max))
        (insert "mine\n")
        (let ((save-silently t)) (save-buffer))
        (should (equal seen "one x two\nmine\n")))
      (should (equal (claude-pair-test--disk file) "one x two\nmine\n"))
      (should (equal (buffer-string) "one xy two\nmine\n"))
      (should-not (buffer-modified-p))
      (should (claude-pair-review-pending-p "e1"))
      (should (get-text-property 5 'read-only))
      (should (get-text-property 6 'read-only))
      (goto-char 6)
      (should-error (delete-char 1) :type 'text-read-only)
      (claude-pair-review-apply "e1")
      (should (equal (claude-pair-test--disk file) "one y two\nmine\n"))
      (should (eq (plist-get (car claude-pair-test--answers) :saved) t)))))

(ert-deftest claude-pair-review-changing-major-mode-keeps-saving-safe ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (text-mode)
      (goto-char (point-max))
      (insert "mine\n")
      (let ((save-silently t)) (save-buffer))
      (should (equal (claude-pair-test--disk file) "one x two\nmine\n"))
      (should (equal (buffer-string) "one xy two\nmine\n")))))

(ert-deftest claude-pair-review-reverting-drops-the-proposal ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (with-temp-file file (insert "changed on disk\n"))
      (revert-buffer t t t)
      (should (equal (buffer-string) "changed on disk\n"))
      (should-not (claude-pair-review-pending-p "e1"))
      (should-not (overlays-in (point-min) (point-max)))
      (should (equal (plist-get (car claude-pair-test--answers) :outcome) "error"))
      (should (string-match-p "reloaded from disk"
                              (plist-get (car claude-pair-test--answers) :message))))))

(ert-deftest claude-pair-review-two-proposals-in-one-buffer ()
  (claude-pair-test-with-file "one x two\nthree\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    ;; Checked against your text: e1's "y" is not seen as part of the file.
    (claude-pair-test--propose "e2" :kind "edit" :filePath file :oldString "three\n" :newString "y\n")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "one xy two\nthree\ny\n"))
      (should-not (buffer-modified-p))
      (should (claude-pair-review-pending-p "e2"))
      ;; Applying e1 saves it, without e2's text.
      (claude-pair-review-apply "e1")
      (should (equal (claude-pair-test--disk file) "one y two\nthree\n"))
      (should (equal (buffer-string) "one y two\nthree\ny\n"))
      (should-not (buffer-modified-p))
      (claude-pair-review-reject "e2" "")
      (should (equal (buffer-string) "one y two\nthree\n"))
      (should-not (buffer-modified-p)))))

(ert-deftest claude-pair-review-overlapping-proposals-are-refused ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x two" :newString "y")
    (claude-pair-test--propose "e2" :kind "edit" :filePath file :oldString "one x" :newString "z")
    (should-not (claude-pair-review-pending-p "e2"))
    (should (string-match-p "Another edit to the same text"
                            (plist-get (car claude-pair-test--answers) :message)))
    (should (claude-pair-review-pending-p "e1"))))

(ert-deftest claude-pair-review-your-undo-history-is-untouched ()
  (claude-pair-test-with-file "one x two\n"
    (with-current-buffer (find-file-noselect file)
      (buffer-enable-undo)
      (goto-char (point-min))
      (insert "AAA")
      (undo-boundary))
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (goto-char (point-max))
      (insert "BBB")
      (undo-boundary)
      (claude-pair-review-reject "e1" "")
      (should (equal (buffer-string) "AAAone x two\nBBB"))
      (let ((last-command nil)) (undo 2))
      (should (equal (buffer-string) "one x two\n")))))

(ert-deftest claude-pair-review-no-lock-file-while-proposing ()
  (claude-pair-test-with-file "one x two\n"
    (let ((create-lockfiles t))
      (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
      (should-not (file-symlink-p (expand-file-name ".#a.txt" (file-name-directory file))))
      (should-not (file-exists-p (expand-file-name ".#a.txt" (file-name-directory file)))))))

(ert-deftest claude-pair-review-write-creates-a-new-file ()
  (claude-pair-test-with-file ""
    (let ((new (expand-file-name "sub/dir/b.txt" (file-name-directory file))))
      (claude-pair-test--propose "e1" :kind "write" :filePath new :content "hello\nworld\n")
      (let ((buffer (find-buffer-visiting new)))
        (with-current-buffer buffer
          (should (equal (buffer-string) "hello\nworld\n"))
          (should-not (buffer-modified-p)))
        (should (string-match-p "this new file"
                                (overlay-get (claude-pair-test--overlay-with 'before-string buffer)
                                             'before-string)))
        (claude-pair-review-apply "e1")
        (should (equal (claude-pair-test--disk new) "hello\nworld\n"))
        (should (equal (car claude-pair-test--answers)
                       '(:requestId "e1" :outcome "applied" :message "" :saved t :created t)))))))

(ert-deftest claude-pair-review-write-shows-only-the-changed-lines ()
  (claude-pair-test-with-file "a\nb\nc\nd\n"
    (claude-pair-test--propose "e1" :kind "write" :filePath file :content "a\nB\nc\nd\n")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "a\nb\nB\nc\nd\n"))
      (let ((faces (mapcar (lambda (ov) (list (overlay-get ov 'face)
                                              (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))
                           (seq-filter (lambda (ov) (overlay-get ov 'face))
                                       (overlays-in (point-min) (point-max))))))
        (should (member '(claude-pair-review-removed "b\n") faces))
        (should (member '(claude-pair-review-added "B\n") faces)))
      (claude-pair-review-apply "e1")
      (should (equal (buffer-string) "a\nB\nc\nd\n")))))

(ert-deftest claude-pair-review-a-read-only-buffer-is-reported ()
  (claude-pair-test-with-file "one x two\n"
    (with-current-buffer (find-file-noselect file) (setq buffer-read-only t))
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (should (equal (plist-get (car claude-pair-test--answers) :outcome) "error"))
    (should (string-match-p "read-only in Emacs" (plist-get (car claude-pair-test--answers) :message)))))

(ert-deftest claude-pair-review-a-failure-while-applying-is-reported ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (cl-letf (((symbol-function 'claude-pair-review--replace) (lambda (&rest _) (error "Disk on fire"))))
      (claude-pair-review-apply "e1"))
    (should (equal (car claude-pair-test--answers)
                   '(:requestId "e1" :outcome "error" :message "Emacs could not apply the edit: Disk on fire"
                                :saved :json-false :created :json-false)))))

(ert-deftest claude-pair-review-apply-saves-and-is-one-undo-step ()
  (claude-pair-test-with-file "a x b x c\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "YY"
                               :replaceAll t)
    (with-current-buffer (find-buffer-visiting file)
      (undo-boundary)
      (claude-pair-review-apply "e1")
      (should (equal (buffer-string) "a YY b YY c\n"))
      (should (equal (claude-pair-test--disk file) "a YY b YY c\n"))
      (should-not (overlays-in (point-min) (point-max)))
      (should-not (text-property-any (point-min) (point-max) 'read-only
                                     claude-pair-review--locked-message))
      (should-not (claude-pair-review-pending-p "e1"))
      (should (equal claude-pair-test--answers
                     '((:requestId "e1" :outcome "applied" :message "" :saved t :created :json-false))))
      (undo-boundary)
      (let ((last-command nil)) (undo))
      (should (equal (buffer-string) "a x b x c\n")))))

(ert-deftest claude-pair-review-reject-leaves-the-file-alone ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (claude-pair-review-reject "e1" "keep x")
      (should (equal (buffer-string) "one x two\n"))
      (should-not (buffer-modified-p))
      (should-not (overlays-in (point-min) (point-max)))
      (goto-char 6)
      (insert "z")
      (should (equal claude-pair-test--answers
                     '((:requestId "e1" :outcome "rejected" :message "keep x" :saved :json-false
                                   :created :json-false)))))))

(ert-deftest claude-pair-review-errors-match-the-built-in-edit-tool ()
  (claude-pair-test-with-file "x and x\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "zzz" :newString "y")
    (claude-pair-test--propose "e2" :kind "edit" :filePath file :oldString "x" :newString "y")
    (claude-pair-test--propose "e3" :kind "edit" :filePath file :oldString "" :newString "y")
    (claude-pair-test--propose "e4" :kind "write" :filePath file :content "x and x\n")
    (let ((messages (mapcar (lambda (a) (plist-get a :message)) (reverse claude-pair-test--answers))))
      (should (equal (mapcar (lambda (a) (plist-get a :outcome)) claude-pair-test--answers)
                     '("error" "error" "error" "error")))
      (should (equal (nth 0 messages) "String to replace not found in file.\nString: zzz"))
      (should (string-prefix-p "Found 2 matches of the string to replace, but replace_all is false." (nth 1 messages)))
      (should (string-suffix-p "\nString: x" (nth 1 messages)))
      (should (equal (nth 2 messages) "Cannot create new file - file already exists."))
      (should (equal (nth 3 messages) "No changes to make: the file already has this content.")))
    (with-current-buffer (find-buffer-visiting file)
      (should-not (overlays-in (point-min) (point-max))))))

(ert-deftest claude-pair-review-your-unsaved-changes-are-never-saved ()
  (claude-pair-test-with-file "one x two\n"
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (insert "mine\n"))
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (claude-pair-review-apply "e1")
    (with-current-buffer (find-buffer-visiting file)
      (should (equal (buffer-string) "one y two\nmine\n"))
      (should (buffer-modified-p)))
    (should (equal (claude-pair-test--disk file) "one x two\n"))
    (should (eq (plist-get (car claude-pair-test--answers) :saved) :json-false))))

(ert-deftest claude-pair-review-typing-during-review-blocks-the-save ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (goto-char (point-max))
      (insert "mine\n"))
    (claude-pair-review-apply "e1")
    (should (equal (claude-pair-test--disk file) "one x two\n"))
    (should (eq (plist-get (car claude-pair-test--answers) :saved) :json-false))))

(ert-deftest claude-pair-review-text-changed-underneath-is-not-applied ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (with-current-buffer (find-buffer-visiting file)
      (let ((inhibit-read-only t))
        (goto-char 5)
        (delete-char 1)
        (insert "w"))
      (claude-pair-review-apply "e1")
      (should (equal (buffer-string) "one w two\n")))
    (should (equal (plist-get (car claude-pair-test--answers) :outcome) "error"))
    (should (string-match-p "changed in Emacs" (plist-get (car claude-pair-test--answers) :message)))))

(ert-deftest claude-pair-review-a-stale-buffer-follows-the-disk-first ()
  (claude-pair-test-with-file "one x two\n"
    (find-file-noselect file)
    (sleep-for 0.01)
    (with-temp-file file (insert "one q two\n"))
    (set-file-times file (time-add nil 2))
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "q" :newString "r")
    (should (claude-pair-review-pending-p "e1"))
    (claude-pair-review-apply "e1")
    (should (equal (claude-pair-test--disk file) "one r two\n"))))

(ert-deftest claude-pair-review-withdraw-removes-the-proposal ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (claude-pair-review--withdraw '(:requestId "e1" :reason "The user stopped the turn."))
    (with-current-buffer (find-buffer-visiting file)
      (should-not (overlays-in (point-min) (point-max)))
      (goto-char 6)
      (insert "z"))
    (should-not (claude-pair-review-pending-p "e1"))
    (should-not claude-pair-test--answers)))

(ert-deftest claude-pair-review-killing-the-buffer-rejects ()
  (claude-pair-test-with-file "one x two\n"
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x" :newString "y")
    (kill-buffer (find-buffer-visiting file))
    (should (equal (car claude-pair-test--answers)
                   '(:requestId "e1" :outcome "rejected" :message "The user closed the buffer."
                                :saved :json-false :created :json-false)))))

(defvar claude-pair-test--pwned nil "Set by a file-local eval the tests must never run.")

(ert-deftest claude-pair-review-file-local-eval-never-runs ()
  (claude-pair-test-with-file "x\n;; Local Variables:\n;; eval: (setq claude-pair-test--pwned t)\n;; End:\n"
    (setq claude-pair-test--pwned nil)
    (claude-pair-test--propose "e1" :kind "edit" :filePath file :oldString "x\n" :newString "y\n")
    (should (claude-pair-review-pending-p "e1"))
    (should-not claude-pair-test--pwned)))

;;;; The chat's edit block

(ert-deftest claude-pair-review-the-chat-block ()
  (claude-pair-test-with-chat
    (let (calls)
      (cl-letf (((symbol-function 'claude-pair-review-pending-p) (lambda (_id) t))
                ((symbol-function 'claude-pair-review-apply) (lambda (id) (push (list 'apply id) calls)))
                ((symbol-function 'claude-pair-review-reject) (lambda (id r) (push (list 'reject id r) calls)))
                ((symbol-function 'read-string) (lambda (&rest _) "too broad")))
        (claude-pair-test--feed '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit"
                                        :relPath "src/a.txt"))
        (should (string-match-p "  ✎ Claude wants to edit src/a\\.txt\n    y apply   n reject   d reject with a reason   RET show\n"
                                (claude-pair-test--transcript)))
        (should (equal claude-pair-chat--state "reviewing"))
        (should (string-match-p "waiting for your review" (claude-pair-chat--header-line)))
        (goto-char (point-min))
        (search-forward "Claude wants to edit")
        (should (eq (lookup-key (get-text-property (point) 'keymap) "y") #'claude-pair-chat-apply-edit))
        (claude-pair-chat-apply-edit)
        (claude-pair-chat-reject-edit-with-reason)
        (should (equal (nreverse calls) '((apply "e1") (reject "e1" "too broad"))))
        (claude-pair-test--feed '(:kind "edit" :state "rejected" :requestId "e1" :message "too broad")))
      (dolist (case '(((:state "applied" :saved t) "✓ Applied and saved")
                      ((:state "applied" :saved :json-false) "✓ Applied, not saved: the buffer has unsaved changes of yours")
                      ((:state "applied" :saved t :created t) "✓ Created and saved")
                      ((:state "rejected" :message "too broad") "✗ Rejected: too broad")
                      ((:state "error" :message "String to replace not found in file.\nString: q")
                       "✗ Not applied: String to replace not found in file\\.")
                      ((:state "withdrawn" :reason "The user stopped the turn.") "Withdrawn: The user stopped the turn\\.")))
        (let ((id (format "e%d" (random 100000))))
          (claude-pair-test--feed (list :kind "edit" :state "pending" :requestId id :editKind "edit" :relPath "a"))
          (claude-pair-test--feed (append (list :kind "edit" :requestId id) (car case)))
          (should (string-match-p (cadr case) (claude-pair-test--transcript)))))
      (should (equal claude-pair-chat--state "running")))))

;;;; For real, through the daemon, the MCP helper and the fake claude

(ert-deftest claude-pair-review-apply-for-real ()
  (claude-pair-test-with-edit-project
    (claude-pair-test--send buffer (claude-pair-test--edit-prompt '(:file "a.txt" :old "x" :new "y")))
    (claude-pair-review-apply (claude-pair-test--wait-proposal))
    (claude-pair-test--wait-idle buffer)
    (should (equal (claude-pair-test--disk (expand-file-name "a.txt" project)) "one y two\n"))
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "✎ Claude wants to edit a\\.txt\n    ✓ Applied and saved\n" text))
        (should-not (let ((case-fold-search nil)) (string-match-p "Edit a\\.txt" text)))
        (should (string-match-p "edit result: The user applied the edit to a\\.txt in Emacs, and it is saved\\." text))))))

(ert-deftest claude-pair-review-reject-for-real ()
  (claude-pair-test-with-edit-project
    (claude-pair-test--send buffer (claude-pair-test--edit-prompt '(:file "a.txt" :old "x" :new "y")))
    (claude-pair-review-reject (claude-pair-test--wait-proposal) "keep x")
    (claude-pair-test--wait-idle buffer)
    (should (equal (claude-pair-test--disk (expand-file-name "a.txt" project)) "one x two\n"))
    (with-current-buffer buffer
      (should (string-match-p "Their note: keep x" (claude-pair-test--transcript))))))

(ert-deftest claude-pair-review-a-bad-edit-for-real ()
  (claude-pair-test-with-edit-project
    (claude-pair-test--say buffer (claude-pair-test--edit-prompt '(:file "a.txt" :old "nope" :new "y")))
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "✗ Not applied: String to replace not found in file\\." text))
        (should (string-match-p "edit result: String to replace not found in file\\.\nString: nope" text))))))

(ert-deftest claude-pair-review-an-edit-shows-once-in-the-chat ()
  (claude-pair-test-with-chat
    (cl-letf (((symbol-function 'claude-pair-review-pending-p) (lambda (_id) t)))
      (claude-pair-test--feed
       '(:kind "tool" :id "t1" :name "mcp__emacs__edit_file" :title "Edit a.txt" :status "started")
       '(:kind "edit" :state "pending" :requestId "e1" :editKind "edit" :relPath "a.txt")
       '(:kind "edit" :state "applied" :requestId "e1" :saved t)
       '(:kind "tool" :id "t1" :name "mcp__emacs__edit_file" :title "Edit a.txt" :status "done" :durationMs 4000)
       ;; Refused before any block: the tool line is all there is.
       '(:kind "tool" :id "t2" :name "mcp__emacs__edit_file" :title "Edit /etc/hosts" :status "started")
       '(:kind "tool" :id "t2" :name "mcp__emacs__edit_file" :title "Edit /etc/hosts" :status "error" :durationMs 3)))
    (let ((text (claude-pair-test--transcript))
          (case-fold-search nil))
      (should-not (string-match-p "Edit a\\.txt" text))
      (should (string-match-p "✎ Claude wants to edit a\\.txt\n    ✓ Applied and saved\n" text))
      (should (string-match-p "^  ✗ Edit /etc/hosts$" text)))
    (should (equal claude-pair-chat--state "running"))))

(ert-deftest claude-pair-review-cancel-for-real ()
  (claude-pair-test-with-edit-project
    (claude-pair-test--send buffer (claude-pair-test--edit-prompt '(:file "a.txt" :old "x" :new "y")))
    (claude-pair-test--wait-proposal)
    (with-current-buffer buffer (claude-pair-chat-cancel))
    (claude-pair-test--wait-idle buffer)
    (should (claude-pair-test--wait-for
             (lambda () (zerop (hash-table-count claude-pair-review--proposals))) 5))
    (with-current-buffer (find-buffer-visiting (expand-file-name "a.txt" project))
      (should-not (overlays-in (point-min) (point-max))))
    (with-current-buffer buffer
      (should (string-match-p "Withdrawn: The user stopped the turn\\." (claude-pair-test--transcript))))))

(provide 'claude-pair-review-tests)
;;; claude-pair-review-tests.el ends here
