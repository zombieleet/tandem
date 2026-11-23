;;; tandem-review.el --- Review Claude's edits in your own buffers  -*- lexical-binding: t; -*-

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
(require 'tandem-authorship)
(require 'tandem-diff)
(require 'tandem-layout)
(require 'tandem-rpc)
(require 'seq)
(require 'subr-x)

(defcustom tandem-review-autosave t
  "Whether to save a buffer after applying Claude's edit to it.
Even when non-nil, a buffer is saved only if it had no unsaved
changes of yours, so nothing of yours is ever saved behind your back."
  :type 'boolean
  :group 'tandem)

(defcustom tandem-review-style 'blocking
  "How Claude's edits wait for you.
`blocking': Claude waits for your decision on each edit.
`deferred': Claude is told the edit waits for your review and carries
on; your decisions go to Claude with your next message.
`auto-accept': edits are applied as they arrive, still coloured as
Claude's, and undone like any change."
  :type '(choice (const blocking) (const deferred) (const auto-accept))
  :group 'tandem)

(defvar tandem-review-deferred-functions nil
  "Functions called when you finish deciding a deferred edit.
Each gets the session id, the edit's request id, and a sentence telling
Claude what you decided; the sentence is a question when you asked one.")

(defcustom tandem-review-merge-gap 2
  "Unchanged lines between two changes up to which they make one hunk."
  :type 'natnum
  :group 'tandem)

(defface tandem-review-removed
  '((t :inherit diff-removed :strike-through t :extend t))
  "Face for text a proposed edit would remove."
  :group 'tandem)

(defface tandem-review-added
  '((t :inherit diff-added :extend t))
  "Face for text a proposed edit would add."
  :group 'tandem)

(defface tandem-review-banner
  '((t :inherit warning :weight bold :extend t))
  "Face for the line above a proposed hunk."
  :group 'tandem)

(defface tandem-review-banner-active
  '((t :inherit (highlight tandem-review-banner)))
  "Face for the line above the hunk point is in."
  :group 'tandem)

(defvar tandem-review-show-functions nil
  "Functions called with each proposal once it is shown in its buffer.")

(defvar tandem-review-before-apply-functions nil
  "Functions called with a proposal just before one of its hunks is applied.
They run in the proposal's buffer, which still has its old text.")

(defvar tandem-review-settle-functions nil
  "Functions called with each hunk once it is decided or withdrawn.")

(defvar tandem-review--proposals (make-hash-table :test #'equal)
  "Map from edit request id to its proposal plist.
A proposal has :id, :buffer, :path, :kind, :session, :new-file and
:hunks, a list of `tandem-review--hunk' in buffer order.")

(cl-defstruct (tandem-review--hunk
               (:constructor tandem-review--make-hunk)
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

(defvar-keymap tandem-review-hunk-map
  :doc "Keys on the lines of a proposed hunk."
  "C-c C-a" #'tandem-review-apply-hunk
  "C-c C-k" #'tandem-review-reject-hunk
  "C-c '" #'tandem-review-ask-hunk
  "C-c C-'" #'tandem-review-ask-hunk)

(defvar-keymap tandem-review-apply-button-map
  :doc "Mouse keys on an \"apply\" button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'tandem-review-click-apply
  ;; A click whose press and release land a pixel apart is a "drag".
  "<drag-mouse-1>" #'tandem-review-click-apply)

(defvar-keymap tandem-review-reject-button-map
  :doc "Mouse keys on a \"reject\" button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'tandem-review-click-reject
  "<drag-mouse-1>" #'tandem-review-click-reject)

(defvar-keymap tandem-review-ask-button-map
  :doc "Mouse keys on an \"ask Claude\" button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'tandem-review-click-ask
  "<drag-mouse-1>" #'tandem-review-click-ask)

(defvar-keymap tandem-review-note-button-map
  :doc "Mouse keys on a note's close button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'tandem-review-click-dismiss
  "<drag-mouse-1>" #'tandem-review-click-dismiss)

(defface tandem-review-note
  '((t :inherit font-lock-doc-face :extend t))
  "Face for a question you asked Claude about a hunk, and its answer."
  :group 'tandem)

(defcustom tandem-review-note-lines 3
  "Lines of Claude's answer a folded note shows.
Notes start unfolded, with the whole answer; [fold] folds one."
  :type 'natnum
  :group 'tandem)

(defvar-keymap tandem-review-note-fold-map
  :doc "Mouse keys on a note's fold button."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'tandem-review-click-fold
  "<drag-mouse-1>" #'tandem-review-click-fold)

(defvar tandem-review--notes (make-hash-table :test #'equal)
  "Map from edit request id to the note of the question asked about it.
A note is a plist: :overlay, :question and :answer.")

(defvar-keymap tandem-review-hunk-text-map
  :doc "Keys on a hunk's own text, which you cannot type into anyway."
  :parent tandem-review-hunk-map
  "n" #'tandem-review-next-hunk
  "p" #'tandem-review-previous-hunk)

(defconst tandem-review--locked-message
  "Claude proposed changing this text: C-c C-a applies the hunk, C-c C-k rejects it"
  "Error shown when you type into text a proposal would replace.")

(defconst tandem-review--changed-message
  "The text to replace changed in Emacs while the user was reviewing the edit.  Read the file again."
  "What Claude is told when the text under its edit changed.")

;;;; Helpers

(defun tandem-review-shift-undo (pos delta)
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

(defvar-local tandem-review--hidden nil
  "Non-nil while the proposed text in this buffer is taken out.")
(put 'tandem-review--hidden 'permanent-local t)

(defun tandem-review--quietly (fn)
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
          (tandem-authorship-claude-editing t))
      (funcall fn))
    (restore-buffer-modified-p modified)))

;; An entry is (START END TEXT OVERLAY): proposed TEXT between the
;; markers START and END, which meet where the text goes while it is out.

(defun tandem-review--show-text (entry)
  "Put ENTRY's proposed text into the buffer, unless it is there."
  (pcase-let ((`(,start ,end ,text ,overlay) entry))
    (when (= start end)
      (let ((pos (marker-position start)))
        (tandem-review--quietly
         (lambda () (save-excursion (goto-char pos) (insert text))))
        (tandem-review-shift-undo (1+ pos) (length text))
        (set-marker start pos)
        (set-marker end (+ pos (length text)))
        (move-overlay overlay start end)
        (tandem-review--lock start end)))))

(defun tandem-review--hide-text (entry)
  "Take ENTRY's proposed text out of the buffer, if it is there."
  (pcase-let ((`(,start ,end ,_text ,_overlay) entry))
    (when (< start end)
      (let ((beg (marker-position start))
            (stop (marker-position end)))
        (tandem-review--unlock beg stop)
        (tandem-review--quietly (lambda () (delete-region beg stop)))
        (tandem-review-shift-undo stop (- beg stop))))))

(defun tandem-review--lock (beg end)
  "Make BEG..END read-only, still allowing typing right after END."
  (when (< beg end)
    (with-silent-modifications
      (put-text-property beg end 'read-only tandem-review--locked-message)
      (put-text-property (1- end) end 'rear-nonsticky '(read-only)))))

(defun tandem-review--unlock (beg end)
  "Undo `tandem-review--lock' on BEG..END."
  (when (< beg end)
    (with-silent-modifications
      (remove-list-of-text-properties beg end '(read-only rear-nonsticky)))))

(defun tandem-review--in-buffer (buffer)
  "Return the proposals shown in BUFFER."
  (let (found)
    (maphash (lambda (_id p) (when (eq (plist-get p :buffer) buffer) (push p found)))
             tandem-review--proposals)
    found))

(defun tandem-review--pending (proposal)
  "Return PROPOSAL's hunks that wait for a decision."
  (seq-filter (lambda (hunk) (eq (tandem-review--hunk-state hunk) 'pending))
              (plist-get proposal :hunks)))

(defun tandem-review--hunk-changed-p (hunk)
  "Return non-nil if the text under HUNK is not what Claude saw.
Call it while the hunk's own new text is out of the buffer."
  (not (equal (buffer-substring-no-properties (tandem-review--hunk-beg hunk)
                                              (tandem-review--hunk-end hunk))
              (tandem-review--hunk-old hunk))))

(defun tandem-review--hunk-hidden-p (hunk)
  "Return non-nil if HUNK's new text is out of the buffer."
  (let ((entry (tandem-review--hunk-entry hunk)))
    (or (null entry) (= (nth 0 entry) (nth 1 entry)))))

(defun tandem-review--hide (buffer)
  "Take the proposed text of every pending hunk out of BUFFER."
  (with-current-buffer buffer
    (unless tandem-review--hidden
      (setq tandem-review--hidden t)
      (dolist (proposal (tandem-review--in-buffer buffer))
        (dolist (hunk (tandem-review--pending proposal))
          (when-let* ((entry (tandem-review--hunk-entry hunk)))
            (tandem-review--hide-text entry)))))))

(defun tandem-review--unhide (buffer)
  "Put the proposed text back into BUFFER.
A hunk whose text changed meanwhile, say by a save hook that reformats
the file, is dropped, and Claude hears it with the edit's outcome."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when tandem-review--hidden
        (setq tandem-review--hidden nil)
        (dolist (proposal (tandem-review--in-buffer buffer))
          (let ((dropped nil))
            (dolist (hunk (tandem-review--pending proposal))
              (if (and (tandem-review--hunk-hidden-p hunk)
                       (tandem-review--hunk-changed-p hunk))
                  (progn (tandem-review--settle hunk 'error tandem-review--changed-message)
                         (setq dropped t))
                (when-let* ((entry (tandem-review--hunk-entry hunk)))
                  (tandem-review--show-text entry))
                (tandem-review--place hunk)))
            ;; Only for hunks dropped here: an edit being applied, whose
            ;; save ran this, finishes itself once it knows what was saved.
            (when dropped
              (tandem-review--maybe-finish proposal))))))))

(defun tandem-review-own-text (buffer)
  "Return BUFFER's text without the proposed text waiting for review in it.
That is the text saving would write.  The buffer does not change."
  (with-current-buffer buffer
    (let ((ranges nil))
      (dolist (proposal (tandem-review--in-buffer buffer))
        (dolist (hunk (tandem-review--pending proposal))
          (when-let* ((entry (tandem-review--hunk-entry hunk))
                      ((< (nth 0 entry) (nth 1 entry))))
            (push (cons (marker-position (nth 0 entry)) (marker-position (nth 1 entry))) ranges))))
      (save-restriction
        (widen)
        (let ((pos (point-min)) (parts nil))
          (dolist (range (sort ranges (lambda (a b) (< (car a) (car b)))))
            (push (buffer-substring pos (car range)) parts)
            (setq pos (cdr range)))
          (push (buffer-substring pos (point-max)) parts)
          (apply #'concat (nreverse parts)))))))

(defun tandem-review--before-save ()
  "Take the proposed text out, so saving writes only your text."
  (when (tandem-review--in-buffer (current-buffer))
    (tandem-review--hide (current-buffer))
    ;; In case the save fails and `after-save-hook' never runs.
    (run-at-time 0 nil #'tandem-review--unhide (current-buffer))))
(put 'tandem-review--before-save 'permanent-local-hook t)

(defun tandem-review--after-save ()
  "Put the proposed text back after saving."
  (tandem-review--unhide (current-buffer)))
(put 'tandem-review--after-save 'permanent-local-hook t)

(defun tandem-review--before-revert ()
  "Drop the hunks waiting in a buffer about to be reloaded from disk."
  (dolist (proposal (tandem-review--in-buffer (current-buffer)))
    (dolist (hunk (tandem-review--pending proposal))
      (tandem-review--settle
       hunk 'error "The file was reloaded from disk in Emacs while the user was reviewing the edit.  Read it again."))
    (tandem-review--maybe-finish proposal)))
(put 'tandem-review--before-revert 'permanent-local-hook t)

(defun tandem-review--conflicts-p (kind found)
  "Return non-nil if an edit of KIND at FOUND meets another proposal here.
FOUND is a list of (BEG . END) ranges."
  (seq-some
   (lambda (other)
     (or (eq kind 'write)
         (eq (plist-get other :kind) 'write)
         (seq-some (lambda (hunk)
                     (let* ((beg (tandem-review--hunk-beg hunk))
                            (end (tandem-review--hunk-end hunk))
                            (b (min beg end)) (e (max beg end)))
                       (seq-some (lambda (range)
                                   (or (and (< (car range) e) (< b (cdr range)))
                                       ;; An insertion inside the range.
                                       (and (= b e) (< (car range) b (cdr range)))))
                                 found)))
                   (tandem-review--pending other))))
   (tandem-review--in-buffer (current-buffer))))

;;;; Hunks

(defun tandem-review--lines (string)
  "Split STRING into a vector of lines, each keeping its newline."
  (let ((start 0) lines)
    (while (string-match "\n" string start)
      (push (substring string start (match-end 0)) lines)
      (setq start (match-end 0)))
    (when (< start (length string))
      (push (substring string start) lines))
    (vconcat (nreverse lines))))

(defun tandem-review--merge (ranges gap)
  "Join RANGES that are at most GAP unchanged lines apart."
  (let (out)
    (dolist (r ranges)
      (if (and out (<= (- (nth 0 r) (nth 1 (car out))) gap))
          (setcar out (list (nth 0 (car out)) (nth 1 r) (nth 2 (car out)) (nth 3 r)))
        (push r out)))
    (nreverse out)))

(defun tandem-review--hunk-specs (old new)
  "Return the hunks that turn OLD into NEW.
Each is (START END TEXT): OLD's characters START to END-1 become TEXT."
  (let* ((a (tandem-review--lines old))
         (b (tandem-review--lines new))
         (offsets (make-vector (1+ (length a)) 0)))
    (dotimes (i (length a))
      (aset offsets (1+ i) (+ (aref offsets i) (length (aref a i)))))
    (mapcar (lambda (r)
              (list (aref offsets (nth 0 r)) (aref offsets (nth 1 r))
                    (apply #'concat (append (seq-subseq b (nth 2 r) (nth 3 r)) nil))))
            (tandem-review--merge (tandem-diff a b)
                                       tandem-review-merge-gap))))

(defun tandem-review--occurrences (old)
  "Return the (BEG . END) of every exact occurrence of OLD in the buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((case-fold-search nil) found)
        (while (search-forward old nil t)
          (push (cons (match-beginning 0) (match-end 0)) found))
        (nreverse found)))))

(defun tandem-review--answer (id outcome &rest fields)
  "Tell the daemon how edit ID ended: OUTCOME, plus FIELDS.
FIELDS may hold :message, :saved, :created and :hunks."
  (let ((message (or (plist-get fields :message) "")))
    (condition-case err
        (tandem-rpc-request
         'edit/answer
         (append (list :requestId id :outcome outcome :message message
                       :saved (if (plist-get fields :saved) t :json-false)
                       :created (if (plist-get fields :created) t :json-false))
                 (when (plist-get fields :hunks)
                   (list :hunks (vconcat (plist-get fields :hunks))))))
      (jsonrpc-error
       (message "tandem: %s" (tandem-rpc-error-message err)))
      (error
       (message "tandem: could not tell the daemon about the edit: %s"
                (error-message-string err))))))

;;;; Proposals arriving

(defun tandem-review--on-notification (method params)
  "Handle `edit/propose' and `edit/withdraw' with PARAMS.
METHOD is the notification's name.  The work runs from a timer, out
of the process filter, because visiting a file can take a while."
  (pcase method
    ('edit/propose (run-at-time 0 nil #'tandem-review--propose params))
    ('edit/withdraw (run-at-time 0 nil #'tandem-review--withdraw params))))

(add-hook 'tandem-rpc-notification-functions #'tandem-review--on-notification)

(defun tandem-review--check (params)
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
      (let ((found (tandem-review--occurrences old)))
        (cond
         ((null found)
          (format "String to replace not found in file.\nString: %s" old))
         ((and (cdr found) (not (eq (plist-get params :replaceAll) t)))
          (format "Found %d matches of the string to replace, but replace_all is false. \
To replace all occurrences, set replace_all to true. To replace only one occurrence, \
please provide more context to uniquely identify the instance.\nString: %s"
                  (length found) old))
         (t (list 'edit found new))))))))

(defun tandem-review--propose (params)
  "Show the edit in PARAMS in its file's buffer, or report why it can't be made."
  (let* ((id (plist-get params :requestId))
         (path (plist-get params :filePath))
         (buffer (condition-case err
                     (tandem-layout-file-buffer path)
                   (error (tandem-review--answer
                           id "error" :message (format "Emacs could not open %s: %s"
                                                       path (error-message-string err)))
                          nil))))
    (when buffer
      (with-current-buffer buffer
        ;; Check against your text alone, not other proposals shown here.
        (tandem-review--hide buffer)
        (unwind-protect
            (progn
              ;; A buffer you have not touched follows the file on disk, so a
              ;; command Claude ran first is not hidden behind a stale buffer.
              (when (and (not (buffer-modified-p)) (file-exists-p path)
                         (not (verify-visited-file-modtime buffer)))
                (let ((inhibit-message t))
                  (revert-buffer t t t)))
              (let ((check (tandem-review--check params)))
                (cond
                 ((stringp check)
                  (tandem-review--answer id "error" :message check))
                 ((tandem-review--conflicts-p (nth 0 check) (nth 1 check))
                  (tandem-review--answer
                   id "error" :message "Another edit to the same text is waiting for the user's review.  Wait for its result, then read the file again."))
                 (t
                  (tandem-review--show-proposal id path params check)))))
          (tandem-review--unhide buffer))))))

(defun tandem-review--show-proposal (id path params check)
  "Draw proposal ID for PATH in the current buffer, hunk by hunk.
PARAMS is the request; CHECK is what `tandem-review--check' returned."
  (pcase-let* ((`(,kind ,found ,new) check)
               (specs nil))
    (dolist (range found)
      (let ((old (buffer-substring-no-properties (car range) (cdr range))))
        (dolist (spec (tandem-review--hunk-specs old new))
          (push (list (+ (car range) (nth 0 spec)) (+ (car range) (nth 1 spec)) (nth 2 spec))
                specs))))
    (setq specs (nreverse specs))
    (if (null specs)
        (tandem-review--answer id "error" :message "No changes to make: the file already has this text.")
      (let* ((index 0)
             ;; Markers for every hunk first, so text added for one moves the others.
             (hunks (mapcar (lambda (spec)
                              (tandem-review--make-hunk
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
                             :deferred (eq tandem-review-style 'deferred))))
        (puthash id proposal tandem-review--proposals)
        (dolist (hunk hunks)
          (tandem-review--draw hunk proposal))
        (add-hook 'kill-buffer-hook #'tandem-review--on-kill nil t)
        (add-hook 'before-save-hook #'tandem-review--before-save -100 t)
        (add-hook 'after-save-hook #'tandem-review--after-save 100 t)
        (add-hook 'before-revert-hook #'tandem-review--before-revert nil t)
        (run-hook-with-args 'tandem-review-show-functions proposal)
        ;; Where the chat is.  When it is not shown, Claude is waiting for
        ;; you, so show it where you are, unless you are in another tab than
        ;; Claude's: your tabs are never touched.
        (tandem-layout-show (current-buffer)
                                 :pos (overlay-start (tandem-review--hunk-banner (car hunks)))
                                 :session (plist-get params :sessionId)
                                 :fallback (not (tandem-layout-elsewhere-p)))
        (pcase tandem-review-style
          ('deferred
           ;; Claude carries on; your decisions go to it later.
           (tandem-review--answer id "deferred")
           (message "tandem: Claude's edit to %s waits for your review (deferred)%s"
                    (file-name-nondirectory path) (tandem-layout-where-text)))
          ('auto-accept
           (run-at-time 0 nil (lambda ()
                                (when (tandem-review-pending-p id)
                                  (tandem-review-apply id)))))
          (_
           (message "tandem: Claude proposes an edit to %s%s%s; C-c C-a applies a hunk, C-c C-k rejects it"
                    (file-name-nondirectory path)
                    (if (cdr hunks) (format " (%d hunks)" (length hunks)) "")
                    (tandem-layout-where-text))))))))

(defun tandem-review-button (label map hunk)
  "Return LABEL as a button with mouse keys MAP acting on HUNK."
  (propertize label 'keymap map 'mouse-face 'highlight 'tandem-hunk hunk
              'help-echo "mouse-1: do it"))

(defun tandem-review--banner-text (hunk proposal &optional active)
  "Return the line shown above HUNK of PROPOSAL.
With ACTIVE, the line of the hunk point is in.  Its key hints are
buttons too, so in a terminal the line is the hunk's popup."
  (let* ((total (length (plist-get proposal :hunks)))
         (apply (tandem-review-button
                 (if (> total 1) "C-c C-a apply" "C-c C-a applies")
                 tandem-review-apply-button-map hunk))
         (reject (tandem-review-button
                  (if (> total 1) "C-c C-k reject" "C-c C-k rejects")
                  tandem-review-reject-button-map hunk))
         (text (if (> total 1)
                   ;; Short enough not to wrap in a window of 80 columns.
                   (concat (format "▸ Claude · hunk %d of %d · " (tandem-review--hunk-index hunk) total)
                           apply " · " reject " · n/p move\n")
                 (concat (format "▸ Claude proposes %s · "
                                 (if (eq (plist-get proposal :kind) 'write)
                                     (if (plist-get proposal :new-file) "this new file" "new content for this file")
                                   "an edit"))
                         apply " · " reject "\n"))))
    (add-face-text-property 0 (length text)
                            (if active 'tandem-review-banner-active 'tandem-review-banner)
                            t text)
    text))

(defun tandem-review-set-active (hunk active)
  "Draw HUNK's banner as the one point is in when ACTIVE is non-nil."
  (when (eq (tandem-review--hunk-state hunk) 'pending)
    (when-let* ((proposal (gethash (tandem-review--hunk-id hunk) tandem-review--proposals))
                (banner (tandem-review--hunk-banner hunk)))
      (when (overlay-buffer banner)
        (overlay-put banner 'before-string (tandem-review--banner-text hunk proposal active))))))

(defun tandem-review--draw (hunk proposal)
  "Draw HUNK of PROPOSAL: lock and strike its old text, show its new text."
  (let ((beg (tandem-review--hunk-beg hunk))
        (end (tandem-review--hunk-end hunk))
        (new (tandem-review--hunk-new hunk))
        (overlays nil))
    (tandem-review--lock beg end)
    (when (< beg end)
      (let ((ov (make-overlay beg end nil t nil)))
        (overlay-put ov 'face 'tandem-review-removed)
        (overlay-put ov 'keymap tandem-review-hunk-text-map)
        (overlay-put ov 'priority 1)
        (overlay-put ov 'tandem-hunk hunk)
        (push ov overlays)))
    (unless (string-empty-p new)
      (let* ((pos (marker-position end))
             (entry (list (copy-marker pos t) (copy-marker pos) new (make-overlay pos pos nil t nil))))
        (overlay-put (nth 3 entry) 'face 'tandem-review-added)
        (overlay-put (nth 3 entry) 'keymap tandem-review-hunk-text-map)
        (overlay-put (nth 3 entry) 'priority 1)
        (overlay-put (nth 3 entry) 'tandem-hunk hunk)
        (setf (tandem-review--hunk-entry hunk) entry)
        (tandem-review--show-text entry)
        (push (nth 3 entry) overlays)))
    (let ((banner (make-overlay beg beg))
          (region (make-overlay beg beg)))
      (overlay-put banner 'before-string (tandem-review--banner-text hunk proposal))
      (overlay-put region 'keymap tandem-review-hunk-map)
      (overlay-put region 'tandem-hunk hunk)
      (overlay-put region 'tandem-proposal (plist-get proposal :id))
      (setf (tandem-review--hunk-banner hunk) banner
            (tandem-review--hunk-region hunk) region
            (tandem-review--hunk-overlays hunk) (append (list banner region) overlays)))
    (tandem-review--place hunk)))

(defun tandem-review--place (hunk)
  "Fit HUNK's banner and its key overlay around its text."
  (let* ((entry (tandem-review--hunk-entry hunk))
         (positions (mapcar #'marker-position
                            (append (list (tandem-review--hunk-beg hunk)
                                          (tandem-review--hunk-end hunk))
                                    (and entry (list (nth 0 entry) (nth 1 entry))))))
         (bol (save-excursion (goto-char (apply #'min positions)) (line-beginning-position)))
         (eol (save-excursion (goto-char (apply #'max positions))
                              (if (and (bolp) (> (point) bol)) (point) (line-end-position)))))
    (move-overlay (tandem-review--hunk-banner hunk) bol bol)
    (move-overlay (tandem-review--hunk-region hunk) bol eol)))

;;;; Deciding

(defun tandem-review--settle (hunk state &optional note)
  "Take HUNK's display out of its buffer and record STATE and NOTE."
  (when (eq (tandem-review--hunk-state hunk) 'pending)
    (let ((beg (tandem-review--hunk-beg hunk))
          (end (tandem-review--hunk-end hunk))
          (entry (tandem-review--hunk-entry hunk)))
      (when (and (marker-buffer beg) (buffer-live-p (marker-buffer beg)))
        (with-current-buffer (marker-buffer beg)
          (when entry
            (tandem-review--hide-text entry))
          (tandem-review--unlock (min beg end) (max beg end))))
      (when entry
        (set-marker (nth 0 entry) nil)
        (set-marker (nth 1 entry) nil))
      (mapc #'delete-overlay (tandem-review--hunk-overlays hunk))
      (setf (tandem-review--hunk-state hunk) state
            (tandem-review--hunk-note hunk) note)
      (run-hook-with-args 'tandem-review-settle-functions hunk))))

(defun tandem-review--free (hunk)
  "Free HUNK's markers once it is decided."
  (set-marker (tandem-review--hunk-beg hunk) nil)
  (set-marker (tandem-review--hunk-end hunk) nil))

(defun tandem-review--clear (proposal)
  "Remove PROPOSAL without answering: its text, overlays and locks."
  (remhash (plist-get proposal :id) tandem-review--proposals)
  (dolist (hunk (plist-get proposal :hunks))
    (tandem-review--settle hunk 'withdrawn)
    (tandem-review--free hunk)))

(defun tandem-review--save (proposal)
  "Save PROPOSAL's buffer, making a new file's directory first."
  (when (plist-get proposal :new-file)
    (make-directory (file-name-directory (plist-get proposal :path)) t))
  (let ((save-silently t) (inhibit-message t))
    (save-buffer)))

(defun tandem-review--apply-one (hunk proposal &optional no-save)
  "Apply HUNK of PROPOSAL as one undo step, then save if the buffer was clean.
With NO-SAVE, leave saving to the caller.  Return non-nil if applied."
  (with-current-buffer (plist-get proposal :buffer)
    (let ((clean (not (buffer-modified-p)))
          (beg (tandem-review--hunk-beg hunk))
          (end (tandem-review--hunk-end hunk)))
      (run-hook-with-args 'tandem-review-before-apply-functions proposal)
      (when-let* ((entry (tandem-review--hunk-entry hunk)))
        (tandem-review--hide-text entry))
      (cond
       ((tandem-review--hunk-changed-p hunk)
        (tandem-review--settle hunk 'error tandem-review--changed-message)
        nil)
       (t
        ;; Whatever happens, the hunk gets a decision, or Claude waits forever.
        (condition-case err
            (let ((start (marker-position beg))
                  (stop (marker-position end)))
              (tandem-review--settle hunk 'applied)
              (tandem-review--replace start stop (tandem-review--hunk-new hunk)
                                           (tandem-review--author proposal))
              (when (and tandem-review-autosave clean (not no-save))
                (tandem-review--save proposal)
                (setf (tandem-review--hunk-saved hunk) t))
              t)
          (error
           (setf (tandem-review--hunk-state hunk) 'error
                 (tandem-review--hunk-note hunk)
                 (format "Emacs could not apply %s: %s"
                         (if (cdr (plist-get proposal :hunks))
                             (format "hunk %d" (tandem-review--hunk-index hunk))
                           "the edit")
                         (error-message-string err)))
           nil)))))))

(defun tandem-review--author (proposal)
  "Return the authorship record of PROPOSAL's text, making it once."
  (or (plist-get proposal :author)
      (let* ((session (plist-get proposal :session))
             (info (and (fboundp 'tandem-chat-session-info)
                        (tandem-chat-session-info session)))
             (id (tandem-authorship-record
                  :session session :request (plist-get proposal :id)
                  :file (plist-get proposal :path)
                  :model (plist-get info :model) :turn (plist-get info :turn)
                  :prompt (plist-get info :prompt))))
        (plist-put proposal :author id)
        id)))

(defun tandem-review--replace (beg end text &optional author)
  "Replace BEG..END with TEXT as a single undo step.
With AUTHOR, an authorship record id, mark TEXT as Claude's."
  (let ((group (prepare-change-group))
        (done nil))
    (unwind-protect
        (progn
          (activate-change-group group)
          (save-excursion
            (goto-char beg)
            (let ((tandem-authorship-claude-editing t))
              (delete-region beg end)
              (insert text))
            (when author
              (tandem-authorship-mark beg (+ beg (length text)) author)))
          (setq done t))
      (if done
          (accept-change-group group)
        (cancel-change-group group))
      (undo-amalgamate-change-group group))))

(defun tandem-review--hunk-report (hunk)
  "Describe HUNK's decision for the daemon."
  (let ((note (tandem-review--hunk-note hunk)))
    (list :index (tandem-review--hunk-index hunk)
          :line (tandem-review--hunk-line hunk)
          :oldLines (length (tandem-review--lines (tandem-review--hunk-old hunk)))
          :newLines (length (tandem-review--lines (tandem-review--hunk-new hunk)))
          :decision (symbol-name (tandem-review--hunk-state hunk))
          :note (or note "")
          :saved (if (tandem-review--hunk-saved hunk) t :json-false))))

(defun tandem-review--maybe-finish (proposal)
  "Tell Claude how PROPOSAL ended, once no hunk of it waits."
  (when (and (gethash (plist-get proposal :id) tandem-review--proposals)
             (null (tandem-review--pending proposal)))
    (remhash (plist-get proposal :id) tandem-review--proposals)
    (let* ((id (plist-get proposal :id))
           (hunks (plist-get proposal :hunks))
           (states (mapcar #'tandem-review--hunk-state hunks))
           (applied (seq-filter (lambda (h) (eq (tandem-review--hunk-state h) 'applied)) hunks))
           (saved (and applied (seq-every-p #'tandem-review--hunk-saved applied)))
           (name (file-name-nondirectory (plist-get proposal :path)))
           (notes (delq nil (mapcar (lambda (h)
                                      (let ((note (tandem-review--hunk-note h)))
                                        (and note (not (string-empty-p note)) note)))
                                    hunks))))
      (mapc #'tandem-review--free hunks)
      (cond
       ((plist-get proposal :deferred)
        (run-hook-with-args 'tandem-review-deferred-functions
                            (plist-get proposal :session) id
                            (tandem-review--summary proposal))
        (message "tandem: your review of Claude's edit to %s goes to Claude with your next message"
                 name))
       ((memq 'asked states)
        (let ((question (tandem-review--hunk-note
                         (seq-find (lambda (h) (eq (tandem-review--hunk-state h) 'asked)) hunks))))
          (tandem-review--answer id "question" :message question :saved saved
                                      :hunks (mapcar #'tandem-review--hunk-report hunks))
          (message "tandem: asked Claude about %s; its answer comes in the chat and in a note"
                   name)))
       ((seq-every-p (lambda (s) (eq s 'applied)) states)
        (tandem-review--answer id "applied" :saved saved
                                    :created (and saved (plist-get proposal :new-file)))
        (message "tandem: applied Claude's edit to %s%s" name
                 (if saved "" " (not saved: the buffer has unsaved changes of yours)")))
       ((and (null (cdr hunks)) (eq (car states) 'error))
        (tandem-review--answer id "error" :message (car notes))
        (message "tandem: Claude's edit to %s was not applied: %s" name (car notes)))
       ((seq-every-p (lambda (s) (eq s 'rejected)) states)
        (tandem-review--answer id "rejected" :message (string-join (seq-uniq notes) "\n")
                                    :hunks (and (cdr hunks) (mapcar #'tandem-review--hunk-report hunks)))
        (message "tandem: rejected Claude's edit to %s" name))
       (t
        (tandem-review--answer id "partial" :saved saved
                                    :hunks (mapcar #'tandem-review--hunk-report hunks))
        (message "tandem: applied %d of %d hunks of Claude's edit to %s"
                 (length applied) (length hunks) name))))))

;;;; Commands

(defun tandem-review--hunk-at-point ()
  "Return the pending hunk at point, or nil."
  (let ((hunk (get-char-property (point) 'tandem-hunk)))
    (and hunk (eq (tandem-review--hunk-state hunk) 'pending) hunk)))

(defun tandem-review--at-point ()
  "Return the id of the edit at point, else one in this buffer, else any."
  (or (when-let* ((hunk (tandem-review--hunk-at-point)))
        (tandem-review--hunk-id hunk))
      (let (here any)
        (maphash (lambda (id p)
                   (setq any id)
                   (when (eq (plist-get p :buffer) (current-buffer))
                     (setq here id)))
                 tandem-review--proposals)
        (or here any))
      (user-error "Claude has no proposed edit waiting")))

(defun tandem-review--proposal (id)
  "Return the waiting proposal ID, or signal a `user-error'."
  (or (gethash id tandem-review--proposals)
      (user-error "That edit is no longer waiting")))

(defun tandem-review-pending-p (id)
  "Return non-nil if edit ID waits for your decision in this Emacs."
  (and (gethash id tandem-review--proposals) t))

(defun tandem-review-waiting (&optional session)
  "Return how many hunks wait for your decision, of SESSION's edits or all."
  (let ((n 0))
    (maphash (lambda (_id p)
               (when (or (null session) (equal session (plist-get p :session)))
                 (setq n (+ n (length (tandem-review--pending p))))))
             tandem-review--proposals)
    n))

(defun tandem-review--name (proposal)
  "Return PROPOSAL's file name, relative to its chat's project when known."
  (let* ((path (plist-get proposal :path))
         (root (and (fboundp 'tandem-chat-session-info)
                    (plist-get (tandem-chat-session-info (plist-get proposal :session)) :root))))
    (if (and root (file-in-directory-p path root))
        (file-relative-name path root)
      (abbreviate-file-name path))))

(defun tandem-review--summary (proposal)
  "Return a sentence telling Claude what you decided on PROPOSAL."
  (let* ((name (tandem-review--name proposal))
         (hunks (plist-get proposal :hunks))
         (states (mapcar #'tandem-review--hunk-state hunks))
         (applied (seq-filter (lambda (h) (eq (tandem-review--hunk-state h) 'applied)) hunks))
         (saved (and applied (seq-every-p #'tandem-review--hunk-saved applied)))
         (where (lambda (h) (if (cdr hunks)
                                (format "hunk %d (line %d)" (tandem-review--hunk-index h)
                                        (tandem-review--hunk-line h))
                              "it")))
         (note (lambda (h) (let ((n (tandem-review--hunk-note h)))
                             (if (and n (not (string-empty-p n))) (format " (note: %s)" n) "")))))
    (cond
     ((memq 'asked states)
      (let ((asked (seq-find (lambda (h) (eq (tandem-review--hunk-state h) 'asked)) hunks)))
        (format "About your edit to %s, %s, the user asks: %s%s"
                name (funcall where asked) (tandem-review--hunk-note asked)
                (if applied
                    (format " (applied first: %s; the rest is not applied)"
                            (mapconcat (lambda (h) (format "hunk %d" (tandem-review--hunk-index h)))
                                       applied ", "))
                  " (not applied)"))))
     ((seq-every-p (lambda (s) (eq s 'applied)) states)
      (format "Your edit to %s was applied%s." name
              (if saved " and saved" ", not saved yet, because the buffer has unsaved changes of the user's")))
     ((seq-every-p (lambda (s) (eq s 'rejected)) states)
      (format "Your edit to %s was rejected%s; do not send it again."
              name (mapconcat note hunks "")))
     ((and (null (cdr hunks)) (eq (car states) 'error))
      (format "Your edit to %s was not applied: %s" name (tandem-review--hunk-note (car hunks))))
     (t
      (format "Your edit to %s, hunk by hunk: %s. Read the file again before you edit it."
              name
              (mapconcat (lambda (h)
                           (format "%s %s%s" (funcall where h)
                                   (pcase (tandem-review--hunk-state h)
                                     ('applied "applied") ('rejected "rejected") (_ "not applied"))
                                   (funcall note h)))
                         hunks "; "))))))

(defun tandem-set-review-style (style)
  "Set how Claude's edits wait for you, to STYLE; see `tandem-review-style'."
  (interactive
   (list (intern (completing-read (format "Review style (now %s): " tandem-review-style)
                                  '("blocking" "deferred" "auto-accept") nil t))))
  (setq tandem-review-style style)
  (message "tandem: Claude's next edits are %s"
           (pcase style
             ('blocking "reviewed while Claude waits")
             ('deferred "reviewed when you like, while Claude carries on")
             (_ "applied as they arrive"))))

(defun tandem-review-hunk-count (id)
  "Return (WAITING . TOTAL), the hunks of edit ID, or nil if it is not waiting."
  (when-let* ((proposal (gethash id tandem-review--proposals)))
    (cons (length (tandem-review--pending proposal))
          (length (plist-get proposal :hunks)))))

(defun tandem-review-apply (&optional id)
  "Apply every waiting hunk of Claude's edit ID, or of the edit at point.
Each hunk is one undo step.  The buffer is saved once, when it had no
unsaved changes of yours and `tandem-review-autosave' is non-nil."
  (interactive)
  (let* ((proposal (tandem-review--proposal (or id (tandem-review--at-point))))
         (buffer (plist-get proposal :buffer)))
    (if (not (buffer-live-p buffer))
        (progn (dolist (hunk (tandem-review--pending proposal))
                 (tandem-review--settle hunk 'error "The buffer was killed."))
               (tandem-review--maybe-finish proposal))
      (with-current-buffer buffer
        (let ((clean (not (buffer-modified-p)))
              (applied nil))
          ;; From the last hunk back, so each one's line numbers still hold.
          (dolist (hunk (reverse (tandem-review--pending proposal)))
            (when (tandem-review--apply-one hunk proposal t)
              (push hunk applied)))
          (when (and applied tandem-review-autosave clean)
            (condition-case err
                (progn (tandem-review--save proposal)
                       (dolist (hunk applied)
                         (setf (tandem-review--hunk-saved hunk) t)))
              (error (message "tandem: could not save %s: %s"
                              (buffer-name) (error-message-string err))))))
        (tandem-review--maybe-finish proposal)))))

(defun tandem-review-reject (&optional id reason)
  "Reject every waiting hunk of Claude's edit ID, or of the edit at point.
Interactively, ask for REASON, an optional note Claude reads."
  (interactive
   (list nil (read-string "Tell Claude why, or what to do instead (optional): ")))
  (let ((proposal (tandem-review--proposal (or id (tandem-review--at-point)))))
    (dolist (hunk (tandem-review--pending proposal))
      (tandem-review--settle hunk 'rejected (or reason "")))
    (tandem-review--maybe-finish proposal)))

(defun tandem-review-apply-hunk (&optional all)
  "Apply the hunk at point, as one undo step.
With prefix argument ALL, apply every waiting hunk of its edit."
  (interactive "P")
  (let* ((hunk (or (tandem-review--hunk-at-point)
                   (user-error "Point is not on a hunk Claude proposed")))
         (proposal (tandem-review--proposal (tandem-review--hunk-id hunk))))
    (if all
        (tandem-review-apply (plist-get proposal :id))
      (tandem-review-apply-this-hunk hunk))))

(defun tandem-review-apply-this-hunk (hunk)
  "Apply HUNK, then move to the next one of its edit."
  (let ((proposal (tandem-review--proposal (tandem-review--hunk-id hunk))))
    (tandem-review--apply-one hunk proposal)
    (tandem-review--after-decision proposal)))

(defun tandem-review-reject-this-hunk (hunk &optional reason)
  "Reject HUNK, asking for REASON unless given, then move to the next one."
  (let ((proposal (tandem-review--proposal (tandem-review--hunk-id hunk)))
        (reason (or reason (read-string "Tell Claude why you reject this hunk (optional): "))))
    (tandem-review--settle hunk 'rejected reason)
    (tandem-review--after-decision proposal)))

(defun tandem-review-ask-hunk (&optional question)
  "Ask Claude QUESTION about the hunk at point before deciding on it.
The edit goes back to Claude with your question: hunks you decided keep
their decisions, the others are not applied, and Claude answers and may
propose them again.  Its answer shows as a note where the hunk was."
  (interactive)
  (tandem-review-ask-this-hunk
   (or (tandem-review--hunk-at-point)
       (user-error "Point is not on a hunk Claude proposed"))
   question))

(defun tandem-review-ask-this-hunk (hunk &optional question)
  "Ask Claude QUESTION about HUNK; see `tandem-review-ask-hunk'."
  (let* ((proposal (tandem-review--proposal (tandem-review--hunk-id hunk)))
         (question (string-trim
                    (or question
                        (read-string (format "@claude (about hunk %d): "
                                             (tandem-review--hunk-index hunk))
                                     nil nil nil t)))))
    (when (string-empty-p question)
      (user-error "Type a question for Claude"))
    (tandem-review--make-note hunk question)
    (tandem-review--settle hunk 'asked question)
    (dolist (other (tandem-review--pending proposal))
      (tandem-review--settle other 'undecided))
    (tandem-review--maybe-finish proposal)))

(defun tandem-review-click-ask (event)
  "Ask Claude about the hunk whose button EVENT clicked."
  (interactive "e")
  (tandem-review-ask-this-hunk (tandem-review--clicked-hunk event)))

;;;; Notes: a question about a hunk, and Claude's answer

(defun tandem-review--wrap (lines width)
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

(defun tandem-review--note-width (overlay)
  "Return how wide the note in OVERLAY may be."
  (let ((window (and (overlay-buffer overlay) (get-buffer-window (overlay-buffer overlay) t))))
    (max 40 (- (if window (window-body-width window) 80) 3))))

(defun tandem-review--note-text (id)
  "Return the lines of the note for edit ID."
  (let* ((note (gethash id tandem-review--notes))
         (bar (propertize "┃ " 'face 'tandem-review-note))
         (answer (string-trim (or (plist-get note :answer) "")))
         (folded (plist-get note :folded))
         (lines (if (string-empty-p answer) nil
                  (tandem-review--wrap
                   (split-string (concat "Claude: " answer) "\n")
                   (tandem-review--note-width (plist-get note :overlay)))))
         (shown (if folded (seq-take lines tandem-review-note-lines) lines))
         (button (lambda (label map help)
                   (propertize label 'keymap map 'mouse-face 'highlight 'tandem-note id
                               'help-echo help)))
         (fold (and (> (length lines) tandem-review-note-lines)
                    (funcall button (if folded "[unfold]" "[fold]") tandem-review-note-fold-map
                             (if folded "mouse-1: show the whole answer" "mouse-1: show only its start"))))
         (close (funcall button "[×]" tandem-review-note-button-map "mouse-1: dismiss this note")))
    (concat
     ;; The question, wrapped like the answer, with the buttons on its last line.
     (let ((question (tandem-review--wrap
                      (split-string (concat "@claude " (plist-get note :question)) "\n")
                      (- (tandem-review--note-width (plist-get note :overlay)) 14))))
       (mapconcat (lambda (line)
                    (concat bar (propertize line 'face '(bold tandem-review-note))
                            (if (eq line (car (last question)))
                                (concat "  " (if fold (concat fold " ") "") close)
                              "")
                            "\n"))
                  question ""))
     (if (null lines)
         (concat bar (propertize (if (plist-get note :done) "Claude: (no answer)" "Claude: …")
                                 'face 'tandem-review-note)
                 "\n")
       (concat
        (mapconcat (lambda (line) (concat bar (propertize line 'face 'tandem-review-note) "\n"))
                   shown "")
        (when (and folded (> (length lines) (length shown)))
          (concat bar (propertize (format "… %d more lines " (- (length lines) (length shown)))
                                  'face '(italic tandem-review-note))
                  fold "\n")))))))

(defun tandem-review-toggle-note (&optional id)
  "Fold or unfold the note for edit ID, or the nearest note above point."
  (interactive)
  (let ((id (or id (tandem-review--note-near-point)
                (user-error "No note from Claude here"))))
    (when-let* ((note (gethash id tandem-review--notes)))
      (plist-put note :folded (not (plist-get note :folded)))
      (tandem-review--redraw-note id))))

(defun tandem-review--note-near-point ()
  "Return the id of the note on the line of point, or the nearest above it."
  (let (best best-pos)
    (maphash (lambda (id note)
               (let ((ov (plist-get note :overlay)))
                 (when (and (eq (overlay-buffer ov) (current-buffer))
                            (<= (overlay-start ov) (line-end-position))
                            (or (null best-pos) (> (overlay-start ov) best-pos)))
                   (setq best id best-pos (overlay-start ov)))))
             tandem-review--notes)
    best))

(defun tandem-review-click-fold (event)
  "Fold or unfold the note whose button EVENT clicked."
  (interactive "e")
  (let ((string (posn-string (event-start event))))
    (when-let* ((id (and string (get-text-property (cdr string) 'tandem-note (car string)))))
      (tandem-review-toggle-note id))))

(defun tandem-review--make-note (hunk question)
  "Put a note for QUESTION at the start of HUNK."
  (let ((beg (tandem-review--hunk-beg hunk)))
    (tandem-review-add-note (tandem-review--hunk-id hunk) (marker-buffer beg) beg question)))

(defun tandem-review-add-note (id buffer pos question)
  "Put the note ID for QUESTION above the line of POS in BUFFER.
Claude's answer goes into it with `tandem-review-note-append'."
  (when-let* ((old (gethash id tandem-review--notes)))
    (delete-overlay (plist-get old :overlay)))
  (with-current-buffer buffer
    (let* ((bol (save-excursion (goto-char pos) (line-beginning-position)))
           (overlay (make-overlay bol bol nil t nil)))
      ;; Above the banner of whatever Claude proposes there next.
      (overlay-put overlay 'priority 10)
      (overlay-put overlay 'tandem-note id)
      (puthash id (list :overlay overlay :question question :answer "") tandem-review--notes)
      (overlay-put overlay 'before-string (tandem-review--note-text id)))))

(defun tandem-review-note-append (id text)
  "Add TEXT, more of Claude's answer, to the note for edit ID."
  (when-let* ((note (gethash id tandem-review--notes)))
    (plist-put note :answer (concat (plist-get note :answer) text))
    (tandem-review--redraw-note id)))

(defun tandem-review-note-done (id)
  "Mark the answer in the note for edit ID as complete."
  (when-let* ((note (gethash id tandem-review--notes)))
    (plist-put note :done t)
    (tandem-review--redraw-note id)))

(defun tandem-review--redraw-note (id)
  "Draw the note for edit ID again."
  (let ((overlay (plist-get (gethash id tandem-review--notes) :overlay)))
    (when (overlay-buffer overlay)
      (overlay-put overlay 'before-string (tandem-review--note-text id)))))

(defun tandem-review-dismiss-note (&optional id)
  "Remove the note for edit ID, or every note in this buffer."
  (interactive)
  (let (ids)
    (maphash (lambda (key note)
               (when (or (equal key id)
                         (and (null id)
                              (eq (overlay-buffer (plist-get note :overlay)) (current-buffer))))
                 (push key ids)))
             tandem-review--notes)
    (dolist (key ids)
      (delete-overlay (plist-get (gethash key tandem-review--notes) :overlay))
      (remhash key tandem-review--notes))))

(defun tandem-review-click-dismiss (event)
  "Remove the note whose close button EVENT clicked."
  (interactive "e")
  (let ((string (posn-string (event-start event))))
    (when-let* ((id (and string (get-text-property (cdr string) 'tandem-note (car string)))))
      (tandem-review-dismiss-note id))))

(defun tandem-review--clicked-hunk (event)
  "Return the pending hunk whose button EVENT clicked, and select its window.
The button is on an overlay string (a banner) or in a buffer (the
popup); a popup's frame belongs to another window, which it names."
  (let* ((posn (event-start event))
         (window (posn-window posn))
         (string (posn-string posn))
         (hunk (if string
                   (get-text-property (cdr string) 'tandem-hunk (car string))
                 (and (windowp window) (posn-point posn)
                      (get-text-property (posn-point posn) 'tandem-hunk (window-buffer window))))))
    (unless (and hunk (eq (tandem-review--hunk-state hunk) 'pending))
      (user-error "That hunk is no longer waiting"))
    (let ((home (or (and (windowp window)
                         (window-parameter window 'tandem-popup-for))
                    window)))
      (when (window-live-p home)
        (select-frame-set-input-focus (window-frame home))
        (select-window home)))
    hunk))

(defun tandem-review-click-apply (event)
  "Apply the hunk whose button EVENT clicked."
  (interactive "e")
  (tandem-review-apply-this-hunk (tandem-review--clicked-hunk event)))

(defun tandem-review-click-reject (event)
  "Reject the hunk whose button EVENT clicked, asking why."
  (interactive "e")
  (tandem-review-reject-this-hunk (tandem-review--clicked-hunk event)))

(defun tandem-review-reject-hunk (&optional all reason)
  "Reject the hunk at point, asking for REASON, an optional note for Claude.
With prefix argument ALL, reject every waiting hunk of its edit."
  (interactive "P")
  (let* ((hunk (or (tandem-review--hunk-at-point)
                   (user-error "Point is not on a hunk Claude proposed")))
         (proposal (tandem-review--proposal (tandem-review--hunk-id hunk)))
         (reason (or reason
                     (read-string (if all
                                      "Tell Claude why, or what to do instead (optional): "
                                    "Tell Claude why you reject this hunk (optional): ")))))
    (if all
        (tandem-review-reject (plist-get proposal :id) reason)
      (tandem-review-reject-this-hunk hunk reason))))

(defun tandem-review--after-decision (proposal)
  "Move to PROPOSAL's next waiting hunk, or tell Claude the outcome."
  (if-let* ((next (car (tandem-review--pending proposal))))
      (progn (when (eq (current-buffer) (plist-get proposal :buffer))
               (goto-char (overlay-start (tandem-review--hunk-banner next))))
             (message "tandem: %d more hunk%s of this edit to decide"
                      (length (tandem-review--pending proposal))
                      (if (cdr (tandem-review--pending proposal)) "s" "")))
    (tandem-review--maybe-finish proposal)))

(defun tandem-review--hunks-here ()
  "Return the waiting hunks in this buffer, in buffer order."
  (sort (seq-mapcat #'tandem-review--pending
                    (tandem-review--in-buffer (current-buffer)))
        (lambda (a b) (< (overlay-start (tandem-review--hunk-banner a))
                         (overlay-start (tandem-review--hunk-banner b))))))

(defun tandem-review-next-hunk ()
  "Move to the next hunk Claude proposed in this buffer."
  (interactive)
  (let ((here (or (tandem-review--hunk-at-point) (point))))
    (if-let* ((next (seq-find (lambda (h)
                                (> (overlay-start (tandem-review--hunk-banner h))
                                   (if (integerp here) here
                                     (overlay-start (tandem-review--hunk-banner here)))))
                              (tandem-review--hunks-here))))
        (goto-char (overlay-start (tandem-review--hunk-banner next)))
      (user-error "No later hunk"))))

(defun tandem-review-previous-hunk ()
  "Move to the previous hunk Claude proposed in this buffer."
  (interactive)
  (let ((here (or (tandem-review--hunk-at-point) (point))))
    (if-let* ((previous (seq-find (lambda (h)
                                    (< (overlay-start (tandem-review--hunk-banner h))
                                       (if (integerp here) here
                                         (overlay-start (tandem-review--hunk-banner here)))))
                                  (reverse (tandem-review--hunks-here)))))
        (goto-char (overlay-start (tandem-review--hunk-banner previous)))
      (user-error "No earlier hunk"))))

(defun tandem-review-show (&optional id)
  "Show the first waiting hunk of Claude's edit ID, or of the newest edit."
  (interactive)
  (let* ((proposal (tandem-review--proposal (or id (tandem-review--at-point))))
         (hunk (car (tandem-review--pending proposal))))
    (pop-to-buffer (plist-get proposal :buffer))
    (goto-char (overlay-start (tandem-review--hunk-banner hunk)))))

(defun tandem-review--withdraw (params)
  "Remove the proposal PARAMS names; Claude no longer wants an answer."
  (when-let* ((proposal (gethash (plist-get params :requestId) tandem-review--proposals)))
    (tandem-review--clear proposal)
    (message "tandem: Claude withdrew its edit to %s: %s"
             (file-name-nondirectory (plist-get proposal :path))
             (plist-get params :reason))))

(defun tandem-review--on-kill ()
  "Reject the waiting hunks of a buffer that is being killed."
  (dolist (proposal (tandem-review--in-buffer (current-buffer)))
    (dolist (hunk (tandem-review--pending proposal))
      (tandem-review--settle hunk 'rejected "The user closed the buffer."))
    (tandem-review--maybe-finish proposal)))

(defun tandem-review--on-disconnect ()
  "Remove every proposal: with the daemon gone, none can be answered."
  (let (proposals)
    (maphash (lambda (_id p) (push p proposals)) tandem-review--proposals)
    (mapc #'tandem-review--clear proposals)))

(add-hook 'tandem-rpc-disconnect-hook #'tandem-review--on-disconnect)

(provide 'tandem-review)
;;; tandem-review.el ends here
