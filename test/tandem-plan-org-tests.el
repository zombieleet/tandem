;;; tandem-plan-org-tests.el --- Tests for plans, Org tasks and Embark  -*- lexical-binding: t; -*-

;;; Commentary:

;; Markdown into Org; a plan edited in Org and approved or rejected; an Org
;; subtree sent as a task with the answer put under it, through the daemon
;; and the fake claude; and the Embark actions, when Embark is there.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-org)
(require 'tandem-test-helpers)

(ert-deftest tandem-markdown-into-org ()
  (should (equal (tandem-markdown-to-org
                  "# Plan\n\nUse `area`, **twice**, see [docs](http://x).\n* one\n  + two\n```python\n* kept\n#+kept\n```\n*stars* first" 1)
                 (concat "** Plan\n\nUse ~area~, *twice*, see [[http://x][docs]].\n- one\n  - two\n"
                         "#+begin_src python\n,* kept\n,#+kept\n#+end_src\n *stars* first")))
  ;; An unclosed block is closed.
  (should (string-suffix-p "#+end_src" (tandem-markdown-to-org "```\ncode"))))

(defun tandem-test--plan-buffer ()
  "Wait for the plan buffer with an open question; return it."
  (tandem-test--wait-for
   (lambda () (seq-find (lambda (b) (buffer-local-value 'tandem-plan--request b)) (buffer-list)))
   10))

(ert-deftest tandem-plan-edited-and-approved ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "/plan document area")
      (tandem-chat-send))
    (let ((plan (tandem-test--plan-buffer)))
      (should plan)
      (with-current-buffer plan
        (should (derived-mode-p 'org-mode))
        (should tandem-plan-mode)
        (should (equal (string-trim (buffer-string)) "1. Read geo.py\n2. Add a docstring to area"))
        ;; Your edit.
        (goto-char (point-max))
        (insert "3. Add type hints\n")
        (tandem-plan-approve))
      (tandem-test--wait-idle buffer)
      (with-current-buffer buffer
        (let ((text (tandem-test--transcript)))
          (should (string-match-p "You\ndocument area\n" text))
          (should (string-match-p "Following the plan:\n1\\. Read geo\\.py\n2\\. Add a docstring to area\n3\\. Add type hints" text))))
      ;; The plan Claude wrote in its reply is what the buffer showed.
      ;; The question is answered: the buffer no longer answers anything.
      (should-not (buffer-local-value 'tandem-plan--request plan))
      (kill-buffer plan))))

(ert-deftest tandem-plan-y-in-the-chat-opens-the-plan ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (with-current-buffer buffer (tandem-plan "document area"))
    (let ((plan (tandem-test--plan-buffer))
          answered)
      (with-current-buffer buffer
        (tandem-test--wait-for (lambda () (string-match-p "Claude's plan is ready" (tandem-test--transcript))) 5)
        (should (string-match-p "📋 Claude's plan is ready\\.  Edit it in Org, then C-c C-c there to go ahead\\.\n    y or RET open the plan"
                                (tandem-test--transcript)))
        (should-not (string-match-p "Claude wants to use ExitPlanMode" (tandem-test--transcript)))
        ;; y, as you pressed it: the plan opens, nothing is answered.
        (cl-letf (((symbol-function 'tandem-chat--answer) (lambda (&rest args) (setq answered args))))
          (tandem-chat-allow)
          (should-not answered)
          (should (eq (window-buffer (selected-window)) plan))
          (with-current-buffer buffer
            (should-error (tandem-chat-answer-permission) :type 'user-error))
          (should-not answered)))
      (with-current-buffer plan
        (should tandem-plan--request)
        (tandem-plan-approve))
      (tandem-test--wait-idle buffer)
      (with-current-buffer buffer
        (should (string-match-p "Following the plan:" (tandem-test--transcript))))
      (kill-buffer plan))))

(ert-deftest tandem-plan-rejected-with-a-reason ()
  (tandem-test-with-project
    (setq buffer (tandem))
    (with-current-buffer buffer (tandem-plan "document area"))
    (let ((plan (tandem-test--plan-buffer)))
      (with-current-buffer plan (tandem-plan-reject "too big"))
      (tandem-test--wait-idle buffer)
      (with-current-buffer buffer
        (should (string-match-p "The plan was rejected: The user did not accept the plan: too big"
                                (tandem-test--transcript))))
      (kill-buffer plan))))

(ert-deftest tandem-org-subtree-as-a-task ()
  (tandem-test-with-project
    (let ((file (expand-file-name "notes.org" project)))
      (with-temp-file file (insert "* TODO Document area\nSay it takes the radius.\n* Next\n"))
      (let ((org (find-file-noselect file)))
        (unwind-protect
            (progn
              (with-current-buffer org
                (goto-char (point-min))
                (forward-line 1)
                (cl-letf (((symbol-function 'tandem-chat--display) #'identity))
                  (setq buffer (tandem-org-send-subtree))))
              (tandem-test--wait-idle buffer)
              (with-current-buffer buffer
                (should (string-match-p "a task from my Org notes: the subtree \"Document area\""
                                        (tandem-test--transcript))))
              (with-current-buffer org
                (let ((text (buffer-string)))
                  ;; Under the heading, before the next one.
                  (should (string-match-p "\\`\\* TODO Document area\nSay it takes the radius\\.\n\\*\\* Claude's answer \\[[0-9-]+ [A-Za-z]+ [0-9:]+\\]\n" text))
                  (should (string-match-p "\n\\* Next\n\\'" text))
                  ;; Claude's echo of the subtree cannot start headings of its own.
                  (should-not (string-match-p "^\\* TODO Document area\n.*\n\\*\\* Claude's answer.*\n\\(?:.*\n\\)*^\\* TODO" text)))))
          (with-current-buffer org (set-buffer-modified-p nil))
          (kill-buffer org))))))

(ert-deftest tandem-embark-actions ()
  (skip-unless (require 'embark nil t))
  (require 'tandem-embark)
  ;; Nothing changes in Embark's menus until you turn the mode on.
  (tandem-embark-mode -1)
  (should-not (keymap-lookup embark-file-map "@"))
  (tandem-embark-mode 1)
  (should (eq (keymap-lookup embark-file-map "@") #'tandem-embark-ask-file))
  (should (eq (keymap-lookup embark-identifier-map "@") #'tandem-embark-ask-symbol))
  (should (eq (keymap-lookup embark-region-map "@") #'tandem-embark-ask-region))
  (tandem-embark-mode -1)
  (should-not (keymap-lookup embark-region-map "@"))
  (tandem-embark-mode 1)
  (let ((dir (file-name-as-directory (tandem-test--private-dir))) sent)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".project" dir))
          (make-directory (expand-file-name "src" dir))
          (with-temp-file (expand-file-name "src/geo.py" dir) (insert "def area(r): pass\n"))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "what is this? "))
                    ((symbol-function 'tandem-embark--send) (lambda (root text) (setq sent (list root text)))))
            (tandem-embark-ask-file (expand-file-name "src/geo.py" dir))
            (should (equal (cadr sent) "what is this? @src/geo.py"))
            (with-current-buffer (find-file-noselect (expand-file-name "src/geo.py" dir))
              (search-forward "area")
              (tandem-embark-ask-symbol "area")
              (kill-buffer))
            (should (equal (cadr sent) "what is this?\n\nAbout `area` (in src/geo.py, line 1)."))))
      (delete-directory dir t))))

(provide 'tandem-plan-org-tests)
;;; tandem-plan-org-tests.el ends here
