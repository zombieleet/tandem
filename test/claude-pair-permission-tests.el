;;; claude-pair-permission-tests.el --- Tests for permission questions  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group draws permission questions from hand-made updates.  The
;; second runs them for real: the fake claude asks its permission tool, the
;; daemon's MCP helper relays the question, and the chat answers it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--bash-request
  '(:kind "permission" :state "pending" :requestId "r1" :toolName "Bash"
          :title "Bash echo $HOME | grep x"
          :input (:command "echo $HOME | grep x" :description "Look at home")
          :alwaysRule "Bash(echo $HOME | grep x)")
  "A pending permission question, as the daemon sends it.")

(defun claude-pair-test--goto-question ()
  "Move point onto the first permission question."
  (goto-char (point-min))
  (search-forward "Claude wants to"))

;;;; Drawing and answering, without a daemon

(ert-deftest claude-pair-permission-question-is-drawn ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed claude-pair-test--bash-request)
    (let ((text (claude-pair-test--transcript)))
      (should (string-match-p
               "  ⏸ Claude wants to run:\n      echo \\$HOME | grep x\n      (Look at home)\n" text))
      (should (string-match-p
               "    y allow once   a always allow Bash(echo \\$HOME | grep x)   n deny   d deny with a reason\n"
               text)))
    (should (equal claude-pair-chat--state "waiting"))
    (should (claude-pair-chat--busy-p))
    (should (string-match-p "waiting for your answer" (claude-pair-chat--header-line)))
    (should (equal claude-pair-chat--pending '("r1")))
    (should (get-buffer-window (current-buffer)))))

(ert-deftest claude-pair-permission-command-is-fontified ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed claude-pair-test--bash-request)
    (goto-char (point-min))
    (search-forward "echo $HOME")
    (should (cl-loop for pos from (match-beginning 0) below (match-end 0)
                     thereis (get-text-property pos 'face)))))

(ert-deftest claude-pair-permission-keys-answer ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed claude-pair-test--bash-request)
    (claude-pair-test--goto-question)
    (let ((map (get-text-property (point) 'keymap))
          sent)
      (should (eq (lookup-key map "y") #'claude-pair-chat-allow))
      (should (eq (lookup-key map "a") #'claude-pair-chat-allow-always))
      (should (eq (lookup-key map "n") #'claude-pair-chat-deny))
      (should (eq (lookup-key map "d") #'claude-pair-chat-deny-with-reason))
      (cl-letf (((symbol-function 'claude-pair-rpc-request)
                 (lambda (method params &optional _timeout) (push (cons method params) sent) '(:ok t)))
                ((symbol-function 'read-string) (lambda (&rest _) "use make clean")))
        (claude-pair-chat-allow)
        (claude-pair-chat-allow-always)
        (claude-pair-chat-deny)
        (claude-pair-chat-deny-with-reason))
      (should (equal (nreverse sent)
                     '((permission/answer :requestId "r1" :decision "allow" :always :json-false :message "")
                       (permission/answer :requestId "r1" :decision "allow" :always t :message "")
                       (permission/answer :requestId "r1" :decision "deny" :always :json-false :message "")
                       (permission/answer :requestId "r1" :decision "deny" :always :json-false
                                          :message "use make clean")))))))

(ert-deftest claude-pair-permission-outcomes-replace-the-keys ()
  (dolist (case '(((:decision "allow" :always :json-false) "    ✓ Allowed\n")
                  ((:decision "allow" :always t) "    ✓ Always allowed: Bash(echo \\$HOME | grep x)\n")
                  ((:decision "deny" :always :json-false :message "use make clean")
                   "    ✗ Denied: use make clean\n")
                  ((:decision "deny" :always :json-false :message "") "    ✗ Denied\n")))
    (claude-pair-test-with-chat
      (claude-pair-test--feed claude-pair-test--bash-request)
      (claude-pair-test--feed (append '(:kind "permission" :state "answered" :requestId "r1") (car case)))
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p (cadr case) text))
        (should-not (string-match-p "y allow once" text)))
      (claude-pair-test--goto-question)
      (should-not (get-text-property (point) 'keymap))
      (should (equal claude-pair-chat--state "running"))
      (should-not claude-pair-chat--pending))))

(ert-deftest claude-pair-permission-withdrawn ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed claude-pair-test--bash-request
                            '(:kind "permission" :state "withdrawn" :requestId "r1"
                                    :reason "The user stopped the turn."))
    (should (string-match-p "    Withdrawn: The user stopped the turn\\.\n" (claude-pair-test--transcript)))
    (should-not claude-pair-chat--pending)))

(ert-deftest claude-pair-permission-menu-answers-the-oldest ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed
     claude-pair-test--bash-request
     '(:kind "permission" :state "pending" :requestId "r2" :toolName "WebFetch"
             :title "WebFetch https://example.com" :input (:url "https://example.com")
             :alwaysRule "WebFetch(domain:example.com)"))
    (should (string-match-p "Claude wants to fetch:\n      https://example\\.com\n"
                            (claude-pair-test--transcript)))
    (goto-char (point-max))
    (let (sent)
      (cl-letf (((symbol-function 'claude-pair-rpc-request)
                 (lambda (_method params &optional _timeout) (push params sent) '(:ok t)))
                ((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?d "deny with a reason")))
                ((symbol-function 'read-string) (lambda (&rest _) "not now")))
        (claude-pair-chat-answer-permission)
        (with-temp-buffer
          (claude-pair-answer-permission)))
      (should (equal sent '((:requestId "r1" :decision "deny" :always :json-false :message "not now")
                            (:requestId "r1" :decision "deny" :always :json-false :message "not now")))))))

(ert-deftest claude-pair-permission-fontifying-is-quiet ()
  (let ((shown '()))
    (cl-letf* ((real-message (symbol-function 'message))
               ((symbol-function 'message)
                (lambda (format-string &rest args)
                  (unless (or inhibit-message (null message-log-max) (null format-string))
                    (push (apply #'format-message format-string args) shown))
                  (apply real-message format-string args))))
      (claude-pair-chat--fontify-shell "echo $HOME"))
    (should-not shown)))

(ert-deftest claude-pair-permission-denials-you-made-are-not-repeated ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed claude-pair-test--bash-request
                            '(:kind "permission" :state "answered" :requestId "r1" :decision "deny"
                                    :always :json-false :message "no")
                            '(:kind "result" :subtype "success" :costUsd 0.01 :durationMs 10
                                    :cancelled :json-false :isError :json-false
                                    :permissionDenials ["Bash"]))
    (should-not (string-match-p "Not allowed" (claude-pair-test--transcript)))
    (claude-pair-test--feed '(:kind "result" :subtype "success" :costUsd 0.01 :durationMs 10
                                    :cancelled :json-false :isError :json-false
                                    :permissionDenials ["WebFetch" "WebFetch"]))
    (should (string-match-p "  Not allowed: WebFetch\.  Claude Code denied it without asking you"
                            (claude-pair-test--transcript)))))

(ert-deftest claude-pair-permission-wait-is-not-tool-time ()
  (claude-pair-test-with-chat
    (claude-pair-test--feed '(:kind "tool" :id "toolu_1" :name "Bash" :title "Bash touch x" :status "started"))
    (claude-pair-chat--handle-update
     '(:kind "permission" :state "pending" :requestId "r9" :toolName "Bash" :toolUseId "toolu_1"
             :title "Bash touch x" :input (:command "touch x") :alwaysRule "Bash(touch x)"))
    ;; Pretend the question waited 5 seconds for an answer.
    (puthash "toolu_1" (- (float-time) 5) claude-pair-chat--asked-at)
    (claude-pair-test--feed
     '(:kind "permission" :state "answered" :requestId "r9" :decision "allow" :always :json-false)
     '(:kind "tool" :id "toolu_1" :name "Bash" :title "Bash touch x" :status "done" :durationMs 5300))
    (should (string-match-p "✓ Bash touch x  \\(2[0-9][0-9]\\|3[0-9][0-9]\\) ms" (claude-pair-test--transcript)))))

(ert-deftest claude-pair-permission-nothing-to-answer ()
  (claude-pair-test-with-chat
    (should-error (claude-pair-chat-allow) :type 'user-error)
    (should-error (claude-pair-chat-answer-permission) :type 'user-error)))

;;;; Through the daemon, its MCP helper and the fake claude

(defun claude-pair-test--wait-question (buffer)
  "Wait until BUFFER shows a permission question, and return its id."
  (should (claude-pair-test--wait-for
           (lambda () (with-current-buffer buffer
                        (and claude-pair-chat--pending (null claude-pair-chat--queue))))
           10))
  (with-current-buffer buffer (car claude-pair-chat--pending)))

(ert-deftest claude-pair-permission-allow-for-real ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--send buffer "script:bash:touch x")
    (claude-pair-test--wait-question buffer)
    (with-current-buffer buffer
      (claude-pair-test--goto-question)
      (claude-pair-chat-allow))
    (claude-pair-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "⏸ Claude wants to run:\n      touch x\n" text))
        (should (string-match-p "    ✓ Allowed\n" text))
        (should (string-match-p "allowed: touch x" text))))))

(ert-deftest claude-pair-permission-deny-with-a-reason-for-real ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--send buffer "script:bash:rm -rf build")
    (claude-pair-test--wait-question buffer)
    (with-current-buffer buffer
      (claude-pair-test--goto-question)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "use make clean")))
        (claude-pair-chat-deny-with-reason)))
    (claude-pair-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "    ✗ Denied: use make clean\n" text))
        (should (string-match-p "denied: use make clean" text))))))

(ert-deftest claude-pair-permission-always-allow-for-real ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--send buffer "script:bash2:touch x")
    (claude-pair-test--wait-question buffer)
    (with-current-buffer buffer
      (claude-pair-test--goto-question)
      (claude-pair-chat-allow-always))
    (claude-pair-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "    ✓ Always allowed: Bash(touch x)\n" text))
        (should (string-match-p "allowed by rule: touch x" text))
        (should (= 1 (cl-count-if (lambda (line) (string-match-p "Claude wants to run" line))
                                  (split-string text "\n"))))))))

(ert-deftest claude-pair-permission-cancel-withdraws-for-real ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (claude-pair-test--send buffer "script:bash:touch x")
    (claude-pair-test--wait-question buffer)
    (with-current-buffer buffer
      (claude-pair-chat-cancel))
    (claude-pair-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (claude-pair-test--transcript)))
        (should (string-match-p "    Withdrawn: The user stopped the turn\\.\n" text))
        (should (string-match-p "  Stopped\\.\n" text))
        (should-not claude-pair-chat--pending)))))

(provide 'claude-pair-permission-tests)
;;; claude-pair-permission-tests.el ends here
