;;; tandem-rewind-tests.el --- Tests for going back to an earlier turn  -*- lexical-binding: t; -*-

;;; Commentary:

;; Checkpoints of the files Claude changes, and rewinding files and
;; conversation, through the daemon and the fake claude, which keeps
;; transcripts with branches as Claude Code does.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-rewind-project (&rest body)
  "Run BODY in an edit project whose transcripts go to a private dir."
  (declare (indent 0) (debug t))
  `(let* ((config (tandem-test--private-dir))
          (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment))
          (tandem-rewind--checkpoints (make-hash-table :test #'equal)))
     (unwind-protect
         (tandem-test-with-edit-project ,@body)
       (delete-directory config t))))

(defun tandem-test--edit-turn (buffer prompt)
  "Send PROMPT, an edit, from BUFFER; apply it; wait for the turn's end."
  (tandem-test--send buffer prompt)
  (tandem-review-apply (tandem-test--wait-proposal))
  (tandem-test--wait-idle buffer))

(defun tandem-test--rewind-to (n)
  "Rewind the current chat to before message N, saying yes."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt table &rest _)
               (seq-find (lambda (c) (string-prefix-p (format "%d. " n) c)) (all-completions "" table))))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
            ((symbol-function 'tandem-chat--display) #'identity))
    ;; As you would: /rewind in the composer.
    (goto-char (point-max))
    (insert "/rewind")
    (tandem-chat-send)))

(ert-deftest tandem-rewind-files-and-conversation ()
  (tandem-test-with-rewind-project
    (let ((a (expand-file-name "a.txt" project))
          (b (expand-file-name "b.txt" project))
          (second (tandem-test--edit-prompt '(:file "a.txt" :old "x" :new "y"))))
      (tandem-test--say buffer "first")
      (tandem-test--edit-turn buffer second)
      (tandem-test--edit-turn
       buffer (concat "script:write:" (json-serialize '(:file "b.txt" :content "new\n"))))
      (should (equal (tandem-test--disk a) "one y two\n"))
      (should (file-exists-p b))
      (with-current-buffer buffer
        (tandem-test--rewind-to 2)
        ;; The files are back: a.txt's change undone, b.txt gone.
        (should (equal (tandem-test--disk a) "one x two\n"))
        (should-not (file-exists-p b))
        (let ((text (tandem-test--transcript)))
          (should (string-match-p "You\nfirst\n\nClaude\nYou said: first" text))
          (should-not (string-match-p "script:edit" text))
          (should (string-match-p "Went back to before message 2\\.  Restored: a\\.txt, b\\.txt\\." text)))
        ;; Your message waits in the composer, to change and send again.
        (should (equal (tandem-chat--input-text) second))
        (tandem-chat--set-input ""))
      ;; Claude goes on from there; message 2 and 3 are forgotten.
      (tandem-test--say buffer "after")
      (let ((texts (seq-keep (lambda (e) (and (equal (plist-get e :kind) "user") (plist-get e :text)))
                             (plist-get (tandem-rpc-request
                                         'session/history
                                         (list :sessionId (buffer-local-value 'tandem-chat--session-id buffer)))
                                        :history))))
        (should (equal texts '("first" "after"))))
      ;; Checkpoints of the forgotten turns are gone.
      (should-not (tandem-rewind--since
                   (buffer-local-value 'tandem-chat--session-id buffer) nil)))))

(ert-deftest tandem-rewind-to-before-the-first-message ()
  (tandem-test-with-rewind-project
    (let ((a (expand-file-name "a.txt" project))
          (old buffer)
          (old-id (buffer-local-value 'tandem-chat--session-id buffer))
          (prompt (tandem-test--edit-prompt '(:file "a.txt" :old "x" :new "y"))))
      (tandem-test--edit-turn buffer prompt)
      (with-current-buffer buffer
        (tandem-test--rewind-to 1))
      (should (equal (tandem-test--disk a) "one x two\n"))
      (should-not (buffer-live-p old))
      (setq buffer (gethash (car (seq-remove (lambda (id) (equal id old-id))
                                             (hash-table-keys tandem-chat--buffers)))
                            tandem-chat--buffers))
      (with-current-buffer buffer
        (should (string-match-p "Went back to before message 1\\.  Restored: a\\.txt\\."
                                (tandem-test--transcript)))
        (should (equal (tandem-chat--input-text) prompt))))))

(ert-deftest tandem-rewind-from-the-chat-with-slash ()
  (let (ran)
    (cl-letf (((symbol-function 'tandem-rewind) (lambda () (interactive) (setq ran t))))
      (with-temp-buffer
        (should (tandem-rewind--send "/rewind"))
        (should-not (tandem-rewind--send "/rewinding"))))
    (should ran)))

(ert-deftest tandem-rewind-checkpoints-once-per-file-and-turn ()
  (let ((tandem-rewind--checkpoints (make-hash-table :test #'equal))
        (tandem-chat--buffers (make-hash-table :test #'equal))
        (dir (tandem-test--private-dir)))
    (unwind-protect
        (let ((path (expand-file-name "f.txt" dir)))
          (with-temp-buffer
            (insert "v1")
            (let ((proposal (list :session "s" :path path)))
              (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 10.0)))
                (tandem-rewind--keep proposal)
                (erase-buffer) (insert "v2")
                ;; The same turn: the first text is what counts.
                (tandem-rewind--keep proposal))
              (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 20.0)))
                (tandem-rewind--keep proposal))))
          (should (equal (mapcar (lambda (cp) (plist-get cp :text)) (gethash "s" tandem-rewind--checkpoints))
                         '("v2" "v1")))
          ;; Back to before the first turn: its text; before the second: the second's.
          (should (equal (plist-get (car (tandem-rewind--since "s" nil)) :text) "v1"))
          (should (equal (plist-get (car (tandem-rewind--since "s" 15.0)) :text) "v2"))
          (should-not (tandem-rewind--since "s" 25.0)))
      (delete-directory dir t))))

(provide 'tandem-rewind-tests)
;;; tandem-rewind-tests.el ends here
