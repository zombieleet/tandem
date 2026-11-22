;;; tandem-project.el --- Where Claude starts  -*- lexical-binding: t; -*-

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

;; The folder a chat starts in is the project: Claude Code reads its
;; instructions (CLAUDE.md) from there and every folder above, and Claude
;; may change files only inside it.  tandem picks it like this:
;;
;; - In a repository, the repository's root (project.el), unless
;;   `tandem-project-root' says to prefer a subfolder with its own
;;   instructions, as in a monorepo.
;; - Otherwise the nearest folder upwards holding one of
;;   `tandem-project-markers', stopping before your home folder.
;; - Otherwise you are asked, with the file's folder as the default.
;;
;; Your home folder or the file system's root is never used without
;; asking you first: it would give Claude every file you have.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)

(defcustom tandem-project-root 'vc
  "How to pick the folder a chat starts in, inside a repository.
`vc': the repository's root.
`nearest-instructions': the nearest folder at or above the file, inside
the repository, with its own instructions (see
`tandem-instruction-files'), else the repository's root.
`ask': ask, offering the repository's root and that folder.
A function: called with no arguments in the current buffer; it returns
a folder, or nil to fall back to `vc'."
  :type '(choice (const vc) (const nearest-instructions) (const ask) function)
  :group 'tandem)

(defcustom tandem-instruction-files
  '("CLAUDE.md" "CLAUDE.local.md" ".claude/CLAUDE.md" "AGENTS.md")
  "Files that give a folder instructions of its own for Claude."
  :type '(repeat string)
  :group 'tandem)

(defcustom tandem-project-markers
  '("CLAUDE.md" "CLAUDE.local.md" ".claude" "AGENTS.md"
    "package.json" "go.mod" "pyproject.toml" "setup.py" "Cargo.toml"
    "Makefile" "CMakeLists.txt" "pom.xml" "build.gradle" "build.gradle.kts"
    "deps.edn" "project.clj" "mix.exs" "Gemfile" "composer.json"
    "Package.swift" "pubspec.yaml" "dune-project" "stack.yaml"
    ".project" ".projectile")
  "Files or folders that mark a project's root when it is not a repository."
  :type '(repeat string)
  :group 'tandem)

(defun tandem-project--clean (dir)
  "Return DIR expanded, as a directory name."
  (file-name-as-directory (expand-file-name dir)))

(defun tandem-project--too-wide-p (dir)
  "Return non-nil if DIR is your home folder, or the root, or above home."
  (let ((dir (tandem-project--clean dir))
        (home (tandem-project--clean "~")))
    (or (equal dir home)
        (equal dir (tandem-project--clean "/"))
        (and (not (equal dir home)) (string-prefix-p dir home)))))

(defun tandem-project--marked-p (dir markers)
  "Return non-nil if one of MARKERS is in DIR."
  (seq-some (lambda (marker) (file-exists-p (expand-file-name marker dir))) markers))

(defun tandem-project--nearest (start stop markers)
  "Return the nearest folder from START up to STOP with one of MARKERS in it.
STOP is included; nil means go up to, but not into, your home folder."
  (let ((dir (tandem-project--clean start))
        (stop (and stop (tandem-project--clean stop)))
        (found nil))
    (while (and dir (not found))
      (cond
       ((and (null stop) (tandem-project--too-wide-p dir))
        (setq dir nil))
       ((tandem-project--marked-p dir markers)
        (setq found dir))
       ((equal dir stop)
        (setq dir nil))
       (t
        (let ((parent (file-name-directory (directory-file-name dir))))
          (setq dir (and parent (not (equal parent dir)) parent))))))
    found))

(defun tandem-project--vc-root ()
  "Return the current project's root according to project.el, or nil."
  (when-let* ((project (project-current)))
    (tandem-project--clean (project-root project))))

(defun tandem-project--confirm-wide (dir)
  "Return DIR if it is not too wide, or if you confirm it; else ask again."
  (if (or (not (tandem-project--too-wide-p dir))
          (yes-or-no-p (format "Let Claude read and change every file in %s? "
                               (abbreviate-file-name dir))))
      dir
    (tandem-project--ask default-directory)))

(defun tandem-project--ask (default)
  "Ask where Claude should start, offering DEFAULT."
  (when noninteractive
    ;; Batch Emacs cannot answer; never wait for it.
    (user-error "No project found in %s; start Claude from a project's folder"
                (abbreviate-file-name default)))
  (tandem-project--confirm-wide
   (tandem-project--clean
    (read-directory-name "No project found here; start Claude in: "
                         (tandem-project--clean default) nil t))))

(defun tandem-project-root ()
  "Return the folder for a chat about the current buffer.
See `tandem-project-root' and `tandem-project-markers'."
  (let* ((here (tandem-project--clean default-directory))
         (custom (and (functionp tandem-project-root)
                      (funcall tandem-project-root)))
         (vc (tandem-project--vc-root)))
    (directory-file-name
     (cond
      (custom (tandem-project--confirm-wide (tandem-project--clean custom)))
      (vc
       (let ((own (and (memq tandem-project-root '(nearest-instructions ask))
                       (tandem-project--nearest here vc tandem-instruction-files))))
         (cond
          ((or (null own) (equal own vc)) (tandem-project--confirm-wide vc))
          ((eq tandem-project-root 'nearest-instructions) own)
          (t (let* ((choices (list (abbreviate-file-name vc) (abbreviate-file-name own)))
                    (choice (completing-read
                             (format "Start Claude in (%s has its own instructions): "
                                     (abbreviate-file-name own))
                             choices nil t nil nil (cadr choices))))
               (tandem-project--clean choice))))))
      ((tandem-project--nearest here nil tandem-project-markers))
      ((tandem-project--too-wide-p here) (tandem-project--ask here))
      (t (tandem-project--ask here))))))

(provide 'tandem-project)
;;; tandem-project.el ends here
