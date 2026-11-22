;;; tandem-suggest.el --- Claude suggests code as you type  -*- lexical-binding: t; -*-

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

;; M-x tandem-suggest-mode in a buffer, or M-x global-tandem-suggest-mode
;; for every programming buffer: when you stop typing for a moment
;; (`tandem-suggest-delay'), Claude suggests the code that comes next, in
;; grey at the cursor.  TAB inserts it; anything else you do goes on as
;; usual and the suggestion goes away, except typing what it starts with,
;; which keeps the rest.  M-x tandem-suggest-now asks at once.
;;
;; A suggestion takes two or three seconds: Claude Code runs a small model
;; (`tandem-suggest-model') with no tools, started ahead of time by the
;; daemon, with the code around the cursor.  Only a pause after you have
;; typed asks, not one after moving around; a newer request ends an older
;; one.  While Company's or Corfu's popup is open, no suggestion shows,
;; so TAB stays theirs.

;;; Code:

(require 'tandem-rpc)
(require 'tandem-chat)
(require 'tandem-ask)
(require 'subr-x)

(defgroup tandem-suggest nil
  "Code Claude suggests as you type."
  :group 'tandem)

(defvar tandem-suggest--timer nil
  "The idle timer that asks for suggestions.")

(defcustom tandem-suggest-delay 0.8
  "Seconds without typing before Claude is asked for a suggestion."
  :type 'number
  :set (lambda (symbol value)
         (set-default symbol value)
         ;; The timer starts again with the new delay.
         (when (timerp tandem-suggest--timer)
           (timer-set-idle-time tandem-suggest--timer value t))))

(defcustom tandem-suggest-model "claude-haiku-5-5"
  "The model suggestions use: a fast, cheap one."
  :type 'string)

(defcustom tandem-suggest-before 4000
  "How many characters before the cursor Claude sees."
  :type 'natnum)

(defcustom tandem-suggest-after 1500
  "How many characters after the cursor Claude sees."
  :type 'natnum)

(defface tandem-suggest
  '((t :inherit shadow))
  "Face of a suggestion not yet inserted.")

(defvar-keymap tandem-suggest-active-map
  :doc "Keys while a suggestion shows."
  "TAB" #'tandem-suggest-accept
  "<tab>" #'tandem-suggest-accept)

(defvar tandem-suggest-mode)

(defvar-local tandem-suggest--overlay nil
  "The overlay showing the suggestion, or nil.")

(defvar-local tandem-suggest--showing nil
  "Non-nil while a suggestion shows, so `tandem-suggest-active-map' applies.")

(defvar-local tandem-suggest--wanted nil
  "Non-nil when the last command typed, so a pause should ask.")

(defvar-local tandem-suggest--tick nil
  "The buffer's modification tick after the last command.")

(defvar tandem-suggest--emulation-alist
  `((tandem-suggest--showing . ,tandem-suggest-active-map))
  "Puts `tandem-suggest-active-map' before the major and minor modes' keys.")

(defvar tandem-suggest--token 0
  "The number of the newest request.")

(defvar tandem-suggest--pending nil
  "The request waiting for an answer: (TOKEN BUFFER POINT TICK), or nil.")

(defvar tandem-suggest--last-error nil
  "The last error shown, so the same one is not shown at every pause.")

;;;; Showing

(defun tandem-suggest--clear ()
  "Take away the suggestion shown in this buffer."
  (when tandem-suggest--overlay
    (delete-overlay tandem-suggest--overlay)
    (setq tandem-suggest--overlay nil))
  (setq tandem-suggest--showing nil))

(defun tandem-suggest--text ()
  "Return the suggestion shown in this buffer, or nil."
  (when tandem-suggest--overlay
    (overlay-get tandem-suggest--overlay 'tandem-suggest)))

(defun tandem-suggest--show (text)
  "Show TEXT as the suggestion at point, or nothing if TEXT is empty."
  (tandem-suggest--clear)
  (unless (string-empty-p text)
    (let ((overlay (make-overlay (point) (point) nil nil t))
          (shown (propertize text 'face 'tandem-suggest)))
      ;; The cursor stays before the suggestion, not after it.
      (put-text-property 0 1 'cursor t shown)
      (overlay-put overlay 'after-string shown)
      (overlay-put overlay 'tandem-suggest text)
      (overlay-put overlay 'priority 100)
      (setq tandem-suggest--overlay overlay
            tandem-suggest--showing t))))

(defun tandem-suggest--popup-open-p ()
  "Return non-nil while a completion popup owns TAB."
  (or (bound-and-true-p company-candidates)
      (bound-and-true-p completion-in-region-mode)))

(defun tandem-suggest--still-p (pending)
  "Return non-nil if the buffer and point are as when PENDING was asked."
  (pcase-let ((`(,_token ,buffer ,pos ,tick) pending))
    (and (buffer-live-p buffer)
         (eq (current-buffer) buffer)
         (= (point) pos)
         (= (buffer-chars-modified-tick) tick)
         (not (use-region-p))
         (not (tandem-suggest--popup-open-p)))))

(defun tandem-suggest--answer (token text)
  "Show TEXT, for request TOKEN, if that request still matters."
  (let ((pending tandem-suggest--pending))
    (when (and pending (equal (car pending) token)
               (buffer-live-p (nth 1 pending)))
      (with-current-buffer (nth 1 pending)
        (when (and tandem-suggest-mode
                   (eq (window-buffer (selected-window)) (current-buffer))
                   (tandem-suggest--still-p pending))
          (tandem-suggest--show text))))))

(defun tandem-suggest--on-notification (method params)
  "Show the suggestion so far from a suggest/text notification.
METHOD and PARAMS are the notification's."
  (when (eq method 'suggest/text)
    (tandem-suggest--answer (plist-get params :token) (plist-get params :text))))

(add-hook 'tandem-rpc-notification-functions #'tandem-suggest--on-notification)

;;;; Asking

(defun tandem-suggest--params (token)
  "Return the params of a suggest/complete request numbered TOKEN."
  (let ((pos (point)))
    (append
     (list :claudePath (tandem-chat--claude-path)
           :env (tandem-chat--environment)
           :token token
           :language (tandem-ask--language)
           :prefix (buffer-substring-no-properties (max (point-min) (- pos tandem-suggest-before)) pos)
           :suffix (buffer-substring-no-properties pos (min (point-max) (+ pos tandem-suggest-after))))
     (when tandem-suggest-model (list :model tandem-suggest-model))
     (when buffer-file-name (list :file (file-name-nondirectory buffer-file-name))))))

(defun tandem-suggest--ask ()
  "Ask Claude for a suggestion at point."
  (let* ((token (setq tandem-suggest--token (1+ tandem-suggest--token)))
         (pending (list token (current-buffer) (point) (buffer-chars-modified-tick))))
    (setq tandem-suggest--pending pending
          tandem-suggest--wanted nil)
    (force-mode-line-update)
    (condition-case err
        (tandem-rpc-async-request
         'suggest/complete (tandem-suggest--params token)
         (lambda (result)
           (tandem-suggest--answer (plist-get result :token) (plist-get result :text))
           (tandem-suggest--done token))
         (lambda (message)
           (tandem-suggest--done token)
           ;; A newer request ended it: nothing to say.
           (unless (string-match-p "replaced\\|cancelled" message)
             (tandem-suggest--report message))))
      (error
       (tandem-suggest--done token)
       (tandem-suggest--report (error-message-string err))))))

(defun tandem-suggest--done (token)
  "Forget request TOKEN if it is the one waiting."
  (when (equal (car tandem-suggest--pending) token)
    (setq tandem-suggest--pending nil)
    (force-mode-line-update t)))

(defun tandem-suggest--report (message)
  "Say MESSAGE, why there is no suggestion, unless it was just said."
  (unless (equal message tandem-suggest--last-error)
    (setq tandem-suggest--last-error message)
    (message "tandem: no suggestion: %s" message)))

(defun tandem-suggest--worth-asking-p ()
  "Return non-nil if asking for a suggestion at point is sensible now."
  (and tandem-suggest-mode
       (not buffer-read-only)
       (not (use-region-p))
       (not (minibufferp))
       (not (tandem-suggest--popup-open-p))
       ;; Not in the middle of a word.
       (not (and (char-after) (memq (char-syntax (char-after)) '(?w ?_))))))

(defun tandem-suggest--on-idle ()
  "After a pause, ask for a suggestion if the last command typed."
  (when (and tandem-suggest-mode tandem-suggest--wanted
             (null tandem-suggest--overlay)
             (tandem-suggest--worth-asking-p))
    (tandem-suggest--ask)))

(defconst tandem-suggest--not-typing
  '(undo undo-only undo-redo undo-tree-undo undo-tree-redo vundo revert-buffer
    yank-pop kill-region kill-line kill-whole-line)
  "Commands that change the buffer without being typing worth a suggestion.")

(defun tandem-suggest--typed-p ()
  "Return non-nil if the command just run changed the buffer by typing.
Any command that changed it counts, except undo and the like and
tandem's own commands, such as applying Claude's edits."
  (and this-command (symbolp this-command)
       (not (eq tandem-suggest--tick (buffer-chars-modified-tick)))
       (not (memq this-command tandem-suggest--not-typing))
       (not (string-prefix-p "tandem-" (symbol-name this-command)))))

(defun tandem-suggest--post-command ()
  "Keep, trim or take away the suggestion after a command, and note typing."
  (let ((text (tandem-suggest--text))
        (start (and tandem-suggest--overlay (overlay-start tandem-suggest--overlay))))
    (cond
     ((memq this-command '(tandem-suggest-accept tandem-suggest-now)))
     ;; Typing what the suggestion starts with keeps the rest.
     ((and text (eq this-command 'self-insert-command)
           (= (point) (1+ start))
           (eq (char-before) (aref text 0))
           (> (length text) 1))
      (tandem-suggest--show (substring text 1)))
     (text (tandem-suggest--clear)))
    (unless (memq this-command '(tandem-suggest-accept tandem-suggest-now))
      (setq tandem-suggest--wanted (and (null tandem-suggest--overlay) (tandem-suggest--typed-p))))
    (setq tandem-suggest--tick (buffer-chars-modified-tick))))

;;;; Commands

(defun tandem-suggest-accept ()
  "Insert the suggestion shown at point."
  (interactive)
  (if-let* ((text (tandem-suggest--text)))
      (progn
        (tandem-suggest--clear)
        (insert text))
    (tandem-suggest--clear)))

(defun tandem-suggest-now ()
  "Ask Claude for a suggestion at point now, without waiting for a pause."
  (interactive)
  (unless tandem-suggest-mode
    (user-error "Turn on `tandem-suggest-mode' first"))
  (tandem-suggest--clear)
  (setq tandem-suggest--last-error nil)
  (tandem-suggest--ask)
  (message "tandem: asking Claude for a suggestion…"))

(defun tandem-suggest--lighter ()
  "Return the mode line text: whether a suggestion is on its way."
  (if (and tandem-suggest--pending (eq (nth 1 tandem-suggest--pending) (current-buffer)))
      " ✦…"
    " ✦"))

;;;###autoload
(define-minor-mode tandem-suggest-mode
  "Show code Claude suggests when you pause typing; TAB inserts it.
See `tandem-suggest-delay' and `tandem-suggest-model'."
  :lighter (:eval (tandem-suggest--lighter))
  (if tandem-suggest-mode
      (progn
        (add-hook 'post-command-hook #'tandem-suggest--post-command nil t)
        (add-to-list 'emulation-mode-map-alists 'tandem-suggest--emulation-alist)
        (setq tandem-suggest--tick (buffer-chars-modified-tick))
        (unless tandem-suggest--timer
          (setq tandem-suggest--timer
                (run-with-idle-timer tandem-suggest-delay t #'tandem-suggest--on-idle))))
    (remove-hook 'post-command-hook #'tandem-suggest--post-command t)
    (tandem-suggest--clear)
    (setq tandem-suggest--wanted nil)))

(defun tandem-suggest--turn-on ()
  "Turn on `tandem-suggest-mode' in a programming buffer visiting a file."
  (when (and (derived-mode-p 'prog-mode) buffer-file-name)
    (tandem-suggest-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-tandem-suggest-mode tandem-suggest-mode
  tandem-suggest--turn-on
  :group 'tandem-suggest)

(provide 'tandem-suggest)
;;; tandem-suggest.el ends here
