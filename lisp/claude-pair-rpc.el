;;; claude-pair-rpc.el --- Connection to the claude-pair daemon  -*- lexical-binding: t; -*-

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

;; Talks to claude-paird, the background daemon that runs Claude, over a
;; Unix socket using JSON-RPC 2.0 (see protocol/PROTOCOL.md).
;;
;; `claude-pair-rpc-connection' returns a live, initialized connection.
;; When no daemon answers on the socket it starts one with
;; "claude-paird --detach", which returns once the socket is ready.
;; The daemon is not a child of Emacs, so it keeps running when Emacs
;; exits, and stops by itself after `claude-pair-daemon-idle-timeout'
;; seconds without clients.

;;; Code:

(require 'cl-lib)
(require 'jsonrpc)
(require 'seq)
(require 'subr-x)

(defgroup claude-pair nil
  "Pair-program with Claude inside Emacs."
  :group 'tools
  :prefix "claude-pair-")

(defconst claude-pair-version "0.1.0"
  "Version of the claude-pair Emacs package.")

(defvar claude-pair-rpc-protocol-version "0.6.0"
  "Protocol version this client speaks.  See protocol/PROTOCOL.md.")

(defcustom claude-pair-daemon-command nil
  "Command that runs claude-paird, as a list of strings.
When nil, use \"claude-paird\" from variable `exec-path', or else the
binary that \"make daemon\" builds next to this package."
  :type '(choice (const :tag "Find automatically" nil)
                 (repeat :tag "Command and arguments" string)))

(defcustom claude-pair-socket-path nil
  "Socket the daemon listens on, or nil for the default.
The default is $XDG_RUNTIME_DIR/claude-pair/daemon.sock.  The
directory holding the socket must be private to you (mode 700)."
  :type '(choice (const :tag "Default" nil) file))

(defcustom claude-pair-daemon-idle-timeout 600
  "Seconds the daemon keeps running with no Emacs connected.
Zero keeps it running until you stop it.  Applies to daemons that
Emacs starts."
  :type 'natnum)

(defcustom claude-pair-daemon-start-timeout 10
  "Seconds to wait for a newly started daemon to accept connections."
  :type 'natnum)

(defcustom claude-pair-events-buffer-size 2000000
  "Maximum size in characters of the protocol log buffer.
Zero turns the log off; nil keeps everything."
  :type '(choice (const :tag "No limit" nil) natnum))

(defvar claude-pair-rpc-notification-functions nil
  "Abnormal hook run for each notification from the daemon.
Each function receives the method (a symbol) and the params (a plist).")

(defvar claude-pair-rpc-disconnect-hook nil
  "Normal hook run after the connection to the daemon closes.")

(defvar claude-pair-rpc--connection nil
  "The current `jsonrpc-process-connection' to the daemon, or nil.")

(defvar claude-pair-rpc--server-info nil
  "Result of the last successful initialize, as a plist.")

(defvar claude-pair-rpc--expected-disconnect nil
  "Non-nil while Emacs closes the connection on purpose.")

(define-error 'claude-pair-rpc-incompatible
  "The running claude-paird speaks another protocol version" 'user-error)

(defconst claude-pair-rpc--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this file was loaded from.")

(defconst claude-pair-rpc--max-socket-path-bytes 103
  "Longest socket path the daemon accepts (the macOS limit).")

;;;; Paths and commands

(defun claude-pair-rpc-default-socket-path ()
  "Return the default socket path.
Keep this in step with daemon/internal/paths/paths.go."
  (let ((xdg (getenv "XDG_RUNTIME_DIR")))
    (expand-file-name
     "daemon.sock"
     (if (and xdg (not (string-empty-p xdg)) (file-name-absolute-p xdg))
         (expand-file-name "claude-pair" xdg)
       (expand-file-name (format "claude-pair-%d" (user-uid))
                         temporary-file-directory)))))

(defun claude-pair-rpc-socket-path ()
  "Return the socket path in use."
  (expand-file-name (or claude-pair-socket-path
                        (claude-pair-rpc-default-socket-path))))

(defun claude-pair-rpc-daemon-command ()
  "Return the command list for starting the daemon.
Signal a `user-error' when no daemon can be found."
  (or claude-pair-daemon-command
      (when-let* ((exe (executable-find "claude-paird")))
        (list exe))
      (let ((built (claude-pair-rpc--built-daemon)))
        (when (file-executable-p built)
          (list built)))
      (user-error "Cannot find claude-paird; run \"make daemon\" in %s or set `claude-pair-daemon-command'"
                  (abbreviate-file-name
                   (file-name-directory (directory-file-name claude-pair-rpc--directory))))))

(defun claude-pair-rpc--built-daemon ()
  "Return where \"make daemon\" puts the daemon binary."
  (expand-file-name "../daemon/bin/claude-paird" claude-pair-rpc--directory))

;;;; Starting and connecting

(defun claude-pair-rpc--open-process (path)
  "Return a network process connected to PATH, or nil if nothing listens."
  (when (> (string-bytes (encode-coding-string path 'utf-8))
           claude-pair-rpc--max-socket-path-bytes)
    (user-error "Socket path is longer than %d bytes: %s"
                claude-pair-rpc--max-socket-path-bytes path))
  (condition-case nil
      (make-network-process :name "claude-pair"
                            :family 'local
                            :service path
                            :coding 'utf-8-emacs-unix
                            :noquery t)
    (file-error nil)))

(defun claude-pair-rpc--start-daemon (path)
  "Start a detached daemon listening on PATH and wait until it is ready.
Return the launcher's output."
  (let* ((command (append (claude-pair-rpc-daemon-command)
                          (list "--detach"
                                "--socket" path
                                "--idle-timeout"
                                (number-to-string claude-pair-daemon-idle-timeout)
                                "--ready-timeout"
                                (number-to-string claude-pair-daemon-start-timeout))))
         (status nil)
         (output ""))
    (with-temp-buffer
      (setq status
            (condition-case err
                (apply #'call-process (car command) nil t nil (cdr command))
              (file-missing
               (user-error "Cannot run %s: %s" (car command)
                           (error-message-string err)))))
      (setq output (string-trim (buffer-string))))
    (unless (eql status 0)
      (user-error "The claude-pair daemon did not start (%s): %s" status output))
    output))

(defun claude-pair-rpc--make-connection (process)
  "Wrap PROCESS in a `jsonrpc-process-connection'."
  (prog1 (jsonrpc-process-connection
          :name "claude-pair"
          :process process
          :events-buffer-config (list :size claude-pair-events-buffer-size :format 'full)
          :request-dispatcher #'claude-pair-rpc--dispatch-request
          :notification-dispatcher #'claude-pair-rpc--dispatch-notification
          :on-shutdown #'claude-pair-rpc--on-shutdown)
    ;; jsonrpc's sentinel always says "Server exited with status N", which
    ;; means nothing for a socket.  Hide its messages; ours come after.
    (let ((sentinel (process-sentinel process)))
      (set-process-sentinel process
                            (lambda (proc change)
                              (let ((inhibit-message t)
                                    (message-log-max nil))
                                (funcall sentinel proc change)))))))

(defun claude-pair-rpc--initialize (connection)
  "Send initialize on CONNECTION and return the result.
Close CONNECTION and signal a `user-error' when the daemon refuses."
  (condition-case err
      (jsonrpc-request
       connection 'initialize
       (list :protocolVersion claude-pair-rpc-protocol-version
             :clientInfo (list :name "claude-pair.el" :version claude-pair-version)
             :capabilities (list :childFrames (if (display-graphic-p) t :json-false)
                                 :maxWindows 5))
       :timeout 5)
    (jsonrpc-error
     (claude-pair-rpc--close connection)
     (let* ((data (cdr err))
            (code (alist-get 'jsonrpc-error-code data))
            (message (alist-get 'jsonrpc-error-message data))
            (extra (alist-get 'jsonrpc-error-data data)))
       (if (eql code -32001)
           (signal 'claude-pair-rpc-incompatible
                   (list (format "This claude-pair speaks protocol %s, but the running claude-paird \
speaks %s.  Run M-x claude-pair-stop-daemon to stop it, then try again"
                                 claude-pair-rpc-protocol-version
                                 (or (plist-get extra :daemonProtocolVersion) "another version"))
                         (plist-get extra :daemonProtocolVersion)))
         (user-error "The claude-pair daemon refused to initialize: %s"
                     (or message "no reason given")))))))

(defun claude-pair-rpc-live-p ()
  "Return non-nil when Emacs has a live connection to the daemon."
  (and claude-pair-rpc--connection
       (jsonrpc-running-p claude-pair-rpc--connection)))

(defun claude-pair-rpc-connection (&optional no-start)
  "Return a live, initialized connection to the daemon.
Start the daemon when nothing answers on the socket, unless NO-START
is non-nil, in which case return nil.  When the running daemon speaks
another protocol version, offer to restart it."
  (if (claude-pair-rpc-live-p)
      claude-pair-rpc--connection
    (condition-case err
        (claude-pair-rpc--connect no-start)
      (claude-pair-rpc-incompatible
       (if (and (not no-start)
                (not noninteractive)
                (y-or-n-p (format "The running claude-paird speaks protocol %s, this \
claude-pair needs %s; restart it, ending its sessions? "
                                  (or (nth 2 err) "another version")
                                  claude-pair-rpc-protocol-version)))
           (progn
             (claude-pair-rpc-stop-without-handshake)
             (claude-pair-rpc--connect nil))
         (signal (car err) (cdr err)))))))

(defun claude-pair-rpc--connect (no-start)
  "Connect to the daemon, starting it unless NO-START, and initialize."
  (let* ((path (claude-pair-rpc-socket-path))
           (process (or (claude-pair-rpc--open-process path)
                        (unless no-start
                          (claude-pair-rpc--start-daemon path)
                          (or (claude-pair-rpc--open-process path)
                              (user-error "The daemon started but %s refuses connections"
                                          path))))))
      (when process
        (let ((connection (claude-pair-rpc--make-connection process)))
          (setq claude-pair-rpc--server-info (claude-pair-rpc--initialize connection))
          (setq claude-pair-rpc--connection connection)))))

(defun claude-pair-rpc-server-info ()
  "Return the daemon's initialize result as a plist, or nil."
  (and (claude-pair-rpc-live-p) claude-pair-rpc--server-info))

(defun claude-pair-rpc-error-message (err)
  "Return the daemon's message from ERR, a `jsonrpc-error' condition."
  (or (alist-get 'jsonrpc-error-message (cdr err))
      (error-message-string err)))

(defun claude-pair-rpc-request (method &optional params timeout)
  "Send METHOD with PARAMS to the daemon and return the result.
Wait at most TIMEOUT seconds, 10 by default."
  (jsonrpc-request (claude-pair-rpc-connection) method params
                   :timeout (or timeout 10)))

;;;; Closing

(defun claude-pair-rpc--close (connection)
  "Close CONNECTION and wait briefly for its sentinel to run."
  (let ((claude-pair-rpc--expected-disconnect t))
    (when (jsonrpc-running-p connection)
      (delete-process (jsonrpc--process connection)))
    (accept-process-output nil 0.05)))

(defun claude-pair-rpc-disconnect ()
  "Close the connection to the daemon, leaving the daemon running."
  (when claude-pair-rpc--connection
    (claude-pair-rpc--close claude-pair-rpc--connection)
    (setq claude-pair-rpc--connection nil
          claude-pair-rpc--server-info nil)))

(defun claude-pair-rpc-shutdown-daemon (&optional timeout)
  "Ask the daemon to exit and wait up to TIMEOUT seconds for it to go.
Return non-nil if a daemon was running.  A daemon that speaks another
protocol version is stopped too."
  (condition-case nil
      (claude-pair-rpc--shutdown-daemon timeout)
    (claude-pair-rpc-incompatible
     (claude-pair-rpc-stop-without-handshake timeout))))

(defun claude-pair-rpc--raw-shutdown (path)
  "Send shutdown to the daemon on PATH without initializing.
Return non-nil if it accepted.  Daemons before protocol 0.4 refuse."
  (when-let* ((process (claude-pair-rpc--open-process path)))
    (let ((connection (claude-pair-rpc--make-connection process))
          (claude-pair-rpc--expected-disconnect t))
      (unwind-protect
          (condition-case nil
              (progn (jsonrpc-request connection 'shutdown nil :timeout 3) t)
            (jsonrpc-error nil))
        (claude-pair-rpc--close connection)))))

(defun claude-pair-rpc--daemon-pids (path)
  "Return the ids of your claude-paird processes listening on PATH."
  (let ((pattern (concat "--socket " (regexp-quote path) "\\( \\|\\'\\)")))
    (seq-filter
     (lambda (pid)
       (let* ((attrs (process-attributes pid))
              (args (alist-get 'args attrs)))
         (and args
              (eql (alist-get 'euid attrs) (user-uid))
              (string-match-p "claude-paird" args)
              (not (string-match-p "claude-paird mcp " args))
              (string-match-p pattern args))))
     (list-system-processes))))

(defun claude-pair-rpc-stop-without-handshake (&optional timeout)
  "Stop the daemon on the socket whatever protocol it speaks.
Ask it to shut down; a daemon too old to accept that before the
handshake gets SIGTERM, which it handles like shutdown.  Wait up to
TIMEOUT seconds, 5 by default, and return non-nil if one was stopped."
  (let ((path (claude-pair-rpc-socket-path))
        (deadline (+ (float-time) (or timeout 5))))
    (claude-pair-rpc-disconnect)
    (unless (claude-pair-rpc--raw-shutdown path)
      (let ((pids (claude-pair-rpc--daemon-pids path)))
        (unless pids
          (user-error "Cannot find the process behind %s; stop it yourself" path))
        (dolist (pid pids)
          (signal-process pid 'SIGTERM))))
    (while (and (file-exists-p path) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (when (file-exists-p path)
      (user-error "The old claude-paird did not stop; stop it yourself, then try again"))
    t))

(defun claude-pair-rpc--shutdown-daemon (timeout)
  "Shut down a daemon this client can talk to, waiting up to TIMEOUT seconds."
  (when-let* ((connection (claude-pair-rpc-connection t)))
    (let ((claude-pair-rpc--expected-disconnect t)
          (deadline (+ (float-time) (or timeout 3))))
      (jsonrpc-request connection 'shutdown nil :timeout 5)
      (while (and (jsonrpc-running-p connection) (< (float-time) deadline))
        (accept-process-output nil 0.05))
      (when (jsonrpc-running-p connection)
        (delete-process (jsonrpc--process connection)))
      (setq claude-pair-rpc--connection nil
            claude-pair-rpc--server-info nil)
      t)))

;;;; Dispatch

(defun claude-pair-rpc--dispatch-request (_connection method _params)
  "Answer a request for METHOD from the daemon."
  (jsonrpc-error :code -32601 :message (format "Emacs does not handle %s yet" method)))

(defun claude-pair-rpc--dispatch-notification (_connection method params)
  "Run `claude-pair-rpc-notification-functions' for METHOD and PARAMS."
  (run-hook-with-args 'claude-pair-rpc-notification-functions method params))

(defun claude-pair-rpc--on-shutdown (connection)
  "Forget CONNECTION once its process has died."
  (when (eq connection claude-pair-rpc--connection)
    (setq claude-pair-rpc--connection nil
          claude-pair-rpc--server-info nil)
    (unless claude-pair-rpc--expected-disconnect
      ;; Runs inside the sentinel, where messages are hidden; post it after.
      (run-at-time 0 nil #'message "claude-pair: lost the connection to the daemon"))
    (run-hooks 'claude-pair-rpc-disconnect-hook)))

(provide 'claude-pair-rpc)
;;; claude-pair-rpc.el ends here
