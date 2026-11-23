;;; tandem-chat.el --- Chat with Claude in an Emacs buffer  -*- lexical-binding: t; -*-

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

;; One chat buffer per Claude session.  The buffer has a read-only
;; transcript and, after a "❯" prompt, a composer you type into:
;;
;;   C-c C-c   send the composer to Claude
;;   C-c C-k   stop Claude's current answer
;;   C-c C-p   answer Claude's oldest permission question
;;   M-p, M-n  step through earlier messages
;;
;; When Claude proposes an edit, it appears in the file's buffer (see
;; tandem-review.el) and as a block in the transcript, where y applies
;; it, n rejects it, d rejects it with a note and RET shows it.
;;
;; When Claude wants to run a command or use a tool that needs approval, the
;; request appears in the transcript.  With point on it, press y to allow
;; it once, a to always allow it in this project, n to deny it, or d to deny
;; it and tell Claude why.  Nothing is asked in the minibuffer behind your
;; back, so a stray keystroke elsewhere can never approve a command.
;;
;; Updates from the daemon are queued and drawn every
;; `tandem-chat-flush-interval' seconds, so long answers do not make
;; typing or redisplay stutter.  Claude's todo list, when it keeps one,
;; sits at the top of the buffer.

;;; Code:

(require 'tandem-layout)
(require 'tandem-markdown)
(require 'tandem-project)
(require 'tandem-rpc)
(require 'tandem-review)
(require 'project)
(require 'ring)
(require 'sh-script)
(require 'subr-x)

(defcustom tandem-claude-command nil
  "Path of the claude command, or nil to look for \"claude\" on variable `exec-path'."
  :type '(choice (const :tag "Find on exec-path" nil) file)
  :group 'tandem)

(defcustom tandem-environment-variables
  '("ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_BASE_URL" "ANTHROPIC_MODEL"
    "CLAUDE_CODE_USE_BEDROCK" "CLAUDE_CODE_USE_VERTEX" "CLAUDE_CONFIG_DIR"
    "AWS_PROFILE" "AWS_REGION" "CLOUD_ML_REGION" "ANTHROPIC_VERTEX_PROJECT_ID"
    "HTTPS_PROXY" "HTTP_PROXY" "NO_PROXY" "https_proxy" "http_proxy" "no_proxy")
  "Environment variables each new session takes from Emacs.
Claude Code reads its credentials and provider from these.  A new
session gets the value Emacs has now (see `getenv'), or the variable
removed if Emacs has none, whatever the daemon started with.  So after
\[setenv], a new chat (\[universal-argument] \[tandem]) uses the new value
without restarting the daemon.  Other variables come from the daemon,
which inherited them from the Emacs that started it."
  :type '(repeat string)
  :group 'tandem)

(defcustom tandem-instructions
  "Write in clear, simple English: short sentences and everyday words, so \
that someone still learning English understands you easily. Use the \
correct technical terms, and when a term may be unfamiliar, say what it \
means in a few plain words the first time you use it."
  "Standing instructions Claude follows in every answer of a new chat.
They go into Claude's system prompt, so they hold for every message
without being repeated.  Empty for none."
  :type 'string
  :group 'tandem)

(defcustom tandem-model nil
  "Model for new sessions, such as \"opus\", or nil for Claude Code's default."
  :type '(choice (const :tag "Claude Code's default" nil) string)
  :group 'tandem)

(defcustom tandem-chat-flush-interval 0.04
  "Seconds between screen updates while Claude writes."
  :type 'number
  :group 'tandem)

(defcustom tandem-chat-window-width 0.38
  "Width of the chat window: a fraction of the frame, or a number of columns."
  :type 'number
  :group 'tandem)

(defcustom tandem-chat-history-size 100
  "Number of sent messages that \\[tandem-chat-previous-input] can recall."
  :type 'natnum
  :group 'tandem)

(defface tandem-chat-you '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the \"You\" label above your messages."
  :group 'tandem)

(defface tandem-chat-claude '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the \"Claude\" label above Claude's answers."
  :group 'tandem)

(defface tandem-chat-tool '((t :inherit shadow))
  "Face for tool call lines."
  :group 'tandem)

(defface tandem-chat-tool-error '((t :inherit error))
  "Face for the mark of a tool call that failed."
  :group 'tandem)

(defface tandem-chat-meta '((t :inherit shadow))
  "Face for durations, costs and notices."
  :group 'tandem)

(defface tandem-chat-error '((t :inherit error))
  "Face for errors in the transcript."
  :group 'tandem)

(defface tandem-chat-prompt '((t :inherit minibuffer-prompt))
  "Face for the prompt before the composer."
  :group 'tandem)

(defface tandem-chat-ask '((t :inherit warning :weight bold))
  "Face for a permission question from Claude."
  :group 'tandem)

(defface tandem-chat-keys '((t :inherit help-key-binding))
  "Face for the keys that answer a permission question."
  :group 'tandem)

(defconst tandem-chat--prompt "\n❯ "
  "Text between the transcript and the composer.")

(defvar tandem-chat--buffers (make-hash-table :test #'equal)
  "Map from session id to its chat buffer.")

(defvar-local tandem-chat--session-id nil "This buffer's session id.")
(defvar-local tandem-chat--root nil "Project directory of this session.")
(defvar-local tandem-chat--output nil "Marker where the transcript grows.")
(defvar-local tandem-chat--input nil "Marker at the start of the composer.")
(defvar-local tandem-chat--todo-end nil "Marker at the end of the todo block.")
(defvar-local tandem-chat--queue nil "Updates waiting to be drawn, newest first.")
(defvar-local tandem-chat--timer nil "Timer that draws queued updates.")
(defvar-local tandem-chat--state "idle" "What Claude is doing, as a short string.")
(defvar-local tandem-chat--tool nil "Name of the tool Claude is running.")
(defvar-local tandem-chat--model nil "Model name reported by Claude Code.")

(defvar-local tandem-chat--turns 0 "Number of messages sent in this chat.")
(defvar-local tandem-chat--cost 0 "Cost of the session so far, in US dollars.")
(defvar-local tandem-chat--tools nil "Map from tool call id to the marker of its status mark.")
(defvar-local tandem-chat--replying nil "Non-nil once Claude's answer to the last message has begun.")

(defvar-local tandem-chat--turn-started nil
  "When the running or last turn began, as from `float-time', or nil.")

(defvar-local tandem-chat--markdown-start nil
  "Marker where Claude's text not yet rendered as Markdown begins, or nil.")
(defvar-local tandem-chat--after-tool nil "Non-nil when the transcript ends with a tool line.")
(defvar-local tandem-chat--history nil "Ring of sent messages.")
(defvar-local tandem-chat--history-index nil "Position in the history ring, or nil.")
(defvar-local tandem-chat--permissions nil
  "Map from permission request id to a plist describing its block.")
(defvar-local tandem-chat--pending nil
  "Ids of unanswered permission requests, oldest first.")
(defvar-local tandem-chat--asked-at nil
  "Map from tool call id to when its permission question arrived.")
(defvar-local tandem-chat--waited nil
  "Map from tool call id to milliseconds its question waited for you.")
(defvar-local tandem-chat--refused nil
  "Tools whose question was denied or withdrawn in the current turn.")
(defvar tandem-chat-text-functions nil
  "Functions that turn your message into what Claude gets, in order.
Each takes the text and returns it, perhaps with context added.  They
run in the chat buffer.")

(defvar tandem-chat-show-user-function #'identity
  "Function that turns your message into what the transcript shows.")

(defvar tandem-chat-send-functions nil
  "Functions that may handle a message you send, instead of Claude.
Each gets the text; the first that returns non-nil has handled it, and
nothing goes to Claude.  One that handles it empties the composer.")

(defvar tandem-chat-permission-functions nil
  "Functions called with each permission update, a plist, in the chat buffer.
Pending, answered and withdrawn questions all come here, after the
chat has handled them.")

(defvar tandem-chat-plan-open-function nil
  "Function that opens Claude's plan, request ID, for you to edit, or nil.
With one, a plan question (ExitPlanMode) is not allowed from the chat:
y and RET open the plan instead, where you approve it.")

(defun tandem-chat--plan-question-p (id)
  "Return non-nil if request ID is Claude's plan, to open for editing."
  (and tandem-chat-plan-open-function
       (equal (plist-get (gethash id tandem-chat--asked-at) :toolName) "ExitPlanMode")))

(defvar tandem-chat-turn-functions nil
  "Functions called when a turn ends, in the chat buffer.
Each gets the text Claude wrote in that turn and the result plist.")

(defvar-local tandem-chat--turn-text nil
  "Claude's text in the running turn, newest piece first.")

(defvar tandem-chat-session-functions nil
  "Functions called with a chat buffer whose session has just started or reopened.")

(defvar tandem-chat-reattach-function #'ignore
  "Function returning a chat buffer for a project ROOT left open in the daemon.
`tandem' calls it when the project has no chat buffer; nil from it
means a new chat starts.")

(defvar-local tandem-chat--review-results nil
  "Your decisions on deferred edits, oldest first, for your next message.
Each is (TEXT . ID), ID being the edit's request id when TEXT asks a
question, so Claude's answer goes into that edit's note.")

(defvar-local tandem-chat--answering nil
  "Request id of the edit Claude is answering a question about, or nil.
Claude's text goes into that edit's note as well.")

(defvar-local tandem-chat--reviews nil
  "Ids of proposed edits waiting for a decision, oldest first.")
(defvar-local tandem-chat--edit-calls nil
  "Edit tool calls not yet finished, oldest first, as (ID . SHOWN).
SHOWN is non-nil once the call's edit block is in the transcript.")

(defconst tandem-chat--edit-tools '("mcp__emacs__edit_file" "mcp__emacs__write_file")
  "Claude's edit tools, which wait for your review.")

(defvar-keymap tandem-chat-edit-map
  :doc "Keys on a proposed edit in the chat transcript."
  "y" #'tandem-chat-apply-edit
  "n" #'tandem-chat-reject-edit
  "d" #'tandem-chat-reject-edit-with-reason
  "RET" #'tandem-chat-show-edit)

(defvar-keymap tandem-chat-permission-map
  :doc "Keys on a permission request in the chat transcript."
  "y" #'tandem-chat-allow
  "a" #'tandem-chat-allow-always
  "n" #'tandem-chat-deny
  "d" #'tandem-chat-deny-with-reason
  "RET" #'tandem-chat-answer-permission)

(defvar-keymap tandem-chat-mode-map
  "C-c C-c" #'tandem-chat-send
  "C-c C-k" #'tandem-chat-cancel
  "C-c C-p" #'tandem-chat-answer-permission
  "C-c C-r" #'tandem-chat-send-reviews
  "M-p" #'tandem-chat-previous-input
  "M-n" #'tandem-chat-next-input)

(define-derived-mode tandem-chat-mode text-mode "Claude"
  "Major mode for chatting with Claude.
Type after the prompt at the bottom and press \\[tandem-chat-send]."
  (setq-local header-line-format '(:eval (tandem-chat--header-line)))
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

;;;; Starting a chat

(defun tandem-chat--project-root ()
  "Return the folder for a chat about the current buffer.
See `tandem-project-root'."
  (tandem-project-root))

(defun tandem-chat--claude-path ()
  "Return the absolute path of the claude command."
  (let ((path (or tandem-claude-command (executable-find "claude"))))
    (unless path
      (user-error "Cannot find claude; install Claude Code or set `tandem-claude-command'"))
    (expand-file-name path)))

(defun tandem-chat--buffer-for (root)
  "Return a live chat buffer for ROOT, or nil."
  (catch 'found
    (maphash (lambda (_id buffer)
               (when (and (buffer-live-p buffer)
                          (equal (buffer-local-value 'tandem-chat--root buffer) root))
                 (throw 'found buffer)))
             tandem-chat--buffers)
    nil))

(defun tandem-chat--create (root)
  "Start a session about ROOT and return its new chat buffer."
  (let* ((params (list :cwd root :claudePath (tandem-chat--claude-path)
                       :env (tandem-chat--environment)
                       :instructions (or tandem-instructions "")))
         (result
          (condition-case err
              (tandem-rpc-request
               'session/new
               (if tandem-model (append params (list :model tandem-model)) params)
               30)
            (jsonrpc-error
             (user-error "tandem: %s" (tandem-rpc-error-message err)))))
         (buffer (generate-new-buffer
                  (format "*tandem: %s*" (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (tandem-chat--setup (plist-get result :sessionId) root))
    (run-hook-with-args 'tandem-chat-session-functions buffer)
    buffer))

(defun tandem-chat--environment ()
  "Return `tandem-environment-variables' as Emacs has them now.
A plist from each name to its value, or nil (JSON null) for a variable
Emacs does not have."
  (let (env)
    (dolist (name tandem-environment-variables)
      (setq env (plist-put env (intern (concat ":" name)) (getenv name))))
    env))

(defun tandem-chat--display (buffer)
  "Show BUFFER in a side window on the right and select it.
Unless it is visible already, first switch to Claude's tab; see
`tandem-layout-tab'."
  (tandem-layout-enable)
  (tandem-layout-enter-tab buffer)
  (let ((window (display-buffer
                 buffer
                 `((display-buffer-in-side-window)
                   (side . right)
                   (slot . 0)
                   (window-width . ,tandem-chat-window-width)
                   (window-parameters . ((no-delete-other-windows . t)))))))
    (when window
      (select-window window))
    (with-current-buffer buffer
      (goto-char (point-max)))
    buffer))

;;;###autoload
(defun tandem (&optional new)
  "Chat with Claude about the current project.
Show this project's chat; else reattach to one still open in the daemon,
as after Emacs restarted; else start one.  With prefix argument NEW,
always start a new session.  To reopen an older chat, use
`tandem-resume'."
  (interactive "P")
  (let* ((root (tandem-chat--project-root))
         (buffer (unless new
                   (or (tandem-chat--buffer-for root)
                       ;; Still open in the daemon, after Emacs restarted.
                       (funcall tandem-chat-reattach-function root)))))
    (tandem-chat--display (or buffer (tandem-chat--create root)))))

(defun tandem-chat--setup (session-id root)
  "Make the current buffer the chat for SESSION-ID about ROOT."
  (tandem-chat-mode)
  (setq tandem-chat--session-id session-id
        tandem-chat--root root
        tandem-chat--tools (make-hash-table :test #'equal)
        tandem-chat--permissions (make-hash-table :test #'equal)
        tandem-chat--asked-at (make-hash-table :test #'equal)
        tandem-chat--waited (make-hash-table :test #'equal)
        tandem-chat--history (make-ring tandem-chat-history-size))
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (erase-buffer)
    (setq tandem-chat--todo-end (copy-marker (point-min)))
    (insert (propertize
             (format "Ask Claude about %s.  C-c C-c sends, C-c C-k stops Claude.\n"
                     (abbreviate-file-name root))
             'face 'tandem-chat-meta 'read-only t 'front-sticky '(read-only)))
    (let ((prompt-start (point)))
      (insert (propertize tandem-chat--prompt
                          'face 'tandem-chat-prompt
                          'read-only t
                          'front-sticky '(read-only)
                          'rear-nonsticky '(read-only face)))
      ;; Made after the prompt is in, so the prompt does not push it along:
      ;; the transcript grows just before the prompt.
      (setq tandem-chat--output (copy-marker prompt-start t)))
    (setq tandem-chat--input (point-marker)))
  (setq buffer-undo-list nil)
  (when session-id
    (puthash session-id (current-buffer) tandem-chat--buffers))
  (add-hook 'kill-buffer-hook #'tandem-chat--on-kill nil t)
  (add-hook 'after-change-functions #'tandem-chat--draft-changed nil t))

(defun tandem-chat--draft-changed (_beg end _length)
  "Format the composer's code again after a change that ends at END."
  (when (and tandem-chat--input (>= end tandem-chat--input))
    (tandem-markdown-render-draft tandem-chat--input (point-max))))

;;;; Commands

(defun tandem-chat--check-buffer ()
  "Signal an error unless the current buffer is a chat buffer."
  (unless (derived-mode-p 'tandem-chat-mode)
    (user-error "Not in a tandem chat buffer")))

(defun tandem-chat--busy-p ()
  "Return non-nil while Claude is working on an answer."
  (not (member tandem-chat--state '("idle" "disconnected"))))

(defun tandem-chat--input-text ()
  "Return the composer's text."
  (buffer-substring-no-properties tandem-chat--input (point-max)))

(defun tandem-chat--set-input (text)
  "Replace the composer's text with TEXT."
  (delete-region tandem-chat--input (point-max))
  (goto-char (point-max))
  (insert text))

(defun tandem-chat-session-info (session)
  "Return (:model MODEL :turn N) for SESSION's chat, or nil."
  (when-let* ((buffer (gethash session tandem-chat--buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (list :model tandem-chat--model :turn tandem-chat--turns
              :root tandem-chat--root
              :prompt (unless (ring-empty-p tandem-chat--history)
                        (truncate-string-to-width
                         (car (split-string (ring-ref tandem-chat--history 0) "\n"))
                         120 nil nil "…")))))))

(defun tandem-chat--expand (text)
  "Return TEXT as Claude gets it, after `tandem-chat-text-functions'."
  (dolist (fn tandem-chat-text-functions text)
    (setq text (funcall fn text))))

(defun tandem-chat-send ()
  "Send the composer's text to Claude."
  (interactive)
  (tandem-chat--check-buffer)
  (let ((text (string-trim (tandem-chat--input-text))))
    (when (string-empty-p text)
      (user-error "Type a message after the prompt first"))
    (unless (run-hook-with-args-until-success 'tandem-chat-send-functions text)
      (tandem-chat--send-to-claude text))))

(defun tandem-chat--send-to-claude (text &optional mode)
  "Send TEXT, your message, to Claude.
MODE is the permission mode of the turn: nil for the usual one, or
\"plan\", in which Claude reads and plans but changes nothing."
  (progn
    (when (tandem-chat--busy-p)
      (user-error "Claude is still answering; C-c C-k stops it"))
    ;; Draw the message before sending, so it precedes any reply.
    (tandem-chat--enqueue (cons 'user text))
    (when tandem-chat--review-results
      (tandem-chat--enqueue
       (cons 'notice (format "Sent with it: your review of %d deferred edit%s"
                             (length tandem-chat--review-results)
                             (if (cdr tandem-chat--review-results) "s" "")))))
    (tandem-chat--flush)
    (setq tandem-chat--state "starting"
          tandem-chat--turn-started (float-time))
    (if (condition-case err
            (progn
              (setq tandem-chat--turn-text nil)
              (tandem-rpc-request 'session/prompt
                                       (append
                                        (list :sessionId tandem-chat--session-id
                                              :text (tandem-chat--with-reviews
                                                     (tandem-chat--expand text)))
                                        (when mode (list :permissionMode mode))))
              t)
          (jsonrpc-error
           (setq tandem-chat--state "idle")
           (tandem-chat--enqueue
            (cons 'notice (format "Not sent: %s" (tandem-rpc-error-message err))))
           (tandem-chat--flush)
           nil))
        (progn
          (setq tandem-chat--turns (1+ tandem-chat--turns))
          ;; A question about a hunk among them: the answer fills its note.
          (when-let* ((asked (seq-find #'cdr tandem-chat--review-results)))
            (tandem-chat--stop-answering)
            (setq tandem-chat--answering (cdr asked)))
          (setq tandem-chat--review-results nil)
          (ring-insert tandem-chat--history text)
          (setq tandem-chat--history-index nil)
          (tandem-chat--set-input "")
          (setq buffer-undo-list nil))
      (goto-char (point-max)))
    (force-mode-line-update)))

(defun tandem-chat-cancel ()
  "Stop Claude's current answer."
  (interactive)
  (tandem-chat--check-buffer)
  (if (not (tandem-chat--busy-p))
      (message "tandem: Claude is not answering")
    (let ((result (tandem-rpc-request 'session/cancel
                                           (list :sessionId tandem-chat--session-id))))
      (if (eq (plist-get result :cancelled) t)
          (setq tandem-chat--state "cancelling")
        (message "tandem: nothing to stop")))
    (force-mode-line-update)))

(defun tandem-chat-previous-input (n)
  "Put the Nth previous sent message in the composer."
  (interactive "p")
  (tandem-chat--check-buffer)
  (let ((size (ring-length tandem-chat--history)))
    (when (zerop size)
      (user-error "No earlier messages"))
    (setq tandem-chat--history-index
          (max 0 (min (1- size) (+ (or tandem-chat--history-index -1) n))))
    (tandem-chat--set-input
     (ring-ref tandem-chat--history tandem-chat--history-index))))

(defun tandem-chat-next-input (n)
  "Put the Nth next sent message in the composer, or empty it."
  (interactive "p")
  (tandem-chat--check-buffer)
  (let ((index (- (or tandem-chat--history-index 0) n)))
    (if (< index 0)
        (progn (setq tandem-chat--history-index nil)
               (tandem-chat--set-input ""))
      (setq tandem-chat--history-index index)
      (tandem-chat--set-input (ring-ref tandem-chat--history index)))))

;;;; Updates from the daemon

(defun tandem-chat--on-notification (method params)
  "Route a `session/update' notification with PARAMS to its chat buffer.
METHOD is the notification's name."
  (when (eq method 'session/update)
    (let ((buffer (gethash (plist-get params :sessionId) tandem-chat--buffers)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (tandem-chat--handle-update (plist-get params :update)))))))

(add-hook 'tandem-rpc-notification-functions #'tandem-chat--on-notification)

(defun tandem-chat--handle-update (update)
  "Record UPDATE, a plist from the daemon, and queue what it draws."
  (pcase (plist-get update :kind)
    ("status"
     (let ((state (plist-get update :state)))
       (setq tandem-chat--state (if (equal state "requesting") "running" state))))
    ("init"
     (setq tandem-chat--model (plist-get update :model)))
    ("text"
     (setq tandem-chat--state "writing")
     (when tandem-chat--answering
       (tandem-review-note-append tandem-chat--answering (plist-get update :delta)))
     (push (plist-get update :delta) tandem-chat--turn-text)
     (tandem-chat--enqueue (cons 'text (plist-get update :delta))))
    ("tool"
     (cond
      ;; An edit shows as its own block; a separate tool line would repeat it.
      ((member (plist-get update :name) tandem-chat--edit-tools)
       (tandem-chat--edit-call update))
      ((equal (plist-get update :status) "started")
       (setq tandem-chat--state "tool"
             tandem-chat--tool (plist-get update :name))
       (tandem-chat--enqueue
        (list 'tool-start (plist-get update :id) (plist-get update :title))))
      (t
       (setq tandem-chat--state "running")
       (let* ((id (plist-get update :id))
              (duration (unless (member (plist-get update :name) tandem-chat--edit-tools)
                          ;; An edit's time is mostly your review.
                          (plist-get update :durationMs)))
              (waited (gethash id tandem-chat--waited)))
         ;; Time spent waiting for your answer is not the tool's own time.
         (when (and (numberp duration) waited)
           (setq duration (max 0 (- duration waited)))
           (remhash id tandem-chat--waited))
         (tandem-chat--enqueue
          (list 'tool-end id (plist-get update :status) duration))))))
    ("todo"
     (tandem-chat--enqueue (cons 'todo (plist-get update :items))))
    ("result"
     (tandem-chat--stop-answering)
     (let ((text (apply #'concat (reverse tandem-chat--turn-text))))
       (setq tandem-chat--turn-text nil)
       (run-hook-with-args 'tandem-chat-turn-functions text update))
     (let ((cost (plist-get update :sessionCostUsd)))
       (when (numberp cost)
         (setq tandem-chat--cost cost)))
     (tandem-chat--enqueue (cons 'result update)))
    ("error"
     (tandem-chat--enqueue
      (list 'error (plist-get update :message) (plist-get update :stderr))))
    ("edit"
     (let ((id (plist-get update :requestId)))
       (when (equal (plist-get update :state) "question")
         ;; What Claude writes next answers the question.
         (tandem-chat--stop-answering)
         (setq tandem-chat--answering id))
       (if (equal (plist-get update :state) "pending")
           (progn
             ;; A new proposal ends the answer.
             (tandem-chat--stop-answering)
             (when-let* ((call (seq-find (lambda (c) (not (cdr c))) tandem-chat--edit-calls)))
               (setcdr call t))
             (setq tandem-chat--reviews (append tandem-chat--reviews (list id))
                   tandem-chat--state "reviewing")
             (tandem-chat--enqueue (cons 'edit update)))
         (setq tandem-chat--reviews (delete id tandem-chat--reviews))
         (when (and (null tandem-chat--reviews)
                    (equal tandem-chat--state "reviewing"))
           (setq tandem-chat--state "running"))
         (tandem-chat--enqueue
          (cons (if (equal (plist-get update :state) "deferred") 'edit-deferred 'edit-done) update)))))
    ("permission"
     (let ((id (plist-get update :requestId))
           (tool-use (plist-get update :toolUseId)))
       (if (equal (plist-get update :state) "pending")
           (progn
             (setq tandem-chat--pending (append tandem-chat--pending (list id))
                   tandem-chat--state "waiting")
             (when tool-use
               (puthash tool-use (float-time) tandem-chat--asked-at))
             (puthash id update tandem-chat--asked-at)
             (tandem-chat--enqueue (cons 'permission update))
             (tandem-chat--alert update))
         (let* ((asked (gethash id tandem-chat--asked-at))
                (tool-use (plist-get asked :toolUseId))
                (since (and tool-use (gethash tool-use tandem-chat--asked-at))))
           (when (numberp since)
             (puthash tool-use (round (* 1000 (- (float-time) since))) tandem-chat--waited)
             (remhash tool-use tandem-chat--asked-at))
           (remhash id tandem-chat--asked-at)
           (unless (and (equal (plist-get update :state) "answered")
                        (equal (plist-get update :decision) "allow"))
             (push (plist-get asked :toolName) tandem-chat--refused)))
         (setq tandem-chat--pending (delete id tandem-chat--pending))
         (when (and (null tandem-chat--pending)
                    (equal tandem-chat--state "waiting"))
           (setq tandem-chat--state "running"))
         (tandem-chat--enqueue (cons 'permission-done update))))
     (run-hook-with-args 'tandem-chat-permission-functions update)))
  (force-mode-line-update))

(defun tandem-chat--edit-call (update)
  "Track the edit tool call in UPDATE.
Its line is drawn only if it ends without an edit block, for example
when the daemon refused a path outside the project."
  (let ((id (plist-get update :id)))
    (if (equal (plist-get update :status) "started")
        (setq tandem-chat--edit-calls (append tandem-chat--edit-calls (list (cons id nil)))
              tandem-chat--state "tool"
              tandem-chat--tool (plist-get update :name))
      (let ((call (assoc id tandem-chat--edit-calls)))
        (setq tandem-chat--edit-calls (delq call tandem-chat--edit-calls)
              tandem-chat--state (if tandem-chat--reviews "reviewing" "running"))
        (unless (cdr call)
          (tandem-chat--enqueue (list 'tool-start id (plist-get update :title)))
          (tandem-chat--enqueue (list 'tool-end id (plist-get update :status) nil)))))))

(defun tandem-chat--alert (update)
  "Make sure the user notices the permission question in UPDATE."
  (let ((buffer (current-buffer)))
    (unless (or (get-buffer-window buffer 'visible)
                ;; Your other tabs are never touched; the message says where.
                (tandem-layout-elsewhere-p))
      (display-buffer buffer
                      `((display-buffer-in-side-window)
                        (side . right) (slot . 0)
                        (window-width . ,tandem-chat-window-width)
                        (inhibit-switch-frame . t))))
    (if (and tandem-chat-plan-open-function
             (equal (plist-get update :toolName) "ExitPlanMode"))
        (message "tandem: Claude's plan is ready: edit it, then C-c C-c to go ahead (C-c C-k: no).  \
In the chat%s, y opens it." (tandem-layout-where-text))
      (message "tandem: Claude wants to %s %s.  In the chat%s, y allows, a always allows, n denies."
               (tandem-chat--verb (plist-get update :toolName))
               (tandem-chat--subject update)
               (tandem-layout-where-text)))))

(defun tandem-chat--on-disconnect ()
  "Tell every chat buffer that the daemon connection closed."
  (maphash (lambda (_id buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq tandem-chat--state "disconnected")
                 (tandem-chat--enqueue
                  (cons 'notice "Disconnected from tandemd.  Sending a message reconnects."))
                 (force-mode-line-update))))
           tandem-chat--buffers))

(add-hook 'tandem-rpc-disconnect-hook #'tandem-chat--on-disconnect)

(defun tandem-chat--on-kill ()
  "Close this buffer's session in the daemon."
  (when tandem-chat--timer
    (cancel-timer tandem-chat--timer))
  (when tandem-chat--session-id
    (remhash tandem-chat--session-id tandem-chat--buffers)
    (when (tandem-rpc-live-p)
      (ignore-errors
        (tandem-rpc-request 'session/close
                                 (list :sessionId tandem-chat--session-id) 3)))))

;;;; Drawing

(defun tandem-chat--enqueue (item)
  "Queue ITEM for drawing and make sure a flush is scheduled."
  (push item tandem-chat--queue)
  (unless tandem-chat--timer
    (setq tandem-chat--timer
          (run-at-time tandem-chat-flush-interval nil
                       #'tandem-chat--flush-buffer (current-buffer)))))

(defun tandem-chat--flush-buffer (buffer)
  "Draw what is queued in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (tandem-chat--flush))))

(defun tandem-chat--flush ()
  "Draw every queued update in order, joining adjacent pieces of text."
  (when tandem-chat--timer
    (cancel-timer tandem-chat--timer)
    (setq tandem-chat--timer nil))
  (let ((items (nreverse tandem-chat--queue)))
    (setq tandem-chat--queue nil)
    (while items
      (let ((item (pop items)))
        ;; Text before anything else is complete: render it before the next piece is drawn.
        (unless (eq (car item) 'text)
          (tandem-chat--render-markdown t))
        (pcase (car item)
          ('text
           (let ((text (cdr item)))
             (while (eq (car-safe (car items)) 'text)
               (setq text (concat text (cdr (pop items)))))
             (tandem-chat--draw-text text)))
          ('user (tandem-chat--draw-user (cdr item)))
          ('tool-start (apply #'tandem-chat--draw-tool-start (cdr item)))
          ('tool-end (apply #'tandem-chat--draw-tool-end (cdr item)))
          ('todo (tandem-chat--draw-todo (cdr item)))
          ('result (tandem-chat--draw-result (cdr item)))
          ('error (apply #'tandem-chat--draw-error (cdr item)))
          ('notice (tandem-chat--draw-notice (cdr item)))
          ('permission (tandem-chat--draw-permission (cdr item)))
          ('edit (tandem-chat--draw-edit (cdr item)))
          ('edit-done (tandem-chat--draw-edit-done (cdr item)))
          ('edit-deferred (tandem-chat--draw-edit-deferred (cdr item)))
          ('permission-done (tandem-chat--draw-permission-done (cdr item))))))
    ;; Text still streaming: render what is complete so far.
    (tandem-chat--render-markdown nil)))

(defalias 'tandem-chat--shift-undo #'tandem-review-shift-undo
  "Move undo positions past a transcript change.
See `tandem-review-shift-undo'.")

(defmacro tandem-chat--editing-transcript (&rest body)
  "Run BODY to edit the transcript without breaking composer undo."
  (declare (indent 0) (debug t))
  `(let ((before (marker-position tandem-chat--input)))
     (let ((inhibit-read-only t)
           (buffer-undo-list t))
       (save-excursion ,@body))
     (tandem-chat--shift-undo before (- (marker-position tandem-chat--input) before))))

(defun tandem-chat--read-only (string)
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

(defun tandem-chat--insert (&rest strings)
  "Add STRINGS, read-only, at the end of the transcript."
  (tandem-chat--editing-transcript
    (goto-char tandem-chat--output)
    (dolist (s strings)
      (insert (tandem-chat--read-only s)))))

(defun tandem-chat--fresh-line ()
  "Start a new transcript line unless one has just started."
  (unless (memq (char-before tandem-chat--output) '(?\n nil))
    (tandem-chat--insert "\n")))

(defun tandem-chat--ensure-reply ()
  "Add the \"Claude\" label unless Claude's answer has already begun."
  (unless tandem-chat--replying
    (tandem-chat--fresh-line)
    (tandem-chat--insert "\n" (propertize "Claude" 'face 'tandem-chat-claude) "\n")
    (setq tandem-chat--replying t
          tandem-chat--after-tool nil)))

(defun tandem-chat--render-markdown (final)
  "Render Claude's text since the last rendering as Markdown.
With FINAL, the text is complete: render all of it and start afresh."
  (when tandem-chat--markdown-start
    (let ((done (tandem-markdown-render tandem-chat--markdown-start
                                             tandem-chat--output final)))
      (if final
          (progn (set-marker tandem-chat--markdown-start nil)
                 (setq tandem-chat--markdown-start nil))
        (set-marker tandem-chat--markdown-start done)))))

(defun tandem-chat--draw-user (text)
  "Add your message TEXT to the transcript."
  (tandem-chat--fresh-line)
  (tandem-chat--insert "\n" (propertize "You" 'face 'tandem-chat-you) "\n")
  (let ((start (marker-position tandem-chat--output)))
    (tandem-chat--insert (funcall tandem-chat-show-user-function text) "\n")
    (tandem-markdown-render start (marker-position tandem-chat--output) t))
  (setq tandem-chat--replying nil
        tandem-chat--after-tool nil))

(defun tandem-chat--draw-text (text)
  "Add TEXT from Claude's answer."
  (tandem-chat--ensure-reply)
  (when tandem-chat--after-tool
    (tandem-chat--fresh-line)
    (tandem-chat--insert "\n")
    (setq tandem-chat--after-tool nil))
  (unless tandem-chat--markdown-start
    (setq tandem-chat--markdown-start (copy-marker tandem-chat--output)))
  (tandem-chat--insert text))

(defun tandem-chat--draw-tool-start (id title)
  "Add a line for tool call ID, described by TITLE."
  (tandem-chat--ensure-reply)
  (tandem-chat--fresh-line)
  (tandem-chat--insert "  ")
  (let ((mark (copy-marker tandem-chat--output)))
    (tandem-chat--insert (propertize (concat "▸ " title) 'face 'tandem-chat-tool) "\n")
    (puthash id mark tandem-chat--tools))
  (setq tandem-chat--after-tool t))

(defun tandem-chat--duration (ms)
  "Return MS milliseconds as a short duration."
  (let ((ms (if (numberp ms) ms 0)))
    (if (< ms 1000)
        (format "%d ms" ms)
      (format "%.1f s" (/ ms 1000.0)))))

(defun tandem-chat--draw-tool-end (id status duration-ms)
  "Mark tool call ID as finished with STATUS after DURATION-MS."
  (when-let* ((mark (gethash id tandem-chat--tools)))
    (remhash id tandem-chat--tools)
    (let ((failed (equal status "error")))
      (tandem-chat--editing-transcript
        (goto-char mark)
        (delete-char 1)
        (insert (tandem-chat--read-only
                 (propertize (if failed "✗" "✓")
                             'face (if failed 'tandem-chat-tool-error 'tandem-chat-tool))))
        (end-of-line)
        (when (numberp duration-ms)
          (insert (tandem-chat--read-only
                   (propertize (concat "  " (tandem-chat--duration duration-ms))
                               'face 'tandem-chat-meta))))))
    (set-marker mark nil)))

(defun tandem-chat--draw-todo (items)
  "Show ITEMS, Claude's todo list, at the top of the buffer."
  (let ((text (if (seq-empty-p items)
                  ""
                (concat
                 (propertize "Plan\n" 'face 'tandem-chat-claude)
                 (mapconcat
                  (lambda (item)
                    (let ((status (plist-get item :status)))
                      (concat "  "
                              (pcase status ("completed" "✓") ("in_progress" "▸") (_ "○"))
                              " " (plist-get item :content) "\n")))
                  items "")
                 "\n"))))
    (tandem-chat--editing-transcript
      (delete-region (point-min) tandem-chat--todo-end)
      (goto-char (point-min))
      (insert-before-markers (tandem-chat--read-only text)))))

(defun tandem-chat--draw-result (result)
  "Close Claude's answer with a line about RESULT."
  (let ((cancelled (eq (plist-get result :cancelled) t))
        (failed (eq (plist-get result :isError) t))
        ;; Denials you made yourself already show on their question.
        (denied (seq-remove (lambda (tool) (member tool tandem-chat--refused))
                            (delete-dups (append (plist-get result :permissionDenials) nil)))))
    (tandem-chat--fresh-line)
    (cond
     (cancelled
      (tandem-chat--insert (propertize "  Stopped." 'face 'tandem-chat-meta) "\n"))
     (failed
      (tandem-chat--insert
       (propertize (format "  Claude stopped: %s"
                           (or (plist-get result :message) (plist-get result :subtype)))
                   'face 'tandem-chat-error)
       "\n"))
     (t
      (tandem-chat--insert
       (propertize (format "  %s · $%.4f"
                           (tandem-chat--duration (plist-get result :durationMs))
                           (or (plist-get result :costUsd) 0))
                   'face 'tandem-chat-meta)
       "\n")))
    (when denied
      (tandem-chat--insert
       (propertize (format "  Not allowed: %s.  Claude Code denied it without asking you, \
because of a deny rule or because no Emacs could answer.\n"
                           (string-join denied ", "))
                   'face 'tandem-chat-meta)))
    (setq tandem-chat--replying nil
          tandem-chat--after-tool nil
          tandem-chat--refused nil)))

(defun tandem-chat--draw-error (message stderr)
  "Add an error line with MESSAGE and the end of STDERR."
  (tandem-chat--fresh-line)
  (tandem-chat--insert (propertize (concat "  " message) 'face 'tandem-chat-error) "\n")
  (when (and (stringp stderr) (not (string-empty-p (string-trim stderr))))
    (let ((lines (last (split-string (string-trim-right stderr) "\n") 5)))
      (tandem-chat--insert
       (propertize (mapconcat (lambda (l) (concat "    " l "\n")) lines "")
                   'face 'tandem-chat-meta))))
  (setq tandem-chat--replying nil
        tandem-chat--after-tool nil))

(defun tandem-chat--draw-notice (text)
  "Add the notice TEXT to the transcript."
  (tandem-chat--fresh-line)
  (tandem-chat--insert (propertize (concat "  " text) 'face 'tandem-chat-meta) "\n"))

(defun tandem-chat--verb (tool)
  "Return what Claude wants to do with TOOL, as a verb phrase."
  (pcase tool
    ("Bash" "run")
    ("WebFetch" "fetch")
    ("WebSearch" "search the web for")
    (_ (format "use %s" tool))))

(defun tandem-chat--subject (update)
  "Return a short description of what permission UPDATE is about."
  (let ((input (plist-get update :input)))
    (pcase (plist-get update :toolName)
      ("Bash" (format "`%s'" (truncate-string-to-width
                             (car (split-string (or (plist-get input :command) "") "\n"))
                             60 nil nil "…")))
      ("WebFetch" (or (plist-get input :url) ""))
      ("WebSearch" (format "\"%s\"" (or (plist-get input :query) "")))
      (_ (or (plist-get update :title) "")))))

(defun tandem-chat--fontify-shell (code)
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

(defun tandem-chat--indent (text prefix)
  "Return TEXT with PREFIX before every line, each ending in a newline."
  (mapconcat (lambda (line) (concat prefix line "\n"))
             (split-string (string-trim-right text "\n") "\n")
             ""))

(defun tandem-chat--permission-detail (tool input)
  "Return the lines that show TOOL's INPUT in a permission request."
  (pcase tool
    ("Bash"
     (concat (tandem-chat--indent
              (tandem-chat--fontify-shell (or (plist-get input :command) ""))
              "      ")
             (when-let* ((description (plist-get input :description)))
               (propertize (format "      (%s)\n" description) 'face 'tandem-chat-meta))))
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

(defun tandem-chat--key (key)
  "Return KEY in the face for answer keys."
  (propertize key 'face 'tandem-chat-keys))

(defun tandem-chat--draw-question (id head hint keymap property &optional extra)
  "Add question ID to the transcript: HEAD, then the HINT line.
KEYMAP and the text property PROPERTY, whose value is ID, cover the
block until it is resolved.  EXTRA is a plist kept with the block."
  (tandem-chat--ensure-reply)
  (tandem-chat--fresh-line)
  (let ((start (copy-marker tandem-chat--output)))
    (tandem-chat--insert head)
    (let ((hint-start (copy-marker tandem-chat--output)))
      (tandem-chat--insert hint "\n")
      (let ((end (copy-marker tandem-chat--output)))
        (tandem-chat--editing-transcript
          (add-text-properties start end (list 'keymap keymap property id)))
        (puthash id (append (list :start start :hint-start hint-start :end end :property property)
                            extra)
                 tandem-chat--permissions)))))

(defun tandem-chat--resolve-question (id outcome)
  "Replace question ID's hint line with OUTCOME and remove its keys."
  (when-let* ((entry (gethash id tandem-chat--permissions)))
    (remhash id tandem-chat--permissions)
    (tandem-chat--editing-transcript
      (let ((hint-start (plist-get entry :hint-start))
            (end (plist-get entry :end)))
        (delete-region hint-start (1- end))
        (goto-char hint-start)
        (insert (tandem-chat--read-only outcome))
        (remove-list-of-text-properties (plist-get entry :start) end
                                        (list 'keymap (plist-get entry :property)))))
    (dolist (key '(:start :hint-start :end))
      (set-marker (plist-get entry key) nil))))

(defun tandem-chat--draw-permission (update)
  "Add the permission question in UPDATE to the transcript."
  (let ((tool (plist-get update :toolName))
        (rule (or (plist-get update :alwaysRule) (plist-get update :toolName))))
    (if (and tandem-chat-plan-open-function (equal tool "ExitPlanMode"))
        (tandem-chat--draw-question
         (plist-get update :requestId)
         (propertize "  📋 Claude's plan is ready.  Edit it in Org, then C-c C-c there to go ahead.\n"
                     'face 'tandem-chat-ask)
         (concat "    " (tandem-chat--key "y") " or " (tandem-chat--key "RET") " open the plan   "
                 (tandem-chat--key "n") " say no   "
                 (tandem-chat--key "d") " say no with a reason")
         tandem-chat-permission-map 'tandem-request
         (list :rule rule))
    (tandem-chat--draw-question
     (plist-get update :requestId)
     (concat (propertize (format "  ⏸ Claude wants to %s:\n" (tandem-chat--verb tool))
                         'face 'tandem-chat-ask)
             (tandem-chat--permission-detail tool (plist-get update :input)))
     (concat "    " (tandem-chat--key "y") " allow once   "
             (tandem-chat--key "a") " always allow "
             (propertize rule 'face 'tandem-chat-meta)
             "   " (tandem-chat--key "n") " deny   "
             (tandem-chat--key "d") " deny with a reason")
     tandem-chat-permission-map 'tandem-request
     (list :rule rule)))))

(defun tandem-chat--draw-permission-done (update)
  "Replace the keys of the question UPDATE answers or withdraws with the outcome."
  (let* ((id (plist-get update :requestId))
         (rule (plist-get (gethash id tandem-chat--permissions) :rule))
         (allowed (equal (plist-get update :decision) "allow"))
         (message (plist-get update :message)))
    (tandem-chat--resolve-question
     id
     (if (equal (plist-get update :state) "withdrawn")
         (propertize (format "    Withdrawn: %s" (plist-get update :reason))
                     'face 'tandem-chat-meta)
       (cond
        ((and allowed (eq (plist-get update :always) t))
         (propertize (format "    ✓ Always allowed: %s" rule) 'face 'tandem-chat-tool))
        (allowed (propertize "    ✓ Allowed" 'face 'tandem-chat-tool))
        (t (propertize (if (and (stringp message) (not (string-empty-p message)))
                           (format "    ✗ Denied: %s" message)
                         "    ✗ Denied")
                       'face 'tandem-chat-tool-error)))))))

(defvar tandem-chat--hunk-totals (make-hash-table :test #'equal)
  "From edit id to its number of hunks, kept from when Emacs showed it.
The block may be drawn after you decided the edit, when it is gone.")

(defun tandem-chat--edit-lines (update)
  "Return (HEAD . HINT), the two lines of the edit block for UPDATE."
  (let* ((id (plist-get update :requestId))
         (total (or (cdr (tandem-review-hunk-count id))
                    (gethash id tandem-chat--hunk-totals)))
         (all (if (and total (> total 1)) " all" "")))
    (cons
     (propertize (format "  ✎ Claude wants to %s %s%s\n"
                         (if (equal (plist-get update :editKind) "write") "write" "edit")
                         (plist-get update :relPath)
                         (if (and total (> total 1)) (format " · %d hunks" total) ""))
                 'face 'tandem-chat-ask)
     (if (tandem-review-pending-p id)
         (concat "    " (tandem-chat--key "y") " apply" all "   "
                 (tandem-chat--key "n") " reject" all "   "
                 (tandem-chat--key "d") " reject" all " with a reason   "
                 (tandem-chat--key "RET") (if (string-empty-p all) " show" " show, decide hunk by hunk"))
       (propertize "    Waiting for review…" 'face 'tandem-chat-meta)))))

(defun tandem-chat--draw-edit (update)
  "Add the proposed edit in UPDATE to the transcript."
  (let ((lines (tandem-chat--edit-lines update)))
    (tandem-chat--draw-question
     (plist-get update :requestId) (car lines) (cdr lines)
     tandem-chat-edit-map 'tandem-edit (list :update update))))

(defun tandem-chat--refresh-edit (proposal)
  "Redraw the chat block of PROPOSAL, now that its hunks are known.
The block can be drawn before Emacs has shown the edit, and then it
has neither its keys nor its number of hunks."
  (let ((id (plist-get proposal :id)))
    (puthash id (length (plist-get proposal :hunks)) tandem-chat--hunk-totals)
    (maphash
     (lambda (_session buffer)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (when-let* ((entry (and (hash-table-p tandem-chat--permissions)
                                   (gethash id tandem-chat--permissions)))
                       (update (plist-get entry :update)))
             (let ((lines (tandem-chat--edit-lines update))
                   (start (plist-get entry :start))
                   (hint-start (plist-get entry :hint-start))
                   (end (plist-get entry :end)))
               (tandem-chat--editing-transcript
                 ;; Both lines end in a newline that stays; the markers before
                 ;; each line do not move when text goes in after them.
                 (delete-region hint-start (1- end))
                 (goto-char hint-start)
                 (insert (tandem-chat--read-only (cdr lines)))
                 (delete-region start (1- hint-start))
                 (goto-char start)
                 (insert (tandem-chat--read-only (string-remove-suffix "\n" (car lines))))
                 (add-text-properties start end (list 'keymap tandem-chat-edit-map
                                                      'tandem-edit id))))))))
     tandem-chat--buffers)))

(add-hook 'tandem-review-show-functions #'tandem-chat--refresh-edit)

(defun tandem-chat--with-reviews (text)
  "Return TEXT, your message, preceded by your review of deferred edits."
  (if (null tandem-chat--review-results)
      text
    (concat "My review of your earlier edits (deferred review):\n"
            (mapconcat (lambda (r) (concat "- " (car r))) tandem-chat--review-results "\n")
            "\n\n" text)))

(defun tandem-chat-send-reviews ()
  "Send your review of deferred edits to Claude, with whatever you typed."
  (interactive)
  (tandem-chat--check-buffer)
  (unless tandem-chat--review-results
    (user-error "No review results wait to go to Claude"))
  (when (string-empty-p (string-trim (tandem-chat--input-text)))
    (tandem-chat--set-input "Here is my review; carry on with it in mind."))
  (tandem-chat-send))

(defun tandem-chat--on-deferred (session id text)
  "Keep TEXT, your decision on deferred edit ID, for SESSION's next message."
  (when-let* ((buffer (gethash session tandem-chat--buffers)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq tandem-chat--review-results
              (append tandem-chat--review-results
                      (list (cons text (and (string-match-p "the user asks:" text) id)))))
        (tandem-chat--resolve-question
         id (propertize (concat "    ✓ Decided; goes to Claude with your next message (C-c C-r sends it now)")
                        'face 'tandem-chat-tool))
        (force-mode-line-update)))))

(add-hook 'tandem-review-deferred-functions #'tandem-chat--on-deferred)

(defun tandem-chat--draw-edit-deferred (update)
  "Show that the edit in UPDATE waits for you while Claude carries on."
  (let ((id (plist-get update :requestId)))
    (when-let* ((entry (gethash id tandem-chat--permissions)))
      (let ((hint-start (plist-get entry :hint-start))
            (end (plist-get entry :end)))
        (tandem-chat--editing-transcript
          (delete-region hint-start (1- end))
          (goto-char hint-start)
          (insert (tandem-chat--read-only
                   (concat (propertize "    ⧗ Deferred: Claude carries on · " 'face 'tandem-chat-meta)
                           (tandem-chat--key "y") " apply   "
                           (tandem-chat--key "n") " reject   "
                           (tandem-chat--key "RET") " show")))
          (add-text-properties (plist-get entry :start) end
                               (list 'keymap tandem-chat-edit-map 'tandem-edit id)))))))

(defun tandem-chat--refresh-headers (&rest _)
  "Redraw the header lines, whose counts of waiting hunks may have changed."
  (force-mode-line-update t))

(add-hook 'tandem-review-show-functions #'tandem-chat--refresh-headers)
(add-hook 'tandem-review-settle-functions #'tandem-chat--refresh-headers)

(defun tandem-chat--stop-answering ()
  "Finish the note Claude was answering into, if any."
  (when tandem-chat--answering
    (tandem-review-note-done tandem-chat--answering)
    (setq tandem-chat--answering nil)))

(defun tandem-chat--question-text (update)
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
                 'face 'tandem-chat-ask)
     (if (> applied 0)
         (propertize (format "\n      %d of %d hunks applied first" applied (length hunks))
                     'face 'tandem-chat-meta)
       ""))))

(defun tandem-chat--partial-text (update)
  "Describe the hunk by hunk outcome in UPDATE, one line per hunk not applied."
  (let* ((hunks (append (plist-get update :hunks) nil))
         (applied (seq-count (lambda (h) (equal (plist-get h :decision) "applied")) hunks)))
    (concat
     (propertize (format "    ◐ Applied %d of %d hunks%s" applied (length hunks)
                         (cond ((zerop applied) "")
                               ((eq (plist-get update :saved) t) ", saved")
                               (t ", not saved: the buffer has unsaved changes of yours")))
                 'face 'tandem-chat-tool)
     (mapconcat
      (lambda (h)
        (let ((note (plist-get h :note)))
          (propertize
           (format "\n      ✗ hunk %d (line %d) %s%s" (plist-get h :index) (plist-get h :line)
                   (if (equal (plist-get h :decision) "rejected") "rejected" "not applied")
                   (if (and (stringp note) (not (string-empty-p note)))
                       (concat ": " (car (split-string note "\n")))
                     ""))
           'face 'tandem-chat-tool-error)))
      (seq-remove (lambda (h) (equal (plist-get h :decision) "applied")) hunks)
      ""))))

(defun tandem-chat--draw-edit-done (update)
  "Replace the keys of the edit UPDATE settles with the outcome."
  (let ((message (or (plist-get update :message) "")))
    (tandem-chat--resolve-question
     (plist-get update :requestId)
     (pcase (plist-get update :state)
       ("applied"
        (propertize (cond ((eq (plist-get update :created) t) "    ✓ Created and saved")
                          ((eq (plist-get update :saved) t) "    ✓ Applied and saved")
                          (t "    ✓ Applied, not saved: the buffer has unsaved changes of yours"))
                    'face 'tandem-chat-tool))
       ("rejected"
        (propertize (if (string-empty-p message) "    ✗ Rejected" (format "    ✗ Rejected: %s" message))
                    'face 'tandem-chat-tool-error))
       ("partial"
        (tandem-chat--partial-text update))
       ("question"
        (tandem-chat--question-text update))
       ("error"
        (propertize (format "    ✗ Not applied: %s" (car (split-string message "\n")))
                    'face 'tandem-chat-tool-error))
       (_
        (propertize (format "    Withdrawn: %s" (plist-get update :reason))
                    'face 'tandem-chat-meta))))))

;;;; Deciding on edits from the chat

(defun tandem-chat--edit-at-point ()
  "Return the edit on the line at point, else the oldest waiting one."
  (or (get-text-property (point) 'tandem-edit)
      (car tandem-chat--reviews)
      (user-error "No edit is waiting for your review")))

(defun tandem-chat-apply-edit ()
  "Apply the proposed edit at point."
  (interactive)
  (tandem-review-apply (tandem-chat--edit-at-point)))

(defun tandem-chat-reject-edit ()
  "Reject the proposed edit at point."
  (interactive)
  (tandem-review-reject (tandem-chat--edit-at-point) ""))

(defun tandem-chat-reject-edit-with-reason ()
  "Reject the proposed edit at point and tell Claude why."
  (interactive)
  (let ((id (tandem-chat--edit-at-point)))
    (tandem-review-reject id (read-string "Tell Claude why, or what to do instead: "))))

(defun tandem-chat-show-edit ()
  "Show the proposed edit at point in its file's buffer."
  (interactive)
  (tandem-review-show (tandem-chat--edit-at-point)))

;;;; Answering permission questions

(defun tandem-chat--request-at-point ()
  "Return the request on the line at point, else the oldest pending one."
  (or (get-text-property (point) 'tandem-request)
      (car tandem-chat--pending)
      (user-error "No permission question is waiting")))

(defun tandem-chat--answer (id decision &optional always message input)
  "Answer permission request ID with DECISION, \"allow\" or \"deny\".
ALWAYS adds a rule; MESSAGE tells Claude why it was denied.  INPUT, a
plist, replaces the tool's input when allowed."
  (condition-case err
      (tandem-rpc-request 'permission/answer
                               (append
                                (list :requestId id :decision decision
                                      :always (if always t :json-false)
                                      :message (or message ""))
                                (when input (list :updatedInput input))))
    (jsonrpc-error
     (message "tandem: %s" (tandem-rpc-error-message err)))))

(defun tandem-chat-allow ()
  "Allow the permission request at point, once.
For Claude's plan, open it instead: you approve it there."
  (interactive)
  (tandem-chat--check-buffer)
  (let ((id (tandem-chat--request-at-point)))
    (if (tandem-chat--plan-question-p id)
        (funcall tandem-chat-plan-open-function id)
      (tandem-chat--answer id "allow"))))

(defun tandem-chat-allow-always ()
  "Allow the permission request at point, and keep allowing it in this project.
Claude Code saves the rule in the project's .claude/settings.local.json."
  (interactive)
  (tandem-chat--check-buffer)
  (let ((id (tandem-chat--request-at-point)))
    (if (tandem-chat--plan-question-p id)
        (funcall tandem-chat-plan-open-function id)
      (tandem-chat--answer id "allow" t))))

(defun tandem-chat-deny ()
  "Deny the permission request at point."
  (interactive)
  (tandem-chat--check-buffer)
  (tandem-chat--answer (tandem-chat--request-at-point) "deny"))

(defun tandem-chat-deny-with-reason ()
  "Deny the permission request at point and tell Claude why."
  (interactive)
  (tandem-chat--check-buffer)
  (let ((id (tandem-chat--request-at-point)))
    (tandem-chat--answer id "deny" nil
                              (read-string "Tell Claude why, or what to do instead: "))))

(defun tandem-chat-answer-permission ()
  "Answer the permission request at point, or the oldest one, from a menu."
  (interactive)
  (tandem-chat--check-buffer)
  (when (tandem-chat--plan-question-p (tandem-chat--request-at-point))
    (funcall tandem-chat-plan-open-function (tandem-chat--request-at-point))
    (user-error "Edit the plan, then C-c C-c to go ahead or C-c C-k to say no"))
  (let* ((id (tandem-chat--request-at-point))
         (rule (plist-get (gethash id tandem-chat--permissions) :rule))
         (choice (read-multiple-choice
                  "Claude is waiting for your answer"
                  `((?y "allow once")
                    (?a "always allow" ,(format "Allow now and in future: %s" rule))
                    (?n "deny")
                    (?d "deny with a reason")))))
    (pcase (car choice)
      (?y (tandem-chat--answer id "allow"))
      (?a (tandem-chat--answer id "allow" t))
      (?n (tandem-chat--answer id "deny"))
      (?d (tandem-chat--answer
           id "deny" nil (read-string "Tell Claude why, or what to do instead: "))))))

;;;###autoload
(defun tandem-answer-permission ()
  "Answer Claude's waiting permission question from any buffer."
  (interactive)
  (let ((buffer (if (and (derived-mode-p 'tandem-chat-mode) tandem-chat--pending)
                    (current-buffer)
                  (catch 'found
                    (maphash (lambda (_id b)
                               (when (and (buffer-live-p b)
                                          (buffer-local-value 'tandem-chat--pending b))
                                 (throw 'found b)))
                             tandem-chat--buffers)
                    nil))))
    (unless buffer
      (user-error "Claude is not waiting for an answer"))
    (with-current-buffer buffer
      (tandem-chat-answer-permission))))

;;;; Header line

(defun tandem-chat--state-text ()
  "Describe `tandem-chat--state' in a few words."
  (pcase tandem-chat--state
    ("idle" "ready")
    ("starting" "starting Claude…")
    ("running" "thinking…")
    ("writing" "writing…")
    ("tool" (format "running %s…" (or tandem-chat--tool "a tool")))
    ("cancelling" "stopping…")
    ("waiting" "waiting for your answer")
    ("reviewing" "waiting for your review")
    ("disconnected" "disconnected")
    (other other)))

(defun tandem-chat--header-line ()
  "Return the chat buffer's header line."
  (concat " "
          (propertize "Claude" 'face 'tandem-chat-claude)
          (when tandem-chat--model
            (concat " · " tandem-chat--model))
          " · " (tandem-chat--state-text)
          (let ((waiting (tandem-review-waiting tandem-chat--session-id)))
            (when (> waiting 0)
              (propertize (format " · %d hunk%s waiting" waiting (if (= waiting 1) "" "s"))
                          'face 'tandem-chat-ask)))
          (when tandem-chat--review-results
            (propertize (format " · %d review result%s for Claude (C-c C-r)"
                                (length tandem-chat--review-results)
                                (if (cdr tandem-chat--review-results) "s" ""))
                        'face 'tandem-chat-ask))
          (when (and (numberp tandem-chat--cost) (> tandem-chat--cost 0))
            (format " · $%.4f" tandem-chat--cost))))

(provide 'tandem-chat)
;;; tandem-chat.el ends here
