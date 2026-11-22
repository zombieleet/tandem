;;; tandem-magit-tests.el --- Tests for Claude's work into git commits  -*- lexical-binding: t; -*-

;;; Commentary:

;; A git repository where Claude wrote some lines and you others: staging
;; only Claude's, the trailer, and the commit message's command and
;; insertion.  The commit buffer test needs Magit's git-commit (see
;; TANDEM_TEST_PACKAGES); without it, that test is skipped.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-magit)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-repo (&rest body)
  "Run BODY in a git repository ROOT holding geo.py, committed."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (tandem-test--private-dir)))
          (default-directory root)
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                         "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "geo.py" root)
             (insert "import math\n\n\ndef area(r):\n    return math.pi * r * r\n\n\ndef main():\n    print(area(2))\n"))
           (tandem-magit--git root "init" "-q")
           (tandem-magit--git root "add" ".")
           (tandem-magit--git root "commit" "-q" "-m" "init")
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory root t))))

(defun tandem-test--write (file line text &optional claude)
  "In FILE, put TEXT after LINE (0: at the top); Claude's with CLAUDE.  Save."
  (with-current-buffer (find-file-noselect (expand-file-name file))
    (goto-char (point-min))
    (forward-line line)
    (let ((start (point)))
      (insert text)
      (when claude
        (tandem-authorship-mark start (point) (tandem-authorship-record :session "s1" :file file))))
    (let ((save-silently t)) (save-buffer))))

(ert-deftest tandem-magit-stages-only-claudes-hunks ()
  (tandem-test-with-repo
    (tandem-test--write "geo.py" 1 "import sys\n")                          ; yours
    (tandem-test--write "geo.py" 6 "    \"\"\"Area of a circle.\"\"\"\n" t) ; Claude's
    (with-temp-file (expand-file-name "notes.txt" root) (insert "mine\n"))      ; yours, new
    (with-current-buffer (find-file-noselect (expand-file-name "util.py" root)) ; Claude's, new
      (insert "def double(x):\n    return 2 * x\n")
      (tandem-authorship-mark (point-min) (point-max) (tandem-authorship-record :session "s1"))
      (let ((save-silently t)) (save-buffer)))
    (should (equal (tandem-magit-stage-claude) '(1 1 2)))
    (let ((staged (tandem-magit--git root "diff" "--cached"))
          (unstaged (tandem-magit--git root "diff")))
      (should (string-match-p "^\\+    \"\"\"Area of a circle\\.\"\"\"$" staged))
      (should-not (string-match-p "import sys" staged))
      (should (string-match-p "^\\+import sys$" unstaged))
      (should (string-match-p "util\\.py" staged))
      (should-not (string-match-p "notes\\.txt" staged)))
    ;; Staged hunks hold Claude's lines; the trailer is due.
    (should (tandem-magit--staged-has-claude-p root))))

(ert-deftest tandem-magit-unsaved-files-are-left-alone ()
  (tandem-test-with-repo
    (tandem-test--write "geo.py" 6 "    \"\"\"Area.\"\"\"\n" t)
    (with-current-buffer (find-buffer-visiting (expand-file-name "geo.py" root))
      (goto-char (point-max))
      (insert "# unsaved\n"))
    (should (equal (tandem-magit-stage-claude) '(0 0 1)))
    (should (string-empty-p (tandem-magit--git root "diff" "--cached")))))

(ert-deftest tandem-magit-nothing-of-claudes ()
  (tandem-test-with-repo
    (tandem-test--write "geo.py" 1 "import sys\n")
    (tandem-magit--git root "add" "geo.py")
    (should-not (tandem-magit--staged-has-claude-p root))
    (should (equal (tandem-magit-stage-claude) '(0 0 0)))))

(defconst tandem-test--trailer "Co-Authored-By: Claude <noreply@anthropic.com>"
  "A trailer some users want.")

(ert-deftest tandem-magit-trailer ()
  (let ((tandem-magit-trailer tandem-test--trailer))
  (with-temp-buffer
    (insert "Add a docstring\n\n# Please enter the commit message.\n# Lines starting with '#' are ignored.\n")
    (setq-local comment-start "#")
    (tandem-magit-add-trailer)
    (tandem-magit-add-trailer)
    (should (equal (buffer-string)
                   (concat "Add a docstring\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n\n"
                           "# Please enter the commit message.\n# Lines starting with '#' are ignored.\n")))))
  ;; By default there is none.
  (should-not (default-value 'tandem-magit-trailer))
  (let ((tandem-magit-trailer nil))
    (with-temp-buffer
      (tandem-magit-add-trailer)
      (should (equal (buffer-string) "")))))

(ert-deftest tandem-magit-draft-replaces-the-message-keeps-the-trailer ()
  (let ((tandem-magit-trailer tandem-test--trailer))
  (with-temp-buffer
    (setq-local comment-start "#")
    (insert "\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n# comment\n")
    (tandem-magit--insert-message (current-buffer) "Add a docstring to area\n\nSo readers know it is a circle.\n")
    (should (equal (buffer-string)
                   (concat "Add a docstring to area\n\nSo readers know it is a circle.\n\n"
                           "Co-Authored-By: Claude <noreply@anthropic.com>\n\n# comment\n"))))))

(ert-deftest tandem-magit-draft-uses-a-copy-of-the-chat ()
  (tandem-test-with-repo
    (cl-letf (((symbol-function 'tandem-chat--claude-path) (lambda () "/usr/bin/claude"))
              ((symbol-function 'tandem-magit--chat-session) (lambda (_root) "sess-1")))
      (let ((command (tandem-magit--command root "diff --git a/x b/x")))
        (should (equal (seq-take command 6) '("/usr/bin/claude" "-p" "--output-format" "json" "--max-turns" "2")))
        (should (member "--fork-session" command))
        (should (member "--no-session-persistence" command))
        (should (equal (cadr (member "--resume" command)) "sess-1"))
        ;; The diff goes on standard input, never on the command line.
        (should-not (seq-some (lambda (arg) (string-match-p "diff --git" arg)) command))))
    (cl-letf (((symbol-function 'tandem-chat--claude-path) (lambda () "/usr/bin/claude"))
              ((symbol-function 'tandem-magit--chat-session) (lambda (_root) nil)))
      (let ((command (tandem-magit--command root "d")))
        (should-not (member "--resume" command))
        (should (member "--no-session-persistence" command))))))

(ert-deftest tandem-magit-in-a-commit-buffer ()
  (skip-unless (require 'git-commit nil t))
  (tandem-test-with-repo
    (tandem-test--write "geo.py" 6 "    \"\"\"Area.\"\"\"\n" t)
    (tandem-magit-stage-claude)
    (let ((file (expand-file-name ".git/COMMIT_EDITMSG" root)))
      (with-temp-file file (insert "\n# Please enter the commit message for your changes.\n"))
      (let ((buffer (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'text-mode))
              (should (bound-and-true-p git-commit-mode))
              ;; No trailer unless you ask for one.
              (should-not (string-match-p "Co-Authored-By" (buffer-string))))
          (with-current-buffer buffer
            (set-buffer-modified-p nil)
            (setq-local kill-buffer-query-functions nil))
          (kill-buffer buffer)))
      (let* ((tandem-magit-trailer tandem-test--trailer)
             (buffer (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "^Co-Authored-By: Claude <noreply@anthropic.com>$" (buffer-string))))
          (with-current-buffer buffer
            (set-buffer-modified-p nil)
            ;; with-editor would ask to cancel the commit instead.
            (setq-local kill-buffer-query-functions nil))
          (kill-buffer buffer))))))

(provide 'tandem-magit-tests)
;;; tandem-magit-tests.el ends here
