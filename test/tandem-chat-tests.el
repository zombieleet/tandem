;;; tandem-chat-tests.el --- Tests for the chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group drives a chat buffer with hand-made updates and needs no
;; daemon.  The second group runs whole conversations through a real daemon
;; and daemon/bin/fakeclaude, which replays scripted Claude Code output.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)


;;;; Drawing, without a daemon

(ert-deftest tandem-chat-text-is-batched-then-drawn ()
  (tandem-test-with-chat
    (tandem-chat--handle-update '(:kind "text" :delta "Hel"))
    (tandem-chat--handle-update '(:kind "text" :delta "lo wörld 🌍"))
    (should-not (string-match-p "Hel" (tandem-test--transcript)))
    (should tandem-chat--timer)
    (tandem-chat--flush)
    (should (string-match-p "Claude\nHello wörld 🌍" (tandem-test--transcript)))
    (should-not tandem-chat--timer)))

(ert-deftest tandem-chat-the-timer-draws-the-queue ()
  (tandem-test-with-chat
    (tandem-chat--handle-update '(:kind "text" :delta "soon"))
    (should (tandem-test--wait-for
             (lambda () (string-match-p "soon" (tandem-test--transcript)))
             2))))

(ert-deftest tandem-chat-transcript-is-read-only ()
  (tandem-test-with-chat
    (tandem-test--feed '(:kind "text" :delta "answer"))
    (dolist (pos (list (point-min) (1+ (point-min)) (1- tandem-chat--output)))
      (goto-char pos)
      (should-error (insert "x") :type 'text-read-only))
    (goto-char tandem-chat--output)
    (should-error (insert "x") :type 'text-read-only)
    (goto-char (1- tandem-chat--input))
    (should-error (insert "x") :type 'text-read-only)
    (goto-char (point-max))
    (insert "typed")
    (should (equal (tandem-chat--input-text) "typed"))))

(ert-deftest tandem-chat-tool-lines ()
  (tandem-test-with-chat
    (tandem-test--feed
     '(:kind "tool" :id "t1" :name "Read" :title "Read README.md" :status "started"))
    (should (string-match-p "^  ▸ Read README\\.md$" (tandem-test--transcript)))
    (should (equal tandem-chat--state "tool"))
    (should (string-match-p "running Read" (tandem-chat--header-line)))
    (tandem-test--feed
     '(:kind "tool" :id "t1" :name "Read" :title "Read README.md" :status "done" :durationMs 412)
     '(:kind "tool" :id "t2" :name "Bash" :title "Bash rm -rf x" :status "started")
     '(:kind "tool" :id "t2" :name "Bash" :title "Bash rm -rf x" :status "error" :durationMs 1500))
    (let ((text (tandem-test--transcript)))
      (should (string-match-p "^  ✓ Read README\\.md  412 ms$" text))
      (should (string-match-p "^  ✗ Bash rm -rf x  1\\.5 s$" text))
      (should-not (string-match-p "▸" text)))))

(ert-deftest tandem-chat-text-after-a-tool-starts-a-new-paragraph ()
  (tandem-test-with-chat
    (tandem-test--feed
     '(:kind "text" :delta "Let me look.")
     '(:kind "tool" :id "t1" :name "Read" :title "Read a" :status "started")
     '(:kind "tool" :id "t1" :name "Read" :title "Read a" :status "done" :durationMs 5)
     '(:kind "text" :delta "Found it."))
    (should (string-match-p "Let me look\\.\n  ✓ Read a  5 ms\n\nFound it\\." (tandem-test--transcript)))))

(ert-deftest tandem-chat-todo-list-sits-at-the-top ()
  (tandem-test-with-chat
    (tandem-test--feed '(:kind "text" :delta "Working."))
    (tandem-test--feed
     '(:kind "todo" :items [(:content "Read" :status "completed")
                            (:content "Write" :status "in_progress")
                            (:content "Test" :status "pending")]))
    (goto-char (point-min))
    (should (looking-at "Plan\n  ✓ Read\n  ▸ Write\n  ○ Test\n"))
    (tandem-test--feed '(:kind "todo" :items [(:content "Read" :status "completed")]))
    (goto-char (point-min))
    (should (looking-at "Plan\n  ✓ Read\n\nAsk Claude"))
    (should (string-match-p "Working\\." (tandem-test--transcript)))))

(ert-deftest tandem-chat-header-line ()
  (tandem-test-with-chat
    (should (string-match-p "Claude · ready" (tandem-chat--header-line)))
    (tandem-test--feed '(:kind "init" :model "claude-fake-1")
                            '(:kind "status" :state "running"))
    (should (string-match-p "claude-fake-1 · thinking…" (tandem-chat--header-line)))
    (tandem-test--feed '(:kind "result" :subtype "success" :costUsd 0.01 :sessionCostUsd 0.0123
                                    :durationMs 900 :cancelled :json-false :isError :json-false)
                            '(:kind "status" :state "idle"))
    (should (string-match-p "ready · \\$0\\.0123" (tandem-chat--header-line)))))

(ert-deftest tandem-chat-result-lines ()
  (tandem-test-with-chat
    (tandem-test--feed '(:kind "text" :delta "One.")
                            '(:kind "result" :subtype "success" :costUsd 0.0042 :durationMs 2300
                                    :cancelled :json-false :isError :json-false
                                    :permissionDenials ["Bash"]))
    (let ((text (tandem-test--transcript)))
      (should (string-match-p "^  2\\.3 s · \\$0\\.0042$" text))
      (should (string-match-p "Not allowed: Bash\\.  Claude Code denied it without asking you" text)))
    (tandem-test--feed '(:kind "text" :delta "Two.") '(:kind "result" :cancelled t))
    (should (string-match-p "Two\\.\n  Stopped\\.$" (tandem-test--transcript)))
    (tandem-test--feed '(:kind "result" :subtype "error_max_turns" :isError t :cancelled :json-false
                                    :message "Reached the maximum number of turns"))
    (should (string-match-p "Claude stopped: Reached the maximum number of turns"
                            (tandem-test--transcript)))))

(ert-deftest tandem-chat-error-lines-show-stderr ()
  (tandem-test-with-chat
    (tandem-test--feed '(:kind "error" :message "claude stopped unexpectedly (exit code 3)"
                                    :stderr "warming up\nfatal: something broke\n"))
    (let ((text (tandem-test--transcript)))
      (should (string-match-p "  claude stopped unexpectedly (exit code 3)\n" text))
      (should (string-match-p "    fatal: something broke\n" text)))))

(ert-deftest tandem-chat-send-uses-the-composer ()
  (tandem-test-with-chat
    (let (sent)
      (cl-letf (((symbol-function 'tandem-rpc-request)
                 (lambda (method params &optional _timeout)
                   (push (list method params) sent)
                   '(:ok t))))
        (goto-char (point-max))
        (insert "  What files are here?  ")
        (tandem-chat-send))
      (should (equal sent '((session/prompt (:sessionId "test-session" :text "What files are here?")))))
      (should (equal (tandem-chat--input-text) ""))
      (should (string-match-p "You\nWhat files are here\\?\n" (tandem-test--transcript)))
      (should (equal (ring-ref tandem-chat--history 0) "What files are here?"))
      (should (tandem-chat--busy-p)))))

(ert-deftest tandem-chat-send-refuses-empty-and-busy ()
  (tandem-test-with-chat
    (cl-letf (((symbol-function 'tandem-rpc-request)
               (lambda (&rest _) (error "Must not be called"))))
      (should-error (tandem-chat-send) :type 'user-error)
      (goto-char (point-max))
      (insert "hello")
      (setq tandem-chat--state "writing")
      (should-error (tandem-chat-send) :type 'user-error)
      (should (equal (tandem-chat--input-text) "hello")))))

(ert-deftest tandem-chat-a-failed-send-keeps-the-text ()
  (tandem-test-with-chat
    (cl-letf (((symbol-function 'tandem-rpc-request)
               (lambda (&rest _)
                 (signal 'jsonrpc-error '("request id=3 failed:"
                                          (jsonrpc-error-code . -32004)
                                          (jsonrpc-error-message . "no session \"test-session\""))))))
      (goto-char (point-max))
      (insert "hello")
      (tandem-chat-send)
      (should (equal (tandem-chat--input-text) "hello"))
      (should (equal tandem-chat--state "idle"))
      (should (string-match-p "Not sent: no session" (tandem-test--transcript))))))

(ert-deftest tandem-chat-history ()
  (tandem-test-with-chat
    (dolist (m '("first" "second" "third"))
      (ring-insert tandem-chat--history m))
    (tandem-chat-previous-input 1)
    (should (equal (tandem-chat--input-text) "third"))
    (tandem-chat-previous-input 1)
    (should (equal (tandem-chat--input-text) "second"))
    (tandem-chat-previous-input 5)
    (should (equal (tandem-chat--input-text) "first"))
    (tandem-chat-next-input 1)
    (should (equal (tandem-chat--input-text) "second"))
    (tandem-chat-next-input 2)
    (should (equal (tandem-chat--input-text) ""))))

(ert-deftest tandem-chat-undo-in-the-composer-survives-streaming ()
  (tandem-test-with-chat
    (goto-char (point-max))
    (insert "abc")
    (undo-boundary)
    (insert "def")
    (undo-boundary)
    (tandem-test--feed '(:kind "text" :delta "A long streamed answer ")
                            '(:kind "tool" :id "t" :name "Read" :title "Read x" :status "started")
                            '(:kind "tool" :id "t" :name "Read" :title "Read x" :status "done" :durationMs 7)
                            '(:kind "todo" :items [(:content "Step" :status "pending")]))
    (goto-char (point-max))
    (let ((last-command nil))
      (undo))
    (should (equal (tandem-chat--input-text) "abc"))
    (should (string-match-p "A long streamed answer" (tandem-test--transcript)))
    (should (string-match-p "✓ Read x" (tandem-test--transcript)))))

(ert-deftest tandem-chat-disconnect-is-shown ()
  (tandem-test-with-chat
    (setq tandem-chat--state "writing")
    (tandem-chat--on-disconnect)
    (tandem-chat--flush)
    (should (equal tandem-chat--state "disconnected"))
    (should-not (tandem-chat--busy-p))
    (should (string-match-p "Disconnected from tandemd" (tandem-test--transcript)))))

;;;; Whole conversations through the daemon and the fake claude

(ert-deftest tandem-chat-a-whole-conversation ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (should (eq (window-buffer (selected-window)) buffer))
    (tandem-test--say buffer "script:hello")
    (with-current-buffer buffer
      (should (string-match-p "You\nscript:hello\n\nClaude\nHello wörld 🌍\n  1\\.2 s · \\$0\\.0100\n"
                              (tandem-test--transcript)))
      (should (string-match-p "claude-fake-1 · ready · \\$0\\.0100" (tandem-chat--header-line))))
    (tandem-test--say buffer "a second question")
    (with-current-buffer buffer
      (should (string-match-p "You said: a second question" (tandem-test--transcript)))
      (should (string-match-p "\\$0\\.0200" (tandem-chat--header-line))))))

(ert-deftest tandem-chat-tools-in-a-real-session ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--say buffer "script:tools")
    (with-current-buffer buffer
      (let ((text (buffer-substring-no-properties (point-min) tandem-chat--output)))
        (should (string-match-p "^Plan\n  ✓ Read the README\n  ▸ Summarize it\n" text))
        (should (string-match-p "^  ✓ Read README\\.md  [0-9]+ ms$" text))
        (should (string-match-p "^  ✗ Bash rm -rf build …  [0-9]+ ms$" text))
        (should (string-match-p "Not allowed: Bash\\.  Claude Code denied it without asking you" text))))))

(ert-deftest tandem-chat-cancel-then-continue ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "script:slow")
      (tandem-chat-send))
    (should (tandem-test--wait-for
             (lambda () (with-current-buffer buffer
                          (string-match-p "\n3\n" (tandem-test--transcript))))
             10))
    (with-current-buffer buffer
      (tandem-chat-cancel))
    (tandem-test--wait-idle buffer)
    (with-current-buffer buffer
      (should (string-match-p "  Stopped\\.\n" (tandem-test--transcript))))
    (tandem-test--say buffer "script:args")
    (with-current-buffer buffer
      (should (string-match-p (concat "--resume " (regexp-quote tandem-chat--session-id))
                              (tandem-test--transcript))))))

(ert-deftest tandem-chat-same-project-same-buffer ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (should (eq (tandem) buffer))
    (let ((other (tandem t)))
      (unwind-protect
          (progn
            (should-not (eq other buffer))
            (should (eql (plist-get (tandem-daemon-status) :sessions) 2)))
        (kill-buffer other)))
    (should (eql (plist-get (tandem-daemon-status) :sessions) 1))))

(ert-deftest tandem-chat-missing-claude-is-a-clear-error ()
  (tandem-test-with-project
    (let* ((tandem-claude-command "/nonexistent/claude")
           (err (should-error (tandem) :type 'user-error)))
      (should (string-match-p "/nonexistent/claude" (cadr err))))))

(ert-deftest tandem-chat-old-claude-is-a-clear-error ()
  (let ((process-environment (cons "FAKE_CLAUDE_VERSION=2.0.9" process-environment)))
    (tandem-test-with-project
      (let ((err (should-error (tandem) :type 'user-error)))
        (should (string-match-p "2\\.0\\.9 is too old" (cadr err)))))))

(ert-deftest tandem-chat-a-new-session-takes-the-environment-from-emacs ()
  (tandem-test-with-project
    (let ((process-environment (append '("CP_TEST_KEY=one" "CP_TEST_GONE=daemon") process-environment))
          (tandem-environment-variables '("CP_TEST_KEY" "CP_TEST_GONE"))
          (second nil))
      (unwind-protect
          (progn
            (setq buffer (tandem))
            (tandem-test--say buffer "script:env:CP_TEST_KEY,CP_TEST_GONE,HOME")
            (with-current-buffer buffer
              (should (string-match-p "CP_TEST_KEY=one CP_TEST_GONE=daemon HOME=/"
                                      (tandem-test--transcript))))
            ;; Changed in Emacs after the daemon started: a new session sees it.
            (let ((pid (tandem-test--pid)))
              (setenv "CP_TEST_KEY" "two")
              (setenv "CP_TEST_GONE" nil)
              (setq second (tandem t))
              (tandem-test--say second "script:env:CP_TEST_KEY,CP_TEST_GONE")
              (with-current-buffer second
                (should (string-match-p "CP_TEST_KEY=two CP_TEST_GONE unset"
                                        (tandem-test--transcript))))
              (should (eql (tandem-test--pid) pid))))
        (when (buffer-live-p second) (kill-buffer second))))))

(ert-deftest tandem-chat-a-new-chat-carries-your-instructions ()
  (let ((tandem-instructions "Use simple English.")
        (tandem-chat-session-functions nil)
        sent)
    (cl-letf (((symbol-function 'tandem-rpc-request)
               (lambda (method params &rest _) (when (eq method 'session/new) (setq sent params))
                 '(:sessionId "s-instr" :claudeVersion "2.1.327")))
              ((symbol-function 'tandem-chat--claude-path) (lambda () "/usr/bin/claude")))
      (let ((buffer (tandem-chat--create "/tmp/project")))
        (unwind-protect
            (should (equal (plist-get sent :instructions) "Use simple English."))
          (kill-buffer buffer)))))
  ;; The default asks for simple English with correct technical terms.
  (should (string-match-p "simple English" (default-value 'tandem-instructions)))
  (should (string-match-p "correct technical terms" (default-value 'tandem-instructions))))

(provide 'tandem-chat-tests)
;;; tandem-chat-tests.el ends here
