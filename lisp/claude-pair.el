;;; claude-pair.el --- Pair-program with Claude inside Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.25"))
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

;; claude-pair runs Claude in a background daemon, claude-paird, and
;; lets you chat with it, review its edits and watch it work, all inside
;; Emacs.
;;
;;   M-x claude-pair                 chat with Claude about this project
;;   M-x claude-pair-connect         connect, starting the daemon if needed
;;   M-x claude-pair-daemon-status   show the daemon's version, pid and clients
;;   M-x claude-pair-disconnect      close the connection, keep the daemon
;;   M-x claude-pair-stop-daemon     stop the daemon
;;   M-x claude-pair-events-buffer   show the protocol log

;;; Code:

(require 'claude-pair-rpc)
(require 'claude-pair-chat)
(require 'claude-pair-layout)
(require 'claude-pair-review)
(require 'claude-pair-popup)
(require 'claude-pair-dashboard)

;;;###autoload
(defun claude-pair-connect ()
  "Connect to the claude-pair daemon, starting it if it is not running."
  (interactive)
  (let* ((was-live (claude-pair-rpc-live-p))
         (connection (claude-pair-rpc-connection))
         (info (claude-pair-rpc-server-info))
         (server (plist-get info :serverInfo)))
    (message "claude-pair: %s %s %s (pid %s)"
             (if was-live "already connected to" "connected to")
             (plist-get server :name)
             (plist-get server :version)
             (plist-get info :pid))
    connection))

;;;###autoload
(defun claude-pair-daemon-status ()
  "Show the daemon's version, process id, uptime and connected clients."
  (interactive)
  (let ((status (claude-pair-rpc-request 'daemon/status)))
    (message "claude-pair: claude-paird %s · pid %s · up %s · %s · %s"
             (plist-get status :version)
             (plist-get status :pid)
             (claude-pair--format-duration (plist-get status :uptimeSeconds))
             (claude-pair--plural (plist-get status :clients) "client")
             (claude-pair--plural (plist-get status :sessions) "session"))
    status))

;;;###autoload
(defun claude-pair-disconnect ()
  "Close the connection to the daemon and leave the daemon running."
  (interactive)
  (if (not (claude-pair-rpc-live-p))
      (message "claude-pair: not connected")
    (claude-pair-rpc-disconnect)
    (message "claude-pair: disconnected; the daemon keeps running")))

;;;###autoload
(defun claude-pair-stop-daemon ()
  "Stop the claude-pair daemon if it is running."
  (interactive)
  (if (claude-pair-rpc-shutdown-daemon)
      (message "claude-pair: daemon stopped")
    (message "claude-pair: no daemon is running")))

;;;###autoload
(defun claude-pair-events-buffer ()
  "Show the log of messages exchanged with the daemon."
  (interactive)
  (unless (claude-pair-rpc-live-p)
    (user-error "Not connected; run M-x claude-pair-connect first"))
  (display-buffer (jsonrpc-events-buffer (claude-pair-rpc-connection))))

(defun claude-pair--format-duration (seconds)
  "Return SECONDS as a short duration such as \"3m 20s\"."
  (let ((seconds (or seconds 0)))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm %ds" (/ seconds 60) (% seconds 60)))
          (t (format "%dh %dm" (/ seconds 3600) (/ (% seconds 3600) 60))))))

(defun claude-pair--plural (count noun)
  "Return COUNT followed by NOUN, pluralized when COUNT is not 1."
  (format "%d %s%s" (or count 0) noun (if (eql count 1) "" "s")))

(provide 'claude-pair)
;;; claude-pair.el ends here
