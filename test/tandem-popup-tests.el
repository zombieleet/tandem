;;; tandem-popup-tests.el --- Tests for the popup on proposed hunks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch Emacs has no graphical frames, so these run the terminal style:
;; the hunk's banner line is the popup.  The placement of the child frame
;; is tested as arithmetic; the child frame itself in a real Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'tandem)
(require 'tandem-test-helpers)

(defconst tandem-test--lines
  (mapconcat (lambda (n) (format "line %d\n" n)) (number-sequence 1 10) "")
  "Ten numbered lines.")

(defmacro tandem-test-with-hunks (&rest body)
  "Run BODY in the buffer of a.txt, with edit e1 shown as two hunks."
  (declare (indent 0) (debug t))
  `(tandem-test-with-file tandem-test--lines
     (tandem-test--propose
      "e1" :kind "edit" :filePath file :oldString tandem-test--lines
      :newString (replace-regexp-in-string
                  "line 9\n" "NINE\n"
                  (replace-regexp-in-string "line 2\n" "TWO\n" tandem-test--lines)))
     (unwind-protect
         (with-current-buffer (find-buffer-visiting file)
           (switch-to-buffer (current-buffer))
           ,@body)
       (tandem-popup-hide))))

(defun tandem-test--popup-hunk (n)
  "Return hunk N of edit e1."
  (nth (1- n) (plist-get (gethash "e1" tandem-review--proposals) :hunks)))

(defun tandem-test--in-hunk (n)
  "Put point inside the new text of hunk N."
  (goto-char (1+ (nth 0 (tandem-review--hunk-entry (tandem-test--popup-hunk n))))))

(defun tandem-test--banner (n)
  "Return the banner string of hunk N."
  (overlay-get (tandem-review--hunk-banner (tandem-test--popup-hunk n)) 'before-string))

(defun tandem-test--active-p (n)
  "Return non-nil if hunk N's banner is drawn as the one point is in."
  (let ((face (get-text-property 0 'face (tandem-test--banner n))))
    (memq 'tandem-review-banner-active (ensure-list face))))

(defun tandem-test--click (string index window)
  "Return a mouse-1 event on character INDEX of STRING shown in WINDOW."
  (list 'mouse-1 (list window (point) '(0 . 0) 0 (cons string index) (point) '(0 . 0) nil '(0 . 0) '(1 . 1))))

(ert-deftest tandem-popup-banners-are-buttons ()
  (tandem-test-with-hunks
    (let* ((banner (tandem-test--banner 1))
           (apply (string-search "C-c C-a apply" banner))
           (reject (string-search "C-c C-k reject" banner)))
      (should apply)
      (should reject)
      (should (eq (get-text-property apply 'keymap banner) tandem-review-apply-button-map))
      (should (eq (get-text-property reject 'keymap banner) tandem-review-reject-button-map))
      (should (eq (get-text-property apply 'tandem-hunk banner) (tandem-test--popup-hunk 1)))
      (should (eq (get-text-property apply 'mouse-face banner) 'highlight)))))

(ert-deftest tandem-popup-clicking-a-banner-button ()
  (tandem-test-with-hunks
    (let* ((banner (tandem-test--banner 2))
           (reject (string-search "C-c C-k reject" banner)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "not nine")))
        (tandem-review-click-reject (tandem-test--click banner reject (selected-window))))
      (should (eq (tandem-review--hunk-state (tandem-test--popup-hunk 2)) 'rejected))
      (should (equal (tandem-review--hunk-note (tandem-test--popup-hunk 2)) "not nine"))
      (let* ((banner (tandem-test--banner 1))
             (apply (string-search "C-c C-a apply" banner)))
        (tandem-review-click-apply (tandem-test--click banner apply (selected-window))))
      (should (string-match-p "TWO" (buffer-string)))
      (should (equal (plist-get (car tandem-test--answers) :outcome) "partial")))))

(ert-deftest tandem-popup-opens-after-a-pause-and-closes-on-leaving ()
  (tandem-test-with-hunks
    (let ((tandem-popup-delay 0.3))
      (tandem-test--in-hunk 1)
      (tandem-popup--post-command)
      ;; Not at once: a timer waits for 0.3 s of idleness.
      (should (timerp tandem-popup--timer))
      (should-not (tandem-test--active-p 1))
      (tandem-popup--open-if-still-there (tandem-test--popup-hunk 1) (selected-window))
      (should (eq tandem-popup--hunk (tandem-test--popup-hunk 1)))
      (should (tandem-test--active-p 1))
      ;; Into the other hunk: this one goes out, that one waits its turn.
      (tandem-test--in-hunk 2)
      (tandem-popup--post-command)
      (should-not (tandem-test--active-p 1))
      (tandem-popup--open-if-still-there (tandem-test--popup-hunk 2) (selected-window))
      (should (tandem-test--active-p 2))
      ;; Out of every hunk: closed.
      (goto-char (point-min))
      (search-forward "line 5")
      (tandem-popup--post-command)
      (should-not tandem-popup--hunk)
      (should-not (tandem-test--active-p 2)))))

(ert-deftest tandem-popup-a-stale-timer-does-nothing ()
  (tandem-test-with-hunks
    (tandem-test--in-hunk 1)
    (tandem-popup--post-command)
    (goto-char (point-min))
    (search-forward "line 5")
    ;; The timer fires after point already left the hunk.
    (tandem-popup--open-if-still-there (tandem-test--popup-hunk 1) (selected-window))
    (should-not tandem-popup--hunk)))

(ert-deftest tandem-popup-m-ret-opens-it-at-once ()
  (tandem-test-with-hunks
    (tandem-test--in-hunk 2)
    (should (eq (key-binding (kbd "M-RET")) #'tandem-popup-show))
    (tandem-popup-show)
    (should (eq tandem-popup--hunk (tandem-test--popup-hunk 2)))
    (should (tandem-test--active-p 2))
    (goto-char (point-min))
    (should-error (tandem-popup-show) :type 'user-error)))

(ert-deftest tandem-popup-deciding-closes-it ()
  (tandem-test-with-hunks
    (tandem-test--in-hunk 1)
    (tandem-popup-show)
    (tandem-review-apply-hunk)
    (should-not (eq tandem-popup--hunk (tandem-test--popup-hunk 1)))))

(ert-deftest tandem-popup-leaving-the-buffer-closes-it ()
  (tandem-test-with-hunks
    (tandem-test--in-hunk 1)
    (tandem-popup-show)
    (with-temp-buffer
      (tandem-popup--elsewhere))
    (should-not tandem-popup--hunk)))

(ert-deftest tandem-popup-hovering-opens-it-without-a-tooltip ()
  (tandem-test-with-hunks
    (let* ((hunk (tandem-test--popup-hunk 2))
           (pos (1+ (nth 0 (tandem-review--hunk-entry hunk))))
           scheduled)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (setq scheduled (cons fn args)))))
        (should-not (tandem-popup--hover (selected-window) nil pos)))
      (should (equal scheduled (list #'tandem-popup--open hunk (selected-window))))
      ;; The overlays carry it.
      (should (eq (get-char-property pos 'help-echo) #'tandem-popup--hover)))))

(ert-deftest tandem-popup-text ()
  (tandem-test-with-hunks
    (let ((text (tandem-popup--text (tandem-test--popup-hunk 2))))
      (should (string-match-p "Claude · hunk 2 of 2 · a.txt" text))
      (should (string-match-p "✓ Approve C-c C-a" text))
      (should (string-match-p "✗ Reject… C-c C-k" text))
      (should (string-match-p "@ Ask Claude… C-c '" text))
      (let ((at (string-search "✓ Approve" text)))
        (should (eq (get-text-property at 'keymap text) tandem-review-apply-button-map))))))

(ert-deftest tandem-popup-a-click-in-the-popup-acts-in-your-window ()
  (tandem-test-with-hunks
    (let* ((home (selected-window))
           (point-before (point))
           (popup (split-window home nil 'below))
           (text (tandem-popup--text (tandem-test--popup-hunk 1))))
      (unwind-protect
          (progn
            (set-window-buffer popup (tandem-popup--buffer))
            (set-window-parameter popup 'tandem-popup-for home)
            (with-current-buffer (tandem-popup--buffer)
              (let ((inhibit-read-only t)) (erase-buffer) (insert text)))
            (let* ((at (with-current-buffer (tandem-popup--buffer)
                         (1+ (string-search "✓ Approve" text))))
                   (event (list 'mouse-1 (list popup at '(0 . 0) 0 nil at '(0 . 0) nil '(0 . 0) '(1 . 1)))))
              (select-window popup)
              (tandem-review-click-apply event))
            (should (eq (selected-window) home))
            (should (string-match-p "TWO" (buffer-string)))
            (ignore point-before))
        (delete-window popup)))))

(ert-deftest tandem-popup-placement ()
  ;; Window text from y=100 to y=500; popup 40 pixels high.
  (should (= (tandem-popup-place 100 500 300 200 40) 300))   ; room below
  (should (= (tandem-popup-place 100 500 480 200 40) 160))   ; not below: above the banner
  (should (= (tandem-popup-place 100 500 nil 200 40) 160))   ; line below off screen
  (should-not (tandem-popup-place 100 500 480 120 40))       ; no room either side
  (should-not (tandem-popup-place 100 500 nil nil 40)))

(ert-deftest tandem-popup-style ()
  (let ((tandem-popup-style 'auto))
    (should (eq (tandem-popup--style (selected-window))
                (if (display-graphic-p) 'child-frame 'inline))))
  (let ((tandem-popup-style 'child-frame))
    ;; Without a graphical frame, the banner stands in.
    (unless (display-graphic-p)
      (should (eq (tandem-popup--style (selected-window)) 'inline))))
  (let ((tandem-popup-style nil))
    (should-not (tandem-popup--style (selected-window)))))

(ert-deftest tandem-popup-a-tiny-drag-is-a-click ()
  ;; In a real Emacs the click on a popup button arrived as drag-mouse-1.
  (should (eq (lookup-key tandem-review-apply-button-map [drag-mouse-1])
              #'tandem-review-click-apply))
  (should (eq (lookup-key tandem-review-reject-button-map [drag-mouse-1])
              #'tandem-review-click-reject))
  (tandem-test-with-hunks
    (let* ((banner (tandem-test--banner 1))
           (at (string-search "C-c C-a apply" banner))
           (event (tandem-test--click banner at (selected-window))))
      (setcar event 'drag-mouse-1)
      (call-interactively (lookup-key tandem-review-apply-button-map [drag-mouse-1]) nil (vector event))
      (should (eq (tandem-review--hunk-state (tandem-test--popup-hunk 1)) 'applied)))))

(provide 'tandem-popup-tests)
;;; tandem-popup-tests.el ends here
