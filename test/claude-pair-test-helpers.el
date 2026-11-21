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
          ;; CLAUDE_PAIR_TEST_TRANSPORT=tcp runs the tests as on Windows.
          (claude-pair-daemon-transport (if (equal (getenv "CLAUDE_PAIR_TEST_TRANSPORT") "tcp") 'tcp 'unix))
          (claude-pair-socket-path
           (expand-file-name (if (eq claude-pair-daemon-transport 'tcp) "d.json" "d.sock") dir))
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
              (claude-pair-layout-tab nil)
              (buffer nil))
         ;; A marker, as a real project has, so Claude starts here.
         (with-temp-file (expand-file-name ".project" project))
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

;;;; Edit proposals

(defvar claude-pair-test--answers nil
  "The edit/answer calls recorded by `claude-pair-test-with-file'.")

(defmacro claude-pair-test-with-file (content &rest body)
  "Run BODY with FILE bound to a new file holding CONTENT.
Calls to the daemon are recorded in `claude-pair-test--answers'."
  (declare (indent 1) (debug t))
  `(let* ((dir (claude-pair-test--private-dir))
          (file (expand-file-name "a.txt" dir))
          (claude-pair-test--answers nil))
     (with-temp-file file (insert ,content))
     (cl-letf (((symbol-function 'claude-pair-rpc-request)
                (lambda (method params &optional _timeout)
                  (when (eq method 'edit/answer)
                    (push params claude-pair-test--answers))
                  '(:ok t))))
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_id p) (claude-pair-review--clear p)) claude-pair-review--proposals)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-directory dir t)))))

(defun claude-pair-test--propose (id &rest params)
  "Propose edit ID with PARAMS, as the daemon would."
  (claude-pair-review--propose (append (list :requestId id :sessionId "s1") params)))

(defun claude-pair-test--disk (file)
  "Return FILE's content on disk."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun claude-pair-test--overlay-with (property buffer)
  "Return an overlay in BUFFER that has PROPERTY."
  (with-current-buffer buffer
    (seq-find (lambda (ov) (overlay-get ov property))
              (overlays-in (point-min) (point-max)))))

(defun claude-pair-test--edit-prompt (spec)
  "Return a fake-claude prompt for the edit SPEC, a plist."
  (concat "script:edit:" (json-serialize spec)))

(defun claude-pair-test--wait-proposal ()
  "Wait until an edit proposal is shown, and return its id."
  (should (claude-pair-test--wait-for
           (lambda () (> (hash-table-count claude-pair-review--proposals) 0)) 10))
  (let (id) (maphash (lambda (k _v) (setq id k)) claude-pair-review--proposals) id))

(defmacro claude-pair-test-with-edit-project (&rest body)
  "Run BODY in a project holding a.txt, with a chat in BUFFER."
  (declare (indent 0) (debug t))
  `(claude-pair-test-with-project
     (with-temp-file (expand-file-name "a.txt" project) (insert "one x two\n"))
     (unwind-protect
         (progn (setq buffer (claude-pair)) ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p project (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(provide 'claude-pair-test-helpers)
;;; claude-pair-test-helpers.el ends here
