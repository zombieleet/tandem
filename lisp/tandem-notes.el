;;; tandem-notes.el --- Claude's lines kept in git notes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, vc
;; URL: https://github.com/victory/tandem

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Claude's lines keep their colour on this machine (see
;; tandem-authorship.el).  With git notes they travel with the
;; repository: to another clone, another machine, a colleague.
;;
;; When you commit with Magit, a note on the new commit, in
;; refs/notes/tandem, says which of the committed lines are Claude's.
;; It holds fingerprints of the lines and who wrote them, never the code.
;; When you open a file that has no colours on this machine, the nearest
;; note on it gives them back, matched by a diff, so later changes are
;; fine.  M-x tandem-notes-write writes the note for any commit, for
;; commits made outside Emacs.
;;
;; Notes stay local until you share them: M-x tandem-notes-share has
;; origin fetch them from now on, into refs/notes/remotes/origin/, apart
;; from yours so a fetch never overwrites them, and pushes yours after
;; merging the two.

;;; Code:

(require 'cl-lib)
(require 'tandem-authorship)
(require 'seq)
(require 'subr-x)

(defcustom tandem-notes-ref "refs/notes/tandem"
  "The git notes ref that holds Claude's lines."
  :type 'string
  :group 'tandem)

(defcustom tandem-notes-automatic t
  "Non-nil to write a note on each commit made with Magit, and read notes on visit."
  :type 'boolean
  :group 'tandem)

;;;; git

(defun tandem-notes--git (dir input &rest args)
  "Run git with ARGS in DIR, INPUT on its standard input if non-nil.
Return (STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (cons (if input
                (progn (insert input)
                       (apply #'call-process-region (point-min) (point-max) "git" t t nil args))
              (apply #'process-file "git" nil t nil args))
            (buffer-string)))))

(defun tandem-notes--ok (dir &rest args)
  "Run git with ARGS in DIR; return its output, or nil if it failed."
  (let ((result (apply #'tandem-notes--git dir nil args)))
    (and (eql (car result) 0) (cdr result))))

(declare-function magit-toplevel "magit-git")

(defun tandem-notes--root (dir)
  "Return the top of the git worktree holding DIR, or nil.
DIR may be inside the repository's git directory, as the commit message
buffer is: then the worktree that git directory belongs to."
  (or (when-let* ((top (tandem-notes--ok dir "rev-parse" "--show-toplevel")))
        (file-name-as-directory (string-trim top)))
      (when (equal (string-trim (or (tandem-notes--ok dir "rev-parse" "--is-inside-git-dir") ""))
                   "true")
        (when-let* ((gitdir (tandem-notes--ok dir "rev-parse" "--absolute-git-dir")))
          (let* ((gitdir (file-name-as-directory (string-trim gitdir)))
                 (link (expand-file-name "gitdir" gitdir)))
            (cond
             ;; A linked worktree: its git directory names the worktree's .git file.
             ((file-readable-p link)
              (file-name-directory
               (string-trim (with-temp-buffer (insert-file-contents link) (buffer-string)))))
             ((equal (file-name-nondirectory (directory-file-name gitdir)) ".git")
              (file-name-directory (directory-file-name gitdir)))))))
      (and (fboundp 'magit-toplevel)
           (let ((default-directory dir))
             (when-let* ((top (ignore-errors (magit-toplevel))))
               (file-name-as-directory top))))))

;;;; Writing

(defun tandem-notes--source (file)
  "Return a snapshot of Claude's lines in FILE, or nil.
From its buffer if it has one without unsaved changes, else from what
this machine remembers of it."
  (let ((buffer (find-buffer-visiting file)))
    (if (and buffer (not (buffer-modified-p buffer)))
        (with-current-buffer buffer (tandem-authorship-snapshot))
      (let ((store (tandem-authorship--store file)))
        (when (file-readable-p store)
          (ignore-errors
            (json-parse-string (with-temp-buffer (insert-file-contents store) (buffer-string))
                               :object-type 'plist :array-type 'array
                               :null-object nil :false-object nil)))))))

(defun tandem-notes--committed (root commit file)
  "Return the fingerprints of FILE as COMMIT has it, under ROOT, or nil."
  (when-let* ((text (tandem-notes--ok root "show" (format "%s:%s" commit file))))
    (with-temp-buffer
      (insert text)
      (tandem-authorship--fingerprints))))

(defun tandem-notes--entry (root commit file)
  "Return the note entry for FILE in COMMIT under ROOT, or nil.
Claude's lines are mapped onto the file as committed: what you did not
commit is left out."
  (when-let* ((source (tandem-notes--source (expand-file-name file root)))
              (committed (tandem-notes--committed root commit file)))
    (let* ((moved (tandem-authorship--map-lines (plist-get source :lines) committed))
           (claude (delq nil (mapcar (lambda (entry)
                                       (when-let* ((line (gethash (aref entry 0) moved)))
                                         (vector line (aref entry 1))))
                                     (plist-get source :claude))))
           (ids (delete-dups (mapcar (lambda (entry) (aref entry 1)) claude))))
      (when claude
        (list :lines committed
              :claude (vconcat claude)
              ;; Shared with the repository: who and when, not where on this disk.
              :records (vconcat
                        (seq-keep (lambda (record)
                                    (when (member (plist-get record :id) ids)
                                      (cl-loop for (key value) on record by #'cddr
                                               unless (eq key :file) append (list key value))))
                                  (plist-get source :records))))))))

;;;###autoload
(defun tandem-notes-write (&optional commit)
  "Write the note on COMMIT (HEAD by default) saying which lines are Claude's.
Return the number of files in it; a commit with none of Claude's lines
gets no note."
  (interactive (list (read-string "Commit: " nil nil "HEAD")))
  (let* ((root (or (tandem-notes--root default-directory) (user-error "Not in a git repository")))
         (commit (string-trim (or (tandem-notes--ok root "rev-parse" "--verify" (or commit "HEAD"))
                                  (user-error "No commit %s" commit))))
         (files (split-string (or (tandem-notes--ok root "diff-tree" "--no-commit-id" "--name-only"
                                                         "-r" "--root" commit)
                                  "")
                              "\n" t))
         (entries nil))
    (dolist (file files)
      (when-let* ((entry (tandem-notes--entry root commit file)))
        (push (intern (concat ":" file)) entries)
        (push entry entries)))
    (setq entries (nreverse entries))
    (when entries
      (let ((result (tandem-notes--git
                     root (json-serialize (list :version 1 :files entries) :null-object nil :false-object :false)
                     "notes" "--ref" tandem-notes-ref "add" "-f" "-F" "-" commit)))
        (unless (eql (car result) 0)
          (error "Git notes failed: %s" (string-trim (cdr result))))))
    (when (called-interactively-p 'any)
      (message "tandem: %s" (if entries
                                     (format "noted Claude's lines in %d file%s of %s"
                                             (/ (length entries) 2) (if (> (length entries) 2) "s" "")
                                             (substring commit 0 8))
                                   "no lines of Claude's in that commit")))
    (/ (length entries) 2)))

(defun tandem-notes--after-commit ()
  "Write the note on the commit just made."
  (when tandem-notes-automatic
    (condition-case err
        (tandem-notes-write "HEAD")
      (error (message "tandem: could not note Claude's lines: %s" (error-message-string err))))))

;;;; Reading

(defvar tandem-notes--has-notes (make-hash-table :test #'equal)
  "From a worktree top to (TIME . NOTED), the commits with notes, lately.")

(defun tandem-notes--refs (root)
  "Return the notes refs to read under ROOT: yours first, then fetched ones.
Notes fetched from a remote stay apart, in refs/notes/remotes/REMOTE/,
so a fetch never overwrites yours."
  (let ((base (file-name-nondirectory tandem-notes-ref)))
    (append (list tandem-notes-ref)
            (split-string (or (tandem-notes--ok root "for-each-ref" "--format=%(refname)"
                                                     (format "refs/notes/remotes/*/%s" base))
                              "")
                          "\n" t)
            ;; Notes written under tandem's old name, claude-pair.
            (when (tandem-notes--ok root "rev-parse" "--verify" "--quiet" "refs/notes/claude-pair")
              (list "refs/notes/claude-pair")))))

(defun tandem-notes--noted (root)
  "Return a table of the commits under ROOT with a note, to its ref; nil if none."
  (let ((cached (gethash root tandem-notes--has-notes)))
    (if (and cached (< (- (float-time) (car cached)) 30))
        (cdr cached)
      (let ((table nil))
        ;; Yours last, so yours win where both have a note.
        (dolist (ref (reverse (tandem-notes--refs root)))
          (when-let* ((list (tandem-notes--ok root "notes" "--ref" ref "list")))
            (dolist (line (split-string list "\n" t))
              (unless table (setq table (make-hash-table :test #'equal)))
              (puthash (cadr (split-string line)) ref table))))
        (puthash root (cons (float-time) table) tandem-notes--has-notes)
        table))))

(defun tandem-notes-restore ()
  "Colour Claude's lines in this file from the nearest git note on it.
Return how many lines were marked."
  (interactive)
  (let ((marked 0))
    (when-let* ((file buffer-file-name)
                (root (tandem-notes--root (file-name-directory file)))
                (noted (tandem-notes--noted root))
                (relative (file-relative-name (file-truename file) (file-truename root)))
                (commits (tandem-notes--ok root "log" "--format=%H" "-n" "100" "--" relative)))
      (catch 'done
        (dolist (commit (split-string commits "\n" t))
          (when-let* ((ref (gethash commit noted))
                      (note (tandem-notes--ok root "notes" "--ref" ref "show" commit))
                      (data (ignore-errors
                              (json-parse-string note :object-type 'plist :array-type 'array
                                                 :null-object nil :false-object nil)))
                      (entry (plist-get (plist-get data :files) (intern (concat ":" relative)))))
            (setq marked (tandem-authorship-apply entry))
            (throw 'done nil)))))
    (when (called-interactively-p 'any)
      (message "tandem: %d line%s of Claude's from git notes" marked (if (= marked 1) "" "s")))
    marked))

(defun tandem-notes--on-visit ()
  "Look in git notes for Claude's lines of a file this machine knows none of."
  (when tandem-notes-automatic
    (ignore-errors (tandem-notes-restore))))

;;;; Sharing

(defun tandem-notes--merge (root fetched)
  "Merge the notes FETCHED from a remote into yours, under ROOT.
Where both have a note on the same commit, yours stays."
  (if (tandem-notes--ok root "rev-parse" "--verify" "--quiet" tandem-notes-ref)
      (let ((result (tandem-notes--git root nil "notes" "--ref" tandem-notes-ref
                                            "merge" "--strategy=ours" "--quiet" fetched)))
        (unless (eql (car result) 0)
          (user-error "Could not merge the fetched notes: %s" (string-trim (cdr result)))))
    (tandem-notes--ok root "update-ref" tandem-notes-ref fetched)))

;;;###autoload
(defun tandem-notes-share (remote)
  "Share Claude's notes with REMOTE: fetch them from now on, and push yours.
Fetched notes are kept apart from yours, so a fetch never overwrites
notes you have not pushed; before pushing, the two are merged."
  (interactive (list (read-string "Remote: " nil nil "origin")))
  (let* ((root (or (tandem-notes--root default-directory) (user-error "Not in a git repository")))
         (fetched (format "refs/notes/remotes/%s/%s" remote (file-name-nondirectory tandem-notes-ref)))
         (refspec (format "+%s:%s" tandem-notes-ref fetched))
         (fetches (split-string (or (tandem-notes--ok root "config" "--get-all"
                                                           (format "remote.%s.fetch" remote))
                                    "")
                                "\n" t)))
    (unless (tandem-notes--ok root "remote" "get-url" remote)
      (user-error "No remote %s" remote))
    (unless (member refspec fetches)
      (tandem-notes--ok root "config" "--add" (format "remote.%s.fetch" remote) refspec))
    ;; The remote may have no notes yet: then there is nothing to fetch.
    (when (tandem-notes--ok root "ls-remote" "--exit-code" remote tandem-notes-ref)
      (let ((result (tandem-notes--git root nil "fetch" "--quiet" remote refspec)))
        (unless (eql (car result) 0)
          (user-error "Fetch failed: %s" (string-trim (cdr result)))))
      (tandem-notes--merge root fetched))
    (remhash root tandem-notes--has-notes)
    (when (and (tandem-notes--ok root "rev-parse" "--verify" "--quiet" tandem-notes-ref)
               (y-or-n-p (format "Push Claude's notes (%s) to %s? " tandem-notes-ref remote)))
      (let ((result (tandem-notes--git root nil "push" "--quiet" remote tandem-notes-ref)))
        (unless (eql (car result) 0)
          (user-error "Push failed: %s" (string-trim (cdr result))))))
    (message "tandem: %s now fetches Claude's notes, apart from yours" remote)))

(add-hook 'tandem-authorship-restore-functions #'tandem-notes--on-visit)
(add-hook 'git-commit-post-finish-hook #'tandem-notes--after-commit)

(provide 'tandem-notes)
;;; tandem-notes.el ends here
