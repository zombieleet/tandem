;;; tandem-authorship.el --- Claude's lines keep their colour  -*- lexical-binding: t; -*-

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

;; Text Claude wrote, through an edit you applied, carries the text
;; property `tandem-author', whose value names a record: the chat
;; session, its turn, the model and the time.  A line holding such text
;; is Claude's, and shows a light tint and, in a graphical frame, a mark
;; in the left fringe, so colour is never the only signal.
;;
;; The rule: any change that is not Claude's takes the colour off every
;; line it touches.  Typing next to Claude's text or pasting it makes it
;; yours.  Opening a new line after one of Claude's, or deleting whole
;; lines around it, does not touch it.  Undo and redo bring the colour
;; back or take it away with the text, since Emacs records text property
;; changes in the undo list.  With `tandem-attribution-ignore-whitespace'
;; a line whose only change is whitespace, as from a formatter, keeps its
;; colour.
;;
;; The colours outlive the buffer: each save writes, under
;; `tandem-attribution-directory', a fingerprint of every line of the
;; file and which lines are Claude's.  Opening the file again diffs those
;; fingerprints against the file as it is, so Claude's lines get their
;; colour back where they are now; a line changed meanwhile does not.
;; \[tandem-blame] says who wrote the line at point.

;;; Code:

(require 'cl-lib)
(require 'tandem-diff)
(require 'color)
(require 'seq)
(require 'subr-x)

(defcustom tandem-attribution-ignore-whitespace t
  "Non-nil means a Claude line keeps its colour when only whitespace changes.
Formatters and reindenting change whitespace on many lines at once."
  :type 'boolean
  :group 'tandem)

(defcustom tandem-author-color "#d97757"
  "Colour blended into the background of Claude's lines, or nil.
With nil, the face `tandem-author' is left as your theme sets it."
  :type '(choice color (const :tag "Leave the face alone" nil))
  :group 'tandem)

(defcustom tandem-author-tint 0.10
  "How much of `tandem-author-color' to blend in: 0 none, 1 all."
  :type 'number
  :group 'tandem)

(defcustom tandem-attribution-persist t
  "Non-nil means remember Claude's lines after a file is closed."
  :type 'boolean
  :group 'tandem)

(defcustom tandem-attribution-directory
  (expand-file-name "tandem/attribution"
                    (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))
  "Directory holding, for each file, which of its lines Claude wrote.
It is made private to you (mode 700)."
  :type 'directory
  :group 'tandem)

(defface tandem-author
  '((t :extend t))
  "Face of the lines Claude wrote.
Its background is computed from `tandem-author-color' and the
theme's background."
  :group 'tandem)

(defface tandem-author-fringe
  '((t :inherit shadow))
  "Face of the fringe mark on the lines Claude wrote.
Its foreground is set to `tandem-author-color'."
  :group 'tandem)

(defvar tandem-authorship-claude-editing nil
  "Non-nil while Claude's own text goes in, so it is not taken for yours.
Also bound for text drawn for display only, such as proposals.")

(defvar tandem-authorship--records (make-hash-table :test #'equal)
  "Map from record id to a plist: :session, :turn, :model, :time, :file, :request.")

(defvar-local tandem-authorship--overlays nil
  "Overlays drawing Claude's lines in this buffer.")

(defvar-local tandem-authorship--dirty nil
  "Non-nil when this buffer's overlays need drawing again.")

(defvar-local tandem-authorship--before nil
  "What `tandem-authorship--before-change' saw: (ALIGNED . LINES).
ALIGNED is non-nil if the changing text was whole lines; LINES maps the
whitespace-free text of each of Claude's lines there to its record.")

(defvar-local tandem-authorship--removed nil
  "Claude's lines that changes in the current command removed: (TEXT . ID).
A formatter that deletes the text and inserts its new version in two
steps gets their colour back for the lines whose only change is
whitespace.  Forgotten after each command.")

(defvar tandem-authorship--timer nil
  "Idle timer that draws the buffers whose overlays are out of date.")

(when (fboundp 'define-fringe-bitmap)
  (define-fringe-bitmap 'tandem-author-bar [#b11100000] 1 8 '(center t)))

;;;; Records

(defun tandem-authorship-record (&rest plist)
  "Store a record of who wrote some text, from PLIST, and return its id.
PLIST holds :session, :turn, :model, :file and :request; :time is added."
  (let ((id (format "%s/%d" (or (plist-get plist :request) "claude")
                    (hash-table-count tandem-authorship--records))))
    (puthash id (append plist (list :time (float-time))) tandem-authorship--records)
    id))

(defun tandem-authorship-record-of (id)
  "Return the record named ID."
  (gethash id tandem-authorship--records))

(defun tandem-authorship-at (pos)
  "Return the record id of the text Claude wrote on the line of POS, or nil."
  (save-excursion
    (goto-char pos)
    (let ((bol (line-beginning-position))
          (eol (line-end-position)))
      (or (get-text-property bol 'tandem-author)
          (let ((next (next-single-property-change bol 'tandem-author nil eol)))
            (and (< next eol) (get-text-property next 'tandem-author)))))))

;;;; Marking Claude's text

(defun tandem-authorship-mark (beg end id)
  "Mark BEG..END as written by Claude, for the record ID."
  (when (< beg end)
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (put-text-property beg end 'tandem-author id))
    (tandem-authorship--watch)
    (tandem-authorship--schedule)))

(defun tandem-authorship--watch ()
  "Watch this buffer, so that your edits take the colour off Claude's lines."
  (add-hook 'before-change-functions #'tandem-authorship--before-change nil t)
  (add-hook 'after-change-functions #'tandem-authorship--after-change nil t)
  (add-hook 'post-command-hook #'tandem-authorship--forget nil t)
  ;; Before the review puts proposed text back (depth 100), so the lines
  ;; written down are the file's.
  (add-hook 'after-save-hook #'tandem-authorship--save 50 t)
  ;; Text you type next to Claude's does not take its property.
  (setq-local text-property-default-nonsticky
              (cons '(tandem-author . t)
                    (assq-delete-all 'tandem-author
                                     (copy-sequence text-property-default-nonsticky))))
  ;; Text you paste is yours.
  (unless (memq 'tandem-author yank-excluded-properties)
    (setq yank-excluded-properties (append yank-excluded-properties '(tandem-author)))))

(defun tandem-authorship--forget ()
  "Forget which of Claude's lines the last command removed."
  (setq tandem-authorship--removed nil))

(defun tandem-authorship--ours-p ()
  "Return non-nil if the change happening now is not one to take as yours."
  (or tandem-authorship-claude-editing undo-in-progress))

(defun tandem-authorship--squeeze (string)
  "Return STRING without any whitespace."
  (replace-regexp-in-string "[ \t\n\r\f]+" "" string))

(defun tandem-authorship--each-line (beg end fn)
  "Call FN with the start and end of each line from BEG's line to END's."
  (save-excursion
    (let ((stop (progn (goto-char end) (line-end-position)))
          (done nil))
      (goto-char beg)
      (forward-line 0)
      (while (and (not done) (<= (point) stop))
        (funcall fn (point) (line-end-position))
        (when (or (> (forward-line 1) 0) (eobp))
          (setq done t))))))

(defun tandem-authorship--lines (beg end)
  "Return (TEXT . ID) for each of Claude's lines from BEG's line to END's.
TEXT is the line without whitespace."
  (let (lines)
    (tandem-authorship--each-line
     beg end
     (lambda (bol eol)
       (when-let* ((id (tandem-authorship-at bol))
                   (text (tandem-authorship--squeeze (buffer-substring-no-properties bol eol))))
         (unless (string-empty-p text)
           (push (cons text id) lines)))))
    lines))

(defun tandem-authorship--before-change (beg end)
  "Note what the change of BEG..END is about to replace."
  (setq tandem-authorship--before
        (unless (tandem-authorship--ours-p)
          (cons (and (save-excursion (goto-char beg) (bolp))
                     (save-excursion (goto-char end) (bolp))
                     (< beg end))
                (and tandem-attribution-ignore-whitespace
                     (text-property-not-all
                      (save-excursion (goto-char beg) (line-beginning-position))
                      (save-excursion (goto-char end) (line-end-position))
                      'tandem-author nil)
                     (tandem-authorship--lines beg end))))))

(defun tandem-authorship--touched (beg end len aligned)
  "Return (FROM . TO), the whole lines a change of BEG..END touched, or nil.
LEN is the length of the text it replaced; ALIGNED is non-nil if that
text was whole lines."
  (cond
   ;; Whole lines went and whole lines (or nothing) came: the lines around
   ;; them are unchanged.
   ((and aligned
         (save-excursion (goto-char beg) (bolp))
         (save-excursion (goto-char end) (bolp)))
    (when (< beg end) (cons beg end)))
   ;; Text inserted at the end of a line, starting with a newline, opens new
   ;; lines below that line without changing it.
   ((and (zerop len) (< beg end) (eq (char-after beg) ?\n)
         (or (= end (point-max)) (eq (char-after end) ?\n)))
    (cons (1+ beg) (save-excursion (goto-char end) (line-end-position))))
   (t
    (cons (save-excursion (goto-char beg) (line-beginning-position))
          (save-excursion (goto-char end) (line-end-position))))))

(defun tandem-authorship--after-change (beg end len)
  "Take the colour off the lines a change of BEG..END, which was LEN long, touched."
  (unless (tandem-authorship--ours-p)
    (let* ((before tandem-authorship--before)
           (range (tandem-authorship--touched beg end len (car before)))
           (known (append (cdr before) tandem-authorship--removed)))
      (setq tandem-authorship--before nil)
      (when (and tandem-attribution-ignore-whitespace (cdr before))
        (setq tandem-authorship--removed known))
      (when (and range
                 (< (car range) (cdr range))
                 (or (text-property-not-all (car range) (cdr range) 'tandem-author nil)
                     known))
        (let ((inhibit-read-only t)
              (inhibit-modification-hooks t))
          (remove-list-of-text-properties (car range) (cdr range) '(tandem-author))
          ;; A line whose only change is whitespace stays Claude's.
          (when (and tandem-attribution-ignore-whitespace known)
            (tandem-authorship--each-line
             (car range) (cdr range)
             (lambda (bol eol)
               (when-let* (((< bol eol))
                           (id (cdr (assoc (tandem-authorship--squeeze
                                            (buffer-substring-no-properties bol eol))
                                           known))))
                 (put-text-property bol eol 'tandem-author id))))))
        (tandem-authorship--schedule)))))

;;;; Drawing

(defun tandem-authorship--schedule ()
  "Draw this buffer's colours again soon."
  (setq tandem-authorship--dirty t)
  (unless (timerp tandem-authorship--timer)
    (setq tandem-authorship--timer
          (run-with-idle-timer 0.05 nil #'tandem-authorship--draw-dirty))))

(defun tandem-authorship--draw-dirty ()
  "Draw every buffer whose colours are out of date."
  (setq tandem-authorship--timer nil)
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'tandem-authorship--dirty buffer)
      (with-current-buffer buffer
        (tandem-authorship-draw)))))

(defun tandem-authorship--prefix ()
  "Return the `line-prefix' that puts a mark in the fringe of Claude's lines."
  (propertize " " 'display '(left-fringe tandem-author-bar tandem-author-fringe)))

(defun tandem-authorship-draw ()
  "Draw Claude's lines in this buffer: one overlay per run of them."
  (setq tandem-authorship--dirty nil)
  (mapc #'delete-overlay tandem-authorship--overlays)
  (setq tandem-authorship--overlays nil)
  (save-excursion
    (save-restriction
      (widen)
      (let ((pos (point-min)) runs)
        ;; Each stretch of Claude's text covers whole lines; join stretches
        ;; on the same or neighbouring lines into runs.
        (while (setq pos (text-property-not-all pos (point-max) 'tandem-author nil))
          (let* ((stop (next-single-property-change pos 'tandem-author nil (point-max)))
                 (first (progn (goto-char pos) (line-beginning-position)))
                 (last (progn (goto-char (max pos (1- stop)))
                              (min (point-max) (1+ (line-end-position))))))
            (if (and runs (<= first (cdar runs)))
                (setcdr (car runs) (max last (cdar runs)))
              (push (cons first last) runs))
            (setq pos stop)))
        (dolist (run runs)
          (let ((ov (make-overlay (car run) (cdr run) nil nil nil)))
            (overlay-put ov 'face 'tandem-author)
            (overlay-put ov 'tandem-author-run t)
            (when (display-graphic-p)
              (overlay-put ov 'line-prefix (tandem-authorship--prefix))
              (overlay-put ov 'wrap-prefix (tandem-authorship--prefix)))
            (push ov tandem-authorship--overlays)))))))

;;;; Remembering Claude's lines

(defvar tandem-authorship--moved nil
  "Non-nil once the store of the old name has been looked for.")

(defun tandem-authorship--move-old-store ()
  "Move what claude-pair, tandem's old name, remembered into the new store.
Only once, and only when the new store does not exist yet."
  (unless tandem-authorship--moved
    (setq tandem-authorship--moved t)
    (let ((old (expand-file-name "claude-pair/attribution"
                                 (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))))
      (when (and (file-directory-p old)
                 (not (file-exists-p tandem-attribution-directory)))
        (ignore-errors
          (make-directory (file-name-directory (directory-file-name tandem-attribution-directory)) t)
          (rename-file old tandem-attribution-directory))))))

(defun tandem-authorship--store (file)
  "Return the file that remembers Claude's lines in FILE."
  (tandem-authorship--move-old-store)
  (expand-file-name (concat (secure-hash 'sha1 (file-truename file)) ".json")
                    tandem-attribution-directory))

(defun tandem-authorship--fingerprint (bol eol)
  "Return a short fingerprint of the line from BOL to EOL."
  (let ((text (buffer-substring-no-properties bol eol)))
    (substring (secure-hash 'sha1 (if tandem-attribution-ignore-whitespace
                                      (tandem-authorship--squeeze text)
                                    text))
               0 12)))

(defun tandem-authorship--fingerprints ()
  "Return the fingerprints of every line of the buffer, as a vector."
  (let (prints)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (not (eobp))
          (push (tandem-authorship--fingerprint (point) (line-end-position)) prints)
          (forward-line 1))))
    (vconcat (nreverse prints))))

(defun tandem-authorship-snapshot ()
  "Return which lines of the buffer are Claude's, as a plist, or nil if none.
:lines holds every line's fingerprint, :claude a vector of [INDEX ID]
for Claude's lines (from 0), :records the records those ids name."
  (let ((claude nil) (ids nil))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((index 0))
          (while (not (eobp))
            (when-let* ((id (tandem-authorship-at (point))))
              (push (vector index id) claude)
              (cl-pushnew id ids :test #'equal))
            (setq index (1+ index))
            (forward-line 1)))))
    (when claude
      (list :lines (tandem-authorship--fingerprints)
            :claude (vconcat (nreverse claude))
            :records (vconcat
                      (mapcar (lambda (id)
                                (append (list :id id) (tandem-authorship-record-of id)))
                              ids))))))

(defun tandem-authorship-apply (data)
  "Colour Claude's lines from DATA, a snapshot, where they still are.
DATA is as `tandem-authorship-snapshot' returns, perhaps of another
version of the text: lines are matched by a diff of the fingerprints.
Return how many lines were marked."
  (let* ((old (plist-get data :lines))
         (new (tandem-authorship--fingerprints))
         (moved (tandem-authorship--map-lines old new))
         (marked 0))
    (seq-doseq (record (plist-get data :records))
      (let ((id (plist-get record :id)))
        (unless (gethash id tandem-authorship--records)
          (puthash id (cl-loop for (key value) on record by #'cddr
                               unless (eq key :id) append (list key value))
                   tandem-authorship--records))))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        ;; In line order, so one pass forward reaches them all.
        (let ((at 0)
              (lines (sort (delq nil (mapcar (lambda (entry)
                                               (when-let* ((line (gethash (aref entry 0) moved)))
                                                 (cons line (aref entry 1))))
                                             (plist-get data :claude)))
                           (lambda (a b) (< (car a) (car b))))))
          (dolist (line lines)
            (forward-line (- (car line) at))
            (setq at (car line))
            (when (< (point) (line-end-position))
              (let ((inhibit-read-only t))
                (with-silent-modifications
                  (put-text-property (point) (line-end-position)
                                     'tandem-author (cdr line))))
              (setq marked (1+ marked)))))))
    (when (> marked 0)
      (tandem-authorship--watch)
      (tandem-authorship--schedule))
    marked))

(defun tandem-authorship--save ()
  "Write down which lines of the file just saved are Claude's."
  (when (and tandem-attribution-persist buffer-file-name)
    (let ((store (tandem-authorship--store buffer-file-name))
          (snapshot (tandem-authorship-snapshot)))
      (condition-case err
          (if (null snapshot)
              (when (file-exists-p store)
                (delete-file store))
            (let ((json (json-serialize
                         (append (list :version 1 :file (abbreviate-file-name buffer-file-name))
                                 snapshot)
                         :null-object nil :false-object :false)))
              (with-file-modes #o700
                (make-directory tandem-attribution-directory t))
              (with-file-modes #o600
                (write-region json nil store nil 'silent))))
        (error (message "tandem: could not remember Claude's lines in %s: %s"
                        (file-name-nondirectory buffer-file-name) (error-message-string err)))))))

(defvar tandem-authorship-restore-functions nil
  "Functions called in a visited file where no line was found to be Claude's.
Each may find Claude's lines elsewhere, such as in git notes.")

(defun tandem-authorship-restore ()
  "Give Claude's lines in this file their colour back, where they still are."
  (when (and tandem-attribution-persist buffer-file-name)
    (let ((store (tandem-authorship--store buffer-file-name))
          (marked 0))
      (when (file-readable-p store)
        (condition-case err
            (setq marked (tandem-authorship-apply
                          (json-parse-string
                           (with-temp-buffer (insert-file-contents store) (buffer-string))
                           :object-type 'plist :array-type 'array
                           :null-object nil :false-object nil)))
          (error (message "tandem: could not read Claude's lines for %s: %s"
                          (file-name-nondirectory buffer-file-name) (error-message-string err)))))
      (when (zerop marked)
        (run-hooks 'tandem-authorship-restore-functions)))))

(defun tandem-authorship--map-lines (old new)
  "Return a table from line index in OLD to the same line's index in NEW.
OLD and NEW are vectors of fingerprints; only lines the diff finds
unchanged are in the table."
  (let ((table (make-hash-table)) (i 0) (j 0))
    (dolist (range (append (tandem-diff old new) (list (list (length old) (length old) (length new) (length new)))))
      (while (< i (nth 0 range))
        (puthash i j table)
        (setq i (1+ i) j (1+ j)))
      (setq i (nth 1 range) j (nth 3 range)))
    table))

(add-hook 'find-file-hook #'tandem-authorship-restore)

;;;; Who wrote this line

(defun tandem-authorship-describe (id)
  "Return a sentence saying who wrote the text of record ID."
  (if (null id)
      "No text Claude wrote is on this line: it is yours."
    (let* ((record (tandem-authorship-record-of id))
           (model (plist-get record :model))
           (session (plist-get record :session))
           (turn (plist-get record :turn))
           (time (plist-get record :time))
           (prompt (plist-get record :prompt)))
      (concat "Claude"
              (if model (format " (%s)" model) "")
              " wrote this line"
              (if session (format ", in chat %s" (substring session 0 (min 8 (length session)))) "")
              (if turn (format ", turn %d" turn) "")
              (if time (format-time-string ", %e %b %H:%M" (seconds-to-time time)) "")
              (if (and prompt (not (string-empty-p prompt))) (format ", answering: \"%s\"" prompt) "")
              "."))))

(defun tandem-blame (&optional all)
  "Say who wrote the line at point.
With prefix argument ALL, list every run of lines Claude wrote in this
buffer, each a link to its lines."
  (interactive "P")
  (if all
      (tandem-authorship--blame-list)
    (message "%s" (tandem-authorship-describe (tandem-authorship-at (point))))))

(defun tandem-authorship--runs ()
  "Return (FIRST LAST ID) for each run of lines Claude wrote, by line number."
  (let (runs)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((line 1))
          (while (not (eobp))
            (let ((id (tandem-authorship-at (point))))
              (if (and id runs (equal (nth 2 (car runs)) id) (= (nth 1 (car runs)) (1- line)))
                  (setcar (cdr (car runs)) line)
                (when id (push (list line line id) runs))))
            (setq line (1+ line))
            (forward-line 1)))))
    (nreverse runs)))

(defun tandem-authorship--blame-list ()
  "Show every run of lines Claude wrote in this buffer."
  (let ((source (current-buffer))
        (runs (tandem-authorship--runs)))
    (unless runs
      (user-error "No text Claude wrote is in this buffer"))
    (with-current-buffer (get-buffer-create (format "*tandem blame: %s*" (buffer-name)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Lines Claude wrote in %s\n\n" (buffer-name source)))
        (dolist (run runs)
          (let ((first (nth 0 run)) (last (nth 1 run)))
            (insert-text-button (if (= first last) (format "line %d" first) (format "lines %d-%d" first last))
                                'action (lambda (_)
                                          (pop-to-buffer source)
                                          (goto-char (point-min))
                                          (forward-line (1- first)))
                                'follow-link t)
            (insert "  " (tandem-authorship-describe (nth 2 run)) "\n"))))
      (special-mode)
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;;; The tint

(defun tandem-authorship--blend (color background alpha &optional frame)
  "Return COLOR blended over BACKGROUND with weight ALPHA, as #rrggbb, or nil.
Colour names are read on FRAME: on a terminal frame, such as a daemon's
first one, they would be rounded to the terminal's few colours."
  (let ((c (and color (color-name-to-rgb color frame)))
        (b (and background (color-name-to-rgb background frame))))
    (when (and c b)
      (apply #'format "#%02x%02x%02x"
             (cl-mapcar (lambda (x y) (round (* 255 (+ (* alpha x) (* (- 1 alpha) y))))) c b)))))

(defun tandem-authorship-refresh-face (&rest _)
  "Compute the background of `tandem-author' from the theme.
Use a graphical frame's background when there is one: an Emacs started
as a daemon has only a frame with no colours until you open one.
Leave the face as it is when no background is known yet."
  (when tandem-author-color
    (let* ((frame (or (seq-find #'display-graphic-p (frame-list)) (selected-frame)))
           (tint (tandem-authorship--blend
                  tandem-author-color (face-background 'default frame t)
                  tandem-author-tint frame)))
      (when tint
        (set-face-background 'tandem-author tint))
      ;; The fringe mark in the colour itself, so it reads as Claude's.
      (when (color-defined-p tandem-author-color frame)
        (set-face-foreground 'tandem-author-fringe tandem-author-color)))))

(tandem-authorship-refresh-face)
;; A daemon's first real frame, and every theme change, bring the colours.
(add-hook 'after-make-frame-functions #'tandem-authorship-refresh-face)
(when (boundp 'enable-theme-functions)
  (add-hook 'enable-theme-functions #'tandem-authorship-refresh-face)
  (add-hook 'disable-theme-functions #'tandem-authorship-refresh-face))

(provide 'tandem-authorship)
;;; tandem-authorship.el ends here
