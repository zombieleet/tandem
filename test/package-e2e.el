;;; package-e2e.el --- Install tandem as a package, end to end  -*- lexical-binding: t; -*-

;;; Commentary:

;; make test-package PACKAGE_BUILD=<melpa/package-build> [COMPAT=<compat>]
;;
;; 1. Copies the checkout as it is now (uncommitted files too) into a git
;;    repository of its own, and builds tandem from it with MELPA's
;;    package-build and the :files of recipes/tandem.
;; 2. In a fresh Emacs, with nothing of the checkout on its load path,
;;    installs that package from a local archive.
;; 3. There, installs the daemon from a local "release" through file://,
;;    checked against its SHA-256, starts it, and chats with the fake
;;    claude; and finds the manual with Info.
;;
;; Everything happens in a temporary directory, removed afterwards.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar tandem-e2e--checkout default-directory
  "The checkout being packaged: where make runs.")

(defun tandem-e2e--say (format-string &rest args)
  "Print FORMAT-STRING with ARGS as a step of the test."
  (princ (concat "test-package: " (apply #'format format-string args) "\n")))

(defun tandem-e2e--fail (format-string &rest args)
  "Fail the test with FORMAT-STRING and ARGS; cleaning up happens on the way out."
  (error "%s" (apply #'format format-string args)))

(defmacro tandem-e2e--main (cleanup &rest body)
  "Run BODY, then CLEANUP whatever happened, then exit: 1 if BODY failed."
  (declare (indent 1))
  `(let ((failed nil))
     (unwind-protect
         (condition-case err
             (progn ,@body)
           (error
            (setq failed t)
            (princ (concat "test-package: FAILED: " (error-message-string err) "\n"))))
       ,cleanup)
     (kill-emacs (if failed 1 0))))

(defun tandem-e2e--run (program &rest args)
  "Run PROGRAM with ARGS; fail the test unless it succeeds.  Return its output."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil t nil args)))
      (unless (eql status 0)
        (tandem-e2e--fail "%s %s: %s" program (string-join args " ") (buffer-string)))
      (buffer-string))))

(defun tandem-e2e--recipe-files ()
  "Return the :files of recipes/tandem."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "recipes/tandem" tandem-e2e--checkout))
    (plist-get (cdr (read (current-buffer))) :files)))

(defun tandem-package-e2e ()
  "Build tandem as MELPA does, then install and use it in a fresh Emacs."
  (require 'package-build)
  (let* ((tmp (file-name-as-directory (make-temp-file "tandem-e2e-" t)))
         (src (expand-file-name "src/" tmp))
         (default-directory tandem-e2e--checkout))
    (tandem-e2e--main (delete-directory tmp t)
          ;; 1. The checkout as it is, as a repository of its own.
          (make-directory src)
          (dolist (file (process-lines "git" "ls-files" "-co" "--exclude-standard"))
            (unless (string-match-p "\\`\\(f\\.bash\\|heap\\.ts\\|p\\.js~?\\|notes_after.*\\|\\.claude/.*\\)\\'" file)
              (let ((to (expand-file-name file src)))
                (make-directory (file-name-directory to) t)
                (copy-file file to t))))
          (let ((default-directory src))
            (tandem-e2e--run "git" "init" "-q")
            (tandem-e2e--run "git" "add" "-A")
            (tandem-e2e--run "git" "-c" "user.name=test" "-c" "user.email=test@example.invalid"
                             "commit" "-q" "-m" "snapshot"))
          (let ((recipes (expand-file-name "recipes/" tmp)))
            (make-directory recipes)
            (with-temp-file (expand-file-name "tandem" recipes)
              (prin1 `(tandem :fetcher git :url ,(directory-file-name src)
                              :files ,(tandem-e2e--recipe-files))
                     (current-buffer)))
            (setq package-build-recipes-dir recipes
                  package-build-working-dir (expand-file-name "work/" tmp)
                  package-build-archive-dir (expand-file-name "archive/" tmp)))
          (tandem-e2e--say "building the package with package-build")
          (package-build-archive "tandem" t)
          (let* ((tars (directory-files package-build-archive-dir t "\\`tandem-.*\\.tar\\'"))
                 (listing (and tars (tandem-e2e--run "tar" "-tf" (car tars)))))
            (unless tars (tandem-e2e--fail "no package was built"))
            (dolist (want '("/tandem.el" "/tandem-pkg.el" "/tandem-suggest.el" "/tandem-install.el"
                            "/tandem-daemon-sums.el" "/tandem.info" "/dir"))
              (unless (string-match-p (regexp-quote want) listing)
                (tandem-e2e--fail "the package lacks %s:\n%s" want listing)))
            (when (string-match-p "tests?\\.el\\|\\.texi\\|\\.go" listing)
              (tandem-e2e--fail "the package holds files it should not:\n%s" listing))
            (tandem-e2e--say "built %s, %d files" (file-name-nondirectory (car tars))
                             (length (split-string listing "\n" t))))
          ;; 2 and 3, in a fresh Emacs.
          (let ((output (tandem-e2e--run
                         (expand-file-name invocation-name invocation-directory)
                         "-Q" "--batch" "-l" (expand-file-name "test/package-e2e.el" tandem-e2e--checkout)
                         "-f" "tandem-package-e2e-install"
                         package-build-archive-dir tmp
                         (expand-file-name "daemon/bin/tandemd" tandem-e2e--checkout)
                         (expand-file-name "daemon/bin/fakeclaude" tandem-e2e--checkout))))
            (princ output))
          (tandem-e2e--say "passed"))))

(defvar tandem-version)
(defvar tandem-daemon-sums-version)
(defvar tandem-daemon-sums)
(defvar tandem-daemon-release-url)
(defvar tandem-daemon-directory)
(defvar tandem-socket-path)
(defvar tandem-claude-command)
(defvar tandem-layout-tab)
(defvar tandem-chat--state)
(defvar tandem-chat--output)
(defvar tandem-chat--queue)
(declare-function tandem-install--platform "tandem-install")
(declare-function tandem-install--file-name "tandem-install")
(declare-function tandem-install--sha256 "tandem-install")
(declare-function tandem-install-daemon "tandem-install")
(declare-function tandem-rpc-daemon-command "tandem-rpc")
(declare-function tandem-chat-send "tandem-chat")
(declare-function tandem-stop-daemon "tandem")
(declare-function tandem "tandem")

(defun tandem-package-e2e-install ()
  "Install the built package in this fresh Emacs and use it.
The command line gives the archive, a scratch directory, the daemon
binary to release and the fake claude."
  (pcase-let* ((`(,archive ,tmp ,daemon ,fake) command-line-args-left)
               (elpa (expand-file-name "elpa/" tmp))
               (release (expand-file-name "release/" tmp))
               (socket-dir (make-temp-file (expand-file-name "tandem-e2e-" (or (getenv "XDG_RUNTIME_DIR") "/tmp")) t)))
    (setq command-line-args-left nil)
    (tandem-e2e--main (progn
                        (when (fboundp 'tandem-stop-daemon)
                          (let ((tandem-socket-path (expand-file-name "d.sock" socket-dir)))
                            (ignore-errors (tandem-stop-daemon))))
                        (delete-directory socket-dir t))
          (require 'package)
          ;; Not the user's project list.
          (setq project-list-file (expand-file-name "projects" tmp))
          (setq package-user-dir elpa
                package-archives `(("local" . ,(file-name-as-directory archive)))
                package-check-signature nil)
          (package-initialize)
          (package-refresh-contents)
          (package-install 'tandem)
          (let ((where (locate-library "tandem")))
            (unless (and where (string-prefix-p elpa where))
              (tandem-e2e--fail "tandem loads from %s, not the installed package" where))
            (tandem-e2e--say "installed from the archive: %s" (abbreviate-file-name where)))
          ;; The package's autoloads, before anything is required.
          (dolist (command '(tandem tandem-do tandem-suggest-mode global-tandem-suggest-mode
                             tandem-install-daemon tandem-embark-mode tandem-magit-mode))
            (unless (fboundp command)
              (tandem-e2e--fail "%s is not autoloaded" command)))
          ;; The manual, through Info.
          (require 'info)
          (info-initialize)
          (with-temp-buffer
            (Info-mode)
            (condition-case err
                (Info-find-node "tandem" "Suggestions as you type")
              (error (tandem-e2e--fail "Info cannot find the manual: %s" (error-message-string err))))
            (unless (string-match-p "TAB" (buffer-string))
              (tandem-e2e--fail "the manual's node is empty")))
          (tandem-e2e--say "C-h i finds the manual")
          (require 'tandem)
          (require 'tandem-install)
          ;; A release of this version, for this system, by file://.
          (let* ((platform (tandem-install--platform))
                 (name (tandem-install--file-name tandem-version platform))
                 (file (expand-file-name (format "v%s/%s" tandem-version name) release)))
            (make-directory (file-name-directory file) t)
            (copy-file daemon file t)
            (setq tandem-daemon-release-url (concat "file://" release "v%s/%s")
                  tandem-daemon-directory (expand-file-name "tandem-daemon/" tmp)
                  tandem-daemon-sums-version tandem-version
                  tandem-daemon-sums (list (cons platform (tandem-install--sha256 file)))))
          ;; Nothing of the checkout: only the installed daemon may be found.
          (setq exec-path (seq-remove (lambda (d) (file-executable-p (expand-file-name "tandemd" d))) exec-path))
          (let ((path (tandem-install-daemon)))
            (unless (equal (tandem-rpc-daemon-command) (list path))
              (tandem-e2e--fail "tandem would start %S, not the installed %s" (tandem-rpc-daemon-command) path))
            (tandem-e2e--say "installed the daemon, checked: %s" (abbreviate-file-name path)))
          ;; A chat, with the fake claude.
          (let* ((project (file-name-as-directory (expand-file-name "project" tmp)))
                 (tandem-socket-path (expand-file-name "d.sock" socket-dir))
                 (tandem-claude-command fake)
                 (tandem-layout-tab nil))
            (make-directory project)
            (with-temp-file (expand-file-name ".project" project))
            (with-temp-file (expand-file-name "a.py" project) (insert "x = 1\n"))
            (with-current-buffer (find-file-noselect (expand-file-name "a.py" project))
              (let ((chat (tandem)))
                (with-current-buffer chat
                  (goto-char (point-max))
                  (insert "hello from a package")
                  (tandem-chat-send)
                  (let ((deadline (+ (float-time) 20)))
                    (while (and (< (float-time) deadline)
                                (not (and (equal tandem-chat--state "idle")
                                          (null tandem-chat--queue))))
                      (accept-process-output nil 0.1)))
                  (let ((text (buffer-substring-no-properties (point-min) tandem-chat--output)))
                    (unless (string-match-p "You said: hello from a package" text)
                      (tandem-e2e--fail "no answer in the chat:\n%s" text))))
                (tandem-e2e--say "a chat through the installed daemon answers")))))))

;;; package-e2e.el ends here
