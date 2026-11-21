;;; claude-pair-markdown-tests.el --- Tests for code in the chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; Inline code and fenced blocks, rendered once and while streaming, and
;; in the chat itself.

;;; Code:

(require 'ert)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defun claude-pair-test--face-at (text)
  "Return the face list at the first TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (if (listp face) face (list face)))))

(defun claude-pair-test--invisible-at (text)
  "Return the invisible property at the first TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (get-text-property (match-beginning 0) 'invisible)))

(ert-deftest claude-pair-markdown-inline-code ()
  (with-temp-buffer
    (insert "Call `area` with `r`, not ``.\n")
    (claude-pair-markdown-render (point-min) (point-max) t)
    (should (memq 'claude-pair-markdown-code (claude-pair-test--face-at "area")))
    (should (claude-pair-test--invisible-at "`area"))
    (should-not (claude-pair-test--invisible-at "Call"))
    ;; The text is unchanged: copying keeps the backticks.
    (should (equal (buffer-string) "Call `area` with `r`, not ``.\n"))))

(ert-deftest claude-pair-markdown-a-python-block ()
  (with-temp-buffer
    (insert "Here:\n```python\ndef area(r):\n    return 3 * r  # `not inline`\n```\nDone `x`.\n")
    (claude-pair-markdown-render (point-min) (point-max) t)
    (should (memq 'claude-pair-markdown-fence (claude-pair-test--face-at "```python")))
    (should (memq 'font-lock-keyword-face (claude-pair-test--face-at "def")))
    (should (memq 'font-lock-function-name-face (claude-pair-test--face-at "area")))
    (should (memq 'claude-pair-markdown-block (claude-pair-test--face-at "return")))
    (should (memq 'font-lock-comment-face (claude-pair-test--face-at "not inline")))
    ;; Backticks inside a block are code, not inline code.
    (should-not (claude-pair-test--invisible-at "`not inline"))
    (should (memq 'claude-pair-markdown-code (claude-pair-test--face-at "x`.")))))

(ert-deftest claude-pair-markdown-unknown-language ()
  (with-temp-buffer
    (insert "```nosuchlang\nsome code\n```\n")
    (claude-pair-markdown-render (point-min) (point-max) t)
    (should (equal (claude-pair-test--face-at "some code") '(claude-pair-markdown-block)))))

(ert-deftest claude-pair-markdown-mode-hooks-never-run ()
  (let* ((ran nil)
         (python-mode-hook (list (lambda () (setq ran t)))))
    (with-temp-buffer
      (insert "```python\nx = 1\n```\n")
      (kill-buffer (get-buffer-create " *claude-pair fontify: python-mode*"))
      (claude-pair-markdown-render (point-min) (point-max) t))
    (should-not ran)))

(ert-deftest claude-pair-markdown-while-streaming ()
  (with-temp-buffer
    (insert "See `a` and `b")
    ;; An unfinished line waits.
    (should (= (claude-pair-markdown-render (point-min) (point-max) nil) (point-min)))
    (insert "`.\n```python\ndef f():\n")
    ;; The whole line is rendered; the open block waits for its fence.
    (let ((stop (claude-pair-markdown-render (point-min) (point-max) nil)))
      (should (memq 'claude-pair-markdown-code (claude-pair-test--face-at "b`")))
      (should (= stop (save-excursion (goto-char (point-min)) (search-forward "```") (match-beginning 0))))
      (should-not (get-text-property (1+ (save-excursion (goto-char (point-min)) (search-forward "def") (match-beginning 0))) 'face))
      (insert "    pass\n```\n")
      (should (= (claude-pair-markdown-render stop (point-max) nil) (point-max)))
      (should (memq 'font-lock-keyword-face (claude-pair-test--face-at "def"))))))

(ert-deftest claude-pair-markdown-an-unclosed-block-at-the-end ()
  (with-temp-buffer
    (insert "```python\ndef f():\n    pass")
    (claude-pair-markdown-render (point-min) (point-max) t)
    (should (memq 'font-lock-keyword-face (claude-pair-test--face-at "def")))))

(ert-deftest claude-pair-markdown-in-the-chat ()
  (let ((claude-pair-chat--buffers (make-hash-table :test #'equal))
        (chat (generate-new-buffer "*claude-pair: markdown test*")))
    (unwind-protect
        (with-current-buffer chat
          (claude-pair-chat--setup "s9" "/tmp")
          ;; Your message.
          (claude-pair-chat--draw-user "why does `area` fail?")
          (should (memq 'claude-pair-markdown-code (claude-pair-test--face-at "area` fail")))
          ;; Claude's answer, streamed in pieces that split the block.
          (dolist (piece '("Use `math.pi`:\n``" "`python\nimport math\n" "x = math.pi\n``" "`\nThat is all."))
            (claude-pair-chat--enqueue (cons 'text piece))
            (claude-pair-chat--flush))
          (should (memq 'claude-pair-markdown-code (claude-pair-test--face-at "math.pi`:")))
          (should (memq 'font-lock-keyword-face (claude-pair-test--face-at "import")))
          ;; A tool line after the text is never Markdown.
          (claude-pair-chat--enqueue (list 'tool-start "t1" "Bash echo `date`"))
          (claude-pair-chat--flush)
          (should-not (claude-pair-test--invisible-at "`date`"))
          (should-not claude-pair-chat--markdown-start))
      (kill-buffer chat))))

(ert-deftest claude-pair-markdown-while-you-type ()
  (let ((claude-pair-chat--buffers (make-hash-table :test #'equal))
        (chat (generate-new-buffer "*claude-pair: draft test*")))
    (unwind-protect
        (with-current-buffer chat
          (claude-pair-chat--setup "s9" "/tmp")
          (goto-char (point-max))
          (insert "why does `area")
          (should-not (get-text-property (1- (point)) 'face))
          (insert "` fail?")
          ;; Coloured as you type; the backticks dimmed, not hidden.
          (should (memq 'claude-pair-markdown-code (claude-pair-test--face-at "area` fail")))
          (should (memq 'claude-pair-markdown-fence (claude-pair-test--face-at "`area")))
          (should-not (claude-pair-test--invisible-at "`area"))
          ;; A block colours when its fence closes, and goes plain again when broken.
          (insert "\n```python\ndef f():\n    pass\n```")
          (should (memq 'font-lock-keyword-face (claude-pair-test--face-at "def")))
          (delete-char -3)
          (delete-char -1)
          (insert "\nmore")
          (should (memq 'font-lock-keyword-face (claude-pair-test--face-at "def")))
          (goto-char (point-min)) (search-forward "```python") (replace-match "plain")
          (should-not (memq 'font-lock-keyword-face (claude-pair-test--face-at "def")))
          ;; The text sent is unchanged.
          (should (equal (claude-pair-chat--input-text) "why does `area` fail?\nplain\ndef f():\n    pass\nmore")))
      (kill-buffer chat))))

(provide 'claude-pair-markdown-tests)
;;; claude-pair-markdown-tests.el ends here
