;;; run-checkdoc.el --- Run checkdoc on files, fail on warnings  -*- lexical-binding: t; -*-

;;; Commentary:

;; Usage: emacs -Q --batch -l test/run-checkdoc.el FILE...
;; In batch mode checkdoc reports through `display-warning', so this
;; collects those warnings and exits with status 1 if there were any.

;;; Code:

(require 'checkdoc)

(defvar run-checkdoc--count 0
  "Number of checkdoc warnings seen so far.")

(advice-add 'display-warning :before
            (lambda (&rest _) (setq run-checkdoc--count (1+ run-checkdoc--count))))

(dolist (file command-line-args-left)
  (checkdoc-file file))
(setq command-line-args-left nil)
(message "checkdoc: %d warning%s" run-checkdoc--count (if (= run-checkdoc--count 1) "" "s"))
(kill-emacs (if (zerop run-checkdoc--count) 0 1))

;;; run-checkdoc.el ends here
