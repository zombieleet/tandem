;;; tandem-install.el --- Get the tandem daemon for a package install  -*- lexical-binding: t; -*-

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

;; Installed as a package, tandem has no daemon of its own: M-x
;; tandem-install-daemon downloads the one built for this system from the
;; GitHub release of the same version, into `tandem-daemon-directory'.
;; Before it is used, its SHA-256 must equal the one this package holds in
;; tandem-daemon-sums.el, written when the release was built: a file
;; changed on the server, or on the way, is refused.  When tandem starts
;; and finds no daemon, it offers to do this.
;;
;; From a checkout, "make daemon" builds it instead.

;;; Code:

(require 'tandem-daemon-sums)
(require 'subr-x)
(require 'url)

(defvar tandem-version)

(defcustom tandem-daemon-directory (locate-user-emacs-file "tandem/")
  "Where `tandem-install-daemon' puts the daemon."
  :type 'directory
  :group 'tandem)

(defcustom tandem-daemon-release-url
  "https://github.com/zombieleet/tandem/releases/download/v%s/%s"
  "Where released daemons are: a format of the version and the file name."
  :type 'string
  :group 'tandem)

(defun tandem-install--platform ()
  "Return this system as the daemon's file names say it, such as \"linux-amd64\".
Return nil for a system no daemon is built for."
  (let ((os (pcase system-type
              ('gnu/linux "linux")
              ('darwin "darwin")
              ('windows-nt "windows")))
        (arch (cond
               ((string-match-p "\\`\\(x86_64\\|amd64\\)" system-configuration) "amd64")
               ((string-match-p "\\`\\(aarch64\\|arm64\\)" system-configuration) "arm64"))))
    (and os arch (concat os "-" arch))))

(defun tandem-install--file-name (version platform)
  "Return the released daemon's file name for VERSION and PLATFORM."
  (format "tandemd-%s-%s%s" version platform
          (if (string-prefix-p "windows" platform) ".exe" "")))

(defun tandem-install-daemon-path ()
  "Return where the installed daemon of this tandem's version is, or would be."
  (expand-file-name (tandem-install--file-name tandem-version (or (tandem-install--platform) "unknown"))
                    tandem-daemon-directory))

(defun tandem-install--expected-sum (platform)
  "Return the SHA-256 the released daemon for PLATFORM must have, or nil.
Nil when this package holds no sums for its own version."
  (and (equal tandem-daemon-sums-version tandem-version)
       (cdr (assoc platform tandem-daemon-sums))))

(defun tandem-install-available-p ()
  "Return non-nil if a released daemon can be installed for this system."
  (when-let* ((platform (tandem-install--platform)))
    (tandem-install--expected-sum platform)))

(defun tandem-install--sha256 (file)
  "Return the SHA-256 of FILE's bytes, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun tandem-install--why-not ()
  "Return why no released daemon can be installed here."
  (let ((platform (tandem-install--platform)))
    (cond
     ((null platform)
      (format "no daemon is built for %s (%s)" system-type system-configuration))
     ((not (equal tandem-daemon-sums-version tandem-version))
      (format "tandem %s has no released daemon yet" tandem-version))
     (t (format "the release has no daemon for %s" platform)))))

;;;###autoload
(defun tandem-install-daemon ()
  "Download the daemon for this system and this tandem's version.
It is checked against the SHA-256 this package holds before it is kept.
Return its path."
  (interactive)
  (let* ((platform (tandem-install--platform))
         (expected (and platform (tandem-install--expected-sum platform))))
    (unless expected
      (user-error "Cannot install the daemon: %s.  Build it from a checkout with \"make daemon\" and set `tandem-daemon-command'"
                  (tandem-install--why-not)))
    (let* ((name (tandem-install--file-name tandem-version platform))
           (url (format tandem-daemon-release-url tandem-version name))
           (target (tandem-install-daemon-path))
           (dir (file-name-directory target))
           (partial (concat target ".part")))
      (make-directory dir t)
      (set-file-modes dir #o700)
      (message "tandem: downloading %s…" url)
      (unwind-protect
          (progn
            (condition-case err
                (url-copy-file url partial t)
              (error (user-error "Cannot download %s: %s" url (error-message-string err))))
            (let ((got (tandem-install--sha256 partial)))
              ;; A server's error page is small; a daemon is megabytes.
              (when (< (file-attribute-size (file-attributes partial)) 100000)
                (user-error "Cannot download %s: the answer is not a daemon" url))
              (unless (string= got expected)
                (user-error "The downloaded daemon is not the released one: its SHA-256 is %s, not %s.  Nothing was installed"
                            got expected)))
            (set-file-modes partial #o755)
            (rename-file partial target t)
            ;; Daemons of other versions are no use any more.
            (dolist (old (directory-files dir t "\\`tandemd-"))
              (unless (or (equal old target) (string-suffix-p ".part" old))
                (ignore-errors (delete-file old))))
            (message "tandem: installed the daemon %s, checked" (abbreviate-file-name target))
            target)
        (when (file-exists-p partial)
          (delete-file partial))))))

(provide 'tandem-install)
;;; tandem-install.el ends here
