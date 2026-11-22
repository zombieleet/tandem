;;; tandem-popup.el --- A small popup on Claude's proposed hunks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience
;; URL: https://github.com/victory/tandem

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

(require 'tandem-review)
(require 'seq)
(require 'subr-x)

(defcustom tandem-popup-delay 0.3
  "Idle seconds in a hunk before its popup opens; nil opens it only on \\[tandem-popup-show]."
  :type '(choice (number :tag "Seconds") (const :tag "Only by hand" nil))
  :group 'tandem)

(defcustom tandem-popup-style 'auto
  "How the popup shows: `auto', `child-frame', `inline' or nil for never.
`auto' uses a child frame in graphical frames and the hunk's banner
line elsewhere; `inline' always uses the banner line."
  :type '(choice (const auto) (const child-frame) (const inline) (const :tag "Never" nil))
  :group 'tandem)

(defface tandem-popup
  '((t :inherit tooltip))
  "Face for the popup's background and text."
  :group 'tandem)

(defface tandem-popup-title
  '((t :inherit (bold tandem-popup)))
  "Face for the popup's first line."
  :group 'tandem)

(defface tandem-popup-button
  '((t :inherit (link tandem-popup) :underline nil :box (:line-width -1)))
  "Face for the popup's buttons."
  :group 'tandem)

(defvar tandem-popup--hunk nil
  "The hunk the popup is open for, or nil.")

(defvar tandem-popup--window nil
  "The window showing the hunk the popup is open for.")

(defvar tandem-popup--timer nil
  "Timer that opens the popup after `tandem-popup-delay'.")

(defvar tandem-popup--frames nil
  "Alist from parent frame to its popup child frame.")

(defconst tandem-popup--buffer-name " *tandem popup*"
  "Name of the buffer the child frame shows.")

;;;; Which kind

(defun tandem-popup--style (window)
  "Return how to show the popup for WINDOW: `child-frame', `inline' or nil."
  (pcase tandem-popup-style
    ('auto (if (display-graphic-p (window-frame window)) 'child-frame 'inline))
    ('child-frame (if (display-graphic-p (window-frame window)) 'child-frame 'inline))
    ('inline 'inline)
    (_ nil)))

;;;; Content

(defun tandem-popup--text (hunk)
  "Return the popup's text for HUNK."
  (let* ((proposal (gethash (tandem-review--hunk-id hunk) tandem-review--proposals))
         (total (length (plist-get proposal :hunks)))
         (title (format "Claude · %s · %s"
                        (if (> total 1)
                            (format "hunk %d of %d" (tandem-review--hunk-index hunk) total)
                          "proposed edit")
                        (file-name-nondirectory (plist-get proposal :path))))
         (apply (propertize (tandem-review-button "✓ Approve" tandem-review-apply-button-map hunk)
                            'face 'tandem-popup-button))
         (reject (propertize (tandem-review-button "✗ Reject…" tandem-review-reject-button-map hunk)
                             'face 'tandem-popup-button))
         (ask (propertize (tandem-review-button "@ Ask Claude…" tandem-review-ask-button-map hunk)
                          'face 'tandem-popup-button))
         (keys (lambda (k) (propertize k 'face '(shadow tandem-popup)))))
    (concat (propertize (concat " " title " ") 'face 'tandem-popup-title) "\n"
            " " apply " " (funcall keys "C-c C-a") "   "
            reject " " (funcall keys "C-c C-k") "   "
            ask " " (funcall keys "C-c '") " ")))

;;;; The child frame

(defun tandem-popup--buffer ()
  "Return the buffer the popup child frames show."
  (or (get-buffer tandem-popup--buffer-name)
      (with-current-buffer (get-buffer-create tandem-popup--buffer-name)
        (setq-local mode-line-format nil
                    header-line-format nil
                    tab-line-format nil
                    cursor-type nil
                    truncate-lines t
                    buffer-read-only t)
        ;; The whole popup, not only its text, in the popup's colours.
        (face-remap-add-relative 'default 'tandem-popup)
        (current-buffer))))

(defun tandem-popup--frame (parent)
  "Return the popup child frame of PARENT, making it if needed."
  (let ((frame (alist-get parent tandem-popup--frames)))
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
          (set-window-buffer window (tandem-popup--buffer))
          (set-window-dedicated-p window t))
        (setf (alist-get parent tandem-popup--frames) frame)
        frame))))

(defun tandem-popup-place (window-top window-bottom below above height)
  "Return the y pixel position for a popup of HEIGHT pixels, or nil.
WINDOW-TOP and WINDOW-BOTTOM bound the window's text area.  BELOW is
the y of the line under the hunk and ABOVE the y of its banner line,
each nil when off screen.  Prefer below; never cover the hunk."
  (cond
   ((and below (<= (+ below height) window-bottom)) below)
   ((and above (>= (- above height) window-top)) (- above height))
   (t nil)))

(defun tandem-popup--y (window pos)
  "Return the frame-relative y pixel of the line of POS in WINDOW, or nil."
  (when-let* ((posn (posn-at-point pos window))
              (xy (posn-x-y posn)))
    (+ (nth 1 (window-inside-pixel-edges window)) (cdr xy))))

(defun tandem-popup--show-child-frame (hunk window)
  "Show HUNK's popup as a child frame of WINDOW's frame."
  (let* ((parent (window-frame window))
         (frame (tandem-popup--frame parent))
         (edges (window-inside-pixel-edges window))
         (line-height (frame-char-height parent))
         (entry (tandem-review--hunk-entry hunk))
         (last (max (tandem-review--hunk-end hunk)
                    (if entry (marker-position (nth 1 entry)) 0)))
         (start (overlay-start (tandem-review--hunk-banner hunk)))
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
                     (tandem-popup--y window after)))
         (above (and before (pos-visible-in-window-p before window)
                     (when-let* ((y (tandem-popup--y window before)))
                       (+ y line-height)))))
    (with-current-buffer (tandem-popup--buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (tandem-popup--text hunk))
        (goto-char (point-min))))
    ;; Follow the theme: the frame's own background shows around the text.
    (when-let* ((background (face-background 'tandem-popup nil t)))
      (unless (equal background (frame-parameter frame 'background-color))
        (set-frame-parameter frame 'background-color background)))
    (let* ((size (window-text-pixel-size (frame-root-window frame) nil nil 10000 10000))
           (width (+ (car size) (frame-char-width frame)))
           (height (cdr size))
           (border (* 2 (frame-internal-border-width frame)))
           (y (tandem-popup-place (nth 1 edges) (nth 3 edges) below above
                                       (+ height border))))
      (if (not y)
          (tandem-popup--hide-frames)
        (set-window-parameter (frame-root-window frame) 'tandem-popup-for window)
        ;; A window may not be shorter than `window-min-height' lines, which
        ;; would make a two-line popup four lines tall.
        (let ((window-min-height 1)
              (window-min-width 1))
          (set-frame-size frame width height t))
        (set-frame-position frame (nth 0 edges) y)
        (unless (frame-visible-p frame)
          (make-frame-visible frame))))))

(defun tandem-popup--hide-frames ()
  "Hide every popup child frame."
  (dolist (entry tandem-popup--frames)
    (when (and (frame-live-p (cdr entry)) (frame-visible-p (cdr entry)))
      (make-frame-invisible (cdr entry)))))

;;;; Showing and hiding

(defun tandem-popup--open (hunk window)
  "Open the popup for HUNK, shown in WINDOW."
  (when (and (eq (tandem-review--hunk-state hunk) 'pending)
             (window-live-p window))
    (unless (eq hunk tandem-popup--hunk)
      (tandem-popup-hide))
    (setq tandem-popup--hunk hunk
          tandem-popup--window window)
    (add-hook 'post-command-hook #'tandem-popup--elsewhere)
    (tandem-review-set-active hunk t)
    (when (eq (tandem-popup--style window) 'child-frame)
      (condition-case err
          (tandem-popup--show-child-frame hunk window)
        (error
         ;; The banner already is the popup; say why the frame did not show.
         (message "tandem: could not show the popup: %s" (error-message-string err)))))))

(defun tandem-popup-hide ()
  "Close the popup."
  (interactive)
  (when (timerp tandem-popup--timer)
    (cancel-timer tandem-popup--timer)
    (setq tandem-popup--timer nil))
  (when tandem-popup--hunk
    (tandem-review-set-active tandem-popup--hunk nil))
  (setq tandem-popup--hunk nil
        tandem-popup--window nil)
  (remove-hook 'post-command-hook #'tandem-popup--elsewhere)
  (tandem-popup--hide-frames))

(defun tandem-popup--elsewhere ()
  "Close the popup once you work in a buffer without its hunk.
Installed globally only while the popup is open."
  (when (and tandem-popup--hunk
             (not (tandem-popup--clicking-p))
             (not (eq (current-buffer)
                      (marker-buffer (tandem-review--hunk-beg tandem-popup--hunk)))))
    (tandem-popup-hide)))

(defun tandem-popup-show ()
  "Open the popup for the hunk at point now."
  (interactive)
  (let ((hunk (or (tandem-review--hunk-at-point)
                  (user-error "Point is not on a hunk Claude proposed"))))
    (if (tandem-popup--style (selected-window))
        (tandem-popup--open hunk (selected-window))
      (user-error "The popup is turned off (`tandem-popup-style')"))))

(defun tandem-popup--open-if-still-there (hunk window)
  "Open the popup for HUNK in WINDOW if point is still in it there."
  (setq tandem-popup--timer nil)
  (when (and (window-live-p window)
             (eq window (selected-window))
             (with-selected-window window
               (eq (tandem-review--hunk-at-point) hunk)))
    (tandem-popup--open hunk window)))

(defun tandem-popup--clicking-p ()
  "Return non-nil if the last input was the mouse, in a popup frame.
Then the popup must stay where it is, or the click turns into a drag."
  (and (mouse-event-p last-input-event)
       (let ((window (posn-window (event-start last-input-event))))
         (and (windowp window)
              (frame-parameter (window-frame window) 'parent-frame)))))

(defun tandem-popup--post-command ()
  "Open, move or close the popup to follow point into and out of hunks."
  (let ((hunk (tandem-review--hunk-at-point))
        (window (selected-window)))
    (cond
     ((tandem-popup--clicking-p) nil)
     ((null hunk)
      (when (and tandem-popup--hunk (eq tandem-popup--window window))
        (tandem-popup-hide)))
     ((eq hunk tandem-popup--hunk)
      ;; Same hunk: follow scrolling.
      (tandem-popup--open hunk window))
     ((and tandem-popup-delay (tandem-popup--style window))
      (tandem-popup-hide)
      (setq tandem-popup--timer
            (run-with-idle-timer tandem-popup-delay nil
                                 #'tandem-popup--open-if-still-there hunk window)))
     (t (tandem-popup-hide)))))

(defun tandem-popup--hover (window _object pos)
  "Open the popup for the hunk at POS in WINDOW; a `help-echo' function.
Return nil, so no tooltip shows.  The popup opens from a timer, since
this runs during redisplay."
  (when (and (window-live-p window) pos (tandem-popup--style window))
    (when-let* ((hunk (get-char-property pos 'tandem-hunk (window-buffer window))))
      (unless (eq hunk tandem-popup--hunk)
        (run-at-time 0 nil #'tandem-popup--open hunk window))))
  nil)

;;;; Wiring

(defun tandem-popup--on-show (proposal)
  "Watch point in PROPOSAL's buffer, and let the mouse open its popups."
  (with-current-buffer (plist-get proposal :buffer)
    (add-hook 'post-command-hook #'tandem-popup--post-command nil t))
  (dolist (hunk (plist-get proposal :hunks))
    (dolist (ov (tandem-review--hunk-overlays hunk))
      (when (overlay-get ov 'tandem-hunk)
        (overlay-put ov 'help-echo #'tandem-popup--hover)))))

(defun tandem-popup--on-settle (hunk)
  "Close the popup if it was open for HUNK."
  (when (eq hunk tandem-popup--hunk)
    (tandem-popup-hide)))

(add-hook 'tandem-review-show-functions #'tandem-popup--on-show)
(add-hook 'tandem-review-settle-functions #'tandem-popup--on-settle)
(keymap-set tandem-review-hunk-map "M-RET" #'tandem-popup-show)

(provide 'tandem-popup)
;;; tandem-popup.el ends here
