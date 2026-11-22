;;; tandem-diff.el --- Line diffs for tandem  -*- lexical-binding: t; -*-

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

;; Which lines changed between two versions of a text: Myers' O(ND)
;; algorithm on vectors of lines.  The review splits Claude's edits into
;; hunks with it; the colours of Claude's lines find their lines again
;; with it when a file is opened.

;;; Code:

(defvar tandem-diff-limit 400
  "Most line edits the diff looks for before calling the rest one change.")

(defun tandem-diff (a b)
  "Return how line vector A becomes line vector B, as changed ranges.
Each range is (OI OJ NI NJ): A's lines OI to OJ-1 become B's lines NI
to NJ-1.  Lines outside the ranges are equal, in the same order."
  (let* ((n (length a)) (m (length b)) (p 0) (s 0))
    (while (and (< p n) (< p m) (equal (aref a p) (aref b p)))
      (setq p (1+ p)))
    (while (and (< s (- n p)) (< s (- m p))
                (equal (aref a (- n 1 s)) (aref b (- m 1 s))))
      (setq s (1+ s)))
    (tandem-diff--myers a p (- n s) b p (- m s))))

(defun tandem-diff--myers (a ao an b bo bm)
  "Return the changed ranges between two spans of lines.
The spans are the lines of vector A from AO up to AN, and of vector B
from BO up to BM, the ends excluded.  This is Myers' O(ND) algorithm;
past `tandem-diff-limit' edits the whole span is one range."
  (let ((n (- an ao)) (m (- bm bo)))
    (cond
     ((and (zerop n) (zerop m)) nil)
     ((or (zerop n) (zerop m)) (list (list ao an bo bm)))
     (t
      (let* ((limit (min (+ n m) tandem-diff-limit))
             (off (1+ limit))
             (v (make-vector (+ (* 2 limit) 3) 0))
             (trace nil)
             (found nil)
             (d 0))
        (while (and (not found) (<= d limit))
          (push (copy-sequence v) trace)
          (let ((k (- d)))
            (while (and (not found) (<= k d))
              (let* ((x (if (or (= k (- d))
                                (and (/= k d) (< (aref v (+ off k -1)) (aref v (+ off k 1)))))
                            (aref v (+ off k 1))
                          (1+ (aref v (+ off k -1)))))
                     (y (- x k)))
                (while (and (< x n) (< y m) (equal (aref a (+ ao x)) (aref b (+ bo y))))
                  (setq x (1+ x) y (1+ y)))
                (aset v (+ off k) x)
                (when (and (>= x n) (>= y m))
                  (setq found t)))
              (setq k (+ k 2))))
          (unless found (setq d (1+ d))))
        (if (not found)
            (list (list ao an bo bm))
          ;; Walk back through the snapshots, collecting the equal pairs.
          (let ((x n) (y m) (pairs nil))
            (dolist (snapshot trace)
              (let* ((k (- x y))
                     (prev-k (if (or (= k (- d))
                                     (and (/= k d) (< (aref snapshot (+ off k -1))
                                                      (aref snapshot (+ off k 1)))))
                                 (1+ k)
                               (1- k)))
                     (prev-x (aref snapshot (+ off prev-k)))
                     (prev-y (- prev-x prev-k)))
                (while (and (> x prev-x) (> y prev-y))
                  (setq x (1- x) y (1- y))
                  (push (cons x y) pairs))
                (setq x prev-x y prev-y d (1- d))))
            ;; The gaps between equal pairs are the changes.
            (let ((i 0) (j 0) (ranges nil))
              (dolist (pair pairs)
                (when (or (> (car pair) i) (> (cdr pair) j))
                  (push (list (+ ao i) (+ ao (car pair)) (+ bo j) (+ bo (cdr pair))) ranges))
                (setq i (1+ (car pair)) j (1+ (cdr pair))))
              (when (or (< i n) (< j m))
                (push (list (+ ao i) an (+ bo j) bm) ranges))
              (nreverse ranges)))))))))

(provide 'tandem-diff)
;;; tandem-diff.el ends here
