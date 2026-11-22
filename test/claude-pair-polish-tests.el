;;; claude-pair-polish-tests.el --- Tests for highlights, places and / completion  -*- lexical-binding: t; -*-

;;; Commentary:

;; The lines Claude shows, highlighted; stepping through the places of an
;; xref lookup with next-error; the slash commands listed as you type /.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defmacro claude-pair-test-with-places (&rest body)
  "Run BODY with DIR holding geo.py, which calls area three times."
  (declare (indent 0) (debug t))
  `(let ((dir (file-name-as-directory (claude-pair-test--private-dir))))
     (with-temp-file (expand-file-name "geo.py" dir)
       (insert "def area(r):\n    return 3 * r * r\n\n\nprint(area(1))\nprint(area(2))\nprint(area(3))\n"))
     (unwind-protect (progn ,@body)
       (claude-pair-layout-unhighlight)
       (when (get-buffer claude-pair-tools--locations-buffer)
         (kill-buffer claude-pair-tools--locations-buffer))
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (kill-buffer b)))
       (delete-directory dir t))))

(defun claude-pair-test--highlighted ()
  "Return (BUFFER FIRST LAST) of the highlighted lines, or nil."
  (when-let* ((overlay claude-pair-layout--shown)
              (buffer (overlay-buffer overlay)))
    (with-current-buffer buffer
      (list buffer (line-number-at-pos (overlay-start overlay))
            (line-number-at-pos (1- (overlay-end overlay)))))))

(ert-deftest claude-pair-polish-shown-lines-are-highlighted ()
  (claude-pair-test-with-places
    (let ((file (expand-file-name "geo.py" dir)))
      (claude-pair-layout--open-file (list :path file :line 1 :endLine 2) "s1" dir)
      (let ((shown (claude-pair-test--highlighted)))
        (should (equal (cdr shown) '(1 2)))
        (should (eq (get-char-property (with-current-buffer (car shown) (point-min)) 'face (car shown))
                    'claude-pair-shown)))
      ;; Moving out of the lines in their buffer takes the highlight away.
      (with-current-buffer (find-buffer-visiting file)
        (goto-char (point-min))
        (claude-pair-layout--leave-shown)
        (should claude-pair-layout--shown)
        (goto-char (point-max))
        (claude-pair-layout--leave-shown)
        (should-not claude-pair-layout--shown))
      ;; A single line, and the next show replaces the last.
      (claude-pair-layout--open-file (list :path file :line 5) "s1" dir)
      (should (equal (cdr (claude-pair-test--highlighted)) '(5 5)))
      (claude-pair-layout--open-file (list :path file :line 6) "s1" dir)
      (should (equal (cdr (claude-pair-test--highlighted)) '(6 6))))))

(ert-deftest claude-pair-polish-stepping-through-places ()
  (claude-pair-test-with-places
    (let* ((file (expand-file-name "geo.py" dir))
           (claude-pair-chat--buffers (make-hash-table :test #'equal))
           (chat (generate-new-buffer "*claude-pair: places test*")))
      (unwind-protect
          (progn
            (with-current-buffer chat (claude-pair-chat--setup "s1" dir))
            (claude-pair-tools--locations "s1" dir "References of area"
                                          '(("geo.py" 5 "print(area(1))") ("geo.py" 6 "print(area(2))")
                                            ("geo.py" 7 "print(area(3))")))
            (with-current-buffer chat
              (claude-pair-chat--flush)
              (should (string-match-p "3 places: .* step through them" (claude-pair-test--transcript))))
            ;; Claude showed the first; M-g n goes to the second, highlighted.
            (claude-pair-layout--open-file (list :path file :line 5) "s1" dir)
            (cl-flet ((here () (with-current-buffer (window-buffer (selected-window))
                                 (list (buffer-file-name) (line-number-at-pos (window-point))))))
              (save-window-excursion
                (next-error)
                (should (equal (here) (list file 6)))
                (should (equal (cdr (claude-pair-test--highlighted)) '(6 6)))
                (next-error)
                (should (equal (here) (list file 7)))
                (previous-error)
                (should (equal (here) (list file 6))))))
        (kill-buffer chat)))))

(ert-deftest claude-pair-polish-slash-lists-commands-as-you-type ()
  (let ((claude-pair-chat--buffers (make-hash-table :test #'equal))
        (chat (generate-new-buffer "*claude-pair: slash popup test*"))
        asked)
    (unwind-protect
        (with-current-buffer chat
          (claude-pair-chat--setup "s1" "/tmp")
          (goto-char (point-max))
          (cl-letf (((symbol-function 'completion-at-point) (lambda () (setq asked t))))
            (let ((last-command-event ?/)) (self-insert-command 1))
            (should asked)
            ;; Not in the middle of a message.
            (setq asked nil)
            (claude-pair-chat--set-input "see ")
            (goto-char (point-max))
            (let ((last-command-event ?/)) (self-insert-command 1))
            (should-not asked)
            (let ((claude-pair-slash-popup nil))
              (claude-pair-chat--set-input "")
              (let ((last-command-event ?/)) (self-insert-command 1))
              (should-not asked))))
      (kill-buffer chat))))

(ert-deftest claude-pair-polish-slash-with-company ()
  (skip-unless (require 'company nil t))
  (let ((claude-pair-chat--buffers (make-hash-table :test #'equal))
        (chat (generate-new-buffer "*claude-pair: company test*"))
        begun)
    (unwind-protect
        (with-current-buffer chat
          (claude-pair-chat--setup "s1" "/tmp")
          (company-mode 1)
          (should (eq (car company-backends) 'company-capf))
          (goto-char (point-max))
          (cl-letf (((symbol-function 'company-manual-begin) (lambda () (setq begun t))))
            (let ((last-command-event ?/)) (self-insert-command 1)))
          (should begun))
      (kill-buffer chat))))

(ert-deftest claude-pair-polish-one-stop-per-line ()
  (claude-pair-test-with-places
    (let ((file (expand-file-name "use.el" dir)))
      (with-temp-file file
        (insert ";;; use.el  -*- lexical-binding: t; -*-\n(defun geo-twice (r) r)\n(+ (geo-twice 1) (geo-twice 2))\n(geo-twice 3)\n"))
      ;; A git repository: Emacs's project, where xref looks for uses.
      (call-process "git" nil nil nil "-C" dir "init" "-q")
      (claude-pair-tools-xref (list :symbol "geo-twice" :path file :kind "references") "s1" dir)
      (with-current-buffer claude-pair-tools--locations-buffer
        (let ((lines (seq-filter (lambda (l) (string-match-p "\\`use\\.el:" l))
                                 (split-string (buffer-string) "\n" t))))
          (should (equal (mapcar (lambda (l) (car (split-string l ":" t))) lines) '("use.el" "use.el" "use.el")))
          (should (equal (mapcar (lambda (l) (nth 1 (split-string l ":"))) lines) '("2" "3" "4"))))))))

(provide 'claude-pair-polish-tests)
;;; claude-pair-polish-tests.el ends here
