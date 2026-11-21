;;; claude-pair-dashboard.el --- Every hunk waiting for you, in one list  -*- lexical-binding: t; -*-

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

;; M-x claude-pair-review lists every hunk Claude proposed that waits for
;; you, across files and chats: file, hunk, line, size of the change,
;; chat and how long it has waited.  It follows your decisions as you
;; make them, here or in the files.
;;
;;   RET, o   show the hunk in its file
;;   a        apply it            A   apply every hunk of its edit
;;   r        reject it           R   reject every hunk of its edit
;;   ?        ask Claude about it
;;   g        list again

;;; Code:

(require 'claude-pair-review)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defconst claude-pair-dashboard--buffer-name "*claude-pair review*"
  "Name of the dashboard buffer.")

(defvar-keymap claude-pair-dashboard-mode-map
  :doc "Keys in the list of hunks waiting for you."
  :parent tabulated-list-mode-map
  "RET" #'claude-pair-dashboard-show
  "o" #'claude-pair-dashboard-show
  "a" #'claude-pair-dashboard-apply
  "r" #'claude-pair-dashboard-reject
  "?" #'claude-pair-dashboard-ask
  "A" #'claude-pair-dashboard-apply-edit
  "R" #'claude-pair-dashboard-reject-edit)

(define-derived-mode claude-pair-dashboard-mode tabulated-list-mode "Claude review"
  "Major mode listing the hunks Claude proposed that wait for you.
\\{claude-pair-dashboard-mode-map}"
  (setq tabulated-list-format
        [("File" 32 t)
         ("Hunk" 7 nil)
         ("Line" 6 claude-pair-dashboard--by-line :right-align t)
         ("Change" 9 nil)
         ("Chat" 9 t)
         ("Waiting" 9 nil)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'claude-pair-dashboard--fill nil t)
  (tabulated-list-init-header))

(defun claude-pair-dashboard--age (seconds)
  "Say how long SECONDS is, briefly."
  (cond ((< seconds 60) (format "%d s" seconds))
        ((< seconds 3600) (format "%d min" (/ seconds 60)))
        (t (format "%d h" (/ seconds 3600)))))

(defun claude-pair-dashboard--line (hunk)
  "Return the number of the line HUNK begins on now."
  (let ((beg (claude-pair-review--hunk-beg hunk)))
    (if (marker-buffer beg)
        (with-current-buffer (marker-buffer beg)
          (line-number-at-pos (min beg (claude-pair-review--hunk-end hunk)) t))
      (claude-pair-review--hunk-line hunk))))

(defun claude-pair-dashboard--by-line (a b)
  "Return non-nil if entry A's line comes before entry B's."
  (< (string-to-number (aref (cadr a) 2)) (string-to-number (aref (cadr b) 2))))

(defun claude-pair-dashboard--entries ()
  "Return the dashboard's entries: one per waiting hunk, oldest edit first."
  (let (proposals entries)
    (maphash (lambda (_id p) (push p proposals)) claude-pair-review--proposals)
    (setq proposals (sort proposals (lambda (a b) (< (or (plist-get a :shown) 0)
                                                     (or (plist-get b :shown) 0)))))
    (dolist (proposal proposals)
      (let ((total (length (plist-get proposal :hunks)))
            (age (claude-pair-dashboard--age
                  (floor (- (float-time) (or (plist-get proposal :shown) (float-time))))))
            (session (or (plist-get proposal :session) "")))
        (dolist (hunk (claude-pair-review--pending proposal))
          (push (list hunk
                      (vector (claude-pair-review--name proposal)
                              (format "%d/%d" (claude-pair-review--hunk-index hunk) total)
                              (number-to-string (claude-pair-dashboard--line hunk))
                              (format "−%d +%d"
                                      (length (claude-pair-review--lines (claude-pair-review--hunk-old hunk)))
                                      (length (claude-pair-review--lines (claude-pair-review--hunk-new hunk))))
                              (substring session 0 (min 8 (length session)))
                              (concat age (if (plist-get proposal :deferred) " ⧗" ""))))
                entries))))
    (nreverse entries)))

(defun claude-pair-dashboard--fill ()
  "Fill the dashboard with the hunks waiting now."
  (setq tabulated-list-entries (claude-pair-dashboard--entries)))

;;;###autoload
(defun claude-pair-review ()
  "List every hunk Claude proposed that waits for your decision."
  (interactive)
  (let ((buffer (get-buffer-create claude-pair-dashboard--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'claude-pair-dashboard-mode)
        (claude-pair-dashboard-mode))
      (claude-pair-dashboard--refresh))
    (pop-to-buffer buffer)
    (unless (claude-pair-dashboard--entries)
      (message "claude-pair: no hunk waits for your review"))))

(defun claude-pair-dashboard--refresh (&rest _)
  "List the waiting hunks again, if the dashboard is open."
  (when-let* ((buffer (get-buffer claude-pair-dashboard--buffer-name)))
    (with-current-buffer buffer
      (claude-pair-dashboard--fill)
      (tabulated-list-print t))))

(defun claude-pair-dashboard--refresh-soon (&rest _)
  "List the waiting hunks again once the current change is done."
  (when (get-buffer claude-pair-dashboard--buffer-name)
    (run-at-time 0 nil #'claude-pair-dashboard--refresh)))

(add-hook 'claude-pair-review-show-functions #'claude-pair-dashboard--refresh-soon)
(add-hook 'claude-pair-review-settle-functions #'claude-pair-dashboard--refresh-soon)

;;;; Acting on the hunk on this line

(defun claude-pair-dashboard--hunk ()
  "Return the waiting hunk on this line."
  (let ((hunk (tabulated-list-get-id)))
    (unless (and hunk (eq (claude-pair-review--hunk-state hunk) 'pending))
      (user-error "No waiting hunk on this line"))
    hunk))

(defun claude-pair-dashboard-show ()
  "Show the hunk on this line in its file."
  (interactive)
  (let* ((hunk (claude-pair-dashboard--hunk))
         (buffer (marker-buffer (claude-pair-review--hunk-beg hunk))))
    (pop-to-buffer buffer)
    (goto-char (overlay-start (claude-pair-review--hunk-banner hunk)))))

(defun claude-pair-dashboard-apply ()
  "Apply the hunk on this line."
  (interactive)
  (claude-pair-review-apply-this-hunk (claude-pair-dashboard--hunk))
  (claude-pair-dashboard--refresh))

(defun claude-pair-dashboard-reject ()
  "Reject the hunk on this line, asking why."
  (interactive)
  (claude-pair-review-reject-this-hunk (claude-pair-dashboard--hunk))
  (claude-pair-dashboard--refresh))

(defun claude-pair-dashboard-ask ()
  "Ask Claude about the hunk on this line."
  (interactive)
  (claude-pair-review-ask-this-hunk (claude-pair-dashboard--hunk))
  (claude-pair-dashboard--refresh))

(defun claude-pair-dashboard-apply-edit ()
  "Apply every waiting hunk of the edit the hunk on this line is part of."
  (interactive)
  (claude-pair-review-apply (claude-pair-review--hunk-id (claude-pair-dashboard--hunk)))
  (claude-pair-dashboard--refresh))

(defun claude-pair-dashboard-reject-edit ()
  "Reject every waiting hunk of the edit the hunk on this line is part of."
  (interactive)
  (claude-pair-review-reject (claude-pair-review--hunk-id (claude-pair-dashboard--hunk))
                             (read-string "Tell Claude why, or what to do instead (optional): "))
  (claude-pair-dashboard--refresh))

(provide 'claude-pair-dashboard)
;;; claude-pair-dashboard.el ends here
