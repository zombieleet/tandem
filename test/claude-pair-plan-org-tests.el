;;; claude-pair-plan-org-tests.el --- Tests for plans, Org tasks and Embark  -*- lexical-binding: t; -*-

;;; Commentary:

;; Markdown into Org; a plan edited in Org and approved or rejected; an Org
;; subtree sent as a task with the answer put under it, through the daemon
;; and the fake claude; and the Embark actions, when Embark is there.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-org)
(require 'claude-pair-test-helpers)

(ert-deftest claude-pair-markdown-into-org ()
  (should (equal (claude-pair-markdown-to-org
                  "# Plan\n\nUse `area`, **twice**, see [docs](http://x).\n* one\n  + two\n```python\n* kept\n#+kept\n```\n*stars* first" 1)
                 (concat "** Plan\n\nUse ~area~, *twice*, see [[http://x][docs]].\n- one\n  - two\n"
                         "#+begin_src python\n,* kept\n,#+kept\n#+end_src\n *stars* first")))
  ;; An unclosed block is closed.
  (should (string-suffix-p "#+end_src" (claude-pair-markdown-to-org "```\ncode"))))

(defun claude-pair-test--plan-buffer ()
  "Wait for the plan buffer with an open question; return it."
  (claude-pair-test--wait-for
   (lambda () (seq-find (lambda (b) (buffer-local-value 'claude-pair-plan--request b)) (buffer-list)))
   10))

(ert-deftest claude-pair-plan-edited-and-approved ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "/plan document area")
      (claude-pair-chat-send))
    (let ((plan (claude-pair-test--plan-buffer)))
      (should plan)
      (with-current-buffer plan
        (should (derived-mode-p 'org-mode))
        (should claude-pair-plan-mode)
        (should (equal (string-trim (buffer-string)) "1. Read geo.py\n2. Add a docstring to area"))
        ;; Your edit.
        (goto-char (point-max))
        (insert "3. Add type hints\n")
        (claude-pair-plan-approve))
      (claude-pair-test--wait-idle buffer)
      (with-current-buffer buffer
        (let ((text (claude-pair-test--transcript)))
          (should (string-match-p "You\ndocument area\n" text))
          (should (string-match-p "Following the plan:\n1\\. Read geo\\.py\n2\\. Add a docstring to area\n3\\. Add type hints" text))))
      ;; The plan Claude wrote in its reply is what the buffer showed.
      ;; The question is answered: the buffer no longer answers anything.
      (should-not (buffer-local-value 'claude-pair-plan--request plan))
      (kill-buffer plan))))

(ert-deftest claude-pair-plan-y-in-the-chat-opens-the-plan ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (with-current-buffer buffer (claude-pair-plan "document area"))
    (let ((plan (claude-pair-test--plan-buffer))
          answered)
      (with-current-buffer buffer
        (claude-pair-test--wait-for (lambda () (string-match-p "Claude's plan is ready" (claude-pair-test--transcript))) 5)
        (should (string-match-p "📋 Claude's plan is ready\\.  Edit it in Org, then C-c C-c there to go ahead\\.\n    y or RET open the plan"
                                (claude-pair-test--transcript)))
        (should-not (string-match-p "Claude wants to use ExitPlanMode" (claude-pair-test--transcript)))
        ;; y, as you pressed it: the plan opens, nothing is answered.
        (cl-letf (((symbol-function 'claude-pair-chat--answer) (lambda (&rest args) (setq answered args))))
          (claude-pair-chat-allow)
          (should-not answered)
          (should (eq (window-buffer (selected-window)) plan))
          (with-current-buffer buffer
            (should-error (claude-pair-chat-answer-permission) :type 'user-error))
          (should-not answered)))
      (with-current-buffer plan
        (should claude-pair-plan--request)
        (claude-pair-plan-approve))
      (claude-pair-test--wait-idle buffer)
      (with-current-buffer buffer
        (should (string-match-p "Following the plan:" (claude-pair-test--transcript))))
      (kill-buffer plan))))

(ert-deftest claude-pair-plan-rejected-with-a-reason ()
  (claude-pair-test-with-project
    (setq buffer (claude-pair))
    (with-current-buffer buffer (claude-pair-plan "document area"))
    (let ((plan (claude-pair-test--plan-buffer)))
      (with-current-buffer plan (claude-pair-plan-reject "too big"))
      (claude-pair-test--wait-idle buffer)
      (with-current-buffer buffer
        (should (string-match-p "The plan was rejected: The user did not accept the plan: too big"
                                (claude-pair-test--transcript))))
      (kill-buffer plan))))

(ert-deftest claude-pair-org-subtree-as-a-task ()
  (claude-pair-test-with-project
    (let ((file (expand-file-name "notes.org" project)))
      (with-temp-file file (insert "* TODO Document area\nSay it takes the radius.\n* Next\n"))
      (let ((org (find-file-noselect file)))
        (unwind-protect
            (progn
              (with-current-buffer org
                (goto-char (point-min))
                (forward-line 1)
                (cl-letf (((symbol-function 'claude-pair-chat--display) #'identity))
                  (setq buffer (claude-pair-org-send-subtree))))
              (claude-pair-test--wait-idle buffer)
              (with-current-buffer buffer
                (should (string-match-p "a task from my Org notes: the subtree \"Document area\""
                                        (claude-pair-test--transcript))))
              (with-current-buffer org
                (let ((text (buffer-string)))
                  ;; Under the heading, before the next one.
                  (should (string-match-p "\\`\\* TODO Document area\nSay it takes the radius\\.\n\\*\\* Claude's answer \\[[0-9-]+ [A-Za-z]+ [0-9:]+\\]\n" text))
                  (should (string-match-p "\n\\* Next\n\\'" text))
                  ;; Claude's echo of the subtree cannot start headings of its own.
                  (should-not (string-match-p "^\\* TODO Document area\n.*\n\\*\\* Claude's answer.*\n\\(?:.*\n\\)*^\\* TODO" text)))))
          (with-current-buffer org (set-buffer-modified-p nil))
          (kill-buffer org))))))

(ert-deftest claude-pair-embark-actions ()
  (skip-unless (require 'embark nil t))
  (require 'claude-pair-embark)
  (should (eq (keymap-lookup embark-file-map "@") #'claude-pair-embark-ask-file))
  (should (eq (keymap-lookup embark-identifier-map "@") #'claude-pair-embark-ask-symbol))
  (should (eq (keymap-lookup embark-region-map "@") #'claude-pair-embark-ask-region))
  (let ((dir (file-name-as-directory (claude-pair-test--private-dir))) sent)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".project" dir))
          (make-directory (expand-file-name "src" dir))
          (with-temp-file (expand-file-name "src/geo.py" dir) (insert "def area(r): pass\n"))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "what is this? "))
                    ((symbol-function 'claude-pair-embark--send) (lambda (root text) (setq sent (list root text)))))
            (claude-pair-embark-ask-file (expand-file-name "src/geo.py" dir))
            (should (equal (cadr sent) "what is this? @src/geo.py"))
            (with-current-buffer (find-file-noselect (expand-file-name "src/geo.py" dir))
              (search-forward "area")
              (claude-pair-embark-ask-symbol "area")
              (kill-buffer))
            (should (equal (cadr sent) "what is this?\n\nAbout `area` (in src/geo.py, line 1)."))))
      (delete-directory dir t))))

(provide 'claude-pair-plan-org-tests)
;;; claude-pair-plan-org-tests.el ends here
