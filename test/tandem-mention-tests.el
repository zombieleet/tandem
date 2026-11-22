;;; tandem-mention-tests.el --- Tests for @ mentions in the chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project with a Python file open beside a chat: what each mention
;; attaches, how mentions show, and completing them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'flymake)
(require 'tandem)
(require 'tandem-test-helpers)

(defmacro tandem-test-with-mentions (&rest body)
  "Run BODY in a chat about a project; SOURCE is geo.py's buffer there."
  (declare (indent 0) (debug t))
  `(let* ((dir (file-name-as-directory (tandem-test--private-dir)))
          (tandem-chat--buffers (make-hash-table :test #'equal))
          (chat (generate-new-buffer "*tandem: mention test*")))
     (make-directory (expand-file-name "src" dir) t)
     (with-temp-file (expand-file-name "src/geo.py" dir)
       (insert "import math\n\n\ndef area(r):\n    return math.pi * r * r\n"))
     (with-temp-file (expand-file-name "README.md" dir) (insert "# geo\n"))
     (let ((source (find-file-noselect (expand-file-name "src/geo.py" dir))))
       (cl-letf (((symbol-function 'tandem-mention--source) (lambda () source)))
         (unwind-protect
             (with-current-buffer chat
               (tandem-chat--setup "s7" (directory-file-name dir))
               (setq tandem-chat--state "idle")
               ,@body)
           (with-current-buffer source (set-buffer-modified-p nil))
           (kill-buffer source)
           (kill-buffer chat)
           (delete-directory dir t))))))

(ert-deftest tandem-mention-a-file ()
  (tandem-test-with-mentions
    (should (equal (tandem-mention-expand "look at @src/geo.py please")
                   (concat "look at @src/geo.py please\n\nContext the user attached:\n\n"
                           "@src/geo.py is the file src/geo.py in the project (read it as needed).")))
    ;; Not a file: left alone.  Nor is an e-mail address a mention.
    (should (equal (tandem-mention-expand "ask @nobody or me@example.com")
                   "ask @nobody or me@example.com"))))

(ert-deftest tandem-mention-the-buffer ()
  (tandem-test-with-mentions
    (should (string-suffix-p "@buffer is the file src/geo.py (saved; read it)."
                             (tandem-mention-expand "what does @buffer do?")))
    ;; With unsaved changes, Claude gets the text as it is now.
    (with-current-buffer source
      (goto-char (point-max))
      (insert "UNSAVED = 1\n"))
    (let ((text (tandem-mention-expand "what does @buffer do?")))
      (should (string-match-p "@buffer is src/geo.py with unsaved changes; its text now:" text))
      (should (string-match-p "UNSAVED = 1" text)))))

(ert-deftest tandem-mention-the-region ()
  (tandem-test-with-mentions
    (with-current-buffer source
      (goto-char (point-min))
      (search-forward "def area")
      (beginning-of-line)
      (set-mark (point))
      (forward-line 2))
    (should (string-suffix-p
             "@region is lines 4-5 of src/geo.py:\n```python\ndef area(r):\n    return math.pi * r * r\n```"
             (tandem-mention-expand "simplify @region,")))))

(ert-deftest tandem-mention-diagnostics-from-flymake ()
  (tandem-test-with-mentions
    (with-current-buffer source
      (setq-local flymake-diagnostic-functions
                  (list (lambda (report &rest _)
                          (funcall report (list (flymake-make-diagnostic
                                                 (current-buffer) 15 22 :error "undefined name 'r2'"))))))
      (flymake-mode 1)
      (flymake-start)
      (should (tandem-test--wait-for (lambda () (flymake-diagnostics)) 3)))
    (should (string-suffix-p "@diagnostics of src/geo.py:\nsrc/geo.py:4: error: undefined name 'r2'"
                             (tandem-mention-expand "fix @diagnostics")))
    (with-current-buffer source (flymake-mode -1))
    (should (string-match-p "has none" (tandem-mention-expand "fix @diagnostics")))))

(ert-deftest tandem-mention-each-once-in-order ()
  (should (equal (tandem-mention--names "@region and @buffer, then @region again.")
                 '("region" "buffer")))
  (should (equal (tandem-mention--names "(@src/a.py) x@y @b") '("src/a.py" "b"))))

(ert-deftest tandem-mention-buttons-in-the-transcript ()
  (tandem-test-with-mentions
    (let* ((text (tandem-mention-buttons "see @src/geo.py and @nothing"))
           (at (string-search "@src" text)))
      (should (eq (get-text-property at 'face text) 'tandem-mention))
      (should (get-text-property at 'keymap text))
      (should-not (get-text-property (string-search "@nothing" text) 'face text)))))

(ert-deftest tandem-mention-completion ()
  (tandem-test-with-mentions
    (goto-char (point-max))
    (insert "look at @sr")
    (let ((capf (tandem-mention-capf)))
      (should capf)
      (should (equal (buffer-substring-no-properties (nth 0 capf) (nth 1 capf)) "sr"))
      (let ((all (all-completions "" (nth 2 capf))))
        (should (member "src/geo.py" all))
        (should (member "region" all))))
    ;; Not after a word: an e-mail address is not completed.
    (tandem-chat--set-input "me@exa")
    (should-not (tandem-mention-capf))
    (tandem-chat--set-input "")
    (tandem-mention-insert "region")
    (should (equal (tandem-chat--input-text) "@region "))
    (should (eq (key-binding (kbd "C-c @")) #'tandem-mention-insert))))

(ert-deftest tandem-mention-sent-with-the-message ()
  (tandem-test-with-mentions
    (let (sent)
      (cl-letf (((symbol-function 'tandem-rpc-request)
                 (lambda (method params &rest _) (when (eq method 'session/prompt) (setq sent (plist-get params :text))) '(:ok t))))
        (goto-char (point-max))
        (insert "summarise @README.md")
        (tandem-chat-send))
      (should (string-prefix-p "summarise @README.md\n\nContext the user attached:" sent))
      ;; The transcript shows your words, with the mention as a button.
      (goto-char (point-min))
      (search-forward "summarise @README")
      (should (eq (get-text-property (- (point) 7) 'face) 'tandem-mention))
      (should-not (string-match-p "Context the user attached" (tandem-test--transcript))))))

(provide 'tandem-mention-tests)
;;; tandem-mention-tests.el ends here
