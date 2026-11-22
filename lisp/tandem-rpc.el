;;; tandem-rpc.el --- Connection to the tandem daemon  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
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

;; Talks to tandemd, the background daemon that runs Claude, over a
;; Unix socket using JSON-RPC 2.0 (see protocol/PROTOCOL.md).
;;
;; `tandem-rpc-connection' returns a live, initialized connection.
;; When no daemon answers on the socket it starts one with
;; "tandemd --detach", which returns once the socket is ready.
;; The daemon is not a child of Emacs, so it keeps running when Emacs
;; exits, and stops by itself after `tandem-daemon-idle-timeout'
;; seconds without clients.

;;; Code:

(require 'cl-lib)
(require 'jsonrpc)
(require 'seq)
(require 'subr-x)

(defgroup tandem nil
  "Pair-program with Claude inside Emacs."
  :group 'tools
  :prefix "tandem-")

(defconst tandem-version "0.4.0"
  "Version of the tandem Emacs package.")

(defvar tandem-rpc-protocol-version "1.0.0"
  "Protocol version this client speaks.  See protocol/PROTOCOL.md.")

(defcustom tandem-daemon-command nil
  "Command that runs tandemd, as a list of strings.
When nil, use \"tandemd\" from variable `exec-path', or else the
binary that \"make daemon\" builds next to this package."
  :type '(choice (const :tag "Find automatically" nil)
                 (repeat :tag "Command and arguments" string)))

(defcustom tandem-socket-path nil
  "Socket the daemon listens on, or nil for the default.
The default is $XDG_RUNTIME_DIR/tandem/daemon.sock.  The
directory holding the socket must be private to you (mode 700).
With `tandem-daemon-transport' set to tcp, this is the endpoint
file instead, %LOCALAPPDATA%\\tandem\\daemon.json by default on
Windows."
  :type '(choice (const :tag "Default" nil) file))

(defcustom tandem-daemon-transport
  (if (eq system-type 'windows-nt) 'tcp 'unix)
  "How Emacs reaches the daemon.
unix: a Unix socket.  tcp: a port on this machine only, which the
daemon writes with a secret token to an endpoint file; Emacs on Windows
has no Unix sockets."
  :type '(choice (const :tag "Unix socket" unix) (const :tag "Local TCP port" tcp)))

(defcustom tandem-daemon-idle-timeout 600
  "Seconds the daemon keeps running with no Emacs connected.
Zero keeps it running until you stop it.  Applies to daemons that
Emacs starts."
  :type 'natnum)

(defcustom tandem-daemon-start-timeout 10
  "Seconds to wait for a newly started daemon to accept connections."
  :type 'natnum)

(defcustom tandem-events-buffer-size 2000000
  "Maximum size in characters of the protocol log buffer.
Zero turns the log off; nil keeps everything."
  :type '(choice (const :tag "No limit" nil) natnum))

(defvar tandem-rpc-notification-functions nil
  "Abnormal hook run for each notification from the daemon.
Each function receives the method (a symbol) and the params (a plist).")

(defvar tandem-rpc-disconnect-hook nil
  "Normal hook run after the connection to the daemon closes.")

(defvar tandem-rpc--connection nil
  "The current `jsonrpc-process-connection' to the daemon, or nil.")

(defvar tandem-rpc--token nil
  "The token the daemon wants with initialize, from its endpoint file, or nil.")

(defvar tandem-rpc--server-info nil
  "Result of the last successful initialize, as a plist.")

(defvar tandem-rpc--expected-disconnect nil
  "Non-nil while Emacs closes the connection on purpose.")

(define-error 'tandem-rpc-incompatible
  "The running tandemd speaks another protocol version" 'user-error)

(defconst tandem-rpc--directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this file was loaded from.")

(defconst tandem-rpc--max-socket-path-bytes 103
  "Longest socket path the daemon accepts (the macOS limit).")

;;;; Paths and commands

(defun tandem-rpc-default-socket-path ()
  "Return the default socket path, or endpoint file for a TCP daemon.
Keep this in step with daemon/internal/paths."
  (let ((xdg (getenv "XDG_RUNTIME_DIR"))
        (local (getenv "LOCALAPPDATA")))
    (expand-file-name
     (if (eq tandem-daemon-transport 'tcp) "daemon.json" "daemon.sock")
     (cond
      ((and (eq system-type 'windows-nt) local (not (string-empty-p local)))
       (expand-file-name "tandem" local))
      ((and xdg (not (string-empty-p xdg)) (file-name-absolute-p xdg))
       (expand-file-name "tandem" xdg))
      (t (expand-file-name (format "tandem-%d" (user-uid))
                           temporary-file-directory))))))

(defun tandem-rpc-socket-path ()
  "Return the socket path in use."
  (expand-file-name (or tandem-socket-path
                        (tandem-rpc-default-socket-path))))

(declare-function tandem-install-daemon "tandem-install")
(declare-function tandem-install-daemon-path "tandem-install")
(declare-function tandem-install-available-p "tandem-install")

(defun tandem-rpc-daemon-command ()
  "Return the command list for starting the daemon.
In order: `tandem-daemon-command', tandemd on the PATH, the one \"make
daemon\" built in a checkout, the one `tandem-install-daemon' installed.
With none, offer to install it; signal a `user-error' if that cannot be."
  (require 'tandem-install)
  (or tandem-daemon-command
      (when-let* ((exe (executable-find "tandemd")))
        (list exe))
      (let ((built (tandem-rpc--built-daemon)))
        (when (file-executable-p built)
          (list built)))
      (let ((installed (tandem-install-daemon-path)))
        (when (file-executable-p installed)
          (list installed)))
      (and (tandem-install-available-p)
           (not noninteractive)
           (y-or-n-p (format "Download tandem's daemon, tandemd %s, from GitHub and check it? "
                             tandem-version))
           (list (tandem-install-daemon)))
      (user-error "Cannot find tandemd: M-x tandem-install-daemon downloads it, \"make daemon\" in a checkout builds it, or set `tandem-daemon-command'")))

(defun tandem-rpc--built-daemon ()
  "Return where \"make daemon\" puts the daemon binary."
  (expand-file-name (if (eq system-type 'windows-nt) "../daemon/bin/tandemd.exe" "../daemon/bin/tandemd")
                    tandem-rpc--directory))

(defun tandem-rpc--endpoint (path)
  "Return the endpoint file at PATH as a plist, or nil if there is none."
  (when (file-regular-p path)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents path)
        (json-parse-buffer :object-type 'plist)))))

;;;; Starting and connecting

(defun tandem-rpc--open-process (path)
  "Return a network process connected to PATH, or nil if nothing listens.
PATH is a socket, or the endpoint file of a TCP daemon, whose token is
kept for initialize."
  (if-let* ((endpoint (tandem-rpc--endpoint path)))
      (progn
        (setq tandem-rpc--token (plist-get endpoint :token))
        (condition-case nil
            (make-network-process :name "tandem"
                                  :host "127.0.0.1"
                                  :service (plist-get endpoint :port)
                                  :coding 'utf-8-emacs-unix
                                  :noquery t)
          (file-error nil)))
    (setq tandem-rpc--token nil)
    (unless (eq tandem-daemon-transport 'tcp)
      (when (> (string-bytes (encode-coding-string path 'utf-8))
               tandem-rpc--max-socket-path-bytes)
        (user-error "Socket path is longer than %d bytes: %s"
                    tandem-rpc--max-socket-path-bytes path))
      (condition-case nil
          (make-network-process :name "tandem"
                                :family 'local
                                :service path
                                :coding 'utf-8-emacs-unix
                                :noquery t)
        (file-error nil)))))

(defun tandem-rpc--start-daemon (path)
  "Start a detached daemon listening on PATH and wait until it is ready.
Return the launcher's output."
  (let* ((command (append (tandem-rpc-daemon-command)
                          (list "--detach"
                                (format "--tcp=%s" (if (eq tandem-daemon-transport 'tcp) "true" "false"))
                                "--socket" path
                                "--idle-timeout"
                                (number-to-string tandem-daemon-idle-timeout)
                                "--ready-timeout"
                                (number-to-string tandem-daemon-start-timeout))))
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
      (user-error "The tandem daemon did not start (%s): %s" status output))
    output))

(defun tandem-rpc--make-connection (process)
  "Wrap PROCESS in a `jsonrpc-process-connection'."
  (prog1 (jsonrpc-process-connection
          :name "tandem"
          :process process
          :events-buffer-config (list :size tandem-events-buffer-size :format 'full)
          :request-dispatcher #'tandem-rpc--dispatch-request
          :notification-dispatcher #'tandem-rpc--dispatch-notification
          :on-shutdown #'tandem-rpc--on-shutdown)
    ;; jsonrpc's sentinel always says "Server exited with status N", which
    ;; means nothing for a socket.  Hide its messages; ours come after.
    (let ((sentinel (process-sentinel process)))
      (set-process-sentinel process
                            (lambda (proc change)
                              (let ((inhibit-message t)
                                    (message-log-max nil))
                                (funcall sentinel proc change)))))))

(defun tandem-rpc--initialize (connection)
  "Send initialize on CONNECTION and return the result.
Close CONNECTION and signal a `user-error' when the daemon refuses."
  (condition-case err
      (jsonrpc-request
       connection 'initialize
       (list :protocolVersion tandem-rpc-protocol-version
             :token (or tandem-rpc--token "")
             :clientInfo (list :name "tandem.el" :version tandem-version)
             :capabilities (list :childFrames (if (display-graphic-p) t :json-false)
                                 :maxWindows 5))
       :timeout 5)
    (jsonrpc-error
     (tandem-rpc--close connection)
     (let* ((data (cdr err))
            (code (alist-get 'jsonrpc-error-code data))
            (message (alist-get 'jsonrpc-error-message data))
            (extra (alist-get 'jsonrpc-error-data data)))
       (if (eql code -32001)
           (signal 'tandem-rpc-incompatible
                   (list (format "This tandem speaks protocol %s, but the running tandemd \
speaks %s.  Run M-x tandem-stop-daemon to stop it, then try again"
                                 tandem-rpc-protocol-version
                                 (or (plist-get extra :daemonProtocolVersion) "another version"))
                         (plist-get extra :daemonProtocolVersion)))
         (user-error "The tandem daemon refused to initialize: %s"
                     (or message "no reason given")))))))

(defun tandem-rpc-live-p ()
  "Return non-nil when Emacs has a live connection to the daemon."
  (and tandem-rpc--connection
       (jsonrpc-running-p tandem-rpc--connection)))

(defun tandem-rpc-connection (&optional no-start)
  "Return a live, initialized connection to the daemon.
Start the daemon when nothing answers on the socket, unless NO-START
is non-nil, in which case return nil.  When the running daemon speaks
another protocol version, offer to restart it."
  (if (tandem-rpc-live-p)
      tandem-rpc--connection
    (condition-case err
        (tandem-rpc--connect no-start)
      (tandem-rpc-incompatible
       (if (and (not no-start)
                (not noninteractive)
                (y-or-n-p (format "The running tandemd speaks protocol %s, this \
tandem needs %s; restart it, ending its sessions? "
                                  (or (nth 2 err) "another version")
                                  tandem-rpc-protocol-version)))
           (progn
             (tandem-rpc-stop-without-handshake)
             (tandem-rpc--connect nil))
         (signal (car err) (cdr err)))))))

(defun tandem-rpc--connect (no-start)
  "Connect to the daemon, starting it unless NO-START, and initialize."
  (let* ((path (tandem-rpc-socket-path))
           (process (or (tandem-rpc--open-process path)
                        (unless no-start
                          (tandem-rpc--start-daemon path)
                          (or (tandem-rpc--open-process path)
                              (user-error "The daemon started but %s refuses connections"
                                          path))))))
      (when process
        (let ((connection (tandem-rpc--make-connection process)))
          (setq tandem-rpc--server-info (tandem-rpc--initialize connection))
          (setq tandem-rpc--connection connection)))))

(defun tandem-rpc-server-info ()
  "Return the daemon's initialize result as a plist, or nil."
  (and (tandem-rpc-live-p) tandem-rpc--server-info))

(defun tandem-rpc-error-message (err)
  "Return the daemon's message from ERR, a `jsonrpc-error' condition."
  (or (alist-get 'jsonrpc-error-message (cdr err))
      (error-message-string err)))

(defun tandem-rpc-request (method &optional params timeout)
  "Send METHOD with PARAMS to the daemon and return the result.
Wait at most TIMEOUT seconds, 10 by default."
  (jsonrpc-request (tandem-rpc-connection) method params
                   :timeout (or timeout 10)))

(defun tandem-rpc-async-request (method params on-result &optional on-error timeout)
  "Send METHOD with PARAMS to the daemon without waiting for the answer.
ON-RESULT gets the result; ON-ERROR, if given, gets the error message.
Give up after TIMEOUT seconds, 30 by default."
  (let ((fail (lambda (message) (when on-error (funcall on-error message)))))
    (jsonrpc-async-request (tandem-rpc-connection) method params
                           :success-fn on-result
                           :error-fn (lambda (err) (funcall fail (or (plist-get err :message) (format "%S" err))))
                           :timeout-fn (lambda () (funcall fail "no answer in time"))
                           :timeout (or timeout 30))))

;;;; Closing

(defun tandem-rpc--close (connection)
  "Close CONNECTION and wait briefly for its sentinel to run."
  (let ((tandem-rpc--expected-disconnect t))
    (when (jsonrpc-running-p connection)
      (delete-process (jsonrpc--process connection)))
    (accept-process-output nil 0.05)))

(defun tandem-rpc-disconnect ()
  "Close the connection to the daemon, leaving the daemon running."
  (when tandem-rpc--connection
    (tandem-rpc--close tandem-rpc--connection)
    (setq tandem-rpc--connection nil
          tandem-rpc--server-info nil)))

(defun tandem-rpc-shutdown-daemon (&optional timeout)
  "Ask the daemon to exit and wait up to TIMEOUT seconds for it to go.
Return non-nil if a daemon was running.  A daemon that speaks another
protocol version is stopped too."
  (condition-case nil
      (tandem-rpc--shutdown-daemon timeout)
    (tandem-rpc-incompatible
     (tandem-rpc-stop-without-handshake timeout))))

(defun tandem-rpc--raw-shutdown (path)
  "Send shutdown to the daemon on PATH without initializing.
Return non-nil if it accepted.  Daemons before protocol 0.4 refuse."
  (when-let* ((process (tandem-rpc--open-process path)))
    (let ((connection (tandem-rpc--make-connection process))
          (tandem-rpc--expected-disconnect t))
      (unwind-protect
          (condition-case nil
              (progn (jsonrpc-request connection 'shutdown
                                      (list :token (or tandem-rpc--token ""))
                                      :timeout 3)
                     t)
            (jsonrpc-error nil))
        (tandem-rpc--close connection)))))

(defun tandem-rpc--daemon-pids (path)
  "Return the ids of your tandemd processes listening on PATH."
  (if-let* ((pid (plist-get (tandem-rpc--endpoint path) :pid)))
      (list pid)
    (tandem-rpc--daemon-pids-by-args path)))

(defun tandem-rpc--daemon-pids-by-args (path)
  "Return your tandemd processes whose arguments name PATH."
  (let ((pattern (concat "--socket " (regexp-quote path) "\\( \\|\\'\\)")))
    (seq-filter
     (lambda (pid)
       (let* ((attrs (process-attributes pid))
              (args (alist-get 'args attrs)))
         (and args
              (eql (alist-get 'euid attrs) (user-uid))
              (string-match-p "tandemd" args)
              (not (string-match-p "tandemd mcp " args))
              (string-match-p pattern args))))
     (list-system-processes))))

(defun tandem-rpc-stop-without-handshake (&optional timeout)
  "Stop the daemon on the socket whatever protocol it speaks.
Ask it to shut down; a daemon too old to accept that before the
handshake gets SIGTERM, which it handles like shutdown.  Wait up to
TIMEOUT seconds, 5 by default, and return non-nil if one was stopped."
  (let ((path (tandem-rpc-socket-path))
        (deadline (+ (float-time) (or timeout 5))))
    (tandem-rpc-disconnect)
    (unless (tandem-rpc--raw-shutdown path)
      (let ((pids (tandem-rpc--daemon-pids path)))
        (unless pids
          (user-error "Cannot find the process behind %s; stop it yourself" path))
        (dolist (pid pids)
          (signal-process pid 'SIGTERM))))
    (while (and (file-exists-p path) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (when (file-exists-p path)
      (user-error "The old tandemd did not stop; stop it yourself, then try again"))
    t))

(defun tandem-rpc--shutdown-daemon (timeout)
  "Shut down a daemon this client can talk to, waiting up to TIMEOUT seconds."
  (when-let* ((connection (tandem-rpc-connection t)))
    (let ((tandem-rpc--expected-disconnect t)
          (deadline (+ (float-time) (or timeout 3))))
      (jsonrpc-request connection 'shutdown (list :token (or tandem-rpc--token "")) :timeout 5)
      (while (and (jsonrpc-running-p connection) (< (float-time) deadline))
        (accept-process-output nil 0.05))
      (when (jsonrpc-running-p connection)
        (delete-process (jsonrpc--process connection)))
      (setq tandem-rpc--connection nil
            tandem-rpc--server-info nil)
      t)))

;;;; Dispatch

(defun tandem-rpc--dispatch-request (_connection method _params)
  "Answer a request for METHOD from the daemon."
  (jsonrpc-error :code -32601 :message (format "Emacs does not handle %s yet" method)))

(defun tandem-rpc--dispatch-notification (_connection method params)
  "Run `tandem-rpc-notification-functions' for METHOD and PARAMS."
  (run-hook-with-args 'tandem-rpc-notification-functions method params))

(defun tandem-rpc--on-shutdown (connection)
  "Forget CONNECTION once its process has died."
  (when (eq connection tandem-rpc--connection)
    (setq tandem-rpc--connection nil
          tandem-rpc--server-info nil)
    (unless tandem-rpc--expected-disconnect
      ;; Runs inside the sentinel, where messages are hidden; post it after.
      (run-at-time 0 nil #'message "tandem: lost the connection to the daemon"))
    (run-hooks 'tandem-rpc-disconnect-hook)))

(provide 'tandem-rpc)
;;; tandem-rpc.el ends here
