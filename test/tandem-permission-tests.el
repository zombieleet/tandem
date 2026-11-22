;;; tandem-permission-tests.el --- Tests for permission questions  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group draws permission questions from hand-made updates.  The
;; second runs them for real: the fake claude asks its permission tool, the
;; daemon's MCP helper relays the question, and the chat answers it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defconst tandem-test--bash-request
  '(:kind "permission" :state "pending" :requestId "r1" :toolName "Bash"
          :title "Bash echo $HOME | grep x"
          :input (:command "echo $HOME | grep x" :description "Look at home")
          :alwaysRule "Bash(echo $HOME | grep x)")
  "A pending permission question, as the daemon sends it.")

(defun tandem-test--goto-question ()
  "Move point onto the first permission question."
  (goto-char (point-min))
  (search-forward "Claude wants to"))

;;;; Drawing and answering, without a daemon

(ert-deftest tandem-permission-question-is-drawn ()
  (tandem-test-with-chat
    (tandem-test--feed tandem-test--bash-request)
    (let ((text (tandem-test--transcript)))
      (should (string-match-p
               "  ⏸ Claude wants to run:\n      echo \\$HOME | grep x\n      (Look at home)\n" text))
      (should (string-match-p
               "    y allow once   a always allow Bash(echo \\$HOME | grep x)   n deny   d deny with a reason\n"
               text)))
    (should (equal tandem-chat--state "waiting"))
    (should (tandem-chat--busy-p))
    (should (string-match-p "waiting for your answer" (tandem-chat--header-line)))
    (should (equal tandem-chat--pending '("r1")))
    (should (get-buffer-window (current-buffer)))))

(ert-deftest tandem-permission-command-is-fontified ()
  (tandem-test-with-chat
    (tandem-test--feed tandem-test--bash-request)
    (goto-char (point-min))
    (search-forward "echo $HOME")
    (should (cl-loop for pos from (match-beginning 0) below (match-end 0)
                     thereis (get-text-property pos 'face)))))

(ert-deftest tandem-permission-keys-answer ()
  (tandem-test-with-chat
    (tandem-test--feed tandem-test--bash-request)
    (tandem-test--goto-question)
    (let ((map (get-text-property (point) 'keymap))
          sent)
      (should (eq (lookup-key map "y") #'tandem-chat-allow))
      (should (eq (lookup-key map "a") #'tandem-chat-allow-always))
      (should (eq (lookup-key map "n") #'tandem-chat-deny))
      (should (eq (lookup-key map "d") #'tandem-chat-deny-with-reason))
      (cl-letf (((symbol-function 'tandem-rpc-request)
                 (lambda (method params &optional _timeout) (push (cons method params) sent) '(:ok t)))
                ((symbol-function 'read-string) (lambda (&rest _) "use make clean")))
        (tandem-chat-allow)
        (tandem-chat-allow-always)
        (tandem-chat-deny)
        (tandem-chat-deny-with-reason))
      (should (equal (nreverse sent)
                     '((permission/answer :requestId "r1" :decision "allow" :always :json-false :message "")
                       (permission/answer :requestId "r1" :decision "allow" :always t :message "")
                       (permission/answer :requestId "r1" :decision "deny" :always :json-false :message "")
                       (permission/answer :requestId "r1" :decision "deny" :always :json-false
                                          :message "use make clean")))))))

(ert-deftest tandem-permission-outcomes-replace-the-keys ()
  (dolist (case '(((:decision "allow" :always :json-false) "    ✓ Allowed\n")
                  ((:decision "allow" :always t) "    ✓ Always allowed: Bash(echo \\$HOME | grep x)\n")
                  ((:decision "deny" :always :json-false :message "use make clean")
                   "    ✗ Denied: use make clean\n")
                  ((:decision "deny" :always :json-false :message "") "    ✗ Denied\n")))
    (tandem-test-with-chat
      (tandem-test--feed tandem-test--bash-request)
      (tandem-test--feed (append '(:kind "permission" :state "answered" :requestId "r1") (car case)))
      (let ((text (tandem-test--transcript)))
        (should (string-match-p (cadr case) text))
        (should-not (string-match-p "y allow once" text)))
      (tandem-test--goto-question)
      (should-not (get-text-property (point) 'keymap))
      (should (equal tandem-chat--state "running"))
      (should-not tandem-chat--pending))))

(ert-deftest tandem-permission-withdrawn ()
  (tandem-test-with-chat
    (tandem-test--feed tandem-test--bash-request
                            '(:kind "permission" :state "withdrawn" :requestId "r1"
                                    :reason "The user stopped the turn."))
    (should (string-match-p "    Withdrawn: The user stopped the turn\\.\n" (tandem-test--transcript)))
    (should-not tandem-chat--pending)))

(ert-deftest tandem-permission-menu-answers-the-oldest ()
  (tandem-test-with-chat
    (tandem-test--feed
     tandem-test--bash-request
     '(:kind "permission" :state "pending" :requestId "r2" :toolName "WebFetch"
             :title "WebFetch https://example.com" :input (:url "https://example.com")
             :alwaysRule "WebFetch(domain:example.com)"))
    (should (string-match-p "Claude wants to fetch:\n      https://example\\.com\n"
                            (tandem-test--transcript)))
    (goto-char (point-max))
    (let (sent)
      (cl-letf (((symbol-function 'tandem-rpc-request)
                 (lambda (_method params &optional _timeout) (push params sent) '(:ok t)))
                ((symbol-function 'read-multiple-choice) (lambda (&rest _) '(?d "deny with a reason")))
                ((symbol-function 'read-string) (lambda (&rest _) "not now")))
        (tandem-chat-answer-permission)
        (with-temp-buffer
          (tandem-answer-permission)))
      (should (equal sent '((:requestId "r1" :decision "deny" :always :json-false :message "not now")
                            (:requestId "r1" :decision "deny" :always :json-false :message "not now")))))))

(ert-deftest tandem-permission-fontifying-is-quiet ()
  (let ((shown '()))
    (cl-letf* ((real-message (symbol-function 'message))
               ((symbol-function 'message)
                (lambda (format-string &rest args)
                  (unless (or inhibit-message (null message-log-max) (null format-string))
                    (push (apply #'format-message format-string args) shown))
                  (apply real-message format-string args))))
      (tandem-chat--fontify-shell "echo $HOME"))
    (should-not shown)))

(ert-deftest tandem-permission-denials-you-made-are-not-repeated ()
  (tandem-test-with-chat
    (tandem-test--feed tandem-test--bash-request
                            '(:kind "permission" :state "answered" :requestId "r1" :decision "deny"
                                    :always :json-false :message "no")
                            '(:kind "result" :subtype "success" :costUsd 0.01 :durationMs 10
                                    :cancelled :json-false :isError :json-false
                                    :permissionDenials ["Bash"]))
    (should-not (string-match-p "Not allowed" (tandem-test--transcript)))
    (tandem-test--feed '(:kind "result" :subtype "success" :costUsd 0.01 :durationMs 10
                                    :cancelled :json-false :isError :json-false
                                    :permissionDenials ["WebFetch" "WebFetch"]))
    (should (string-match-p "  Not allowed: WebFetch\.  Claude Code denied it without asking you"
                            (tandem-test--transcript)))))

(ert-deftest tandem-permission-wait-is-not-tool-time ()
  (tandem-test-with-chat
    (tandem-test--feed '(:kind "tool" :id "toolu_1" :name "Bash" :title "Bash touch x" :status "started"))
    (tandem-chat--handle-update
     '(:kind "permission" :state "pending" :requestId "r9" :toolName "Bash" :toolUseId "toolu_1"
             :title "Bash touch x" :input (:command "touch x") :alwaysRule "Bash(touch x)"))
    ;; Pretend the question waited 5 seconds for an answer.
    (puthash "toolu_1" (- (float-time) 5) tandem-chat--asked-at)
    (tandem-test--feed
     '(:kind "permission" :state "answered" :requestId "r9" :decision "allow" :always :json-false)
     '(:kind "tool" :id "toolu_1" :name "Bash" :title "Bash touch x" :status "done" :durationMs 5300))
    (should (string-match-p "✓ Bash touch x  \\(2[0-9][0-9]\\|3[0-9][0-9]\\) ms" (tandem-test--transcript)))))

(ert-deftest tandem-permission-nothing-to-answer ()
  (tandem-test-with-chat
    (should-error (tandem-chat-allow) :type 'user-error)
    (should-error (tandem-chat-answer-permission) :type 'user-error)))

;;;; Through the daemon, its MCP helper and the fake claude

(defun tandem-test--wait-question (buffer)
  "Wait until BUFFER shows a permission question, and return its id."
  (should (tandem-test--wait-for
           (lambda () (with-current-buffer buffer
                        (and tandem-chat--pending (null tandem-chat--queue))))
           10))
  (with-current-buffer buffer (car tandem-chat--pending)))

(ert-deftest tandem-permission-allow-for-real ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--send buffer "script:bash:touch x")
    (tandem-test--wait-question buffer)
    (with-current-buffer buffer
      (tandem-test--goto-question)
      (tandem-chat-allow))
    (tandem-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "⏸ Claude wants to run:\n      touch x\n" text))
        (should (string-match-p "    ✓ Allowed\n" text))
        (should (string-match-p "allowed: touch x" text))))))

(ert-deftest tandem-permission-deny-with-a-reason-for-real ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--send buffer "script:bash:rm -rf build")
    (tandem-test--wait-question buffer)
    (with-current-buffer buffer
      (tandem-test--goto-question)
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "use make clean")))
        (tandem-chat-deny-with-reason)))
    (tandem-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "    ✗ Denied: use make clean\n" text))
        (should (string-match-p "denied: use make clean" text))))))

(ert-deftest tandem-permission-always-allow-for-real ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--send buffer "script:bash2:touch x")
    (tandem-test--wait-question buffer)
    (with-current-buffer buffer
      (tandem-test--goto-question)
      (tandem-chat-allow-always))
    (tandem-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "    ✓ Always allowed: Bash(touch x)\n" text))
        (should (string-match-p "allowed by rule: touch x" text))
        (should (= 1 (cl-count-if (lambda (line) (string-match-p "Claude wants to run" line))
                                  (split-string text "\n"))))))))

(ert-deftest tandem-permission-cancel-withdraws-for-real ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (tandem-test--send buffer "script:bash:touch x")
    (tandem-test--wait-question buffer)
    (with-current-buffer buffer
      (tandem-chat-cancel))
    (tandem-test--wait-idle buffer)
    (with-current-buffer buffer
      (let ((text (tandem-test--transcript)))
        (should (string-match-p "    Withdrawn: The user stopped the turn\\.\n" text))
        (should (string-match-p "  Stopped\\.\n" text))
        (should-not tandem-chat--pending)))))

(provide 'tandem-permission-tests)
;;; tandem-permission-tests.el ends here
