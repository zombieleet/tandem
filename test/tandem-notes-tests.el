;;; tandem-notes-tests.el --- Tests for Claude's lines in git notes  -*- lexical-binding: t; -*-

;;; Commentary:

;; A repository where Claude wrote a line: the note on the commit, the
;; lines mapped onto what was committed, and the colours coming back on a
;; machine that knows nothing, after later commits too.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-notes)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-noted-repo (&rest body)
  "Run BODY in a git repository ROOT holding geo.py, committed."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (tandem-test--private-dir)))
          (default-directory root)
          (tandem-notes--has-notes (make-hash-table :test #'equal))
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                         "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "geo.py" root)
             (insert "import math\n\n\ndef area(r):\n    return math.pi * r * r\n"))
           (tandem-notes--ok root "init" "-q")
           (tandem-notes--ok root "add" ".")
           (tandem-notes--ok root "commit" "-q" "-m" "init")
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory root t))))

(defun tandem-test--claude-writes (line text)
  "In geo.py, put TEXT, Claude's, after LINE; save."
  (with-current-buffer (find-file-noselect (expand-file-name "geo.py"))
    (goto-char (point-min))
    (forward-line line)
    (let ((start (point)))
      (insert text)
      (tandem-authorship-mark start (point)
                                   (tandem-authorship-record :session "s1" :model "claude-test"
                                                                  :file (buffer-file-name))))
    (let ((save-silently t)) (save-buffer))))

(defun tandem-test--line-claudes-p (file text)
  "Return non-nil if the line TEXT in FILE's buffer is Claude's."
  (with-current-buffer (find-file-noselect (expand-file-name file))
    (save-excursion
      (goto-char (point-min))
      (and (search-forward text nil t)
           (tandem-authorship-at (match-beginning 0))))))

(defun tandem-test--fresh-machine (root)
  "Forget every colour this machine knows of files under ROOT, as on another clone."
  (dolist (b (buffer-list))
    (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
      (kill-buffer b)))
  (dolist (f (directory-files tandem-attribution-directory t "\\.json\\'"))
    (delete-file f))
  (clrhash tandem-notes--has-notes))

(ert-deftest tandem-notes-written-on-a-commit ()
  (tandem-test-with-noted-repo
    (tandem-test--claude-writes 4 "    \"\"\"Area of a circle.\"\"\"\n")
    ;; A line of yours, not committed: the note must count without it.
    (with-current-buffer (find-buffer-visiting (expand-file-name "geo.py"))
      (goto-char (point-min))
      (insert "# mine, not committed\n")
      (let ((save-silently t)) (save-buffer)))
    (with-temp-buffer
      ;; Commit only Claude's line: the file as it was plus the docstring.
      (insert "import math\n\n\ndef area(r):\n    \"\"\"Area of a circle.\"\"\"\n    return math.pi * r * r\n")
      (let ((blob (string-trim (cdr (tandem-notes--git root (buffer-string) "hash-object" "-w" "--stdin")))))
        (tandem-notes--ok root "update-index" "--cacheinfo" (concat "100644," blob ",geo.py"))))
    (tandem-notes--ok root "commit" "-q" "-m" "docstring")
    (should (= (tandem-notes-write) 1))
    (let* ((note (json-parse-string (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "show" "HEAD")
                                    :object-type 'plist :array-type 'list))
           (entry (plist-get (plist-get note :files) :geo.py)))
      (should (= (length (plist-get entry :lines)) 6))
      ;; Line 4 (from 0) of the committed file, not of your working copy.
      (should (equal (car (car (plist-get entry :claude))) 4))
      (should (equal (plist-get (car (plist-get entry :records)) :model) "claude-test"))
      ;; No paths of this machine in a note others will read.
      (should-not (plist-member (car (plist-get entry :records)) :file))
      (should-not (string-match-p "personal\\|/tmp/\\|/home/" (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "show" "HEAD"))))))

(ert-deftest tandem-notes-from-the-commit-buffers-folder ()
  ;; The hook runs where the commit message was: inside .git.
  (tandem-test-with-noted-repo
    (tandem-test--claude-writes 4 "    \"\"\"Area.\"\"\"\n")
    (tandem-notes--ok root "commit" "-q" "-am" "docstring")
    (let ((default-directory (expand-file-name ".git/" root)))
      (should (equal (tandem-notes--root default-directory) root))
      (should (= (tandem-notes-write) 1)))
    ;; And from a linked worktree's git directory.
    (let ((tree (expand-file-name "wt" (tandem-test--private-dir))))
      (tandem-notes--ok root "worktree" "add" "-q" "-b" "wt" tree)
      (should (equal (tandem-notes--root (expand-file-name ".git/worktrees/wt/" root))
                     (file-name-as-directory tree)))
      (tandem-notes--ok root "worktree" "remove" "--force" tree))))

(ert-deftest tandem-notes-nothing-of-claudes-no-note ()
  (tandem-test-with-noted-repo
    (with-temp-file (expand-file-name "geo.py") (insert "import math\n# mine\n"))
    (tandem-notes--ok root "commit" "-q" "-am" "mine")
    (should (= (tandem-notes-write) 0))
    (should-not (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "show" "HEAD"))))

(ert-deftest tandem-notes-colours-come-back ()
  (tandem-test-with-noted-repo
    (tandem-test--claude-writes 4 "    \"\"\"Area of a circle.\"\"\"\n")
    (tandem-notes--ok root "commit" "-q" "-am" "docstring")
    (tandem-notes-write)
    ;; Then a commit of yours elsewhere in the file, with no note.
    (tandem-test--fresh-machine root)
    (with-temp-file (expand-file-name "geo.py")
      (insert "import math\nimport sys\n\n\ndef area(r):\n    \"\"\"Area of a circle.\"\"\"\n    return math.pi * r * r\n"))
    (tandem-notes--ok root "commit" "-q" "-am" "sys")
    ;; On a machine that knows nothing, opening the file finds the note.
    (tandem-test--fresh-machine root)
    (should (tandem-test--line-claudes-p "geo.py" "\"\"\"Area of a circle.\"\"\""))
    (should-not (tandem-test--line-claudes-p "geo.py" "import sys"))
    (should (equal (plist-get (tandem-authorship-record-of
                               (tandem-test--line-claudes-p "geo.py" "\"\"\"Area of a circle.\"\"\""))
                              :model)
                   "claude-test"))))

(ert-deftest tandem-notes-a-repository-without-notes-costs-nothing ()
  (tandem-test-with-noted-repo
    (should-not (tandem-notes--noted root))
    (with-current-buffer (find-file-noselect (expand-file-name "geo.py"))
      (should (= (tandem-notes-restore) 0)))))

(defun tandem-test--note-of (dir commit)
  "Return the files noted on COMMIT in DIR's own notes, as a list of names."
  (when-let* ((note (tandem-notes--ok dir "notes" "--ref" tandem-notes-ref "show" commit)))
    (cl-loop for (key _) on (plist-get (json-parse-string note :object-type 'plist) :files) by #'cddr
             collect (substring (symbol-name key) 1))))

(ert-deftest tandem-notes-shared-by-two-without-losing-any ()
  (tandem-test-with-noted-repo
    (let* ((remote (tandem-test--private-dir))
           (other (file-name-as-directory (expand-file-name "other" (tandem-test--private-dir))))
           (yes (lambda (_) t)))
      (unwind-protect
          (progn
            (tandem-notes--ok remote "init" "-q" "--bare")
            (tandem-notes--ok root "remote" "add" "origin" remote)
            ;; You: a commit with Claude's line, noted, shared.
            (tandem-test--claude-writes 4 "    \"\"\"Area.\"\"\"\n")
            (tandem-notes--ok root "commit" "-q" "-am" "docstring")
            (tandem-notes-write)
            (let ((mine (string-trim (tandem-notes--ok root "rev-parse" "HEAD"))))
              (tandem-notes--ok root "push" "-q" "origin" "HEAD:refs/heads/main")
              (cl-letf (((symbol-function 'y-or-n-p) yes))
                (tandem-notes-share "origin"))
              (should (member "+refs/notes/tandem:refs/notes/remotes/origin/tandem"
                              (split-string (tandem-notes--ok root "config" "--get-all" "remote.origin.fetch") "\n" t)))
              ;; A colleague: clones, shares, and reads your note without merging.
              (tandem-notes--ok (file-name-directory (directory-file-name other)) "clone" "-q" "-b" "main" remote other)
              (let ((default-directory other))
                (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
                  (tandem-notes-share "origin")))
              (should (equal (tandem-test--note-of other mine) '("geo.py")))
              (with-current-buffer (find-file-noselect (expand-file-name "geo.py" other))
                (should (tandem-authorship-at (save-excursion (goto-char (point-min)) (search-forward "Area.")))))
              ;; They note a commit of their own and push it.
              (with-current-buffer (find-file-noselect (expand-file-name "geo.py" other))
                (goto-char (point-max))
                (let ((start (point)))
                  (insert "\ndef twice(r):\n    return 2 * area(r)\n")
                  (tandem-authorship-mark start (point) (tandem-authorship-record :model "theirs")))
                (let ((save-silently t)) (save-buffer)))
              (tandem-notes--ok other "commit" "-q" "-am" "twice")
              (let ((default-directory other))
                (tandem-notes-write)
                (cl-letf (((symbol-function 'y-or-n-p) yes))
                  (tandem-notes-share "origin")))
              (tandem-notes--ok other "push" "-q" "origin" "HEAD:refs/heads/main")
              (let ((theirs (string-trim (tandem-notes--ok other "rev-parse" "HEAD"))))
                ;; Meanwhile you noted another commit, not pushed yet.
                (with-temp-file (expand-file-name "notes.txt" root) (insert "x\n"))
                (tandem-notes--ok root "add" "notes.txt")
                (tandem-notes--ok root "commit" "-q" "-m" "local")
                (let ((local (string-trim (tandem-notes--ok root "rev-parse" "HEAD"))))
                  (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "add" "-m"
                                         "{\"version\":1,\"files\":{}}" local)
                  ;; A plain fetch brings theirs apart and leaves yours alone.
                  (tandem-notes--ok root "fetch" "-q" "origin")
                  (should (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "show" local))
                  (should-not (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "show" theirs))
                  (should (tandem-notes--ok root "notes" "--ref" "refs/notes/remotes/origin/tandem" "show" theirs))
                  ;; Sharing merges and pushes: all three notes, everywhere.
                  (cl-letf (((symbol-function 'y-or-n-p) yes))
                    (tandem-notes-share "origin"))
                  (dolist (commit (list mine theirs local))
                    (should (tandem-notes--ok root "notes" "--ref" tandem-notes-ref "show" commit))
                    (should (tandem-notes--ok remote "notes" "--ref" tandem-notes-ref "show" commit)))))))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p other (buffer-file-name b)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))
        (delete-directory remote t)
        (delete-directory (file-name-directory (directory-file-name other)) t)))))

(ert-deftest tandem-notes-written-after-a-magit-commit ()
  (skip-unless (require 'git-commit nil t))
  (should (memq #'tandem-notes--after-commit git-commit-post-finish-hook)))

(ert-deftest tandem-notes-read-under-the-old-name ()
  (tandem-test-with-noted-repo
    (tandem-test--claude-writes 4 "    \"\"\"Area.\"\"\"\n")
    (tandem-notes--ok root "commit" "-q" "-am" "docstring")
    (let ((tandem-notes-ref "refs/notes/claude-pair"))
      (tandem-notes-write))
    (should-not (tandem-notes--ok root "rev-parse" "--verify" "--quiet" "refs/notes/tandem"))
    (tandem-test--fresh-machine root)
    (should (tandem-test--line-claudes-p "geo.py" "\"\"\"Area.\"\"\""))))

(provide 'tandem-notes-tests)
;;; tandem-notes-tests.el ends here
