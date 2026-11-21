;;; claude-pair-agents-tests.el --- Tests for worktrees and the chats dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; A git repository with a chat, a worktree with its own chat, the
;; dashboard of both, a chat left open only in the daemon, and removing the
;; worktree; through the daemon and the fake claude.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defmacro claude-pair-test-with-git-project (&rest body)
  "Run BODY in a git project with a commit; transcripts in a private dir."
  (declare (indent 0) (debug t))
  `(let* ((config (claude-pair-test--private-dir))
          (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" config)
                                             "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                             "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (claude-pair-test-with-project
           (let ((worktrees (concat (directory-file-name project) ".worktrees")))
             (unwind-protect
                 (progn
                   (claude-pair-agents--git project "init" "-q" "-b" "main")
                   (claude-pair-agents--git project "add" ".")
                   (claude-pair-agents--git project "commit" "-q" "-m" "init" "--allow-empty")
                   ,@body)
               (delete-directory worktrees t))))
       (when (get-buffer "*claude-pair chats*") (kill-buffer "*claude-pair chats*"))
       (delete-directory config t))))

(defun claude-pair-test--row (root)
  "Return the dashboard row about ROOT, as (ID . COLUMNS)."
  (seq-find (lambda (row) (equal (plist-get (car row) :root) root)) (claude-pair-chats--entries)))

(ert-deftest claude-pair-agents-worktree-with-its-chat ()
  (claude-pair-test-with-git-project
    (setq buffer (claude-pair))
    (let* ((path (expand-file-name "feat" (concat (directory-file-name project) ".worktrees")))
           (chat (cl-letf (((symbol-function 'claude-pair-chat--display) #'identity))
                   (claude-pair-worktree "feat"))))
      (unwind-protect
          (progn
            (should (file-directory-p path))
            (should (equal (claude-pair-agents--git path "rev-parse" "--abbrev-ref" "HEAD") "feat"))
            (should (equal (buffer-local-value 'claude-pair-chat--root chat) path))
            ;; A chat of its own, apart from the main one.
            (should-not (equal (buffer-local-value 'claude-pair-chat--session-id chat)
                               (buffer-local-value 'claude-pair-chat--session-id buffer)))
            (claude-pair-test--say chat "script:hello")
            ;; The dashboard: both chats, with their branches.
            (let ((main (claude-pair-test--row (buffer-local-value 'claude-pair-chat--root buffer)))
                  (feat (claude-pair-test--row path)))
              (should (equal (aref (cadr main) 1) "main"))
              (should (equal (aref (cadr feat) 0) "feat"))
              (should (equal (aref (cadr feat) 1) "feat"))
              (should (equal (substring-no-properties (aref (cadr feat) 2)) "idle"))
              (should (string-match-p "\\`\\$" (aref (cadr feat) 4))))
            ;; Removing it closes its chat; the branch stays.
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
              (claude-pair-worktree-remove path))
            (should-not (file-exists-p path))
            (should-not (buffer-live-p chat))
            (should (string-match-p "feat" (claude-pair-agents--git project "branch" "--list" "feat"))))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest claude-pair-agents-a-chat-only-in-the-daemon ()
  (claude-pair-test-with-git-project
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "script:hello")
    (let ((root (buffer-local-value 'claude-pair-chat--root buffer))
          (id (buffer-local-value 'claude-pair-chat--session-id buffer)))
      ;; As after an Emacs restart: the session stays in the daemon.
      (with-current-buffer buffer
        (remhash claude-pair-chat--session-id claude-pair-chat--buffers)
        (setq claude-pair-chat--session-id nil))
      (kill-buffer buffer)
      (let ((row (claude-pair-test--row root)))
        (should row)
        (should (equal (substring-no-properties (aref (cadr row) 2)) "open in the daemon"))
        (should-not (plist-get (car row) :buffer))
        ;; RET on it, in the dashboard, reattaches.
        (cl-letf (((symbol-function 'claude-pair-chat--display) #'identity)
                  ((symbol-function 'pop-to-buffer) #'identity))
          (claude-pair-chats)
          (with-current-buffer "*claude-pair chats*"
            (goto-char (point-min))
            (while (and (not (eobp)) (not (equal (plist-get (tabulated-list-get-id) :root) root)))
              (forward-line 1))
            (setq buffer (claude-pair-chats-open))))
        (with-current-buffer buffer
          (should (equal claude-pair-chat--session-id id))
          (should (string-match-p "Reattached" (claude-pair-test--transcript))))))))

(ert-deftest claude-pair-agents-the-dashboard-buffer ()
  (claude-pair-test-with-git-project
    (setq buffer (claude-pair))
    (cl-letf (((symbol-function 'pop-to-buffer) #'identity))
      (claude-pair-chats))
    (with-current-buffer "*claude-pair chats*"
      (should (derived-mode-p 'claude-pair-chats-mode))
      (goto-char (point-min))
      (should (equal (plist-get (tabulated-list-get-id) :buffer) buffer))
      (should (string-match-p "main" (buffer-string))))
    (should claude-pair-chats--timer)
    (kill-buffer "*claude-pair chats*")
    (claude-pair-chats--refresh)
    (should-not claude-pair-chats--timer)))

(ert-deftest claude-pair-agents-names-git-accepts ()
  (dolist (bad '("" "a b" "../up" "-x" "x.lock" "a..b" "x/"))
    (should-error (claude-pair-agents--check-name bad) :type 'user-error))
  (claude-pair-agents--check-name "feature/login"))

(provide 'claude-pair-agents-tests)
;;; claude-pair-agents-tests.el ends here
