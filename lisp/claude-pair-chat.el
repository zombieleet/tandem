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
;;   M-p, M-n  step through earlier messages
;;
;; Updates from the daemon are queued and drawn every
;; `claude-pair-chat-flush-interval' seconds, so long answers do not make
;; typing or redisplay stutter.  Claude's todo list, when it keeps one,
;; sits at the top of the buffer.

;;; Code:

(require 'claude-pair-rpc)
(require 'project)
(require 'ring)
(require 'subr-x)

(defcustom claude-pair-claude-command nil
  "Path of the claude command, or nil to look for \"claude\" on variable `exec-path'."
  :type '(choice (const :tag "Find on exec-path" nil) file)
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
(defvar-local claude-pair-chat--cost 0 "Cost of the session so far, in US dollars.")
(defvar-local claude-pair-chat--tools nil "Map from tool call id to the marker of its status mark.")
(defvar-local claude-pair-chat--replying nil "Non-nil once Claude's answer to the last message has begun.")
(defvar-local claude-pair-chat--after-tool nil "Non-nil when the transcript ends with a tool line.")
(defvar-local claude-pair-chat--history nil "Ring of sent messages.")
(defvar-local claude-pair-chat--history-index nil "Position in the history ring, or nil.")

(defvar-keymap claude-pair-chat-mode-map
  "C-c C-c" #'claude-pair-chat-send
  "C-c C-k" #'claude-pair-chat-cancel
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
  (let* ((params (list :cwd root :claudePath (claude-pair-chat--claude-path)))
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

(defun claude-pair-chat--display (buffer)
  "Show BUFFER in a side window on the right and select it."
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
     (claude-pair-chat--enqueue (cons 'text (plist-get update :delta))))
    ("tool"
     (if (equal (plist-get update :status) "started")
         (progn
           (setq claude-pair-chat--state "tool"
                 claude-pair-chat--tool (plist-get update :name))
           (claude-pair-chat--enqueue
            (list 'tool-start (plist-get update :id) (plist-get update :title))))
       (setq claude-pair-chat--state "running")
       (claude-pair-chat--enqueue
        (list 'tool-end (plist-get update :id) (plist-get update :status)
              (plist-get update :durationMs)))))
    ("todo"
     (claude-pair-chat--enqueue (cons 'todo (plist-get update :items))))
    ("result"
     (let ((cost (plist-get update :sessionCostUsd)))
       (when (numberp cost)
         (setq claude-pair-chat--cost cost)))
     (claude-pair-chat--enqueue (cons 'result update)))
    ("error"
     (claude-pair-chat--enqueue
      (list 'error (plist-get update :message) (plist-get update :stderr)))))
  (force-mode-line-update))

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
          ('notice (claude-pair-chat--draw-notice (cdr item))))))))

(defun claude-pair-chat--shift-undo (pos delta)
  "Move positions at or after POS in `buffer-undo-list' by DELTA.
The transcript changes without undo records, so composer edits
recorded before a change have to move with the text."
  (unless (or (zerop delta) (eq buffer-undo-list t))
    (let ((shift (lambda (p)
                   (cond ((not (integerp p)) p)
                         ((and (>= p 0) (>= p pos)) (+ p delta))
                         ((and (< p 0) (>= (- p) pos)) (- p delta))
                         (t p)))))
      (setq buffer-undo-list
            (mapcar
             (lambda (entry)
               (cond
                ((integerp entry) (funcall shift entry))
                ((and (consp entry) (integerp (car entry)) (integerp (cdr entry)))
                 (cons (funcall shift (car entry)) (funcall shift (cdr entry))))
                ((and (consp entry) (stringp (car entry)) (integerp (cdr entry)))
                 (cons (car entry) (funcall shift (cdr entry))))
                ((and (consp entry) (null (car entry)) (consp (cdr entry))
                      (consp (cddr entry)) (consp (cdddr entry)))
                 (let ((range (cdddr entry)))
                   (if (and (integerp (car range)) (integerp (cdr range)))
                       (append (list nil (cadr entry) (caddr entry))
                               (cons (funcall shift (car range)) (funcall shift (cdr range))))
                     entry)))
                (t entry)))
             buffer-undo-list)))))

(defmacro claude-pair-chat--editing-transcript (&rest body)
  "Run BODY to edit the transcript without breaking composer undo."
  (declare (indent 0) (debug t))
  `(let ((before (marker-position claude-pair-chat--input)))
     (let ((inhibit-read-only t)
           (buffer-undo-list t))
       (save-excursion ,@body))
     (claude-pair-chat--shift-undo before (- (marker-position claude-pair-chat--input) before))))

(defun claude-pair-chat--read-only (string)
  "Return STRING marked read-only, so text cannot be typed into or beside it."
  (propertize string 'read-only t 'front-sticky '(read-only)))

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
        (insert (claude-pair-chat--read-only
                 (propertize (concat "  " (claude-pair-chat--duration duration-ms))
                             'face 'claude-pair-chat-meta)))))
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
        (denied (append (plist-get result :permissionDenials) nil)))
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
       (propertize (format "  Not allowed yet: %s.  Tools that need your approval are \
denied until permission prompts arrive.\n"
                           (string-join denied ", "))
                   'face 'claude-pair-chat-meta)))
    (setq claude-pair-chat--replying nil
          claude-pair-chat--after-tool nil)))

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
