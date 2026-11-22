;;; tandem-project-tests.el --- Tests for where Claude starts  -*- lexical-binding: t; -*-

;;; Commentary:

;; Folder trees made under a fake home folder: repositories, monorepos,
;; folders with project markers and folders with none.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-home (&rest body)
  "Run BODY with HOME, a fresh folder that is your home folder meanwhile."
  (declare (indent 0) (debug t))
  `(let* ((home (file-name-as-directory (file-truename (tandem-test--private-dir))))
          (process-environment (cons (concat "HOME=" home) process-environment))
          ;; The questions are answered by stubs, as you would.
          (noninteractive nil))
     (unwind-protect (progn ,@body)
       (delete-directory home t))))

(defun tandem-test--tree (root &rest paths)
  "Make PATHS under ROOT: names ending in / are folders, others files."
  (dolist (path paths)
    (let ((full (expand-file-name path root)))
      (if (string-suffix-p "/" path)
          (make-directory full t)
        (make-directory (file-name-directory full) t)
        (with-temp-file full)))))

(defun tandem-test--root-from (dir)
  "Return the root a chat started from DIR gets."
  (let ((default-directory (file-name-as-directory dir)))
    (tandem-project-root)))

(defun tandem-test--git (dir)
  "Make DIR a git repository."
  (let ((default-directory (file-name-as-directory dir)))
    (call-process "git" nil nil nil "init" "-q")))

(ert-deftest tandem-project-a-repository-is-its-root ()
  (tandem-test-with-home
    (let ((repo (expand-file-name "work/app/" home)))
      (tandem-test--tree repo "src/lib/x.py" "services/api/CLAUDE.md" "services/api/main.go")
      (tandem-test--git repo)
      (should (equal (tandem-test--root-from (expand-file-name "src/lib" repo))
                     (directory-file-name repo)))
      ;; A subfolder with its own instructions is still the repository.
      (should (equal (tandem-test--root-from (expand-file-name "services/api" repo))
                     (directory-file-name repo))))))

(ert-deftest tandem-project-a-monorepo-subfolder-on-request ()
  (tandem-test-with-home
    (let ((repo (expand-file-name "mono/" home)))
      (tandem-test--tree repo "services/api/AGENTS.md" "services/api/handlers/h.go" "web/x.ts")
      (tandem-test--git repo)
      (let ((tandem-project-root 'nearest-instructions))
        (should (equal (tandem-test--root-from (expand-file-name "services/api/handlers" repo))
                       (directory-file-name (expand-file-name "services/api" repo))))
        ;; No instructions of its own on the way up: the repository.
        (should (equal (tandem-test--root-from (expand-file-name "web" repo))
                       (directory-file-name repo))))
      (let ((tandem-project-root 'ask) offered)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _) (setq offered choices) (car choices))))
          (should (equal (tandem-test--root-from (expand-file-name "services/api/handlers" repo))
                         (directory-file-name repo)))
          (should (= (length offered) 2))))
      (let ((tandem-project-root (lambda () (expand-file-name "web" repo))))
        (should (equal (tandem-test--root-from (expand-file-name "services/api" repo))
                       (directory-file-name (expand-file-name "web" repo))))))))

(ert-deftest tandem-project-without-git-the-nearest-marker ()
  (tandem-test-with-home
    (let ((proj (expand-file-name "notes/site/" home)))
      (tandem-test--tree proj "package.json" "src/pages/index.js")
      (should (equal (tandem-test--root-from (expand-file-name "src/pages" proj))
                     (directory-file-name proj))))))

(ert-deftest tandem-project-without-git-or-markers-it-asks ()
  (tandem-test-with-home
    (let ((dir (expand-file-name "scratch/ideas/" home)) asked)
      (tandem-test--tree dir "a.txt")
      (cl-letf (((symbol-function 'read-directory-name)
                 (lambda (_prompt default &rest _) (setq asked default) default)))
        (should (equal (tandem-test--root-from dir) (directory-file-name dir)))
        (should (equal asked dir))))))

(ert-deftest tandem-project-never-home-without-asking ()
  (tandem-test-with-home
    ;; Markers in your home folder do not make it a project.
    (tandem-test--tree home "Makefile" "package.json" "loose/a.txt")
    (let (confirmed)
      (cl-letf (((symbol-function 'read-directory-name)
                 (lambda (_prompt _default &rest _) home))
                ((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (setq confirmed prompt) t)))
        (should (equal (tandem-test--root-from (expand-file-name "loose" home))
                       (directory-file-name home)))
        (should (string-match-p "every file in" confirmed))))
    ;; Declining asks again; the second answer is used.
    (let ((answers (list home (expand-file-name "loose/" home))))
      (cl-letf (((symbol-function 'read-directory-name)
                 (lambda (&rest _) (pop answers)))
                ((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (should (equal (tandem-test--root-from home)
                       (directory-file-name (expand-file-name "loose" home))))))))

(ert-deftest tandem-project-a-repository-at-home-asks ()
  ;; A dotfiles repository makes your home folder a repository.
  (tandem-test-with-home
    (tandem-test--tree home "dots/.bashrc")
    (tandem-test--git home)
    (let (asked)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) t)))
        (should (equal (tandem-test--root-from (expand-file-name "dots" home))
                       (directory-file-name home)))
        (should asked)))))

(ert-deftest tandem-project-batch-emacs-never-waits ()
  (tandem-test-with-home
    (let ((dir (expand-file-name "scratch/" home))
          (noninteractive t))
      (tandem-test--tree dir "a.txt")
      (should-error (tandem-test--root-from dir) :type 'user-error))))

(ert-deftest tandem-project-too-wide ()
  (tandem-test-with-home
    (should (tandem-project--too-wide-p home))
    (should (tandem-project--too-wide-p "/"))
    (should (tandem-project--too-wide-p (file-name-directory (directory-file-name home))))
    (should-not (tandem-project--too-wide-p (expand-file-name "work" home)))))

(provide 'tandem-project-tests)
;;; tandem-project-tests.el ends here
