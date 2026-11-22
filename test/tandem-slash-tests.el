;;; tandem-slash-tests.el --- Tests for slash commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; Completing slash commands, running Claude Code's, and tandem's own
;; /clear and /resume, through the daemon and the fake claude.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defun tandem-test--commands-loaded (buffer)
  "Wait until BUFFER has its slash commands; return them."
  (tandem-test--wait-for
   (lambda () (buffer-local-value 'tandem-slash--commands buffer)) 10)
  (buffer-local-value 'tandem-slash--commands buffer))

(ert-deftest tandem-slash-completion ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (should (equal (mapcar (lambda (c) (plist-get c :name)) (tandem-test--commands-loaded buffer))
                   '("compact" "clear" "greet")))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "/gr")
      (let ((capf (tandem-slash-capf)))
        (should capf)
        (should (equal (buffer-substring-no-properties (nth 0 capf) (nth 1 capf)) "gr"))
        (let ((all (all-completions "" (nth 2 capf))))
          ;; tandem's own first; /clear once.
          (should (equal all '("clear" "resume" "rewind" "plan" "compact" "greet"))))
        (should (equal (funcall (plist-get (nthcdr 3 capf) :annotation-function) "greet")
                       " NAME   Greet someone by name (project)"))
        (should (string-match-p "this one stays in tandem-resume"
                                (funcall (plist-get (nthcdr 3 capf) :annotation-function) "clear")))
        ;; Completing a command that takes an argument adds a space.
        (completion-in-region (nth 0 capf) (nth 1 capf) (nth 2 capf))
        (funcall (plist-get (nthcdr 3 capf) :exit-function) "greet" 'finished)
        (should (equal (tandem-chat--input-text) "/greet ")))
      ;; Not after the start of the message.
      (tandem-chat--set-input "see /gr")
      (should-not (tandem-slash-capf))
      (tandem-chat--set-input ""))))

(ert-deftest tandem-slash-claude-codes-commands-run ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--say buffer "/greet Bob")
    (tandem-test--say buffer "/compact")
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "You\n/greet Bob\n\nClaude\nRan /greet with Bob" text))
        (should (string-match-p "You\n/compact\n\nClaude\nCompacted\n" text))))))

(ert-deftest tandem-slash-clear-starts-a-new-chat ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--say buffer "script:hello")
    (let ((old buffer)
          (old-id (buffer-local-value 'tandem-chat--session-id buffer))
          sent)
      (with-current-buffer old
        (goto-char (point-max))
        (insert "/clear")
        (cl-letf (((symbol-function 'tandem-chat--send-to-claude) (lambda (text) (setq sent text))))
          (tandem-chat-send)))
      (should-not sent)
      (should-not (buffer-live-p old))
      (setq buffer (tandem))
      (with-current-buffer buffer
        (should-not (equal tandem-chat--session-id old-id))
        (should (string-match-p "New chat\\.  The earlier one is in M-x tandem-resume\\."
                                (tandem-test--transcript)))
        (should-not (string-match-p "Hello" (tandem-test--transcript)))))))

(ert-deftest tandem-slash-resume-and-aliases-stay-here ()
  (let (ran)
    (cl-letf (((symbol-function 'tandem-slash--clear) (lambda () (push 'clear ran)))
              ((symbol-function 'tandem-resume) (lambda () (interactive) (push 'resume ran))))
      (should (tandem-slash--send "/new"))
      (should (tandem-slash--send "/reset"))
      (should (tandem-slash--send "/resume"))
      (should-not (tandem-slash--send "/compact"))
      (should-not (tandem-slash--send "/clearly not"))
      (should-not (tandem-slash--send "say /clear")))
    (should (equal ran '(resume clear clear)))))

(provide 'tandem-slash-tests)
;;; tandem-slash-tests.el ends here
