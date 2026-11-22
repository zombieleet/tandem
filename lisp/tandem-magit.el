;;; tandem-magit.el --- Claude's work into git commits  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, vc
;; URL: https://github.com/zombieleet/tandem

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

;; Optional.  The commands below load it when you first use them;
;; (tandem-magit-mode 1) also adds the trailer and the automatic draft,
;; if you want them, to every new commit message buffer.
;;
;; M-x tandem-magit-stage-claude stages the hunks you accepted from
;;   Claude: the uncommitted changes whose new lines are all Claude's, from
;;   the colours Claude's lines keep.  Everything else stays unstaged, so
;;   your own changes go into a commit of their own.
;;
;; M-x tandem-magit-draft-message, in the commit message buffer, has
;;   Claude write the message from the staged diff and the chat's
;;   conversation.  Claude answers in a copy of the chat that is never
;;   saved: the chat itself does not change.
;;
;; If you want one, a trailer such as Co-Authored-By goes into the commit
;; message when the staged changes hold lines Claude wrote; there is none
;; unless you set `tandem-magit-trailer'.
;;
;; Staging needs only git; the commit buffer parts need Magit's git-commit.

;;; Code:

(require 'tandem-authorship)
(require 'tandem-chat)
(require 'tandem-layout)
(require 'tandem-project)
(require 'seq)
(require 'subr-x)

(declare-function magit-refresh "magit-mode")
(declare-function magit-toplevel "magit-git")

(defgroup tandem-magit nil
  "Claude's work into git commits."
  :group 'tandem)

(defcustom tandem-magit-trailer nil
  "Trailer added to a commit message when the staged changes hold Claude's lines.
Nil, the default, adds none.  For example:
  \"Co-Authored-By: Claude <noreply@anthropic.com>\""
  :type '(choice (const :tag "None" nil) string))

(defcustom tandem-magit-model "haiku"
  "Model that drafts commit messages; nil for Claude Code's default."
  :type '(choice (const :tag "Claude Code's default" nil) string))

(defcustom tandem-magit-draft-automatically nil
  "Non-nil to draft the message whenever a commit buffer opens empty."
  :type 'boolean)

(defcustom tandem-magit-diff-limit 60000
  "Most characters of the staged diff Claude reads for a commit message."
  :type 'natnum)

;;;; git

(defun tandem-magit--root ()
  "Return the top of the current git repository."
  (let ((root (or (and (fboundp 'magit-toplevel) (magit-toplevel))
                  (locate-dominating-file default-directory ".git"))))
    (unless root
      (user-error "Not in a git repository"))
    (file-name-as-directory (expand-file-name root))))

(defun tandem-magit--git (root &rest args)
  "Run git with ARGS in ROOT and return its output; signal on failure."
  (with-temp-buffer
    (let* ((default-directory root)
           (status (apply #'process-file "git" nil t nil args)))
      (unless (eql status 0)
        (error "Git %s failed: %s" (car args) (string-trim (buffer-string))))
      (buffer-string))))

(defun tandem-magit--git-input (root input &rest args)
  "Run git with ARGS in ROOT, INPUT on its standard input; signal on failure."
  (with-temp-buffer
    (insert input)
    (let* ((default-directory root)
           (status (apply #'call-process-region (point-min) (point-max) "git" t t nil args)))
      (unless (eql status 0)
        (error "Git %s failed: %s" (car args) (string-trim (buffer-string)))))))

;;;; Which lines are Claude's

(defun tandem-magit--file-buffer (file)
  "Return a buffer on FILE with Claude's lines known, or nil.
A buffer with unsaved changes is no good: its lines are not the file's."
  (let ((buffer (or (find-buffer-visiting file)
                    (and (file-exists-p file) (tandem-layout-file-buffer file)))))
    (and buffer (not (buffer-modified-p buffer)) buffer)))

(defun tandem-magit--claude-lines-p (buffer first count)
  "Return non-nil if COUNT lines of BUFFER from line FIRST are all Claude's."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (and (zerop (forward-line (1- first)))
             (catch 'mine
               (dotimes (_ count t)
                 (when (or (eobp) (not (tandem-authorship-at (point))))
                   (throw 'mine nil))
                 (forward-line 1))))))))

(defun tandem-magit--claude-text-p (buffer text)
  "Return non-nil if BUFFER has a line of Claude's whose text is TEXT."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((found nil))
          (while (and (not found)
                      (search-forward text nil t))
            (when (and (= (match-beginning 0) (line-beginning-position))
                       (= (match-end 0) (line-end-position))
                       (tandem-authorship-at (match-beginning 0)))
              (setq found t)))
          found)))))

;;;; Hunks

(defun tandem-magit--parse (diff)
  "Split DIFF, a -U0 git diff, into files of hunks.
Return a list of (FILE HEADER HUNKS), each hunk (NEW-START NEW-COUNT TEXT)."
  (let ((files nil))
    (dolist (chunk (cdr (split-string diff "^diff --git " )))
      (let* ((chunk (concat "diff --git " chunk))
             (at (string-match "^@@ " chunk))
             (header (substring chunk 0 at))
             (file (and (string-match "^\\+\\+\\+ b/\\(.*\\)$" header) (match-string 1 header)))
             (hunks nil))
        (when (and at file)
          (dolist (hunk (cdr (split-string (substring chunk at) "^@@ ")))
            (let ((hunk (concat "@@ " hunk)))
              (when (string-match "\\`@@ -[0-9]+\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@" hunk)
                (push (list (string-to-number (match-string 1 hunk))
                            (if (match-string 2 hunk) (string-to-number (match-string 2 hunk)) 1)
                            hunk)
                      hunks))))
          (push (list file header (nreverse hunks)) files))))
    (nreverse files)))

(defun tandem-magit--added-lines (hunk-text)
  "Return the new lines of HUNK-TEXT, without their + signs."
  (seq-keep (lambda (line) (and (string-prefix-p "+" line) (substring line 1)))
            (cdr (split-string hunk-text "\n" t))))

(defun tandem-magit--claude-patch (root)
  "Return (PATCH STAGED OTHERS UNTRACKED) for the work under ROOT.
PATCH holds the hunks whose new lines are all Claude's, STAGED counts
them, OTHERS counts the hunks left out, UNTRACKED lists new files that
are all Claude's."
  (let ((patch "") (staged 0) (others 0) (untracked nil))
    (dolist (file (tandem-magit--parse
                   (tandem-magit--git root "diff" "-U0" "--no-color" "--no-ext-diff")))
      (pcase-let* ((`(,name ,header ,hunks) file)
                   (buffer (tandem-magit--file-buffer (expand-file-name name root)))
                   (mine (and buffer
                              (seq-filter (lambda (h) (and (> (nth 1 h) 0)
                                                           (tandem-magit--claude-lines-p
                                                            buffer (nth 0 h) (nth 1 h))))
                                          hunks))))
        (setq staged (+ staged (length mine))
              others (+ others (- (length hunks) (length mine))))
        (when mine
          (setq patch (concat patch header (mapconcat (lambda (h) (nth 2 h)) mine ""))))))
    (dolist (name (seq-remove
                   ;; Emacs's lock and auto-save files.
                   (lambda (name) (string-match-p "\\(?:\\`\\|/\\)\\(?:\\.#\\|#.*#\\'\\)" name))
                   (split-string (tandem-magit--git root "ls-files" "--others" "--exclude-standard") "\n" t)))
      (let* ((path (expand-file-name name root))
             (buffer (tandem-magit--file-buffer path))
             (lines (and buffer (with-current-buffer buffer
                                  (save-restriction (widen) (count-lines (point-min) (point-max)))))))
        (if (and buffer (> lines 0) (tandem-magit--claude-lines-p buffer 1 lines))
            (push name untracked)
          (setq others (1+ others)))))
    (list patch staged others (nreverse untracked))))

;;;###autoload
(defun tandem-magit-stage-claude ()
  "Stage the hunks you accepted from Claude, and only those.
A hunk is Claude's when every line it adds is one of Claude's coloured
lines; a new file, when all of it is.  Lines Claude removed without
adding any cannot be told from yours, and stay unstaged.  Files with
unsaved changes are left alone."
  (interactive)
  (let ((root (tandem-magit--root)))
    (pcase-let ((`(,patch ,staged ,others ,untracked) (tandem-magit--claude-patch root)))
      (unless (string-empty-p patch)
        (tandem-magit--git-input root patch "apply" "--cached" "--unidiff-zero" "-"))
      (when untracked
        (apply #'tandem-magit--git root "add" "--" untracked))
      (when (featurep 'magit)
        (magit-refresh))
      (message "tandem: staged %d hunk%s%s of Claude's; %d other change%s left unstaged"
               staged (if (= staged 1) "" "s")
               (if untracked (format " and %d new file%s" (length untracked)
                                     (if (cdr untracked) "s" ""))
                 "")
               others (if (= others 1) "" "s"))
      (list staged (length untracked) others))))

(defun tandem-magit--staged-has-claude-p (root)
  "Return non-nil if new lines of Claude's are staged in ROOT."
  (seq-some
   (lambda (file)
     (pcase-let* ((`(,name ,_header ,hunks) file))
       (when-let* ((buffer (tandem-magit--file-buffer (expand-file-name name root))))
         (seq-some (lambda (hunk)
                     (seq-some (lambda (line)
                                 (and (not (string-blank-p line))
                                      (tandem-magit--claude-text-p buffer line)))
                               (tandem-magit--added-lines (nth 2 hunk))))
                   hunks))))
   (tandem-magit--parse
    (tandem-magit--git root "diff" "--cached" "-U0" "--no-color" "--no-ext-diff"))))

;;;; The commit message

(defun tandem-magit--message-end ()
  "Return where the message of the commit buffer ends: before its comments."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward (format "^%s" (regexp-quote (or (bound-and-true-p comment-start) "#"))) nil t)
        (match-beginning 0)
      (point-max))))

(defun tandem-magit-add-trailer ()
  "Add `tandem-magit-trailer' to the commit message, unless it is there."
  (when (and tandem-magit-trailer
             (not (save-excursion
                    (goto-char (point-min))
                    (search-forward tandem-magit-trailer nil t))))
    (save-excursion
      (goto-char (tandem-magit--message-end))
      (skip-chars-backward "\n")
      (let ((empty (= (point) (point-min))))
        (insert (if empty "\n\n" "\n\n") tandem-magit-trailer)
        (unless (looking-at "\n") (insert "\n"))))))

(defun tandem-magit--chat-session (root)
  "Return the session id of the chat about ROOT, or nil."
  (when-let* ((buffer (or (tandem-chat--buffer-for (directory-file-name root))
                          (tandem-chat--buffer-for root))))
    (buffer-local-value 'tandem-chat--session-id buffer)))

(defun tandem-magit--prompt (diff)
  "Return the request for a commit message about DIFF."
  (concat "Write the git commit message for the staged changes below. "
          "First line: a summary in the imperative, at most 72 characters. "
          "Then a blank line and a short body, wrapped at 72 characters, that says why "
          "the change was made; use what we discussed in this conversation if there was any. "
          "Reply with the message only: no code fences, no comments, no tools, and no "
          "trailers such as Co-Authored-By or Signed-off-by.\n\n"
          diff))

(defun tandem-magit--command (root _diff)
  "Return the claude command line that drafts a commit message in ROOT.
The request, with the diff, goes on its standard input, not its command
line: other users of the machine can read command lines."
  (let ((session (tandem-magit--chat-session root)))
    (append (list (tandem-chat--claude-path) "-p" "--output-format" "json" "--max-turns" "2")
            (when tandem-magit-model (list "--model" tandem-magit-model))
            ;; A copy of the chat, never saved: the chat stays as it is.
            (when session (list "--resume" session "--fork-session" "--no-session-persistence"))
            (unless session (list "--no-session-persistence")))))

(defun tandem-magit--insert-message (buffer text)
  "Put TEXT as the message of the commit BUFFER, keeping its trailers."
  (with-current-buffer buffer
    (save-excursion
      (let* ((end (tandem-magit--message-end))
             (old (buffer-substring-no-properties (point-min) end))
             (trailers (and tandem-magit-trailer
                            (string-search tandem-magit-trailer old))))
        (delete-region (point-min) end)
        (goto-char (point-min))
        (insert (string-trim text) "\n")
        (when trailers
          (tandem-magit-add-trailer))
        (unless (looking-at "\n\\|\\'") (insert "\n"))))))

;;;###autoload
(defun tandem-magit-draft-message ()
  "Have Claude write the commit message for what is staged.
Claude reads the staged diff and, if the project has a chat, what was
said there.  The answer replaces the message in this buffer."
  (interactive)
  (let* ((buffer (current-buffer))
         (root (tandem-magit--root))
         (diff (tandem-magit--git root "diff" "--cached" "--no-color" "--no-ext-diff"))
         (diff (if (> (length diff) tandem-magit-diff-limit)
                   (concat (substring diff 0 tandem-magit-diff-limit) "\n[… the diff goes on]")
                 diff))
         (output (generate-new-buffer " *tandem commit message*")))
    (when (string-blank-p diff)
      (user-error "Nothing is staged"))
    (message "tandem: Claude is writing the commit message…")
    (let ((default-directory root))
      (let ((process
      (make-process
       :name "tandem-commit-message"
       :buffer output
       :command (tandem-magit--command root diff)
       :connection-type 'pipe
       :noquery t
       :stderr (get-buffer-create " *tandem commit message errors*")
       :sentinel
       (lambda (process _event)
         (unless (process-live-p process)
           (unwind-protect
               (let* ((result (ignore-errors
                                (with-current-buffer output
                                  (goto-char (point-min))
                                  (json-parse-buffer :object-type 'plist))))
                      (text (plist-get result :result)))
                 (cond
                  ((not (buffer-live-p buffer))
                   (message "tandem: the commit buffer is gone"))
                  ((and (stringp text) (not (string-blank-p text))
                        (not (eq (plist-get result :is_error) t)))
                   (tandem-magit--insert-message buffer text)
                   (message "tandem: Claude wrote the commit message; edit it as you like"))
                  (t (message "tandem: no commit message from Claude%s"
                              (if (stringp text) (concat ": " text) "")))))
             (kill-buffer output)))))))
        (process-send-string process (tandem-magit--prompt diff))
        (process-send-eof process)))))

(defun tandem-magit--setup-commit-buffer ()
  "In a new commit buffer: the trailer for Claude's lines, and maybe a draft."
  (ignore-errors
    (let ((root (tandem-magit--root)))
      (when (and tandem-magit-trailer (tandem-magit--staged-has-claude-p root))
        (tandem-magit-add-trailer))
      (when (and tandem-magit-draft-automatically
                 (string-blank-p (buffer-substring-no-properties
                                  (point-min) (tandem-magit--message-end)))
                 (tandem-magit--chat-session root))
        (tandem-magit-draft-message)))))

;;;###autoload
(define-minor-mode tandem-magit-mode
  "Add the trailer and draft you asked for to new commit message buffers.
See `tandem-magit-trailer' and `tandem-magit-draft-automatically'."
  :global t
  :group 'tandem
  (if tandem-magit-mode
      (add-hook 'git-commit-setup-hook #'tandem-magit--setup-commit-buffer)
    (remove-hook 'git-commit-setup-hook #'tandem-magit--setup-commit-buffer)))

(provide 'tandem-magit)
;;; tandem-magit.el ends here
