;;; claude-pair-agents.el --- Several chats at once: worktrees and a dashboard  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, vc
;; URL: https://github.com/victory/claude-pair

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
;; M-x claude-pair-worktree makes a worktree on a new branch, next to the
;;   repository, and opens its chat.
;; M-x claude-pair-chats lists every chat: project and branch, what Claude
;;   is doing, what waits for you, the cost.  Chats still open in the
;;   daemon but not in this Emacs are listed too; RET reattaches them.
;; M-x claude-pair-worktree-remove removes a worktree and closes its chat.

;;; Code:

(require 'claude-pair-chat)
(require 'claude-pair-dashboard)
(require 'claude-pair-resume)
(require 'claude-pair-review)
(require 'claude-pair-rpc)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defcustom claude-pair-worktree-directory "{repo}.worktrees/{name}"
  "Where a new worktree goes, relative to the repository's parent folder.
{repo} is the repository's folder name and {name} the worktree's."
  :type 'string
  :group 'claude-pair)

(defcustom claude-pair-chats-refresh 1
  "Seconds between refreshes of the chats dashboard while it is shown."
  :type 'number
  :group 'claude-pair)

;;;; git

(defun claude-pair-agents--git (dir &rest args)
  "Run git with ARGS in DIR; return its trimmed output, or signal."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory dir))
           (status (apply #'process-file "git" nil t nil args)))
      (unless (eql status 0)
        (user-error "Git %s: %s" (car args) (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun claude-pair-agents--main-repository (dir)
  "Return the main worktree of the repository holding DIR."
  (let ((common (claude-pair-agents--git dir "rev-parse" "--path-format=absolute" "--git-common-dir")))
    (file-name-directory (directory-file-name common))))

(defun claude-pair-agents--worktree-path (repo name)
  "Return the folder for the worktree NAME of the repository REPO."
  (let ((repo (directory-file-name repo)))
    (expand-file-name
     (replace-regexp-in-string
      "{name}" name
      (replace-regexp-in-string "{repo}" (file-name-nondirectory repo) claude-pair-worktree-directory t t)
      t t)
     (file-name-directory repo))))

(defvar claude-pair-agents--branches (make-hash-table :test #'equal)
  "From a folder to (TIME . BRANCH), the branch checked out there lately.")

(defun claude-pair-agents--branch (dir)
  "Return the branch checked out in DIR, or nil; asked of git now and then."
  (let ((cached (gethash dir claude-pair-agents--branches)))
    (if (and cached (< (- (float-time) (car cached)) 10))
        (cdr cached)
      (let ((branch (ignore-errors
                      (with-temp-buffer
                        (let ((default-directory (file-name-as-directory dir)))
                          (when (eql 0 (process-file "git" nil t nil "rev-parse" "--abbrev-ref" "HEAD"))
                            (string-trim (buffer-string))))))))
        (puthash dir (cons (float-time) branch) claude-pair-agents--branches)
        branch))))

;;;; Worktrees

(defun claude-pair-agents--check-name (name)
  "Signal an error unless NAME can name a worktree and its branch."
  (when (or (string-empty-p name)
            (string-match-p "[ \t\n~^:?*\\[\\\\]\\|\\.\\.\\|\\`[-/.]\\|/\\'\\|\\.lock\\'" name)
            (not (eql 0 (call-process "git" nil nil nil "check-ref-format" "--branch" name))))
    (user-error "Not a branch name git accepts: %S" name)))

;;;###autoload
(defun claude-pair-worktree (name)
  "Make a git worktree NAME on a new branch NAME, and open its chat.
The worktree goes next to the repository (see
`claude-pair-worktree-directory'), from the commit you have checked out;
a branch NAME that exists already is checked out there instead."
  (interactive (list (string-trim (read-string "Worktree and branch name: "))))
  (claude-pair-agents--check-name name)
  (let* ((repo (claude-pair-agents--main-repository default-directory))
         (path (claude-pair-agents--worktree-path repo name))
         (exists (eql 0 (let ((default-directory repo))
                          (process-file "git" nil nil nil "show-ref" "--verify" "--quiet"
                                        (concat "refs/heads/" name))))))
    (when (file-exists-p path)
      (user-error "%s exists already" (abbreviate-file-name path)))
    (make-directory (file-name-directory (directory-file-name path)) t)
    (if exists
        (claude-pair-agents--git repo "worktree" "add" path name)
      (claude-pair-agents--git repo "worktree" "add" "-b" name path))
    (let ((chat (claude-pair-chat--create (directory-file-name path))))
      (claude-pair-chat--display chat)
      (message "claude-pair: worktree %s on branch %s; its chat is open"
               (abbreviate-file-name path) name)
      chat)))

;;;###autoload
(defun claude-pair-worktree-remove (path &optional force)
  "Remove the git worktree at PATH and close its chat.
Refuse when it has changes not committed, unless FORCE (a prefix
argument).  The branch stays."
  (interactive
   (list (or (and (derived-mode-p 'claude-pair-chats-mode) (plist-get (tabulated-list-get-id) :root))
             (and (derived-mode-p 'claude-pair-chat-mode) claude-pair-chat--root)
             (read-directory-name "Remove worktree: "))
         current-prefix-arg))
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (repo (claude-pair-agents--main-repository path)))
    (when (file-equal-p repo path)
      (user-error "%s is the main worktree, not one to remove" (abbreviate-file-name path)))
    (unless (yes-or-no-p (format "Remove the worktree %s%s? " (abbreviate-file-name path)
                                 (if force ", changes and all" "")))
      (user-error "Nothing removed"))
    (when-let* ((chat (claude-pair-chat--buffer-for (directory-file-name path))))
      (kill-buffer chat))
    (apply #'claude-pair-agents--git repo "worktree" "remove"
           (append (when force (list "--force")) (list (directory-file-name path))))
    (message "claude-pair: removed %s; its branch stays" (abbreviate-file-name path))))

;;;; The dashboard

(defvar claude-pair-chats-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "RET" #'claude-pair-chats-open)
    (keymap-set map "o" #'claude-pair-chats-open)
    (keymap-set map "k" #'claude-pair-chats-close)
    (keymap-set map "w" #'claude-pair-worktree)
    (keymap-set map "D" #'claude-pair-worktree-remove)
    (keymap-set map "r" #'claude-pair-review)
    map)
  "Keymap of `claude-pair-chats-mode'.")

(define-derived-mode claude-pair-chats-mode tabulated-list-mode "Claude chats"
  "Every chat with Claude: what it does and what waits for you.
\\<claude-pair-chats-mode-map>
\\[claude-pair-chats-open] opens a chat, \\[claude-pair-chats-close] closes one.
\\[claude-pair-worktree] makes a worktree with its chat.
\\[claude-pair-worktree-remove] removes a worktree.
\\[claude-pair-review] lists the hunks waiting, \\[revert-buffer] refreshes."
  (setq tabulated-list-format [("Project" 22 t) ("Branch" 16 t) ("Claude" 18 t)
                               ("Waiting" 9 t :right-align t) ("Cost" 8 t :right-align t)
                               ("Folder" 0 t)]
        tabulated-list-padding 1
        tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'claude-pair-chats--fill nil t)
  (tabulated-list-init-header))

(defun claude-pair-chats--waiting (session buffer)
  "Return what waits for you in SESSION, chat BUFFER: hunks and questions."
  (+ (claude-pair-review-waiting session)
     (length (buffer-local-value 'claude-pair-chat--pending buffer))))

(defun claude-pair-chats--row (root session state waiting cost &optional buffer)
  "Return a dashboard row for SESSION about ROOT.
STATE, WAITING and COST describe it; BUFFER is its chat, if open here."
  (list (list :root root :session session :buffer buffer)
        (vector (file-name-nondirectory (directory-file-name root))
                (or (claude-pair-agents--branch root) "")
                (propertize state 'face (cond ((member state '("idle" "open in the daemon")) 'shadow)
                                              ((string-match-p "waiting\\|reviewing" state) 'warning)
                                              (t 'success)))
                (if (and waiting (> waiting 0)) (propertize (number-to-string waiting) 'face 'warning) "")
                (if (and (numberp cost) (> cost 0)) (format "$%.2f" cost) "")
                (abbreviate-file-name root))))

(defun claude-pair-chats--entries ()
  "Return the dashboard's rows: chats here, then chats only in the daemon."
  (let ((rows nil) (here nil))
    (maphash
     (lambda (session buffer)
       (when (buffer-live-p buffer)
         (push session here)
         (with-current-buffer buffer
           (push (claude-pair-chats--row claude-pair-chat--root session claude-pair-chat--state
                                         (claude-pair-chats--waiting session buffer)
                                         claude-pair-chat--cost buffer)
                 rows))))
     claude-pair-chat--buffers)
    (when (claude-pair-rpc-live-p)
      (seq-doseq (open (ignore-errors (plist-get (claude-pair-rpc-request 'session/all nil 5) :sessions)))
        (unless (member (plist-get open :sessionId) here)
          (push (claude-pair-chats--row (plist-get open :cwd) (plist-get open :sessionId)
                                        (if (eq (plist-get open :busy) t) "running, not shown" "open in the daemon")
                                        nil (plist-get open :costUsd))
                rows))))
    (sort rows (lambda (a b) (string< (plist-get (car a) :root) (plist-get (car b) :root))))))

(defun claude-pair-chats--fill ()
  "Fill the dashboard."
  (setq tabulated-list-entries (claude-pair-chats--entries)))

(defvar claude-pair-chats--timer nil
  "Timer that refreshes the dashboard while it is shown.")

(defun claude-pair-chats--refresh ()
  "Refresh the dashboard if it is shown; stop refreshing when it is gone."
  (let ((buffer (get-buffer "*claude-pair chats*")))
    (if (not (buffer-live-p buffer))
        (when claude-pair-chats--timer
          (cancel-timer claude-pair-chats--timer)
          (setq claude-pair-chats--timer nil))
      (when (get-buffer-window buffer 'visible)
        (with-current-buffer buffer
          (let ((id (tabulated-list-get-id)))
            (claude-pair-chats--fill)
            (tabulated-list-print t)
            (when id
              (goto-char (point-min))
              (while (and (not (eobp)) (not (equal (tabulated-list-get-id) id)))
                (forward-line 1))
              (when (eobp) (goto-char (point-min))))))))))

;;;###autoload
(defun claude-pair-chats ()
  "List every chat with Claude: project, branch, state, what waits, cost."
  (interactive)
  (let ((buffer (get-buffer-create "*claude-pair chats*")))
    (with-current-buffer buffer
      (claude-pair-chats-mode)
      (claude-pair-chats--fill)
      (tabulated-list-print))
    (unless claude-pair-chats--timer
      (setq claude-pair-chats--timer
            (run-with-timer claude-pair-chats-refresh claude-pair-chats-refresh #'claude-pair-chats--refresh)))
    (pop-to-buffer buffer)))

(defun claude-pair-chats--id ()
  "Return the row at point, or signal."
  (or (tabulated-list-get-id) (user-error "No chat on this line")))

(defun claude-pair-chats-open ()
  "Show the chat on this line; one open only in the daemon is reattached."
  (interactive)
  (let* ((id (claude-pair-chats--id))
         (buffer (plist-get id :buffer)))
    (claude-pair-chat--display
     (if (buffer-live-p buffer)
         buffer
       (claude-pair-resume-open (plist-get id :session) (plist-get id :root))))))

(defun claude-pair-chats-close ()
  "Close the chat on this line: its session ends; it stays in `claude-pair-resume'."
  (interactive)
  (let* ((id (claude-pair-chats--id))
         (buffer (plist-get id :buffer)))
    (unless (yes-or-no-p (format "Close the chat about %s? " (abbreviate-file-name (plist-get id :root))))
      (user-error "Nothing closed"))
    (if (buffer-live-p buffer)
        (kill-buffer buffer)
      (claude-pair-rpc-request 'session/close (list :sessionId (plist-get id :session))))
    (revert-buffer)))

(provide 'claude-pair-agents)
;;; claude-pair-agents.el ends here
