;;; claude-pair-resume-tests.el --- Tests for reopening chats  -*- lexical-binding: t; -*-

;;; Commentary:

;; Reopening a closed chat, reattaching one left open in the daemon, and
;; the list you pick from, through the daemon and the fake claude, which
;; keeps transcripts under CLAUDE_CONFIG_DIR as Claude Code does.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defmacro claude-pair-test-with-history (&rest body)
  "Run BODY in a project whose transcripts go to a private CONFIG dir."
  (declare (indent 0) (debug t))
  `(let* ((config (claude-pair-test--private-dir))
          (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment)))
     (unwind-protect
         (claude-pair-test-with-project ,@body)
       (when (get-buffer " *claude-pair resume test*")
         (kill-buffer " *claude-pair resume test*"))
       (delete-directory config t))))

(defun claude-pair-test--forget-buffer (buffer)
  "Kill BUFFER as an Emacs restart would: its session stays in the daemon."
  (with-current-buffer buffer
    (remhash claude-pair-chat--session-id claude-pair-chat--buffers)
    (setq claude-pair-chat--session-id nil))
  (claude-pair-test--kill buffer))

(defun claude-pair-test--kill (buffer)
  "Kill BUFFER and stay in the project, as you would be."
  (let ((dir (buffer-local-value 'default-directory buffer)))
    (kill-buffer buffer)
    (set-buffer (get-buffer-create " *claude-pair resume test*"))
    (setq default-directory dir)))

(ert-deftest claude-pair-resume-a-closed-chat ()
  (claude-pair-test-with-history
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "script:hello")
    (claude-pair-test--say buffer "what is `area`?")
    (let ((id (buffer-local-value 'claude-pair-chat--session-id buffer))
          (root (buffer-local-value 'claude-pair-chat--root buffer)))
      (claude-pair-test--kill buffer)   ; closes the session
      (let ((chats (claude-pair-resume--list root)))
        (should (= (length chats) 1))
        (should (equal (plist-get (car chats) :title) "script:hello"))
        (should (string-match-p "\\`just now · 2 messages\\'" (claude-pair-resume--describe (car chats)))))
      (setq buffer (claude-pair-resume-open id root))
      (with-current-buffer buffer
        (let ((text (claude-pair-test--transcript)))
          (should (string-match-p "You\nscript:hello\n\nClaude\nHello wörld 🌍" text))
          (should (string-match-p "You\nwhat is `area`\\?\n\nClaude\nYou said: what is `area`\\?" text))
          (should (string-match-p "Reopened: Claude remembers the conversation above\\." text)))
        ;; Rendered as when it was new.
        (goto-char (point-min))
        (search-forward "area`?")
        (should (memq 'claude-pair-markdown-code
                      (ensure-list (get-text-property (- (point) 4) 'face)))))
      ;; Claude goes on in the same conversation.
      (claude-pair-test--say buffer "again")
      (with-current-buffer buffer
        (should (string-match-p "You said: again" (claude-pair-test--transcript)))
        (should (equal claude-pair-chat--session-id id)))
      ;; Asked again, the open buffer is shown, not a second one.
      (should (eq (claude-pair-resume-open id root) buffer)))))

(ert-deftest claude-pair-resume-reattaches-after-a-restart ()
  (claude-pair-test-with-history
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "script:hello")
    (let ((id (buffer-local-value 'claude-pair-chat--session-id buffer)))
      (claude-pair-test--forget-buffer buffer)
      ;; C-c c P again: the chat left in the daemon comes back.
      (setq buffer (claude-pair))
      (with-current-buffer buffer
        (should (equal claude-pair-chat--session-id id))
        (should (string-match-p "Hello wörld 🌍\n.*\n?  Reattached: this chat was still open in the daemon\\."
                                (claude-pair-test--transcript))))
      (claude-pair-test--say buffer "still here?")
      (with-current-buffer buffer
        (should (string-match-p "You said: still here\\?" (claude-pair-test--transcript))))
      ;; With a prefix argument, a new chat.
      (let ((fresh (claude-pair t)))
        (unwind-protect
            (should-not (equal (buffer-local-value 'claude-pair-chat--session-id fresh) id))
          (kill-buffer fresh))))))

(ert-deftest claude-pair-resume-picking-from-the-list ()
  (claude-pair-test-with-history
    (setq buffer (claude-pair))
    (claude-pair-test--say buffer "first chat")
    (let ((first (buffer-local-value 'claude-pair-chat--session-id buffer))
          prompt-seen candidates)
      (claude-pair-test--kill buffer)
      (setq buffer (claude-pair))
      (claude-pair-test--say buffer "second chat")
      (claude-pair-test--kill buffer)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &rest _)
                   (setq prompt-seen prompt
                         candidates (all-completions "" table))
                   (car (last candidates))))
                ((symbol-function 'claude-pair-chat--display) #'identity))
        (setq buffer (claude-pair-resume)))
      (should (equal prompt-seen "Reopen chat: "))
      ;; Newest first.
      (should (string-prefix-p "second chat" (car candidates)))
      (should (string-prefix-p "first chat" (cadr candidates)))
      (should (equal (buffer-local-value 'claude-pair-chat--session-id buffer) first)))))

(ert-deftest claude-pair-resume-nothing-to-reopen ()
  (claude-pair-test-with-history
    (should-error (call-interactively #'claude-pair-resume) :type 'user-error)))

(ert-deftest claude-pair-resume-shows-your-words-only ()
  (should (equal (claude-pair-resume--shown "fix @buffer\n\nContext the user attached:\n\n@buffer is …")
                 "fix @buffer"))
  (should (equal (claude-pair-resume--shown "plain") "plain")))

(ert-deftest claude-pair-resume-ages ()
  (let ((ago (lambda (seconds)
               (claude-pair-resume--age
                (format-time-string "%FT%T%z" (time-subtract nil seconds))))))
    (should (equal (funcall ago 5) "just now"))
    (should (equal (funcall ago 300) "5 min ago"))
    (should (equal (funcall ago 7200) "2 h ago"))
    (should (equal (funcall ago (* 3 86400)) "3 days ago"))
    (should (string-match-p "[0-9]\\{4\\}\\'" (funcall ago (* 30 86400))))))

(provide 'claude-pair-resume-tests)
;;; claude-pair-resume-tests.el ends here
