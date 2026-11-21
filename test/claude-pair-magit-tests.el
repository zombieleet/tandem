;;; claude-pair-magit-tests.el --- Tests for Claude's work into git commits  -*- lexical-binding: t; -*-

;;; Commentary:

;; A git repository where Claude wrote some lines and you others: staging
;; only Claude's, the trailer, and the commit message's command and
;; insertion.  The commit buffer test needs Magit's git-commit (see
;; CLAUDE_PAIR_TEST_PACKAGES); without it, that test is skipped.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-magit)
(require 'claude-pair-test-helpers)

(defmacro claude-pair-test-with-repo (&rest body)
  "Run BODY in a git repository ROOT holding geo.py, committed."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (claude-pair-test--private-dir)))
          (default-directory root)
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                         "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "geo.py" root)
             (insert "import math\n\n\ndef area(r):\n    return math.pi * r * r\n\n\ndef main():\n    print(area(2))\n"))
           (claude-pair-magit--git root "init" "-q")
           (claude-pair-magit--git root "add" ".")
           (claude-pair-magit--git root "commit" "-q" "-m" "init")
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory root t))))

(defun claude-pair-test--write (file line text &optional claude)
  "In FILE, put TEXT after LINE (0: at the top); Claude's with CLAUDE.  Save."
  (with-current-buffer (find-file-noselect (expand-file-name file))
    (goto-char (point-min))
    (forward-line line)
    (let ((start (point)))
      (insert text)
      (when claude
        (claude-pair-authorship-mark start (point) (claude-pair-authorship-record :session "s1" :file file))))
    (let ((save-silently t)) (save-buffer))))

(ert-deftest claude-pair-magit-stages-only-claudes-hunks ()
  (claude-pair-test-with-repo
    (claude-pair-test--write "geo.py" 1 "import sys\n")                          ; yours
    (claude-pair-test--write "geo.py" 6 "    \"\"\"Area of a circle.\"\"\"\n" t) ; Claude's
    (with-temp-file (expand-file-name "notes.txt" root) (insert "mine\n"))      ; yours, new
    (with-current-buffer (find-file-noselect (expand-file-name "util.py" root)) ; Claude's, new
      (insert "def double(x):\n    return 2 * x\n")
      (claude-pair-authorship-mark (point-min) (point-max) (claude-pair-authorship-record :session "s1"))
      (let ((save-silently t)) (save-buffer)))
    (should (equal (claude-pair-magit-stage-claude) '(1 1 2)))
    (let ((staged (claude-pair-magit--git root "diff" "--cached"))
          (unstaged (claude-pair-magit--git root "diff")))
      (should (string-match-p "^\\+    \"\"\"Area of a circle\\.\"\"\"$" staged))
      (should-not (string-match-p "import sys" staged))
      (should (string-match-p "^\\+import sys$" unstaged))
      (should (string-match-p "util\\.py" staged))
      (should-not (string-match-p "notes\\.txt" staged)))
    ;; Staged hunks hold Claude's lines; the trailer is due.
    (should (claude-pair-magit--staged-has-claude-p root))))

(ert-deftest claude-pair-magit-unsaved-files-are-left-alone ()
  (claude-pair-test-with-repo
    (claude-pair-test--write "geo.py" 6 "    \"\"\"Area.\"\"\"\n" t)
    (with-current-buffer (find-buffer-visiting (expand-file-name "geo.py" root))
      (goto-char (point-max))
      (insert "# unsaved\n"))
    (should (equal (claude-pair-magit-stage-claude) '(0 0 1)))
    (should (string-empty-p (claude-pair-magit--git root "diff" "--cached")))))

(ert-deftest claude-pair-magit-nothing-of-claudes ()
  (claude-pair-test-with-repo
    (claude-pair-test--write "geo.py" 1 "import sys\n")
    (claude-pair-magit--git root "add" "geo.py")
    (should-not (claude-pair-magit--staged-has-claude-p root))
    (should (equal (claude-pair-magit-stage-claude) '(0 0 0)))))

(defconst claude-pair-test--trailer "Co-Authored-By: Claude <noreply@anthropic.com>"
  "A trailer some users want.")

(ert-deftest claude-pair-magit-trailer ()
  (let ((claude-pair-magit-trailer claude-pair-test--trailer))
  (with-temp-buffer
    (insert "Add a docstring\n\n# Please enter the commit message.\n# Lines starting with '#' are ignored.\n")
    (setq-local comment-start "#")
    (claude-pair-magit-add-trailer)
    (claude-pair-magit-add-trailer)
    (should (equal (buffer-string)
                   (concat "Add a docstring\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n\n"
                           "# Please enter the commit message.\n# Lines starting with '#' are ignored.\n")))))
  ;; By default there is none.
  (should-not (default-value 'claude-pair-magit-trailer))
  (let ((claude-pair-magit-trailer nil))
    (with-temp-buffer
      (claude-pair-magit-add-trailer)
      (should (equal (buffer-string) "")))))

(ert-deftest claude-pair-magit-draft-replaces-the-message-keeps-the-trailer ()
  (let ((claude-pair-magit-trailer claude-pair-test--trailer))
  (with-temp-buffer
    (setq-local comment-start "#")
    (insert "\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n# comment\n")
    (claude-pair-magit--insert-message (current-buffer) "Add a docstring to area\n\nSo readers know it is a circle.\n")
    (should (equal (buffer-string)
                   (concat "Add a docstring to area\n\nSo readers know it is a circle.\n\n"
                           "Co-Authored-By: Claude <noreply@anthropic.com>\n\n# comment\n"))))))

(ert-deftest claude-pair-magit-draft-uses-a-copy-of-the-chat ()
  (claude-pair-test-with-repo
    (cl-letf (((symbol-function 'claude-pair-chat--claude-path) (lambda () "/usr/bin/claude"))
              ((symbol-function 'claude-pair-magit--chat-session) (lambda (_root) "sess-1")))
      (let ((command (claude-pair-magit--command root "diff --git a/x b/x")))
        (should (equal (seq-take command 6) '("/usr/bin/claude" "-p" "--output-format" "json" "--max-turns" "2")))
        (should (member "--fork-session" command))
        (should (member "--no-session-persistence" command))
        (should (equal (cadr (member "--resume" command)) "sess-1"))
        (should (string-match-p "diff --git a/x b/x\\'" (car (last command))))))
    (cl-letf (((symbol-function 'claude-pair-chat--claude-path) (lambda () "/usr/bin/claude"))
              ((symbol-function 'claude-pair-magit--chat-session) (lambda (_root) nil)))
      (let ((command (claude-pair-magit--command root "d")))
        (should-not (member "--resume" command))
        (should (member "--no-session-persistence" command))))))

(ert-deftest claude-pair-magit-in-a-commit-buffer ()
  (skip-unless (require 'git-commit nil t))
  (claude-pair-test-with-repo
    (claude-pair-test--write "geo.py" 6 "    \"\"\"Area.\"\"\"\n" t)
    (claude-pair-magit-stage-claude)
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
      (let* ((claude-pair-magit-trailer claude-pair-test--trailer)
             (buffer (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "^Co-Authored-By: Claude <noreply@anthropic.com>$" (buffer-string))))
          (with-current-buffer buffer
            (set-buffer-modified-p nil)
            ;; with-editor would ask to cancel the commit instead.
            (setq-local kill-buffer-query-functions nil))
          (kill-buffer buffer))))))

(provide 'claude-pair-magit-tests)
;;; claude-pair-magit-tests.el ends here
