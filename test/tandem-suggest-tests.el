;;; tandem-suggest-tests.el --- Tests for suggestions as you type  -*- lexical-binding: t; -*-

;;; Commentary:

;; The grey suggestion: when it is asked for, what is sent, showing it as
;; it arrives, TAB, typing through it, and a real one from the fake claude.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defvar company-candidates)

(defmacro tandem-test-with-suggest (&rest body)
  "Run BODY in a Python buffer with `tandem-suggest-mode' on.
ASKED collects (PARAMS ON-RESULT ON-ERROR) of each request, newest first."
  (declare (indent 0) (debug t))
  `(let ((asked nil)
         (tandem-suggest--pending nil)
         (tandem-suggest--last-error nil)
         (tandem-claude-command "/bin/true"))
     (cl-letf (((symbol-function 'tandem-rpc-async-request)
                (lambda (method params on-result &optional on-error _timeout)
                  (should (eq method 'suggest/complete))
                  (push (list params on-result on-error) asked))))
       (with-temp-buffer
         (python-mode)
         (insert "def area(r):\n    ")
         (tandem-suggest-mode 1)
         ;; `with-temp-buffer' does not show the buffer; suggestions only
         ;; show in the selected window's buffer.
         (set-window-buffer (selected-window) (current-buffer))
         (unwind-protect (progn ,@body)
           (tandem-suggest-mode -1))))))

(defun tandem-test--command (command &optional insert)
  "Run the post-command work as if COMMAND had just run, after INSERT."
  (let ((this-command command))
    (when insert (insert insert))
    (tandem-suggest--post-command)))

(defun tandem-test--ghost ()
  "Return the suggestion shown, or nil."
  (tandem-suggest--text))

(ert-deftest tandem-suggest-asks-after-typing-only ()
  (tandem-test-with-suggest
    (tandem-test--command 'self-insert-command "r")
    (should tandem-suggest--wanted)
    (tandem-suggest--on-idle)
    (should (= (length asked) 1))
    (let ((params (car (car asked))))
      (should (equal (plist-get params :prefix) "def area(r):\n    r"))
      (should (equal (plist-get params :suffix) ""))
      (should (equal (plist-get params :model) "claude-haiku-5-5"))
      (should (equal (plist-get params :language) "python"))
      (should (equal (plist-get params :token) tandem-suggest--token)))
    ;; One pause, one request.
    (tandem-suggest--on-idle)
    (should (= (length asked) 1))
    ;; Moving around is not typing.
    (tandem-test--command 'backward-char)
    (backward-char)
    (should-not tandem-suggest--wanted)
    ;; Nor is undo.
    (let ((tandem-suggest--tick 0)) (tandem-test--command 'undo))
    (should-not tandem-suggest--wanted)))

(ert-deftest tandem-suggest-shows-as-it-arrives-and-tab-inserts ()
  (tandem-test-with-suggest
    (tandem-test--command 'self-insert-command "r")
    (tandem-suggest--on-idle)
    (let ((token tandem-suggest--token))
      (tandem-suggest--on-notification 'suggest/text (list :token token :text "eturn math"))
      (should (equal (tandem-test--ghost) "eturn math"))
      ;; The cursor stays before it.
      (should (get-text-property 0 'cursor (overlay-get tandem-suggest--overlay 'after-string)))
      (should (eq (key-binding (kbd "TAB")) #'tandem-suggest-accept))
      (funcall (nth 1 (car asked)) (list :token token :text "eturn math.pi * r * r"))
      (should (equal (tandem-test--ghost) "eturn math.pi * r * r"))
      (should-not tandem-suggest--pending))
    (let ((this-command 'tandem-suggest-accept))
      (tandem-suggest-accept)
      (tandem-suggest--post-command))
    (should (equal (buffer-string) "def area(r):\n    return math.pi * r * r"))
    (should-not (tandem-test--ghost))
    (should-not (eq (key-binding (kbd "TAB")) #'tandem-suggest-accept))))

(ert-deftest tandem-suggest-typing-through-keeps-the-rest ()
  (tandem-test-with-suggest
    (tandem-suggest--show "return 1")
    (tandem-test--command 'self-insert-command "r")
    (should (equal (tandem-test--ghost) "eturn 1"))
    ;; Another character, or any other command, takes it away.
    (tandem-test--command 'self-insert-command "x")
    (should-not (tandem-test--ghost))
    (tandem-suggest--show "abc")
    (tandem-test--command 'forward-word)
    (should-not (tandem-test--ghost))))

(ert-deftest tandem-suggest-drops-an-answer-that-came-too-late ()
  (tandem-test-with-suggest
    (tandem-test--command 'self-insert-command "r")
    (tandem-suggest--on-idle)
    (let ((token tandem-suggest--token))
      ;; You typed on meanwhile.
      (tandem-test--command 'self-insert-command "e")
      (funcall (nth 1 (car asked)) (list :token token :text "turn 1"))
      (should-not (tandem-test--ghost))
      ;; An older request's text is ignored too.
      (tandem-suggest--on-notification 'suggest/text (list :token (1- token) :text "zzz"))
      (should-not (tandem-test--ghost)))))

(ert-deftest tandem-suggest-not-when-it-makes-no-sense ()
  (tandem-test-with-suggest
    ;; In the middle of a word.
    (insert "ab")
    (backward-char)
    (setq tandem-suggest--wanted t)
    (tandem-suggest--on-idle)
    (should-not asked)
    (goto-char (point-max))
    ;; With a region.
    (let ((transient-mark-mode t))
      (set-mark (point-min))
      (activate-mark)
      (tandem-suggest--on-idle)
      (should-not asked)
      (deactivate-mark))
    ;; While Company's popup is open.
    (let ((company-candidates '("x")))
      (tandem-suggest--on-idle)
      (should-not asked))
    (tandem-suggest--on-idle)
    (should asked)))

(ert-deftest tandem-suggest-errors-are-said-once ()
  (tandem-test-with-suggest
    (let ((said nil))
      (cl-letf (((symbol-function 'message) (lambda (&rest args) (push (apply #'format args) said))))
        ;; The same error at every pause is said once.
        (dotimes (_ 2)
          (setq tandem-suggest--wanted t)
          (tandem-suggest--on-idle)
          (funcall (nth 2 (car asked)) "claude: rate limited"))
        (should (equal said '("tandem: no suggestion: claude: rate limited")))
        ;; Asking yourself says it again.
        (setq said nil)
        (tandem-suggest-now)
        (funcall (nth 2 (car asked)) "claude: rate limited")
        (should (member "tandem: no suggestion: claude: rate limited" said))
        ;; A request a newer one replaced says nothing.
        (setq said nil tandem-suggest--last-error nil tandem-suggest--wanted t)
        (tandem-suggest--on-idle)
        (funcall (nth 2 (car asked)) "a newer suggestion request replaced this one")
        (should-not said)))))

(ert-deftest tandem-suggest-global-mode-is-for-code-files ()
  (with-temp-buffer
    (python-mode)
    (tandem-suggest--turn-on)
    (should-not tandem-suggest-mode)
    (setq buffer-file-name "/tmp/x.py")
    (tandem-suggest--turn-on)
    (should tandem-suggest-mode)
    (tandem-suggest-mode -1)
    (setq buffer-file-name nil))
  (with-temp-buffer
    (text-mode)
    (setq buffer-file-name "/tmp/x.txt")
    (tandem-suggest--turn-on)
    (should-not tandem-suggest-mode)
    (setq buffer-file-name nil)))

;;;; For real

(ert-deftest tandem-suggest-for-real ()
  (tandem-test-with-project
    (let ((file (expand-file-name "calc.py" project)))
      (with-temp-file file (insert "x = fake-suggest:42"))
      (with-current-buffer (find-file-noselect file)
        (unwind-protect
            (progn
              (set-window-buffer (selected-window) (current-buffer))
              (goto-char (point-max))
              (tandem-suggest-mode 1)
              (tandem-suggest-now)
              (should (tandem-test--wait-for
                       (lambda () (and (null tandem-suggest--pending) (tandem-test--ghost))) 10))
              (should (equal (tandem-test--ghost) "42"))
              (tandem-suggest-accept)
              (should (equal (buffer-string) "x = fake-suggest:4242")))
          (tandem-suggest-mode -1)
          (set-buffer-modified-p nil)
          (kill-buffer))))))

(provide 'tandem-suggest-tests)
;;; tandem-suggest-tests.el ends here
