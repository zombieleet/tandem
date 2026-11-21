;;; claude-pair-plan.el --- Claude's plan, in Org, for you to edit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Keywords: tools, convenience, outlines
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

;; M-x claude-pair-plan, or /plan in the chat, gives Claude a task in plan
;; mode: Claude reads what it needs and writes a plan, but changes nothing.
;; The plan opens in an Org buffer.  Edit it as you like: reorder steps,
;; cut some, add your own.  C-c C-c tells Claude to go ahead with your
;; version; C-c C-k says no, with a reason.  Claude then leaves plan mode and
;; works from the plan you approved; its edits still come to you for review.
;;
;; A plan Claude proposes while you are in plan mode by other means opens
;; the same way.

;;; Code:

(require 'claude-pair-chat)
(require 'claude-pair-markdown)
(require 'subr-x)

(declare-function org-mode "org")

(defvar-local claude-pair-plan--request nil
  "The permission request this plan buffer answers.")

(defvar-local claude-pair-plan--chat nil
  "The chat buffer whose plan this is.")

(defvar claude-pair-plan-mode-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "C-c C-c" #'claude-pair-plan-approve)
    (keymap-set map "C-c C-k" #'claude-pair-plan-reject)
    map)
  "Keymap of `claude-pair-plan-mode'.")

(define-minor-mode claude-pair-plan-mode
  "Claude's plan, in an Org buffer for you to edit.
\\<claude-pair-plan-mode-map>\\[claude-pair-plan-approve] lets Claude go ahead with the plan as it is \
now; \\[claude-pair-plan-reject] says no."
  :lighter " Plan"
  (when claude-pair-plan-mode
    (setq-local header-line-format
                (substitute-command-keys
                 "Claude's plan: edit it, then \\<claude-pair-plan-mode-map>\\[claude-pair-plan-approve] \
to go ahead, \\[claude-pair-plan-reject] to say no"))))

(defun claude-pair-plan--buffer-name (chat)
  "Return the name of the plan buffer for CHAT."
  (format "*claude-pair plan: %s*"
          (file-name-nondirectory (directory-file-name (buffer-local-value 'claude-pair-chat--root chat)))))

(defun claude-pair-plan--show (update)
  "Open the plan in the ExitPlanMode question UPDATE for you to edit."
  (require 'org)
  (let* ((chat (current-buffer))
         (given (plist-get (plist-get update :input) :plan))
         ;; Claude Code 2.1 sends no plan: Claude wrote it in its reply.
         (plan (if (and (stringp given) (not (string-blank-p given)))
                   given
                 (apply #'concat (reverse claude-pair-chat--turn-text))))
         (buffer (get-buffer-create (claude-pair-plan--buffer-name chat))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (claude-pair-markdown-to-org plan 0) "\n")
        (goto-char (point-min))
        (set-buffer-modified-p nil))
      (claude-pair-plan-mode 1)
      (setq claude-pair-plan--request (plist-get update :requestId)
            claude-pair-plan--chat chat))
    (claude-pair-plan--display buffer chat)
    buffer))

(defun claude-pair-plan--display (buffer chat)
  "Show the plan BUFFER beside CHAT, and select it if you are in the chat.
A chat in another tab is left alone; the message says where it is."
  (when-let* ((chat-window (get-buffer-window chat)))
    (let ((window (with-selected-window chat-window
                    (display-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window)
                                             (inhibit-same-window . t))))))
      ;; You were waiting in the chat: the plan is where you type next.
      (when (and window (eq (selected-window) chat-window))
        (select-window window)))))

(defun claude-pair-plan-open (request)
  "Open the plan of permission REQUEST for you to edit, and select it."
  (let ((buffer (seq-find (lambda (b) (equal (buffer-local-value 'claude-pair-plan--request b) request))
                          (buffer-list))))
    (unless buffer
      (user-error "The plan is gone; ask Claude again"))
    (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window)
                            (inhibit-same-window . t)))
    (message "%s" (substitute-command-keys
                   "Edit Claude's plan, then \\<claude-pair-plan-mode-map>\\[claude-pair-plan-approve] \
to go ahead or \\[claude-pair-plan-reject] to say no"))
    buffer))

(defun claude-pair-plan--close (request)
  "Close the plan buffer that answers REQUEST, if there is one."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (equal (buffer-local-value 'claude-pair-plan--request buffer) request))
      (with-current-buffer buffer
        (setq claude-pair-plan--request nil)
        (set-buffer-modified-p nil))
      (quit-windows-on buffer t))))

(defun claude-pair-plan--on-permission (update)
  "Open or close a plan buffer for the permission UPDATE, if it is a plan."
  (let ((state (plist-get update :state)))
    (cond
     ((and (equal state "pending") (equal (plist-get update :toolName) "ExitPlanMode"))
      (claude-pair-plan--show update))
     ((member state '("answered" "withdrawn"))
      (claude-pair-plan--close (plist-get update :requestId))))))

(defun claude-pair-plan--check ()
  "Signal an error unless this is a plan buffer with a question open."
  (unless (and claude-pair-plan-mode claude-pair-plan--request)
    (user-error "This buffer holds no plan waiting for an answer")))

(defun claude-pair-plan-approve ()
  "Let Claude go ahead with the plan as it is in this buffer."
  (interactive)
  (claude-pair-plan--check)
  (let ((plan (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (request claude-pair-plan--request))
    (when (string-empty-p plan)
      (user-error "The plan is empty; C-c C-k to say no instead"))
    (claude-pair-chat--answer request "allow" nil nil (list :plan plan))
    (message "claude-pair: Claude goes ahead with your plan")))

(defun claude-pair-plan-reject (reason)
  "Tell Claude no to this plan, with REASON."
  (interactive (progn (claude-pair-plan--check)
                      (list (read-string "Why not (Claude reads this): "))))
  (claude-pair-plan--check)
  (claude-pair-chat--answer claude-pair-plan--request "deny" nil
                            (if (string-blank-p reason)
                                "The user did not accept the plan."
                              (concat "The user did not accept the plan: " reason))))

;;;###autoload
(defun claude-pair-plan (task)
  "Give Claude TASK in plan mode, to plan it without changing anything.
The plan opens in an Org buffer for you to edit before Claude goes
ahead."
  (interactive (list (read-string "Task for Claude to plan: ")))
  (when (string-blank-p task)
    (user-error "Say what Claude should plan"))
  (let ((chat (if (derived-mode-p 'claude-pair-chat-mode)
                  (current-buffer)
                (claude-pair))))
    (with-current-buffer chat
      (claude-pair-chat--send-to-claude task "plan"))
    chat))

(defun claude-pair-plan--send (text)
  "Run /plan TASK from the chat; return non-nil if TEXT is it."
  (when (string-match "\\`/plan\\(?:[ \t\n]+\\(\\(?:.\\|\n\\)*\\)\\)?\\'" text)
    (let ((task (string-trim (or (match-string 1 text) ""))))
      (when (string-empty-p task)
        (user-error "Write the task after /plan"))
      (claude-pair-chat--set-input "")
      (claude-pair-chat--send-to-claude task "plan")
      t)))

(add-hook 'claude-pair-chat-permission-functions #'claude-pair-plan--on-permission)
(setq claude-pair-chat-plan-open-function #'claude-pair-plan-open)
(add-hook 'claude-pair-chat-send-functions #'claude-pair-plan--send)

(provide 'claude-pair-plan)
;;; claude-pair-plan.el ends here
