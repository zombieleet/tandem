;;; tandem-ask-tests.el --- Tests for asking Claude about any code  -*- lexical-binding: t; -*-

;;; Commentary:

;; Asking about a region, a function or a line: the message Claude gets,
;; the note above the code, and the chat it goes through.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defconst tandem-test--py
  "import math\n\n\ndef area(r):\n    return math.pi * r * r\n\n\ndef main():\n    print(area(2))\n"
  "A small Python file.")

(defmacro tandem-test-with-ask (&rest body)
  "Run BODY in geo.py of a project with an idle chat; SENT collects prompts.
DIR is the project, CHAT the chat buffer."
  (declare (indent 0) (debug t))
  `(let* ((dir (file-name-as-directory (tandem-test--private-dir)))
          (tandem-chat--buffers (make-hash-table :test #'equal))
          (chat (generate-new-buffer "*tandem: ask test*"))
          (sent nil))
     (with-current-buffer chat
       (tandem-chat--setup "s9" (directory-file-name dir))
       (setq tandem-chat--state "idle"))
     (with-temp-file (expand-file-name "geo.py" dir) (insert tandem-test--py))
     (cl-letf (((symbol-function 'tandem-rpc-request)
                (lambda (method params &rest _)
                  (when (eq method 'session/prompt) (push (plist-get params :text) sent))
                  '(:ok t)))
               ((symbol-function 'tandem-chat--project-root)
                (lambda () (directory-file-name dir))))
       (unwind-protect
           (with-current-buffer (find-file-noselect (expand-file-name "geo.py" dir))
             (python-mode)
             ,@body)
         (maphash (lambda (id _) (tandem-review-dismiss-note id)) tandem-review--notes)
         (let ((b (find-buffer-visiting (expand-file-name "geo.py" dir))))
           (when b (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
         (kill-buffer chat)
         (delete-directory dir t)))))

(defun tandem-test--note-here ()
  "Return the text of the note in this buffer, or nil."
  (when-let* ((ov (seq-find (lambda (o) (overlay-get o 'tandem-note))
                            (overlays-in (point-min) (point-max)))))
    (overlay-get ov 'before-string)))

(ert-deftest tandem-ask-about-a-region ()
  (tandem-test-with-ask
    (goto-char (point-min))
    (search-forward "def area")
    (beginning-of-line)
    (set-mark (point))
    (forward-line 2)
    (activate-mark)
    (tandem-ask "explain this")
    (should (equal (car sent)
                   ;; The chat trims what it sends: no newline after the fence.
                   "explain this\n\nIn geo.py, lines 4-5:\n```python\ndef area(r):\n    return math.pi * r * r\n```"))
    ;; A note above the code, which Claude's answer fills.
    (let ((note (tandem-test--note-here)))
      (should (string-match-p "@claude explain this" note)))
    (should-not (region-active-p))
    (with-current-buffer chat
      (should (string-prefix-p "ask-" tandem-chat--answering))
      (tandem-test--feed '(:kind "text" :delta "It computes the area.")))
    (should (string-match-p "Claude: It computes the area\\." (tandem-test--note-here)))))

(ert-deftest tandem-ask-about-the-function-at-point ()
  (tandem-test-with-ask
    (goto-char (point-min))
    (search-forward "print(area")
    (tandem-ask "why 2?")
    (should (string-match-p "\\`why 2\\?\n\nIn geo.py, lines 8-9:\n```python\ndef main():\n    print(area(2))\n```\\'"
                            (car sent)))))

(ert-deftest tandem-ask-keeps-your-draft ()
  (tandem-test-with-ask
    (with-current-buffer chat
      (goto-char (point-max))
      (insert "half-typed thought"))
    (goto-char (point-min))
    (tandem-ask "what is math?")
    (should (string-prefix-p "what is math?" (car sent)))
    (with-current-buffer chat
      (should (equal (tandem-chat--input-text) "half-typed thought")))))

(ert-deftest tandem-ask-when-the-chat-is-busy ()
  (tandem-test-with-ask
    (with-current-buffer chat (setq tandem-chat--state "writing"))
    (goto-char (point-min))
    (should-error (tandem-ask "hello?") :type 'user-error)
    (should-not sent)
    ;; No note left behind.
    (should-not (tandem-test--note-here))
    (should-error (tandem-ask "  ") :type 'user-error)))

(ert-deftest tandem-ask-message-and-fence ()
  (should (equal (tandem-ask--fence "no ticks") "```"))
  (should (equal (tandem-ask--fence "a ``` b") "````"))
  (should (equal (tandem-ask--fence "a ````` b") "``````"))
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (equal (tandem-ask--language) "emacs-lisp"))
    (should (equal (tandem-ask--message "q" "x.el" 3 3 "(a)")
                   "q\n\nIn x.el, line 3:\n```emacs-lisp\n(a)\n```\n"))))

;;;; For real

(ert-deftest tandem-ask-for-real ()
  (tandem-test-with-project
    (with-temp-file (expand-file-name "geo.py" project) (insert tandem-test--py))
    (let ((file-buffer (find-file-noselect (expand-file-name "geo.py" project))))
      (unwind-protect
          (progn
            (setq buffer (with-current-buffer file-buffer (tandem)))
            (with-current-buffer file-buffer
              (goto-char (point-min))
              (search-forward "return math")
              (tandem-ask "explain"))
            (tandem-test--wait-idle buffer)
            (with-current-buffer buffer
              (should (string-match-p "In geo.py, lines 4-5" (tandem-test--transcript))))
            (with-current-buffer file-buffer
              ;; The fake claude echoes the question; it reached the note.
              (should (string-match-p "Claude: You said: explain" (tandem-test--note-here)))))
        (with-current-buffer file-buffer
          (tandem-review-dismiss-note)
          (set-buffer-modified-p nil))
        (kill-buffer file-buffer)))))

(provide 'tandem-ask-tests)
;;; tandem-ask-tests.el ends here
