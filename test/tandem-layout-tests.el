;;; tandem-layout-tests.el --- Tests for the windows Claude works with  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group calls the layout tools directly in a frame holding your
;; window and a chat side window.  The second runs them for real: the fake
;; claude calls open_file through the daemon's MCP helper.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defvar tandem-test--dir nil "The project directory of the layout test running.")

(defun tandem-test--reset-frame ()
  "Leave the selected frame with one ordinary window on *scratch*."
  (dolist (window (window-list nil 'nomini))
    (when (and (window-live-p window) (window-parameter window 'window-side))
      (delete-window window)))
  (delete-other-windows)
  (switch-to-buffer "*scratch*")
  (dolist (parameter '(tandem-owner tandem-id tandem-used-by-you tandem-used-by-claude))
    (set-window-parameter nil parameter nil)))

(defmacro tandem-test-with-layout (&rest body)
  "Run BODY in a frame with your window and the chat of session \"s1\".
DIR is a project with files f1.txt to f6.txt; CHAT is the chat buffer
and MINE your window."
  (declare (indent 0) (debug t))
  `(let* ((dir (tandem-test--private-dir))
          (tandem-chat--buffers (make-hash-table :test #'equal))
          (tandem-layout-tab nil)
          (chat (generate-new-buffer " *tandem layout test chat*")))
     (unwind-protect
         (progn
           (tandem-test--reset-frame)
           (dotimes (i 6)
             (with-temp-file (expand-file-name (format "f%d.txt" (1+ i)) dir)
               (dotimes (n 60) (insert (format "file %d line %d\n" (1+ i) (1+ n))))))
           (with-current-buffer chat (tandem-chat-mode))
           (puthash "s1" chat tandem-chat--buffers)
           (display-buffer chat '((display-buffer-in-side-window)
                                  (side . right) (window-width . 0.38)
                                  (window-parameters . ((no-delete-other-windows . t)))))
           (let ((mine (selected-window))
                 (tandem-test--dir dir))
             (ignore mine)
             ,@body))
       (tandem-test--reset-frame)
       (kill-buffer chat)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (kill-buffer b)))
       (delete-directory dir t))))

(defun tandem-test--tool (tool &rest args)
  "Run Claude's TOOL with ARGS in session s1 of project DIR; return its text.
Signal a test failure when the tool reports an error, unless ARGS has
:error t, in which case the text must be an error."
  (let* ((want-error (plist-get args :error))
         (args (cl-loop for (k v) on args by #'cddr unless (eq k :error) append (list k v)))
         (result (tandem-layout--run tool args "s1" tandem-test--dir)))
    (unless (eq (and (cdr result) t) (and want-error t))
      (ert-fail (list "unexpected tool outcome" tool args result)))
    (car result)))

(defun tandem-test--file (n)
  "Return the path of fN.txt in DIR."
  (expand-file-name (format "f%d.txt" n) tandem-test--dir))

(defun tandem-test--count ()
  "Return how many windows the selected frame has."
  (length (window-list nil 'nomini)))

(defun tandem-test--window-of (n)
  "Return the window showing fN.txt."
  (get-buffer-window (find-buffer-visiting (tandem-test--file n))))

(ert-deftest tandem-layout-opens-at-most-five-windows ()
  (tandem-test-with-layout
    (let ((before (window-buffer mine))
          (point (window-point mine)))
      (should (= (tandem-test--count) 2))
      (should (string-match-p "a new window Claude opened, now at line 3\\. Windows: 3 of at most 5\\."
                              (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 3)))
      (tandem-test--tool "open_file" :path (tandem-test--file 2))
      (tandem-test--tool "open_file" :path (tandem-test--file 3))
      (should (= (tandem-test--count) 5))
      ;; At the limit: reuse the window Claude used least recently.
      (let ((first (tandem-test--window-of 1)))
        (should (string-match-p "which showed f1.txt before"
                                (tandem-test--tool "open_file" :path (tandem-test--file 4))))
        (should (eq (tandem-test--window-of 4) first)))
      (should (string-match-p "which showed f2.txt before"
                              (tandem-test--tool "open_file" :path (tandem-test--file 5))))
      (tandem-test--tool "open_file" :path (tandem-test--file 6))
      (should (= (tandem-test--count) 5))
      ;; Your window: still selected, same buffer, same point.
      (should (eq (selected-window) mine))
      (should (eq (window-buffer mine) before))
      (should (= (window-point mine) point))
      (dolist (n '(4 5 6))
        (should (window-parameter (tandem-test--window-of n) 'tandem-owner))))))

(ert-deftest tandem-layout-moves-to-the-line ()
  (tandem-test-with-layout
    (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 40)
    (let ((window (tandem-test--window-of 1)))
      (with-current-buffer (window-buffer window)
        (should (= (line-number-at-pos (window-point window)) 40))
        (should (<= (window-start window) (window-point window))))
      ;; A file already shown is not opened twice.
      (should (string-match-p "f1.txt is shown in window [0-9]+, now at line 10\\. Windows: 3"
                              (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 10)))
      (with-current-buffer (window-buffer window)
        (should (= (line-number-at-pos (window-point window)) 10))))))

(ert-deftest tandem-layout-never-moves-your-window ()
  (tandem-test-with-layout
    (find-file (tandem-test--file 1))
    (goto-char (point-min))
    (forward-line 4)
    (let ((point (point)))
      (should (string-match-p "the user is working in that window, so it was not moved to line 50"
                              (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 50)))
      (should (= (window-point mine) point))
      (should (= (tandem-test--count) 2)))))

(ert-deftest tandem-layout-leaves-a-window-you-just-used ()
  (tandem-test-with-layout
    (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 2)
    (let ((window (tandem-test--window-of 1)))
      (set-window-parameter window 'tandem-used-by-you (float-time))
      (should (string-match-p "not moved to line 30"
                              (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 30)))
      (with-current-buffer (window-buffer window)
        (should (= (line-number-at-pos (window-point window)) 2)))
      ;; Not reused at the limit either.
      (tandem-test--tool "open_file" :path (tandem-test--file 2))
      (tandem-test--tool "open_file" :path (tandem-test--file 3))
      (tandem-test--tool "open_file" :path (tandem-test--file 4))
      (should (eq (window-buffer window) (find-buffer-visiting (tandem-test--file 1))))
      ;; Once the guard time is over, it is Claude's to move again.
      (set-window-parameter window 'tandem-used-by-you (- (float-time) 10))
      (should (string-match-p "now at line 30"
                              (tandem-test--tool "open_file" :path (tandem-test--file 1) :line 30))))))

(ert-deftest tandem-layout-your-own-windows-count-toward-the-limit ()
  (tandem-test-with-layout
    (split-window mine nil 'below)
    (split-window mine nil 'below)
    (let ((yours (split-window mine nil 'right)))
      (set-window-buffer yours (get-buffer-create "*yours*"))
      (should (= (tandem-test--count) 5))
      (should (string-match-p "Windows: 5 of at most 5"
                              (tandem-test--tool "open_file" :path (tandem-test--file 1))))
      (should (= (tandem-test--count) 5))
      (should (eq (selected-window) mine))
      ;; Reusing one of your windows does not make it Claude's.
      (should-not (window-parameter (tandem-test--window-of 1) 'tandem-owner))
      (kill-buffer "*yours*"))))

(ert-deftest tandem-layout-close-window-rules ()
  (tandem-test-with-layout
    (tandem-test--tool "list_windows")
    (let* ((chat-id (window-parameter (get-buffer-window chat) 'tandem-id))
           (mine-id (window-parameter mine 'tandem-id)))
      (tandem-test--tool "open_file" :path (tandem-test--file 1))
      (let ((claudes (window-parameter (tandem-test--window-of 1) 'tandem-id)))
        (should (string-match-p "is the user's, so it stays open"
                                (tandem-test--tool "close_window" :window mine-id :error t)))
        (should (string-match-p "is the chat, so it stays open"
                                (tandem-test--tool "close_window" :window chat-id :error t)))
        (should (string-match-p "There is no window 999"
                                (tandem-test--tool "close_window" :window 999 :error t)))
        (let ((tandem-min-windows 3))
          (should (string-match-p "keeps at least 3 windows open"
                                  (tandem-test--tool "close_window" :window claudes :error t))))
        (set-window-parameter (tandem-test--window-of 1) 'tandem-used-by-you (float-time))
        (should (string-match-p "The user is working in window"
                                (tandem-test--tool "close_window" :window claudes :error t)))
        (set-window-parameter (tandem-test--window-of 1) 'tandem-used-by-you nil)
        (should (string-match-p "Closed window [0-9]+\\. Windows: 2 of at most 5"
                                (tandem-test--tool "close_window" :window claudes)))
        (should (= (tandem-test--count) 2))))))

(ert-deftest tandem-layout-list-windows ()
  (tandem-test-with-layout
    (tandem-test--tool "open_file" :path (tandem-test--file 2) :line 5)
    (let ((text (tandem-test--tool "list_windows")))
      (should (string-match-p "has 3 windows (at most 5, at least 2 stay open)" text))
      (should (string-match-p "\\[[0-9]+\\] user's: \\*scratch\\* (the user is working here)" text))
      (should (string-match-p "\\[[0-9]+\\] Claude's: f2.txt, lines [0-9]+-[0-9]+$" text))
      (should (string-match-p "\\[[0-9]+\\] chat: " text))
      ;; The line range fits the window.
      (let* ((window (tandem-test--window-of 2)))
        (string-match "Claude's: f2.txt, lines \\([0-9]+\\)-\\([0-9]+\\)" text)
        (should (< (- (string-to-number (match-string 2 text)) (string-to-number (match-string 1 text)))
                   (window-body-height window)))))))

(ert-deftest tandem-layout-nothing-is-shown-while-you-look-elsewhere ()
  (tandem-test-with-layout
    (delete-window (get-buffer-window chat))
    (should (string-match-p "not shown: the user is not looking at the frame or tab with the chat"
                            (tandem-test--tool "open_file" :path (tandem-test--file 1))))
    (should (find-buffer-visiting (tandem-test--file 1)))
    (should (= (tandem-test--count) 1))
    (should (string-match-p "No windows to list" (tandem-test--tool "list_windows")))
    (should (string-match-p "No window was closed" (tandem-test--tool "close_window" :window 1 :error t)))))

(ert-deftest tandem-layout-open-file-checks-the-file ()
  (tandem-test-with-layout
    (should (string-match-p "There is no file nope.txt"
                            (tandem-test--tool "open_file" :path (expand-file-name "nope.txt" dir) :error t)))
    (should (string-match-p "is a directory"
                            (tandem-test--tool "open_file" :path dir :error t)))
    (let ((large-file-warning-threshold 100))
      (should (string-match-p "f1.txt is too large to show"
                              (tandem-test--tool "open_file" :path (tandem-test--file 1) :error t))))
    (should (string-match-p "open_file needs a path" (tandem-test--tool "open_file" :error t)))
    (should (string-match-p "Emacs has no tool" (tandem-test--tool "split_frame" :error t)))))

(ert-deftest tandem-layout-files-open-without-unsafe-local-variables ()
  (tandem-test-with-layout
    (let ((evil (expand-file-name "evil.txt" dir)))
      (with-temp-file evil
        (insert "x\n;; Local Variables:\n;; eval: (setq tandem-test--pwned t)\n;; End:\n"))
      (defvar tandem-test--pwned nil)
      (tandem-test--tool "open_file" :path evil)
      (should-not tandem-test--pwned))))

(ert-deftest tandem-layout-c-x-1-keeps-the-chat ()
  (tandem-test-with-layout
    (tandem-test--tool "open_file" :path (tandem-test--file 1))
    (delete-other-windows)
    (should (get-buffer-window chat))
    (should (= (tandem-test--count) 2))))

(ert-deftest tandem-layout-marks-survive-a-tab-switch ()
  (tandem-test-with-layout
    (tandem-layout-enable)
    (tandem-test--tool "open_file" :path (tandem-test--file 1))
    (let ((id (window-parameter (tandem-test--window-of 1) 'tandem-id)))
      (unwind-protect
          (progn
            (tab-bar-new-tab)
            (tab-bar-switch-to-prev-tab)
            (let ((window (tandem-test--window-of 1)))
              (should window)
              (should (window-parameter window 'tandem-owner))
              (should (eql (window-parameter window 'tandem-id) id))))
        (tab-bar-close-other-tabs)
        (tab-bar-mode -1)))))

(ert-deftest tandem-layout-the-chat-gets-a-tab-of-its-own ()
  (let ((tandem-layout-tab "Claude test")
        (buffer (get-buffer-create " *tandem tab test*")))
    (unwind-protect
        (progn
          (tandem-test--reset-frame)
          (tandem-layout-enter-tab buffer)
          (should (equal (alist-get 'name (tab-bar--current-tab)) "Claude test"))
          ;; Already there, or the buffer is visible: no switch.
          (tandem-layout-enter-tab buffer)
          (should (= (length (funcall tab-bar-tabs-function)) 2))
          (tab-bar-switch-to-prev-tab)
          (switch-to-buffer buffer)
          (tandem-layout-enter-tab buffer)
          (should-not (equal (alist-get 'name (tab-bar--current-tab)) "Claude test")))
      (tab-bar-close-other-tabs)
      (tab-bar-mode -1)
      (tandem-test--reset-frame)
      (kill-buffer buffer))))

(ert-deftest tandem-layout-a-proposal-respects-the-limit ()
  (tandem-test-with-layout
    (dolist (n '(1 2 3))
      (tandem-test--tool "open_file" :path (tandem-test--file n)))
    (cl-letf (((symbol-function 'tandem-rpc-request) (lambda (&rest _) '(:ok t))))
      (tandem-review--propose
       (list :requestId "e1" :sessionId "s1" :kind "edit" :filePath (tandem-test--file 5)
             :oldString "file 5 line 30\n" :newString "FIVE\n"))
      (unwind-protect
          (progn
            (should (= (tandem-test--count) 5))
            (should (eq (selected-window) mine))
            (should (tandem-test--window-of 5))
            (should-not (tandem-test--window-of 1)))
        (tandem-review-reject "e1" "")))))

(ert-deftest tandem-layout-your-tab-is-never-touched-by-a-proposal ()
  (tandem-test-with-layout
    (let ((tandem-layout-tab "Claude test"))
      (unwind-protect
          (progn
            ;; The chat lives in Claude's tab; you are back in your own.
            (tab-bar-switch-to-tab "Claude test")
            (tab-bar-switch-to-prev-tab)
            (delete-window (get-buffer-window chat))
            (should (= (tandem-test--count) 1))
            (should (tandem-layout-elsewhere-p))
            (let (shown)
              (cl-letf (((symbol-function 'tandem-rpc-request) (lambda (&rest _) '(:ok t)))
                        ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) shown))))
                (tandem-review--propose
                 (list :requestId "e1" :sessionId "s1" :kind "edit" :filePath (tandem-test--file 1)
                       :oldString "file 1 line 3\n" :newString "THREE\n")))
              (unwind-protect
                  (progn
                    (should (= (tandem-test--count) 1))
                    (should (eq (window-buffer mine) (get-buffer "*scratch*")))
                    (should (tandem-review-pending-p "e1"))
                    (should (seq-some (lambda (m) (string-match-p "in the Claude test tab: C-x t o" m)) shown)))
                (cl-letf (((symbol-function 'tandem-rpc-request) (lambda (&rest _) '(:ok t))))
                  (tandem-review-reject "e1" "")))))
        (tab-bar-close-other-tabs)
        (tab-bar-mode -1)))))

(ert-deftest tandem-layout-without-claude-tab-a-proposal-comes-to-you ()
  (tandem-test-with-layout
    (delete-window (get-buffer-window chat))
    (should-not (tandem-layout-elsewhere-p))
    (cl-letf (((symbol-function 'tandem-rpc-request) (lambda (&rest _) '(:ok t))))
      (tandem-review--propose
       (list :requestId "e1" :sessionId "s1" :kind "edit" :filePath (tandem-test--file 1)
             :oldString "file 1 line 3\n" :newString "THREE\n"))
      (unwind-protect
          (progn
            (should (tandem-test--window-of 1))
            (should (eq (selected-window) mine)))
        (tandem-review-reject "e1" "")))))

;;;; For real, through the daemon

(ert-deftest tandem-layout-open-file-for-real ()
  (tandem-test-with-project
    (let ((tandem-layout-tab nil))
      (tandem-test--reset-frame)
      (with-temp-file (expand-file-name "f1.txt" project)
        (dotimes (n 30) (insert (format "line %d\n" (1+ n)))))
      (unwind-protect
          (progn
            ;; *scratch* is current after the reset; start in the project.
            (let ((default-directory (file-name-as-directory project)))
              (setq buffer (tandem)))
            (select-window (get-mru-window nil nil t))
            (tandem-test--say buffer "script:mcp:open_file:{\"path\":\"f1.txt\",\"line\":12} && list_windows:")
            (let* ((file-buffer (find-buffer-visiting (expand-file-name "f1.txt" project)))
                   (window (and file-buffer (get-buffer-window file-buffer))))
              (unless window
                (ert-fail (list "f1.txt is not shown" (with-current-buffer buffer (tandem-test--transcript)))))
              (should (window-parameter window 'tandem-owner))
              (with-current-buffer (window-buffer window)
                (should (= (line-number-at-pos (window-point window)) 12))))
            (with-current-buffer buffer
              (let ((text (tandem-test--transcript)))
                (should (string-match-p "Show f1.txt:12" text))
                (should (string-match-p "open_file result: Showing f1.txt in window [0-9]+, a new window Claude opened, now at line 12\\. Windows: 3 of at most 5\\." text))
                (should (string-match-p "\\] Claude's: f1.txt, lines" text))
                (should-not (string-match-p "Allow\\|wants to" text)))))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p project (buffer-file-name b)))
            (kill-buffer b)))
        (tandem-test--reset-frame)))))

(ert-deftest tandem-layout-outside-the-project-for-real ()
  (tandem-test-with-project
    (let ((tandem-layout-tab nil))
      (unwind-protect
          (progn
            ;; *scratch* is current after the reset; start in the project.
            (let ((default-directory (file-name-as-directory project)))
              (setq buffer (tandem)))
            (tandem-test--say buffer "script:mcp:open_file:{\"path\":\"/etc/hostname\"}")
            (should-not (find-buffer-visiting "/etc/hostname"))
            (with-current-buffer buffer
              (should (string-match-p "only shows files inside the project"
                                      (tandem-test--transcript)))))
        (tandem-test--reset-frame)))))

(provide 'tandem-layout-tests)
;;; tandem-layout-tests.el ends here
