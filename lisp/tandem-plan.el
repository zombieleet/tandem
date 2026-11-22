;;; tandem-plan.el --- Claude's plan, in Org, for you to edit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience, outlines
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

;; M-x tandem-plan, or /plan in the chat, gives Claude a task in plan
;; mode: Claude reads what it needs and writes a plan, but changes nothing.
;; The plan opens in an Org buffer.  Edit it as you like: reorder steps,
;; cut some, add your own.  C-c C-c tells Claude to go ahead with your
;; version; C-c C-k says no, with a reason.  Claude then leaves plan mode and
;; works from the plan you approved; its edits still come to you for review.
;;
;; A plan Claude proposes while you are in plan mode by other means opens
;; the same way.

;;; Code:

(require 'tandem-chat)
(require 'tandem-markdown)
(require 'subr-x)

(declare-function org-mode "org")

(defvar-local tandem-plan--request nil
  "The permission request this plan buffer answers.")

(defvar-local tandem-plan--chat nil
  "The chat buffer whose plan this is.")

(defvar tandem-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-c" #'tandem-plan-approve)
    (keymap-set map "C-c C-k" #'tandem-plan-reject)
    map)
  "Keymap of `tandem-plan-mode'.")

(define-minor-mode tandem-plan-mode
  "Claude's plan, in an Org buffer for you to edit.
\\<tandem-plan-mode-map>\\[tandem-plan-approve] lets Claude go ahead with the plan as it is \
now; \\[tandem-plan-reject] says no."
  :lighter " Plan"
  (when tandem-plan-mode
    (setq-local header-line-format
                (substitute-command-keys
                 "Claude's plan: edit it, then \\<tandem-plan-mode-map>\\[tandem-plan-approve] \
to go ahead, \\[tandem-plan-reject] to say no"))))

(defun tandem-plan--buffer-name (chat)
  "Return the name of the plan buffer for CHAT."
  (format "*tandem plan: %s*"
          (file-name-nondirectory (directory-file-name (buffer-local-value 'tandem-chat--root chat)))))

(defun tandem-plan--show (update)
  "Open the plan in the ExitPlanMode question UPDATE for you to edit."
  (require 'org)
  (let* ((chat (current-buffer))
         (given (plist-get (plist-get update :input) :plan))
         ;; Claude Code 2.1 sends no plan: Claude wrote it in its reply.
         (plan (if (and (stringp given) (not (string-blank-p given)))
                   given
                 (apply #'concat (reverse tandem-chat--turn-text))))
         (buffer (get-buffer-create (tandem-plan--buffer-name chat))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (tandem-markdown-to-org plan 0) "\n")
        (goto-char (point-min))
        (set-buffer-modified-p nil))
      (tandem-plan-mode 1)
      (setq tandem-plan--request (plist-get update :requestId)
            tandem-plan--chat chat))
    (tandem-plan--display buffer chat)
    buffer))

(defun tandem-plan--display (buffer chat)
  "Show the plan BUFFER beside CHAT, and select it if you are in the chat.
A chat in another tab is left alone; the message says where it is."
  (when-let* ((chat-window (get-buffer-window chat)))
    (let ((window (with-selected-window chat-window
                    (display-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window)
                                             (inhibit-same-window . t))))))
      ;; You were waiting in the chat: the plan is where you type next.
      (when (and window (eq (selected-window) chat-window))
        (select-window window)))))

(defun tandem-plan-open (request)
  "Open the plan of permission REQUEST for you to edit, and select it."
  (let ((buffer (seq-find (lambda (b) (equal (buffer-local-value 'tandem-plan--request b) request))
                          (buffer-list))))
    (unless buffer
      (user-error "The plan is gone; ask Claude again"))
    (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window)
                            (inhibit-same-window . t)))
    (message "%s" (substitute-command-keys
                   "Edit Claude's plan, then \\<tandem-plan-mode-map>\\[tandem-plan-approve] \
to go ahead or \\[tandem-plan-reject] to say no"))
    buffer))

(defun tandem-plan--close (request)
  "Close the plan buffer that answers REQUEST, if there is one."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (equal (buffer-local-value 'tandem-plan--request buffer) request))
      (with-current-buffer buffer
        (setq tandem-plan--request nil)
        (set-buffer-modified-p nil))
      (quit-windows-on buffer t))))

(defun tandem-plan--on-permission (update)
  "Open or close a plan buffer for the permission UPDATE, if it is a plan."
  (let ((state (plist-get update :state)))
    (cond
     ((and (equal state "pending") (equal (plist-get update :toolName) "ExitPlanMode"))
      (tandem-plan--show update))
     ((member state '("answered" "withdrawn"))
      (tandem-plan--close (plist-get update :requestId))))))

(defun tandem-plan--check ()
  "Signal an error unless this is a plan buffer with a question open."
  (unless (and tandem-plan-mode tandem-plan--request)
    (user-error "This buffer holds no plan waiting for an answer")))

(defun tandem-plan-approve ()
  "Let Claude go ahead with the plan as it is in this buffer."
  (interactive)
  (tandem-plan--check)
  (let ((plan (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (request tandem-plan--request))
    (when (string-empty-p plan)
      (user-error "The plan is empty; C-c C-k to say no instead"))
    (tandem-chat--answer request "allow" nil nil (list :plan plan))
    (message "tandem: Claude goes ahead with your plan")))

(defun tandem-plan-reject (reason)
  "Tell Claude no to this plan, with REASON."
  (interactive (progn (tandem-plan--check)
                      (list (read-string "Why not (Claude reads this): "))))
  (tandem-plan--check)
  (tandem-chat--answer tandem-plan--request "deny" nil
                            (if (string-blank-p reason)
                                "The user did not accept the plan."
                              (concat "The user did not accept the plan: " reason))))

;;;###autoload
(defun tandem-plan (task)
  "Give Claude TASK in plan mode, to plan it without changing anything.
The plan opens in an Org buffer for you to edit before Claude goes
ahead."
  (interactive (list (read-string "Task for Claude to plan: ")))
  (when (string-blank-p task)
    (user-error "Say what Claude should plan"))
  (let ((chat (if (derived-mode-p 'tandem-chat-mode)
                  (current-buffer)
                (tandem))))
    (with-current-buffer chat
      (tandem-chat--send-to-claude task "plan"))
    chat))

(defun tandem-plan--send (text)
  "Run /plan TASK from the chat; return non-nil if TEXT is it."
  (when (string-match "\\`/plan\\(?:[ \t\n]+\\(\\(?:.\\|\n\\)*\\)\\)?\\'" text)
    (let ((task (string-trim (or (match-string 1 text) ""))))
      (when (string-empty-p task)
        (user-error "Write the task after /plan"))
      (tandem-chat--set-input "")
      (tandem-chat--send-to-claude task "plan")
      t)))

(add-hook 'tandem-chat-permission-functions #'tandem-plan--on-permission)
(setq tandem-chat-plan-open-function #'tandem-plan-open)
(add-hook 'tandem-chat-send-functions #'tandem-plan--send)

(provide 'tandem-plan)
;;; tandem-plan.el ends here
