;;; install-deps.el --- Install the packages tandem needs for its tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; For `make lisp-deps'.  Emacs comes with jsonrpc, but before Emacs 30
;; with an older one than lisp/tandem.el asks for.  This installs from
;; GNU ELPA what the running Emacs lacks, into a directory of the
;; checkout, and nothing when Emacs has it all.

;;; Code:

(require 'package)

(defun tandem-install-deps ()
  "Install what the file named first on the command line requires.
The packages go into the directory named second.  Do nothing, and
need no network, when Emacs has them all, built in or there."
  (pcase-let ((`(,file ,dir) command-line-args-left))
    (setq command-line-args-left nil)
    (setq package-user-dir (expand-file-name dir)
          package-archives '(("gnu" . "https://elpa.gnu.org/packages/")))
    (package-initialize)
    (let ((missing
           (seq-remove
            (pcase-lambda (`(,name ,version))
              (or (eq name 'emacs) (package-installed-p name version)))
            (with-temp-buffer
              (insert-file-contents file)
              (package-desc-reqs (package-buffer-info))))))
      (when missing
        (package-refresh-contents)
        (pcase-dolist (`(,name ,version) missing)
          (let ((desc (cadr (assq name package-archive-contents))))
            (unless (and desc (version-list-<= version (package-desc-version desc)))
              (error "GNU ELPA has no %s %s" name (package-version-join version)))
            ;; By its description: by name, Emacs 29 takes the older
            ;; one it comes with for installed.
            (package-install desc)
            (message "Installed %s %s in %s" name
                     (package-version-join (package-desc-version desc)) dir)))))))

;;; install-deps.el ends here
