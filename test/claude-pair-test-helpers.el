;;; claude-pair-test-helpers.el --- Shared helpers for the claude-pair tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by the test files with `require'; not a test file itself.

;;; Code:

(require 'claude-pair)
(require 'ert)

(defun claude-pair-test--wait-for (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil or TIMEOUT seconds pass.
Return the last value of PREDICATE."
  (let ((deadline (+ (float-time) (or timeout 5)))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(defun claude-pair-test--private-dir (&optional mode)
  "Make a temporary directory with MODE, #o700 by default."
  (let ((dir (make-temp-file "cpt-" t)))
    (set-file-modes dir (or mode #o700))
    dir))

(defmacro claude-pair-test-with-daemon-dir (&rest body)
  "Run BODY with the socket in a fresh private directory.
Afterwards stop any daemon started there and delete the directory."
  (declare (indent 0) (debug t))
  `(let* ((dir (claude-pair-test--private-dir))
          (claude-pair-socket-path (expand-file-name "d.sock" dir))
          (claude-pair-daemon-idle-timeout 60)
          (claude-pair-daemon-command nil)
          (claude-pair-rpc--connection nil)
          (claude-pair-rpc--server-info nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (claude-pair-rpc-shutdown-daemon))
       (claude-pair-test--wait-for
        (lambda () (not (file-exists-p claude-pair-socket-path))) 5)
       (delete-directory dir t))))

(defun claude-pair-test--pid ()
  "Return the pid the connected daemon reported."
  (plist-get (claude-pair-rpc-server-info) :pid))

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
       (when-let* ((window (get-buffer-window buffer)))
         (ignore-errors (delete-window window)))
       (kill-buffer buffer))))

(defun claude-pair-test--feed (&rest updates)
  "Handle UPDATES as if they came from the daemon, then draw them."
  (dolist (u updates)
    (claude-pair-chat--handle-update u))
  (claude-pair-chat--flush))

(defun claude-pair-test--transcript ()
  "Return the transcript text, without properties."
  (buffer-substring-no-properties (point-min) claude-pair-chat--output))

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

(defun claude-pair-test--send (buffer text)
  "Type TEXT into BUFFER's composer and send it, without waiting."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (claude-pair-chat-send)))

(provide 'claude-pair-test-helpers)
;;; claude-pair-test-helpers.el ends here
