;;; tandem-install-tests.el --- Tests for installing the daemon  -*- lexical-binding: t; -*-

;;; Commentary:

;; tandem-install-daemon against a "release" in a local directory, through
;; file:// URLs: the checked download, a changed file, an error page, no
;; release for this version; and where tandem looks for the daemon.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-install)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-release (content &rest body)
  "Run BODY with a release holding a daemon made of CONTENT for this system.
RELEASE is its directory, INSTALL the daemon directory, SUM its SHA-256."
  (declare (indent 1) (debug t))
  `(let* ((release (file-name-as-directory (tandem-test--private-dir)))
          (install (file-name-as-directory (expand-file-name "tandem" (tandem-test--private-dir))))
          (platform (or (tandem-install--platform) (ert-skip "no daemon for this system")))
          (name (tandem-install--file-name tandem-version platform))
          (file (expand-file-name (concat "v" tandem-version "/" name) release))
          (sum nil))
     (make-directory (file-name-directory file) t)
     (with-temp-file file
       (set-buffer-multibyte nil)
       (insert ,content))
     (setq sum (tandem-install--sha256 file))
     (let ((tandem-daemon-release-url (concat "file://" release "v%s/%s"))
           (tandem-daemon-directory install)
           (tandem-daemon-sums-version tandem-version)
           (tandem-daemon-sums (list (cons platform sum))))
       (unwind-protect (progn ,@body)
         (delete-directory release t)
         (delete-directory (file-name-directory (directory-file-name install)) t)))))

(defun tandem-test--daemon-bytes ()
  "Return bytes the size of a daemon."
  (apply #'unibyte-string (mapcar (lambda (i) (% (* i 7) 256)) (number-sequence 1 200000))))

(ert-deftest tandem-install-a-checked-daemon ()
  (tandem-test-with-release (tandem-test--daemon-bytes)
    ;; A daemon of an older version is there already.
    (make-directory install t)
    (with-temp-file (expand-file-name "tandemd-0.0.1-old" install) (insert "old"))
    (let ((path (tandem-install-daemon)))
      (should (equal path (tandem-install-daemon-path)))
      (should (file-executable-p path))
      (should (equal (tandem-install--sha256 path) sum))
      (should (= (logand (file-modes install) #o077) 0))
      (should-not (file-exists-p (expand-file-name "tandemd-0.0.1-old" install)))
      (should-not (directory-files install nil "\\.part\\'")))))

(ert-deftest tandem-install-refuses-a-changed-daemon ()
  (tandem-test-with-release (tandem-test--daemon-bytes)
    (let ((tandem-daemon-sums (list (cons platform (make-string 64 ?0)))))
      (should-error (tandem-install-daemon) :type 'user-error)
      (should-not (file-exists-p (tandem-install-daemon-path)))
      (should-not (directory-files install nil "\\.part\\'")))))

(ert-deftest tandem-install-refuses-an-error-page ()
  (tandem-test-with-release "<html>Not Found</html>"
    (let ((err (should-error (tandem-install-daemon) :type 'user-error)))
      (should (string-match-p "not a daemon" (cadr err))))
    (should-not (file-exists-p (tandem-install-daemon-path)))))

(ert-deftest tandem-install-needs-sums-for-this-version ()
  (tandem-test-with-release (tandem-test--daemon-bytes)
    (let ((tandem-daemon-sums-version "0.0.1"))
      (should-not (tandem-install-available-p))
      (let ((err (should-error (tandem-install-daemon) :type 'user-error)))
        (should (string-match-p "has no released daemon yet" (cadr err)))))
    (let ((tandem-daemon-sums nil))
      (should-not (tandem-install-available-p)))))

(ert-deftest tandem-install-platforms ()
  (dolist (case '((gnu/linux "x86_64-pc-linux-gnu" "linux-amd64")
                  (gnu/linux "aarch64-unknown-linux-gnu" "linux-arm64")
                  (darwin "aarch64-apple-darwin23.4.0" "darwin-arm64")
                  (darwin "x86_64-apple-darwin21.6.0" "darwin-amd64")
                  (windows-nt "x86_64-w64-mingw32" "windows-amd64")
                  (berkeley-unix "x86_64-unknown-freebsd14.0" nil)
                  (gnu/linux "riscv64-unknown-linux-gnu" nil)))
    (let ((system-type (nth 0 case))
          (system-configuration (nth 1 case)))
      (should (equal (tandem-install--platform) (nth 2 case))))
    (should (equal (tandem-install--file-name "1.0.0" "windows-arm64") "tandemd-1.0.0-windows-arm64.exe"))
    (should (equal (tandem-install--file-name "1.0.0" "linux-amd64") "tandemd-1.0.0-linux-amd64"))))

(ert-deftest tandem-install-where-tandem-looks ()
  (tandem-test-with-release (tandem-test--daemon-bytes)
    (cl-letf (((symbol-function 'tandem-rpc--built-daemon) (lambda () "/nonexistent/tandemd"))
              ((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (let ((tandem-daemon-command nil))
        ;; Nothing yet, and no one to ask in batch mode.
        (let ((err (should-error (tandem-rpc-daemon-command) :type 'user-error)))
          (should (string-match-p "tandem-install-daemon" (cadr err))))
        ;; Asked, and answered yes.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
          (let ((noninteractive nil))
            (should (equal (tandem-rpc-daemon-command) (list (tandem-install-daemon-path))))))
        ;; Installed: found without asking.
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked"))))
          (let ((noninteractive nil))
            (should (equal (tandem-rpc-daemon-command) (list (tandem-install-daemon-path))))))
        ;; Your own setting comes first.
        (let ((tandem-daemon-command '("/opt/tandemd")))
          (should (equal (tandem-rpc-daemon-command) '("/opt/tandemd"))))))))

(provide 'tandem-install-tests)
;;; tandem-install-tests.el ends here
