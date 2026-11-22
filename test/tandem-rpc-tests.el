;;; tandem-rpc-tests.el --- Tests for the daemon connection  -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests start real daemons (daemon/bin/tandemd) on sockets in
;; private temporary directories, so they never touch a daemon you are
;; using.  Run them with "make test-lisp".

;;; Code:

(require 'ert)
(require 'tandem)
(require 'tandem-test-helpers)

;;;; Paths and commands

(ert-deftest tandem-rpc-socket-path-uses-xdg-runtime-dir ()
  (let ((process-environment (cons "XDG_RUNTIME_DIR=/run/user/4242" process-environment))
        (tandem-socket-path nil))
    (should (equal (tandem-rpc-socket-path)
                   "/run/user/4242/tandem/daemon.sock"))))

(ert-deftest tandem-rpc-socket-path-falls-back-to-tmp ()
  (dolist (xdg '(nil "" "relative/dir"))
    (let ((process-environment (copy-sequence process-environment))
          (temporary-file-directory "/tmp/")
          (tandem-socket-path nil))
      (setenv "XDG_RUNTIME_DIR" xdg)
      (should (equal (tandem-rpc-socket-path)
                     (format "/tmp/tandem-%d/daemon.sock" (user-uid)))))))

(ert-deftest tandem-rpc-socket-path-honors-the-option ()
  (let ((tandem-socket-path "/somewhere/private/d.sock"))
    (should (equal (tandem-rpc-socket-path) "/somewhere/private/d.sock"))))

(ert-deftest tandem-rpc-daemon-command-finds-the-built-binary ()
  (skip-unless (not (executable-find "tandemd")))
  (let* ((tandem-daemon-command nil)
         (command (tandem-rpc-daemon-command)))
    (should (= (length command) 1))
    (should (string-suffix-p "daemon/bin/tandemd" (car command)))
    (should (file-executable-p (car command)))))

(ert-deftest tandem-rpc-missing-binary-says-how-to-build-it ()
  (let ((tandem-daemon-command nil)
        (exec-path nil))
    (cl-letf (((symbol-function 'tandem-rpc--built-daemon)
               (lambda () "/nonexistent/daemon/bin/tandemd")))
      (let ((err (should-error (tandem-rpc-daemon-command) :type 'user-error)))
        (should (string-match-p "make daemon" (cadr err)))))))

(ert-deftest tandem-rpc-daemon-command-honors-the-option ()
  (let ((tandem-daemon-command '("/opt/bin/tandemd" "--log-level" "debug")))
    (should (equal (tandem-rpc-daemon-command)
                   '("/opt/bin/tandemd" "--log-level" "debug")))))

(ert-deftest tandem-rpc-long-socket-path-is-refused ()
  (let ((tandem-socket-path (concat "/tmp/" (make-string 120 ?x) "/d.sock")))
    (should-error (tandem-rpc-connection) :type 'user-error)))

;;;; Talking to a real daemon

(ert-deftest tandem-rpc-connect-starts-the-daemon ()
  (tandem-test-with-daemon-dir
    (should-not (file-exists-p tandem-socket-path))
    (tandem-connect)
    (should (tandem-rpc-live-p))
    (should (file-exists-p tandem-socket-path))
    (let ((info (tandem-rpc-server-info)))
      (should (equal (plist-get (plist-get info :serverInfo) :name) "tandemd"))
      (should (equal (plist-get info :protocolVersion) tandem-rpc-protocol-version))
      (should (natnump (plist-get info :pid))))))

(ert-deftest tandem-rpc-connect-twice-reuses-the-connection ()
  (tandem-test-with-daemon-dir
    (let ((first (tandem-connect)))
      (should (eq (tandem-connect) first)))))

(ert-deftest tandem-rpc-status-reports-one-client ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (let ((status (tandem-daemon-status)))
      (should (eql (plist-get status :clients) 1))
      (should (eql (plist-get status :sessions) 0))
      (should (eql (plist-get status :pid) (tandem-test--pid)))
      (should (equal (plist-get status :socketPath) tandem-socket-path)))))

(ert-deftest tandem-rpc-the-events-buffer-logs-initialize ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (with-current-buffer (jsonrpc-events-buffer (tandem-rpc-connection))
      (should (string-match-p "initialize" (buffer-string)))
      (should (string-match-p "tandemd" (buffer-string))))))

(ert-deftest tandem-rpc-disconnect-leaves-the-daemon-running ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (let ((pid (tandem-test--pid)))
      (tandem-disconnect)
      (should-not (tandem-rpc-live-p))
      (should (file-exists-p tandem-socket-path))
      (tandem-connect)
      (should (eql (tandem-test--pid) pid)))))

(ert-deftest tandem-rpc-stop-then-connect-starts-a-new-daemon ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (let ((pid (tandem-test--pid)))
      (tandem-stop-daemon)
      (should-not (tandem-rpc-live-p))
      (should (tandem-test--wait-for
               (lambda () (not (file-exists-p tandem-socket-path)))))
      (tandem-connect)
      (should-not (eql (tandem-test--pid) pid)))))

(ert-deftest tandem-rpc-stop-without-a-daemon-says-so ()
  (tandem-test-with-daemon-dir
    (should-not (tandem-rpc-shutdown-daemon))
    (should-not (file-exists-p tandem-socket-path))))

(ert-deftest tandem-rpc-incompatible-protocol-is-a-clear-error ()
  (tandem-test-with-daemon-dir
    (let* ((ours tandem-rpc-protocol-version)
           (tandem-rpc-protocol-version "9.0.0")
           (err (should-error (tandem-connect) :type 'user-error)))
      (should (string-match-p "9\\.0\\.0" (cadr err)))
      (should (string-match-p (regexp-quote ours) (cadr err)))
      (should (string-match-p "tandem-stop-daemon" (cadr err)))
      (should-not (tandem-rpc-live-p)))))

(ert-deftest tandem-rpc-stop-daemon-works-across-protocols ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (tandem-disconnect)
    (let ((tandem-rpc-protocol-version "9.0.0"))
      (should-error (tandem-connect) :type 'tandem-rpc-incompatible)
      (tandem-stop-daemon))
    (should-not (file-exists-p tandem-socket-path))))

(ert-deftest tandem-rpc-a-daemon-too-old-for-shutdown-gets-sigterm ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (let ((pid (tandem-test--pid)))
      (tandem-disconnect)
      (should (equal (tandem-rpc--daemon-pids tandem-socket-path) (list pid)))
      (cl-letf (((symbol-function 'tandem-rpc--raw-shutdown) (lambda (_path) nil)))
        (let ((tandem-rpc-protocol-version "9.0.0"))
          (should (tandem-rpc-shutdown-daemon))))
      (should-not (file-exists-p tandem-socket-path))
      (should (tandem-test--wait-for (lambda () (not (process-attributes pid))) 5)))))

(ert-deftest tandem-rpc-an-incompatible-daemon-can-be-restarted ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (let ((old-pid (tandem-test--pid))
          (calls 0)
          (real (symbol-function 'tandem-rpc--initialize)))
      (tandem-disconnect)
      ;; The first handshake meets "another version"; after the restart the
      ;; new daemon speaks ours.
      (cl-letf (((symbol-function 'tandem-rpc--initialize)
                 (lambda (connection)
                   (setq calls (1+ calls))
                   (let ((tandem-rpc-protocol-version
                          (if (= calls 1) "9.0.0" tandem-rpc-protocol-version)))
                     (funcall real connection))))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (let ((noninteractive nil))
          (tandem-connect)))
      (should (tandem-rpc-live-p))
      (should-not (eql (tandem-test--pid) old-pid)))))

(ert-deftest tandem-rpc-declining-the-restart-keeps-the-old-daemon ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (tandem-disconnect)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (let ((noninteractive nil)
            (tandem-rpc-protocol-version "9.0.0"))
        (should-error (tandem-connect) :type 'tandem-rpc-incompatible)))
    (should (file-exists-p tandem-socket-path))))

(ert-deftest tandem-rpc-missing-daemon-command-is-a-clear-error ()
  (tandem-test-with-daemon-dir
    (let* ((tandem-daemon-command '("/nonexistent/tandemd"))
           (err (should-error (tandem-connect) :type 'user-error)))
      (should (string-match-p "/nonexistent/tandemd" (cadr err))))))

(ert-deftest tandem-rpc-unsafe-socket-directory-is-a-clear-error ()
  (let ((dir (tandem-test--private-dir #o755)))
    (unwind-protect
        (let* ((tandem-socket-path (expand-file-name "d.sock" dir))
               (tandem-daemon-command nil)
               (tandem-rpc--connection nil)
               (err (should-error (tandem-connect) :type 'user-error)))
          (should (string-match-p "other users can reach the socket" (cadr err)))
          (should (eql (file-modes dir) #o755)))
      (delete-directory dir t))))

(ert-deftest tandem-rpc-a-dying-daemon-is-reported-without-jsonrpc-noise ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
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
        (signal-process (tandem-test--pid) 'SIGTERM)
        (should (tandem-test--wait-for (lambda () (not (tandem-rpc-live-p)))))
        (should (tandem-test--wait-for
                 (lambda () (member "tandem: lost the connection to the daemon" shown)))))
      (should-not (seq-some (lambda (text) (string-match-p "Server exited" text)) shown))
      (should (seq-some (lambda (text) (string-match-p "Server exited" text)) hidden)))))

(ert-deftest tandem-rpc-intentional-disconnect-is-quiet ()
  (tandem-test-with-daemon-dir
    (tandem-connect)
    (let ((shown '()))
      (cl-letf* ((real-message (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (unless (or inhibit-message (null message-log-max) (null format-string))
                      (push (apply #'format-message format-string args) shown))
                    (apply real-message format-string args))))
        (tandem-rpc-disconnect)
        (accept-process-output nil 0.2))
      (should-not (seq-some (lambda (text) (string-match-p "lost the connection\\|Server exited" text))
                            shown)))))

(ert-deftest tandem-rpc-daemon-outlives-the-connecting-emacs ()
  "A daemon started from a child Emacs keeps running after it exits."
  (tandem-test-with-daemon-dir
    (let* ((lisp-dir (file-name-directory (locate-library "tandem")))
           (status
            (call-process
             (expand-file-name invocation-name invocation-directory) nil nil nil
             "-Q" "--batch" "-L" lisp-dir
             ;; Stale .elc files would speak an older protocol.
             "--eval" "(setq load-prefer-newer t)"
             "--eval" (format "(setq tandem-socket-path %S tandem-daemon-transport '%s)"
                              tandem-socket-path tandem-daemon-transport)
             "--eval" "(progn (require 'tandem) (tandem-connect))")))
      (should (eql status 0))
      (should (file-exists-p tandem-socket-path))
      (tandem-connect)
      (should (eql (plist-get (tandem-daemon-status) :clients) 1)))))

(provide 'tandem-rpc-tests)
;;; tandem-rpc-tests.el ends here
