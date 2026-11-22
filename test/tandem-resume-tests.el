;;; tandem-resume-tests.el --- Tests for reopening chats  -*- lexical-binding: t; -*-

;;; Commentary:

;; Reopening a closed chat, reattaching one left open in the daemon, and
;; the list you pick from, through the daemon and the fake claude, which
;; keeps transcripts under CLAUDE_CONFIG_DIR as Claude Code does.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-history (&rest body)
  "Run BODY in a project whose transcripts go to a private CONFIG dir."
  (declare (indent 0) (debug t))
  `(let* ((config (tandem-test--private-dir))
          (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment)))
     (unwind-protect
         (tandem-test-with-project ,@body)
       (when (get-buffer " *tandem resume test*")
         (kill-buffer " *tandem resume test*"))
       (delete-directory config t))))

(defun tandem-test--forget-buffer (buffer)
  "Kill BUFFER as an Emacs restart would: its session stays in the daemon."
  (with-current-buffer buffer
    (remhash tandem-chat--session-id tandem-chat--buffers)
    (setq tandem-chat--session-id nil))
  (tandem-test--kill buffer))

(defun tandem-test--kill (buffer)
  "Kill BUFFER and stay in the project, as you would be."
  (let ((dir (buffer-local-value 'default-directory buffer)))
    (kill-buffer buffer)
    (set-buffer (get-buffer-create " *tandem resume test*"))
    (setq default-directory dir)))

(ert-deftest tandem-resume-a-closed-chat ()
  (tandem-test-with-history
    (setq buffer (tandem))
    (tandem-test--say buffer "script:hello")
    (tandem-test--say buffer "what is `area`?")
    (let ((id (buffer-local-value 'tandem-chat--session-id buffer))
          (root (buffer-local-value 'tandem-chat--root buffer)))
      (tandem-test--kill buffer)   ; closes the session
      (let ((chats (tandem-resume--list root)))
        (should (= (length chats) 1))
        (should (equal (plist-get (car chats) :title) "script:hello"))
        (should (string-match-p "\\`just now · 2 messages\\'" (tandem-resume--describe (car chats)))))
      (setq buffer (tandem-resume-open id root))
      (with-current-buffer buffer
        (let ((text (tandem-test--transcript)))
          (should (string-match-p "You\nscript:hello\n\nClaude\nHello wörld 🌍" text))
          (should (string-match-p "You\nwhat is `area`\\?\n\nClaude\nYou said: what is `area`\\?" text))
          (should (string-match-p "Reopened: Claude remembers the conversation above\\." text)))
        ;; Rendered as when it was new.
        (goto-char (point-min))
        (search-forward "area`?")
        (should (memq 'tandem-markdown-code
                      (ensure-list (get-text-property (- (point) 4) 'face)))))
      ;; Claude goes on in the same conversation.
      (tandem-test--say buffer "again")
      (with-current-buffer buffer
        (should (string-match-p "You said: again" (tandem-test--transcript)))
        (should (equal tandem-chat--session-id id)))
      ;; Asked again, the open buffer is shown, not a second one.
      (should (eq (tandem-resume-open id root) buffer)))))

(ert-deftest tandem-resume-reattaches-after-a-restart ()
  (tandem-test-with-history
    (setq buffer (tandem))
    (tandem-test--say buffer "script:hello")
    (let ((id (buffer-local-value 'tandem-chat--session-id buffer)))
      (tandem-test--forget-buffer buffer)
      ;; C-c c P again: the chat left in the daemon comes back.
      (setq buffer (tandem))
      (with-current-buffer buffer
        (should (equal tandem-chat--session-id id))
        (should (string-match-p "Hello wörld 🌍\n.*\n?  Reattached: this chat was still open in the daemon\\."
                                (tandem-test--transcript))))
      (tandem-test--say buffer "still here?")
      (with-current-buffer buffer
        (should (string-match-p "You said: still here\\?" (tandem-test--transcript))))
      ;; With a prefix argument, a new chat.
      (let ((fresh (tandem t)))
        (unwind-protect
            (should-not (equal (buffer-local-value 'tandem-chat--session-id fresh) id))
          (kill-buffer fresh))))))

(ert-deftest tandem-resume-picking-from-the-list ()
  (tandem-test-with-history
    (setq buffer (tandem))
    (tandem-test--say buffer "first chat")
    (let ((first (buffer-local-value 'tandem-chat--session-id buffer))
          prompt-seen candidates)
      (tandem-test--kill buffer)
      (setq buffer (tandem))
      (tandem-test--say buffer "second chat")
      (tandem-test--kill buffer)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt table &rest _)
                   (setq prompt-seen prompt
                         candidates (all-completions "" table))
                   (car (last candidates))))
                ((symbol-function 'tandem-chat--display) #'identity))
        (setq buffer (tandem-resume)))
      (should (equal prompt-seen "Reopen chat: "))
      ;; Newest first.
      (should (string-prefix-p "second chat" (car candidates)))
      (should (string-prefix-p "first chat" (cadr candidates)))
      (should (equal (buffer-local-value 'tandem-chat--session-id buffer) first)))))

(ert-deftest tandem-resume-nothing-to-reopen ()
  (tandem-test-with-history
    (should-error (call-interactively #'tandem-resume) :type 'user-error)))

(ert-deftest tandem-resume-shows-your-words-only ()
  (should (equal (tandem-resume--shown "fix @buffer\n\nContext the user attached:\n\n@buffer is …")
                 "fix @buffer"))
  (should (equal (tandem-resume--shown "plain") "plain")))

(ert-deftest tandem-resume-ages ()
  (let ((ago (lambda (seconds)
               (tandem-resume--age
                (format-time-string "%FT%T%z" (time-subtract nil seconds))))))
    (should (equal (funcall ago 5) "just now"))
    (should (equal (funcall ago 300) "5 min ago"))
    (should (equal (funcall ago 7200) "2 h ago"))
    (should (equal (funcall ago (* 3 86400)) "3 days ago"))
    (should (string-match-p "[0-9]\\{4\\}\\'" (funcall ago (* 30 86400))))))

(provide 'tandem-resume-tests)
;;; tandem-resume-tests.el ends here
