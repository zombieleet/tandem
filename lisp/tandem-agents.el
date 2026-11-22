;;; tandem-agents.el --- Several chats at once: worktrees and a dashboard  -*- lexical-binding: t; -*-

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

;; Several Claudes can work at once, each in its own git worktree, so their
;; edits never meet.  Every worktree is a project of its own, with its own
;; chat.
;;
;; M-x tandem-worktree makes a worktree on a new branch, next to the
;;   repository, and opens its chat.
;; M-x tandem-chats lists every chat: project and branch, what Claude
;;   is doing, what waits for you, the cost.  Chats still open in the
;;   daemon but not in this Emacs are listed too; RET reattaches them.
;; M-x tandem-worktree-remove removes a worktree and closes its chat.

;;; Code:

(require 'tandem-chat)
(require 'tandem-dashboard)
(require 'tandem-resume)
(require 'tandem-review)
(require 'tandem-rpc)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defcustom tandem-worktree-directory "{repo}.worktrees/{name}"
  "Where a new worktree goes, relative to the repository's parent folder.
{repo} is the repository's folder name and {name} the worktree's."
  :type 'string
  :group 'tandem)

(defcustom tandem-chats-refresh 1
  "Seconds between refreshes of the chats dashboard while it is shown."
  :type 'number
  :group 'tandem)

;;;; git

(defun tandem-agents--git (dir &rest args)
  "Run git with ARGS in DIR; return its trimmed output, or signal."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory dir))
           (status (apply #'process-file "git" nil t nil args)))
      (unless (eql status 0)
        (user-error "Git %s: %s" (car args) (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun tandem-agents--main-repository (dir)
  "Return the main worktree of the repository holding DIR."
  (let ((common (tandem-agents--git dir "rev-parse" "--path-format=absolute" "--git-common-dir")))
    (file-name-directory (directory-file-name common))))

(defun tandem-agents--worktree-path (repo name)
  "Return the folder for the worktree NAME of the repository REPO."
  (let ((repo (directory-file-name repo)))
    (expand-file-name
     (replace-regexp-in-string
      "{name}" name
      (replace-regexp-in-string "{repo}" (file-name-nondirectory repo) tandem-worktree-directory t t)
      t t)
     (file-name-directory repo))))

(defvar tandem-agents--branches (make-hash-table :test #'equal)
  "From a folder to (TIME . BRANCH), the branch checked out there lately.")

(defun tandem-agents--branch (dir)
  "Return the branch checked out in DIR, or nil; asked of git now and then."
  (let ((cached (gethash dir tandem-agents--branches)))
    (if (and cached (< (- (float-time) (car cached)) 10))
        (cdr cached)
      (let ((branch (ignore-errors
                      (with-temp-buffer
                        (let ((default-directory (file-name-as-directory dir)))
                          (when (eql 0 (process-file "git" nil t nil "rev-parse" "--abbrev-ref" "HEAD"))
                            (string-trim (buffer-string))))))))
        (puthash dir (cons (float-time) branch) tandem-agents--branches)
        branch))))

;;;; Worktrees

(defun tandem-agents--check-name (name)
  "Signal an error unless NAME can name a worktree and its branch."
  (when (or (string-empty-p name)
            (string-match-p "[ \t\n~^:?*\\[\\\\]\\|\\.\\.\\|\\`[-/.]\\|/\\'\\|\\.lock\\'" name)
            (not (eql 0 (call-process "git" nil nil nil "check-ref-format" "--branch" name))))
    (user-error "Not a branch name git accepts: %S" name)))

;;;###autoload
(defun tandem-worktree (name)
  "Make a git worktree NAME on a new branch NAME, and open its chat.
The worktree goes next to the repository (see
`tandem-worktree-directory'), from the commit you have checked out;
a branch NAME that exists already is checked out there instead."
  (interactive (list (string-trim (read-string "Worktree and branch name: "))))
  (tandem-agents--check-name name)
  (let* ((repo (tandem-agents--main-repository default-directory))
         (path (tandem-agents--worktree-path repo name))
         (exists (eql 0 (let ((default-directory repo))
                          (process-file "git" nil nil nil "show-ref" "--verify" "--quiet"
                                        (concat "refs/heads/" name))))))
    (when (file-exists-p path)
      (user-error "%s exists already" (abbreviate-file-name path)))
    (make-directory (file-name-directory (directory-file-name path)) t)
    (if exists
        (tandem-agents--git repo "worktree" "add" path name)
      (tandem-agents--git repo "worktree" "add" "-b" name path))
    (let ((chat (tandem-chat--create (directory-file-name path))))
      (tandem-chat--display chat)
      (message "tandem: worktree %s on branch %s; its chat is open"
               (abbreviate-file-name path) name)
      chat)))

;;;###autoload
(defun tandem-worktree-remove (path &optional force)
  "Remove the git worktree at PATH and close its chat.
Refuse when it has changes not committed, unless FORCE (a prefix
argument).  The branch stays."
  (interactive
   (list (or (and (derived-mode-p 'tandem-chats-mode) (plist-get (tabulated-list-get-id) :root))
             (and (derived-mode-p 'tandem-chat-mode) tandem-chat--root)
             (read-directory-name "Remove worktree: "))
         current-prefix-arg))
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (repo (tandem-agents--main-repository path)))
    (when (file-equal-p repo path)
      (user-error "%s is the main worktree, not one to remove" (abbreviate-file-name path)))
    (unless (yes-or-no-p (format "Remove the worktree %s%s? " (abbreviate-file-name path)
                                 (if force ", changes and all" "")))
      (user-error "Nothing removed"))
    (when-let* ((chat (tandem-chat--buffer-for (directory-file-name path))))
      (kill-buffer chat))
    (apply #'tandem-agents--git repo "worktree" "remove"
           (append (when force (list "--force")) (list (directory-file-name path))))
    (message "tandem: removed %s; its branch stays" (abbreviate-file-name path))))

;;;; The dashboard

(defvar tandem-chats-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "RET" #'tandem-chats-open)
    (keymap-set map "o" #'tandem-chats-open)
    (keymap-set map "k" #'tandem-chats-close)
    (keymap-set map "w" #'tandem-worktree)
    (keymap-set map "D" #'tandem-worktree-remove)
    (keymap-set map "r" #'tandem-review)
    map)
  "Keymap of `tandem-chats-mode'.")

(define-derived-mode tandem-chats-mode tabulated-list-mode "Claude chats"
  "Every chat with Claude: what it does and what waits for you.
\\<tandem-chats-mode-map>
\\[tandem-chats-open] opens a chat, \\[tandem-chats-close] closes one.
\\[tandem-worktree] makes a worktree with its chat.
\\[tandem-worktree-remove] removes a worktree.
\\[tandem-review] lists the hunks waiting, \\[revert-buffer] refreshes."
  (setq tabulated-list-format [("Project" 22 t) ("Branch" 16 t) ("Claude" 18 t)
                               ("Waiting" 9 t :right-align t) ("Cost" 8 t :right-align t)
                               ("Folder" 0 t)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'tandem-chats--fill nil t)
  (tabulated-list-init-header))

(defun tandem-chats--waiting (session buffer)
  "Return what waits for you in SESSION, chat BUFFER: hunks and questions."
  (+ (tandem-review-waiting session)
     (length (buffer-local-value 'tandem-chat--pending buffer))))

(defun tandem-chats--row (root session state waiting cost &optional buffer)
  "Return a dashboard row for SESSION about ROOT.
STATE, WAITING and COST describe it; BUFFER is its chat, if open here."
  (list (list :root root :session session :buffer buffer)
        (vector (file-name-nondirectory (directory-file-name root))
                (or (tandem-agents--branch root) "")
                (propertize state 'face (cond ((member state '("idle" "open in the daemon")) 'shadow)
                                              ((string-match-p "waiting\\|reviewing" state) 'warning)
                                              (t 'success)))
                (if (and waiting (> waiting 0)) (propertize (number-to-string waiting) 'face 'warning) "")
                (if (and (numberp cost) (> cost 0)) (format "$%.2f" cost) "")
                (abbreviate-file-name root))))

(defun tandem-chats--entries ()
  "Return the dashboard's rows: chats here, then chats only in the daemon."
  (let ((rows nil) (here nil))
    (maphash
     (lambda (session buffer)
       (when (buffer-live-p buffer)
         (push session here)
         (with-current-buffer buffer
           (push (tandem-chats--row tandem-chat--root session tandem-chat--state
                                         (tandem-chats--waiting session buffer)
                                         tandem-chat--cost buffer)
                 rows))))
     tandem-chat--buffers)
    (when (tandem-rpc-live-p)
      (seq-doseq (open (ignore-errors (plist-get (tandem-rpc-request 'session/all nil 5) :sessions)))
        (unless (member (plist-get open :sessionId) here)
          (push (tandem-chats--row (plist-get open :cwd) (plist-get open :sessionId)
                                        (if (eq (plist-get open :busy) t) "running, not shown" "open in the daemon")
                                        nil (plist-get open :costUsd))
                rows))))
    (sort rows (lambda (a b) (string< (plist-get (car a) :root) (plist-get (car b) :root))))))

(defun tandem-chats--fill ()
  "Fill the dashboard."
  (setq tabulated-list-entries (tandem-chats--entries)))

(defvar tandem-chats--timer nil
  "Timer that refreshes the dashboard while it is shown.")

(defun tandem-chats--refresh ()
  "Refresh the dashboard if it is shown; stop refreshing when it is gone."
  (let ((buffer (get-buffer "*tandem chats*")))
    (if (not (buffer-live-p buffer))
        (when tandem-chats--timer
          (cancel-timer tandem-chats--timer)
          (setq tandem-chats--timer nil))
      (when (get-buffer-window buffer 'visible)
        (with-current-buffer buffer
          (let ((id (tabulated-list-get-id)))
            (tandem-chats--fill)
            (tabulated-list-print t)
            (when id
              (goto-char (point-min))
              (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
                (forward-line 1))
              (when (eobp) (goto-char (point-min))))))))))

;;;###autoload
(defun tandem-chats ()
  "List every chat with Claude: project, branch, state, what waits, cost."
  (interactive)
  (let ((buffer (get-buffer-create "*tandem chats*")))
    (with-current-buffer buffer
      (tandem-chats-mode)
      (tandem-chats--fill)
      (tabulated-list-print))
    (unless tandem-chats--timer
      (setq tandem-chats--timer
            (run-with-timer tandem-chats-refresh tandem-chats-refresh #'tandem-chats--refresh)))
    (pop-to-buffer buffer)))

(defun tandem-chats--id ()
  "Return the row at point, or signal."
  (or (tabulated-list-get-id) (user-error "No chat on this line")))

(defun tandem-chats-open ()
  "Show the chat on this line; one open only in the daemon is reattached."
  (interactive)
  (let* ((id (tandem-chats--id))
         (buffer (plist-get id :buffer)))
    (tandem-chat--display
     (if (buffer-live-p buffer)
         buffer
       (tandem-resume-open (plist-get id :session) (plist-get id :root))))))

(defun tandem-chats-close ()
  "Close the chat on this line: its session ends; it stays in `tandem-resume'."
  (interactive)
  (let* ((id (tandem-chats--id))
         (buffer (plist-get id :buffer)))
    (unless (yes-or-no-p (format "Close the chat about %s? " (abbreviate-file-name (plist-get id :root))))
      (user-error "Nothing closed"))
    (if (buffer-live-p buffer)
        (kill-buffer buffer)
      (tandem-rpc-request 'session/close (list :sessionId (plist-get id :session))))
    (revert-buffer)))

(provide 'tandem-agents)
;;; tandem-agents.el ends here
