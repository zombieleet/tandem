;;; claude-pair-notes-tests.el --- Tests for Claude's lines in git notes  -*- lexical-binding: t; -*-

;;; Commentary:

;; A repository where Claude wrote a line: the note on the commit, the
;; lines mapped onto what was committed, and the colours coming back on a
;; machine that knows nothing, after later commits too.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-notes)
(require 'claude-pair-test-helpers)

(defmacro claude-pair-test-with-noted-repo (&rest body)
  "Run BODY in a git repository ROOT holding geo.py, committed."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (claude-pair-test--private-dir)))
          (default-directory root)
          (claude-pair-notes--has-notes (make-hash-table :test #'equal))
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                         "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "geo.py" root)
             (insert "import math\n\n\ndef area(r):\n    return math.pi * r * r\n"))
           (claude-pair-notes--ok root "init" "-q")
           (claude-pair-notes--ok root "add" ".")
           (claude-pair-notes--ok root "commit" "-q" "-m" "init")
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory root t))))

(defun claude-pair-test--claude-writes (line text)
  "In geo.py, put TEXT, Claude's, after LINE; save."
  (with-current-buffer (find-file-noselect (expand-file-name "geo.py"))
    (goto-char (point-min))
    (forward-line line)
    (let ((start (point)))
      (insert text)
      (claude-pair-authorship-mark start (point)
                                   (claude-pair-authorship-record :session "s1" :model "claude-test"
                                                                  :file (buffer-file-name))))
    (let ((save-silently t)) (save-buffer))))

(defun claude-pair-test--line-claudes-p (file text)
  "Return non-nil if the line TEXT in FILE's buffer is Claude's."
  (with-current-buffer (find-file-noselect (expand-file-name file))
    (save-excursion
      (goto-char (point-min))
      (and (search-forward text nil t)
           (claude-pair-authorship-at (match-beginning 0))))))

(defun claude-pair-test--fresh-machine (root)
  "Forget every colour this machine knows of files under ROOT, as on another clone."
  (dolist (b (buffer-list))
    (when (and (buffer-file-name b) (string-prefix-p root (buffer-file-name b)))
      (kill-buffer b)))
  (dolist (f (directory-files claude-pair-attribution-directory t "\\.json\\'"))
    (delete-file f))
  (clrhash claude-pair-notes--has-notes))

(ert-deftest claude-pair-notes-written-on-a-commit ()
  (claude-pair-test-with-noted-repo
    (claude-pair-test--claude-writes 4 "    \"\"\"Area of a circle.\"\"\"\n")
    ;; A line of yours, not committed: the note must count without it.
    (with-current-buffer (find-buffer-visiting (expand-file-name "geo.py"))
      (goto-char (point-min))
      (insert "# mine, not committed\n")
      (let ((save-silently t)) (save-buffer)))
    (with-temp-buffer
      ;; Commit only Claude's line: the file as it was plus the docstring.
      (insert "import math\n\n\ndef area(r):\n    \"\"\"Area of a circle.\"\"\"\n    return math.pi * r * r\n")
      (let ((blob (string-trim (cdr (claude-pair-notes--git root (buffer-string) "hash-object" "-w" "--stdin")))))
        (claude-pair-notes--ok root "update-index" "--cacheinfo" (concat "100644," blob ",geo.py"))))
    (claude-pair-notes--ok root "commit" "-q" "-m" "docstring")
    (should (= (claude-pair-notes-write) 1))
    (let* ((note (json-parse-string (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "show" "HEAD")
                                    :object-type 'plist :array-type 'list))
           (entry (plist-get (plist-get note :files) :geo.py)))
      (should (= (length (plist-get entry :lines)) 6))
      ;; Line 4 (from 0) of the committed file, not of your working copy.
      (should (equal (car (car (plist-get entry :claude))) 4))
      (should (equal (plist-get (car (plist-get entry :records)) :model) "claude-test"))
      ;; No paths of this machine in a note others will read.
      (should-not (plist-member (car (plist-get entry :records)) :file))
      (should-not (string-match-p "personal\\|/tmp/\\|/home/" (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "show" "HEAD"))))))

(ert-deftest claude-pair-notes-from-the-commit-buffers-folder ()
  ;; The hook runs where the commit message was: inside .git.
  (claude-pair-test-with-noted-repo
    (claude-pair-test--claude-writes 4 "    \"\"\"Area.\"\"\"\n")
    (claude-pair-notes--ok root "commit" "-q" "-am" "docstring")
    (let ((default-directory (expand-file-name ".git/" root)))
      (should (equal (claude-pair-notes--root default-directory) root))
      (should (= (claude-pair-notes-write) 1)))
    ;; And from a linked worktree's git directory.
    (let ((tree (expand-file-name "wt" (claude-pair-test--private-dir))))
      (claude-pair-notes--ok root "worktree" "add" "-q" "-b" "wt" tree)
      (should (equal (claude-pair-notes--root (expand-file-name ".git/worktrees/wt/" root))
                     (file-name-as-directory tree)))
      (claude-pair-notes--ok root "worktree" "remove" "--force" tree))))

(ert-deftest claude-pair-notes-nothing-of-claudes-no-note ()
  (claude-pair-test-with-noted-repo
    (with-temp-file (expand-file-name "geo.py") (insert "import math\n# mine\n"))
    (claude-pair-notes--ok root "commit" "-q" "-am" "mine")
    (should (= (claude-pair-notes-write) 0))
    (should-not (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "show" "HEAD"))))

(ert-deftest claude-pair-notes-colours-come-back ()
  (claude-pair-test-with-noted-repo
    (claude-pair-test--claude-writes 4 "    \"\"\"Area of a circle.\"\"\"\n")
    (claude-pair-notes--ok root "commit" "-q" "-am" "docstring")
    (claude-pair-notes-write)
    ;; Then a commit of yours elsewhere in the file, with no note.
    (claude-pair-test--fresh-machine root)
    (with-temp-file (expand-file-name "geo.py")
      (insert "import math\nimport sys\n\n\ndef area(r):\n    \"\"\"Area of a circle.\"\"\"\n    return math.pi * r * r\n"))
    (claude-pair-notes--ok root "commit" "-q" "-am" "sys")
    ;; On a machine that knows nothing, opening the file finds the note.
    (claude-pair-test--fresh-machine root)
    (should (claude-pair-test--line-claudes-p "geo.py" "\"\"\"Area of a circle.\"\"\""))
    (should-not (claude-pair-test--line-claudes-p "geo.py" "import sys"))
    (should (equal (plist-get (claude-pair-authorship-record-of
                               (claude-pair-test--line-claudes-p "geo.py" "\"\"\"Area of a circle.\"\"\""))
                              :model)
                   "claude-test"))))

(ert-deftest claude-pair-notes-a-repository-without-notes-costs-nothing ()
  (claude-pair-test-with-noted-repo
    (should-not (claude-pair-notes--noted root))
    (with-current-buffer (find-file-noselect (expand-file-name "geo.py"))
      (should (= (claude-pair-notes-restore) 0)))))

(defun claude-pair-test--note-of (dir commit)
  "Return the files noted on COMMIT in DIR's own notes, as a list of names."
  (when-let* ((note (claude-pair-notes--ok dir "notes" "--ref" claude-pair-notes-ref "show" commit)))
    (cl-loop for (key _) on (plist-get (json-parse-string note :object-type 'plist) :files) by #'cddr
             collect (substring (symbol-name key) 1))))

(ert-deftest claude-pair-notes-shared-by-two-without-losing-any ()
  (claude-pair-test-with-noted-repo
    (let* ((remote (claude-pair-test--private-dir))
           (other (file-name-as-directory (expand-file-name "other" (claude-pair-test--private-dir))))
           (yes (lambda (_) t)))
      (unwind-protect
          (progn
            (claude-pair-notes--ok remote "init" "-q" "--bare")
            (claude-pair-notes--ok root "remote" "add" "origin" remote)
            ;; You: a commit with Claude's line, noted, shared.
            (claude-pair-test--claude-writes 4 "    \"\"\"Area.\"\"\"\n")
            (claude-pair-notes--ok root "commit" "-q" "-am" "docstring")
            (claude-pair-notes-write)
            (let ((mine (string-trim (claude-pair-notes--ok root "rev-parse" "HEAD"))))
              (claude-pair-notes--ok root "push" "-q" "origin" "HEAD:refs/heads/main")
              (cl-letf (((symbol-function 'y-or-n-p) yes))
                (claude-pair-notes-share "origin"))
              (should (member "+refs/notes/claude-pair:refs/notes/remotes/origin/claude-pair"
                              (split-string (claude-pair-notes--ok root "config" "--get-all" "remote.origin.fetch") "\n" t)))
              ;; A colleague: clones, shares, and reads your note without merging.
              (claude-pair-notes--ok (file-name-directory (directory-file-name other)) "clone" "-q" "-b" "main" remote other)
              (let ((default-directory other))
                (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
                  (claude-pair-notes-share "origin")))
              (should (equal (claude-pair-test--note-of other mine) '("geo.py")))
              (with-current-buffer (find-file-noselect (expand-file-name "geo.py" other))
                (should (claude-pair-authorship-at (save-excursion (goto-char (point-min)) (search-forward "Area.")))))
              ;; They note a commit of their own and push it.
              (with-current-buffer (find-file-noselect (expand-file-name "geo.py" other))
                (goto-char (point-max))
                (let ((start (point)))
                  (insert "\ndef twice(r):\n    return 2 * area(r)\n")
                  (claude-pair-authorship-mark start (point) (claude-pair-authorship-record :model "theirs")))
                (let ((save-silently t)) (save-buffer)))
              (claude-pair-notes--ok other "commit" "-q" "-am" "twice")
              (let ((default-directory other))
                (claude-pair-notes-write)
                (cl-letf (((symbol-function 'y-or-n-p) yes))
                  (claude-pair-notes-share "origin")))
              (claude-pair-notes--ok other "push" "-q" "origin" "HEAD:refs/heads/main")
              (let ((theirs (string-trim (claude-pair-notes--ok other "rev-parse" "HEAD"))))
                ;; Meanwhile you noted another commit, not pushed yet.
                (with-temp-file (expand-file-name "notes.txt" root) (insert "x\n"))
                (claude-pair-notes--ok root "add" "notes.txt")
                (claude-pair-notes--ok root "commit" "-q" "-m" "local")
                (let ((local (string-trim (claude-pair-notes--ok root "rev-parse" "HEAD"))))
                  (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "add" "-m"
                                         "{\"version\":1,\"files\":{}}" local)
                  ;; A plain fetch brings theirs apart and leaves yours alone.
                  (claude-pair-notes--ok root "fetch" "-q" "origin")
                  (should (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "show" local))
                  (should-not (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "show" theirs))
                  (should (claude-pair-notes--ok root "notes" "--ref" "refs/notes/remotes/origin/claude-pair" "show" theirs))
                  ;; Sharing merges and pushes: all three notes, everywhere.
                  (cl-letf (((symbol-function 'y-or-n-p) yes))
                    (claude-pair-notes-share "origin"))
                  (dolist (commit (list mine theirs local))
                    (should (claude-pair-notes--ok root "notes" "--ref" claude-pair-notes-ref "show" commit))
                    (should (claude-pair-notes--ok remote "notes" "--ref" claude-pair-notes-ref "show" commit)))))))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p other (buffer-file-name b)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))
        (delete-directory remote t)
        (delete-directory (file-name-directory (directory-file-name other)) t)))))

(ert-deftest claude-pair-notes-written-after-a-magit-commit ()
  (skip-unless (require 'git-commit nil t))
  (should (memq #'claude-pair-notes--after-commit git-commit-post-finish-hook)))

(provide 'claude-pair-notes-tests)
;;; claude-pair-notes-tests.el ends here
