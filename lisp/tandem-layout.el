;;; tandem-layout.el --- The windows Claude works with  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience
;; URL: https://github.com/zombieleet/tandem

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Claude shows you files with its open_file, close_window and
;; list_windows tools, and its edit proposals appear the same way.  The
;; daemon only relays those calls; Emacs decides what happens, by these
;; rules:
;;
;; - Claude works in the frame and tab where its chat is shown.
;;   `M-x tandem' opens the chat in a tab of its own, named by
;;   `tandem-layout-tab', so your other tabs are never touched.
;; - At most `tandem-max-windows' windows, the chat included.  To
;;   show a file, Claude uses a window that already shows it, else splits
;;   the largest window, else, at the limit, reuses the window it used
;;   least recently.
;; - Windows Claude splits off are its own.  It can close only those, and
;;   never below `tandem-min-windows' windows.
;; - The focus guard: Claude never selects a window, never changes the
;;   window you are in, and leaves alone any window you used in the last
;;   `tandem-focus-guard-seconds' seconds.

;;; Code:

(require 'cl-lib)
(require 'tandem-rpc)
(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(defvar tandem-chat--buffers)

(defcustom tandem-max-windows 5
  "Most windows Claude's frame may have when Claude adds one.
The chat window counts.  Claude never splits beyond this; at the limit
it reuses a window instead.  Windows you make yourself are not limited."
  :type 'natnum
  :group 'tandem)

(defcustom tandem-min-windows 2
  "Fewest windows Claude leaves when it closes one, the chat included."
  :type 'natnum
  :group 'tandem)

(defface tandem-shown
  '((t :inherit highlight :extend t))
  "Face of the lines Claude shows you, such as a definition."
  :group 'tandem)

(defvar tandem-layout-shown-functions nil
  "Functions called when Claude shows a file at a line.
Each gets the buffer and the first and last lines shown.")

(defvar tandem-layout--shown nil
  "The overlay on the lines Claude showed last, or nil.")

(defun tandem-layout-unhighlight ()
  "Remove the highlight from the lines Claude showed last."
  (when tandem-layout--shown
    (delete-overlay tandem-layout--shown)
    (setq tandem-layout--shown nil))
  (remove-hook 'post-command-hook #'tandem-layout--leave-shown))

(defun tandem-layout--leave-shown ()
  "Remove the highlight once you move out of the lines in their buffer."
  (let ((overlay tandem-layout--shown))
    (cond
     ((not (and overlay (overlay-buffer overlay)))
      (tandem-layout-unhighlight))
     ((and (eq (current-buffer) (overlay-buffer overlay))
           (not (and (>= (point) (overlay-start overlay)) (<= (point) (overlay-end overlay)))))
      (tandem-layout-unhighlight)))))

(defun tandem-layout-highlight (buffer first last)
  "Highlight lines FIRST to LAST of BUFFER, the place Claude points you to.
The highlight stays until you move out of those lines in that buffer,
change them, or Claude shows something else."
  (tandem-layout-unhighlight)
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- first))
        (let ((beg (point)))
          (forward-line (max 1 (1+ (- (or last first) first))))
          (let ((overlay (make-overlay beg (point) nil t nil)))
            (overlay-put overlay 'face 'tandem-shown)
            (overlay-put overlay 'priority 50)
            (overlay-put overlay 'tandem-shown t)
            (overlay-put overlay 'modification-hooks
                         (list (lambda (_ov after &rest _) (when after (tandem-layout-unhighlight)))))
            (setq tandem-layout--shown overlay))))))
  (add-hook 'post-command-hook #'tandem-layout--leave-shown))

(defcustom tandem-focus-guard-seconds 3
  "Seconds after you use a window during which Claude leaves it alone."
  :type 'number
  :group 'tandem)

(defcustom tandem-layout-tab "Claude"
  "Name of the tab `tandem' shows the chat in, or nil for the current tab.
Claude's windows live where its chat is, so with a tab of its own your
other tabs keep their layout."
  :type '(choice (const :tag "The current tab" nil) string)
  :group 'tandem)

(defvar tandem-layout--next-id 0
  "The last window id handed out.")

;;;; Setup

(defun tandem-layout-enable ()
  "Start noting the window you use, for the focus guard.
Also keep Claude's window marks when a window layout is saved and
restored, as when you switch tabs."
  (add-hook 'post-command-hook #'tandem-layout--note-use)
  (dolist (parameter '(tandem-owner tandem-id))
    (unless (assq parameter window-persistent-parameters)
      (push (cons parameter 'writable) window-persistent-parameters))))

(defun tandem-layout--note-use ()
  "Remember that you just used the selected window."
  (unless (window-minibuffer-p)
    (set-window-parameter nil 'tandem-used-by-you (float-time))))

(defun tandem-layout-enter-tab (buffer)
  "Switch to Claude's tab, unless BUFFER is visible in the current one.
The tab is named by `tandem-layout-tab'; nil means stay."
  (when (and tandem-layout-tab
             (not (get-buffer-window buffer))
             (not (equal (alist-get 'name (tab-bar--current-tab)) tandem-layout-tab)))
    (tab-bar-switch-to-tab tandem-layout-tab)))

(defun tandem-layout-elsewhere-p ()
  "Return non-nil if Claude's tab exists and you are in another tab.
Then Claude must not touch your windows, even to get your attention."
  (and tandem-layout-tab
       (not (equal (alist-get 'name (tab-bar--current-tab)) tandem-layout-tab))
       (seq-some (lambda (tab) (equal (alist-get 'name tab) tandem-layout-tab))
                 (funcall tab-bar-tabs-function))
       t))

(defun tandem-layout-where-text ()
  "Say where to find Claude's chat, for a message: its tab, if any."
  (if (tandem-layout-elsewhere-p)
      (format " (in the %s tab: C-x t o)" tandem-layout-tab)
    ""))

;;;; What Claude may touch

(defun tandem-layout--chat-window (session)
  "Return the window SESSION's chat is in, or nil."
  (when-let* ((buffer (and session (boundp 'tandem-chat--buffers)
                           (gethash session tandem-chat--buffers))))
    (and (buffer-live-p buffer) (get-buffer-window buffer t))))

(defun tandem-layout--frame (session &optional fallback)
  "Return the frame Claude works in for SESSION, the one with its chat.
When the chat is not shown, return the selected frame if FALLBACK is
non-nil, else nil."
  (if-let* ((window (tandem-layout--chat-window session)))
      (window-frame window)
    (and fallback (selected-frame))))

(defun tandem-layout--windows (frame)
  "Return FRAME's windows in a stable order, without the minibuffer."
  (window-list frame 'nomini (frame-first-window frame)))

(defun tandem-layout--chat-p (window)
  "Return non-nil if WINDOW is a tandem chat window."
  (provided-mode-derived-p (buffer-local-value 'major-mode (window-buffer window))
                           'tandem-chat-mode))

(defun tandem-layout--claudes-p (window)
  "Return non-nil if Claude opened WINDOW."
  (window-parameter window 'tandem-owner))

(defun tandem-layout--yours-now-p (window)
  "Return non-nil if you are working in WINDOW.
That is the window selected in its frame, the one the minibuffer
returns to, or one you used in the last few seconds."
  (or (eq window (frame-selected-window (window-frame window)))
      (eq window (minibuffer-selected-window))
      (< (- (float-time) (or (window-parameter window 'tandem-used-by-you) 0))
         tandem-focus-guard-seconds)))

(defun tandem-layout--plain-p (window)
  "Return non-nil if WINDOW is an ordinary window Claude could show a file in."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))
       (not (window-dedicated-p window))
       (not (tandem-layout--chat-p window))))

(defun tandem-layout--last-use (window)
  "Return when WINDOW was last used, by you or by Claude."
  (max (or (window-parameter window 'tandem-used-by-you) 0)
       (or (window-parameter window 'tandem-used-by-claude) 0)))

(defun tandem-layout--id (window)
  "Return WINDOW's id, the number Claude refers to it by."
  (or (window-parameter window 'tandem-id)
      (set-window-parameter window 'tandem-id
                            (cl-incf tandem-layout--next-id))))

;;;; Showing a buffer

(defun tandem-layout--split (frame)
  "Split a window of FRAME for Claude, if FRAME is under the limit.
Prefer the largest window you are not working in.  Return the new
window, or nil."
  (when (< (length (tandem-layout--windows frame)) tandem-max-windows)
    (let* ((area (lambda (w) (* (window-total-width w) (window-total-height w))))
           (candidates (seq-filter #'tandem-layout--plain-p (tandem-layout--windows frame)))
           (sorted (sort candidates
                         (lambda (a b)
                           (let ((ya (tandem-layout--yours-now-p a))
                                 (yb (tandem-layout--yours-now-p b)))
                             (if (eq ya yb) (> (funcall area a) (funcall area b)) yb))))))
      (seq-some (lambda (window)
                  ;; A character cell is about twice as tall as it is wide.
                  (let* ((wide (>= (window-total-width window) (* 2 (window-total-height window))))
                         (new (or (ignore-errors (split-window window nil (if wide 'right 'below)))
                                  (ignore-errors (split-window window nil (if wide 'below 'right))))))
                    (when new
                      (dolist (parameter '(tandem-id tandem-used-by-you tandem-used-by-claude))
                        (set-window-parameter new parameter nil))
                      new)))
                sorted))))

(defun tandem-layout--reusable (frame)
  "Return the window of FRAME Claude should reuse, or nil.
The least recently used of Claude's windows, else of yours, never one
you are working in."
  (let* ((windows (seq-remove #'tandem-layout--yours-now-p
                              (seq-filter #'tandem-layout--plain-p
                                          (tandem-layout--windows frame))))
         (claudes (seq-filter #'tandem-layout--claudes-p windows)))
    (car (sort (or claudes windows)
               (lambda (a b) (< (tandem-layout--last-use a) (tandem-layout--last-use b)))))))

(defun tandem-layout--scroll-to (window pos)
  "Put point at POS in WINDOW, about a quarter of the way down."
  (set-window-point window pos)
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char pos)
      (forward-line (- (/ (window-body-height window) 4)))
      (set-window-start window (line-beginning-position)))))

(cl-defun tandem-layout-show (buffer &key pos session fallback)
  "Show BUFFER for Claude's SESSION by the layout rules, at POS if given.
Use the frame where the session's chat is shown, or with FALLBACK the
selected frame.  Never select a window.  Return a plist: :window,
:how (`visible', `split' or `reused'; `no-frame' or `full' when not
shown), :moved (non-nil if the window now shows POS) and :before (the
buffer a reused window showed)."
  (let ((frame (tandem-layout--frame session fallback)))
    (if (not frame)
        (list :how 'no-frame)
      (let* ((showing (seq-filter #'window-live-p (get-buffer-window-list buffer 'nomini frame)))
             (window (or (seq-remove #'tandem-layout--yours-now-p showing) showing))
             (window (car window))
             (how (and window 'visible))
             before)
        (unless window
          (if (setq window (tandem-layout--split frame))
              (progn (setq how 'split)
                     (set-window-parameter window 'tandem-owner (or session t)))
            (when (setq window (tandem-layout--reusable frame))
              (setq how 'reused))))
        (if (not window)
            (list :how 'full)
          (unless (eq how 'visible)
            (setq before (window-buffer window))
            (set-window-buffer window buffer))
          (set-window-parameter window 'tandem-used-by-claude (float-time))
          (tandem-layout--id window)
          (let ((moved (and pos (not (tandem-layout--yours-now-p window))
                            (progn (tandem-layout--scroll-to window pos) t))))
            (list :window window :how how :moved moved :before before)))))))

;;;; Claude's tools

(defun tandem-layout--name (path root)
  "Return PATH relative to ROOT when it is inside, else abbreviated."
  (if (and root (file-in-directory-p path root))
      (file-relative-name path root)
    (abbreviate-file-name path)))

(defun tandem-layout--count-text (frame)
  "Say how many windows FRAME has, for Claude."
  (format "Windows: %d of at most %d."
          (length (tandem-layout--windows frame)) tandem-max-windows))

(defconst tandem-layout--not-looking
  "the user is not looking at the frame or tab with the chat right now"
  "Why nothing can be shown when the chat is not visible.")

(defun tandem-layout--open-file (args session root)
  "Run open_file with ARGS for SESSION, whose project is ROOT.
Return (TEXT . ERROR)."
  (let* ((path (plist-get args :path))
         (line (plist-get args :line))
         (line (and (natnump line) (> line 0) line))
         (end (plist-get args :endLine))
         (end (and line (natnump end) (>= end line) end)))
    (if (not (stringp path))
        (cons "open_file needs a path." t)
      (let ((name (tandem-layout--name path root))
            (size (file-attribute-size (file-attributes path))))
        (cond
         ((not (file-exists-p path)) (cons (format "There is no file %s." name) t))
         ((file-directory-p path) (cons (format "%s is a directory; open_file shows files." name) t))
         ((not (file-readable-p path)) (cons (format "Emacs cannot read %s." name) t))
         ((and large-file-warning-threshold size (> size large-file-warning-threshold))
          (cons (format "%s is too large to show (%s)." name (file-size-human-readable size)) t))
         (t
          (let* ((buffer (tandem-layout-file-buffer path))
                 (pos (and line (with-current-buffer buffer
                                  (save-restriction
                                    (widen)
                                    (save-excursion
                                      (goto-char (point-min))
                                      (forward-line (1- line))
                                      (point))))))
                 (shown (tandem-layout-show buffer :pos pos :session session))
                 (_ (when line
                      (tandem-layout-highlight buffer line (or end line))
                      (run-hook-with-args 'tandem-layout-shown-functions buffer line (or end line))))
                 (window (plist-get shown :window))
                 (at (if line (format " at line %d" line) "")))
            (pcase (plist-get shown :how)
              ('no-frame
               (cons (format "Opened %s in Emacs, but it is not shown: %s." name
                             tandem-layout--not-looking)
                     nil))
              ('full
               (cons (format "Opened %s in Emacs, but it is not shown: all %d windows are the \
user's to keep right now (in use, dedicated, or the chat)."
                             name (length (tandem-layout--windows
                                           (tandem-layout--frame session))))
                     nil))
              (how
               (let ((id (tandem-layout--id window))
                     (frame (window-frame window)))
                 (cons
                  (concat
                   (pcase how
                     ('visible (format "%s is shown in window %d" name id))
                     ('split (format "Showing %s in window %d, a new window Claude opened" name id))
                     ('reused (format "Showing %s in window %d, which showed %s before" name id
                                      (buffer-name (plist-get shown :before)))))
                   (cond
                    ((not line) ".")
                    ((plist-get shown :moved) (format ", now%s." at))
                    (t (format "; the user is working in that window, so it was not moved to line %d."
                               line)))
                   " " (tandem-layout--count-text frame))
                  nil)))))))))))

(defun tandem-layout--describe (window root)
  "Describe WINDOW for Claude; ROOT is the project directory."
  (let* ((buffer (window-buffer window))
         (file (buffer-file-name buffer))
         (whose (cond ((tandem-layout--chat-p window) "chat")
                      ((tandem-layout--claudes-p window) "Claude's")
                      (t "user's")))
         (what (if file (tandem-layout--name file root) (buffer-name buffer)))
         (lines (when file
                  (ignore-errors
                    (with-current-buffer buffer
                      (let* ((start (window-start window))
                             ;; `window-end' is exact on a display; without
                             ;; one (batch) it says point-max, so cap it.
                             (guess (save-excursion
                                      (goto-char start)
                                      (forward-line (1- (window-body-height window)))
                                      (point)))
                             (end (min guess (max start (1- (window-end window t))))))
                        (format ", lines %d-%d" (line-number-at-pos start) (line-number-at-pos end))))))))
    (format "[%d] %s: %s%s%s" (tandem-layout--id window) whose what (or lines "")
            (if (tandem-layout--yours-now-p window) " (the user is working here)" ""))))

(defun tandem-layout--list-windows (session root)
  "Run list_windows for SESSION, whose project is ROOT.  Return (TEXT . ERROR)."
  (if-let* ((frame (tandem-layout--frame session)))
      (let ((windows (tandem-layout--windows frame)))
        (cons (concat (format "The user's Emacs has %d windows (at most %d, at least %d stay open). \
Claude may close only windows marked Claude's.\n"
                              (length windows) tandem-max-windows tandem-min-windows)
                      (mapconcat (lambda (w) (tandem-layout--describe w root)) windows "\n"))
              nil))
    (cons (format "No windows to list: %s." tandem-layout--not-looking) nil)))

(defun tandem-layout--close-window (args session)
  "Run close_window with ARGS for SESSION.  Return (TEXT . ERROR)."
  (let* ((frame (tandem-layout--frame session))
         (id (plist-get args :window))
         (windows (and frame (tandem-layout--windows frame)))
         (window (seq-find (lambda (w) (eql (window-parameter w 'tandem-id) id)) windows)))
    (cond
     ((not frame) (cons (format "No window was closed: %s." tandem-layout--not-looking) t))
     ((not window) (cons (format "There is no window %s.  Call list_windows for the current ids." id) t))
     ((not (tandem-layout--claudes-p window))
      (cons (format "Window %d is %s, so it stays open; Claude can close only windows it opened."
                    id (if (tandem-layout--chat-p window) "the chat" "the user's"))
            t))
     ((tandem-layout--yours-now-p window)
      (cons (format "The user is working in window %d, so it stays open." id) t))
     ((<= (length windows) tandem-min-windows)
      (cons (format "Emacs keeps at least %d windows open, so window %d stays."
                    tandem-min-windows id)
            t))
     (t
      (condition-case err
          (progn (delete-window window)
                 (cons (format "Closed window %d. %s" id (tandem-layout--count-text frame)) nil))
        (error (cons (format "Emacs could not close window %d: %s" id (error-message-string err)) t)))))))

(defvar tandem-layout-tools
  (list (cons "open_file" #'tandem-layout--open-file)
        (cons "close_window" (lambda (args session _root) (tandem-layout--close-window args session)))
        (cons "list_windows" (lambda (_args session root) (tandem-layout--list-windows session root))))
  "Claude's Emacs tools: an alist from name to function.
Each function takes the call's ARGS, SESSION and project ROOT and
returns (TEXT . ERROR).")

(defun tandem-layout--run (tool args session root)
  "Run Claude's TOOL with ARGS for SESSION in project ROOT.
Return (TEXT . ERROR)."
  (if-let* ((fn (cdr (assoc tool tandem-layout-tools))))
      (funcall fn args session root)
    (cons (format "Emacs has no tool %s." tool) t)))

(defun tandem-layout--call (params)
  "Answer the tool call in PARAMS with tool/result."
  (pcase-let ((`(,text . ,error)
               (condition-case err
                   (tandem-layout--run (plist-get params :tool) (plist-get params :args)
                                            (plist-get params :sessionId) (plist-get params :root))
                 (error (cons (format "Emacs failed: %s" (error-message-string err)) t)))))
    (condition-case err
        (tandem-rpc-request 'tool/result
                                 (list :requestId (plist-get params :requestId)
                                       :text text :isError (if error t :json-false)))
      (error (message "tandem: could not answer Claude's %s: %s"
                      (plist-get params :tool) (error-message-string err))))))

(defun tandem-layout--on-notification (method params)
  "Handle `tool/call' with PARAMS; METHOD is the notification's name.
The work runs from a timer, out of the process filter."
  (when (eq method 'tool/call)
    (run-at-time 0 nil #'tandem-layout--call params)))

(add-hook 'tandem-rpc-notification-functions #'tandem-layout--on-notification)

;;;; Files

(defun tandem-layout-file-buffer (path)
  "Return a buffer visiting PATH, without running unsafe local variables."
  (or (find-buffer-visiting path)
      (let* ((enable-local-variables :safe)
             (inhibit-message t)
             (buffer (find-file-noselect path)))
        ;; A new file in a directory that does not exist yet is not
        ;; writable until the directory is made, which happens on saving.
        (unless (file-exists-p path)
          (with-current-buffer buffer
            (setq buffer-read-only nil)))
        buffer)))

(provide 'tandem-layout)
;;; tandem-layout.el ends here
