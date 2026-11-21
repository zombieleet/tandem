;;; claude-pair-tools-tests.el --- Tests for what Emacs tells Claude  -*- lexical-binding: t; -*-

;;; Commentary:

;; The diagnostics, xref, imenu and selection tools, called as the daemon
;; calls them, and once for real through the fake claude.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'flymake)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--geo
  "import math\n\n\ndef area(r):\n    return math.pi * r * r\n\n\ndef main():\n    print(area(2))\n"
  "A small Python file.")

(defmacro claude-pair-test-with-tools (&rest body)
  "Run BODY with a project DIR holding geo.py and calls.el; ROOT is DIR."
  (declare (indent 0) (debug t))
  `(let* ((dir (file-name-as-directory (claude-pair-test--private-dir)))
          (root dir))
     (ignore root)
     (with-temp-file (expand-file-name "geo.py" dir) (insert claude-pair-test--geo))
     (with-temp-file (expand-file-name "calls.el" dir) (insert "(claude-pair-ask \"what?\")\n"))
     (with-temp-file (expand-file-name "notes.txt" dir) (insert "just words\n"))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))

(defvar claude-pair-test--tools-dir nil "The project the tool tests run in.")

(defun claude-pair-test--call (tool &rest args)
  "Call TOOL with ARGS in session s1 of `claude-pair-test--tools-dir'; return its text."
  (car (claude-pair-layout--run tool args "s1" claude-pair-test--tools-dir)))

(defun claude-pair-test--flymake (buffer line message)
  "Give BUFFER a Flymake backend reporting MESSAGE on LINE."
  (with-current-buffer buffer
    (setq-local flymake-diagnostic-functions
                (list (lambda (report &rest _)
                        (funcall report (list (flymake-make-diagnostic
                                               (current-buffer)
                                               (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point))
                                               (save-excursion (goto-char (point-min)) (forward-line (1- line)) (line-end-position))
                                               :warning message))))))
    (flymake-mode 1)))

(ert-deftest claude-pair-tools-diagnostics-of-a-file ()
  (claude-pair-test-with-tools
    (let* ((claude-pair-test--tools-dir dir)
           (path (expand-file-name "geo.py" dir)))
      (claude-pair-test--flymake (find-file-noselect path) 9 "area is called with an int")
      (should (equal (claude-pair-test--call "diagnostics" :path path)
                     "geo.py:9: warning: area is called with an int"))
      ;; Every open file of the project, without a path.
      (should (equal (claude-pair-test--call "diagnostics")
                     "geo.py:9: warning: area is called with an int"))
      ;; No checker there.
      (should (equal (claude-pair-test--call "diagnostics" :path (expand-file-name "notes.txt" dir))
                     "No checker (Flymake or Flycheck) runs for notes.txt in Emacs.")))))

(ert-deftest claude-pair-tools-xref-through-the-mode ()
  (claude-pair-test-with-tools
    (let* ((claude-pair-test--tools-dir dir)
           (text (claude-pair-test--call "xref" :symbol "claude-pair-ask"
                                         :path (expand-file-name "calls.el" dir) :line 1)))
      (should (string-match-p "\\`Definitions of claude-pair-ask (elisp):" text))
      (should (string-match-p "claude-pair-ask\\.el:[0-9]+: (defun claude-pair-ask" text)))))

(ert-deftest claude-pair-tools-xref-without-a-backend-never-asks-for-tags ()
  (claude-pair-test-with-tools
    (let ((claude-pair-test--tools-dir dir)
          (tags-table-list nil)
          (tags-file-name nil))
      (cl-letf (((symbol-function 'visit-tags-table) (lambda (&rest _) (error "Asked for a TAGS file"))))
        (should (string-match-p "no language server or tags for notes.txt"
                                (claude-pair-test--call "xref" :symbol "words"
                                                        :path (expand-file-name "notes.txt" dir))))))))

(ert-deftest claude-pair-tools-imenu-outline ()
  (claude-pair-test-with-tools
    (let ((claude-pair-test--tools-dir dir))
      (should (equal (claude-pair-test--call "imenu" :path (expand-file-name "geo.py" dir))
                     ;; Python's mode labels its entries "(def)".
                     "Outline of geo.py:\narea (def) (line 4)\nmain (def) (line 8)"))
      (should (string-match-p "has no outline"
                              (claude-pair-test--call "imenu" :path (expand-file-name "notes.txt" dir)))))))

(ert-deftest claude-pair-tools-a-missing-file ()
  (claude-pair-test-with-tools
    ;; The tool signals; the call that answers the daemon makes it an error result.
    (should-error (claude-pair-layout--run "imenu" (list :path (expand-file-name "nope.py" dir)) "s1" dir))
    (let (answered)
      (cl-letf (((symbol-function 'claude-pair-rpc-request)
                 (lambda (_method params &rest _) (setq answered params) '(:ok t))))
        (claude-pair-layout--call (list :requestId "t1" :sessionId "s1" :tool "imenu" :root dir
                                        :args (list :path (expand-file-name "nope.py" dir)))))
      (should (eq (plist-get answered :isError) t))
      (should (string-match-p "There is no file" (plist-get answered :text))))))

(ert-deftest claude-pair-tools-selection ()
  (claude-pair-test-with-tools
    (let ((claude-pair-test--tools-dir dir))
      (switch-to-buffer (find-file-noselect (expand-file-name "geo.py" dir)))
      (goto-char (point-min))
      (search-forward "return")
      (let ((text (claude-pair-test--call "selection")))
        (should (string-match-p "\\`The user is in geo.py, at line 5, column 10; lines 1-" text))
        (should (string-match-p "They have nothing selected\\.\\'" text)))
      (beginning-of-line)
      (set-mark (point))
      (forward-line 1)
      (activate-mark)
      (let ((text (claude-pair-test--call "selection")))
        (should (string-match-p "They have selected lines 5-5:\n```python\n    return math.pi \\* r \\* r\n```" text)))
      (deactivate-mark)
      ;; From the chat: the window you were in.
      (let ((chat (generate-new-buffer "*claude-pair: tools test*")))
        (unwind-protect
            (let ((window (split-window nil nil 'right)))
              (with-current-buffer chat (claude-pair-chat-mode))
              (set-window-buffer window chat)
              (select-window window)
              (should (string-match-p "\\`The user is in geo.py" (claude-pair-test--call "selection")))
              (delete-window window))
          (kill-buffer chat))))))

(ert-deftest claude-pair-tools-registered ()
  (dolist (tool '("open_file" "close_window" "list_windows" "diagnostics" "xref" "imenu" "selection"))
    (should (assoc tool claude-pair-layout-tools))))

;;;; For real

(ert-deftest claude-pair-tools-for-real ()
  (claude-pair-test-with-project
    (with-temp-file (expand-file-name "geo.py" project) (insert claude-pair-test--geo))
    (unwind-protect
        (progn
          (setq buffer (claude-pair))
          (claude-pair-test--say buffer "script:mcp:imenu:{\"path\":\"geo.py\"}")
          (with-current-buffer buffer
            (let ((text (claude-pair-test--transcript)))
              (should (string-match-p "Outline geo.py" text))
              (should (string-match-p "imenu result: Outline of geo.py:\narea (def) (line 4)\nmain (def) (line 8)" text))
              (should-not (string-match-p "wants to" text)))))
      (let ((b (find-buffer-visiting (expand-file-name "geo.py" project))))
        (when b (kill-buffer b))))))

(provide 'claude-pair-tools-tests)
;;; claude-pair-tools-tests.el ends here
