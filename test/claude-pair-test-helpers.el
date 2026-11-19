;;; claude-pair-test-helpers.el --- Shared helpers for the claude-pair tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by the test files with `require'; not a test file itself.

;;; Code:

(require 'claude-pair)

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

(provide 'claude-pair-test-helpers)
;;; claude-pair-test-helpers.el ends here
