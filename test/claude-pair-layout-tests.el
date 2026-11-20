;;; claude-pair-layout-tests.el --- Tests for the windows Claude works with  -*- lexical-binding: t; -*-

;;; Commentary:

;; The first group calls the layout tools directly in a frame holding your
;; window and a chat side window.  The second runs them for real: the fake
;; claude calls open_file through the daemon's MCP helper.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defvar claude-pair-test--dir nil "The project directory of the layout test running.")

(defun claude-pair-test--reset-frame ()
  "Leave the selected frame with one ordinary window on *scratch*."
  (dolist (window (window-list nil 'nomini))
    (when (and (window-live-p window) (window-parameter window 'window-side))
      (delete-window window)))
  (delete-other-windows)
  (switch-to-buffer "*scratch*")
  (dolist (parameter '(claude-pair-owner claude-pair-id claude-pair-used-by-you claude-pair-used-by-claude))
    (set-window-parameter nil parameter nil)))

(defmacro claude-pair-test-with-layout (&rest body)
  "Run BODY in a frame with your window and the chat of session \"s1\".
DIR is a project with files f1.txt to f6.txt; CHAT is the chat buffer
and MINE your window."
  (declare (indent 0) (debug t))
  `(let* ((dir (claude-pair-test--private-dir))
          (claude-pair-chat--buffers (make-hash-table :test #'equal))
          (claude-pair-layout-tab nil)
          (chat (generate-new-buffer " *claude-pair layout test chat*")))
     (unwind-protect
         (progn
           (claude-pair-test--reset-frame)
           (dotimes (i 6)
             (with-temp-file (expand-file-name (format "f%d.txt" (1+ i)) dir)
               (dotimes (n 60) (insert (format "file %d line %d\n" (1+ i) (1+ n))))))
           (with-current-buffer chat (claude-pair-chat-mode))
           (puthash "s1" chat claude-pair-chat--buffers)
           (display-buffer chat '((display-buffer-in-side-window)
                                  (side . right) (window-width . 0.38)
                                  (window-parameters . ((no-delete-other-windows . t)))))
           (let ((mine (selected-window))
                 (claude-pair-test--dir dir))
             (ignore mine)
             ,@body))
       (claude-pair-test--reset-frame)
       (kill-buffer chat)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (kill-buffer b)))
       (delete-directory dir t))))

(defun claude-pair-test--tool (tool &rest args)
  "Run Claude's TOOL with ARGS in session s1 of project DIR; return its text.
Signal a test failure when the tool reports an error, unless ARGS has
:error t, in which case the text must be an error."
  (let* ((want-error (plist-get args :error))
         (args (cl-loop for (k v) on args by #'cddr unless (eq k :error) append (list k v)))
         (result (claude-pair-layout--run tool args "s1" claude-pair-test--dir)))
    (unless (eq (and (cdr result) t) (and want-error t))
      (ert-fail (list "unexpected tool outcome" tool args result)))
    (car result)))

(defun claude-pair-test--file (n)
  "Return the path of fN.txt in DIR."
  (expand-file-name (format "f%d.txt" n) claude-pair-test--dir))

(defun claude-pair-test--count ()
  "Return how many windows the selected frame has."
  (length (window-list nil 'nomini)))

(defun claude-pair-test--window-of (n)
  "Return the window showing fN.txt."
  (get-buffer-window (find-buffer-visiting (claude-pair-test--file n))))

(ert-deftest claude-pair-layout-opens-at-most-five-windows ()
  (claude-pair-test-with-layout
    (let ((before (window-buffer mine))
          (point (window-point mine)))
      (should (= (claude-pair-test--count) 2))
      (should (string-match-p "a new window Claude opened, now at line 3\\. Windows: 3 of at most 5\\."
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 3)))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 2))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 3))
      (should (= (claude-pair-test--count) 5))
      ;; At the limit: reuse the window Claude used least recently.
      (let ((first (claude-pair-test--window-of 1)))
        (should (string-match-p "which showed f1.txt before"
                                (claude-pair-test--tool "open_file" :path (claude-pair-test--file 4))))
        (should (eq (claude-pair-test--window-of 4) first)))
      (should (string-match-p "which showed f2.txt before"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 5))))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 6))
      (should (= (claude-pair-test--count) 5))
      ;; Your window: still selected, same buffer, same point.
      (should (eq (selected-window) mine))
      (should (eq (window-buffer mine) before))
      (should (= (window-point mine) point))
      (dolist (n '(4 5 6))
        (should (window-parameter (claude-pair-test--window-of n) 'claude-pair-owner))))))

(ert-deftest claude-pair-layout-moves-to-the-line ()
  (claude-pair-test-with-layout
    (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 40)
    (let ((window (claude-pair-test--window-of 1)))
      (with-current-buffer (window-buffer window)
        (should (= (line-number-at-pos (window-point window)) 40))
        (should (<= (window-start window) (window-point window))))
      ;; A file already shown is not opened twice.
      (should (string-match-p "f1.txt is shown in window [0-9]+, now at line 10\\. Windows: 3"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 10)))
      (with-current-buffer (window-buffer window)
        (should (= (line-number-at-pos (window-point window)) 10))))))

(ert-deftest claude-pair-layout-never-moves-your-window ()
  (claude-pair-test-with-layout
    (find-file (claude-pair-test--file 1))
    (goto-char (point-min))
    (forward-line 4)
    (let ((point (point)))
      (should (string-match-p "the user is working in that window, so it was not moved to line 50"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 50)))
      (should (= (window-point mine) point))
      (should (= (claude-pair-test--count) 2)))))

(ert-deftest claude-pair-layout-leaves-a-window-you-just-used ()
  (claude-pair-test-with-layout
    (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 2)
    (let ((window (claude-pair-test--window-of 1)))
      (set-window-parameter window 'claude-pair-used-by-you (float-time))
      (should (string-match-p "not moved to line 30"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 30)))
      (with-current-buffer (window-buffer window)
        (should (= (line-number-at-pos (window-point window)) 2)))
      ;; Not reused at the limit either.
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 2))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 3))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 4))
      (should (eq (window-buffer window) (find-buffer-visiting (claude-pair-test--file 1))))
      ;; Once the guard time is over, it is Claude's to move again.
      (set-window-parameter window 'claude-pair-used-by-you (- (float-time) 10))
      (should (string-match-p "now at line 30"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :line 30))))))

(ert-deftest claude-pair-layout-your-own-windows-count-toward-the-limit ()
  (claude-pair-test-with-layout
    (split-window mine nil 'below)
    (split-window mine nil 'below)
    (let ((yours (split-window mine nil 'right)))
      (set-window-buffer yours (get-buffer-create "*yours*"))
      (should (= (claude-pair-test--count) 5))
      (should (string-match-p "Windows: 5 of at most 5"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1))))
      (should (= (claude-pair-test--count) 5))
      (should (eq (selected-window) mine))
      ;; Reusing one of your windows does not make it Claude's.
      (should-not (window-parameter (claude-pair-test--window-of 1) 'claude-pair-owner))
      (kill-buffer "*yours*"))))

(ert-deftest claude-pair-layout-close-window-rules ()
  (claude-pair-test-with-layout
    (claude-pair-test--tool "list_windows")
    (let* ((chat-id (window-parameter (get-buffer-window chat) 'claude-pair-id))
           (mine-id (window-parameter mine 'claude-pair-id)))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1))
      (let ((claudes (window-parameter (claude-pair-test--window-of 1) 'claude-pair-id)))
        (should (string-match-p "is the user's, so it stays open"
                                (claude-pair-test--tool "close_window" :window mine-id :error t)))
        (should (string-match-p "is the chat, so it stays open"
                                (claude-pair-test--tool "close_window" :window chat-id :error t)))
        (should (string-match-p "There is no window 999"
                                (claude-pair-test--tool "close_window" :window 999 :error t)))
        (let ((claude-pair-min-windows 3))
          (should (string-match-p "keeps at least 3 windows open"
                                  (claude-pair-test--tool "close_window" :window claudes :error t))))
        (set-window-parameter (claude-pair-test--window-of 1) 'claude-pair-used-by-you (float-time))
        (should (string-match-p "The user is working in window"
                                (claude-pair-test--tool "close_window" :window claudes :error t)))
        (set-window-parameter (claude-pair-test--window-of 1) 'claude-pair-used-by-you nil)
        (should (string-match-p "Closed window [0-9]+\\. Windows: 2 of at most 5"
                                (claude-pair-test--tool "close_window" :window claudes)))
        (should (= (claude-pair-test--count) 2))))))

(ert-deftest claude-pair-layout-list-windows ()
  (claude-pair-test-with-layout
    (claude-pair-test--tool "open_file" :path (claude-pair-test--file 2) :line 5)
    (let ((text (claude-pair-test--tool "list_windows")))
      (should (string-match-p "has 3 windows (at most 5, at least 2 stay open)" text))
      (should (string-match-p "\\[[0-9]+\\] user's: \\*scratch\\* (the user is working here)" text))
      (should (string-match-p "\\[[0-9]+\\] Claude's: f2.txt, lines [0-9]+-[0-9]+$" text))
      (should (string-match-p "\\[[0-9]+\\] chat: " text))
      ;; The line range fits the window.
      (let* ((window (claude-pair-test--window-of 2)))
        (string-match "Claude's: f2.txt, lines \\([0-9]+\\)-\\([0-9]+\\)" text)
        (should (< (- (string-to-number (match-string 2 text)) (string-to-number (match-string 1 text)))
                   (window-body-height window)))))))

(ert-deftest claude-pair-layout-nothing-is-shown-while-you-look-elsewhere ()
  (claude-pair-test-with-layout
    (delete-window (get-buffer-window chat))
    (should (string-match-p "not shown: the user is not looking at the frame or tab with the chat"
                            (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1))))
    (should (find-buffer-visiting (claude-pair-test--file 1)))
    (should (= (claude-pair-test--count) 1))
    (should (string-match-p "No windows to list" (claude-pair-test--tool "list_windows")))
    (should (string-match-p "No window was closed" (claude-pair-test--tool "close_window" :window 1 :error t)))))

(ert-deftest claude-pair-layout-open-file-checks-the-file ()
  (claude-pair-test-with-layout
    (should (string-match-p "There is no file nope.txt"
                            (claude-pair-test--tool "open_file" :path (expand-file-name "nope.txt" dir) :error t)))
    (should (string-match-p "is a directory"
                            (claude-pair-test--tool "open_file" :path dir :error t)))
    (let ((large-file-warning-threshold 100))
      (should (string-match-p "f1.txt is too large to show"
                              (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1) :error t))))
    (should (string-match-p "open_file needs a path" (claude-pair-test--tool "open_file" :error t)))
    (should (string-match-p "Emacs has no tool" (claude-pair-test--tool "split_frame" :error t)))))

(ert-deftest claude-pair-layout-files-open-without-unsafe-local-variables ()
  (claude-pair-test-with-layout
    (let ((evil (expand-file-name "evil.txt" dir)))
      (with-temp-file evil
        (insert "x\n;; Local Variables:\n;; eval: (setq claude-pair-test--pwned t)\n;; End:\n"))
      (defvar claude-pair-test--pwned nil)
      (claude-pair-test--tool "open_file" :path evil)
      (should-not claude-pair-test--pwned))))

(ert-deftest claude-pair-layout-c-x-1-keeps-the-chat ()
  (claude-pair-test-with-layout
    (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1))
    (delete-other-windows)
    (should (get-buffer-window chat))
    (should (= (claude-pair-test--count) 2))))

(ert-deftest claude-pair-layout-marks-survive-a-tab-switch ()
  (claude-pair-test-with-layout
    (claude-pair-layout-enable)
    (claude-pair-test--tool "open_file" :path (claude-pair-test--file 1))
    (let ((id (window-parameter (claude-pair-test--window-of 1) 'claude-pair-id)))
      (unwind-protect
          (progn
            (tab-bar-new-tab)
            (tab-bar-switch-to-prev-tab)
            (let ((window (claude-pair-test--window-of 1)))
              (should window)
              (should (window-parameter window 'claude-pair-owner))
              (should (eql (window-parameter window 'claude-pair-id) id))))
        (tab-bar-close-other-tabs)
        (tab-bar-mode -1)))))

(ert-deftest claude-pair-layout-the-chat-gets-a-tab-of-its-own ()
  (let ((claude-pair-layout-tab "Claude test")
        (buffer (get-buffer-create " *claude-pair tab test*")))
    (unwind-protect
        (progn
          (claude-pair-test--reset-frame)
          (claude-pair-layout-enter-tab buffer)
          (should (equal (alist-get 'name (tab-bar--current-tab)) "Claude test"))
          ;; Already there, or the buffer is visible: no switch.
          (claude-pair-layout-enter-tab buffer)
          (should (= (length (funcall tab-bar-tabs-function)) 2))
          (tab-bar-switch-to-prev-tab)
          (switch-to-buffer buffer)
          (claude-pair-layout-enter-tab buffer)
          (should-not (equal (alist-get 'name (tab-bar--current-tab)) "Claude test")))
      (tab-bar-close-other-tabs)
      (tab-bar-mode -1)
      (claude-pair-test--reset-frame)
      (kill-buffer buffer))))

(ert-deftest claude-pair-layout-a-proposal-respects-the-limit ()
  (claude-pair-test-with-layout
    (dolist (n '(1 2 3))
      (claude-pair-test--tool "open_file" :path (claude-pair-test--file n)))
    (cl-letf (((symbol-function 'claude-pair-rpc-request) (lambda (&rest _) '(:ok t))))
      (claude-pair-review--propose
       (list :requestId "e1" :sessionId "s1" :kind "edit" :filePath (claude-pair-test--file 5)
             :oldString "file 5 line 30\n" :newString "FIVE\n"))
      (unwind-protect
          (progn
            (should (= (claude-pair-test--count) 5))
            (should (eq (selected-window) mine))
            (should (claude-pair-test--window-of 5))
            (should-not (claude-pair-test--window-of 1)))
        (claude-pair-review-reject "e1" "")))))

(ert-deftest claude-pair-layout-your-tab-is-never-touched-by-a-proposal ()
  (claude-pair-test-with-layout
    (let ((claude-pair-layout-tab "Claude test"))
      (unwind-protect
          (progn
            ;; The chat lives in Claude's tab; you are back in your own.
            (tab-bar-switch-to-tab "Claude test")
            (tab-bar-switch-to-prev-tab)
            (delete-window (get-buffer-window chat))
            (should (= (claude-pair-test--count) 1))
            (should (claude-pair-layout-elsewhere-p))
            (let (shown)
              (cl-letf (((symbol-function 'claude-pair-rpc-request) (lambda (&rest _) '(:ok t)))
                        ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) shown))))
                (claude-pair-review--propose
                 (list :requestId "e1" :sessionId "s1" :kind "edit" :filePath (claude-pair-test--file 1)
                       :oldString "file 1 line 3\n" :newString "THREE\n")))
              (unwind-protect
                  (progn
                    (should (= (claude-pair-test--count) 1))
                    (should (eq (window-buffer mine) (get-buffer "*scratch*")))
                    (should (claude-pair-review-pending-p "e1"))
                    (should (seq-some (lambda (m) (string-match-p "in the Claude test tab: C-x t o" m)) shown)))
                (cl-letf (((symbol-function 'claude-pair-rpc-request) (lambda (&rest _) '(:ok t))))
                  (claude-pair-review-reject "e1" "")))))
        (tab-bar-close-other-tabs)
        (tab-bar-mode -1)))))

(ert-deftest claude-pair-layout-without-claude-tab-a-proposal-comes-to-you ()
  (claude-pair-test-with-layout
    (delete-window (get-buffer-window chat))
    (should-not (claude-pair-layout-elsewhere-p))
    (cl-letf (((symbol-function 'claude-pair-rpc-request) (lambda (&rest _) '(:ok t))))
      (claude-pair-review--propose
       (list :requestId "e1" :sessionId "s1" :kind "edit" :filePath (claude-pair-test--file 1)
             :oldString "file 1 line 3\n" :newString "THREE\n"))
      (unwind-protect
          (progn
            (should (claude-pair-test--window-of 1))
            (should (eq (selected-window) mine)))
        (claude-pair-review-reject "e1" "")))))

;;;; For real, through the daemon

(ert-deftest claude-pair-layout-open-file-for-real ()
  (claude-pair-test-with-project
    (let ((claude-pair-layout-tab nil))
      (claude-pair-test--reset-frame)
      (with-temp-file (expand-file-name "f1.txt" project)
        (dotimes (n 30) (insert (format "line %d\n" (1+ n)))))
      (unwind-protect
          (progn
            ;; *scratch* is current after the reset; start in the project.
            (let ((default-directory (file-name-as-directory project)))
              (setq buffer (claude-pair)))
            (select-window (get-mru-window nil nil t))
            (claude-pair-test--say buffer "script:mcp:open_file:{\"path\":\"f1.txt\",\"line\":12} && list_windows:")
            (let* ((file-buffer (find-buffer-visiting (expand-file-name "f1.txt" project)))
                   (window (and file-buffer (get-buffer-window file-buffer))))
              (unless window
                (ert-fail (list "f1.txt is not shown" (with-current-buffer buffer (claude-pair-test--transcript)))))
              (should (window-parameter window 'claude-pair-owner))
              (with-current-buffer (window-buffer window)
                (should (= (line-number-at-pos (window-point window)) 12))))
            (with-current-buffer buffer
              (let ((text (claude-pair-test--transcript)))
                (should (string-match-p "Show f1.txt:12" text))
                (should (string-match-p "open_file result: Showing f1.txt in window [0-9]+, a new window Claude opened, now at line 12\\. Windows: 3 of at most 5\\." text))
                (should (string-match-p "\\] Claude's: f1.txt, lines" text))
                (should-not (string-match-p "Allow\\|wants to" text)))))
        (dolist (b (buffer-list))
          (when (and (buffer-file-name b) (string-prefix-p project (buffer-file-name b)))
            (kill-buffer b)))
        (claude-pair-test--reset-frame)))))

(ert-deftest claude-pair-layout-outside-the-project-for-real ()
  (claude-pair-test-with-project
    (let ((claude-pair-layout-tab nil))
      (unwind-protect
          (progn
            ;; *scratch* is current after the reset; start in the project.
            (let ((default-directory (file-name-as-directory project)))
              (setq buffer (claude-pair)))
            (claude-pair-test--say buffer "script:mcp:open_file:{\"path\":\"/etc/hostname\"}")
            (should-not (find-buffer-visiting "/etc/hostname"))
            (with-current-buffer buffer
              (should (string-match-p "only shows files inside the project"
                                      (claude-pair-test--transcript)))))
        (claude-pair-test--reset-frame)))))

(provide 'claude-pair-layout-tests)
;;; claude-pair-layout-tests.el ends here
