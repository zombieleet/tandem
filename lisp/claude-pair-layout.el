;;; claude-pair-layout.el --- The windows Claude works with  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience
;; URL: https://github.com/victory/claude-pair

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
;;   `M-x claude-pair' opens the chat in a tab of its own, named by
;;   `claude-pair-layout-tab', so your other tabs are never touched.
;; - At most `claude-pair-max-windows' windows, the chat included.  To
;;   show a file, Claude uses a window that already shows it, else splits
;;   the largest window, else, at the limit, reuses the window it used
;;   least recently.
;; - Windows Claude splits off are its own.  It can close only those, and
;;   never below `claude-pair-min-windows' windows.
;; - The focus guard: Claude never selects a window, never changes the
;;   window you are in, and leaves alone any window you used in the last
;;   `claude-pair-focus-guard-seconds' seconds.

;;; Code:

(require 'cl-lib)
(require 'claude-pair-rpc)
(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(defvar claude-pair-chat--buffers)

(defcustom claude-pair-max-windows 5
  "Most windows Claude's frame may have when Claude adds one.
The chat window counts.  Claude never splits beyond this; at the limit
it reuses a window instead.  Windows you make yourself are not limited."
  :type 'natnum
  :group 'claude-pair)

(defcustom claude-pair-min-windows 2
  "Fewest windows Claude leaves when it closes one, the chat included."
  :type 'natnum
  :group 'claude-pair)

(defcustom claude-pair-focus-guard-seconds 3
  "Seconds after you use a window during which Claude leaves it alone."
  :type 'number
  :group 'claude-pair)

(defcustom claude-pair-layout-tab "Claude"
  "Name of the tab `claude-pair' shows the chat in, or nil for the current tab.
Claude's windows live where its chat is, so with a tab of its own your
other tabs keep their layout."
  :type '(choice (const :tag "The current tab" nil) string)
  :group 'claude-pair)

(defvar claude-pair-layout--next-id 0
  "The last window id handed out.")

;;;; Setup

(defun claude-pair-layout-enable ()
  "Start noting the window you use, for the focus guard.
Also keep Claude's window marks when a window layout is saved and
restored, as when you switch tabs."
  (add-hook 'post-command-hook #'claude-pair-layout--note-use)
  (dolist (parameter '(claude-pair-owner claude-pair-id))
    (unless (assq parameter window-persistent-parameters)
      (push (cons parameter 'writable) window-persistent-parameters))))

(defun claude-pair-layout--note-use ()
  "Remember that you just used the selected window."
  (unless (window-minibuffer-p)
    (set-window-parameter nil 'claude-pair-used-by-you (float-time))))

(defun claude-pair-layout-enter-tab (buffer)
  "Switch to Claude's tab, unless BUFFER is visible in the current one.
The tab is named by `claude-pair-layout-tab'; nil means stay."
  (when (and claude-pair-layout-tab
             (not (get-buffer-window buffer))
             (not (equal (alist-get 'name (tab-bar--current-tab)) claude-pair-layout-tab)))
    (tab-bar-switch-to-tab claude-pair-layout-tab)))

(defun claude-pair-layout-elsewhere-p ()
  "Return non-nil if Claude's tab exists and you are in another tab.
Then Claude must not touch your windows, even to get your attention."
  (and claude-pair-layout-tab
       (not (equal (alist-get 'name (tab-bar--current-tab)) claude-pair-layout-tab))
       (seq-some (lambda (tab) (equal (alist-get 'name tab) claude-pair-layout-tab))
                 (funcall tab-bar-tabs-function))
       t))

(defun claude-pair-layout-where-text ()
  "Say where to find Claude's chat, for a message: its tab, if any."
  (if (claude-pair-layout-elsewhere-p)
      (format " (in the %s tab: C-x t o)" claude-pair-layout-tab)
    ""))

;;;; What Claude may touch

(defun claude-pair-layout--chat-window (session)
  "Return the window SESSION's chat is in, or nil."
  (when-let* ((buffer (and session (boundp 'claude-pair-chat--buffers)
                           (gethash session claude-pair-chat--buffers))))
    (and (buffer-live-p buffer) (get-buffer-window buffer t))))

(defun claude-pair-layout--frame (session &optional fallback)
  "Return the frame Claude works in for SESSION, the one with its chat.
When the chat is not shown, return the selected frame if FALLBACK is
non-nil, else nil."
  (if-let* ((window (claude-pair-layout--chat-window session)))
      (window-frame window)
    (and fallback (selected-frame))))

(defun claude-pair-layout--windows (frame)
  "Return FRAME's windows in a stable order, without the minibuffer."
  (window-list frame 'nomini (frame-first-window frame)))

(defun claude-pair-layout--chat-p (window)
  "Return non-nil if WINDOW is a claude-pair chat window."
  (provided-mode-derived-p (buffer-local-value 'major-mode (window-buffer window))
                           'claude-pair-chat-mode))

(defun claude-pair-layout--claudes-p (window)
  "Return non-nil if Claude opened WINDOW."
  (window-parameter window 'claude-pair-owner))

(defun claude-pair-layout--yours-now-p (window)
  "Return non-nil if you are working in WINDOW.
That is the window selected in its frame, the one the minibuffer
returns to, or one you used in the last few seconds."
  (or (eq window (frame-selected-window (window-frame window)))
      (eq window (minibuffer-selected-window))
      (< (- (float-time) (or (window-parameter window 'claude-pair-used-by-you) 0))
         claude-pair-focus-guard-seconds)))

(defun claude-pair-layout--plain-p (window)
  "Return non-nil if WINDOW is an ordinary window Claude could show a file in."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))
       (not (window-dedicated-p window))
       (not (claude-pair-layout--chat-p window))))

(defun claude-pair-layout--last-use (window)
  "Return when WINDOW was last used, by you or by Claude."
  (max (or (window-parameter window 'claude-pair-used-by-you) 0)
       (or (window-parameter window 'claude-pair-used-by-claude) 0)))

(defun claude-pair-layout--id (window)
  "Return WINDOW's id, the number Claude refers to it by."
  (or (window-parameter window 'claude-pair-id)
      (set-window-parameter window 'claude-pair-id
                            (cl-incf claude-pair-layout--next-id))))

;;;; Showing a buffer

(defun claude-pair-layout--split (frame)
  "Split a window of FRAME for Claude, if FRAME is under the limit.
Prefer the largest window you are not working in.  Return the new
window, or nil."
  (when (< (length (claude-pair-layout--windows frame)) claude-pair-max-windows)
    (let* ((area (lambda (w) (* (window-total-width w) (window-total-height w))))
           (candidates (seq-filter #'claude-pair-layout--plain-p (claude-pair-layout--windows frame)))
           (sorted (sort candidates
                         (lambda (a b)
                           (let ((ya (claude-pair-layout--yours-now-p a))
                                 (yb (claude-pair-layout--yours-now-p b)))
                             (if (eq ya yb) (> (funcall area a) (funcall area b)) yb))))))
      (seq-some (lambda (window)
                  ;; A character cell is about twice as tall as it is wide.
                  (let* ((wide (>= (window-total-width window) (* 2 (window-total-height window))))
                         (new (or (ignore-errors (split-window window nil (if wide 'right 'below)))
                                  (ignore-errors (split-window window nil (if wide 'below 'right))))))
                    (when new
                      (dolist (parameter '(claude-pair-id claude-pair-used-by-you claude-pair-used-by-claude))
                        (set-window-parameter new parameter nil))
                      new)))
                sorted))))

(defun claude-pair-layout--reusable (frame)
  "Return the window of FRAME Claude should reuse, or nil.
The least recently used of Claude's windows, else of yours, never one
you are working in."
  (let* ((windows (seq-remove #'claude-pair-layout--yours-now-p
                              (seq-filter #'claude-pair-layout--plain-p
                                          (claude-pair-layout--windows frame))))
         (claudes (seq-filter #'claude-pair-layout--claudes-p windows)))
    (car (sort (or claudes windows)
               (lambda (a b) (< (claude-pair-layout--last-use a) (claude-pair-layout--last-use b)))))))

(defun claude-pair-layout--scroll-to (window pos)
  "Put point at POS in WINDOW, about a quarter of the way down."
  (set-window-point window pos)
  (with-current-buffer (window-buffer window)
    (save-excursion
      (goto-char pos)
      (forward-line (- (/ (window-body-height window) 4)))
      (set-window-start window (line-beginning-position)))))

(cl-defun claude-pair-layout-show (buffer &key pos session fallback)
  "Show BUFFER for Claude's SESSION by the layout rules, at POS if given.
Use the frame where the session's chat is shown, or with FALLBACK the
selected frame.  Never select a window.  Return a plist: :window,
:how (`visible', `split' or `reused'; `no-frame' or `full' when not
shown), :moved (non-nil if the window now shows POS) and :before (the
buffer a reused window showed)."
  (let ((frame (claude-pair-layout--frame session fallback)))
    (if (not frame)
        (list :how 'no-frame)
      (let* ((showing (seq-filter #'window-live-p (get-buffer-window-list buffer 'nomini frame)))
             (window (or (seq-remove #'claude-pair-layout--yours-now-p showing) showing))
             (window (car window))
             (how (and window 'visible))
             before)
        (unless window
          (if (setq window (claude-pair-layout--split frame))
              (progn (setq how 'split)
                     (set-window-parameter window 'claude-pair-owner (or session t)))
            (when (setq window (claude-pair-layout--reusable frame))
              (setq how 'reused))))
        (if (not window)
            (list :how 'full)
          (unless (eq how 'visible)
            (setq before (window-buffer window))
            (set-window-buffer window buffer))
          (set-window-parameter window 'claude-pair-used-by-claude (float-time))
          (claude-pair-layout--id window)
          (let ((moved (and pos (not (claude-pair-layout--yours-now-p window))
                            (progn (claude-pair-layout--scroll-to window pos) t))))
            (list :window window :how how :moved moved :before before)))))))

;;;; Claude's tools

(defun claude-pair-layout--name (path root)
  "Return PATH relative to ROOT when it is inside, else abbreviated."
  (if (and root (file-in-directory-p path root))
      (file-relative-name path root)
    (abbreviate-file-name path)))

(defun claude-pair-layout--count-text (frame)
  "Say how many windows FRAME has, for Claude."
  (format "Windows: %d of at most %d."
          (length (claude-pair-layout--windows frame)) claude-pair-max-windows))

(defconst claude-pair-layout--not-looking
  "the user is not looking at the frame or tab with the chat right now"
  "Why nothing can be shown when the chat is not visible.")

(defun claude-pair-layout--open-file (args session root)
  "Run open_file with ARGS for SESSION, whose project is ROOT.
Return (TEXT . ERROR)."
  (let* ((path (plist-get args :path))
         (line (plist-get args :line))
         (line (and (natnump line) (> line 0) line)))
    (if (not (stringp path))
        (cons "open_file needs a path." t)
      (let ((name (claude-pair-layout--name path root))
            (size (file-attribute-size (file-attributes path))))
        (cond
         ((not (file-exists-p path)) (cons (format "There is no file %s." name) t))
         ((file-directory-p path) (cons (format "%s is a directory; open_file shows files." name) t))
         ((not (file-readable-p path)) (cons (format "Emacs cannot read %s." name) t))
         ((and large-file-warning-threshold size (> size large-file-warning-threshold))
          (cons (format "%s is too large to show (%s)." name (file-size-human-readable size)) t))
         (t
          (let* ((buffer (claude-pair-layout-file-buffer path))
                 (pos (and line (with-current-buffer buffer
                                  (save-restriction
                                    (widen)
                                    (save-excursion
                                      (goto-char (point-min))
                                      (forward-line (1- line))
                                      (point))))))
                 (shown (claude-pair-layout-show buffer :pos pos :session session))
                 (window (plist-get shown :window))
                 (at (if line (format " at line %d" line) "")))
            (pcase (plist-get shown :how)
              ('no-frame
               (cons (format "Opened %s in Emacs, but it is not shown: %s." name
                             claude-pair-layout--not-looking)
                     nil))
              ('full
               (cons (format "Opened %s in Emacs, but it is not shown: all %d windows are the \
user's to keep right now (in use, dedicated, or the chat)."
                             name (length (claude-pair-layout--windows
                                           (claude-pair-layout--frame session))))
                     nil))
              (how
               (let ((id (claude-pair-layout--id window))
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
                   " " (claude-pair-layout--count-text frame))
                  nil)))))))))))

(defun claude-pair-layout--describe (window root)
  "Describe WINDOW for Claude; ROOT is the project directory."
  (let* ((buffer (window-buffer window))
         (file (buffer-file-name buffer))
         (whose (cond ((claude-pair-layout--chat-p window) "chat")
                      ((claude-pair-layout--claudes-p window) "Claude's")
                      (t "user's")))
         (what (if file (claude-pair-layout--name file root) (buffer-name buffer)))
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
    (format "[%d] %s: %s%s%s" (claude-pair-layout--id window) whose what (or lines "")
            (if (claude-pair-layout--yours-now-p window) " (the user is working here)" ""))))

(defun claude-pair-layout--list-windows (session root)
  "Run list_windows for SESSION, whose project is ROOT.  Return (TEXT . ERROR)."
  (if-let* ((frame (claude-pair-layout--frame session)))
      (let ((windows (claude-pair-layout--windows frame)))
        (cons (concat (format "The user's Emacs has %d windows (at most %d, at least %d stay open). \
Claude may close only windows marked Claude's.\n"
                              (length windows) claude-pair-max-windows claude-pair-min-windows)
                      (mapconcat (lambda (w) (claude-pair-layout--describe w root)) windows "\n"))
              nil))
    (cons (format "No windows to list: %s." claude-pair-layout--not-looking) nil)))

(defun claude-pair-layout--close-window (args session)
  "Run close_window with ARGS for SESSION.  Return (TEXT . ERROR)."
  (let* ((frame (claude-pair-layout--frame session))
         (id (plist-get args :window))
         (windows (and frame (claude-pair-layout--windows frame)))
         (window (seq-find (lambda (w) (eql (window-parameter w 'claude-pair-id) id)) windows)))
    (cond
     ((not frame) (cons (format "No window was closed: %s." claude-pair-layout--not-looking) t))
     ((not window) (cons (format "There is no window %s.  Call list_windows for the current ids." id) t))
     ((not (claude-pair-layout--claudes-p window))
      (cons (format "Window %d is %s, so it stays open; Claude can close only windows it opened."
                    id (if (claude-pair-layout--chat-p window) "the chat" "the user's"))
            t))
     ((claude-pair-layout--yours-now-p window)
      (cons (format "The user is working in window %d, so it stays open." id) t))
     ((<= (length windows) claude-pair-min-windows)
      (cons (format "Emacs keeps at least %d windows open, so window %d stays."
                    claude-pair-min-windows id)
            t))
     (t
      (condition-case err
          (progn (delete-window window)
                 (cons (format "Closed window %d. %s" id (claude-pair-layout--count-text frame)) nil))
        (error (cons (format "Emacs could not close window %d: %s" id (error-message-string err)) t)))))))

(defun claude-pair-layout--run (tool args session root)
  "Run Claude's TOOL with ARGS for SESSION in project ROOT.
Return (TEXT . ERROR)."
  (pcase tool
    ("open_file" (claude-pair-layout--open-file args session root))
    ("close_window" (claude-pair-layout--close-window args session))
    ("list_windows" (claude-pair-layout--list-windows session root))
    (_ (cons (format "Emacs has no tool %s." tool) t))))

(defun claude-pair-layout--call (params)
  "Answer the tool call in PARAMS with tool/result."
  (pcase-let ((`(,text . ,error)
               (condition-case err
                   (claude-pair-layout--run (plist-get params :tool) (plist-get params :args)
                                            (plist-get params :sessionId) (plist-get params :root))
                 (error (cons (format "Emacs failed: %s" (error-message-string err)) t)))))
    (condition-case err
        (claude-pair-rpc-request 'tool/result
                                 (list :requestId (plist-get params :requestId)
                                       :text text :isError (if error t :json-false)))
      (error (message "claude-pair: could not answer Claude's %s: %s"
                      (plist-get params :tool) (error-message-string err))))))

(defun claude-pair-layout--on-notification (method params)
  "Handle `tool/call' with PARAMS; METHOD is the notification's name.
The work runs from a timer, out of the process filter."
  (when (eq method 'tool/call)
    (run-at-time 0 nil #'claude-pair-layout--call params)))

(add-hook 'claude-pair-rpc-notification-functions #'claude-pair-layout--on-notification)

;;;; Files

(defun claude-pair-layout-file-buffer (path)
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

(provide 'claude-pair-layout)
;;; claude-pair-layout.el ends here
