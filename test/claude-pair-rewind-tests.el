;;; claude-pair-rewind-tests.el --- Tests for going back to an earlier turn  -*- lexical-binding: t; -*-

;;; Commentary:

;; Checkpoints of the files Claude changes, and rewinding files and
;; conversation, through the daemon and the fake claude, which keeps
;; transcripts with branches as Claude Code does.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defmacro claude-pair-test-with-rewind-project (&rest body)
  "Run BODY in an edit project whose transcripts go to a private dir."
  (declare (indent 0) (debug t))
  `(let* ((config (claude-pair-test--private-dir))
          (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment))
          (claude-pair-rewind--checkpoints (make-hash-table :test #'equal)))
     (unwind-protect
         (claude-pair-test-with-edit-project ,@body)
       (delete-directory config t))))

(defun claude-pair-test--edit-turn (buffer prompt)
  "Send PROMPT, an edit, from BUFFER; apply it; wait for the turn's end."
  (claude-pair-test--send buffer prompt)
  (claude-pair-review-apply (claude-pair-test--wait-proposal))
  (claude-pair-test--wait-idle buffer))

(defun claude-pair-test--rewind-to (n)
  "Rewind the current chat to before message N, saying yes."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (_prompt table &rest _)
               (seq-find (lambda (c) (string-prefix-p (format "%d. " n) c)) (all-completions "" table))))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
            ((symbol-function 'claude-pair-chat--display) #'identity))
    ;; As you would: /rewind in the composer.
    (goto-char (point-max))
    (insert "/rewind")
    (claude-pair-chat-send)))

(ert-deftest claude-pair-rewind-files-and-conversation ()
  (claude-pair-test-with-rewind-project
    (let ((a (expand-file-name "a.txt" project))
          (b (expand-file-name "b.txt" project))
          (second (claude-pair-test--edit-prompt '(:file "a.txt" :old "x" :new "y"))))
      (claude-pair-test--say buffer "first")
      (claude-pair-test--edit-turn buffer second)
      (claude-pair-test--edit-turn
       buffer (concat "script:write:" (json-serialize '(:file "b.txt" :content "new\n"))))
      (should (equal (claude-pair-test--disk a) "one y two\n"))
      (should (file-exists-p b))
      (with-current-buffer buffer
        (claude-pair-test--rewind-to 2)
        ;; The files are back: a.txt's change undone, b.txt gone.
        (should (equal (claude-pair-test--disk a) "one x two\n"))
        (should-not (file-exists-p b))
        (let ((text (claude-pair-test--transcript)))
          (should (string-match-p "You\nfirst\n\nClaude\nYou said: first" text))
          (should-not (string-match-p "script:edit" text))
          (should (string-match-p "Went back to before message 2\\.  Restored: a\\.txt, b\\.txt\\." text)))
        ;; Your message waits in the composer, to change and send again.
        (should (equal (claude-pair-chat--input-text) second))
        (claude-pair-chat--set-input ""))
      ;; Claude goes on from there; message 2 and 3 are forgotten.
      (claude-pair-test--say buffer "after")
      (let ((texts (seq-keep (lambda (e) (and (equal (plist-get e :kind) "user") (plist-get e :text)))
                             (plist-get (claude-pair-rpc-request
                                         'session/history
                                         (list :sessionId (buffer-local-value 'claude-pair-chat--session-id buffer)))
                                        :history))))
        (should (equal texts '("first" "after"))))
      ;; Checkpoints of the forgotten turns are gone.
      (should-not (claude-pair-rewind--since
                   (buffer-local-value 'claude-pair-chat--session-id buffer) nil)))))

(ert-deftest claude-pair-rewind-to-before-the-first-message ()
  (claude-pair-test-with-rewind-project
    (let ((a (expand-file-name "a.txt" project))
          (old buffer)
          (old-id (buffer-local-value 'claude-pair-chat--session-id buffer))
          (prompt (claude-pair-test--edit-prompt '(:file "a.txt" :old "x" :new "y"))))
      (claude-pair-test--edit-turn buffer prompt)
      (with-current-buffer buffer
        (claude-pair-test--rewind-to 1))
      (should (equal (claude-pair-test--disk a) "one x two\n"))
      (should-not (buffer-live-p old))
      (setq buffer (gethash (car (seq-remove (lambda (id) (equal id old-id))
                                             (hash-table-keys claude-pair-chat--buffers)))
                            claude-pair-chat--buffers))
      (with-current-buffer buffer
        (should (string-match-p "Went back to before message 1\\.  Restored: a\\.txt\\."
                                (claude-pair-test--transcript)))
        (should (equal (claude-pair-chat--input-text) prompt))))))

(ert-deftest claude-pair-rewind-from-the-chat-with-slash ()
  (let (ran)
    (cl-letf (((symbol-function 'claude-pair-rewind) (lambda () (interactive) (setq ran t))))
      (with-temp-buffer
        (should (claude-pair-rewind--send "/rewind"))
        (should-not (claude-pair-rewind--send "/rewinding"))))
    (should ran)))

(ert-deftest claude-pair-rewind-checkpoints-once-per-file-and-turn ()
  (let ((claude-pair-rewind--checkpoints (make-hash-table :test #'equal))
        (claude-pair-chat--buffers (make-hash-table :test #'equal))
        (dir (claude-pair-test--private-dir)))
    (unwind-protect
        (let ((path (expand-file-name "f.txt" dir)))
          (with-temp-buffer
            (insert "v1")
            (let ((proposal (list :session "s" :path path)))
              (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 10.0)))
                (claude-pair-rewind--keep proposal)
                (erase-buffer) (insert "v2")
                ;; The same turn: the first text is what counts.
                (claude-pair-rewind--keep proposal))
              (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 20.0)))
                (claude-pair-rewind--keep proposal))))
          (should (equal (mapcar (lambda (cp) (plist-get cp :text)) (gethash "s" claude-pair-rewind--checkpoints))
                         '("v2" "v1")))
          ;; Back to before the first turn: its text; before the second: the second's.
          (should (equal (plist-get (car (claude-pair-rewind--since "s" nil)) :text) "v1"))
          (should (equal (plist-get (car (claude-pair-rewind--since "s" 15.0)) :text) "v2"))
          (should-not (claude-pair-rewind--since "s" 25.0)))
      (delete-directory dir t))))

(provide 'claude-pair-rewind-tests)
;;; claude-pair-rewind-tests.el ends here
