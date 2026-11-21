;;; claude-pair-ask-tests.el --- Tests for asking Claude about any code  -*- lexical-binding: t; -*-

;;; Commentary:

;; Asking about a region, a function or a line: the message Claude gets,
;; the note above the code, and the chat it goes through.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--py
  "import math\n\n\ndef area(r):\n    return math.pi * r * r\n\n\ndef main():\n    print(area(2))\n"
  "A small Python file.")

(defmacro claude-pair-test-with-ask (&rest body)
  "Run BODY in geo.py of a project with an idle chat; SENT collects prompts.
DIR is the project, CHAT the chat buffer."
  (declare (indent 0) (debug t))
  `(let* ((dir (file-name-as-directory (claude-pair-test--private-dir)))
          (claude-pair-chat--buffers (make-hash-table :test #'equal))
          (chat (generate-new-buffer "*claude-pair: ask test*"))
          (sent nil))
     (with-current-buffer chat
       (claude-pair-chat--setup "s9" (directory-file-name dir))
       (setq claude-pair-chat--state "idle"))
     (with-temp-file (expand-file-name "geo.py" dir) (insert claude-pair-test--py))
     (cl-letf (((symbol-function 'claude-pair-rpc-request)
                (lambda (method params &rest _)
                  (when (eq method 'session/prompt) (push (plist-get params :text) sent))
                  '(:ok t)))
               ((symbol-function 'claude-pair-chat--project-root)
                (lambda () (directory-file-name dir))))
       (unwind-protect
           (with-current-buffer (find-file-noselect (expand-file-name "geo.py" dir))
             (python-mode)
             ,@body)
         (maphash (lambda (id _) (claude-pair-review-dismiss-note id)) claude-pair-review--notes)
         (let ((b (find-buffer-visiting (expand-file-name "geo.py" dir))))
           (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
         (kill-buffer chat)
         (delete-directory dir t)))))

(defun claude-pair-test--note-here ()
  "Return the text of the note in this buffer, or nil."
  (when-let* ((ov (seq-find (lambda (o) (overlay-get o 'claude-pair-note))
                            (overlays-in (point-min) (point-max)))))
    (overlay-get ov 'before-string)))

(ert-deftest claude-pair-ask-about-a-region ()
  (claude-pair-test-with-ask
    (goto-char (point-min))
    (search-forward "def area")
    (beginning-of-line)
    (set-mark (point))
    (forward-line 2)
    (activate-mark)
    (claude-pair-ask "explain this")
    (should (equal (car sent)
                   ;; The chat trims what it sends: no newline after the fence.
                   "explain this\n\nIn geo.py, lines 4-5:\n```python\ndef area(r):\n    return math.pi * r * r\n```"))
    ;; A note above the code, which Claude's answer fills.
    (let ((note (claude-pair-test--note-here)))
      (should (string-match-p "@claude explain this" note)))
    (should-not (region-active-p))
    (with-current-buffer chat
      (should (string-prefix-p "ask-" claude-pair-chat--answering))
      (claude-pair-test--feed '(:kind "text" :delta "It computes the area.")))
    (should (string-match-p "Claude: It computes the area\\." (claude-pair-test--note-here)))))

(ert-deftest claude-pair-ask-about-the-function-at-point ()
  (claude-pair-test-with-ask
    (goto-char (point-min))
    (search-forward "print(area")
    (claude-pair-ask "why 2?")
    (should (string-match-p "\\`why 2\\?\n\nIn geo.py, lines 8-9:\n```python\ndef main():\n    print(area(2))\n```\\'"
                            (car sent)))))

(ert-deftest claude-pair-ask-keeps-your-draft ()
  (claude-pair-test-with-ask
    (with-current-buffer chat
      (goto-char (point-max))
      (insert "half-typed thought"))
    (goto-char (point-min))
    (claude-pair-ask "what is math?")
    (should (string-prefix-p "what is math?" (car sent)))
    (with-current-buffer chat
      (should (equal (claude-pair-chat--input-text) "half-typed thought")))))

(ert-deftest claude-pair-ask-when-the-chat-is-busy ()
  (claude-pair-test-with-ask
    (with-current-buffer chat (setq claude-pair-chat--state "writing"))
    (goto-char (point-min))
    (should-error (claude-pair-ask "hello?") :type 'user-error)
    (should-not sent)
    ;; No note left behind.
    (should-not (claude-pair-test--note-here))
    (should-error (claude-pair-ask "  ") :type 'user-error)))

(ert-deftest claude-pair-ask-message-and-fence ()
  (should (equal (claude-pair-ask--fence "no ticks") "```"))
  (should (equal (claude-pair-ask--fence "a ``` b") "````"))
  (should (equal (claude-pair-ask--fence "a ````` b") "``````"))
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (equal (claude-pair-ask--language) "emacs-lisp"))
    (should (equal (claude-pair-ask--message "q" "x.el" 3 3 "(a)")
                   "q\n\nIn x.el, line 3:\n```emacs-lisp\n(a)\n```\n"))))

;;;; For real

(ert-deftest claude-pair-ask-for-real ()
  (claude-pair-test-with-project
    (with-temp-file (expand-file-name "geo.py" project) (insert claude-pair-test--py))
    (let ((file-buffer (find-file-noselect (expand-file-name "geo.py" project))))
      (unwind-protect
          (progn
            (setq buffer (with-current-buffer file-buffer (claude-pair)))
            (with-current-buffer file-buffer
              (goto-char (point-min))
              (search-forward "return math")
              (claude-pair-ask "explain"))
            (claude-pair-test--wait-idle buffer)
            (with-current-buffer buffer
              (should (string-match-p "In geo.py, lines 4-5" (claude-pair-test--transcript))))
            (with-current-buffer file-buffer
              ;; The fake claude echoes the question; it reached the note.
              (should (string-match-p "Claude: You said: explain" (claude-pair-test--note-here)))))
        (with-current-buffer file-buffer
          (claude-pair-review-dismiss-note)
          (set-buffer-modified-p nil))
        (kill-buffer file-buffer)))))

(provide 'claude-pair-ask-tests)
;;; claude-pair-ask-tests.el ends here
