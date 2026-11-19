;;; claude-pair-chat-tests.el --- Tests for the chat buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group drives a chat buffer with hand-made updates and needs no
;; daemon.  The second group runs whole conversations through a real daemon
;; and daemon/bin/fakeclaude, which replays scripted Claude Code output.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--fake-claude
  (expand-file-name "../daemon/bin/fakeclaude"
                    (file-name-directory (locate-library "claude-pair")))
  "The stand-in for Claude Code that \"make fakeclaude\" builds.")

(defmacro claude-pair-test-with-chat (&rest body)
  "Run BODY in a fresh chat buffer that is not connected to any daemon."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer "*claude-pair test*")))
     (unwind-protect
         (with-current-buffer buffer
           (claude-pair-chat--setup "test-session" "/tmp/project")
           ,@body)
       (kill-buffer buffer))))

(defun claude-pair-test--feed (&rest updates)
  "Handle UPDATES as if they came from the daemon, then draw them."
  (dolist (u updates)
    (claude-pair-chat--handle-update u))
  (claude-pair-chat--flush))

(defun claude-pair-test--transcript ()
  "Return the transcript text, without properties."
  (buffer-substring-no-properties (point-min) claude-pair-chat--output))

;;;; Drawing, without a daemon

(ert-deftest claude-pair-chat-text-is-batched-then-drawn ()
  (claude-pair-test-with-chat
    (claude-pair-chat--handle-update '(:kind "text" :delta "Hel"))
    (claude-pair-chat--handle-update '(:kind "text" :delta "lo wörld 🌍"))
    (should-not (string-match-p "Hel" (claude-pair-test--transcript)))
    (should claude-pair-chat--timer)
    (claude-pair-chat--flush)
    (should (string-match-p "Claude\nHello wörld 🌍" (claude-pair-test--transcript)))
    (should-not claude-pair-chat--timer)))

(ert-deftest claude-pair-chat-the-timer-draws-the-queue ()
  (claude-pair-test-with-chat
    (claude-pair-chat--handle-update '(:kind "text" :delta "soon"))
    (should (claude-pair-test--wait-for
             (lambda () (string-match-p "soon" (claude-pair-test--transcript)))
             2))))

(ert-deftest claude-pair-chat-transcript-is-read-only ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed '(:kind "text" :delta "answer"))
    (dolist (pos (list (point-min) (1+ (point-min)) (1- claude-pair-chat--output)))
      (goto-char pos)
      (should-error (insert "x") :type 'text-read-only))
    (goto-char claude-pair-chat--output)
    (should-error (insert "x") :type 'text-read-only)
    (goto-char (1- claude-pair-chat--input))
    (should-error (insert "x") :type 'text-read-only)
    (goto-char (point-max))
    (insert "typed")
    (should (equal (claude-pair-chat--input-text) "typed"))))

(ert-deftest claude-pair-chat-tool-lines ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed
     '(:kind "tool" :id "t1" :name "Read" :title "Read README.md" :status "started"))
    (should (string-match-p "^  ▸ Read README\\.md$" (claude-pair-test--transcript)))
    (should (equal claude-pair-chat--state "tool"))
    (should (string-match-p "running Read" (claude-pair-chat--header-line)))
    (claude-pair-test--feed
     '(:kind "tool" :id "t1" :name "Read" :title "Read README.md" :status "done" :durationMs 412)
     '(:kind "tool" :id "t2" :name "Bash" :title "Bash rm -rf x" :status "started")
     '(:kind "tool" :id "t2" :name "Bash" :title "Bash rm -rf x" :status "error" :durationMs 1500))
    (let ((text (claude-pair-test--transcript)))
      (should (string-match-p "^  ✓ Read README\\.md  412 ms$" text))
      (should (string-match-p "^  ✗ Bash rm -rf x  1\\.5 s$" text))
      (should-not (string-match-p "▸" text)))))

(ert-deftest claude-pair-chat-text-after-a-tool-starts-a-new-paragraph ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed
     '(:kind "text" :delta "Let me look.")
     '(:kind "tool" :id "t1" :name "Read" :title "Read a" :status "started")
     '(:kind "tool" :id "t1" :name "Read" :title "Read a" :status "done" :durationMs 5)
     '(:kind "text" :delta "Found it."))
    (should (string-match-p "Let me look\\.\n  ✓ Read a  5 ms\n\nFound it\\." (claude-pair-test--transcript)))))

(ert-deftest claude-pair-chat-todo-list-sits-at-the-top ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed '(:kind "text" :delta "Working."))
    (claude-pair-test--feed
     '(:kind "todo" :items [(:content "Read" :status "completed")
                            (:content "Write" :status "in_progress")
                            (:content "Test" :status "pending")]))
    (goto-char (point-min))
    (should (looking-at "Plan\n  ✓ Read\n  ▸ Write\n  ○ Test\n"))
    (claude-pair-test--feed '(:kind "todo" :items [(:content "Read" :status "completed")]))
    (goto-char (point-min))
    (should (looking-at "Plan\n  ✓ Read\n\nAsk Claude"))
    (should (string-match-p "Working\\." (claude-pair-test--transcript)))))

(ert-deftest claude-pair-chat-header-line ()
  (claude-pair-test-with-chat
    (should (string-match-p "Claude · ready" (claude-pair-chat--header-line)))
    (claude-pair-test--feed '(:kind "init" :model "claude-fake-1")
                            '(:kind "status" :state "running"))
    (should (string-match-p "claude-fake-1 · thinking…" (claude-pair-chat--header-line)))
    (claude-pair-test--feed '(:kind "result" :subtype "success" :costUsd 0.01 :sessionCostUsd 0.0123
                                    :durationMs 900 :cancelled :json-false :isError :json-false)
                            '(:kind "status" :state "idle"))
    (should (string-match-p "ready · \\$0\\.0123" (claude-pair-chat--header-line)))))

(ert-deftest claude-pair-chat-result-lines ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed '(:kind "text" :delta "One.")
                            '(:kind "result" :subtype "success" :costUsd 0.0042 :durationMs 2300
                                    :cancelled :json-false :isError :json-false
                                    :permissionDenials ["Bash"]))
    (let ((text (claude-pair-test--transcript)))
      (should (string-match-p "^  2\\.3 s · \\$0\\.0042$" text))
      (should (string-match-p "Not allowed yet: Bash" text)))
    (claude-pair-test--feed '(:kind "text" :delta "Two.") '(:kind "result" :cancelled t))
    (should (string-match-p "Two\\.\n  Stopped\\.$" (claude-pair-test--transcript)))
    (claude-pair-test--feed '(:kind "result" :subtype "error_max_turns" :isError t :cancelled :json-false
                                    :message "Reached the maximum number of turns"))
    (should (string-match-p "Claude stopped: Reached the maximum number of turns"
                            (claude-pair-test--transcript)))))

(ert-deftest claude-pair-chat-error-lines-show-stderr ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed '(:kind "error" :message "claude stopped unexpectedly (exit code 3)"
                                    :stderr "warming up\nfatal: something broke\n"))
    (let ((text (claude-pair-test--transcript)))
      (should (string-match-p "  claude stopped unexpectedly (exit code 3)\n" text))
      (should (string-match-p "    fatal: something broke\n" text)))))

(ert-deftest claude-pair-chat-send-uses-the-composer ()
  (claude-pair-test-with-chat
    (let (sent)
      (cl-letf (((symbol-function 'claude-pair-rpc-request)
                 (lambda (method params &optional _timeout)
                   (push (list method params) sent)
                   '(:ok t))))
        (goto-char (point-max))
        (insert "  What files are here?  ")
        (claude-pair-chat-send))
      (should (equal sent '((session/prompt (:sessionId "test-session" :text "What files are here?")))))
      (should (equal (claude-pair-chat--input-text) ""))
      (should (string-match-p "You\nWhat files are here\\?\n" (claude-pair-test--transcript)))
      (should (equal (ring-ref claude-pair-chat--history 0) "What files are here?"))
      (should (claude-pair-chat--busy-p)))))

(ert-deftest claude-pair-chat-send-refuses-empty-and-busy ()
  (claude-pair-test-with-chat
    (cl-letf (((symbol-function 'claude-pair-rpc-request)
               (lambda (&rest _) (error "Must not be called"))))
      (should-error (claude-pair-chat-send) :type 'user-error)
      (goto-char (point-max))
      (insert "hello")
      (setq claude-pair-chat--state "writing")
      (should-error (claude-pair-chat-send) :type 'user-error)
      (should (equal (claude-pair-chat--input-text) "hello")))))

(ert-deftest claude-pair-chat-a-failed-send-keeps-the-text ()
  (claude-pair-test-with-chat
    (cl-letf (((symbol-function 'claude-pair-rpc-request)
               (lambda (&rest _)
                 (signal 'jsonrpc-error '("request id=3 failed:"
                                          (jsonrpc-error-code . -32004)
                                          (jsonrpc-error-message . "no session \"test-session\""))))))
      (goto-char (point-max))
      (insert "hello")
      (claude-pair-chat-send)
      (should (equal (claude-pair-chat--input-text) "hello"))
      (should (equal claude-pair-chat--state "idle"))
      (should (string-match-p "Not sent: no session" (claude-pair-test--transcript))))))

(ert-deftest claude-pair-chat-history ()
  (claude-pair-test-with-chat
    (dolist (m '("first" "second" "third"))
      (ring-insert claude-pair-chat--history m))
    (claude-pair-chat-previous-input 1)
    (should (equal (claude-pair-chat--input-text) "third"))
    (claude-pair-chat-previous-input 1)
    (should (equal (claude-pair-chat--input-text) "second"))
    (claude-pair-chat-previous-input 5)
    (should (equal (claude-pair-chat--input-text) "first"))
    (claude-pair-chat-next-input 1)
    (should (equal (claude-pair-chat--input-text) "second"))
    (claude-pair-chat-next-input 2)
    (should (equal (claude-pair-chat--input-text) ""))))

(ert-deftest claude-pair-chat-undo-in-the-composer-survives-streaming ()
  (claude-pair-test-with-chat
    (goto-char (point-max))
    (insert "abc")
    (undo-boundary)
    (insert "def")
    (undo-boundary)
    (claude-pair-test--feed '(:kind "text" :delta "A long streamed answer ")
                            '(:kind "tool" :id "t" :name "Read" :title "Read x" :status "started")
                            '(:kind "tool" :id "t" :name "Read" :title "Read x" :status "done" :durationMs 7)
                            '(:kind "todo" :items [(:content "Step" :status "pending")]))
    (goto-char (point-max))
    (let ((last-command nil))
      (undo))
    (should (equal (claude-pair-chat--input-text) "abc"))
    (should (string-match-p "A long streamed answer" (claude-pair-test--transcript)))
    (should (string-match-p "✓ Read x" (claude-pair-test--transcript)))))

(ert-deftest claude-pair-chat-disconnect-is-shown ()
  (claude-pair-test-with-chat
    (setq claude-pair-chat--state "writing")
    (claude-pair-chat--on-disconnect)
    (claude-pair-chat--flush)
    (should (equal claude-pair-chat--state "disconnected"))
    (should-not (claude-pair-chat--busy-p))
    (should (string-match-p "Disconnected from claude-paird" (claude-pair-test--transcript)))))

;;;; Whole conversations through the daemon and the fake claude

(defmacro claude-pair-test-with-project (&rest body)
  "Run BODY with a daemon, the fake claude and a temporary project directory.
BUFFER is bound to nil for BODY to set; it is killed afterwards."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (file-executable-p claude-pair-test--fake-claude))
     (claude-pair-test-with-daemon-dir
       (let* ((project (claude-pair-test--private-dir))
              (default-directory (file-name-as-directory project))
              (claude-pair-claude-command claude-pair-test--fake-claude)
              (claude-pair-model nil)
              (buffer nil))
         (unwind-protect
             (progn ,@body)
           (when (buffer-live-p buffer)
             (kill-buffer buffer))
           (delete-directory project t))))))

(defun claude-pair-test--say (buffer text)
  "Send TEXT from BUFFER's composer and wait until Claude has answered."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (claude-pair-chat-send))
  (claude-pair-test--wait-idle buffer))

(defun claude-pair-test--wait-idle (buffer)
  "Wait until BUFFER's session is idle and everything is drawn."
  (should (claude-pair-test--wait-for
           (lambda ()
             (with-current-buffer buffer
               (and (equal claude-pair-chat--state "idle")
                    (null claude-pair-chat--queue))))
           10)))

(ert-deftest claude-pair-chat-a-whole-conversation ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (should (eq (window-buffer (selected-window)) buffer))
    (claude-pair-test--say buffer "script:hello")
    (with-current-buffer buffer
      (should (string-match-p "You\nscript:hello\n\nClaude\nHello wörld 🌍\n  1\\.2 s · \\$0\\.0100\n"
                              (claude-pair-test--transcript)))
      (should (string-match-p "claude-fake-1 · ready · \\$0\\.0100" (claude-pair-chat--header-line))))
    (claude-pair-test--say buffer "a second question")
    (with-current-buffer buffer
      (should (string-match-p "You said: a second question" (claude-pair-test--transcript)))
      (should (string-match-p "\\$0\\.0200" (claude-pair-chat--header-line))))))

(ert-deftest claude-pair-chat-tools-in-a-real-session ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "script:tools")
    (with-current-buffer buffer
      (let ((text (buffer-substring-no-properties (point-min) claude-pair-chat--output)))
        (should (string-match-p "^Plan\n  ✓ Read the README\n  ▸ Summarize it\n" text))
        (should (string-match-p "^  ✓ Read README\\.md  [0-9]+ ms$" text))
        (should (string-match-p "^  ✗ Bash rm -rf build …  [0-9]+ ms$" text))
        (should (string-match-p "Not allowed yet: Bash" text))))))

(ert-deftest claude-pair-chat-cancel-then-continue ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "script:slow")
      (claude-pair-chat-send))
    (should (claude-pair-test--wait-for
             (lambda () (with-current-buffer buffer
                          (string-match-p "\n3\n" (claude-pair-test--transcript))))
             10))
    (with-current-buffer buffer
      (claude-pair-chat-cancel))
    (claude-pair-test--wait-idle buffer)
    (with-current-buffer buffer
      (should (string-match-p "  Stopped\\.\n" (claude-pair-test--transcript))))
    (claude-pair-test--say buffer "script:args")
    (with-current-buffer buffer
      (should (string-match-p (concat "--resume " (regexp-quote claude-pair-chat--session-id))
                              (claude-pair-test--transcript))))))

(ert-deftest claude-pair-chat-same-project-same-buffer ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (should (eq (claude-pair) buffer))
    (let ((other (claude-pair t)))
      (unwind-protect
          (progn
            (should-not (eq other buffer))
            (should (eql (plist-get (claude-pair-daemon-status) :sessions) 2)))
        (kill-buffer other)))
    (should (eql (plist-get (claude-pair-daemon-status) :sessions) 1))))

(ert-deftest claude-pair-chat-missing-claude-is-a-clear-error ()
  (claude-pair-test-with-project
    (let* ((claude-pair-claude-command "/nonexistent/claude")
           (err (should-error (claude-pair) :type 'user-error)))
      (should (string-match-p "/nonexistent/claude" (cadr err))))))

(ert-deftest claude-pair-chat-old-claude-is-a-clear-error ()
  (let ((process-environment (cons "FAKE_CLAUDE_VERSION=2.0.9" process-environment)))
    (claude-pair-test-with-project
      (let ((err (should-error (claude-pair) :type 'user-error)))
        (should (string-match-p "2\\.0\\.9 is too old" (cadr err)))))))

(provide 'claude-pair-chat-tests)
;;; claude-pair-chat-tests.el ends here
