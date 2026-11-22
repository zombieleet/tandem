;;; tandem-manual-tests.el --- Tests for the manual  -*- lexical-binding: t; -*-

;;; Commentary:

;; In a checkout where make info has run, C-h i finds the manual.

;;; Code:

(require 'ert)
(require 'tandem)
(require 'info)

(ert-deftest tandem-manual-found-by-info ()
  (skip-unless (file-exists-p (expand-file-name "dir" tandem--doc-directory)))
  (should (member tandem--doc-directory Info-additional-directory-list))
  (save-window-excursion
    (info "(tandem) Top")
    (unwind-protect
        (with-current-buffer "*info*"
          (should (string-match-p "tandem lets you pair-program with Claude" (buffer-string)))
          (Info-goto-node "Commands")
          (should (string-match-p "M-x tandem-resume" (buffer-string))))
      (kill-buffer "*info*"))))

(provide 'tandem-manual-tests)
;;; tandem-manual-tests.el ends here
