;;; tandem-markdown-tests.el --- Tests for code in the chat  -*- lexical-binding: t; -*-

;;; Commentary:

;; Inline code and fenced blocks, rendered once and while streaming, and
;; in the chat itself.

;;; Code:

(require 'ert)
(require 'tandem)
(require 'tandem-test-helpers)

(defun tandem-test--face-at (text)
  "Return the face list at the first TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (let ((face (get-text-property (match-beginning 0) 'face)))
      (if (listp face) face (list face)))))

(defun tandem-test--invisible-at (text)
  "Return the invisible property at the first TEXT in the buffer."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (get-text-property (match-beginning 0) 'invisible)))

(ert-deftest tandem-markdown-inline-code ()
  (with-temp-buffer
    (insert "Call `area` with `r`, not ``.\n")
    (tandem-markdown-render (point-min) (point-max) t)
    (should (memq 'tandem-markdown-code (tandem-test--face-at "area")))
    (should (tandem-test--invisible-at "`area"))
    (should-not (tandem-test--invisible-at "Call"))
    ;; The text is unchanged: copying keeps the backticks.
    (should (equal (buffer-string) "Call `area` with `r`, not ``.\n"))))

(ert-deftest tandem-markdown-a-python-block ()
  (with-temp-buffer
    (insert "Here:\n```python\ndef area(r):\n    return 3 * r  # `not inline`\n```\nDone `x`.\n")
    (tandem-markdown-render (point-min) (point-max) t)
    (should (memq 'tandem-markdown-fence (tandem-test--face-at "```python")))
    (should (memq 'font-lock-keyword-face (tandem-test--face-at "def")))
    (should (memq 'font-lock-function-name-face (tandem-test--face-at "area")))
    (should (memq 'tandem-markdown-block (tandem-test--face-at "return")))
    (should (memq 'font-lock-comment-face (tandem-test--face-at "not inline")))
    ;; Backticks inside a block are code, not inline code.
    (should-not (tandem-test--invisible-at "`not inline"))
    (should (memq 'tandem-markdown-code (tandem-test--face-at "x`.")))))

(ert-deftest tandem-markdown-unknown-language ()
  (with-temp-buffer
    (insert "```nosuchlang\nsome code\n```\n")
    (tandem-markdown-render (point-min) (point-max) t)
    (should (equal (tandem-test--face-at "some code") '(tandem-markdown-block)))))

(ert-deftest tandem-markdown-mode-hooks-never-run ()
  (let* ((ran nil)
         (python-mode-hook (list (lambda () (setq ran t)))))
    (with-temp-buffer
      (insert "```python\nx = 1\n```\n")
      (kill-buffer (get-buffer-create " *tandem fontify: python-mode*"))
      (tandem-markdown-render (point-min) (point-max) t))
    (should-not ran)))

(ert-deftest tandem-markdown-while-streaming ()
  (with-temp-buffer
    (insert "See `a` and `b")
    ;; An unfinished line waits.
    (should (= (tandem-markdown-render (point-min) (point-max) nil) (point-min)))
    (insert "`.\n```python\ndef f():\n")
    ;; The whole line is rendered; the open block waits for its fence.
    (let ((stop (tandem-markdown-render (point-min) (point-max) nil)))
      (should (memq 'tandem-markdown-code (tandem-test--face-at "b`")))
      (should (= stop (save-excursion (goto-char (point-min)) (search-forward "```") (match-beginning 0))))
      (should-not (get-text-property (1+ (save-excursion (goto-char (point-min)) (search-forward "def") (match-beginning 0))) 'face))
      (insert "    pass\n```\n")
      (should (= (tandem-markdown-render stop (point-max) nil) (point-max)))
      (should (memq 'font-lock-keyword-face (tandem-test--face-at "def"))))))

(ert-deftest tandem-markdown-an-unclosed-block-at-the-end ()
  (with-temp-buffer
    (insert "```python\ndef f():\n    pass")
    (tandem-markdown-render (point-min) (point-max) t)
    (should (memq 'font-lock-keyword-face (tandem-test--face-at "def")))))

(ert-deftest tandem-markdown-in-the-chat ()
  (let ((tandem-chat--buffers (make-hash-table :test #'equal))
        (chat (generate-new-buffer "*tandem: markdown test*")))
    (unwind-protect
        (with-current-buffer chat
          (tandem-chat--setup "s9" "/tmp")
          ;; Your message.
          (tandem-chat--draw-user "why does `area` fail?")
          (should (memq 'tandem-markdown-code (tandem-test--face-at "area` fail")))
          ;; Claude's answer, streamed in pieces that split the block.
          (dolist (piece '("Use `math.pi`:\n``" "`python\nimport math\n" "x = math.pi\n``" "`\nThat is all."))
            (tandem-chat--enqueue (cons 'text piece))
            (tandem-chat--flush))
          (should (memq 'tandem-markdown-code (tandem-test--face-at "math.pi`:")))
          (should (memq 'font-lock-keyword-face (tandem-test--face-at "import")))
          ;; A tool line after the text is never Markdown.
          (tandem-chat--enqueue (list 'tool-start "t1" "Bash echo `date`"))
          (tandem-chat--flush)
          (should-not (tandem-test--invisible-at "`date`"))
          (should-not tandem-chat--markdown-start))
      (kill-buffer chat))))

(ert-deftest tandem-markdown-while-you-type ()
  (let ((tandem-chat--buffers (make-hash-table :test #'equal))
        (chat (generate-new-buffer "*tandem: draft test*")))
    (unwind-protect
        (with-current-buffer chat
          (tandem-chat--setup "s9" "/tmp")
          (goto-char (point-max))
          (insert "why does `area")
          (should-not (get-text-property (1- (point)) 'face))
          (insert "` fail?")
          ;; Coloured as you type; the backticks dimmed, not hidden.
          (should (memq 'tandem-markdown-code (tandem-test--face-at "area` fail")))
          (should (memq 'tandem-markdown-fence (tandem-test--face-at "`area")))
          (should-not (tandem-test--invisible-at "`area"))
          ;; A block colours when its fence closes, and goes plain again when broken.
          (insert "\n```python\ndef f():\n    pass\n```")
          (should (memq 'font-lock-keyword-face (tandem-test--face-at "def")))
          (delete-char -3)
          (delete-char -1)
          (insert "\nmore")
          (should (memq 'font-lock-keyword-face (tandem-test--face-at "def")))
          (goto-char (point-min)) (search-forward "```python") (replace-match "plain")
          (should-not (memq 'font-lock-keyword-face (tandem-test--face-at "def")))
          ;; The text sent is unchanged.
          (should (equal (tandem-chat--input-text) "why does `area` fail?\nplain\ndef f():\n    pass\nmore")))
      (kill-buffer chat))))

(provide 'tandem-markdown-tests)
;;; tandem-markdown-tests.el ends here
