;;; tandem.el --- Pair-program with Claude Code  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Victory

;; Author: Victory <osikwemhev@gmail.com>
;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.25"))
;; Keywords: tools, convenience
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

;; tandem runs Claude in a background daemon, tandemd, and
;; lets you chat with it, review its edits and watch it work, all inside
;; Emacs.
;;
;;   M-x tandem                 chat with Claude about this project
;;   M-x tandem-connect         connect, starting the daemon if needed
;;   M-x tandem-daemon-status   show the daemon's version, pid and clients
;;   M-x tandem-disconnect      close the connection, keep the daemon
;;   M-x tandem-stop-daemon     stop the daemon
;;   M-x tandem-do              tell Claude to refactor, document, fix… the code here
;;   M-x global-tandem-suggest-mode  grey code suggestions as you type; TAB inserts
;;   M-x tandem-events-buffer   show the protocol log

;;; Code:

(require 'tandem-rpc)
(require 'tandem-chat)
(require 'tandem-layout)
(require 'tandem-review)
(require 'tandem-popup)
(require 'tandem-dashboard)
(require 'tandem-ask)
(require 'tandem-do)
(require 'tandem-suggest)
(require 'tandem-mention)
(require 'tandem-tools)
(require 'tandem-resume)
(require 'tandem-slash)
(require 'tandem-rewind)
(require 'tandem-plan)
(require 'tandem-agents)
(require 'tandem-notes)

;; The manual, built in the checkout by make info: C-h i finds it there.
(defconst tandem--doc-directory
  (expand-file-name "../doc/" (file-name-directory (or load-file-name buffer-file-name "")))
  "Where the manual is built in a checkout.")
(defvar Info-additional-directory-list)
(when (file-exists-p (expand-file-name "dir" tandem--doc-directory))
  ;; Before info.el loads, its defcustom keeps a value set here.
  (setq Info-additional-directory-list
        (append (bound-and-true-p Info-additional-directory-list)
                (list tandem--doc-directory))))

;; Optional parts, for a checkout (a package's autoloads say the same):
;; each loads when first used.
(autoload 'tandem-magit-stage-claude "tandem-magit"
  "Stage the hunks you accepted from Claude, and only those." t)
(autoload 'tandem-magit-draft-message "tandem-magit"
  "Have Claude write the commit message for what is staged." t)
(autoload 'tandem-magit-mode "tandem-magit"
  "In new commit message buffers, add the trailer and the draft you asked for." t)
(autoload 'tandem-org-send-subtree "tandem-org"
  "Send the Org subtree at point to Claude as a task." t)
(autoload 'tandem-embark-mode "tandem-embark"
  "Put \"@\" in Embark's action menus: ask Claude about the target." t)

;;;###autoload
(defun tandem-connect ()
  "Connect to the tandem daemon, starting it if it is not running."
  (interactive)
  (let* ((was-live (tandem-rpc-live-p))
         (connection (tandem-rpc-connection))
         (info (tandem-rpc-server-info))
         (server (plist-get info :serverInfo)))
    (message "tandem: %s %s %s (pid %s)"
             (if was-live "already connected to" "connected to")
             (plist-get server :name)
             (plist-get server :version)
             (plist-get info :pid))
    connection))

;;;###autoload
(defun tandem-daemon-status ()
  "Show the daemon's version, process id, uptime and connected clients."
  (interactive)
  (let ((status (tandem-rpc-request 'daemon/status)))
    (message "tandem: tandemd %s · pid %s · up %s · %s · %s"
             (plist-get status :version)
             (plist-get status :pid)
             (tandem--format-duration (plist-get status :uptimeSeconds))
             (tandem--plural (plist-get status :clients) "client")
             (tandem--plural (plist-get status :sessions) "session"))
    status))

;;;###autoload
(defun tandem-disconnect ()
  "Close the connection to the daemon and leave the daemon running."
  (interactive)
  (if (not (tandem-rpc-live-p))
      (message "tandem: not connected")
    (tandem-rpc-disconnect)
    (message "tandem: disconnected; the daemon keeps running")))

;;;###autoload
(defun tandem-stop-daemon ()
  "Stop the tandem daemon if it is running."
  (interactive)
  (if (tandem-rpc-shutdown-daemon)
      (message "tandem: daemon stopped")
    (message "tandem: no daemon is running")))

;;;###autoload
(defun tandem-events-buffer ()
  "Show the log of messages exchanged with the daemon."
  (interactive)
  (unless (tandem-rpc-live-p)
    (user-error "Not connected; run M-x tandem-connect first"))
  (display-buffer (jsonrpc-events-buffer (tandem-rpc-connection))))

(defun tandem--format-duration (seconds)
  "Return SECONDS as a short duration such as \"3m 20s\"."
  (let ((seconds (or seconds 0)))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm %ds" (/ seconds 60) (% seconds 60)))
          (t (format "%dh %dm" (/ seconds 3600) (/ (% seconds 3600) 60))))))

(defun tandem--plural (count noun)
  "Return COUNT followed by NOUN, pluralized when COUNT is not 1."
  (format "%d %s%s" (or count 0) noun (if (eql count 1) "" "s")))

(provide 'tandem)
;;; tandem.el ends here
