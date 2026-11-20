;;; claude-pair-popup.el --- A small popup on Claude's proposed hunks  -*- lexical-binding: t; -*-

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

;; When point rests in one of Claude's proposed hunks, or the mouse hovers
;; over one, a small popup opens next to it:
;;
;;   Claude · hunk 2 of 3 · geo.py
;;   [✓ Approve] C-c C-a   [✗ Reject…] C-c C-k   [@ Ask Claude…] C-c '
;;
;; In a graphical frame it is a child frame below the hunk (above it when
;; there is no room below) that never takes focus, so you keep typing where
;; you were.  In a terminal, where Emacs before 31 has no child frames, the
;; hunk's own banner line is the popup: it lights up while point is in the
;; hunk, and its "apply" and "reject" parts are buttons.  M-RET opens the
;; popup by hand.  It closes when point leaves the hunk or the hunk is
;; decided.

;;; Code:

(require 'claude-pair-review)
(require 'seq)
(require 'subr-x)

(defcustom claude-pair-popup-delay 0.3
  "Idle seconds in a hunk before its popup opens; nil opens it only on \\[claude-pair-popup-show]."
  :type '(choice (number :tag "Seconds") (const :tag "Only by hand" nil))
  :group 'claude-pair)

(defcustom claude-pair-popup-style 'auto
  "How the popup shows: `auto', `child-frame', `inline' or nil for never.
`auto' uses a child frame in graphical frames and the hunk's banner
line elsewhere; `inline' always uses the banner line."
  :type '(choice (const auto) (const child-frame) (const inline) (const :tag "Never" nil))
  :group 'claude-pair)

(defface claude-pair-popup
  '((t :inherit tooltip))
  "Face for the popup's background and text."
  :group 'claude-pair)

(defface claude-pair-popup-title
  '((t :inherit (bold claude-pair-popup)))
  "Face for the popup's first line."
  :group 'claude-pair)

(defface claude-pair-popup-button
  '((t :inherit (link claude-pair-popup) :underline nil :box (:line-width -1)))
  "Face for the popup's buttons."
  :group 'claude-pair)

(defvar claude-pair-popup--hunk nil
  "The hunk the popup is open for, or nil.")

(defvar claude-pair-popup--window nil
  "The window showing the hunk the popup is open for.")

(defvar claude-pair-popup--timer nil
  "Timer that opens the popup after `claude-pair-popup-delay'.")

(defvar claude-pair-popup--frames nil
  "Alist from parent frame to its popup child frame.")

(defconst claude-pair-popup--buffer-name " *claude-pair popup*"
  "Name of the buffer the child frame shows.")

;;;; Which kind

(defun claude-pair-popup--style (window)
  "Return how to show the popup for WINDOW: `child-frame', `inline' or nil."
  (pcase claude-pair-popup-style
    ('auto (if (display-graphic-p (window-frame window)) 'child-frame 'inline))
    ('child-frame (if (display-graphic-p (window-frame window)) 'child-frame 'inline))
    ('inline 'inline)
    (_ nil)))

;;;; Content

(defun claude-pair-popup--text (hunk)
  "Return the popup's text for HUNK."
  (let* ((proposal (gethash (claude-pair-review--hunk-id hunk) claude-pair-review--proposals))
         (total (length (plist-get proposal :hunks)))
         (title (format "Claude · %s · %s"
                        (if (> total 1)
                            (format "hunk %d of %d" (claude-pair-review--hunk-index hunk) total)
                          "proposed edit")
                        (file-name-nondirectory (plist-get proposal :path))))
         (apply (propertize (claude-pair-review-button "✓ Approve" claude-pair-review-apply-button-map hunk)
                            'face 'claude-pair-popup-button))
         (reject (propertize (claude-pair-review-button "✗ Reject…" claude-pair-review-reject-button-map hunk)
                             'face 'claude-pair-popup-button))
         (ask (propertize (claude-pair-review-button "@ Ask Claude…" claude-pair-review-ask-button-map hunk)
                          'face 'claude-pair-popup-button))
         (keys (lambda (k) (propertize k 'face '(shadow claude-pair-popup)))))
    (concat (propertize (concat " " title " ") 'face 'claude-pair-popup-title) "\n"
            " " apply " " (funcall keys "C-c C-a") "   "
            reject " " (funcall keys "C-c C-k") "   "
            ask " " (funcall keys "C-c '") " ")))

;;;; The child frame

(defun claude-pair-popup--buffer ()
  "Return the buffer the popup child frames show."
  (or (get-buffer claude-pair-popup--buffer-name)
      (with-current-buffer (get-buffer-create claude-pair-popup--buffer-name)
        (setq-local mode-line-format nil
                    header-line-format nil
                    tab-line-format nil
                    cursor-type nil
                    truncate-lines t
                    buffer-read-only t)
        ;; The whole popup, not only its text, in the popup's colours.
        (face-remap-add-relative 'default 'claude-pair-popup)
        (current-buffer))))

(defun claude-pair-popup--frame (parent)
  "Return the popup child frame of PARENT, making it if needed."
  (let ((frame (alist-get parent claude-pair-popup--frames)))
    (if (frame-live-p frame)
        frame
      ;; Other packages' frame hooks are for real frames, not this one.
      (let* ((after-make-frame-functions nil)
             (before-make-frame-hook nil)
             (frame (make-frame
                     `((parent-frame . ,parent)
                       (minibuffer . nil)
                       (visibility . nil)
                       (no-accept-focus . t)
                       (no-focus-on-map . t)
                       (undecorated . t)
                       (unsplittable . t)
                       (no-other-frame . t)
                       (skip-taskbar . t)
                       (desktop-dont-save . t)
                       (internal-border-width . 1)
                       (child-frame-border-width . 1)
                       (left-fringe . 0)
                       (right-fringe . 0)
                       (vertical-scroll-bars . nil)
                       (horizontal-scroll-bars . nil)
                       (menu-bar-lines . 0)
                       (tool-bar-lines . 0)
                       (tab-bar-lines . 0)
                       (line-spacing . 0)
                       (cursor-type . nil)
                       (no-special-glyphs . t)
                       (width . 40)
                       (height . 2)))))
        (let ((window (frame-root-window frame)))
          (set-window-buffer window (claude-pair-popup--buffer))
          (set-window-dedicated-p window t))
        (setf (alist-get parent claude-pair-popup--frames) frame)
        frame))))

(defun claude-pair-popup-place (window-top window-bottom below above height)
  "Return the y pixel position for a popup of HEIGHT pixels, or nil.
WINDOW-TOP and WINDOW-BOTTOM bound the window's text area.  BELOW is
the y of the line under the hunk and ABOVE the y of its banner line,
each nil when off screen.  Prefer below; never cover the hunk."
  (cond
   ((and below (<= (+ below height) window-bottom)) below)
   ((and above (>= (- above height) window-top)) (- above height))
   (t nil)))

(defun claude-pair-popup--y (window pos)
  "Return the frame-relative y pixel of the line of POS in WINDOW, or nil."
  (when-let* ((posn (posn-at-point pos window))
              (xy (posn-x-y posn)))
    (+ (nth 1 (window-inside-pixel-edges window)) (cdr xy))))

(defun claude-pair-popup--show-child-frame (hunk window)
  "Show HUNK's popup as a child frame of WINDOW's frame."
  (let* ((parent (window-frame window))
         (frame (claude-pair-popup--frame parent))
         (edges (window-inside-pixel-edges window))
         (line-height (frame-char-height parent))
         (entry (claude-pair-review--hunk-entry hunk))
         (last (max (claude-pair-review--hunk-end hunk)
                    (if entry (marker-position (nth 1 entry)) 0)))
         (start (overlay-start (claude-pair-review--hunk-banner hunk)))
         (buffer (window-buffer window))
         ;; The first line after the hunk: the popup's top goes there.
         (after (with-current-buffer buffer
                  (save-excursion (goto-char last)
                                  (if (and (bolp) (> (point) start)) (point)
                                    (min (point-max) (1+ (line-end-position)))))))
         ;; The line before the banner: the popup's bottom goes under it.
         (before (with-current-buffer buffer
                   (save-excursion (goto-char start)
                                   (and (zerop (forward-line -1)) (point)))))
         (below (and (pos-visible-in-window-p after window)
                     (claude-pair-popup--y window after)))
         (above (and before (pos-visible-in-window-p before window)
                     (when-let* ((y (claude-pair-popup--y window before)))
                       (+ y line-height)))))
    (with-current-buffer (claude-pair-popup--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (claude-pair-popup--text hunk))
        (goto-char (point-min))))
    ;; Follow the theme: the frame's own background shows around the text.
    (when-let* ((background (face-background 'claude-pair-popup nil t)))
      (unless (equal background (frame-parameter frame 'background-color))
        (set-frame-parameter frame 'background-color background)))
    (let* ((size (window-text-pixel-size (frame-root-window frame) nil nil 10000 10000))
           (width (+ (car size) (frame-char-width frame)))
           (height (cdr size))
           (border (* 2 (frame-internal-border-width frame)))
           (y (claude-pair-popup-place (nth 1 edges) (nth 3 edges) below above
                                       (+ height border))))
      (if (not y)
          (claude-pair-popup--hide-frames)
        (set-window-parameter (frame-root-window frame) 'claude-pair-popup-for window)
        ;; A window may not be shorter than `window-min-height' lines, which
        ;; would make a two-line popup four lines tall.
        (let ((window-min-height 1)
              (window-min-width 1))
          (set-frame-size frame width height t))
        (set-frame-position frame (nth 0 edges) y)
        (unless (frame-visible-p frame)
          (make-frame-visible frame))))))

(defun claude-pair-popup--hide-frames ()
  "Hide every popup child frame."
  (dolist (entry claude-pair-popup--frames)
    (when (and (frame-live-p (cdr entry)) (frame-visible-p (cdr entry)))
      (make-frame-invisible (cdr entry)))))

;;;; Showing and hiding

(defun claude-pair-popup--open (hunk window)
  "Open the popup for HUNK, shown in WINDOW."
  (when (and (eq (claude-pair-review--hunk-state hunk) 'pending)
             (window-live-p window))
    (unless (eq hunk claude-pair-popup--hunk)
      (claude-pair-popup-hide))
    (setq claude-pair-popup--hunk hunk
          claude-pair-popup--window window)
    (add-hook 'post-command-hook #'claude-pair-popup--elsewhere)
    (claude-pair-review-set-active hunk t)
    (when (eq (claude-pair-popup--style window) 'child-frame)
      (condition-case err
          (claude-pair-popup--show-child-frame hunk window)
        (error
         ;; The banner already is the popup; say why the frame did not show.
         (message "claude-pair: could not show the popup: %s" (error-message-string err)))))))

(defun claude-pair-popup-hide ()
  "Close the popup."
  (interactive)
  (when (timerp claude-pair-popup--timer)
    (cancel-timer claude-pair-popup--timer)
    (setq claude-pair-popup--timer nil))
  (when claude-pair-popup--hunk
    (claude-pair-review-set-active claude-pair-popup--hunk nil))
  (setq claude-pair-popup--hunk nil
        claude-pair-popup--window nil)
  (remove-hook 'post-command-hook #'claude-pair-popup--elsewhere)
  (claude-pair-popup--hide-frames))

(defun claude-pair-popup--elsewhere ()
  "Close the popup once you work in a buffer without its hunk.
Installed globally only while the popup is open."
  (when (and claude-pair-popup--hunk
             (not (claude-pair-popup--clicking-p))
             (not (eq (current-buffer)
                      (marker-buffer (claude-pair-review--hunk-beg claude-pair-popup--hunk)))))
    (claude-pair-popup-hide)))

(defun claude-pair-popup-show ()
  "Open the popup for the hunk at point now."
  (interactive)
  (let ((hunk (or (claude-pair-review--hunk-at-point)
                  (user-error "Point is not on a hunk Claude proposed"))))
    (if (claude-pair-popup--style (selected-window))
        (claude-pair-popup--open hunk (selected-window))
      (user-error "The popup is turned off (`claude-pair-popup-style')"))))

(defun claude-pair-popup--open-if-still-there (hunk window)
  "Open the popup for HUNK in WINDOW if point is still in it there."
  (setq claude-pair-popup--timer nil)
  (when (and (window-live-p window)
             (eq window (selected-window))
             (with-selected-window window
               (eq (claude-pair-review--hunk-at-point) hunk)))
    (claude-pair-popup--open hunk window)))

(defun claude-pair-popup--clicking-p ()
  "Return non-nil if the last input was the mouse, in a popup frame.
Then the popup must stay where it is, or the click turns into a drag."
  (and (mouse-event-p last-input-event)
       (let ((window (posn-window (event-start last-input-event))))
         (and (windowp window)
              (frame-parameter (window-frame window) 'parent-frame)))))

(defun claude-pair-popup--post-command ()
  "Open, move or close the popup to follow point into and out of hunks."
  (let ((hunk (claude-pair-review--hunk-at-point))
        (window (selected-window)))
    (cond
     ((claude-pair-popup--clicking-p) nil)
     ((null hunk)
      (when (and claude-pair-popup--hunk (eq claude-pair-popup--window window))
        (claude-pair-popup-hide)))
     ((eq hunk claude-pair-popup--hunk)
      ;; Same hunk: follow scrolling.
      (claude-pair-popup--open hunk window))
     ((and claude-pair-popup-delay (claude-pair-popup--style window))
      (claude-pair-popup-hide)
      (setq claude-pair-popup--timer
            (run-with-idle-timer claude-pair-popup-delay nil
                                 #'claude-pair-popup--open-if-still-there hunk window)))
     (t (claude-pair-popup-hide)))))

(defun claude-pair-popup--hover (window _object pos)
  "Open the popup for the hunk at POS in WINDOW; a `help-echo' function.
Return nil, so no tooltip shows.  The popup opens from a timer, since
this runs during redisplay."
  (when (and (window-live-p window) pos (claude-pair-popup--style window))
    (when-let* ((hunk (get-char-property pos 'claude-pair-hunk (window-buffer window))))
      (unless (eq hunk claude-pair-popup--hunk)
        (run-at-time 0 nil #'claude-pair-popup--open hunk window))))
  nil)

;;;; Wiring

(defun claude-pair-popup--on-show (proposal)
  "Watch point in PROPOSAL's buffer, and let the mouse open its popups."
  (with-current-buffer (plist-get proposal :buffer)
    (add-hook 'post-command-hook #'claude-pair-popup--post-command nil t))
  (dolist (hunk (plist-get proposal :hunks))
    (dolist (ov (claude-pair-review--hunk-overlays hunk))
      (when (overlay-get ov 'claude-pair-hunk)
        (overlay-put ov 'help-echo #'claude-pair-popup--hover)))))

(defun claude-pair-popup--on-settle (hunk)
  "Close the popup if it was open for HUNK."
  (when (eq hunk claude-pair-popup--hunk)
    (claude-pair-popup-hide)))

(add-hook 'claude-pair-review-show-functions #'claude-pair-popup--on-show)
(add-hook 'claude-pair-review-settle-functions #'claude-pair-popup--on-settle)
(keymap-set claude-pair-review-hunk-map "M-RET" #'claude-pair-popup-show)

(provide 'claude-pair-popup)
;;; claude-pair-popup.el ends here
