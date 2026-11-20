;;; claude-pair-review.el --- Review Claude's edits in your own buffers  -*- lexical-binding: t; -*-

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

;; Claude never writes your files directly.  Its edit tools send each
;; change here, and it appears in the file's buffer as a proposal: the
;; text to go struck through, and the new text below it as real text you
;; can move through and read, fontified by the buffer's mode.  The new
;; text is for display only: it leaves no undo record, does not mark the
;; buffer modified, and is taken out while the buffer is saved, so saving
;; writes only your text.  Both texts are read-only until you decide:
;;
;;   C-c C-a   apply the edit (one undo step)
;;   C-c C-k   reject it, optionally telling Claude why
;;
;; with point on the proposal, or y and n on its block in the chat.  An
;; applied edit is saved when the buffer had no unsaved changes of yours;
;; otherwise it stays unsaved, and Claude is told so.
;;
;; The change is checked against the live buffer, unsaved changes
;; included, with the same rules and messages as Claude Code's built-in
;; Edit tool.

;;; Code:

(require 'claude-pair-layout)
(require 'claude-pair-rpc)
(require 'seq)
(require 'subr-x)

(defcustom claude-pair-review-autosave t
  "Whether to save a buffer after applying Claude's edit to it.
Even when non-nil, a buffer is saved only if it had no unsaved
changes of yours, so nothing of yours is ever saved behind your back."
  :type 'boolean
  :group 'claude-pair)

(defface claude-pair-review-removed
  '((t :inherit diff-removed :strike-through t :extend t))
  "Face for text a proposed edit would remove."
  :group 'claude-pair)

(defface claude-pair-review-added
  '((t :inherit diff-added :extend t))
  "Face for text a proposed edit would add."
  :group 'claude-pair)

(defface claude-pair-review-banner
  '((t :inherit warning :weight bold :extend t))
  "Face for the line above a proposed edit."
  :group 'claude-pair)

(defvar claude-pair-review--proposals (make-hash-table :test #'equal)
  "Map from edit request id to its proposal plist.")

(defvar-keymap claude-pair-review-proposal-map
  :doc "Keys on a proposed edit in a file buffer."
  "C-c C-a" #'claude-pair-review-apply
  "C-c C-k" #'claude-pair-review-reject)

(defconst claude-pair-review--locked-message
  "Claude proposed changing this text: C-c C-a applies the edit, C-c C-k rejects it"
  "Error shown when you type into text a proposal would replace.")

;;;; Helpers

(defun claude-pair-review-shift-undo (pos delta)
  "Move positions at or after POS in `buffer-undo-list' by DELTA.
For text changed without undo records, so the edits recorded around
it still undo in the right place."
  (unless (or (zerop delta) (eq buffer-undo-list t))
    (let ((shift (lambda (p)
                   (cond ((not (integerp p)) p)
                         ((and (>= p 0) (>= p pos)) (+ p delta))
                         ((and (< p 0) (>= (- p) pos)) (- p delta))
                         (t p)))))
      (setq buffer-undo-list
            (mapcar
             (lambda (entry)
               (cond
                ((integerp entry) (funcall shift entry))
                ((and (consp entry) (integerp (car entry)) (integerp (cdr entry)))
                 (cons (funcall shift (car entry)) (funcall shift (cdr entry))))
                ((and (consp entry) (stringp (car entry)) (integerp (cdr entry)))
                 (cons (car entry) (funcall shift (cdr entry))))
                ((and (consp entry) (null (car entry)) (consp (cdr entry))
                      (consp (cddr entry)) (consp (cdddr entry)))
                 (let ((range (cdddr entry)))
                   (if (and (integerp (car range)) (integerp (cdr range)))
                       (append (list nil (cadr entry) (caddr entry))
                               (cons (funcall shift (car range)) (funcall shift (cdr range))))
                     entry)))
                (t entry)))
             buffer-undo-list)))))

(defvar-local claude-pair-review--hidden nil
  "Non-nil while the proposed text in this buffer is taken out.")
(put 'claude-pair-review--hidden 'permanent-local t)

(defun claude-pair-review--quietly (fn)
  "Call FN to change display-only text, leaving the buffer's state alone.
No undo record, no file lock, no \"changed on disk\" question, and the
modified flag stays as it was."
  (let ((modified (buffer-modified-p)))
    (let ((inhibit-read-only t)
          (create-lockfiles nil)
          ;; As `with-silent-modifications' once did: no truename, no
          ;; file locking or supersession check for this change.
          (buffer-file-truename nil)
          (buffer-undo-list t))
      (funcall fn))
    (restore-buffer-modified-p modified)))

;; An entry is (START END TEXT OVERLAY): proposed TEXT between the
;; markers START and END, which meet where the text goes while it is out.

(defun claude-pair-review--show-text (entry)
  "Put ENTRY's proposed text into the buffer, unless it is there."
  (pcase-let ((`(,start ,end ,text ,overlay) entry))
    (when (= start end)
      (let ((pos (marker-position start)))
        (claude-pair-review--quietly
         (lambda () (save-excursion (goto-char pos) (insert text))))
        (claude-pair-review-shift-undo (1+ pos) (length text))
        (set-marker start pos)
        (set-marker end (+ pos (length text)))
        (move-overlay overlay start end)
        (claude-pair-review--lock start end)))))

(defun claude-pair-review--hide-text (entry)
  "Take ENTRY's proposed text out of the buffer, if it is there."
  (pcase-let ((`(,start ,end ,_text ,_overlay) entry))
    (when (< start end)
      (let ((beg (marker-position start))
            (stop (marker-position end)))
        (claude-pair-review--unlock beg stop)
        (claude-pair-review--quietly (lambda () (delete-region beg stop)))
        (claude-pair-review-shift-undo stop (- beg stop))))))

(defun claude-pair-review--lock (beg end)
  "Make BEG..END read-only, still allowing typing right after END."
  (when (< beg end)
    (with-silent-modifications
      (put-text-property beg end 'read-only claude-pair-review--locked-message)
      (put-text-property (1- end) end 'rear-nonsticky '(read-only)))))

(defun claude-pair-review--unlock (beg end)
  "Undo `claude-pair-review--lock' on BEG..END."
  (when (< beg end)
    (with-silent-modifications
      (remove-list-of-text-properties beg end '(read-only rear-nonsticky)))))

(defun claude-pair-review--in-buffer (buffer)
  "Return the proposals shown in BUFFER."
  (let (found)
    (maphash (lambda (_id p) (when (eq (plist-get p :buffer) buffer) (push p found)))
             claude-pair-review--proposals)
    found))

(defun claude-pair-review--changed-p (proposal)
  "Return non-nil if the text under PROPOSAL is not what Claude saw.
Call it while the proposal's own text is out of the buffer."
  (seq-find (lambda (occ)
              (not (equal (buffer-substring-no-properties (nth 0 occ) (nth 1 occ))
                          (nth 2 occ))))
            (plist-get proposal :occurrences)))

(defun claude-pair-review--all-hidden-p (proposal)
  "Return non-nil if none of PROPOSAL's text is in the buffer."
  (seq-every-p (lambda (entry) (= (nth 0 entry) (nth 1 entry)))
               (plist-get proposal :entries)))

(defun claude-pair-review--hide (buffer)
  "Take the proposed text of every proposal out of BUFFER."
  (with-current-buffer buffer
    (unless claude-pair-review--hidden
      (setq claude-pair-review--hidden t)
      (dolist (proposal (claude-pair-review--in-buffer buffer))
        (mapc #'claude-pair-review--hide-text (plist-get proposal :entries))))))

(defun claude-pair-review--unhide (buffer)
  "Put the proposed text back into BUFFER.
A proposal whose text changed meanwhile, say by a save hook that
reformats the file, is dropped and Claude is told."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when claude-pair-review--hidden
        (setq claude-pair-review--hidden nil)
        (dolist (proposal (claude-pair-review--in-buffer buffer))
          (if (and (claude-pair-review--all-hidden-p proposal)
                   (claude-pair-review--changed-p proposal))
              (claude-pair-review--drop proposal claude-pair-review--changed-message)
            (mapc #'claude-pair-review--show-text (plist-get proposal :entries))
            (claude-pair-review--place proposal)))))))

(defconst claude-pair-review--changed-message
  "The text to replace changed in Emacs while the user was reviewing the edit.  Read the file again."
  "What Claude is told when the text under its edit changed.")

(defun claude-pair-review--drop (proposal reason)
  "Remove PROPOSAL and tell Claude it was not applied, for REASON."
  (claude-pair-review--clear proposal)
  (claude-pair-review--answer (plist-get proposal :id) "error" :message reason)
  (message "claude-pair: Claude's edit to %s was dropped: %s"
           (file-name-nondirectory (plist-get proposal :path)) reason))

(defun claude-pair-review--before-save ()
  "Take the proposed text out, so saving writes only your text."
  (when (claude-pair-review--in-buffer (current-buffer))
    (claude-pair-review--hide (current-buffer))
    ;; In case the save fails and `after-save-hook' never runs.
    (run-at-time 0 nil #'claude-pair-review--unhide (current-buffer))))
(put 'claude-pair-review--before-save 'permanent-local-hook t)

(defun claude-pair-review--after-save ()
  "Put the proposed text back after saving."
  (claude-pair-review--unhide (current-buffer)))
(put 'claude-pair-review--after-save 'permanent-local-hook t)

(defun claude-pair-review--before-revert ()
  "Drop the proposals in a buffer about to be reloaded from disk."
  (dolist (proposal (claude-pair-review--in-buffer (current-buffer)))
    (claude-pair-review--drop
     proposal "The file was reloaded from disk in Emacs while the user was reviewing the edit.  Read it again.")))
(put 'claude-pair-review--before-revert 'permanent-local-hook t)

(defun claude-pair-review--conflicts-p (kind found)
  "Return non-nil if an edit of KIND at FOUND meets another proposal here.
FOUND is a list of (BEG . END) ranges."
  (seq-some
   (lambda (other)
     (or (eq kind 'write)
         (eq (plist-get other :kind) 'write)
         (seq-some (lambda (occ)
                     (let ((b (min (nth 0 occ) (nth 1 occ)))
                           (e (max (nth 0 occ) (nth 1 occ))))
                       (seq-some (lambda (range) (and (< (car range) e) (< b (cdr range))))
                                 found)))
                   (plist-get other :occurrences))))
   (claude-pair-review--in-buffer (current-buffer))))

(defun claude-pair-review--lines (string)
  "Split STRING into a vector of lines, each keeping its newline."
  (let ((start 0) lines)
    (while (string-match "\n" string start)
      (push (substring string start (match-end 0)) lines)
      (setq start (match-end 0)))
    (when (< start (length string))
      (push (substring string start) lines))
    (vconcat (nreverse lines))))

(defun claude-pair-review--trim (old new)
  "Return (PREFIX SUFFIX MIDDLE) for showing OLD replaced by NEW.
PREFIX and SUFFIX are the lengths of the whole lines OLD and NEW share
at their start and end; MIDDLE is the part of NEW between them."
  (let* ((ol (claude-pair-review--lines old))
         (nl (claude-pair-review--lines new))
         (on (length ol)) (nn (length nl))
         (i 0) (j 0))
    (while (and (< i on) (< i nn) (equal (aref ol i) (aref nl i)))
      (setq i (1+ i)))
    (while (and (< j (- on i)) (< j (- nn i))
                (equal (aref ol (- on 1 j)) (aref nl (- nn 1 j))))
      (setq j (1+ j)))
    (list (apply #'+ (mapcar #'length (seq-subseq ol 0 i)))
          (apply #'+ (mapcar #'length (seq-subseq ol (- on j))))
          (apply #'concat (append (seq-subseq nl i (- nn j)) nil)))))

(defun claude-pair-review--occurrences (old)
  "Return the (BEG . END) of every exact occurrence of OLD in the buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((case-fold-search nil) found)
        (while (search-forward old nil t)
          (push (cons (match-beginning 0) (match-end 0)) found))
        (nreverse found)))))

(defun claude-pair-review--answer (id outcome &rest fields)
  "Tell the daemon how edit ID ended: OUTCOME, plus FIELDS."
  (let ((message (or (plist-get fields :message) "")))
    (condition-case err
        (claude-pair-rpc-request
         'edit/answer
         (list :requestId id :outcome outcome :message message
               :saved (if (plist-get fields :saved) t :json-false)
               :created (if (plist-get fields :created) t :json-false)))
      (jsonrpc-error
       (message "claude-pair: %s" (claude-pair-rpc-error-message err)))
      (error
       (message "claude-pair: could not tell the daemon about the edit: %s"
                (error-message-string err))))))

;;;; Proposals arriving

(defun claude-pair-review--on-notification (method params)
  "Handle `edit/propose' and `edit/withdraw' with PARAMS.
METHOD is the notification's name.  The work runs from a timer, out
of the process filter, because visiting a file can take a while."
  (pcase method
    ('edit/propose (run-at-time 0 nil #'claude-pair-review--propose params))
    ('edit/withdraw (run-at-time 0 nil #'claude-pair-review--withdraw params))))

(add-hook 'claude-pair-rpc-notification-functions #'claude-pair-review--on-notification)

(defun claude-pair-review--check (params)
  "Check the edit in PARAMS against the current buffer.
Return (KIND OCCURRENCES NEW), where OCCURRENCES are (BEG . END) pairs
and NEW is the replacement text, or a string saying what is wrong."
  (let* ((kind (plist-get params :kind))
         (old (or (plist-get params :oldString) ""))
         (new (or (plist-get params :newString) ""))
         (content (or (plist-get params :content) ""))
         (exists (file-exists-p (plist-get params :filePath))))
    (cond
     (buffer-read-only
      "The file's buffer is read-only in Emacs, so the edit was not made.  The user can make it writable with C-x C-q.")
     ((and (buffer-modified-p) exists (not (verify-visited-file-modtime (current-buffer))))
      "The file has unsaved changes in Emacs and also changed on disk.  Ask the user to save or revert it, then read it again.")
     ((equal kind "write")
      (if (equal content (buffer-substring-no-properties (point-min) (point-max)))
          "No changes to make: the file already has this content."
        (list 'write (list (cons (point-min) (point-max))) content)))
     ((equal old "")
      (if (and (not exists) (zerop (buffer-size)))
          (list 'write (list (cons (point-min) (point-max))) new)
        "Cannot create new file - file already exists."))
     (t
      (let ((found (claude-pair-review--occurrences old)))
        (cond
         ((null found)
          (format "String to replace not found in file.\nString: %s" old))
         ((and (cdr found) (not (eq (plist-get params :replaceAll) t)))
          (format "Found %d matches of the string to replace, but replace_all is false. \
To replace all occurrences, set replace_all to true. To replace only one occurrence, \
please provide more context to uniquely identify the instance.\nString: %s"
                  (length found) old))
         (t (list 'edit found new))))))))

(defun claude-pair-review--propose (params)
  "Show the edit in PARAMS in its file's buffer, or report why it can't be made."
  (let* ((id (plist-get params :requestId))
         (path (plist-get params :filePath))
         (buffer (condition-case err
                     (claude-pair-layout-file-buffer path)
                   (error (claude-pair-review--answer
                           id "error" :message (format "Emacs could not open %s: %s"
                                                       path (error-message-string err)))
                          nil))))
    (when buffer
      (with-current-buffer buffer
        ;; Check against your text alone, not other proposals shown here.
        (claude-pair-review--hide buffer)
        (unwind-protect
            (progn
              ;; A buffer you have not touched follows the file on disk, so a
              ;; command Claude ran first is not hidden behind a stale buffer.
              (when (and (not (buffer-modified-p)) (file-exists-p path)
                         (not (verify-visited-file-modtime buffer)))
                (let ((inhibit-message t))
                  (revert-buffer t t t)))
              (let ((check (claude-pair-review--check params)))
                (cond
                 ((stringp check)
                  (claude-pair-review--answer id "error" :message check))
                 ((claude-pair-review--conflicts-p (nth 0 check) (nth 1 check))
                  (claude-pair-review--answer
                   id "error" :message "Another edit to the same text is waiting for the user's review.  Wait for its result, then read the file again."))
                 (t
                  (claude-pair-review--show-proposal id path params check)))))
          (claude-pair-review--unhide buffer))))))

(defun claude-pair-review--show-proposal (id path params check)
  "Draw proposal ID for PATH in the current buffer.
PARAMS is the request; CHECK is what `claude-pair-review--check' returned.
The text to go is struck through; the new text goes in below it as real,
read-only text, so it can be scrolled through and read like code."
  (pcase-let* ((`(,kind ,found ,new) check)
               (overlays nil)
               (occurrences nil)
               (entries nil))
    (dolist (range (reverse found))
      ;; From the last occurrence back, so earlier positions stay valid.
      (let* ((beg (car range)) (end (cdr range))
             (old (buffer-substring-no-properties beg end))
             ;; Markers first, so the text added below moves them correctly.
             (occurrence (list (copy-marker beg t) (copy-marker end) old new)))
        (pcase-let ((`(,prefix ,suffix ,middle) (claude-pair-review--trim old new)))
          (let ((rb (+ beg prefix)) (re (- end suffix)))
            (claude-pair-review--lock beg end)
            (when (< rb re)
              (let ((ov (make-overlay rb re nil t nil)))
                (overlay-put ov 'face 'claude-pair-review-removed)
                (push ov overlays)))
            (unless (string-empty-p middle)
              (let ((entry (list (copy-marker re t) (copy-marker re) middle
                                 (make-overlay re re nil t nil))))
                (overlay-put (nth 3 entry) 'face 'claude-pair-review-added)
                (claude-pair-review--show-text entry)
                (push (nth 3 entry) overlays)
                (push entry entries)))
            (push occurrence occurrences)))))
    (let* ((banner (make-overlay (point-min) (point-min)))
           (region (make-overlay (point-min) (point-min)))
           (proposal (list :id id :buffer (current-buffer) :path path :kind kind
                           :session (plist-get params :sessionId)
                           :occurrences occurrences :entries entries
                           :banner banner :region region
                           :overlays (append (list banner region) overlays)
                           :new-file (not (file-exists-p path)))))
      (overlay-put banner 'before-string
                   (propertize (format "▸ Claude proposes %s%s · C-c C-a applies · C-c C-k rejects\n"
                                       (if (eq kind 'write)
                                           (if (file-exists-p path) "new content for this file" "this new file")
                                         "an edit")
                                       (if (cdr found) (format " (%d places)" (length found)) ""))
                               'face 'claude-pair-review-banner))
      (overlay-put region 'keymap claude-pair-review-proposal-map)
      (overlay-put region 'claude-pair-proposal id)
      (claude-pair-review--place proposal)
      (puthash id proposal claude-pair-review--proposals)
      (add-hook 'kill-buffer-hook #'claude-pair-review--on-kill nil t)
      (add-hook 'before-save-hook #'claude-pair-review--before-save -100 t)
      (add-hook 'after-save-hook #'claude-pair-review--after-save 100 t)
      (add-hook 'before-revert-hook #'claude-pair-review--before-revert nil t)
      ;; Where the chat is, else in the selected frame: Claude is waiting for you.
      ;; Where the chat is.  When it is not shown, Claude is waiting for
      ;; you, so show it where you are, unless you are in another tab than
      ;; Claude's: your tabs are never touched.
      (claude-pair-layout-show (current-buffer) :pos (overlay-start banner)
                               :session (plist-get params :sessionId)
                               :fallback (not (claude-pair-layout-elsewhere-p)))
      (message "claude-pair: Claude proposes an edit to %s%s; C-c C-a applies it, C-c C-k rejects it"
               (file-name-nondirectory path) (claude-pair-layout-where-text)))))

(defun claude-pair-review--place (proposal)
  "Fit PROPOSAL's banner and its key overlay around its text."
  (let* ((occurrences (plist-get proposal :occurrences))
         (entries (plist-get proposal :entries))
         (positions (mapcar #'marker-position
                            (append (mapcar #'car occurrences) (mapcar #'cadr occurrences)
                                    (mapcar #'car entries) (mapcar #'cadr entries))))
         (bol (save-excursion (goto-char (apply #'min positions)) (line-beginning-position)))
         (eol (save-excursion (goto-char (apply #'max positions))
                              (if (and (bolp) (> (point) bol)) (point) (line-end-position)))))
    (move-overlay (plist-get proposal :banner) bol bol)
    (move-overlay (plist-get proposal :region) bol eol)))

;;;; Deciding

(defun claude-pair-review--clear (proposal &optional keep-markers)
  "Remove PROPOSAL from its buffer: its text, overlays and locks.
With KEEP-MARKERS, leave the markers on the text it replaces."
  (remhash (plist-get proposal :id) claude-pair-review--proposals)
  (let ((buffer (plist-get proposal :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (dolist (entry (plist-get proposal :entries))
          (claude-pair-review--hide-text entry)
          (set-marker (nth 0 entry) nil)
          (set-marker (nth 1 entry) nil))
        (dolist (occ (plist-get proposal :occurrences))
          (claude-pair-review--unlock (nth 0 occ) (nth 1 occ))
          (unless keep-markers
            (set-marker (nth 0 occ) nil)
            (set-marker (nth 1 occ) nil))))))
  (mapc #'delete-overlay (plist-get proposal :overlays)))

(defun claude-pair-review--at-point ()
  "Return the id of the proposal at point, else one in this buffer, else any."
  (or (get-char-property (point) 'claude-pair-proposal)
      (let (here any)
        (maphash (lambda (id p)
                   (setq any id)
                   (when (eq (plist-get p :buffer) (current-buffer))
                     (setq here id)))
                 claude-pair-review--proposals)
        (or here any))
      (user-error "Claude has no proposed edit waiting")))

(defun claude-pair-review-pending-p (id)
  "Return non-nil if edit ID waits for your decision in this Emacs."
  (and (gethash id claude-pair-review--proposals) t))

(defun claude-pair-review-apply (&optional id)
  "Apply Claude's proposed edit ID, or the one at point.
The change is one undo step.  The buffer is saved when it had no
unsaved changes of yours and `claude-pair-review-autosave' is non-nil."
  (interactive)
  (let* ((id (or id (claude-pair-review--at-point)))
         (proposal (or (gethash id claude-pair-review--proposals)
                       (user-error "That edit is no longer waiting")))
         (buffer (plist-get proposal :buffer))
         (occurrences (plist-get proposal :occurrences)))
    (unless (buffer-live-p buffer)
      (claude-pair-review--clear proposal)
      (user-error "The buffer for that edit is gone"))
    (with-current-buffer buffer
      (claude-pair-review--clear proposal t)
      (let ((unsaved (buffer-modified-p))
            (new-file (plist-get proposal :new-file)))
        (if (claude-pair-review--changed-p proposal)
            (progn
              (dolist (occ occurrences)
                (set-marker (nth 0 occ) nil)
                (set-marker (nth 1 occ) nil))
              (claude-pair-review--answer id "error" :message claude-pair-review--changed-message)
              (message "claude-pair: the text changed under Claude's edit; it was not applied"))
          ;; Whatever happens, the daemon must hear the outcome, or Claude waits forever.
          (condition-case err
              (progn
                (claude-pair-review--replace proposal)
                (let ((saved (and claude-pair-review-autosave (not unsaved))))
                  (when saved
                    (when new-file
                      (make-directory (file-name-directory (plist-get proposal :path)) t))
                    (let ((save-silently t) (inhibit-message t))
                      (save-buffer)))
                  (claude-pair-review--answer id "applied" :saved saved :created new-file)
                  (message "claude-pair: applied Claude's edit to %s%s"
                           (file-name-nondirectory (plist-get proposal :path))
                           (if saved "" " (not saved: the buffer has unsaved changes of yours)"))))
            (error
             (claude-pair-review--answer
              id "error" :message (format "Emacs could not apply the edit: %s" (error-message-string err)))
             (message "claude-pair: could not apply Claude's edit: %s" (error-message-string err)))))))))

(defun claude-pair-review--replace (proposal)
  "Make PROPOSAL's change as a single undo step."
  (let ((group (prepare-change-group))
        (done nil))
    (unwind-protect
        (progn
          (activate-change-group group)
          (if (eq (plist-get proposal :kind) 'write)
              (let ((new (nth 3 (car (plist-get proposal :occurrences)))))
                (replace-region-contents (point-min) (point-max) (lambda () new)))
            (dolist (occ (reverse (plist-get proposal :occurrences)))
              (save-excursion
                (goto-char (nth 0 occ))
                (delete-region (nth 0 occ) (nth 1 occ))
                (insert (nth 3 occ)))))
          (setq done t))
      (if done
          (accept-change-group group)
        (cancel-change-group group))
      (undo-amalgamate-change-group group))
    (dolist (occ (plist-get proposal :occurrences))
      (set-marker (nth 0 occ) nil)
      (set-marker (nth 1 occ) nil))))

(defun claude-pair-review-reject (&optional id reason)
  "Reject Claude's proposed edit ID, or the one at point.
Interactively, ask for REASON, an optional note Claude reads."
  (interactive
   (list nil (read-string "Tell Claude why, or what to do instead (optional): ")))
  (let* ((id (or id (claude-pair-review--at-point)))
         (proposal (or (gethash id claude-pair-review--proposals)
                       (user-error "That edit is no longer waiting"))))
    (claude-pair-review--clear proposal)
    (claude-pair-review--answer id "rejected" :message (or reason ""))
    (message "claude-pair: rejected Claude's edit to %s"
             (file-name-nondirectory (plist-get proposal :path)))))

(defun claude-pair-review-show (&optional id)
  "Show Claude's proposed edit ID, or the newest one."
  (interactive)
  (let* ((id (or id (claude-pair-review--at-point)))
         (proposal (or (gethash id claude-pair-review--proposals)
                       (user-error "That edit is no longer waiting")))
         (banner (plist-get proposal :banner)))
    (pop-to-buffer (plist-get proposal :buffer))
    (goto-char (overlay-start banner))))

(defun claude-pair-review--withdraw (params)
  "Remove the proposal PARAMS names; Claude no longer wants an answer."
  (when-let* ((proposal (gethash (plist-get params :requestId) claude-pair-review--proposals)))
    (claude-pair-review--clear proposal)
    (message "claude-pair: Claude withdrew its edit to %s: %s"
             (file-name-nondirectory (plist-get proposal :path))
             (plist-get params :reason))))

(defun claude-pair-review--on-kill ()
  "Reject proposals in a buffer that is being killed."
  (let ((buffer (current-buffer)) ids)
    (maphash (lambda (id p) (when (eq (plist-get p :buffer) buffer) (push id ids)))
             claude-pair-review--proposals)
    (dolist (id ids)
      (claude-pair-review--clear (gethash id claude-pair-review--proposals))
      (claude-pair-review--answer id "rejected" :message "The user closed the buffer."))))

(defun claude-pair-review--on-disconnect ()
  "Remove every proposal: with the daemon gone, none can be answered."
  (let (proposals)
    (maphash (lambda (_id p) (push p proposals)) claude-pair-review--proposals)
    (mapc #'claude-pair-review--clear proposals)))

(add-hook 'claude-pair-rpc-disconnect-hook #'claude-pair-review--on-disconnect)

(provide 'claude-pair-review)
;;; claude-pair-review.el ends here
