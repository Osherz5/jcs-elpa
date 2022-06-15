;;; sideline.el --- Show informations on the side  -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Shen, Jen-Chieh
;; Created date 2022-06-13 22:08:26

;; Author: Shen, Jen-Chieh <jcs090218@gmail.com>
;; Description: Show informations on the side
;; Keyword: sideline
;; Version: 0.1.0
;; Package-Version: 20220615.1259
;; Package-Commit: 26d2cf81bb309bf87915262a710182349474c4ec
;; Package-Requires: ((emacs "26.1"))
;; URL: https://github.com/jcs-elpa/sideline

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Show informations on the side.
;;

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'rect)
(require 'subr-x)

(defgroup sideline nil
  "Show informations on the side."
  :prefix "sideline-"
  :group 'tool
  :link '(url-link :tag "Repository" "https://github.com/jcs-elpa/sideline"))

(defcustom sideline-backends-left nil
  "The list of active backends to display sideline on the left."
  :type 'list
  :group 'sideline)

(defcustom sideline-backends-right nil
  "The list of active backends to display sideline on the right."
  :type 'list
  :group 'sideline)

(defcustom sideline-order 'up
  "Display order."
  :type '(choice (const :tag "Search up" up)
                 (const :tag "Search down" down))
  :group 'line-reminder)

(defface sideline-default
  '((((background light)) :foreground "DarkOrange")
    (t :foreground "yellow"))
  "Face used to highlight action text."
  :group 'sideline)

(defcustom sideline-backends-skip-current-line t
  "Don't display at line."
  :type 'boolean
  :group 'sideline)

(defcustom sideline-format-left "%s   "
  "Format candidate string for left alignment."
  :type 'string
  :group 'sideline)

(defcustom sideline-format-right "   %s"
  "Format candidate string for right alignment."
  :type 'string
  :group 'sideline)

(defcustom sideline-priority 100
  "Overlays' priority."
  :type 'integer
  :group 'sideline)

(defcustom sideline-pre-render-hook nil
  "Hooks runs before rendering sidelines."
  :type 'hook
  :group 'sideline)

(defcustom sideline-post-render-hook nil
  "Hooks runs after rendering sidelines."
  :type 'hook
  :group 'sideline)

(defcustom sideline-reset-hook nil
  "Hooks runs once the sideline is reset in `post-command-hook'."
  :type 'hook
  :group 'sideline)

(defvar-local sideline--overlays nil
  "Displayed overlays.")

(defvar-local sideline--last-bound nil
  "Record of last bound; if this isn't the same, clean up overlays.")

(defvar-local sideline--occupied-lines-left nil
  "Occupied lines on the left.")

(defvar-local sideline--occupied-lines-right nil
  "Occupied lines on the right.")

;;
;; (@* "Entry" )
;;

(defun sideline--enable ()
  "Enable `sideline' in current buffer."
  (add-hook 'post-command-hook #'sideline--post-command nil t))

(defun sideline--disable ()
  "Disable `sideline' in current buffer."
  (remove-hook 'post-command-hook #'sideline--post-command t)
  (sideline--reset))

;;;###autoload
(define-minor-mode sideline-mode
  "Minor mode 'sideline-mode'."
  :lighter " Sideline"
  :group sideline
  (if sideline-mode (sideline--enable) (sideline--disable)))

(defun sideline--turn-on-sideline-mode ()
  "Turn on the 'sideline-mode'."
  (sideline-mode 1))

;;;###autoload
(define-globalized-minor-mode global-sideline-mode
  sideline-mode sideline--turn-on-sideline-mode
  :require 'sideline)

;;
;; (@* "Util" )
;;

(defun sideline--column-to-point (column)
  "Convert COLUMN to point."
  (save-excursion (move-to-column column) (point)))

(defun sideline--line-number-display-width ()
  "Safe way to get value from function `line-number-display-width'."
  (if (bound-and-true-p display-line-numbers-mode)
      (+ (or (ignore-errors (line-number-display-width)) 0) 2)
    0))

(defun sideline--margin-width ()
  "General calculation of margin width."
  (+ (if fringes-outside-margins right-margin-width 0)
     (or (and (boundp 'fringe-mode)
              (consp fringe-mode)
              (or (equal (car fringe-mode) 0)
                  (equal (cdr fringe-mode) 0))
              1)
         (and (boundp 'fringe-mode) (equal fringe-mode 0) 1)
         0)
     (let ((win-fringes (window-fringes)))
       (if (or (equal (car win-fringes) 0)
               (equal (cadr win-fringes) 0))
           2
         0))
     (if (< emacs-major-version 27)
         ;; This was necessary with emacs < 27, recent versions take
         ;; into account the display-line width with :align-to
         (sideline--line-number-display-width)
       0)
     (if (or (bound-and-true-p whitespace-mode)
             (bound-and-true-p global-whitespace-mode))
         1
       0)))

(defun sideline--window-width ()
  "Correct window width for sideline."
  (- (min (window-text-width) (window-body-width))
     (sideline--margin-width)
     (or (and (>= emacs-major-version 27)
              ;; We still need this number when calculating available space
              ;; even with emacs >= 27
              (sideline--line-number-display-width))
         0)))

(defun sideline--align (&rest lengths)
  "Align sideline string by LENGTHS from the right of the window."
  (+ (apply '+ lengths)
     (if (display-graphic-p) 1 2)))

(defun sideline--compute-height nil
  "Return a fixed size for text in sideline."
  (if (null text-scale-mode-remapping)
      '(height 1)
    ;; Readjust height when text-scale-mode is used
    (list 'height
          (/ 1 (or (plist-get (cdr text-scale-mode-remapping) :height)
                   1)))))

(defun sideline--calc-space (str-len on-left)
  "Calculate space in current line.

Argument STR-LEN is the string size.

If argument ON-LEFT is non-nil, we calculate to the left side.  Otherwise,
calculate to the right side."
  (if on-left
      (let ((column-start (window-hscroll))
            (pos-first (save-excursion (back-to-indentation) (current-column)))
            (pos-end (save-excursion (end-of-line) (current-column))))
        (cond ((< str-len (- pos-first column-start))
               (cons column-start pos-first))
              ((= pos-first pos-end)
               (cons column-start (sideline--window-width)))))
    (let* ((column-start (window-hscroll))
           (column-end (+ column-start (sideline--window-width)))
           (pos-end (save-excursion (end-of-line) (current-column))))
      (when (< str-len (- column-end pos-end))
        (cons column-end pos-end)))))

(defun sideline--find-line (str-len on-left &optional direction exceeded)
  "Find a line where the string can be inserted.

Argument STR-LEN is the length of the message, use to calculate the alignment.

If argument ON-LEFT is non-nil, it will align to the left instead of right.

See variable `sideline-order' document string for optional argument DIRECTION
for details.

Optional argument EXCEEDED is set to non-nil when we have already searched
available lines in both directions (up & down)."
  (let ((bol (window-start)) (eol (window-end))
        (occupied-lines (if on-left sideline--occupied-lines-left
                          sideline--occupied-lines-right))
        (going-up (eq direction 'up))
        (skip-first t)
        (break-it)
        (pos-ov))
    (save-excursion
      (while (not break-it)
        (if skip-first (setq skip-first nil)
          (forward-line (if going-up -1 1))
          (when (or (= (point) (point-min)) (= (point) (point-max)))
            (setq break-it t)))
        (unless (if going-up (<= bol (point)) (<= (point) eol))
          (setq break-it t))
        (when (and (not (memq (line-beginning-position) occupied-lines))
                   (not break-it))
          (when-let ((col (sideline--calc-space str-len on-left)))
            (setq pos-ov (cons (sideline--column-to-point (car col))
                               (sideline--column-to-point (cdr col))))
            (setq break-it t)
            (push (line-beginning-position) occupied-lines)))))
    (if on-left
        (setq sideline--occupied-lines-left occupied-lines)
      (setq sideline--occupied-lines-right occupied-lines))
    (or pos-ov
        (and (not exceeded)
             (sideline--find-line str-len on-left (if going-up 'down 'up) t)))))

(defun sideline--create-keymap (action candidate)
  "Create keymap for sideline ACTION.

Argument CANDIDATE is the data for users."
  (let ((map (make-sparse-keymap)))
    (define-key map [down-mouse-1]
                (lambda ()
                  (interactive)
                  (funcall action sideline--last-bound candidate)))
    map))

;;
;; (@* "Overlays" )
;;

(defun sideline--delete-ovs ()
  "Clean up all overlays."
  (mapc #'delete-overlay sideline--overlays))

(defun sideline--create-ov (candidate action face on-left)
  "Create information (CANDIDATE) overlay.

See function `sideline--render' document string for arguments ACTION, FACE, and
ON-LEFT for details."
  (when-let*
      ((len-cand (length candidate))
       (title
        (progn
          (add-face-text-property 0 len-cand face nil candidate)
          (when action
            (let ((keymap (sideline--create-keymap action candidate)))
              (add-text-properties 0 len-cand `(keymap ,keymap mouse-face highlight) candidate)))
          (if on-left (format sideline-format-left candidate)
            (format sideline-format-right candidate))))
       (len-title (length title))
       (margin (sideline--margin-width))
       (str (concat
             (unless on-left
               (propertize " " 'display `((space :align-to (- right ,(sideline--align (1- len-title) margin)))
                                          (space :width 0))
                           `cursor t))
             (propertize title 'display (sideline--compute-height))))
       (len-str (length str))
       (pos-ov (sideline--find-line len-title on-left sideline-order)))
    ;; Create overlay
    (let* ((pos-start (car pos-ov)) (pos-end (cdr pos-ov))
           (empty-ln (= pos-start pos-end))
           (ov (make-overlay pos-start (if empty-ln pos-start (+ pos-start len-str))
                             nil t t)))
      (cond (on-left
             (if empty-ln
                 (overlay-put ov 'after-string str)
               (overlay-put ov 'display str)
               (overlay-put ov 'invisible t)))
            (t (overlay-put ov 'after-string str)))
      (overlay-put ov 'window (get-buffer-window))
      (overlay-put ov 'priority sideline-priority)
      (push ov sideline--overlays))))

;;
;; (@* "Async" )
;;

(defun sideline--render (candidates action face on-left)
  "Render a list of backends (CANDIDATES).

Argument ACTION is the code action callback.

Argument FACE is optional face to render text; default face is
`sideline-default'.

Argument ON-LEFT is a flag indicates rendering alignment."
  (dolist (candidate candidates)
    (sideline--create-ov candidate action face on-left)))

;;
;; (@* "Core" )
;;

(defun sideline--call-backend (backend command)
  "Return BACKEND's result with COMMAND."
  (funcall backend command))

(defun sideline--render-backends (backends on-left)
  "Render a list of BACKENDS.

If argument ON-LEFT is non-nil, it will align to the left instead of right."
  (dolist (backend backends)
    (let ((candidates (sideline--call-backend backend 'candidates))
          (action (sideline--call-backend backend 'action))
          (face (or (sideline--call-backend backend 'face) 'sideline-default))
          (buffer (current-buffer)))  ; for async check
      (if (eq (car candidates) :async)
          (funcall (cdr candidates)
                   (lambda (cands &rest _)
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (when sideline-mode
                           (sideline--render cands action face on-left))))))
        (sideline--render candidates action face on-left)))))

(defun sideline-render ()
  "Render sideline once."
  (run-hooks 'sideline-pre-render-hook)
  (if sideline-backends-skip-current-line
      (let ((mark (list (line-beginning-position))))
        (setq sideline--occupied-lines-left mark
              sideline--occupied-lines-right mark))
    (setq sideline--occupied-lines-left nil
          sideline--occupied-lines-right nil))
  (sideline--delete-ovs)
  (sideline--render-backends sideline-backends-left t)
  (sideline--render-backends sideline-backends-right nil)
  (run-hooks 'sideline-post-render-hook))

(defun sideline--post-command ()
  "Post command."
  (let ((inhibit-field-text-motion t)
        (bound (bounds-of-thing-at-point 'symbol)))
    (when (or (null bound)
              (not (equal sideline--last-bound bound)))
      (setq sideline--last-bound bound)  ; update
      (sideline-render)
      (run-hooks 'sideline-reset-hook))))

(defun sideline--reset ()
  "Clean up for next use."
  (setq sideline--last-bound nil)
  (sideline--delete-ovs))

(provide 'sideline)
;;; sideline.el ends here
