;;; tandem-dashboard.el --- Every hunk waiting for you, in one list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
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

;; M-x tandem-review lists every hunk Claude proposed that waits for
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

(require 'tandem-review)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defconst tandem-dashboard--buffer-name "*tandem review*"
  "Name of the dashboard buffer.")

(defvar-keymap tandem-dashboard-mode-map
  :doc "Keys in the list of hunks waiting for you."
  :parent tabulated-list-mode-map
  "RET" #'tandem-dashboard-show
  "o" #'tandem-dashboard-show
  "a" #'tandem-dashboard-apply
  "r" #'tandem-dashboard-reject
  "?" #'tandem-dashboard-ask
  "A" #'tandem-dashboard-apply-edit
  "R" #'tandem-dashboard-reject-edit)

(define-derived-mode tandem-dashboard-mode tabulated-list-mode "Claude review"
  "Major mode listing the hunks Claude proposed that wait for you.
\\{tandem-dashboard-mode-map}"
  (setq tabulated-list-format
        [("File" 32 t)
         ("Hunk" 7 nil)
         ("Line" 6 tandem-dashboard--by-line :right-align t)
         ("Change" 9 nil)
         ("Chat" 9 t)
         ("Waiting" 9 nil)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'tandem-dashboard--fill nil t)
  (tabulated-list-init-header))

(defun tandem-dashboard--age (seconds)
  "Say how long SECONDS is, briefly."
  (cond ((< seconds 60) (format "%d s" seconds))
        ((< seconds 3600) (format "%d min" (/ seconds 60)))
        (t (format "%d h" (/ seconds 3600)))))

(defun tandem-dashboard--line (hunk)
  "Return the number of the line HUNK begins on now."
  (let ((beg (tandem-review--hunk-beg hunk)))
    (if (marker-buffer beg)
        (with-current-buffer (marker-buffer beg)
          (line-number-at-pos (min beg (tandem-review--hunk-end hunk)) t))
      (tandem-review--hunk-line hunk))))

(defun tandem-dashboard--by-line (a b)
  "Return non-nil if entry A's line comes before entry B's."
  (< (string-to-number (aref (cadr a) 2)) (string-to-number (aref (cadr b) 2))))

(defun tandem-dashboard--entries ()
  "Return the dashboard's entries: one per waiting hunk, oldest edit first."
  (let (proposals entries)
    (maphash (lambda (_id p) (push p proposals)) tandem-review--proposals)
    (setq proposals (sort proposals (lambda (a b) (< (or (plist-get a :shown) 0)
                                                     (or (plist-get b :shown) 0)))))
    (dolist (proposal proposals)
      (let ((total (length (plist-get proposal :hunks)))
            (age (tandem-dashboard--age
                  (floor (- (float-time) (or (plist-get proposal :shown) (float-time))))))
            (session (or (plist-get proposal :session) "")))
        (dolist (hunk (tandem-review--pending proposal))
          (push (list hunk
                      (vector (tandem-review--name proposal)
                              (format "%d/%d" (tandem-review--hunk-index hunk) total)
                              (number-to-string (tandem-dashboard--line hunk))
                              (format "−%d +%d"
                                      (length (tandem-review--lines (tandem-review--hunk-old hunk)))
                                      (length (tandem-review--lines (tandem-review--hunk-new hunk))))
                              (substring session 0 (min 8 (length session)))
                              (concat age (if (plist-get proposal :deferred) " ⧗" ""))))
                entries))))
    (nreverse entries)))

(defun tandem-dashboard--fill ()
  "Fill the dashboard with the hunks waiting now."
  (setq tabulated-list-entries (tandem-dashboard--entries)))

;;;###autoload
(defun tandem-review ()
  "List every hunk Claude proposed that waits for your decision."
  (interactive)
  (let ((buffer (get-buffer-create tandem-dashboard--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'tandem-dashboard-mode)
        (tandem-dashboard-mode))
      (tandem-dashboard--refresh))
    (pop-to-buffer buffer)
    (unless (tandem-dashboard--entries)
      (message "tandem: no hunk waits for your review"))))

(defun tandem-dashboard--refresh (&rest _)
  "List the waiting hunks again, if the dashboard is open."
  (when-let* ((buffer (get-buffer tandem-dashboard--buffer-name)))
    (with-current-buffer buffer
      (tandem-dashboard--fill)
      (tabulated-list-print t))))

(defun tandem-dashboard--refresh-soon (&rest _)
  "List the waiting hunks again once the current change is done."
  (when (get-buffer tandem-dashboard--buffer-name)
    (run-at-time 0 nil #'tandem-dashboard--refresh)))

(add-hook 'tandem-review-show-functions #'tandem-dashboard--refresh-soon)
(add-hook 'tandem-review-settle-functions #'tandem-dashboard--refresh-soon)

;;;; Acting on the hunk on this line

(defun tandem-dashboard--hunk ()
  "Return the waiting hunk on this line."
  (let ((hunk (tabulated-list-get-id)))
    (unless (and hunk (eq (tandem-review--hunk-state hunk) 'pending))
      (user-error "No waiting hunk on this line"))
    hunk))

(defun tandem-dashboard-show ()
  "Show the hunk on this line in its file."
  (interactive)
  (let* ((hunk (tandem-dashboard--hunk))
         (buffer (marker-buffer (tandem-review--hunk-beg hunk))))
    (pop-to-buffer buffer)
    (goto-char (overlay-start (tandem-review--hunk-banner hunk)))))

(defun tandem-dashboard-apply ()
  "Apply the hunk on this line."
  (interactive)
  (tandem-review-apply-this-hunk (tandem-dashboard--hunk))
  (tandem-dashboard--refresh))

(defun tandem-dashboard-reject ()
  "Reject the hunk on this line, asking why."
  (interactive)
  (tandem-review-reject-this-hunk (tandem-dashboard--hunk))
  (tandem-dashboard--refresh))

(defun tandem-dashboard-ask ()
  "Ask Claude about the hunk on this line."
  (interactive)
  (tandem-review-ask-this-hunk (tandem-dashboard--hunk))
  (tandem-dashboard--refresh))

(defun tandem-dashboard-apply-edit ()
  "Apply every waiting hunk of the edit the hunk on this line is part of."
  (interactive)
  (tandem-review-apply (tandem-review--hunk-id (tandem-dashboard--hunk)))
  (tandem-dashboard--refresh))

(defun tandem-dashboard-reject-edit ()
  "Reject every waiting hunk of the edit the hunk on this line is part of."
  (interactive)
  (tandem-review-reject (tandem-review--hunk-id (tandem-dashboard--hunk))
                             (read-string "Tell Claude why, or what to do instead (optional): "))
  (tandem-dashboard--refresh))

(provide 'tandem-dashboard)
;;; tandem-dashboard.el ends here
