;;; claude-pair-slash-tests.el --- Tests for slash commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; Completing slash commands, running Claude Code's, and claude-pair's own
;; /clear and /resume, through the daemon and the fake claude.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defun claude-pair-test--commands-loaded (buffer)
  "Wait until BUFFER has its slash commands; return them."
  (claude-pair-test--wait-for
   (lambda () (buffer-local-value 'claude-pair-slash--commands buffer)) 10)
  (buffer-local-value 'claude-pair-slash--commands buffer))

(ert-deftest claude-pair-slash-completion ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (should (equal (mapcar (lambda (c) (plist-get c :name)) (claude-pair-test--commands-loaded buffer))
                   '("compact" "clear" "greet")))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "/gr")
      (let ((capf (claude-pair-slash-capf)))
        (should capf)
        (should (equal (buffer-substring-no-properties (nth 0 capf) (nth 1 capf)) "gr"))
        (let ((all (all-completions "" (nth 2 capf))))
          ;; claude-pair's own first; /clear once.
          (should (equal all '("clear" "resume" "compact" "greet"))))
        (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function) "greet")
                       " NAME   Greet someone by name (project)"))
        (should (string-match-p "this one stays in claude-pair-resume"
                                (funcall (plist-get (nthcdr 3 capf) :annotation-function) "clear")))
        ;; Completing a command that takes an argument adds a space.
        (completion-in-region (nth 0 capf) (nth 1 capf) (nth 2 capf))
        (funcall (plist-get (nthcdr 3 capf) :exit-function) "greet" 'finished)
        (should (equal (claude-pair-chat--input-text) "/greet ")))
      ;; Not after the start of the message.
      (claude-pair-chat--set-input "see /gr")
      (should-not (claude-pair-slash-capf))
      (claude-pair-chat--set-input ""))))

(ert-deftest claude-pair-slash-claude-codes-commands-run ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "/greet Bob")
    (claude-pair-test--say buffer "/compact")
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "You\n/greet Bob\n\nClaude\nRan /greet with Bob" text))
        (should (string-match-p "You\n/compact\n\nClaude\nCompacted\n" text))))))

(ert-deftest claude-pair-slash-clear-starts-a-new-chat ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "script:hello")
    (let ((old buffer)
          (old-id (buffer-local-value 'claude-pair-chat--session-id buffer))
          sent)
      (with-current-buffer old
        (goto-char (point-max))
        (insert "/clear")
        (cl-letf (((symbol-function 'claude-pair-chat--send-to-claude) (lambda (text) (setq sent text))))
          (claude-pair-chat-send)))
      (should-not sent)
      (should-not (buffer-live-p old))
      (setq buffer (claude-pair))
      (with-current-buffer buffer
        (should-not (equal claude-pair-chat--session-id old-id))
        (should (string-match-p "New chat\\.  The earlier one is in M-x claude-pair-resume\\."
                                (claude-pair-test--transcript)))
        (should-not (string-match-p "Hello" (claude-pair-test--transcript)))))))

(ert-deftest claude-pair-slash-resume-and-aliases-stay-here ()
  (let (ran)
    (cl-letf (((symbol-function 'claude-pair-slash--clear) (lambda () (push 'clear ran)))
              ((symbol-function 'claude-pair-resume) (lambda () (interactive) (push 'resume ran))))
      (should (claude-pair-slash--send "/new"))
      (should (claude-pair-slash--send "/reset"))
      (should (claude-pair-slash--send "/resume"))
      (should-not (claude-pair-slash--send "/compact"))
      (should-not (claude-pair-slash--send "/clearly not"))
      (should-not (claude-pair-slash--send "say /clear")))
    (should (equal ran '(resume clear clear)))))

(provide 'claude-pair-slash-tests)
;;; claude-pair-slash-tests.el ends here
