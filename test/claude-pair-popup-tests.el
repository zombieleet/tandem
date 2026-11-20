;;; claude-pair-popup-tests.el --- Tests for the popup on proposed hunks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch Emacs has no graphical frames, so these run the terminal style:
;; the hunk's banner line is the popup.  The placement of the child frame
;; is tested as arithmetic; the child frame itself in a real Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'claude-pair)
(require 'claude-pair-test-helpers)

(defconst claude-pair-test--lines
  (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 10) "")
  "Ten numbered lines.")

(defmacro claude-pair-test-with-hunks (&rest body)
  "Run BODY in the buffer of a.txt, with edit e1 shown as two hunks."
  (declare (indent 0) (debug t))
  `(claude-pair-test-with-file claude-pair-test--lines
     (claude-pair-test--propose
      "e1" :kind "edit" :filePath file :oldString claude-pair-test--lines
      :newString (replace-regexp-in-string
                  "line 9\n" "NINE\n"
                  (replace-regexp-in-string "line 2\n" "TWO\n" claude-pair-test--lines)))
     (unwind-protect
         (with-current-buffer (find-buffer-visiting file)
           (switch-to-buffer (current-buffer))
           ,@body)
       (claude-pair-popup-hide))))

(defun claude-pair-test--popup-hunk (n)
  "Return hunk N of edit e1."
  (nth (1- n) (plist-get (gethash "e1" claude-pair-review--proposals) :hunks)))

(defun claude-pair-test--in-hunk (n)
  "Put point inside the new text of hunk N."
  (goto-char (1+ (nth 0 (claude-pair-review--hunk-entry (claude-pair-test--popup-hunk n))))))

(defun claude-pair-test--banner (n)
  "Return the banner string of hunk N."
  (overlay-get (claude-pair-review--hunk-banner (claude-pair-test--popup-hunk n)) 'before-string))

(defun claude-pair-test--active-p (n)
  "Return non-nil if hunk N's banner is drawn as the one point is in."
  (let ((face (get-text-property 0 'face (claude-pair-test--banner n))))
    (memq 'claude-pair-review-banner-active (ensure-list face))))

(defun claude-pair-test--click (string index window)
  "Return a mouse-1 event on character INDEX of STRING shown in WINDOW."
  (list 'mouse-1 (list window (point) '(0 . 0) 0 (cons string index) (point) '(0 . 0) nil '(0 . 0) '(1 . 1))))

(ert-deftest claude-pair-popup-banners-are-buttons ()
  (claude-pair-test-with-hunks
    (let* ((banner (claude-pair-test--banner 1))
           (apply (string-search "C-c C-a apply" banner))
           (reject (string-search "C-c C-k reject" banner)))
      (should apply)
      (should reject)
      (should (eq (get-text-property apply 'keymap banner) claude-pair-review-apply-button-map))
      (should (eq (get-text-property reject 'keymap banner) claude-pair-review-reject-button-map))
      (should (eq (get-text-property apply 'claude-pair-hunk banner) (claude-pair-test--popup-hunk 1)))
      (should (eq (get-text-property apply 'mouse-face banner) 'highlight)))))

(ert-deftest claude-pair-popup-clicking-a-banner-button ()
  (claude-pair-test-with-hunks
    (let* ((banner (claude-pair-test--banner 2))
           (reject (string-search "C-c C-k reject" banner)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "not nine")))
        (claude-pair-review-click-reject (claude-pair-test--click banner reject (selected-window))))
      (should (eq (claude-pair-review--hunk-state (claude-pair-test--popup-hunk 2)) 'rejected))
      (should (equal (claude-pair-review--hunk-note (claude-pair-test--popup-hunk 2)) "not nine"))
      (let* ((banner (claude-pair-test--banner 1))
             (apply (string-search "C-c C-a apply" banner)))
        (claude-pair-review-click-apply (claude-pair-test--click banner apply (selected-window))))
      (should (string-match-p "TWO" (buffer-string)))
      (should (equal (plist-get (car claude-pair-test--answers) :outcome) "partial")))))

(ert-deftest claude-pair-popup-opens-after-a-pause-and-closes-on-leaving ()
  (claude-pair-test-with-hunks
    (let ((claude-pair-popup-delay 0.3))
      (claude-pair-test--in-hunk 1)
      (claude-pair-popup--post-command)
      ;; Not at once: a timer waits for 0.3 s of idleness.
      (should (timerp claude-pair-popup--timer))
      (should-not (claude-pair-test--active-p 1))
      (claude-pair-popup--open-if-still-there (claude-pair-test--popup-hunk 1) (selected-window))
      (should (eq claude-pair-popup--hunk (claude-pair-test--popup-hunk 1)))
      (should (claude-pair-test--active-p 1))
      ;; Into the other hunk: this one goes out, that one waits its turn.
      (claude-pair-test--in-hunk 2)
      (claude-pair-popup--post-command)
      (should-not (claude-pair-test--active-p 1))
      (claude-pair-popup--open-if-still-there (claude-pair-test--popup-hunk 2) (selected-window))
      (should (claude-pair-test--active-p 2))
      ;; Out of every hunk: closed.
      (goto-char (point-min))
      (search-forward "line 5")
      (claude-pair-popup--post-command)
      (should-not claude-pair-popup--hunk)
      (should-not (claude-pair-test--active-p 2)))))

(ert-deftest claude-pair-popup-a-stale-timer-does-nothing ()
  (claude-pair-test-with-hunks
    (claude-pair-test--in-hunk 1)
    (claude-pair-popup--post-command)
    (goto-char (point-min))
    (search-forward "line 5")
    ;; The timer fires after point already left the hunk.
    (claude-pair-popup--open-if-still-there (claude-pair-test--popup-hunk 1) (selected-window))
    (should-not claude-pair-popup--hunk)))

(ert-deftest claude-pair-popup-m-ret-opens-it-at-once ()
  (claude-pair-test-with-hunks
    (claude-pair-test--in-hunk 2)
    (should (eq (key-binding (kbd "M-RET")) #'claude-pair-popup-show))
    (claude-pair-popup-show)
    (should (eq claude-pair-popup--hunk (claude-pair-test--popup-hunk 2)))
    (should (claude-pair-test--active-p 2))
    (goto-char (point-min))
    (should-error (claude-pair-popup-show) :type 'user-error)))

(ert-deftest claude-pair-popup-deciding-closes-it ()
  (claude-pair-test-with-hunks
    (claude-pair-test--in-hunk 1)
    (claude-pair-popup-show)
    (claude-pair-review-apply-hunk)
    (should-not (eq claude-pair-popup--hunk (claude-pair-test--popup-hunk 1)))))

(ert-deftest claude-pair-popup-leaving-the-buffer-closes-it ()
  (claude-pair-test-with-hunks
    (claude-pair-test--in-hunk 1)
    (claude-pair-popup-show)
    (with-temp-buffer
      (claude-pair-popup--elsewhere))
    (should-not claude-pair-popup--hunk)))

(ert-deftest claude-pair-popup-hovering-opens-it-without-a-tooltip ()
  (claude-pair-test-with-hunks
    (let* ((hunk (claude-pair-test--popup-hunk 2))
           (pos (1+ (nth 0 (claude-pair-review--hunk-entry hunk))))
           scheduled)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (setq scheduled (cons fn args)))))
        (should-not (claude-pair-popup--hover (selected-window) nil pos)))
      (should (equal scheduled (list #'claude-pair-popup--open hunk (selected-window))))
      ;; The overlays carry it.
      (should (eq (get-char-property pos 'help-echo) #'claude-pair-popup--hover)))))

(ert-deftest claude-pair-popup-text ()
  (claude-pair-test-with-hunks
    (let ((text (claude-pair-popup--text (claude-pair-test--popup-hunk 2))))
      (should (string-match-p "Claude · hunk 2 of 2 · a.txt" text))
      (should (string-match-p "✓ Approve C-c C-a" text))
      (should (string-match-p "✗ Reject… C-c C-k" text))
      (let ((at (string-search "✓ Approve" text)))
        (should (eq (get-text-property at 'keymap text) claude-pair-review-apply-button-map))))))

(ert-deftest claude-pair-popup-a-click-in-the-popup-acts-in-your-window ()
  (claude-pair-test-with-hunks
    (let* ((home (selected-window))
           (point-before (point))
           (popup (split-window home nil 'below))
           (text (claude-pair-popup--text (claude-pair-test--popup-hunk 1))))
      (unwind-protect
          (progn
            (set-window-buffer popup (claude-pair-popup--buffer))
            (set-window-parameter popup 'claude-pair-popup-for home)
            (with-current-buffer (claude-pair-popup--buffer)
              (let ((inhibit-read-only t)) (erase-buffer) (insert text)))
            (let* ((at (with-current-buffer (claude-pair-popup--buffer)
                         (1+ (string-search "✓ Approve" text))))
                   (event (list 'mouse-1 (list popup at '(0 . 0) 0 nil at '(0 . 0) nil '(0 . 0) '(1 . 1)))))
              (select-window popup)
              (claude-pair-review-click-apply event))
            (should (eq (selected-window) home))
            (should (string-match-p "TWO" (buffer-string)))
            (ignore point-before))
        (delete-window popup)))))

(ert-deftest claude-pair-popup-placement ()
  ;; Window text from y=100 to y=500; popup 40 pixels high.
  (should (= (claude-pair-popup-place 100 500 300 200 40) 300))   ; room below
  (should (= (claude-pair-popup-place 100 500 480 200 40) 160))   ; not below: above the banner
  (should (= (claude-pair-popup-place 100 500 nil 200 40) 160))   ; line below off screen
  (should-not (claude-pair-popup-place 100 500 480 120 40))       ; no room either side
  (should-not (claude-pair-popup-place 100 500 nil nil 40)))

(ert-deftest claude-pair-popup-style ()
  (let ((claude-pair-popup-style 'auto))
    (should (eq (claude-pair-popup--style (selected-window))
                (if (display-graphic-p) 'child-frame 'inline))))
  (let ((claude-pair-popup-style 'child-frame))
    ;; Without a graphical frame, the banner stands in.
    (unless (display-graphic-p)
      (should (eq (claude-pair-popup--style (selected-window)) 'inline))))
  (let ((claude-pair-popup-style nil))
    (should-not (claude-pair-popup--style (selected-window)))))

(ert-deftest claude-pair-popup-a-tiny-drag-is-a-click ()
  ;; In a real Emacs the click on a popup button arrived as drag-mouse-1.
  (should (eq (lookup-key claude-pair-review-apply-button-map [drag-mouse-1])
              #'claude-pair-review-click-apply))
  (should (eq (lookup-key claude-pair-review-reject-button-map [drag-mouse-1])
              #'claude-pair-review-click-reject))
  (claude-pair-test-with-hunks
    (let* ((banner (claude-pair-test--banner 1))
           (at (string-search "C-c C-a apply" banner))
           (event (claude-pair-test--click banner at (selected-window))))
      (setcar event 'drag-mouse-1)
      (call-interactively (lookup-key claude-pair-review-apply-button-map [drag-mouse-1]) nil (vector event))
      (should (eq (claude-pair-review--hunk-state (claude-pair-test--popup-hunk 1)) 'applied)))))

(provide 'claude-pair-popup-tests)
;;; claude-pair-popup-tests.el ends here
