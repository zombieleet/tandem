;;; claude-pair-security-tests.el --- Tests for the security review's fixes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Text Claude writes is untrusted: it may come from a file Claude read.
;; It must not call minor modes, nor become Org settings or clickable
;; elisp links; secrets in a diff must not go on a command line.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-magit)
(require 'claude-pair-test-helpers)

(define-minor-mode claude-pair-test-trap-mode
  "A global minor mode that a code block must never toggle."
  :global t)

(ert-deftest claude-pair-security-code-blocks-call-only-major-modes ()
  (claude-pair-test-trap-mode -1)
  (with-temp-buffer
    (insert "```claude-pair-test-trap\nx\n```\n```server\ny\n```\n")
    (claude-pair-markdown-render (point-min) (point-max) t))
  (should-not claude-pair-test-trap-mode)
  (should-not (claude-pair-markdown--mode "claude-pair-test-trap"))
  (should-not (claude-pair-markdown--mode "server"))
  (should-not (claude-pair-markdown--mode "../evil"))
  ;; Real major modes still work.
  (should (eq (claude-pair-markdown--mode "python") 'python-mode))
  (should (eq (claude-pair-markdown--mode "emacs-lisp") 'emacs-lisp-mode))
  (should (eq (claude-pair-markdown--mode "css") 'css-mode)))

(ert-deftest claude-pair-security-org-text-stays-text ()
  (let ((org (claude-pair-markdown-to-org
              (concat "#+INCLUDE: \"/etc/passwd\"\n  #+SETUPFILE: https://example.com/x.org\n"
                      "[click](elisp:(delete-file \"x\")) and [run](shell:rm -rf /)\n"
                      "[docs](https://example.com) and [mail](mailto:a@b.c)\n"
                      "```\n#+kept in a block\n```"))))
    (should (string-match-p "^: #\\+INCLUDE" org))
    (should (string-match-p "^:   #\\+SETUPFILE" org))
    (should-not (string-match-p "\\[\\[elisp:" org))
    (should-not (string-match-p "\\[\\[shell:" org))
    (should (string-match-p "\\[\\[https://example.com\\]\\[docs\\]\\]" org))
    (should (string-match-p "\\[\\[mailto:a@b.c\\]\\[mail\\]\\]" org))
    (should (string-match-p "^,#\\+kept in a block$" org))))

(ert-deftest claude-pair-security-commit-diff-goes-on-stdin ()
  (let* ((dir (file-name-as-directory (claude-pair-test--private-dir)))
         (fake (expand-file-name "claude" dir))
         (argv-log (expand-file-name "argv" dir))
         (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                        "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t"
                                        "GIT_CONFIG_GLOBAL=/dev/null")
                                      process-environment))
         (default-directory dir))
    (unwind-protect
        (progn
          ;; A stand-in claude: logs its arguments, answers with the first
          ;; words of what it read on stdin.
          (with-temp-file fake
            (insert "#!/bin/sh\nprintf '%s\\n' \"$@\" > " (shell-quote-argument argv-log) "\n"
                    "first=$(head -c 34 | tr -d '\"\\\\\\n')\n"
                    "printf '{\"type\":\"result\",\"result\":\"%s\",\"is_error\":false}' \"$first\"\n"))
          (set-file-modes fake #o700)
          (claude-pair-magit--git dir "init" "-q")
          (with-temp-file (expand-file-name "secret.txt" dir) (insert "API_KEY=sk-not-a-real-key-12345\n"))
          (claude-pair-magit--git dir "add" "secret.txt")
          (with-temp-buffer
            (setq-local comment-start "#")
            (insert "\n# comment\n")
            (cl-letf (((symbol-function 'claude-pair-chat--claude-path) (lambda () fake))
                      ((symbol-function 'claude-pair-magit--chat-session) (lambda (_) nil)))
              (claude-pair-magit-draft-message)
              (claude-pair-test--wait-for (lambda () (not (get-process "claude-pair-commit-message"))) 10))
            (should (string-match-p "\\`Write the git commit message" (buffer-string))))
          (let ((argv (with-temp-buffer (insert-file-contents argv-log) (buffer-string))))
            (should (string-match-p "^-p$" argv))
            (should-not (string-match-p "sk-not-a-real-key" argv))
            (should-not (string-match-p "secret.txt" argv))))
      (delete-directory dir t))))

(provide 'claude-pair-security-tests)
;;; claude-pair-security-tests.el ends here
