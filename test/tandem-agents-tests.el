;;; tandem-agents-tests.el --- Tests for worktrees and the chats dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; A git repository with a chat, a worktree with its own chat, the
;; dashboard of both, a chat left open only in the daemon, and removing the
;; worktree; through the daemon and the fake claude.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-git-project (&rest body)
  "Run BODY in a git project with a commit; transcripts in a private dir."
  (declare (indent 0) (debug t))
  `(let* ((config (tandem-test--private-dir))
          (process-environment (append (list (concat "CLAUDE_CONFIG_DIR=" config)
                                             "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                             "GIT_CONFIG_GLOBAL=/dev/null")
                                       process-environment)))
     (unwind-protect
         (tandem-test-with-project
           (let ((worktrees (concat (directory-file-name project) ".worktrees")))
             (unwind-protect
                 (progn
                   (tandem-agents--git project "init" "-q" "-b" "main")
                   (tandem-agents--git project "add" ".")
                   (tandem-agents--git project "commit" "-q" "-m" "init" "--allow-empty")
                   ,@body)
               (delete-directory worktrees t))))
       (when (get-buffer "*tandem chats*") (kill-buffer "*tandem chats*"))
       (delete-directory config t))))

(defun tandem-test--row (root)
  "Return the dashboard row about ROOT, as (ID . COLUMNS)."
  (seq-find (lambda (row) (equal (plist-get (car row) :root) root)) (tandem-chats--entries)))

(ert-deftest tandem-agents-worktree-with-its-chat ()
  (tandem-test-with-git-project
    (setq buffer (tandem))
    (let* ((path (expand-file-name "feat" (concat (directory-file-name project) ".worktrees")))
           (chat (cl-letf (((symbol-function 'tandem-chat--display) #'identity))
                   (tandem-worktree "feat"))))
      (unwind-protect
          (progn
            (should (file-directory-p path))
            (should (equal (tandem-agents--git path "rev-parse" "--abbrev-ref" "HEAD") "feat"))
            (should (equal (buffer-local-value 'tandem-chat--root chat) path))
            ;; A chat of its own, apart from the main one.
            (should-not (equal (buffer-local-value 'tandem-chat--session-id chat)
                               (buffer-local-value 'tandem-chat--session-id buffer)))
            (tandem-test--say chat "script:hello")
            ;; The dashboard: both chats, with their branches.
            (let ((main (tandem-test--row (buffer-local-value 'tandem-chat--root buffer)))
                  (feat (tandem-test--row path)))
              (should (equal (aref (cadr main) 1) "main"))
              (should (equal (aref (cadr feat) 0) "feat"))
              (should (equal (aref (cadr feat) 1) "feat"))
              (should (equal (substring-no-properties (aref (cadr feat) 2)) "idle"))
              (should (string-match-p "\\`\\$" (aref (cadr feat) 4))))
            ;; Removing it closes its chat; the branch stays.
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
              (tandem-worktree-remove path))
            (should-not (file-exists-p path))
            (should-not (buffer-live-p chat))
            (should (string-match-p "feat" (tandem-agents--git project "branch" "--list" "feat"))))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest tandem-agents-a-chat-only-in-the-daemon ()
  (tandem-test-with-git-project
    (setq buffer (tandem))
    (tandem-test--say buffer "script:hello")
    (let ((root (buffer-local-value 'tandem-chat--root buffer))
          (id (buffer-local-value 'tandem-chat--session-id buffer)))
      ;; As after an Emacs restart: the session stays in the daemon.
      (with-current-buffer buffer
        (remhash tandem-chat--session-id tandem-chat--buffers)
        (setq tandem-chat--session-id nil))
      (kill-buffer buffer)
      (let ((row (tandem-test--row root)))
        (should row)
        (should (equal (substring-no-properties (aref (cadr row) 2)) "open in the daemon"))
        (should-not (plist-get (car row) :buffer))
        ;; RET on it, in the dashboard, reattaches.
        (cl-letf (((symbol-function 'tandem-chat--display) #'identity)
                  ((symbol-function 'pop-to-buffer) #'identity))
          (tandem-chats)
          (with-current-buffer "*tandem chats*"
            (goto-char (point-min))
            (while (and (not (eobp)) (not (equal (plist-get (tabulated-list-get-id) :root) root)))
              (forward-line 1))
            (setq buffer (tandem-chats-open))))
        (with-current-buffer buffer
          (should (equal tandem-chat--session-id id))
          (should (string-match-p "Reattached" (tandem-test--transcript))))))))

(ert-deftest tandem-agents-the-dashboard-buffer ()
  (tandem-test-with-git-project
    (setq buffer (tandem))
    (cl-letf (((symbol-function 'pop-to-buffer) #'identity))
      (tandem-chats))
    (with-current-buffer "*tandem chats*"
      (should (derived-mode-p 'tandem-chats-mode))
      (goto-char (point-min))
      (should (equal (plist-get (tabulated-list-get-id) :buffer) buffer))
      (should (string-match-p "main" (buffer-string))))
    (should tandem-chats--timer)
    (kill-buffer "*tandem chats*")
    (tandem-chats--refresh)
    (should-not tandem-chats--timer)))

(ert-deftest tandem-agents-names-git-accepts ()
  (dolist (bad '("" "a b" "../up" "-x" "x.lock" "a..b" "x/"))
    (should-error (tandem-agents--check-name bad) :type 'user-error))
  (tandem-agents--check-name "feature/login"))

(provide 'tandem-agents-tests)
;;; tandem-agents-tests.el ends here
