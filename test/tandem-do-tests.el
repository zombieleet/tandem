;;; tandem-do-tests.el --- Tests for telling Claude what to do with code  -*- lexical-binding: t; -*-

;;; Commentary:

;; tandem-do: the instruction Claude gets for the region, the function or
;; the line, the line saying Claude is on it, plan mode, and a real turn in
;; which the change comes back as a hunk in the buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)
(require 'tandem-ask-tests)

(defmacro tandem-test-with-do (&rest body)
  "Run BODY as `tandem-test-with-ask' does; MODES collects permission modes."
  (declare (indent 0) (debug t))
  `(let ((modes nil))
     (tandem-test-with-ask
       (cl-letf* ((stub (symbol-function 'tandem-rpc-request))
                  ((symbol-function 'tandem-rpc-request)
                   (lambda (method params &rest rest)
                     (when (eq method 'session/prompt) (push (plist-get params :permissionMode) modes))
                     (apply stub method params rest))))
         ,@body))))

(defun tandem-test--working-here ()
  "Return the text of the line saying Claude is working, or nil."
  (when-let* ((ov (tandem-test--overlay-with 'tandem-do (current-buffer))))
    (overlay-get ov 'before-string)))

(ert-deftest tandem-do-an-action-on-the-function-at-point ()
  (tandem-test-with-do
    (goto-char (point-min))
    (search-forward "return math")
    (tandem-do "Document")
    (let ((text (car sent)))
      (should (string-prefix-p (concat (cdr (assoc "Document" tandem-do-actions))
                                       "\n\nIn geo.py, lines 4-5:\n```python\ndef area(r):\n")
                               text))
      ;; How to make the change: with the edit tool, for review.
      (should (string-match-p "edit tool" text)))
    (should (equal modes '(nil)))
    ;; Claude is on it, above the code, until the turn ends.
    (should (string-match-p "Claude is on it: document" (tandem-test--working-here)))
    (with-current-buffer chat
      (tandem-test--feed '(:kind "result" :subtype "success" :isError :false)))
    (should-not (tandem-test--working-here))))

(ert-deftest tandem-do-your-own-instruction-on-a-region ()
  (tandem-test-with-do
    (goto-char (point-min))
    (search-forward "def main")
    (beginning-of-line)
    (set-mark (point))
    (forward-line 1)
    (activate-mark)
    (tandem-do "rename main to run")
    (should (string-prefix-p "rename main to run\n\nIn geo.py, line 8:\n```python\ndef main():\n```"
                             (car sent)))
    (should-not (region-active-p))
    (should (string-match-p "Claude is on it: rename main to run" (tandem-test--working-here)))))

(ert-deftest tandem-do-with-a-plan-first ()
  (tandem-test-with-do
    (goto-char (point-min))
    (search-forward "print")
    (tandem-do "Refactor" t)
    (should (equal modes '("plan")))))

(ert-deftest tandem-do-sends-what-emacs-reports-there ()
  (tandem-test-with-do
    (cl-letf (((symbol-function 'tandem-mention-diagnostics)
               (lambda (_buffer) '((5 "error" "undefined name 'r'") (9 "warning" "far away")))))
      (goto-char (point-min))
      (search-forward "return math")
      (tandem-do "Fix"))
    (should (string-match-p "Emacs reports here:\nline 5: error: undefined name 'r'\n" (car sent)))
    ;; Only what is reported in this code.
    (should-not (string-match-p "far away" (car sent)))))

(ert-deftest tandem-do-keeps-your-draft-and-refuses-when-busy ()
  (tandem-test-with-do
    (with-current-buffer chat
      (goto-char (point-max))
      (insert "half a thought"))
    (goto-char (point-min))
    (tandem-do "Simplify")
    (with-current-buffer chat
      (should (equal (tandem-chat--input-text) "half a thought")))
    ;; The chat is busy now: no second instruction, no second line.
    (should-error (tandem-do "Simplify") :type 'user-error)
    (should (= (length sent) 1))
    (should (= 1 (seq-count (lambda (o) (overlay-get o 'tandem-do))
                            (overlays-in (point-min) (point-max)))))))

(ert-deftest tandem-do-reads-a-choice ()
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Tests")))
    (should (equal (tandem-do--read "line 3") "Tests")))
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "  ")))
    (should-error (tandem-do--read "line 3") :type 'user-error))
  (should (equal (tandem-do--instruction "make it faster") "make it faster"))
  (should (string-prefix-p "Write tests" (tandem-do--instruction "Tests"))))

;;;; For real

(ert-deftest tandem-do-for-real ()
  ;; The fake claude reads a script from the first line of the prompt:
  ;; here an edit of area(), which comes back as a hunk in geo.py.
  (tandem-test-with-project
    (with-temp-file (expand-file-name "geo.py" project) (insert tandem-test--py))
    (let ((file-buffer (find-file-noselect (expand-file-name "geo.py" project)))
          (tandem-chat-text-functions (list (lambda (text) (car (split-string text "\n"))))))
      (unwind-protect
          (progn
            (setq buffer (with-current-buffer file-buffer (tandem)))
            (with-current-buffer file-buffer
              (goto-char (point-min))
              (search-forward "return math")
              (tandem-do (tandem-test--edit-prompt
                          '(:file "geo.py" :old "math.pi * r * r" :new "math.pi * r ** 2")))
              (should (tandem-test--working-here)))
            (let ((id (tandem-test--wait-proposal)))
              (should (equal (tandem-review-hunk-count id) '(1 . 1)))
              (tandem-review-apply id))
            (tandem-test--wait-idle buffer)
            (with-current-buffer file-buffer
              (should (string-match-p "math\\.pi \\* r \\*\\* 2" (buffer-string)))
              (should-not (tandem-test--working-here))))
        (with-current-buffer file-buffer (set-buffer-modified-p nil))
        (kill-buffer file-buffer)))))

(provide 'tandem-do-tests)
;;; tandem-do-tests.el ends here
