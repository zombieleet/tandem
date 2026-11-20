;;; claude-pair-rpc-tests.el --- Tests for the daemon connection  -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests start real daemons (daemon/bin/claude-paird) on sockets in
;; private temporary directories, so they never touch a daemon you are
;; using.  Run them with "make test-lisp".

;;; Code:

(require 'ert)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

;;;; Paths and commands

(ert-deftest claude-pair-rpc-socket-path-uses-xdg-runtime-dir ()
  (let ((process-environment (cons "XDG_RUNTIME_DIR=/run/user/4242" process-environment))
        (claude-pair-socket-path nil))
    (should (equal (claude-pair-rpc-socket-path)
                   "/run/user/4242/claude-pair/daemon.sock"))))

(ert-deftest claude-pair-rpc-socket-path-falls-back-to-tmp ()
  (dolist (xdg '(nil "" "relative/dir"))
    (let ((process-environment (copy-sequence process-environment))
          (temporary-file-directory "/tmp/")
          (claude-pair-socket-path nil))
      (setenv "XDG_RUNTIME_DIR" xdg)
      (should (equal (claude-pair-rpc-socket-path)
                     (format "/tmp/claude-pair-%d/daemon.sock" (user-uid)))))))

(ert-deftest claude-pair-rpc-socket-path-honors-the-option ()
  (let ((claude-pair-socket-path "/somewhere/private/d.sock"))
    (should (equal (claude-pair-rpc-socket-path) "/somewhere/private/d.sock"))))

(ert-deftest claude-pair-rpc-daemon-command-finds-the-built-binary ()
  (skip-unless (not (executable-find "claude-paird")))
  (let* ((claude-pair-daemon-command nil)
         (command (claude-pair-rpc-daemon-command)))
    (should (= (length command) 1))
    (should (string-suffix-p "daemon/bin/claude-paird" (car command)))
    (should (file-executable-p (car command)))))

(ert-deftest claude-pair-rpc-missing-binary-says-how-to-build-it ()
  (let ((claude-pair-daemon-command nil)
        (exec-path nil))
    (cl-letf (((symbol-function 'claude-pair-rpc--built-daemon)
               (lambda () "/nonexistent/daemon/bin/claude-paird")))
      (let ((err (should-error (claude-pair-rpc-daemon-command) :type 'user-error)))
        (should (string-match-p "make daemon" (cadr err)))))))

(ert-deftest claude-pair-rpc-daemon-command-honors-the-option ()
  (let ((claude-pair-daemon-command '("/opt/bin/claude-paird" "--log-level" "debug")))
    (should (equal (claude-pair-rpc-daemon-command)
                   '("/opt/bin/claude-paird" "--log-level" "debug")))))

(ert-deftest claude-pair-rpc-long-socket-path-is-refused ()
  (let ((claude-pair-socket-path (concat "/tmp/" (make-string 120 ?x) "/d.sock")))
    (should-error (claude-pair-rpc-connection) :type 'user-error)))

;;;; Talking to a real daemon

(ert-deftest claude-pair-rpc-connect-starts-the-daemon ()
  (claude-pair-test-with-daemon-dir
    (should-not (file-exists-p claude-pair-socket-path))
    (claude-pair-connect)
    (should (claude-pair-rpc-live-p))
    (should (file-exists-p claude-pair-socket-path))
    (let ((info (claude-pair-rpc-server-info)))
      (should (equal (plist-get (plist-get info :serverInfo) :name) "claude-paird"))
      (should (equal (plist-get info :protocolVersion) claude-pair-rpc-protocol-version))
      (should (natnump (plist-get info :pid))))))

(ert-deftest claude-pair-rpc-connect-twice-reuses-the-connection ()
  (claude-pair-test-with-daemon-dir
    (let ((first (claude-pair-connect)))
      (should (eq (claude-pair-connect) first)))))

(ert-deftest claude-pair-rpc-status-reports-one-client ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((status (claude-pair-daemon-status)))
      (should (eql (plist-get status :clients) 1))
      (should (eql (plist-get status :sessions) 0))
      (should (eql (plist-get status :pid) (claude-pair-test--pid)))
      (should (equal (plist-get status :socketPath) claude-pair-socket-path)))))

(ert-deftest claude-pair-rpc-the-events-buffer-logs-initialize ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (with-current-buffer (jsonrpc-events-buffer (claude-pair-rpc-connection))
      (should (string-match-p "initialize" (buffer-string)))
      (should (string-match-p "claude-paird" (buffer-string))))))

(ert-deftest claude-pair-rpc-disconnect-leaves-the-daemon-running ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((pid (claude-pair-test--pid)))
      (claude-pair-disconnect)
      (should-not (claude-pair-rpc-live-p))
      (should (file-exists-p claude-pair-socket-path))
      (claude-pair-connect)
      (should (eql (claude-pair-test--pid) pid)))))

(ert-deftest claude-pair-rpc-stop-then-connect-starts-a-new-daemon ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((pid (claude-pair-test--pid)))
      (claude-pair-stop-daemon)
      (should-not (claude-pair-rpc-live-p))
      (should (claude-pair-test--wait-for
               (lambda () (not (file-exists-p claude-pair-socket-path)))))
      (claude-pair-connect)
      (should-not (eql (claude-pair-test--pid) pid)))))

(ert-deftest claude-pair-rpc-stop-without-a-daemon-says-so ()
  (claude-pair-test-with-daemon-dir
    (should-not (claude-pair-rpc-shutdown-daemon))
    (should-not (file-exists-p claude-pair-socket-path))))

(ert-deftest claude-pair-rpc-incompatible-protocol-is-a-clear-error ()
  (claude-pair-test-with-daemon-dir
    (let* ((ours claude-pair-rpc-protocol-version)
           (claude-pair-rpc-protocol-version "9.0.0")
           (err (should-error (claude-pair-connect) :type 'user-error)))
      (should (string-match-p "9\\.0\\.0" (cadr err)))
      (should (string-match-p (regexp-quote ours) (cadr err)))
      (should (string-match-p "claude-pair-stop-daemon" (cadr err)))
      (should-not (claude-pair-rpc-live-p)))))

(ert-deftest claude-pair-rpc-stop-daemon-works-across-protocols ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (claude-pair-disconnect)
    (let ((claude-pair-rpc-protocol-version "9.0.0"))
      (should-error (claude-pair-connect) :type 'claude-pair-rpc-incompatible)
      (claude-pair-stop-daemon))
    (should-not (file-exists-p claude-pair-socket-path))))

(ert-deftest claude-pair-rpc-a-daemon-too-old-for-shutdown-gets-sigterm ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((pid (claude-pair-test--pid)))
      (claude-pair-disconnect)
      (should (equal (claude-pair-rpc--daemon-pids claude-pair-socket-path) (list pid)))
      (cl-letf (((symbol-function 'claude-pair-rpc--raw-shutdown) (lambda (_path) nil)))
        (let ((claude-pair-rpc-protocol-version "9.0.0"))
          (should (claude-pair-rpc-shutdown-daemon))))
      (should-not (file-exists-p claude-pair-socket-path))
      (should (claude-pair-test--wait-for (lambda () (not (process-attributes pid))) 5)))))

(ert-deftest claude-pair-rpc-an-incompatible-daemon-can-be-restarted ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((old-pid (claude-pair-test--pid))
          (calls 0)
          (real (symbol-function 'claude-pair-rpc--initialize)))
      (claude-pair-disconnect)
      ;; The first handshake meets "another version"; after the restart the
      ;; new daemon speaks ours.
      (cl-letf (((symbol-function 'claude-pair-rpc--initialize)
                 (lambda (connection)
                   (setq calls (1+ calls))
                   (let ((claude-pair-rpc-protocol-version
                          (if (= calls 1) "9.0.0" claude-pair-rpc-protocol-version)))
                     (funcall real connection))))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (let ((noninteractive nil))
          (claude-pair-connect)))
      (should (claude-pair-rpc-live-p))
      (should-not (eql (claude-pair-test--pid) old-pid)))))

(ert-deftest claude-pair-rpc-declining-the-restart-keeps-the-old-daemon ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (claude-pair-disconnect)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (let ((noninteractive nil)
            (claude-pair-rpc-protocol-version "9.0.0"))
        (should-error (claude-pair-connect) :type 'claude-pair-rpc-incompatible)))
    (should (file-exists-p claude-pair-socket-path))))

(ert-deftest claude-pair-rpc-missing-daemon-command-is-a-clear-error ()
  (claude-pair-test-with-daemon-dir
    (let* ((claude-pair-daemon-command '("/nonexistent/claude-paird"))
           (err (should-error (claude-pair-connect) :type 'user-error)))
      (should (string-match-p "/nonexistent/claude-paird" (cadr err))))))

(ert-deftest claude-pair-rpc-unsafe-socket-directory-is-a-clear-error ()
  (let ((dir (claude-pair-test--private-dir #o755)))
    (unwind-protect
        (let* ((claude-pair-socket-path (expand-file-name "d.sock" dir))
               (claude-pair-daemon-command nil)
               (claude-pair-rpc--connection nil)
               (err (should-error (claude-pair-connect) :type 'user-error)))
          (should (string-match-p "other users can reach the socket" (cadr err)))
          (should (eql (file-modes dir) #o755)))
      (delete-directory dir t))))

(ert-deftest claude-pair-rpc-a-dying-daemon-is-reported-without-jsonrpc-noise ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((shown '())
          (hidden '()))
      (cl-letf* ((real-message (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (let ((text (and format-string (apply #'format-message format-string args))))
                      (if (or inhibit-message (null message-log-max))
                          (push text hidden)
                        (push text shown)))
                    (apply real-message format-string args))))
        (signal-process (claude-pair-test--pid) 'SIGTERM)
        (should (claude-pair-test--wait-for (lambda () (not (claude-pair-rpc-live-p)))))
        (should (claude-pair-test--wait-for
                 (lambda () (member "claude-pair: lost the connection to the daemon" shown)))))
      (should-not (seq-some (lambda (text) (string-match-p "Server exited" text)) shown))
      (should (seq-some (lambda (text) (string-match-p "Server exited" text)) hidden)))))

(ert-deftest claude-pair-rpc-intentional-disconnect-is-quiet ()
  (claude-pair-test-with-daemon-dir
    (claude-pair-connect)
    (let ((shown '()))
      (cl-letf* ((real-message (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (unless (or inhibit-message (null message-log-max) (null format-string))
                      (push (apply #'format-message format-string args) shown))
                    (apply real-message format-string args))))
        (claude-pair-rpc-disconnect)
        (accept-process-output nil 0.2))
      (should-not (seq-some (lambda (text) (string-match-p "lost the connection\\|Server exited" text))
                            shown)))))

(ert-deftest claude-pair-rpc-daemon-outlives-the-connecting-emacs ()
  "A daemon started from a child Emacs keeps running after it exits."
  (claude-pair-test-with-daemon-dir
    (let* ((lisp-dir (file-name-directory (locate-library "claude-pair")))
           (status
            (call-process
             (expand-file-name invocation-name invocation-directory) nil nil nil
             "-Q" "--batch" "-L" lisp-dir
             ;; Stale .elc files would speak an older protocol.
             "--eval" "(setq load-prefer-newer t)"
             "--eval" (format "(setq claude-pair-socket-path %S)" claude-pair-socket-path)
             "--eval" "(progn (require 'claude-pair) (claude-pair-connect))")))
      (should (eql status 0))
      (should (file-exists-p claude-pair-socket-path))
      (claude-pair-connect)
      (should (eql (plist-get (claude-pair-daemon-status) :clients) 1)))))

(provide 'claude-pair-rpc-tests)
;;; claude-pair-rpc-tests.el ends here
