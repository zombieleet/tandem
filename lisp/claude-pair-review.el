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
;; change here, and it appears in the file's buffer as a proposal, split
;; into hunks: the blocks of lines that change, with the unchanged lines
;; between them left alone.  In each hunk the text to go is struck
;; through and the new text sits below it as real text you can move
;; through and read, fontified by the buffer's mode.  The new text is for
;; display only: it leaves no undo record, does not mark the buffer
;; modified, and is taken out while the buffer is saved, so saving writes
;; only your text.  Both texts are read-only until you decide, hunk by
;; hunk, with point on one:
;;
;;   C-c C-a   apply the hunk (one undo step)
;;   C-c C-k   reject it, optionally telling Claude why
;;   C-c '     ask Claude about it first (@claude …); its answer shows
;;             as a note where the hunk was
;;   C-u       before either: the same for every hunk of the edit
;;   n, p      on the hunk's text: the next or previous hunk
;;
;; or y and n on the edit's block in the chat, for every hunk at once.  An
;; applied hunk is saved when the buffer had no unsaved changes of yours.
;; Claude hears the outcome of every hunk once the last one is decided.
;;
;; The change is checked against the live buffer, unsaved changes
;; included, with the same rules and messages as Claude Code's built-in
;; Edit tool.

;;; Code:

(require 'cl-lib)
(require 'claude-pair-authorship)
(require 'claude-pair-diff)
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

(defcustom claude-pair-review-style 'blocking
  "How Claude's edits wait for you.
`blocking': Claude waits for your decision on each edit.
`deferred': Claude is told the edit waits for your review and carries
on; your decisions go to Claude with your next message.
`auto-accept': edits are applied as they arrive, still coloured as
Claude's, and undone like any change."
  :type '(choice (const blocking) (const deferred) (const auto-accept))
  :group 'claude-pair)

(defvar claude-pair-review-deferred-functions nil
  "Functions called when you finish deciding a deferred edit.
Each gets the session id, the edit's request id, and a sentence telling
Claude what you decided; the sentence is a question when you asked one.")

(defcustom claude-pair-review-merge-gap 2
  "Unchanged lines between two changes up to which they make one hunk."
  :type 'natnum
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
  "Face for the line above a proposed hunk."
  :group 'claude-pair)

(defface claude-pair-review-banner-active
  '((t :inherit (highlight claude-pair-review-banner)))
  "Face for the line above the hunk point is in."
  :group 'claude-pair)

(defvar claude-pair-review-show-functions nil
  "Functions called with each proposal once it is shown in its buffer.")

(defvar claude-pair-review-settle-functions nil
  "Functions called with each hunk once it is decided or withdrawn.")

(defvar claude-pair-review--proposals (make-hash-table :test #'equal)
  "Map from edit request id to its proposal plist.
A proposal has :id, :buffer, :path, :kind, :session, :new-file and
:hunks, a list of `claude-pair-review--hunk' in buffer order.")

(cl-defstruct (claude-pair-review--hunk
               (:constructor claude-pair-review--make-hunk)
               (:copier nil))
  "One block of changed lines in a proposed edit."
  id         ; the edit's request id
  index      ; 1-based, in buffer order
  beg end    ; markers around the text the hunk replaces
  old new    ; that text, and what replaces it
  line       ; the line where the hunk started when Claude proposed it
  entry      ; (START END TEXT OVERLAY) of the new text, or nil
  overlays   ; every overlay drawn for it
  banner region
  (state 'pending)  ; pending, applied, rejected or error
  note saved)

(defvar-keymap claude-pair-review-hunk-map
  :doc "Keys on the lines of a proposed hunk."
  "C-c C-a" #'claude-pair-review-apply-hunk
  "C-c C-k" #'claude-pair-review-reject-hunk
  "C-c '" #'claude-pair-review-ask-hunk
  "C-c C-'" #'claude-pair-review-ask-hunk)

(defvar-keymap claude-pair-review-apply-button-map
  :doc "Mouse keys on an \"apply\" button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'claude-pair-review-click-apply
  ;; A click whose press and release land a pixel apart is a "drag".
  "<drag-mouse-1>" #'claude-pair-review-click-apply)

(defvar-keymap claude-pair-review-reject-button-map
  :doc "Mouse keys on a \"reject\" button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'claude-pair-review-click-reject
  "<drag-mouse-1>" #'claude-pair-review-click-reject)

(defvar-keymap claude-pair-review-ask-button-map
  :doc "Mouse keys on an \"ask Claude\" button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'claude-pair-review-click-ask
  "<drag-mouse-1>" #'claude-pair-review-click-ask)

(defvar-keymap claude-pair-review-note-button-map
  :doc "Mouse keys on a note's close button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'claude-pair-review-click-dismiss
  "<drag-mouse-1>" #'claude-pair-review-click-dismiss)

(defface claude-pair-review-note
  '((t :inherit font-lock-doc-face :extend t))
  "Face for a question you asked Claude about a hunk, and its answer."
  :group 'claude-pair)

(defcustom claude-pair-review-note-lines 3
  "Lines of Claude's answer a folded note shows.
Notes start unfolded, with the whole answer; [fold] folds one."
  :type 'natnum
  :group 'claude-pair)

(defvar-keymap claude-pair-review-note-fold-map
  :doc "Mouse keys on a note's fold button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'claude-pair-review-click-fold
  "<drag-mouse-1>" #'claude-pair-review-click-fold)

(defvar claude-pair-review--notes (make-hash-table :test #'equal)
  "Map from edit request id to the note of the question asked about it.
A note is a plist: :overlay, :question and :answer.")

(defvar-keymap claude-pair-review-hunk-text-map
  :doc "Keys on a hunk's own text, which you cannot type into anyway."
  :parent claude-pair-review-hunk-map
  "n" #'claude-pair-review-next-hunk
  "p" #'claude-pair-review-previous-hunk)

(defconst claude-pair-review--locked-message
  "Claude proposed changing this text: C-c C-a applies the hunk, C-c C-k rejects it"
  "Error shown when you type into text a proposal would replace.")

(defconst claude-pair-review--changed-message
  "The text to replace changed in Emacs while the user was reviewing the edit.  Read the file again."
  "What Claude is told when the text under its edit changed.")

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
          (buffer-undo-list t)
          ;; Not an edit of yours: Claude's lines keep their colour.
          (claude-pair-authorship-claude-editing t))
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

(defun claude-pair-review--pending (proposal)
  "Return PROPOSAL's hunks that wait for a decision."
  (seq-filter (lambda (hunk) (eq (claude-pair-review--hunk-state hunk) 'pending))
              (plist-get proposal :hunks)))

(defun claude-pair-review--hunk-changed-p (hunk)
  "Return non-nil if the text under HUNK is not what Claude saw.
Call it while the hunk's own new text is out of the buffer."
  (not (equal (buffer-substring-no-properties (claude-pair-review--hunk-beg hunk)
                                              (claude-pair-review--hunk-end hunk))
              (claude-pair-review--hunk-old hunk))))

(defun claude-pair-review--hunk-hidden-p (hunk)
  "Return non-nil if HUNK's new text is out of the buffer."
  (let ((entry (claude-pair-review--hunk-entry hunk)))
    (or (null entry) (= (nth 0 entry) (nth 1 entry)))))

(defun claude-pair-review--hide (buffer)
  "Take the proposed text of every pending hunk out of BUFFER."
  (with-current-buffer buffer
    (unless claude-pair-review--hidden
      (setq claude-pair-review--hidden t)
      (dolist (proposal (claude-pair-review--in-buffer buffer))
        (dolist (hunk (claude-pair-review--pending proposal))
          (when-let* ((entry (claude-pair-review--hunk-entry hunk)))
            (claude-pair-review--hide-text entry)))))))

(defun claude-pair-review--unhide (buffer)
  "Put the proposed text back into BUFFER.
A hunk whose text changed meanwhile, say by a save hook that reformats
the file, is dropped, and Claude hears it with the edit's outcome."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when claude-pair-review--hidden
        (setq claude-pair-review--hidden nil)
        (dolist (proposal (claude-pair-review--in-buffer buffer))
          (let ((dropped nil))
            (dolist (hunk (claude-pair-review--pending proposal))
              (if (and (claude-pair-review--hunk-hidden-p hunk)
                       (claude-pair-review--hunk-changed-p hunk))
                  (progn (claude-pair-review--settle hunk 'error claude-pair-review--changed-message)
                         (setq dropped t))
                (when-let* ((entry (claude-pair-review--hunk-entry hunk)))
                  (claude-pair-review--show-text entry))
                (claude-pair-review--place hunk)))
            ;; Only for hunks dropped here: an edit being applied, whose
            ;; save ran this, finishes itself once it knows what was saved.
            (when dropped
              (claude-pair-review--maybe-finish proposal))))))))

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
  "Drop the hunks waiting in a buffer about to be reloaded from disk."
  (dolist (proposal (claude-pair-review--in-buffer (current-buffer)))
    (dolist (hunk (claude-pair-review--pending proposal))
      (claude-pair-review--settle
       hunk 'error "The file was reloaded from disk in Emacs while the user was reviewing the edit.  Read it again."))
    (claude-pair-review--maybe-finish proposal)))
(put 'claude-pair-review--before-revert 'permanent-local-hook t)

(defun claude-pair-review--conflicts-p (kind found)
  "Return non-nil if an edit of KIND at FOUND meets another proposal here.
FOUND is a list of (BEG . END) ranges."
  (seq-some
   (lambda (other)
     (or (eq kind 'write)
         (eq (plist-get other :kind) 'write)
         (seq-some (lambda (hunk)
                     (let* ((beg (claude-pair-review--hunk-beg hunk))
                            (end (claude-pair-review--hunk-end hunk))
                            (b (min beg end)) (e (max beg end)))
                       (seq-some (lambda (range)
                                   (or (and (< (car range) e) (< b (cdr range)))
                                       ;; An insertion inside the range.
                                       (and (= b e) (< (car range) b (cdr range)))))
                                 found)))
                   (claude-pair-review--pending other))))
   (claude-pair-review--in-buffer (current-buffer))))

;;;; Hunks

(defun claude-pair-review--lines (string)
  "Split STRING into a vector of lines, each keeping its newline."
  (let ((start 0) lines)
    (while (string-match "\n" string start)
      (push (substring string start (match-end 0)) lines)
      (setq start (match-end 0)))
    (when (< start (length string))
      (push (substring string start) lines))
    (vconcat (nreverse lines))))

(defun claude-pair-review--merge (ranges gap)
  "Join RANGES that are at most GAP unchanged lines apart."
  (let (out)
    (dolist (r ranges)
      (if (and out (<= (- (nth 0 r) (nth 1 (car out))) gap))
          (setcar out (list (nth 0 (car out)) (nth 1 r) (nth 2 (car out)) (nth 3 r)))
        (push r out)))
    (nreverse out)))

(defun claude-pair-review--hunk-specs (old new)
  "Return the hunks that turn OLD into NEW.
Each is (START END TEXT): OLD's characters START to END-1 become TEXT."
  (let* ((a (claude-pair-review--lines old))
         (b (claude-pair-review--lines new))
         (offsets (make-vector (1+ (length a)) 0)))
    (dotimes (i (length a))
      (aset offsets (1+ i) (+ (aref offsets i) (length (aref a i)))))
    (mapcar (lambda (r)
              (list (aref offsets (nth 0 r)) (aref offsets (nth 1 r))
                    (apply #'concat (append (seq-subseq b (nth 2 r) (nth 3 r)) nil))))
            (claude-pair-review--merge (claude-pair-diff a b)
                                       claude-pair-review-merge-gap))))

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
  "Tell the daemon how edit ID ended: OUTCOME, plus FIELDS.
FIELDS may hold :message, :saved, :created and :hunks."
  (let ((message (or (plist-get fields :message) "")))
    (condition-case err
        (claude-pair-rpc-request
         'edit/answer
         (append (list :requestId id :outcome outcome :message message
                       :saved (if (plist-get fields :saved) t :json-false)
                       :created (if (plist-get fields :created) t :json-false))
                 (when (plist-get fields :hunks)
                   (list :hunks (vconcat (plist-get fields :hunks))))))
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
  "Draw proposal ID for PATH in the current buffer, hunk by hunk.
PARAMS is the request; CHECK is what `claude-pair-review--check' returned."
  (pcase-let* ((`(,kind ,found ,new) check)
               (specs nil))
    (dolist (range found)
      (let ((old (buffer-substring-no-properties (car range) (cdr range))))
        (dolist (spec (claude-pair-review--hunk-specs old new))
          (push (list (+ (car range) (nth 0 spec)) (+ (car range) (nth 1 spec)) (nth 2 spec))
                specs))))
    (setq specs (nreverse specs))
    (if (null specs)
        (claude-pair-review--answer id "error" :message "No changes to make: the file already has this text.")
      (let* ((index 0)
             ;; Markers for every hunk first, so text added for one moves the others.
             (hunks (mapcar (lambda (spec)
                              (claude-pair-review--make-hunk
                               :id id :index (setq index (1+ index))
                               :beg (copy-marker (nth 0 spec) t) :end (copy-marker (nth 1 spec))
                               :old (buffer-substring-no-properties (nth 0 spec) (nth 1 spec))
                               :new (nth 2 spec)
                               :line (line-number-at-pos (nth 0 spec) t)))
                            specs))
             (proposal (list :id id :buffer (current-buffer) :path path :kind kind
                             :session (plist-get params :sessionId) :hunks hunks
                             :new-file (not (file-exists-p path))
                             :shown (float-time)
                             :deferred (eq claude-pair-review-style 'deferred))))
        (puthash id proposal claude-pair-review--proposals)
        (dolist (hunk hunks)
          (claude-pair-review--draw hunk proposal))
        (add-hook 'kill-buffer-hook #'claude-pair-review--on-kill nil t)
        (add-hook 'before-save-hook #'claude-pair-review--before-save -100 t)
        (add-hook 'after-save-hook #'claude-pair-review--after-save 100 t)
        (add-hook 'before-revert-hook #'claude-pair-review--before-revert nil t)
        (run-hook-with-args 'claude-pair-review-show-functions proposal)
        ;; Where the chat is.  When it is not shown, Claude is waiting for
        ;; you, so show it where you are, unless you are in another tab than
        ;; Claude's: your tabs are never touched.
        (claude-pair-layout-show (current-buffer)
                                 :pos (overlay-start (claude-pair-review--hunk-banner (car hunks)))
                                 :session (plist-get params :sessionId)
                                 :fallback (not (claude-pair-layout-elsewhere-p)))
        (pcase claude-pair-review-style
          ('deferred
           ;; Claude carries on; your decisions go to it later.
           (claude-pair-review--answer id "deferred")
           (message "claude-pair: Claude's edit to %s waits for your review (deferred)%s"
                    (file-name-nondirectory path) (claude-pair-layout-where-text)))
          ('auto-accept
           (run-at-time 0 nil (lambda ()
                                (when (claude-pair-review-pending-p id)
                                  (claude-pair-review-apply id)))))
          (_
           (message "claude-pair: Claude proposes an edit to %s%s%s; C-c C-a applies a hunk, C-c C-k rejects it"
                    (file-name-nondirectory path)
                    (if (cdr hunks) (format " (%d hunks)" (length hunks)) "")
                    (claude-pair-layout-where-text))))))))

(defun claude-pair-review-button (label map hunk)
  "Return LABEL as a button with mouse keys MAP acting on HUNK."
  (propertize label 'keymap map 'mouse-face 'highlight 'claude-pair-hunk hunk
              'help-echo "mouse-1: do it"))

(defun claude-pair-review--banner-text (hunk proposal &optional active)
  "Return the line shown above HUNK of PROPOSAL.
With ACTIVE, the line of the hunk point is in.  Its key hints are
buttons too, so in a terminal the line is the hunk's popup."
  (let* ((total (length (plist-get proposal :hunks)))
         (apply (claude-pair-review-button
                 (if (> total 1) "C-c C-a apply" "C-c C-a applies")
                 claude-pair-review-apply-button-map hunk))
         (reject (claude-pair-review-button
                  (if (> total 1) "C-c C-k reject" "C-c C-k rejects")
                  claude-pair-review-reject-button-map hunk))
         (text (if (> total 1)
                   ;; Short enough not to wrap in a window of 80 columns.
                   (concat (format "▸ Claude · hunk %d of %d · " (claude-pair-review--hunk-index hunk) total)
                           apply " · " reject " · n/p move\n")
                 (concat (format "▸ Claude proposes %s · "
                                 (if (eq (plist-get proposal :kind) 'write)
                                     (if (plist-get proposal :new-file) "this new file" "new content for this file")
                                   "an edit"))
                         apply " · " reject "\n"))))
    (add-face-text-property 0 (length text)
                            (if active 'claude-pair-review-banner-active 'claude-pair-review-banner)
                            t text)
    text))

(defun claude-pair-review-set-active (hunk active)
  "Draw HUNK's banner as the one point is in when ACTIVE is non-nil."
  (when (eq (claude-pair-review--hunk-state hunk) 'pending)
    (when-let* ((proposal (gethash (claude-pair-review--hunk-id hunk) claude-pair-review--proposals))
                (banner (claude-pair-review--hunk-banner hunk)))
      (when (overlay-buffer banner)
        (overlay-put banner 'before-string (claude-pair-review--banner-text hunk proposal active))))))

(defun claude-pair-review--draw (hunk proposal)
  "Draw HUNK of PROPOSAL: lock and strike its old text, show its new text."
  (let ((beg (claude-pair-review--hunk-beg hunk))
        (end (claude-pair-review--hunk-end hunk))
        (new (claude-pair-review--hunk-new hunk))
        (overlays nil))
    (claude-pair-review--lock beg end)
    (when (< beg end)
      (let ((ov (make-overlay beg end nil t nil)))
        (overlay-put ov 'face 'claude-pair-review-removed)
        (overlay-put ov 'keymap claude-pair-review-hunk-text-map)
        (overlay-put ov 'priority 1)
        (overlay-put ov 'claude-pair-hunk hunk)
        (push ov overlays)))
    (unless (string-empty-p new)
      (let* ((pos (marker-position end))
             (entry (list (copy-marker pos t) (copy-marker pos) new (make-overlay pos pos nil t nil))))
        (overlay-put (nth 3 entry) 'face 'claude-pair-review-added)
        (overlay-put (nth 3 entry) 'keymap claude-pair-review-hunk-text-map)
        (overlay-put (nth 3 entry) 'priority 1)
        (overlay-put (nth 3 entry) 'claude-pair-hunk hunk)
        (setf (claude-pair-review--hunk-entry hunk) entry)
        (claude-pair-review--show-text entry)
        (push (nth 3 entry) overlays)))
    (let ((banner (make-overlay beg beg))
          (region (make-overlay beg beg)))
      (overlay-put banner 'before-string (claude-pair-review--banner-text hunk proposal))
      (overlay-put region 'keymap claude-pair-review-hunk-map)
      (overlay-put region 'claude-pair-hunk hunk)
      (overlay-put region 'claude-pair-proposal (plist-get proposal :id))
      (setf (claude-pair-review--hunk-banner hunk) banner
            (claude-pair-review--hunk-region hunk) region
            (claude-pair-review--hunk-overlays hunk) (append (list banner region) overlays)))
    (claude-pair-review--place hunk)))

(defun claude-pair-review--place (hunk)
  "Fit HUNK's banner and its key overlay around its text."
  (let* ((entry (claude-pair-review--hunk-entry hunk))
         (positions (mapcar #'marker-position
                            (append (list (claude-pair-review--hunk-beg hunk)
                                          (claude-pair-review--hunk-end hunk))
                                    (and entry (list (nth 0 entry) (nth 1 entry))))))
         (bol (save-excursion (goto-char (apply #'min positions)) (line-beginning-position)))
         (eol (save-excursion (goto-char (apply #'max positions))
                              (if (and (bolp) (> (point) bol)) (point) (line-end-position)))))
    (move-overlay (claude-pair-review--hunk-banner hunk) bol bol)
    (move-overlay (claude-pair-review--hunk-region hunk) bol eol)))

;;;; Deciding

(defun claude-pair-review--settle (hunk state &optional note)
  "Take HUNK's display out of its buffer and record STATE and NOTE."
  (when (eq (claude-pair-review--hunk-state hunk) 'pending)
    (let ((beg (claude-pair-review--hunk-beg hunk))
          (end (claude-pair-review--hunk-end hunk))
          (entry (claude-pair-review--hunk-entry hunk)))
      (when (and (marker-buffer beg) (buffer-live-p (marker-buffer beg)))
        (with-current-buffer (marker-buffer beg)
          (when entry
            (claude-pair-review--hide-text entry))
          (claude-pair-review--unlock (min beg end) (max beg end))))
      (when entry
        (set-marker (nth 0 entry) nil)
        (set-marker (nth 1 entry) nil))
      (mapc #'delete-overlay (claude-pair-review--hunk-overlays hunk))
      (setf (claude-pair-review--hunk-state hunk) state
            (claude-pair-review--hunk-note hunk) note)
      (run-hook-with-args 'claude-pair-review-settle-functions hunk))))

(defun claude-pair-review--free (hunk)
  "Free HUNK's markers once it is decided."
  (set-marker (claude-pair-review--hunk-beg hunk) nil)
  (set-marker (claude-pair-review--hunk-end hunk) nil))

(defun claude-pair-review--clear (proposal)
  "Remove PROPOSAL without answering: its text, overlays and locks."
  (remhash (plist-get proposal :id) claude-pair-review--proposals)
  (dolist (hunk (plist-get proposal :hunks))
    (claude-pair-review--settle hunk 'withdrawn)
    (claude-pair-review--free hunk)))

(defun claude-pair-review--save (proposal)
  "Save PROPOSAL's buffer, making a new file's directory first."
  (when (plist-get proposal :new-file)
    (make-directory (file-name-directory (plist-get proposal :path)) t))
  (let ((save-silently t) (inhibit-message t))
    (save-buffer)))

(defun claude-pair-review--apply-one (hunk proposal &optional no-save)
  "Apply HUNK of PROPOSAL as one undo step, then save if the buffer was clean.
With NO-SAVE, leave saving to the caller.  Return non-nil if applied."
  (with-current-buffer (plist-get proposal :buffer)
    (let ((clean (not (buffer-modified-p)))
          (beg (claude-pair-review--hunk-beg hunk))
          (end (claude-pair-review--hunk-end hunk)))
      (when-let* ((entry (claude-pair-review--hunk-entry hunk)))
        (claude-pair-review--hide-text entry))
      (cond
       ((claude-pair-review--hunk-changed-p hunk)
        (claude-pair-review--settle hunk 'error claude-pair-review--changed-message)
        nil)
       (t
        ;; Whatever happens, the hunk gets a decision, or Claude waits forever.
        (condition-case err
            (let ((start (marker-position beg))
                  (stop (marker-position end)))
              (claude-pair-review--settle hunk 'applied)
              (claude-pair-review--replace start stop (claude-pair-review--hunk-new hunk)
                                           (claude-pair-review--author proposal))
              (when (and claude-pair-review-autosave clean (not no-save))
                (claude-pair-review--save proposal)
                (setf (claude-pair-review--hunk-saved hunk) t))
              t)
          (error
           (setf (claude-pair-review--hunk-state hunk) 'error
                 (claude-pair-review--hunk-note hunk)
                 (format "Emacs could not apply %s: %s"
                         (if (cdr (plist-get proposal :hunks))
                             (format "hunk %d" (claude-pair-review--hunk-index hunk))
                           "the edit")
                         (error-message-string err)))
           nil)))))))

(defun claude-pair-review--author (proposal)
  "Return the authorship record of PROPOSAL's text, making it once."
  (or (plist-get proposal :author)
      (let* ((session (plist-get proposal :session))
             (info (and (fboundp 'claude-pair-chat-session-info)
                        (claude-pair-chat-session-info session)))
             (id (claude-pair-authorship-record
                  :session session :request (plist-get proposal :id)
                  :file (plist-get proposal :path)
                  :model (plist-get info :model) :turn (plist-get info :turn)
                  :prompt (plist-get info :prompt))))
        (plist-put proposal :author id)
        id)))

(defun claude-pair-review--replace (beg end text &optional author)
  "Replace BEG..END with TEXT as a single undo step.
With AUTHOR, an authorship record id, mark TEXT as Claude's."
  (let ((group (prepare-change-group))
        (done nil))
    (unwind-protect
        (progn
          (activate-change-group group)
          (save-excursion
            (goto-char beg)
            (let ((claude-pair-authorship-claude-editing t))
              (delete-region beg end)
              (insert text))
            (when author
              (claude-pair-authorship-mark beg (+ beg (length text)) author)))
          (setq done t))
      (if done
          (accept-change-group group)
        (cancel-change-group group))
      (undo-amalgamate-change-group group))))

(defun claude-pair-review--hunk-report (hunk)
  "Describe HUNK's decision for the daemon."
  (let ((note (claude-pair-review--hunk-note hunk)))
    (list :index (claude-pair-review--hunk-index hunk)
          :line (claude-pair-review--hunk-line hunk)
          :oldLines (length (claude-pair-review--lines (claude-pair-review--hunk-old hunk)))
          :newLines (length (claude-pair-review--lines (claude-pair-review--hunk-new hunk)))
          :decision (symbol-name (claude-pair-review--hunk-state hunk))
          :note (or note "")
          :saved (if (claude-pair-review--hunk-saved hunk) t :json-false))))

(defun claude-pair-review--maybe-finish (proposal)
  "Tell Claude how PROPOSAL ended, once no hunk of it waits."
  (when (and (gethash (plist-get proposal :id) claude-pair-review--proposals)
             (null (claude-pair-review--pending proposal)))
    (remhash (plist-get proposal :id) claude-pair-review--proposals)
    (let* ((id (plist-get proposal :id))
           (hunks (plist-get proposal :hunks))
           (states (mapcar #'claude-pair-review--hunk-state hunks))
           (applied (seq-filter (lambda (h) (eq (claude-pair-review--hunk-state h) 'applied)) hunks))
           (saved (and applied (seq-every-p #'claude-pair-review--hunk-saved applied)))
           (name (file-name-nondirectory (plist-get proposal :path)))
           (notes (delq nil (mapcar (lambda (h)
                                      (let ((note (claude-pair-review--hunk-note h)))
                                        (and note (not (string-empty-p note)) note)))
                                    hunks))))
      (mapc #'claude-pair-review--free hunks)
      (cond
       ((plist-get proposal :deferred)
        (run-hook-with-args 'claude-pair-review-deferred-functions
                            (plist-get proposal :session) id
                            (claude-pair-review--summary proposal))
        (message "claude-pair: your review of Claude's edit to %s goes to Claude with your next message"
                 name))
       ((memq 'asked states)
        (let ((question (claude-pair-review--hunk-note
                         (seq-find (lambda (h) (eq (claude-pair-review--hunk-state h) 'asked)) hunks))))
          (claude-pair-review--answer id "question" :message question :saved saved
                                      :hunks (mapcar #'claude-pair-review--hunk-report hunks))
          (message "claude-pair: asked Claude about %s; its answer comes in the chat and in a note"
                   name)))
       ((seq-every-p (lambda (s) (eq s 'applied)) states)
        (claude-pair-review--answer id "applied" :saved saved
                                    :created (and saved (plist-get proposal :new-file)))
        (message "claude-pair: applied Claude's edit to %s%s" name
                 (if saved "" " (not saved: the buffer has unsaved changes of yours)")))
       ((and (null (cdr hunks)) (eq (car states) 'error))
        (claude-pair-review--answer id "error" :message (car notes))
        (message "claude-pair: Claude's edit to %s was not applied: %s" name (car notes)))
       ((seq-every-p (lambda (s) (eq s 'rejected)) states)
        (claude-pair-review--answer id "rejected" :message (string-join (seq-uniq notes) "\n")
                                    :hunks (and (cdr hunks) (mapcar #'claude-pair-review--hunk-report hunks)))
        (message "claude-pair: rejected Claude's edit to %s" name))
       (t
        (claude-pair-review--answer id "partial" :saved saved
                                    :hunks (mapcar #'claude-pair-review--hunk-report hunks))
        (message "claude-pair: applied %d of %d hunks of Claude's edit to %s"
                 (length applied) (length hunks) name))))))

;;;; Commands

(defun claude-pair-review--hunk-at-point ()
  "Return the pending hunk at point, or nil."
  (let ((hunk (get-char-property (point) 'claude-pair-hunk)))
    (and hunk (eq (claude-pair-review--hunk-state hunk) 'pending) hunk)))

(defun claude-pair-review--at-point ()
  "Return the id of the edit at point, else one in this buffer, else any."
  (or (when-let* ((hunk (claude-pair-review--hunk-at-point)))
        (claude-pair-review--hunk-id hunk))
      (let (here any)
        (maphash (lambda (id p)
                   (setq any id)
                   (when (eq (plist-get p :buffer) (current-buffer))
                     (setq here id)))
                 claude-pair-review--proposals)
        (or here any))
      (user-error "Claude has no proposed edit waiting")))

(defun claude-pair-review--proposal (id)
  "Return the waiting proposal ID, or signal a `user-error'."
  (or (gethash id claude-pair-review--proposals)
      (user-error "That edit is no longer waiting")))

(defun claude-pair-review-pending-p (id)
  "Return non-nil if edit ID waits for your decision in this Emacs."
  (and (gethash id claude-pair-review--proposals) t))

(defun claude-pair-review-waiting (&optional session)
  "Return how many hunks wait for your decision, of SESSION's edits or all."
  (let ((n 0))
    (maphash (lambda (_id p)
               (when (or (null session) (equal session (plist-get p :session)))
                 (setq n (+ n (length (claude-pair-review--pending p))))))
             claude-pair-review--proposals)
    n))

(defun claude-pair-review--name (proposal)
  "Return PROPOSAL's file name, relative to its chat's project when known."
  (let* ((path (plist-get proposal :path))
         (root (and (fboundp 'claude-pair-chat-session-info)
                    (plist-get (claude-pair-chat-session-info (plist-get proposal :session)) :root))))
    (if (and root (file-in-directory-p path root))
        (file-relative-name path root)
      (abbreviate-file-name path))))

(defun claude-pair-review--summary (proposal)
  "Return a sentence telling Claude what you decided on PROPOSAL."
  (let* ((name (claude-pair-review--name proposal))
         (hunks (plist-get proposal :hunks))
         (states (mapcar #'claude-pair-review--hunk-state hunks))
         (applied (seq-filter (lambda (h) (eq (claude-pair-review--hunk-state h) 'applied)) hunks))
         (saved (and applied (seq-every-p #'claude-pair-review--hunk-saved applied)))
         (where (lambda (h) (if (cdr hunks)
                                (format "hunk %d (line %d)" (claude-pair-review--hunk-index h)
                                        (claude-pair-review--hunk-line h))
                              "it")))
         (note (lambda (h) (let ((n (claude-pair-review--hunk-note h)))
                             (if (and n (not (string-empty-p n))) (format " (note: %s)" n) "")))))
    (cond
     ((memq 'asked states)
      (let ((asked (seq-find (lambda (h) (eq (claude-pair-review--hunk-state h) 'asked)) hunks)))
        (format "About your edit to %s, %s, the user asks: %s%s"
                name (funcall where asked) (claude-pair-review--hunk-note asked)
                (if applied
                    (format " (applied first: %s; the rest is not applied)"
                            (mapconcat (lambda (h) (format "hunk %d" (claude-pair-review--hunk-index h)))
                                       applied ", "))
                  " (not applied)"))))
     ((seq-every-p (lambda (s) (eq s 'applied)) states)
      (format "Your edit to %s was applied%s." name
              (if saved " and saved" ", not saved yet, because the buffer has unsaved changes of the user's")))
     ((seq-every-p (lambda (s) (eq s 'rejected)) states)
      (format "Your edit to %s was rejected%s; do not send it again."
              name (mapconcat note hunks "")))
     ((and (null (cdr hunks)) (eq (car states) 'error))
      (format "Your edit to %s was not applied: %s" name (claude-pair-review--hunk-note (car hunks))))
     (t
      (format "Your edit to %s, hunk by hunk: %s. Read the file again before you edit it."
              name
              (mapconcat (lambda (h)
                           (format "%s %s%s" (funcall where h)
                                   (pcase (claude-pair-review--hunk-state h)
                                     ('applied "applied") ('rejected "rejected") (_ "not applied"))
                                   (funcall note h)))
                         hunks "; "))))))

(defun claude-pair-set-review-style (style)
  "Set how Claude's edits wait for you, to STYLE; see `claude-pair-review-style'."
  (interactive
   (list (intern (completing-read (format "Review style (now %s): " claude-pair-review-style)
                                  '("blocking" "deferred" "auto-accept") nil t))))
  (setq claude-pair-review-style style)
  (message "claude-pair: Claude's next edits are %s"
           (pcase style
             ('blocking "reviewed while Claude waits")
             ('deferred "reviewed when you like, while Claude carries on")
             (_ "applied as they arrive"))))

(defun claude-pair-review-hunk-count (id)
  "Return (WAITING . TOTAL), the hunks of edit ID, or nil if it is not waiting."
  (when-let* ((proposal (gethash id claude-pair-review--proposals)))
    (cons (length (claude-pair-review--pending proposal))
          (length (plist-get proposal :hunks)))))

(defun claude-pair-review-apply (&optional id)
  "Apply every waiting hunk of Claude's edit ID, or of the edit at point.
Each hunk is one undo step.  The buffer is saved once, when it had no
unsaved changes of yours and `claude-pair-review-autosave' is non-nil."
  (interactive)
  (let* ((proposal (claude-pair-review--proposal (or id (claude-pair-review--at-point))))
         (buffer (plist-get proposal :buffer)))
    (if (not (buffer-live-p buffer))
        (progn (dolist (hunk (claude-pair-review--pending proposal))
                 (claude-pair-review--settle hunk 'error "The buffer was killed."))
               (claude-pair-review--maybe-finish proposal))
      (with-current-buffer buffer
        (let ((clean (not (buffer-modified-p)))
              (applied nil))
          ;; From the last hunk back, so each one's line numbers still hold.
          (dolist (hunk (reverse (claude-pair-review--pending proposal)))
            (when (claude-pair-review--apply-one hunk proposal t)
              (push hunk applied)))
          (when (and applied claude-pair-review-autosave clean)
            (condition-case err
                (progn (claude-pair-review--save proposal)
                       (dolist (hunk applied)
                         (setf (claude-pair-review--hunk-saved hunk) t)))
              (error (message "claude-pair: could not save %s: %s"
                              (buffer-name) (error-message-string err))))))
        (claude-pair-review--maybe-finish proposal)))))

(defun claude-pair-review-reject (&optional id reason)
  "Reject every waiting hunk of Claude's edit ID, or of the edit at point.
Interactively, ask for REASON, an optional note Claude reads."
  (interactive
   (list nil (read-string "Tell Claude why, or what to do instead (optional): ")))
  (let ((proposal (claude-pair-review--proposal (or id (claude-pair-review--at-point)))))
    (dolist (hunk (claude-pair-review--pending proposal))
      (claude-pair-review--settle hunk 'rejected (or reason "")))
    (claude-pair-review--maybe-finish proposal)))

(defun claude-pair-review-apply-hunk (&optional all)
  "Apply the hunk at point, as one undo step.
With prefix argument ALL, apply every waiting hunk of its edit."
  (interactive "P")
  (let* ((hunk (or (claude-pair-review--hunk-at-point)
                   (user-error "Point is not on a hunk Claude proposed")))
         (proposal (claude-pair-review--proposal (claude-pair-review--hunk-id hunk))))
    (if all
        (claude-pair-review-apply (plist-get proposal :id))
      (claude-pair-review-apply-this-hunk hunk))))

(defun claude-pair-review-apply-this-hunk (hunk)
  "Apply HUNK, then move to the next one of its edit."
  (let ((proposal (claude-pair-review--proposal (claude-pair-review--hunk-id hunk))))
    (claude-pair-review--apply-one hunk proposal)
    (claude-pair-review--after-decision proposal)))

(defun claude-pair-review-reject-this-hunk (hunk &optional reason)
  "Reject HUNK, asking for REASON unless given, then move to the next one."
  (let ((proposal (claude-pair-review--proposal (claude-pair-review--hunk-id hunk)))
        (reason (or reason (read-string "Tell Claude why you reject this hunk (optional): "))))
    (claude-pair-review--settle hunk 'rejected reason)
    (claude-pair-review--after-decision proposal)))

(defun claude-pair-review-ask-hunk (&optional question)
  "Ask Claude QUESTION about the hunk at point before deciding on it.
The edit goes back to Claude with your question: hunks you decided keep
their decisions, the others are not applied, and Claude answers and may
propose them again.  Its answer shows as a note where the hunk was."
  (interactive)
  (claude-pair-review-ask-this-hunk
   (or (claude-pair-review--hunk-at-point)
       (user-error "Point is not on a hunk Claude proposed"))
   question))

(defun claude-pair-review-ask-this-hunk (hunk &optional question)
  "Ask Claude QUESTION about HUNK; see `claude-pair-review-ask-hunk'."
  (let* ((proposal (claude-pair-review--proposal (claude-pair-review--hunk-id hunk)))
         (question (string-trim
                    (or question
                        (read-string (format "@claude (about hunk %d): "
                                             (claude-pair-review--hunk-index hunk))
                                     nil nil nil t)))))
    (when (string-empty-p question)
      (user-error "Type a question for Claude"))
    (claude-pair-review--make-note hunk question)
    (claude-pair-review--settle hunk 'asked question)
    (dolist (other (claude-pair-review--pending proposal))
      (claude-pair-review--settle other 'undecided))
    (claude-pair-review--maybe-finish proposal)))

(defun claude-pair-review-click-ask (event)
  "Ask Claude about the hunk whose button EVENT clicked."
  (interactive "e")
  (claude-pair-review-ask-this-hunk (claude-pair-review--clicked-hunk event)))

;;;; Notes: a question about a hunk, and Claude's answer

(defun claude-pair-review--wrap (lines width)
  "Return LINES with lines wider than WIDTH broken at spaces.
Lines inside code fences stay as they are."
  (let ((in-code nil) out)
    (dolist (line lines)
      (cond
       ((string-match-p "\\`\\s-*```" line)
        (setq in-code (not in-code))
        (push line out))
       ((or in-code (<= (string-width line) width))
        (push line out))
       (t
        (let ((indent (if (string-match "\\`\\s-*\\(?:[-*] \\|[0-9]+\\. \\)?" line)
                          (make-string (string-width (match-string 0 line)) ?\s)
                        ""))
              (rest line)
              (first t))
          (while (> (string-width rest) width)
            (let* ((cut (or (and (string-match ".*\\( \\)" (substring rest 0 width))
                                 (match-beginning 1))
                            width)))
              (push (substring rest 0 cut) out)
              (setq rest (concat indent (string-trim-left (substring rest cut)))
                    first nil)))
          (ignore first)
          (push rest out)))))
    (nreverse out)))

(defun claude-pair-review--note-width (overlay)
  "Return how wide the note in OVERLAY may be."
  (let ((window (and (overlay-buffer overlay) (get-buffer-window (overlay-buffer overlay) t))))
    (max 40 (- (if window (window-body-width window) 80) 3))))

(defun claude-pair-review--note-text (id)
  "Return the lines of the note for edit ID."
  (let* ((note (gethash id claude-pair-review--notes))
         (bar (propertize "┃ " 'face 'claude-pair-review-note))
         (answer (string-trim (or (plist-get note :answer) "")))
         (folded (plist-get note :folded))
         (lines (if (string-empty-p answer) nil
                  (claude-pair-review--wrap
                   (split-string (concat "Claude: " answer) "\n")
                   (claude-pair-review--note-width (plist-get note :overlay)))))
         (shown (if folded (seq-take lines claude-pair-review-note-lines) lines))
         (button (lambda (label map help)
                   (propertize label 'keymap map 'mouse-face 'highlight 'claude-pair-note id
                               'help-echo help)))
         (fold (and (> (length lines) claude-pair-review-note-lines)
                    (funcall button (if folded "[unfold]" "[fold]") claude-pair-review-note-fold-map
                             (if folded "mouse-1: show the whole answer" "mouse-1: show only its start"))))
         (close (funcall button "[×]" claude-pair-review-note-button-map "mouse-1: dismiss this note")))
    (concat
     ;; The question, wrapped like the answer, with the buttons on its last line.
     (let ((question (claude-pair-review--wrap
                      (split-string (concat "@claude " (plist-get note :question)) "\n")
                      (- (claude-pair-review--note-width (plist-get note :overlay)) 14))))
       (mapconcat (lambda (line)
                    (concat bar (propertize line 'face '(bold claude-pair-review-note))
                            (if (eq line (car (last question)))
                                (concat "  " (if fold (concat fold " ") "") close)
                              "")
                            "\n"))
                  question ""))
     (if (null lines)
         (concat bar (propertize (if (plist-get note :done) "Claude: (no answer)" "Claude: …")
                                 'face 'claude-pair-review-note)
                 "\n")
       (concat
        (mapconcat (lambda (line) (concat bar (propertize line 'face 'claude-pair-review-note) "\n"))
                   shown "")
        (when (and folded (> (length lines) (length shown)))
          (concat bar (propertize (format "… %d more lines " (- (length lines) (length shown)))
                                  'face '(italic claude-pair-review-note))
                  fold "\n")))))))

(defun claude-pair-review-toggle-note (&optional id)
  "Fold or unfold the note for edit ID, or the nearest note above point."
  (interactive)
  (let ((id (or id (claude-pair-review--note-near-point)
                (user-error "No note from Claude here"))))
    (when-let* ((note (gethash id claude-pair-review--notes)))
      (plist-put note :folded (not (plist-get note :folded)))
      (claude-pair-review--redraw-note id))))

(defun claude-pair-review--note-near-point ()
  "Return the id of the note on the line of point, or the nearest above it."
  (let (best best-pos)
    (maphash (lambda (id note)
               (let ((ov (plist-get note :overlay)))
                 (when (and (eq (overlay-buffer ov) (current-buffer))
                            (<= (overlay-start ov) (line-end-position))
                            (or (null best-pos) (> (overlay-start ov) best-pos)))
                   (setq best id best-pos (overlay-start ov)))))
             claude-pair-review--notes)
    best))

(defun claude-pair-review-click-fold (event)
  "Fold or unfold the note whose button EVENT clicked."
  (interactive "e")
  (let ((string (posn-string (event-start event))))
    (when-let* ((id (and string (get-text-property (cdr string) 'claude-pair-note (car string)))))
      (claude-pair-review-toggle-note id))))

(defun claude-pair-review--make-note (hunk question)
  "Put a note for QUESTION at the start of HUNK."
  (let ((beg (claude-pair-review--hunk-beg hunk)))
    (claude-pair-review-add-note (claude-pair-review--hunk-id hunk) (marker-buffer beg) beg question)))

(defun claude-pair-review-add-note (id buffer pos question)
  "Put the note ID for QUESTION above the line of POS in BUFFER.
Claude's answer goes into it with `claude-pair-review-note-append'."
  (when-let* ((old (gethash id claude-pair-review--notes)))
    (delete-overlay (plist-get old :overlay)))
  (with-current-buffer buffer
    (let* ((bol (save-excursion (goto-char pos) (line-beginning-position)))
           (overlay (make-overlay bol bol nil t nil)))
      ;; Above the banner of whatever Claude proposes there next.
      (overlay-put overlay 'priority 10)
      (overlay-put overlay 'claude-pair-note id)
      (puthash id (list :overlay overlay :question question :answer "") claude-pair-review--notes)
      (overlay-put overlay 'before-string (claude-pair-review--note-text id)))))

(defun claude-pair-review-note-append (id text)
  "Add TEXT, more of Claude's answer, to the note for edit ID."
  (when-let* ((note (gethash id claude-pair-review--notes)))
    (plist-put note :answer (concat (plist-get note :answer) text))
    (claude-pair-review--redraw-note id)))

(defun claude-pair-review-note-done (id)
  "Mark the answer in the note for edit ID as complete."
  (when-let* ((note (gethash id claude-pair-review--notes)))
    (plist-put note :done t)
    (claude-pair-review--redraw-note id)))

(defun claude-pair-review--redraw-note (id)
  "Draw the note for edit ID again."
  (let ((overlay (plist-get (gethash id claude-pair-review--notes) :overlay)))
    (when (overlay-buffer overlay)
      (overlay-put overlay 'before-string (claude-pair-review--note-text id)))))

(defun claude-pair-review-dismiss-note (&optional id)
  "Remove the note for edit ID, or every note in this buffer."
  (interactive)
  (let (ids)
    (maphash (lambda (key note)
               (when (or (equal key id)
                         (and (null id)
                              (eq (overlay-buffer (plist-get note :overlay)) (current-buffer))))
                 (push key ids)))
             claude-pair-review--notes)
    (dolist (key ids)
      (delete-overlay (plist-get (gethash key claude-pair-review--notes) :overlay))
      (remhash key claude-pair-review--notes))))

(defun claude-pair-review-click-dismiss (event)
  "Remove the note whose close button EVENT clicked."
  (interactive "e")
  (let ((string (posn-string (event-start event))))
    (when-let* ((id (and string (get-text-property (cdr string) 'claude-pair-note (car string)))))
      (claude-pair-review-dismiss-note id))))

(defun claude-pair-review--clicked-hunk (event)
  "Return the pending hunk whose button EVENT clicked, and select its window.
The button is on an overlay string (a banner) or in a buffer (the
popup); a popup's frame belongs to another window, which it names."
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (string (posn-string posn))
         (hunk (if string
                   (get-text-property (cdr string) 'claude-pair-hunk (car string))
                 (and (windowp window) (posn-point posn)
                      (get-text-property (posn-point posn) 'claude-pair-hunk (window-buffer window))))))
    (unless (and hunk (eq (claude-pair-review--hunk-state hunk) 'pending))
      (user-error "That hunk is no longer waiting"))
    (let ((home (or (and (windowp window)
                         (window-parameter window 'claude-pair-popup-for))
                    window)))
      (when (window-live-p home)
        (select-frame-set-input-focus (window-frame home))
        (select-window home)))
    hunk))

(defun claude-pair-review-click-apply (event)
  "Apply the hunk whose button EVENT clicked."
  (interactive "e")
  (claude-pair-review-apply-this-hunk (claude-pair-review--clicked-hunk event)))

(defun claude-pair-review-click-reject (event)
  "Reject the hunk whose button EVENT clicked, asking why."
  (interactive "e")
  (claude-pair-review-reject-this-hunk (claude-pair-review--clicked-hunk event)))

(defun claude-pair-review-reject-hunk (&optional all reason)
  "Reject the hunk at point, asking for REASON, an optional note for Claude.
With prefix argument ALL, reject every waiting hunk of its edit."
  (interactive "P")
  (let* ((hunk (or (claude-pair-review--hunk-at-point)
                   (user-error "Point is not on a hunk Claude proposed")))
         (proposal (claude-pair-review--proposal (claude-pair-review--hunk-id hunk)))
         (reason (or reason
                     (read-string (if all
                                      "Tell Claude why, or what to do instead (optional): "
                                    "Tell Claude why you reject this hunk (optional): ")))))
    (if all
        (claude-pair-review-reject (plist-get proposal :id) reason)
      (claude-pair-review-reject-this-hunk hunk reason))))

(defun claude-pair-review--after-decision (proposal)
  "Move to PROPOSAL's next waiting hunk, or tell Claude the outcome."
  (if-let* ((next (car (claude-pair-review--pending proposal))))
      (progn (when (eq (current-buffer) (plist-get proposal :buffer))
               (goto-char (overlay-start (claude-pair-review--hunk-banner next))))
             (message "claude-pair: %d more hunk%s of this edit to decide"
                      (length (claude-pair-review--pending proposal))
                      (if (cdr (claude-pair-review--pending proposal)) "s" "")))
    (claude-pair-review--maybe-finish proposal)))

(defun claude-pair-review--hunks-here ()
  "Return the waiting hunks in this buffer, in buffer order."
  (sort (seq-mapcat #'claude-pair-review--pending
                    (claude-pair-review--in-buffer (current-buffer)))
        (lambda (a b) (< (overlay-start (claude-pair-review--hunk-banner a))
                         (overlay-start (claude-pair-review--hunk-banner b))))))

(defun claude-pair-review-next-hunk ()
  "Move to the next hunk Claude proposed in this buffer."
  (interactive)
  (let ((here (or (claude-pair-review--hunk-at-point) (point))))
    (if-let* ((next (seq-find (lambda (h)
                                (> (overlay-start (claude-pair-review--hunk-banner h))
                                   (if (integerp here) here
                                     (overlay-start (claude-pair-review--hunk-banner here)))))
                              (claude-pair-review--hunks-here))))
        (goto-char (overlay-start (claude-pair-review--hunk-banner next)))
      (user-error "No later hunk"))))

(defun claude-pair-review-previous-hunk ()
  "Move to the previous hunk Claude proposed in this buffer."
  (interactive)
  (let ((here (or (claude-pair-review--hunk-at-point) (point))))
    (if-let* ((previous (seq-find (lambda (h)
                                    (< (overlay-start (claude-pair-review--hunk-banner h))
                                       (if (integerp here) here
                                         (overlay-start (claude-pair-review--hunk-banner here)))))
                                  (reverse (claude-pair-review--hunks-here)))))
        (goto-char (overlay-start (claude-pair-review--hunk-banner previous)))
      (user-error "No earlier hunk"))))

(defun claude-pair-review-show (&optional id)
  "Show the first waiting hunk of Claude's edit ID, or of the newest edit."
  (interactive)
  (let* ((proposal (claude-pair-review--proposal (or id (claude-pair-review--at-point))))
         (hunk (car (claude-pair-review--pending proposal))))
    (pop-to-buffer (plist-get proposal :buffer))
    (goto-char (overlay-start (claude-pair-review--hunk-banner hunk)))))

(defun claude-pair-review--withdraw (params)
  "Remove the proposal PARAMS names; Claude no longer wants an answer."
  (when-let* ((proposal (gethash (plist-get params :requestId) claude-pair-review--proposals)))
    (claude-pair-review--clear proposal)
    (message "claude-pair: Claude withdrew its edit to %s: %s"
             (file-name-nondirectory (plist-get proposal :path))
             (plist-get params :reason))))

(defun claude-pair-review--on-kill ()
  "Reject the waiting hunks of a buffer that is being killed."
  (dolist (proposal (claude-pair-review--in-buffer (current-buffer)))
    (dolist (hunk (claude-pair-review--pending proposal))
      (claude-pair-review--settle hunk 'rejected "The user closed the buffer."))
    (claude-pair-review--maybe-finish proposal)))

(defun claude-pair-review--on-disconnect ()
  "Remove every proposal: with the daemon gone, none can be answered."
  (let (proposals)
    (maphash (lambda (_id p) (push p proposals)) claude-pair-review--proposals)
    (mapc #'claude-pair-review--clear proposals)))

(add-hook 'claude-pair-rpc-disconnect-hook #'claude-pair-review--on-disconnect)

(provide 'claude-pair-review)
;;; claude-pair-review.el ends here
