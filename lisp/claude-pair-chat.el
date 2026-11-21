;;; claude-pair-chat.el --- Chat with Claude in an Emacs buffer  -*- lexical-binding: t; -*-

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

;; One chat buffer per Claude session.  The buffer has a read-only
;; transcript and, after a "❯" prompt, a composer you type into:
;;
;;   C-c C-c   send the composer to Claude
;;   C-c C-k   stop Claude's current answer
;;   C-c C-p   answer Claude's oldest permission question
;;   M-p, M-n  step through earlier messages
;;
;; When Claude proposes an edit, it appears in the file's buffer (see
;; claude-pair-review.el) and as a block in the transcript, where y applies
;; it, n rejects it, d rejects it with a note and RET shows it.
;;
;; When Claude wants to run a command or use a tool that needs approval, the
;; request appears in the transcript.  With point on it, press y to allow
;; it once, a to always allow it in this project, n to deny it, or d to deny
;; it and tell Claude why.  Nothing is asked in the minibuffer behind your
;; back, so a stray keystroke elsewhere can never approve a command.
;;
;; Updates from the daemon are queued and drawn every
;; `claude-pair-chat-flush-interval' seconds, so long answers do not make
;; typing or redisplay stutter.  Claude's todo list, when it keeps one,
;; sits at the top of the buffer.

;;; Code:

(require 'claude-pair-layout)
(require 'claude-pair-rpc)
(require 'claude-pair-review)
(require 'project)
(require 'ring)
(require 'sh-script)
(require 'subr-x)

(defcustom claude-pair-claude-command nil
  "Path of the claude command, or nil to look for \"claude\" on variable `exec-path'."
  :type '(choice (const :tag "Find on exec-path" nil) file)
  :group 'claude-pair)

(defcustom claude-pair-environment-variables
  '("ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL"
    "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX"
    "AWS_PROFILE" "AWS_REGION" "CLOUD_ML_REGION" "ANTHROPIC_VERTEX_PROJECT_ID"
    "HTTPS_PROXY" "HTTP_PROXY" "NO_PROXY" "https_proxy" "http_proxy" "no_proxy")
  "Environment variables each new session takes from Emacs.
Claude Code reads its credentials and provider from these.  A new
session gets the value Emacs has now (see `getenv'), or the variable
removed if Emacs has none, whatever the daemon started with.  So after
\[setenv], a new chat (\[universal-argument] \[claude-pair]) uses the new value
without restarting the daemon.  Other variables come from the daemon,
which inherited them from the Emacs that started it."
  :type '(repeat string)
  :group 'claude-pair)

(defcustom claude-pair-model nil
  "Model for new sessions, such as \"opus\", or nil for Claude Code's default."
  :type '(choice (const :tag "Claude Code's default" nil) string)
  :group 'claude-pair)

(defcustom claude-pair-chat-flush-interval 0.04
  "Seconds between screen updates while Claude writes."
  :type 'number
  :group 'claude-pair)

(defcustom claude-pair-chat-window-width 0.38
  "Width of the chat window: a fraction of the frame, or a number of columns."
  :type 'number
  :group 'claude-pair)

(defcustom claude-pair-chat-history-size 100
  "Number of sent messages that \\[claude-pair-chat-previous-input] can recall."
  :type 'natnum
  :group 'claude-pair)

(defface claude-pair-chat-you '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the \"You\" label above your messages."
  :group 'claude-pair)

(defface claude-pair-chat-claude '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the \"Claude\" label above Claude's answers."
  :group 'claude-pair)

(defface claude-pair-chat-tool '((t :inherit shadow))
  "Face for tool call lines."
  :group 'claude-pair)

(defface claude-pair-chat-tool-error '((t :inherit error))
  "Face for the mark of a tool call that failed."
  :group 'claude-pair)

(defface claude-pair-chat-meta '((t :inherit shadow))
  "Face for durations, costs and notices."
  :group 'claude-pair)

(defface claude-pair-chat-error '((t :inherit error))
  "Face for errors in the transcript."
  :group 'claude-pair)

(defface claude-pair-chat-prompt '((t :inherit minibuffer-prompt))
  "Face for the prompt before the composer."
  :group 'claude-pair)

(defface claude-pair-chat-ask '((t :inherit warning :weight bold))
  "Face for a permission question from Claude."
  :group 'claude-pair)

(defface claude-pair-chat-keys '((t :inherit help-key-binding))
  "Face for the keys that answer a permission question."
  :group 'claude-pair)

(defconst claude-pair-chat--prompt "\n❯ "
  "Text between the transcript and the composer.")

(defvar claude-pair-chat--buffers (make-hash-table :test #'equal)
  "Map from session id to its chat buffer.")

(defvar-local claude-pair-chat--session-id nil "This buffer's session id.")
(defvar-local claude-pair-chat--root nil "Project directory of this session.")
(defvar-local claude-pair-chat--output nil "Marker where the transcript grows.")
(defvar-local claude-pair-chat--input nil "Marker at the start of the composer.")
(defvar-local claude-pair-chat--todo-end nil "Marker at the end of the todo block.")
(defvar-local claude-pair-chat--queue nil "Updates waiting to be drawn, newest first.")
(defvar-local claude-pair-chat--timer nil "Timer that draws queued updates.")
(defvar-local claude-pair-chat--state "idle" "What Claude is doing, as a short string.")
(defvar-local claude-pair-chat--tool nil "Name of the tool Claude is running.")
(defvar-local claude-pair-chat--model nil "Model name reported by Claude Code.")

(defvar-local claude-pair-chat--turns 0 "Number of messages sent in this chat.")
(defvar-local claude-pair-chat--cost 0 "Cost of the session so far, in US dollars.")
(defvar-local claude-pair-chat--tools nil "Map from tool call id to the marker of its status mark.")
(defvar-local claude-pair-chat--replying nil "Non-nil once Claude's answer to the last message has begun.")
(defvar-local claude-pair-chat--after-tool nil "Non-nil when the transcript ends with a tool line.")
(defvar-local claude-pair-chat--history nil "Ring of sent messages.")
(defvar-local claude-pair-chat--history-index nil "Position in the history ring, or nil.")
(defvar-local claude-pair-chat--permissions nil
  "Map from permission request id to a plist describing its block.")
(defvar-local claude-pair-chat--pending nil
  "Ids of unanswered permission requests, oldest first.")
(defvar-local claude-pair-chat--asked-at nil
  "Map from tool call id to when its permission question arrived.")
(defvar-local claude-pair-chat--waited nil
  "Map from tool call id to milliseconds its question waited for you.")
(defvar-local claude-pair-chat--refused nil
  "Tools whose question was denied or withdrawn in the current turn.")
(defvar-local claude-pair-chat--answering nil
  "Request id of the edit Claude is answering a question about, or nil.
Claude's text goes into that edit's note as well.")

(defvar-local claude-pair-chat--reviews nil
  "Ids of proposed edits waiting for a decision, oldest first.")
(defvar-local claude-pair-chat--edit-calls nil
  "Edit tool calls not yet finished, oldest first, as (ID . SHOWN).
SHOWN is non-nil once the call's edit block is in the transcript.")

(defconst claude-pair-chat--edit-tools '("mcp__emacs__edit_file" "mcp__emacs__write_file")
  "Claude's edit tools, which wait for your review.")

(defvar-keymap claude-pair-chat-edit-map
  :doc "Keys on a proposed edit in the chat transcript."
  "y" #'claude-pair-chat-apply-edit
  "n" #'claude-pair-chat-reject-edit
  "d" #'claude-pair-chat-reject-edit-with-reason
  "RET" #'claude-pair-chat-show-edit)

(defvar-keymap claude-pair-chat-permission-map
  :doc "Keys on a permission request in the chat transcript."
  "y" #'claude-pair-chat-allow
  "a" #'claude-pair-chat-allow-always
  "n" #'claude-pair-chat-deny
  "d" #'claude-pair-chat-deny-with-reason
  "RET" #'claude-pair-chat-answer-permission)

(defvar-keymap claude-pair-chat-mode-map
  "C-c C-c" #'claude-pair-chat-send
  "C-c C-k" #'claude-pair-chat-cancel
  "C-c C-p" #'claude-pair-chat-answer-permission
  "M-p" #'claude-pair-chat-previous-input
  "M-n" #'claude-pair-chat-next-input)

(define-derived-mode claude-pair-chat-mode text-mode "Claude"
  "Major mode for chatting with Claude.
Type after the prompt at the bottom and press \\[claude-pair-chat-send]."
  (setq-local header-line-format '(:eval (claude-pair-chat--header-line)))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

;;;; Starting a chat

(defun claude-pair-chat--project-root ()
  "Return the current project's directory, or `default-directory'."
  (directory-file-name
   (expand-file-name
    (if-let* ((project (project-current)))
        (project-root project)
      default-directory))))

(defun claude-pair-chat--claude-path ()
  "Return the absolute path of the claude command."
  (let ((path (or claude-pair-claude-command (executable-find "claude"))))
    (unless path
      (user-error "Cannot find claude; install Claude Code or set `claude-pair-claude-command'"))
    (expand-file-name path)))

(defun claude-pair-chat--buffer-for (root)
  "Return a live chat buffer for ROOT, or nil."
  (catch 'found
    (maphash (lambda (_id buffer)
               (when (and (buffer-live-p buffer)
                          (equal (buffer-local-value 'claude-pair-chat--root buffer) root))
                 (throw 'found buffer)))
             claude-pair-chat--buffers)
    nil))

(defun claude-pair-chat--create (root)
  "Start a session about ROOT and return its new chat buffer."
  (let* ((params (list :cwd root :claudePath (claude-pair-chat--claude-path)
                       :env (claude-pair-chat--environment)))
         (result
          (condition-case err
              (claude-pair-rpc-request
               'session/new
               (if claude-pair-model (append params (list :model claude-pair-model)) params)
               30)
            (jsonrpc-error
             (user-error "claude-pair: %s" (claude-pair-rpc-error-message err)))))
         (buffer (generate-new-buffer
                  (format "*claude-pair: %s*" (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (claude-pair-chat--setup (plist-get result :sessionId) root))
    buffer))

(defun claude-pair-chat--environment ()
  "Return `claude-pair-environment-variables' as Emacs has them now.
A plist from each name to its value, or nil (JSON null) for a variable
Emacs does not have."
  (let (env)
    (dolist (name claude-pair-environment-variables)
      (setq env (plist-put env (intern (concat ":" name)) (getenv name))))
    env))

(defun claude-pair-chat--display (buffer)
  "Show BUFFER in a side window on the right and select it.
Unless it is visible already, first switch to Claude's tab; see
`claude-pair-layout-tab'."
  (claude-pair-layout-enable)
  (claude-pair-layout-enter-tab buffer)
  (let ((window (display-buffer
                 buffer
                 `((display-buffer-in-side-window)
                   (side . right)
                   (slot . 0)
                   (window-width . ,claude-pair-chat-window-width)
                   (window-parameters . ((no-delete-other-windows . t)))))))
    (when window
      (select-window window))
    (with-current-buffer buffer
      (goto-char (point-max)))
    buffer))

;;;###autoload
(defun claude-pair (&optional new)
  "Chat with Claude about the current project.
Show this project's chat, or start one.  With prefix argument NEW,
always start a new session."
  (interactive "P")
  (let* ((root (claude-pair-chat--project-root))
         (buffer (unless new (claude-pair-chat--buffer-for root))))
    (claude-pair-chat--display (or buffer (claude-pair-chat--create root)))))

(defun claude-pair-chat--setup (session-id root)
  "Make the current buffer the chat for SESSION-ID about ROOT."
  (claude-pair-chat-mode)
  (setq claude-pair-chat--session-id session-id
        claude-pair-chat--root root
        claude-pair-chat--tools (make-hash-table :test #'equal)
        claude-pair-chat--permissions (make-hash-table :test #'equal)
        claude-pair-chat--asked-at (make-hash-table :test #'equal)
        claude-pair-chat--waited (make-hash-table :test #'equal)
        claude-pair-chat--history (make-ring claude-pair-chat-history-size))
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (erase-buffer)
    (setq claude-pair-chat--todo-end (copy-marker (point-min)))
    (insert (propertize
             (format "Ask Claude about %s.  C-c C-c sends, C-c C-k stops Claude.\n"
                     (abbreviate-file-name root))
             'face 'claude-pair-chat-meta 'read-only t 'front-sticky '(read-only)))
    (let ((prompt-start (point)))
      (insert (propertize claude-pair-chat--prompt
                          'face 'claude-pair-chat-prompt
                          'read-only t
                          'front-sticky '(read-only)
                          'rear-nonsticky '(read-only face)))
      ;; Made after the prompt is in, so the prompt does not push it along:
      ;; the transcript grows just before the prompt.
      (setq claude-pair-chat--output (copy-marker prompt-start t)))
    (setq claude-pair-chat--input (point-marker)))
  (setq buffer-undo-list nil)
  (when session-id
    (puthash session-id (current-buffer) claude-pair-chat--buffers))
  (add-hook 'kill-buffer-hook #'claude-pair-chat--on-kill nil t))

;;;; Commands

(defun claude-pair-chat--check-buffer ()
  "Signal an error unless the current buffer is a chat buffer."
  (unless (derived-mode-p 'claude-pair-chat-mode)
    (user-error "Not in a claude-pair chat buffer")))

(defun claude-pair-chat--busy-p ()
  "Return non-nil while Claude is working on an answer."
  (not (member claude-pair-chat--state '("idle" "disconnected"))))

(defun claude-pair-chat--input-text ()
  "Return the composer's text."
  (buffer-substring-no-properties claude-pair-chat--input (point-max)))

(defun claude-pair-chat--set-input (text)
  "Replace the composer's text with TEXT."
  (delete-region claude-pair-chat--input (point-max))
  (goto-char (point-max))
  (insert text))

(defun claude-pair-chat-session-info (session)
  "Return (:model MODEL :turn N) for SESSION's chat, or nil."
  (when-let* ((buffer (gethash session claude-pair-chat--buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (list :model claude-pair-chat--model :turn claude-pair-chat--turns
              :prompt (unless (ring-empty-p claude-pair-chat--history)
                        (truncate-string-to-width
                         (car (split-string (ring-ref claude-pair-chat--history 0) "\n"))
                         120 nil nil "…")))))))

(defun claude-pair-chat-send ()
  "Send the composer's text to Claude."
  (interactive)
  (claude-pair-chat--check-buffer)
  (let ((text (string-trim (claude-pair-chat--input-text))))
    (when (string-empty-p text)
      (user-error "Type a message after the prompt first"))
    (when (claude-pair-chat--busy-p)
      (user-error "Claude is still answering; C-c C-k stops it"))
    ;; Draw the message before sending, so it precedes any reply.
    (claude-pair-chat--enqueue (cons 'user text))
    (claude-pair-chat--flush)
    (setq claude-pair-chat--state "starting")
    (if (condition-case err
            (progn
              (claude-pair-rpc-request 'session/prompt
                                       (list :sessionId claude-pair-chat--session-id :text text))
              t)
          (jsonrpc-error
           (setq claude-pair-chat--state "idle")
           (claude-pair-chat--enqueue
            (cons 'notice (format "Not sent: %s" (claude-pair-rpc-error-message err))))
           (claude-pair-chat--flush)
           nil))
        (progn
          (setq claude-pair-chat--turns (1+ claude-pair-chat--turns))
          (ring-insert claude-pair-chat--history text)
          (setq claude-pair-chat--history-index nil)
          (claude-pair-chat--set-input "")
          (setq buffer-undo-list nil))
      (goto-char (point-max)))
    (force-mode-line-update)))

(defun claude-pair-chat-cancel ()
  "Stop Claude's current answer."
  (interactive)
  (claude-pair-chat--check-buffer)
  (if (not (claude-pair-chat--busy-p))
      (message "claude-pair: Claude is not answering")
    (let ((result (claude-pair-rpc-request 'session/cancel
                                           (list :sessionId claude-pair-chat--session-id))))
      (if (eq (plist-get result :cancelled) t)
          (setq claude-pair-chat--state "cancelling")
        (message "claude-pair: nothing to stop")))
    (force-mode-line-update)))

(defun claude-pair-chat-previous-input (n)
  "Put the Nth previous sent message in the composer."
  (interactive "p")
  (claude-pair-chat--check-buffer)
  (let ((size (ring-length claude-pair-chat--history)))
    (when (zerop size)
      (user-error "No earlier messages"))
    (setq claude-pair-chat--history-index
          (max 0 (min (1- size) (+ (or claude-pair-chat--history-index -1) n))))
    (claude-pair-chat--set-input
     (ring-ref claude-pair-chat--history claude-pair-chat--history-index))))

(defun claude-pair-chat-next-input (n)
  "Put the Nth next sent message in the composer, or empty it."
  (interactive "p")
  (claude-pair-chat--check-buffer)
  (let ((index (- (or claude-pair-chat--history-index 0) n)))
    (if (< index 0)
        (progn (setq claude-pair-chat--history-index nil)
               (claude-pair-chat--set-input ""))
      (setq claude-pair-chat--history-index index)
      (claude-pair-chat--set-input (ring-ref claude-pair-chat--history index)))))

;;;; Updates from the daemon

(defun claude-pair-chat--on-notification (method params)
  "Route a `session/update' notification with PARAMS to its chat buffer.
METHOD is the notification's name."
  (when (eq method 'session/update)
    (let ((buffer (gethash (plist-get params :sessionId) claude-pair-chat--buffers)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (claude-pair-chat--handle-update (plist-get params :update)))))))

(add-hook 'claude-pair-rpc-notification-functions #'claude-pair-chat--on-notification)

(defun claude-pair-chat--handle-update (update)
  "Record UPDATE, a plist from the daemon, and queue what it draws."
  (pcase (plist-get update :kind)
    ("status"
     (let ((state (plist-get update :state)))
       (setq claude-pair-chat--state (if (equal state "requesting") "running" state))))
    ("init"
     (setq claude-pair-chat--model (plist-get update :model)))
    ("text"
     (setq claude-pair-chat--state "writing")
     (when claude-pair-chat--answering
       (claude-pair-review-note-append claude-pair-chat--answering (plist-get update :delta)))
     (claude-pair-chat--enqueue (cons 'text (plist-get update :delta))))
    ("tool"
     (cond
      ;; An edit shows as its own block; a separate tool line would repeat it.
      ((member (plist-get update :name) claude-pair-chat--edit-tools)
       (claude-pair-chat--edit-call update))
      ((equal (plist-get update :status) "started")
       (setq claude-pair-chat--state "tool"
             claude-pair-chat--tool (plist-get update :name))
       (claude-pair-chat--enqueue
        (list 'tool-start (plist-get update :id) (plist-get update :title))))
      (t
       (setq claude-pair-chat--state "running")
       (let* ((id (plist-get update :id))
              (duration (unless (member (plist-get update :name) claude-pair-chat--edit-tools)
                          ;; An edit's time is mostly your review.
                          (plist-get update :durationMs)))
              (waited (gethash id claude-pair-chat--waited)))
         ;; Time spent waiting for your answer is not the tool's own time.
         (when (and (numberp duration) waited)
           (setq duration (max 0 (- duration waited)))
           (remhash id claude-pair-chat--waited))
         (claude-pair-chat--enqueue
          (list 'tool-end id (plist-get update :status) duration))))))
    ("todo"
     (claude-pair-chat--enqueue (cons 'todo (plist-get update :items))))
    ("result"
     (claude-pair-chat--stop-answering)
     (let ((cost (plist-get update :sessionCostUsd)))
       (when (numberp cost)
         (setq claude-pair-chat--cost cost)))
     (claude-pair-chat--enqueue (cons 'result update)))
    ("error"
     (claude-pair-chat--enqueue
      (list 'error (plist-get update :message) (plist-get update :stderr))))
    ("edit"
     (let ((id (plist-get update :requestId)))
       (when (equal (plist-get update :state) "question")
         ;; What Claude writes next answers the question.
         (claude-pair-chat--stop-answering)
         (setq claude-pair-chat--answering id))
       (if (equal (plist-get update :state) "pending")
           (progn
             ;; A new proposal ends the answer.
             (claude-pair-chat--stop-answering)
             (when-let* ((call (seq-find (lambda (c) (not (cdr c))) claude-pair-chat--edit-calls)))
               (setcdr call t))
             (setq claude-pair-chat--reviews (append claude-pair-chat--reviews (list id))
                   claude-pair-chat--state "reviewing")
             (claude-pair-chat--enqueue (cons 'edit update)))
         (setq claude-pair-chat--reviews (delete id claude-pair-chat--reviews))
         (when (and (null claude-pair-chat--reviews)
                    (equal claude-pair-chat--state "reviewing"))
           (setq claude-pair-chat--state "running"))
         (claude-pair-chat--enqueue (cons 'edit-done update)))))
    ("permission"
     (let ((id (plist-get update :requestId))
           (tool-use (plist-get update :toolUseId)))
       (if (equal (plist-get update :state) "pending")
           (progn
             (setq claude-pair-chat--pending (append claude-pair-chat--pending (list id))
                   claude-pair-chat--state "waiting")
             (when tool-use
               (puthash tool-use (float-time) claude-pair-chat--asked-at))
             (puthash id update claude-pair-chat--asked-at)
             (claude-pair-chat--enqueue (cons 'permission update))
             (claude-pair-chat--alert update))
         (let* ((asked (gethash id claude-pair-chat--asked-at))
                (tool-use (plist-get asked :toolUseId))
                (since (and tool-use (gethash tool-use claude-pair-chat--asked-at))))
           (when (numberp since)
             (puthash tool-use (round (* 1000 (- (float-time) since))) claude-pair-chat--waited)
             (remhash tool-use claude-pair-chat--asked-at))
           (remhash id claude-pair-chat--asked-at)
           (unless (and (equal (plist-get update :state) "answered")
                        (equal (plist-get update :decision) "allow"))
             (push (plist-get asked :toolName) claude-pair-chat--refused)))
         (setq claude-pair-chat--pending (delete id claude-pair-chat--pending))
         (when (and (null claude-pair-chat--pending)
                    (equal claude-pair-chat--state "waiting"))
           (setq claude-pair-chat--state "running"))
         (claude-pair-chat--enqueue (cons 'permission-done update))))))
  (force-mode-line-update))

(defun claude-pair-chat--edit-call (update)
  "Track the edit tool call in UPDATE.
Its line is drawn only if it ends without an edit block, for example
when the daemon refused a path outside the project."
  (let ((id (plist-get update :id)))
    (if (equal (plist-get update :status) "started")
        (setq claude-pair-chat--edit-calls (append claude-pair-chat--edit-calls (list (cons id nil)))
              claude-pair-chat--state "tool"
              claude-pair-chat--tool (plist-get update :name))
      (let ((call (assoc id claude-pair-chat--edit-calls)))
        (setq claude-pair-chat--edit-calls (delq call claude-pair-chat--edit-calls)
              claude-pair-chat--state (if claude-pair-chat--reviews "reviewing" "running"))
        (unless (cdr call)
          (claude-pair-chat--enqueue (list 'tool-start id (plist-get update :title)))
          (claude-pair-chat--enqueue (list 'tool-end id (plist-get update :status) nil)))))))

(defun claude-pair-chat--alert (update)
  "Make sure the user notices the permission question in UPDATE."
  (let ((buffer (current-buffer)))
    (unless (or (get-buffer-window buffer 'visible)
                ;; Your other tabs are never touched; the message says where.
                (claude-pair-layout-elsewhere-p))
      (display-buffer buffer
                      `((display-buffer-in-side-window)
                        (side . right) (slot . 0)
                        (window-width . ,claude-pair-chat-window-width)
                        (inhibit-switch-frame . t))))
    (message "claude-pair: Claude wants to %s %s.  In the chat%s, y allows, a always allows, n denies."
             (claude-pair-chat--verb (plist-get update :toolName))
             (claude-pair-chat--subject update)
             (claude-pair-layout-where-text))))

(defun claude-pair-chat--on-disconnect ()
  "Tell every chat buffer that the daemon connection closed."
  (maphash (lambda (_id buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq claude-pair-chat--state "disconnected")
                 (claude-pair-chat--enqueue
                  (cons 'notice "Disconnected from claude-paird.  Sending a message reconnects."))
                 (force-mode-line-update))))
           claude-pair-chat--buffers))

(add-hook 'claude-pair-rpc-disconnect-hook #'claude-pair-chat--on-disconnect)

(defun claude-pair-chat--on-kill ()
  "Close this buffer's session in the daemon."
  (when claude-pair-chat--timer
    (cancel-timer claude-pair-chat--timer))
  (when claude-pair-chat--session-id
    (remhash claude-pair-chat--session-id claude-pair-chat--buffers)
    (when (claude-pair-rpc-live-p)
      (ignore-errors
        (claude-pair-rpc-request 'session/close
                                 (list :sessionId claude-pair-chat--session-id) 3)))))

;;;; Drawing

(defun claude-pair-chat--enqueue (item)
  "Queue ITEM for drawing and make sure a flush is scheduled."
  (push item claude-pair-chat--queue)
  (unless claude-pair-chat--timer
    (setq claude-pair-chat--timer
          (run-at-time claude-pair-chat-flush-interval nil
                       #'claude-pair-chat--flush-buffer (current-buffer)))))

(defun claude-pair-chat--flush-buffer (buffer)
  "Draw what is queued in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (claude-pair-chat--flush))))

(defun claude-pair-chat--flush ()
  "Draw every queued update in order, joining adjacent pieces of text."
  (when claude-pair-chat--timer
    (cancel-timer claude-pair-chat--timer)
    (setq claude-pair-chat--timer nil))
  (let ((items (nreverse claude-pair-chat--queue)))
    (setq claude-pair-chat--queue nil)
    (while items
      (let ((item (pop items)))
        (pcase (car item)
          ('text
           (let ((text (cdr item)))
             (while (eq (car-safe (car items)) 'text)
               (setq text (concat text (cdr (pop items)))))
             (claude-pair-chat--draw-text text)))
          ('user (claude-pair-chat--draw-user (cdr item)))
          ('tool-start (apply #'claude-pair-chat--draw-tool-start (cdr item)))
          ('tool-end (apply #'claude-pair-chat--draw-tool-end (cdr item)))
          ('todo (claude-pair-chat--draw-todo (cdr item)))
          ('result (claude-pair-chat--draw-result (cdr item)))
          ('error (apply #'claude-pair-chat--draw-error (cdr item)))
          ('notice (claude-pair-chat--draw-notice (cdr item)))
          ('permission (claude-pair-chat--draw-permission (cdr item)))
          ('edit (claude-pair-chat--draw-edit (cdr item)))
          ('edit-done (claude-pair-chat--draw-edit-done (cdr item)))
          ('permission-done (claude-pair-chat--draw-permission-done (cdr item))))))))

(defalias 'claude-pair-chat--shift-undo #'claude-pair-review-shift-undo
  "Move undo positions past a transcript change.
See `claude-pair-review-shift-undo'.")

(defmacro claude-pair-chat--editing-transcript (&rest body)
  "Run BODY to edit the transcript without breaking composer undo."
  (declare (indent 0) (debug t))
  `(let ((before (marker-position claude-pair-chat--input)))
     (let ((inhibit-read-only t)
           (buffer-undo-list t))
       (save-excursion ,@body))
     (claude-pair-chat--shift-undo before (- (marker-position claude-pair-chat--input) before))))

(defun claude-pair-chat--read-only (string)
  "Return STRING marked read-only, so text cannot be typed into or beside it.
Faces are copied to `font-lock-face' as well, so modes that refontify
the buffer do not strip them."
  (let ((s (propertize string 'read-only t 'front-sticky '(read-only)))
        (pos 0))
    (while (< pos (length s))
      (let ((next (next-single-property-change pos 'face s (length s)))
            (face (get-text-property pos 'face s)))
        (when face
          (put-text-property pos next 'font-lock-face face s))
        (setq pos next)))
    s))

(defun claude-pair-chat--insert (&rest strings)
  "Add STRINGS, read-only, at the end of the transcript."
  (claude-pair-chat--editing-transcript
    (goto-char claude-pair-chat--output)
    (dolist (s strings)
      (insert (claude-pair-chat--read-only s)))))

(defun claude-pair-chat--fresh-line ()
  "Start a new transcript line unless one has just started."
  (unless (memq (char-before claude-pair-chat--output) '(?\n nil))
    (claude-pair-chat--insert "\n")))

(defun claude-pair-chat--ensure-reply ()
  "Add the \"Claude\" label unless Claude's answer has already begun."
  (unless claude-pair-chat--replying
    (claude-pair-chat--fresh-line)
    (claude-pair-chat--insert "\n" (propertize "Claude" 'face 'claude-pair-chat-claude) "\n")
    (setq claude-pair-chat--replying t
          claude-pair-chat--after-tool nil)))

(defun claude-pair-chat--draw-user (text)
  "Add your message TEXT to the transcript."
  (claude-pair-chat--fresh-line)
  (claude-pair-chat--insert "\n" (propertize "You" 'face 'claude-pair-chat-you) "\n" text "\n")
  (setq claude-pair-chat--replying nil
        claude-pair-chat--after-tool nil))

(defun claude-pair-chat--draw-text (text)
  "Add TEXT from Claude's answer."
  (claude-pair-chat--ensure-reply)
  (when claude-pair-chat--after-tool
    (claude-pair-chat--fresh-line)
    (claude-pair-chat--insert "\n")
    (setq claude-pair-chat--after-tool nil))
  (claude-pair-chat--insert text))

(defun claude-pair-chat--draw-tool-start (id title)
  "Add a line for tool call ID, described by TITLE."
  (claude-pair-chat--ensure-reply)
  (claude-pair-chat--fresh-line)
  (claude-pair-chat--insert "  ")
  (let ((mark (copy-marker claude-pair-chat--output)))
    (claude-pair-chat--insert (propertize (concat "▸ " title) 'face 'claude-pair-chat-tool) "\n")
    (puthash id mark claude-pair-chat--tools))
  (setq claude-pair-chat--after-tool t))

(defun claude-pair-chat--duration (ms)
  "Return MS milliseconds as a short duration."
  (let ((ms (if (numberp ms) ms 0)))
    (if (< ms 1000)
        (format "%d ms" ms)
      (format "%.1f s" (/ ms 1000.0)))))

(defun claude-pair-chat--draw-tool-end (id status duration-ms)
  "Mark tool call ID as finished with STATUS after DURATION-MS."
  (when-let* ((mark (gethash id claude-pair-chat--tools)))
    (remhash id claude-pair-chat--tools)
    (let ((failed (equal status "error")))
      (claude-pair-chat--editing-transcript
        (goto-char mark)
        (delete-char 1)
        (insert (claude-pair-chat--read-only
                 (propertize (if failed "✗" "✓")
                             'face (if failed 'claude-pair-chat-tool-error 'claude-pair-chat-tool))))
        (end-of-line)
        (when (numberp duration-ms)
          (insert (claude-pair-chat--read-only
                   (propertize (concat "  " (claude-pair-chat--duration duration-ms))
                               'face 'claude-pair-chat-meta))))))
    (set-marker mark nil)))

(defun claude-pair-chat--draw-todo (items)
  "Show ITEMS, Claude's todo list, at the top of the buffer."
  (let ((text (if (seq-empty-p items)
                  ""
                (concat
                 (propertize "Plan\n" 'face 'claude-pair-chat-claude)
                 (mapconcat
                  (lambda (item)
                    (let ((status (plist-get item :status)))
                      (concat "  "
                              (pcase status ("completed" "✓") ("in_progress" "▸") (_ "○"))
                              " " (plist-get item :content) "\n")))
                  items "")
                 "\n"))))
    (claude-pair-chat--editing-transcript
      (delete-region (point-min) claude-pair-chat--todo-end)
      (goto-char (point-min))
      (insert-before-markers (claude-pair-chat--read-only text)))))

(defun claude-pair-chat--draw-result (result)
  "Close Claude's answer with a line about RESULT."
  (let ((cancelled (eq (plist-get result :cancelled) t))
        (failed (eq (plist-get result :isError) t))
        ;; Denials you made yourself already show on their question.
        (denied (seq-remove (lambda (tool) (member tool claude-pair-chat--refused))
                            (delete-dups (append (plist-get result :permissionDenials) nil)))))
    (claude-pair-chat--fresh-line)
    (cond
     (cancelled
      (claude-pair-chat--insert (propertize "  Stopped." 'face 'claude-pair-chat-meta) "\n"))
     (failed
      (claude-pair-chat--insert
       (propertize (format "  Claude stopped: %s"
                           (or (plist-get result :message) (plist-get result :subtype)))
                   'face 'claude-pair-chat-error)
       "\n"))
     (t
      (claude-pair-chat--insert
       (propertize (format "  %s · $%.4f"
                           (claude-pair-chat--duration (plist-get result :durationMs))
                           (or (plist-get result :costUsd) 0))
                   'face 'claude-pair-chat-meta)
       "\n")))
    (when denied
      (claude-pair-chat--insert
       (propertize (format "  Not allowed: %s.  Claude Code denied it without asking you, \
because of a deny rule or because no Emacs could answer.\n"
                           (string-join denied ", "))
                   'face 'claude-pair-chat-meta)))
    (setq claude-pair-chat--replying nil
          claude-pair-chat--after-tool nil
          claude-pair-chat--refused nil)))

(defun claude-pair-chat--draw-error (message stderr)
  "Add an error line with MESSAGE and the end of STDERR."
  (claude-pair-chat--fresh-line)
  (claude-pair-chat--insert (propertize (concat "  " message) 'face 'claude-pair-chat-error) "\n")
  (when (and (stringp stderr) (not (string-empty-p (string-trim stderr))))
    (let ((lines (last (split-string (string-trim-right stderr) "\n") 5)))
      (claude-pair-chat--insert
       (propertize (mapconcat (lambda (l) (concat "    " l "\n")) lines "")
                   'face 'claude-pair-chat-meta))))
  (setq claude-pair-chat--replying nil
        claude-pair-chat--after-tool nil))

(defun claude-pair-chat--draw-notice (text)
  "Add the notice TEXT to the transcript."
  (claude-pair-chat--fresh-line)
  (claude-pair-chat--insert (propertize (concat "  " text) 'face 'claude-pair-chat-meta) "\n"))

(defun claude-pair-chat--verb (tool)
  "Return what Claude wants to do with TOOL, as a verb phrase."
  (pcase tool
    ("Bash" "run")
    ("WebFetch" "fetch")
    ("WebSearch" "search the web for")
    (_ (format "use %s" tool))))

(defun claude-pair-chat--subject (update)
  "Return a short description of what permission UPDATE is about."
  (let ((input (plist-get update :input)))
    (pcase (plist-get update :toolName)
      ("Bash" (format "`%s'" (truncate-string-to-width
                             (car (split-string (or (plist-get input :command) "") "\n"))
                             60 nil nil "…")))
      ("WebFetch" (or (plist-get input :url) ""))
      ("WebSearch" (format "\"%s\"" (or (plist-get input :query) "")))
      (_ (or (plist-get update :title) "")))))

(defun claude-pair-chat--fontify-shell (code)
  "Return CODE fontified as a shell command."
  (with-temp-buffer
    (insert code)
    ;; sh-mode announces its shell setup; that would hide the question's
    ;; echo-area message.
    (let ((inhibit-message t)
          (message-log-max nil))
      (delay-mode-hooks (sh-mode))
      (font-lock-ensure))
    (buffer-string)))

(defun claude-pair-chat--indent (text prefix)
  "Return TEXT with PREFIX before every line, each ending in a newline."
  (mapconcat (lambda (line) (concat prefix line "\n"))
             (split-string (string-trim-right text "\n") "\n")
             ""))

(defun claude-pair-chat--permission-detail (tool input)
  "Return the lines that show TOOL's INPUT in a permission request."
  (pcase tool
    ("Bash"
     (concat (claude-pair-chat--indent
              (claude-pair-chat--fontify-shell (or (plist-get input :command) ""))
              "      ")
             (when-let* ((description (plist-get input :description)))
               (propertize (format "      (%s)\n" description) 'face 'claude-pair-chat-meta))))
    ("WebFetch" (format "      %s\n" (or (plist-get input :url) "")))
    ("WebSearch" (format "      %s\n" (or (plist-get input :query) "")))
    (_
     (let ((lines nil) (plist input))
       (while (and plist (< (length lines) 6))
         (push (format "      %s: %s\n"
                       (substring (symbol-name (car plist)) 1)
                       (truncate-string-to-width (format "%s" (cadr plist)) 200 nil nil "…"))
               lines)
         (setq plist (cddr plist)))
       (apply #'concat (nreverse lines))))))

(defun claude-pair-chat--key (key)
  "Return KEY in the face for answer keys."
  (propertize key 'face 'claude-pair-chat-keys))

(defun claude-pair-chat--draw-question (id head hint keymap property &optional extra)
  "Add question ID to the transcript: HEAD, then the HINT line.
KEYMAP and the text property PROPERTY, whose value is ID, cover the
block until it is resolved.  EXTRA is a plist kept with the block."
  (claude-pair-chat--ensure-reply)
  (claude-pair-chat--fresh-line)
  (let ((start (copy-marker claude-pair-chat--output)))
    (claude-pair-chat--insert head)
    (let ((hint-start (copy-marker claude-pair-chat--output)))
      (claude-pair-chat--insert hint "\n")
      (let ((end (copy-marker claude-pair-chat--output)))
        (claude-pair-chat--editing-transcript
          (add-text-properties start end (list 'keymap keymap property id)))
        (puthash id (append (list :start start :hint-start hint-start :end end :property property)
                            extra)
                 claude-pair-chat--permissions)))))

(defun claude-pair-chat--resolve-question (id outcome)
  "Replace question ID's hint line with OUTCOME and remove its keys."
  (when-let* ((entry (gethash id claude-pair-chat--permissions)))
    (remhash id claude-pair-chat--permissions)
    (claude-pair-chat--editing-transcript
      (let ((hint-start (plist-get entry :hint-start))
            (end (plist-get entry :end)))
        (delete-region hint-start (1- end))
        (goto-char hint-start)
        (insert (claude-pair-chat--read-only outcome))
        (remove-list-of-text-properties (plist-get entry :start) end
                                        (list 'keymap (plist-get entry :property)))))
    (dolist (key '(:start :hint-start :end))
      (set-marker (plist-get entry key) nil))))

(defun claude-pair-chat--draw-permission (update)
  "Add the permission question in UPDATE to the transcript."
  (let ((tool (plist-get update :toolName))
        (rule (or (plist-get update :alwaysRule) (plist-get update :toolName))))
    (claude-pair-chat--draw-question
     (plist-get update :requestId)
     (concat (propertize (format "  ⏸ Claude wants to %s:\n" (claude-pair-chat--verb tool))
                         'face 'claude-pair-chat-ask)
             (claude-pair-chat--permission-detail tool (plist-get update :input)))
     (concat "    " (claude-pair-chat--key "y") " allow once   "
             (claude-pair-chat--key "a") " always allow "
             (propertize rule 'face 'claude-pair-chat-meta)
             "   " (claude-pair-chat--key "n") " deny   "
             (claude-pair-chat--key "d") " deny with a reason")
     claude-pair-chat-permission-map 'claude-pair-request
     (list :rule rule))))

(defun claude-pair-chat--draw-permission-done (update)
  "Replace the keys of the question UPDATE answers or withdraws with the outcome."
  (let* ((id (plist-get update :requestId))
         (rule (plist-get (gethash id claude-pair-chat--permissions) :rule))
         (allowed (equal (plist-get update :decision) "allow"))
         (message (plist-get update :message)))
    (claude-pair-chat--resolve-question
     id
     (if (equal (plist-get update :state) "withdrawn")
         (propertize (format "    Withdrawn: %s" (plist-get update :reason))
                     'face 'claude-pair-chat-meta)
       (cond
        ((and allowed (eq (plist-get update :always) t))
         (propertize (format "    ✓ Always allowed: %s" rule) 'face 'claude-pair-chat-tool))
        (allowed (propertize "    ✓ Allowed" 'face 'claude-pair-chat-tool))
        (t (propertize (if (and (stringp message) (not (string-empty-p message)))
                           (format "    ✗ Denied: %s" message)
                         "    ✗ Denied")
                       'face 'claude-pair-chat-tool-error)))))))

(defun claude-pair-chat--edit-lines (update)
  "Return (HEAD . HINT), the two lines of the edit block for UPDATE."
  (let* ((id (plist-get update :requestId))
         (total (cdr (claude-pair-review-hunk-count id)))
         (all (if (and total (> total 1)) " all" "")))
    (cons
     (propertize (format "  ✎ Claude wants to %s %s%s\n"
                         (if (equal (plist-get update :editKind) "write") "write" "edit")
                         (plist-get update :relPath)
                         (if (and total (> total 1)) (format " · %d hunks" total) ""))
                 'face 'claude-pair-chat-ask)
     (if (claude-pair-review-pending-p id)
         (concat "    " (claude-pair-chat--key "y") " apply" all "   "
                 (claude-pair-chat--key "n") " reject" all "   "
                 (claude-pair-chat--key "d") " reject" all " with a reason   "
                 (claude-pair-chat--key "RET") (if (string-empty-p all) " show" " show, decide hunk by hunk"))
       (propertize "    Waiting for review…" 'face 'claude-pair-chat-meta)))))

(defun claude-pair-chat--draw-edit (update)
  "Add the proposed edit in UPDATE to the transcript."
  (let ((lines (claude-pair-chat--edit-lines update)))
    (claude-pair-chat--draw-question
     (plist-get update :requestId) (car lines) (cdr lines)
     claude-pair-chat-edit-map 'claude-pair-edit (list :update update))))

(defun claude-pair-chat--refresh-edit (proposal)
  "Redraw the chat block of PROPOSAL, now that its hunks are known.
The block can be drawn before Emacs has shown the edit, and then it
has neither its keys nor its number of hunks."
  (let ((id (plist-get proposal :id)))
    (maphash
     (lambda (_session buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when-let* ((entry (and (hash-table-p claude-pair-chat--permissions)
                                   (gethash id claude-pair-chat--permissions)))
                       (update (plist-get entry :update)))
             (let ((lines (claude-pair-chat--edit-lines update))
                   (start (plist-get entry :start))
                   (hint-start (plist-get entry :hint-start))
                   (end (plist-get entry :end)))
               (claude-pair-chat--editing-transcript
                 ;; Both lines end in a newline that stays; the markers before
                 ;; each line do not move when text goes in after them.
                 (delete-region hint-start (1- end))
                 (goto-char hint-start)
                 (insert (claude-pair-chat--read-only (cdr lines)))
                 (delete-region start (1- hint-start))
                 (goto-char start)
                 (insert (claude-pair-chat--read-only (string-remove-suffix "\n" (car lines))))
                 (add-text-properties start end (list 'keymap claude-pair-chat-edit-map
                                                      'claude-pair-edit id))))))))
     claude-pair-chat--buffers)))

(add-hook 'claude-pair-review-show-functions #'claude-pair-chat--refresh-edit)

(defun claude-pair-chat--stop-answering ()
  "Finish the note Claude was answering into, if any."
  (when claude-pair-chat--answering
    (claude-pair-review-note-done claude-pair-chat--answering)
    (setq claude-pair-chat--answering nil)))

(defun claude-pair-chat--question-text (update)
  "Describe the question you asked about a hunk of the edit in UPDATE."
  (let* ((hunks (append (plist-get update :hunks) nil))
         (asked (seq-find (lambda (h) (equal (plist-get h :decision) "asked")) hunks))
         (applied (seq-count (lambda (h) (equal (plist-get h :decision) "applied")) hunks)))
    (concat
     (propertize (format "    ? You asked about %s: %s"
                         (if (cdr hunks)
                             (format "hunk %d (line %d)" (plist-get asked :index) (plist-get asked :line))
                           "it")
                         (car (split-string (or (plist-get update :message) "") "\n")))
                 'face 'claude-pair-chat-ask)
     (if (> applied 0)
         (propertize (format "\n      %d of %d hunks applied first" applied (length hunks))
                     'face 'claude-pair-chat-meta)
       ""))))

(defun claude-pair-chat--partial-text (update)
  "Describe the hunk by hunk outcome in UPDATE, one line per hunk not applied."
  (let* ((hunks (append (plist-get update :hunks) nil))
         (applied (seq-count (lambda (h) (equal (plist-get h :decision) "applied")) hunks)))
    (concat
     (propertize (format "    ◐ Applied %d of %d hunks%s" applied (length hunks)
                         (cond ((zerop applied) "")
                               ((eq (plist-get update :saved) t) ", saved")
                               (t ", not saved: the buffer has unsaved changes of yours")))
                 'face 'claude-pair-chat-tool)
     (mapconcat
      (lambda (h)
        (let ((note (plist-get h :note)))
          (propertize
           (format "\n      ✗ hunk %d (line %d) %s%s" (plist-get h :index) (plist-get h :line)
                   (if (equal (plist-get h :decision) "rejected") "rejected" "not applied")
                   (if (and (stringp note) (not (string-empty-p note)))
                       (concat ": " (car (split-string note "\n")))
                     ""))
           'face 'claude-pair-chat-tool-error)))
      (seq-remove (lambda (h) (equal (plist-get h :decision) "applied")) hunks)
      ""))))

(defun claude-pair-chat--draw-edit-done (update)
  "Replace the keys of the edit UPDATE settles with the outcome."
  (let ((message (or (plist-get update :message) "")))
    (claude-pair-chat--resolve-question
     (plist-get update :requestId)
     (pcase (plist-get update :state)
       ("applied"
        (propertize (cond ((eq (plist-get update :created) t) "    ✓ Created and saved")
                          ((eq (plist-get update :saved) t) "    ✓ Applied and saved")
                          (t "    ✓ Applied, not saved: the buffer has unsaved changes of yours"))
                    'face 'claude-pair-chat-tool))
       ("rejected"
        (propertize (if (string-empty-p message) "    ✗ Rejected" (format "    ✗ Rejected: %s" message))
                    'face 'claude-pair-chat-tool-error))
       ("partial"
        (claude-pair-chat--partial-text update))
       ("question"
        (claude-pair-chat--question-text update))
       ("error"
        (propertize (format "    ✗ Not applied: %s" (car (split-string message "\n")))
                    'face 'claude-pair-chat-tool-error))
       (_
        (propertize (format "    Withdrawn: %s" (plist-get update :reason))
                    'face 'claude-pair-chat-meta))))))

;;;; Deciding on edits from the chat

(defun claude-pair-chat--edit-at-point ()
  "Return the edit on the line at point, else the oldest waiting one."
  (or (get-text-property (point) 'claude-pair-edit)
      (car claude-pair-chat--reviews)
      (user-error "No edit is waiting for your review")))

(defun claude-pair-chat-apply-edit ()
  "Apply the proposed edit at point."
  (interactive)
  (claude-pair-review-apply (claude-pair-chat--edit-at-point)))

(defun claude-pair-chat-reject-edit ()
  "Reject the proposed edit at point."
  (interactive)
  (claude-pair-review-reject (claude-pair-chat--edit-at-point) ""))

(defun claude-pair-chat-reject-edit-with-reason ()
  "Reject the proposed edit at point and tell Claude why."
  (interactive)
  (let ((id (claude-pair-chat--edit-at-point)))
    (claude-pair-review-reject id (read-string "Tell Claude why, or what to do instead: "))))

(defun claude-pair-chat-show-edit ()
  "Show the proposed edit at point in its file's buffer."
  (interactive)
  (claude-pair-review-show (claude-pair-chat--edit-at-point)))

;;;; Answering permission questions

(defun claude-pair-chat--request-at-point ()
  "Return the request on the line at point, else the oldest pending one."
  (or (get-text-property (point) 'claude-pair-request)
      (car claude-pair-chat--pending)
      (user-error "No permission question is waiting")))

(defun claude-pair-chat--answer (id decision &optional always message)
  "Answer permission request ID with DECISION, \"allow\" or \"deny\".
ALWAYS adds a rule; MESSAGE tells Claude why it was denied."
  (condition-case err
      (claude-pair-rpc-request 'permission/answer
                               (list :requestId id :decision decision
                                     :always (if always t :json-false)
                                     :message (or message "")))
    (jsonrpc-error
     (message "claude-pair: %s" (claude-pair-rpc-error-message err)))))

(defun claude-pair-chat-allow ()
  "Allow the permission request at point, once."
  (interactive)
  (claude-pair-chat--check-buffer)
  (claude-pair-chat--answer (claude-pair-chat--request-at-point) "allow"))

(defun claude-pair-chat-allow-always ()
  "Allow the permission request at point, and keep allowing it in this project.
Claude Code saves the rule in the project's .claude/settings.local.json."
  (interactive)
  (claude-pair-chat--check-buffer)
  (claude-pair-chat--answer (claude-pair-chat--request-at-point) "allow" t))

(defun claude-pair-chat-deny ()
  "Deny the permission request at point."
  (interactive)
  (claude-pair-chat--check-buffer)
  (claude-pair-chat--answer (claude-pair-chat--request-at-point) "deny"))

(defun claude-pair-chat-deny-with-reason ()
  "Deny the permission request at point and tell Claude why."
  (interactive)
  (claude-pair-chat--check-buffer)
  (let ((id (claude-pair-chat--request-at-point)))
    (claude-pair-chat--answer id "deny" nil
                              (read-string "Tell Claude why, or what to do instead: "))))

(defun claude-pair-chat-answer-permission ()
  "Answer the permission request at point, or the oldest one, from a menu."
  (interactive)
  (claude-pair-chat--check-buffer)
  (let* ((id (claude-pair-chat--request-at-point))
         (rule (plist-get (gethash id claude-pair-chat--permissions) :rule))
         (choice (read-multiple-choice
                  "Claude is waiting for your answer"
                  `((?y "allow once")
                    (?a "always allow" ,(format "Allow now and in future: %s" rule))
                    (?n "deny")
                    (?d "deny with a reason")))))
    (pcase (car choice)
      (?y (claude-pair-chat--answer id "allow"))
      (?a (claude-pair-chat--answer id "allow" t))
      (?n (claude-pair-chat--answer id "deny"))
      (?d (claude-pair-chat--answer
           id "deny" nil (read-string "Tell Claude why, or what to do instead: "))))))

;;;###autoload
(defun claude-pair-answer-permission ()
  "Answer Claude's waiting permission question from any buffer."
  (interactive)
  (let ((buffer (if (and (derived-mode-p 'claude-pair-chat-mode) claude-pair-chat--pending)
                    (current-buffer)
                  (catch 'found
                    (maphash (lambda (_id b)
                               (when (and (buffer-live-p b)
                                          (buffer-local-value 'claude-pair-chat--pending b))
                                 (throw 'found b)))
                             claude-pair-chat--buffers)
                    nil))))
    (unless buffer
      (user-error "Claude is not waiting for an answer"))
    (with-current-buffer buffer
      (claude-pair-chat-answer-permission))))

;;;; Header line

(defun claude-pair-chat--state-text ()
  "Describe `claude-pair-chat--state' in a few words."
  (pcase claude-pair-chat--state
    ("idle" "ready")
    ("starting" "starting Claude…")
    ("running" "thinking…")
    ("writing" "writing…")
    ("tool" (format "running %s…" (or claude-pair-chat--tool "a tool")))
    ("cancelling" "stopping…")
    ("waiting" "waiting for your answer")
    ("reviewing" "waiting for your review")
    ("disconnected" "disconnected")
    (other other)))

(defun claude-pair-chat--header-line ()
  "Return the chat buffer's header line."
  (concat " "
          (propertize "Claude" 'face 'claude-pair-chat-claude)
          (when claude-pair-chat--model
            (concat " · " claude-pair-chat--model))
          " · " (claude-pair-chat--state-text)
          (when (and (numberp claude-pair-chat--cost) (> claude-pair-chat--cost 0))
            (format " · $%.4f" claude-pair-chat--cost))))

(provide 'claude-pair-chat)
;;; claude-pair-chat.el ends here
