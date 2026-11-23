;;; tandem-test-helpers.el --- Shared helpers for the tandem tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by the test files with `require'; not a test file itself.

;;; Code:

(require 'tandem)
(require 'ert)

;; TANDEM_TEST_PACKAGES names a directory of built packages (one
;; subdirectory each, as straight.el or package.el make them), so the tests
;; of the optional files can load Magit, Embark and the rest.
(when-let* ((dir (getenv "TANDEM_TEST_PACKAGES")))
  (dolist (package (directory-files dir t "\\`[^.]"))
    (when (file-directory-p package)
      (add-to-list 'load-path package))))

;; Never the user's own store: Claude's lines in test files go to a
;; private directory, removed when the tests end.
(defconst tandem-test--attribution-directory (make-temp-file "cpt-attribution-" t)
  "Where the tests keep Claude's lines.")
(setq tandem-attribution-directory tandem-test--attribution-directory
      ;; Never move the user's store of the old name.
      tandem-authorship--moved t)
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory tandem-test--attribution-directory t))))

;; Never the user's own project list either: project.el remembers every
;; project it sees, and the tests make many in temporary directories.
(defconst tandem-test--emacs-directory (make-temp-file "cpt-emacs-" t)
  "Where the tests let Emacs keep its own state, such as the project list.")
(setq project-list-file (expand-file-name "projects" tandem-test--emacs-directory))
(add-hook 'kill-emacs-hook
          (lambda () (ignore-errors (delete-directory tandem-test--emacs-directory t))))

;; The tests write their own files; Emacs 30.2 and later refuse to run
;; Flymake backends in a file they do not trust, so trust them all here.
(defvar trusted-content)
(setq trusted-content :all)

(defun tandem-test--wait-for (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil or TIMEOUT seconds pass.
Return the last value of PREDICATE."
  (let ((deadline (+ (float-time) (or timeout 5)))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(defun tandem-test--private-dir (&optional mode)
  "Make a temporary directory with MODE, #o700 by default.
Return its true name: on macOS the temporary directory is under
/var, a link to /private/var, and git answers with the true one."
  (let ((dir (file-truename (make-temp-file "cpt-" t))))
    (set-file-modes dir (or mode #o700))
    dir))

(defmacro tandem-test-with-daemon-dir (&rest body)
  "Run BODY with the socket in a fresh private directory.
Afterwards stop any daemon started there and delete the directory."
  (declare (indent 0) (debug t))
  `(let* ((dir (tandem-test--private-dir))
          ;; TANDEM_TEST_TRANSPORT=tcp runs the tests as on Windows.
          (tandem-daemon-transport (if (equal (getenv "TANDEM_TEST_TRANSPORT") "tcp") 'tcp 'unix))
          (tandem-socket-path
           (expand-file-name (if (eq tandem-daemon-transport 'tcp) "d.json" "d.sock") dir))
          (tandem-daemon-idle-timeout 60)
          (tandem-daemon-command nil)
          (tandem-rpc--connection nil)
          (tandem-rpc--server-info nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (tandem-rpc-shutdown-daemon))
       (tandem-test--wait-for
        (lambda () (not (file-exists-p tandem-socket-path))) 5)
       (delete-directory dir t))))

(defun tandem-test--pid ()
  "Return the pid the connected daemon reported."
  (plist-get (tandem-rpc-server-info) :pid))

(defconst tandem-test--fake-claude
  (expand-file-name "../daemon/bin/fakeclaude"
                    (file-name-directory (locate-library "tandem")))
  "The stand-in for Claude Code that \"make fakeclaude\" builds.")

(defmacro tandem-test-with-chat (&rest body)
  "Run BODY in a fresh chat buffer that is not connected to any daemon."
  (declare (indent 0) (debug t))
  `(let ((buffer (generate-new-buffer "*tandem test*")))
     (unwind-protect
         (with-current-buffer buffer
           (tandem-chat--setup "test-session" "/tmp/project")
           ,@body)
       (when-let* ((window (get-buffer-window buffer)))
         (ignore-errors (delete-window window)))
       (kill-buffer buffer))))

(defun tandem-test--feed (&rest updates)
  "Handle UPDATES as if they came from the daemon, then draw them."
  (dolist (u updates)
    (tandem-chat--handle-update u))
  (tandem-chat--flush))

(defun tandem-test--transcript ()
  "Return the transcript text, without properties."
  (buffer-substring-no-properties (point-min) tandem-chat--output))

(defmacro tandem-test-with-project (&rest body)
  "Run BODY with a daemon, the fake claude and a temporary project directory.
BUFFER is bound to nil for BODY to set; it is killed afterwards."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (file-executable-p tandem-test--fake-claude))
     (tandem-test-with-daemon-dir
       (let* ((project (tandem-test--private-dir))
              (default-directory (file-name-as-directory project))
              (tandem-claude-command tandem-test--fake-claude)
              (tandem-model nil)
              (tandem-layout-tab nil)
              (buffer nil))
         ;; A marker, as a real project has, so Claude starts here.
         (with-temp-file (expand-file-name ".project" project))
         (unwind-protect
             (progn ,@body)
           (when (buffer-live-p buffer)
             (kill-buffer buffer))
           (delete-directory project t))))))

(defun tandem-test--say (buffer text)
  "Send TEXT from BUFFER's composer and wait until Claude has answered."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (tandem-chat-send))
  (tandem-test--wait-idle buffer))

(defun tandem-test--wait-idle (buffer)
  "Wait until BUFFER's session is idle and everything is drawn."
  (should (tandem-test--wait-for
           (lambda ()
             (with-current-buffer buffer
               (and (equal tandem-chat--state "idle")
                    (null tandem-chat--queue))))
           10)))

(defun tandem-test--send (buffer text)
  "Type TEXT into BUFFER's composer and send it, without waiting."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (tandem-chat-send)))

;;;; Edit proposals

(defvar tandem-test--answers nil
  "The edit/answer calls recorded by `tandem-test-with-file'.")

(defmacro tandem-test-with-file (content &rest body)
  "Run BODY with FILE bound to a new file holding CONTENT.
Calls to the daemon are recorded in `tandem-test--answers'."
  (declare (indent 1) (debug t))
  `(let* ((dir (tandem-test--private-dir))
          (file (expand-file-name "a.txt" dir))
          (tandem-test--answers nil))
     (with-temp-file file (insert ,content))
     (cl-letf (((symbol-function 'tandem-rpc-request)
                (lambda (method params &optional _timeout)
                  (when (eq method 'edit/answer)
                    (push params tandem-test--answers))
                  '(:ok t))))
       (unwind-protect
           (progn ,@body)
         (maphash (lambda (_id p) (tandem-review--clear p)) tandem-review--proposals)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-directory dir t)))))

(defun tandem-test--propose (id &rest params)
  "Propose edit ID with PARAMS, as the daemon would."
  (tandem-review--propose (append (list :requestId id :sessionId "s1") params)))

(defun tandem-test--disk (file)
  "Return FILE's content on disk."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun tandem-test--overlay-with (property buffer)
  "Return an overlay in BUFFER that has PROPERTY."
  (with-current-buffer buffer
    (seq-find (lambda (ov) (overlay-get ov property))
              (overlays-in (point-min) (point-max)))))

(defun tandem-test--edit-prompt (spec)
  "Return a fake-claude prompt for the edit SPEC, a plist."
  (concat "script:edit:" (json-serialize spec)))

(defun tandem-test--wait-proposal ()
  "Wait until an edit proposal is shown, and return its id."
  (should (tandem-test--wait-for
           (lambda () (> (hash-table-count tandem-review--proposals) 0)) 10))
  (let (id) (maphash (lambda (k _v) (setq id k)) tandem-review--proposals) id))

(defmacro tandem-test-with-edit-project (&rest body)
  "Run BODY in a project holding a.txt, with a chat in BUFFER."
  (declare (indent 0) (debug t))
  `(tandem-test-with-project
     (with-temp-file (expand-file-name "a.txt" project) (insert "one x two\n"))
     (unwind-protect
         (progn (setq buffer (tandem)) ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p project (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b))))))

(provide 'tandem-test-helpers)
;;; tandem-test-helpers.el ends here
