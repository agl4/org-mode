;;; org-colview.el --- Column View in Org            -*- lexical-binding: t; -*-

;; Copyright (C) 2004-2025 Free Software Foundation, Inc.

;; Author: Carsten Dominik <carsten.dominik@gmail.com>
;; Keywords: outlines, hypermedia, calendar, text
;; URL: https://orgmode.org
;;
;; This file is part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; This file contains the column view for Org.

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'cl-lib)
(require 'org)

(declare-function org-agenda-redo "org-agenda" (&optional all))
(declare-function org-agenda-do-context-action "org-agenda" ())
(declare-function org-clock-sum-today "org-clock" (&optional headline-filter))
(declare-function org-element-extract "org-element-ast" (node))
(declare-function org-element-interpret-data "org-element" (data))
(declare-function org-element-map "org-element" (data types fun &optional info first-match no-recursion with-affiliated))
(declare-function org-element-parse-secondary-string "org-element" (string restriction &optional parent))
(declare-function org-element-property "org-element-ast" (property node))
(declare-function org-element-restriction "org-element" (element))
(declare-function org-element-type-p "org-element-ast" (node types))
(declare-function org-dynamic-block-define "org" (type func))
(declare-function org-link-display-format "ol" (s))
(declare-function org-link-open-from-string "ol" (s &optional arg))
(declare-function face-remap-remove-relative "face-remap" (cookie))
(declare-function face-remap-add-relative "face-remap" (face &rest specs))

(defvar org-agenda-columns-add-appointments-to-effort-sum)
(defvar org-agenda-columns-compute-summary-properties)
(defvar org-agenda-columns-show-summaries)
(defvar org-agenda-view-columns-initially)
(defvar org-inlinetask-min-level)


;;; Configuration

(defcustom org-columns-checkbox-allowed-values '("[ ]" "[X]")
  "Allowed values for columns with SUMMARY-TYPE that uses checkbox.
The affected summary types are \"X%\", \"X/\", and \"X\" (see info
node `(org)Column attributes')."
  :group 'org-properties
  :package-version '(Org . "9.6")
  :type '(repeat (choice
                  (const :tag "Unchecked [ ]" "[ ]")
                  (const :tag "Checked [X]" "[X]")
                  (const :tag "No checkbox" "")
                  (const :tag "Intermediate state [-]" "[-]")
                  (string :tag "Arbitrary string"))))

(defcustom org-columns-modify-value-for-display-function nil
  "Function that modifies values for display in column view.
For example, it can be used to cut out a certain part from a time stamp.
The function must take 2 arguments:

column-title    The title of the column (*not* the property name)
value           The value that should be modified.

The function should return the value that should be displayed,
or nil if the normal value should be used."
  :group 'org-properties
  :type '(choice (const nil) (function)))

(defcustom org-columns-summary-types nil
  "Alist between operators and summarize functions.

Each association follows the pattern (LABEL . SUMMARIZE),
or (LABEL SUMMARIZE COLLECT) where

  LABEL is a string used in #+COLUMNS definition describing the
  summary type.  It can contain any character but \"}\".  It is
  case-sensitive.

  SUMMARIZE is a function called with two arguments.  The first
  argument is a non-empty list of values, as non-empty strings.
  The second one is a format string or nil.  It has to return
  a string summarizing the list of values.

  COLLECT is a function called with one argument, a property
  name.  It is called in the context of a headline and must
  return the collected property, or the empty string.  You can
  use this to only collect a property if a related conditional
  properties is set, e.g., to return VACATION_DAYS only if
  CONFIRMED is true.

Note that the return value can become one value for an higher
order summary, so the function is expected to handle its own
output.

Types defined in this variable take precedence over those defined
in `org-columns-summary-types-default', which see."
  :group 'org-properties
  :version "26.1"
  :package-version '(Org . "9.0")
  :type '(alist :key-type (string :tag "       Label")
		:value-type
		(choice (function :tag "Summarize")
			(list :tag "Collect and summarize"
			      (function :tag "Summarize")
			      (function :tag "Collect")))))

(defcustom org-columns-dblock-formatter #'org-columns-dblock-write-default
  "Function to format data in column view dynamic blocks.
For more information, see `org-columns-dblock-write-default'."
  :group 'org-properties
  :package-version '(Org . "9.7")
  :type 'function)


;;; Column View

(defvar-local org-columns-overlays nil
  "Holds the list of current column overlays.")
(put 'org-columns-overlays 'permanent-local t)

(defvar-local org-columns-global nil
  "Local variable, holds non-nil when current columns are global.")

(defvar-local org-columns-current-fmt nil
  "Local variable, holds the currently active column format.")

(defvar-local org-columns-current-fmt-compiled nil
  "Local variable, holds the currently active column format.
This is the compiled version of the format.")

(defvar-local org-columns-current-maxwidths nil
  "Currently active maximum column widths, as a vector.")

(defvar-local org-columns-begin-marker nil
  "Points to the position where last a column creation command was called.")

(defvar-local org-columns-top-level-marker nil
  "Points to the position where current columns region starts.")

(defvar org-columns--time 0.0
  "Number of seconds since the epoch, as a floating point number.")

(defvar org-columns-map (make-sparse-keymap)
  "The keymap valid in column display.")

(defconst org-columns-summary-types-default
  '(("+"     . org-columns--summary-sum)
    ("$"     . org-columns--summary-currencies)
    ("X"     . org-columns--summary-checkbox)
    ("X/"    . org-columns--summary-checkbox-count)
    ("X%"    . org-columns--summary-checkbox-percent)
    ("max"   . org-columns--summary-max)
    ("mean"  . org-columns--summary-mean)
    ("min"   . org-columns--summary-min)
    (":"     . org-columns--summary-sum-times)
    (":max"  . org-columns--summary-max-time)
    (":mean" . org-columns--summary-mean-time)
    (":min"  . org-columns--summary-min-time)
    ("@max"  . org-columns--summary-max-age)
    ("@mean" . org-columns--summary-mean-age)
    ("@min"  . org-columns--summary-min-age)
    ("est+"  . org-columns--summary-estimate))
  "Map operators to summarize functions.
See `org-columns-summary-types' for details.")

(defun org-columns-content ()
  "Switch to contents view while in columns view."
  (interactive)
  (org-cycle-overview)
  (org-cycle-content))

(org-defkey org-columns-map "c"        #'org-columns-content)
(org-defkey org-columns-map "o"        #'org-overview)
(org-defkey org-columns-map "e"        #'org-columns-edit-value)
(org-defkey org-columns-map "\C-c\C-t" #'org-columns-todo)
(org-defkey org-columns-map "\C-c\C-c" #'org-columns-toggle-or-columns-quit)
(org-defkey org-columns-map "\C-c\C-o" #'org-columns-open-link)
(org-defkey org-columns-map "v"        #'org-columns-show-value)
(org-defkey org-columns-map "q"        #'org-columns-quit)
(org-defkey org-columns-map "r"        #'org-columns-redo)
(org-defkey org-columns-map "g"        #'org-columns-redo)
(org-defkey org-columns-map [left]     #'backward-char)
(org-defkey org-columns-map "\M-b"     #'backward-char)
(org-defkey org-columns-map "a"        #'org-columns-edit-allowed)
(org-defkey org-columns-map "s"        #'org-columns-edit-attributes)
(org-defkey org-columns-map "\M-f"     #'forward-char)
(org-defkey org-columns-map [right]    #'forward-char)
(org-defkey org-columns-map [up]       #'org-columns-move-up)
(org-defkey org-columns-map [down]     #'org-columns-move-down)
(org-defkey org-columns-map [(shift right)] #'org-columns-next-allowed-value)
(org-defkey org-columns-map "n" #'org-columns-next-allowed-value)
(org-defkey org-columns-map [(shift left)] #'org-columns-previous-allowed-value)
(org-defkey org-columns-map "p" #'org-columns-previous-allowed-value)
(org-defkey org-columns-map "<" #'org-columns-narrow)
(org-defkey org-columns-map ">" #'org-columns-widen)
(org-defkey org-columns-map [(meta right)] #'org-columns-move-right)
(org-defkey org-columns-map [(meta left)]  #'org-columns-move-left)
(org-defkey org-columns-map [(meta down)]  #'org-columns-move-row-down)
(org-defkey org-columns-map [(meta up)]  #'org-columns-move-row-up)
(org-defkey org-columns-map [(shift meta right)] #'org-columns-new)
(org-defkey org-columns-map [(shift meta left)]  #'org-columns-delete)
(dotimes (i 10)
  (org-defkey org-columns-map (number-to-string i)
	      (lambda () (interactive)
		(org-columns-next-allowed-value nil i))))

(easy-menu-define org-columns-menu org-columns-map "Org Column Menu."
  '("Column"
    ["Edit property" org-columns-edit-value t]
    ["Next allowed value" org-columns-next-allowed-value t]
    ["Previous allowed value" org-columns-previous-allowed-value t]
    ["Show full value" org-columns-show-value t]
    ["Edit allowed values" org-columns-edit-allowed t]
    "--"
    ["Edit column attributes" org-columns-edit-attributes t]
    ["Increase column width" org-columns-widen t]
    ["Decrease column width" org-columns-narrow t]
    "--"
    ["Move column right" org-columns-move-right t]
    ["Move column left" org-columns-move-left t]
    ["Move row up" org-columns-move-row-up t]
    ["Move row down" org-columns-move-row-down t]
    ["Add column" org-columns-new t]
    ["Delete column" org-columns-delete t]
    "--"
    ["CONTENTS" org-columns-content t]
    ["OVERVIEW" org-overview t]
    ["Refresh columns display" org-columns-redo t]
    "--"
    ["Open link" org-columns-open-link t]
    "--"
    ["Quit" org-columns-quit t]))

(defun org-columns--displayed-value (spec value &optional no-star)
  "Return displayed value for specification SPEC in current entry.

SPEC is a column format specification as stored in
`org-columns-current-fmt-compiled'.  VALUE is the real value to
display, as a string.

When NO-STAR is non-nil, do not add asterisks before displayed
value for ITEM property."
  (or (and (functionp org-columns-modify-value-for-display-function)
	   (funcall org-columns-modify-value-for-display-function
		    (nth 1 spec)	;column name
		    value))
      (pcase spec
	(`("ITEM" . ,_)
	 (let ((stars
		(and (not no-star)
		     (concat (make-string (1- (org-current-level))
					  (if org-hide-leading-stars ?\s ?*))
			     "* "))))
	   (concat stars (org-link-display-format value))))
	(`(,(or "DEADLINE" "SCHEDULED" "TIMESTAMP") . ,_)
	 (replace-regexp-in-string org-ts-regexp "[\\1]" value))
	(`(,_ ,_ ,_ ,_ nil) value)
	;; If PRINTF is set, assume we are displaying a number and
	;; obey to the format string.
	(`(,_ ,_ ,_ ,_ ,printf) (format printf (string-to-number value)))
	(_ (error "Invalid column specification format: %S" spec)))))

(defun org-columns--collect-values (&optional compiled-fmt agenda-marker)
  "Collect values for columns on the current line.

Return a list of triplets (SPEC VALUE DISPLAYED) suitable for
`org-columns--display-here'.

This function assumes `org-columns-current-fmt-compiled' is
initialized is set in the current buffer.  However, it is
possible to override it with optional argument COMPILED-FMT.

The optional argument AGENDA-MARKER is used when called from the
agenda to pass a marker to the agenda line.
"
  (let ((summaries (get-text-property (point) 'org-summaries)))
    (mapcar
     (lambda (spec)
       (pcase spec
	 (`(,p . ,_)
	  (let* ((v (or (cdr (assoc spec summaries))
			(org-entry-get (point) p 'selective t)
			(and compiled-fmt ;assume `org-agenda-columns'
			     ;; Effort property is not defined.  Try
			     ;; to use appointment duration.
			     org-agenda-columns-add-appointments-to-effort-sum
                             agenda-marker
			     (string= p (upcase org-effort-property))
			     (get-text-property
                              (marker-position agenda-marker)
                              'duration
                              (marker-buffer agenda-marker))
			     (propertize
                              (org-duration-from-minutes
                               (get-text-property
                                (marker-position agenda-marker)
                                'duration
                                (marker-buffer agenda-marker)))
			      'face 'org-warning))
			"")))
	    ;; A non-nil COMPILED-FMT means we're calling from Org
	    ;; Agenda mode, where we do not want leading stars for
	    ;; ITEM.  Hence the optional argument for
	    ;; `org-columns--displayed-value'.
	    (list spec v (org-columns--displayed-value spec v compiled-fmt))))))
     (or compiled-fmt org-columns-current-fmt-compiled))))

(defun org-columns--set-widths (cache)
  "Compute the maximum column widths from the format and CACHE.
This function sets `org-columns-current-maxwidths' as a vector of
integers greater than 0."
  (setq org-columns-current-maxwidths
	(apply #'vector
	       (mapcar
		(lambda (spec)
		  (pcase spec
		    (`(,_ ,_ ,(and width (pred wholenump)) . ,_) width)
		    (`(,_ ,name . ,_)
		     ;; No width is specified in the columns format.
		     ;; Compute it by checking all possible values for
		     ;; PROPERTY.
		     (let ((width (length name)))
		       (dolist (entry cache width)
			 (let ((value (nth 2 (assoc spec (cdr entry)))))
			   (setq width (max (length value) width))))))))
		org-columns-current-fmt-compiled))))

(defun org-columns--new-overlay (beg end &optional string face)
  "Create a new column overlay and add it to the list."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'face (or face 'secondary-selection))
    (org-overlay-display ov string face)
    (push ov org-columns-overlays)
    ov))

(defun org-columns--summarize (operator)
  "Return summary function associated to string OPERATOR."
  (pcase (or (assoc operator org-columns-summary-types)
	     (assoc operator org-columns-summary-types-default))
    (`nil (error "Unknown %S operator" operator))
    (`(,_ . ,(and (pred functionp) summarize)) summarize)
    (`(,_ ,summarize ,_) summarize)
    (_ (error "Invalid definition for operator %S" operator))))

(defun org-columns--collect (operator)
  "Return collect function associated to string OPERATOR.
Return nil if no collect function is associated to OPERATOR."
  (pcase (or (assoc operator org-columns-summary-types)
	     (assoc operator org-columns-summary-types-default))
    (`nil (error "Unknown %S operator" operator))
    (`(,_ . ,(pred functionp)) nil)	;default value
    (`(,_ ,_ ,collect) collect)
    (_ (error "Invalid definition for operator %S" operator))))

(defun org-columns--overlay-text (value fmt width property original)
  "Return decorated VALUE string for columns overlay display.
FMT is a format string.  WIDTH is the width of the column, as an
integer.  PROPERTY is the property being displayed, as a string.
ORIGINAL is the real string, i.e., before it is modified by
`org-columns--displayed-value'."
  (format fmt
          (let ((v (org-columns-add-ellipses value width)))
            (pcase property
              ("PRIORITY"
               (propertize v 'face (org-get-priority-face original)))
              ("TAGS"
               (if (not org-tags-special-faces-re)
                   (propertize v 'face 'org-tag)
                 (replace-regexp-in-string
                  org-tags-special-faces-re
                  (lambda (m) (propertize m 'face (org-get-tag-face m)))
                  v nil nil 1)))
              ("TODO" (propertize v 'face (org-get-todo-face original)))
              (_ v)))))

(defvar org-columns-header-line-remap nil
  "Store the relative remapping of column header-line.
This is needed to later remove this relative remapping.")

(defvar org-columns--read-only-string nil)
(defun org-columns--display-here (columns &optional dateline)
  "Overlay the current line with column display.
COLUMNS is an alist (SPEC VALUE DISPLAYED).  Optional argument
DATELINE is non-nil when the face used should be
`org-agenda-column-dateline'."
  (when (and (not org-columns-header-line-remap)
             (or (fboundp 'face-remap-add-relative)
                 (ignore-errors (require 'face-remap))))
    (setq org-columns-header-line-remap
	  (face-remap-add-relative 'header-line '(:inherit default))))
  (save-excursion
    (forward-line 0)
    (let* ((level-face (and (looking-at "\\(\\**\\)\\(\\* \\)")
			    (org-get-level-face 2)))
	   (ref-face (or level-face
			 (and (eq major-mode 'org-agenda-mode)
			      (org-get-at-bol 'face))
			 'default))
	   (color (list :foreground (face-attribute ref-face :foreground)))
	   (font (list :family (face-attribute 'default :family)))
	   (face (list color font 'org-column ref-face))
	   (face1 (list color font 'org-agenda-column-dateline ref-face)))
      ;; Each column is an overlay on top of a character.  So there has
      ;; to be at least as many characters available on the line as
      ;; columns to display.
      (let ((columns (length org-columns-current-fmt-compiled))
	    (chars (- (line-end-position) (line-beginning-position))))
	(when (> columns chars)
	  (save-excursion
	    (end-of-line)
	    (let ((inhibit-read-only t))
	      (insert (make-string (- columns chars) ?\s))))))
      ;; Display columns.  Create and install the overlay for the
      ;; current column on the next character.
      (let ((i 0)
	    (last (1- (length columns))))
	(dolist (column columns)
	  (pcase column
	    (`(,spec ,original ,value)
	     (let* ((property (car spec))
		    (width (aref org-columns-current-maxwidths i))
		    (fmt (format (if (= i last) "%%-%d.%ds |"
				   "%%-%d.%ds | ")
				 width width))
		    (ov (org-columns--new-overlay
			 (point) (1+ (point))
			 (org-columns--overlay-text
			  value fmt width property original)
			 (if dateline face1 face))))
	       (overlay-put ov 'keymap org-columns-map)
	       (overlay-put ov 'org-columns-key property)
	       (overlay-put ov 'org-columns-value original)
	       (overlay-put ov 'org-columns-value-modified value)
	       (overlay-put ov 'org-columns-format fmt)
	       (overlay-put ov 'line-prefix "")
	       (overlay-put ov 'wrap-prefix "")
	       (forward-char))))
	  (cl-incf i)))
      ;; Make the rest of the line disappear.
      (let ((ov (org-columns--new-overlay (point) (line-end-position))))
	(overlay-put ov 'invisible t)
	(overlay-put ov 'keymap org-columns-map)
	(overlay-put ov 'line-prefix "")
	(overlay-put ov 'wrap-prefix ""))
      (let ((ov (make-overlay (1- (line-end-position))
			      (line-beginning-position 2))))
	(overlay-put ov 'keymap org-columns-map)
	(push ov org-columns-overlays))
      (with-silent-modifications
	(let ((inhibit-read-only t))
	  (put-text-property
	   (line-end-position 0)
	   (line-beginning-position 2)
	   'read-only
           (or org-columns--read-only-string
	       (setq org-columns--read-only-string
                     (substitute-command-keys
	              "Type \\<org-columns-map>`\\[org-columns-edit-value]' \
to edit property")))))))))

(defun org-columns--truncate-below-width (string width)
  "Return a substring of STRING no wider than WIDTH.
This substring must start at 0, and must be the longest possible
substring whose `string-width' does not exceed WIDTH."
  (declare (side-effect-free t))
  (let ((end (min width (length string))) res)
    (while (and end (>= end 0))
      (let* ((curr (string-width (substring string 0 end)))
             (excess (- curr width)))
        (if (> excess 0)
            (cl-decf end (max 1 (/ excess 2)))
          (setq res (substring string 0 end) end nil))))
    res))

(defun org-columns-add-ellipses (string width)
  "Truncate STRING with WIDTH characters, with ellipses."
  (cond
   ((<= (string-width string) width) string)
   ((<= width (string-width org-columns-ellipses))
    (org-columns--truncate-below-width org-columns-ellipses width))
   (t (concat
       (org-columns--truncate-below-width
        string (- width (string-width org-columns-ellipses)))
       org-columns-ellipses))))

(defvar org-columns-full-header-line-format nil
  "The full header line format, will be shifted by horizontal scrolling." )
(defvar org-previous-header-line-format nil
  "The header line format before column view was turned on.")
(defvar org-columns-inhibit-recalculation nil
  "Inhibit recomputing of columns on column view startup.")
(defvar org-columns-flyspell-was-active nil
  "Remember the state of `flyspell-mode' before column view.
Flyspell-mode can cause problems in columns view, so it is turned off
for the duration of the command.")

(defvar header-line-format)
(defvar org-columns-previous-hscroll 0)

(defun org-columns--display-here-title ()
  "Overlay the newline before the current line with the table title."
  (interactive)
  (let ((title "")
	(linum-offset (org-line-number-display-width 'columns))
	(i 0))
    (dolist (column org-columns-current-fmt-compiled)
      (pcase column
	(`(,property ,name . ,_)
	 (let* ((width (aref org-columns-current-maxwidths i))
		(fmt (format "%%-%d.%ds | " width width)))
	   (setq title (concat title (format fmt (or name property)))))))
      (cl-incf i))
    (setq-local org-previous-header-line-format header-line-format)
    (setq org-columns-full-header-line-format
	  (concat
	   (org-add-props " " nil 'display `(space :align-to ,linum-offset))
	   (org-add-props (substring title 0 -1) nil 'face 'org-column-title)))
    (setq org-columns-previous-hscroll -1)
    (add-hook 'post-command-hook #'org-columns-hscroll-title nil 'local)))

(defun org-columns-hscroll-title ()
  "Set the `header-line-format' so that it scrolls along with the table."
  (sit-for .0001) ; need to force a redisplay to update window-hscroll
  (let ((hscroll (window-hscroll)))
    (when (/= org-columns-previous-hscroll hscroll)
      (setq header-line-format
	    (concat (substring org-columns-full-header-line-format 0 1)
		    (substring org-columns-full-header-line-format
			       (min (length org-columns-full-header-line-format)
				    (1+ hscroll))))
	    org-columns-previous-hscroll hscroll)
      (force-mode-line-update))))

(defvar org-colview-initial-truncate-line-value nil
  "Remember the value of `truncate-lines' across colview.")

;;;###autoload
(defun org-columns-remove-overlays ()
  "Remove all currently active column overlays."
  (interactive)
  (when org-columns-header-line-remap
    (face-remap-remove-relative org-columns-header-line-remap)
    (setq org-columns-header-line-remap nil))
  (when org-columns-overlays
    (when (local-variable-p 'org-previous-header-line-format)
      (setq header-line-format org-previous-header-line-format)
      (kill-local-variable 'org-previous-header-line-format)
      (remove-hook 'post-command-hook #'org-columns-hscroll-title 'local))
    (when (markerp org-columns-begin-marker)
      (set-marker org-columns-begin-marker nil))
    (when (markerp org-columns-top-level-marker)
      (set-marker org-columns-top-level-marker nil))
    (with-silent-modifications
      (mapc #'delete-overlay org-columns-overlays)
      (setq org-columns-overlays nil)
      (let ((inhibit-read-only t))
	(remove-text-properties (point-min) (point-max) '(read-only t))))
    (when org-columns-flyspell-was-active
      (flyspell-mode 1))
    (when (local-variable-p 'org-colview-initial-truncate-line-value)
      (setq truncate-lines org-colview-initial-truncate-line-value))))

(defun org-columns-show-value ()
  "Show the full value of the property."
  (interactive)
  (let ((value (get-char-property (point) 'org-columns-value)))
    (message "Value is: %s" (or value ""))))

(defvar org-agenda-columns-active) ;; defined in org-agenda.el

(defun org-columns-quit ()
  "Remove the column overlays and in this way exit column editing."
  (interactive)
  (with-silent-modifications
    (org-columns-remove-overlays)
    (let ((inhibit-read-only t))
      (remove-text-properties (point-min) (point-max) '(read-only t))))
  (if (not (eq major-mode 'org-agenda-mode))
      (setq org-columns-current-fmt nil)
    (setq org-agenda-columns-active nil)
    (message
     "Modification not yet reflected in Agenda buffer, use `r' to refresh")))

(defun org-columns-check-computed ()
  "Throw an error if current column value is computed."
  (let ((spec (nth (org-current-text-column) org-columns-current-fmt-compiled)))
    (and
     (nth 3 spec)
     (assoc spec (get-text-property (line-beginning-position) 'org-summaries))
     (error "This value is computed from the entry's children"))))

(defun org-columns-todo (&optional _arg)
  "Change the TODO state during column view."
  (interactive "P")
  (org-columns-edit-value "TODO"))

(defun org-columns-toggle-or-columns-quit ()
  "Toggle checkbox at point, or quit column view."
  (interactive)
  (or (org-columns--toggle)
      (org-columns-quit)))

(defun org-columns--toggle ()
  "Toggle checkbox at point.  Return non-nil if toggle happened, else nil.
See info documentation about realizing a suitable checkbox."
  (when (string-match "\\`\\[[ xX-]\\]\\'"
		      (get-char-property (point) 'org-columns-value))
    (org-columns-next-allowed-value)
    t))

(defvar org-overriding-columns-format nil
  "When set, overrides any other format definition for the agenda.
Don't set this, this is meant for dynamic scoping.  Set
`org-columns-default-format' and `org-columns-default-format-for-agenda'
instead.  You should use this variable only in the local settings
section for a custom agenda view.")

(defvar-local org-local-columns-format nil
  "When set, overrides any other format definition for the agenda.
This can be set as a buffer local value to avoid interfering with
dynamic scoping for `org-overriding-columns-format'.")

(defun org-columns-edit-value (&optional key)
  "Edit the value of the property at point in column view.
Where possible, use the standard interface for changing this line."
  (interactive)
  (org-columns-check-computed)
  (let* ((col (current-column))
	 (bol (line-beginning-position))
	 (eol (line-end-position))
	 (pom (or (get-text-property bol 'org-hd-marker) (point)))
	 (key (or key (get-char-property (point) 'org-columns-key)))
	 (org-columns--time (float-time))
	 (action
	  (pcase key
	    ("CLOCKSUM"
	     (user-error "This special column cannot be edited"))
	    ("ITEM"
	     (lambda () (org-with-point-at pom (org-edit-headline))))
	    ("TODO"
	     (lambda ()
	       (org-with-point-at pom (call-interactively #'org-todo))))
	    ("PRIORITY"
	     (lambda ()
	       (org-with-point-at pom
		 (call-interactively #'org-priority))))
	    ("TAGS"
	     (lambda ()
	       (org-with-point-at pom
		 (let ((org-fast-tag-selection-single-key
			(if (eq org-fast-tag-selection-single-key 'expert)
			    t
			  org-fast-tag-selection-single-key)))
		   (call-interactively #'org-set-tags-command)))))
	    ("DEADLINE"
	     (lambda ()
	       (org-with-point-at pom (call-interactively #'org-deadline))))
	    ("SCHEDULED"
	     (lambda ()
	       (org-with-point-at pom (call-interactively #'org-schedule))))
	    ("BEAMER_ENV"
	     (lambda ()
	       (org-with-point-at pom
		 (call-interactively #'org-beamer-select-environment))))
	    (_
	     (let* ((allowed (org-property-get-allowed-values pom key 'table))
		    (value (get-char-property (point) 'org-columns-value))
		    (nval (org-trim
			   (if (null allowed) (read-string "Edit: " value)
			     (completing-read
			      "Value: " allowed nil
			      (not (get-text-property
				    0 'org-unrestricted (caar allowed))))))))
	       (and (not (equal nval value))
		    (lambda () (org-entry-put pom key nval))))))))
    (cond
     ((null action))
     ((eq major-mode 'org-agenda-mode)
      (org-columns--call action)
      ;; The following let preserves the current format, and makes
      ;; sure that in only a single file things need to be updated.
      (let* ((org-overriding-columns-format org-columns-current-fmt)
	     (buffer (marker-buffer pom))
	     (org-agenda-contributing-files
	      (list (with-current-buffer buffer
		      (buffer-file-name (buffer-base-buffer))))))
	(org-agenda-columns)))
     (t
      (let ((inhibit-read-only t))
	(with-silent-modifications
	  (remove-text-properties (max (point-min) (1- bol)) eol '(read-only t)))
	(org-columns--call action))
      ;; Some properties can modify headline (e.g., "TODO"), and
      ;; possible shuffle overlays.  Make sure they are still all at
      ;; the right place on the current line.
      (let ((org-columns-inhibit-recalculation)) (org-columns-redo))
      (org-columns-update key)
      (org-move-to-column col)))))

(defun org-columns-edit-allowed ()
  "Edit the list of allowed values for the current property."
  (interactive)
  (let* ((pom (or (org-get-at-bol 'org-marker)
		  (org-get-at-bol 'org-hd-marker)
		  (point)))
	 (key (concat (or (get-char-property (point) 'org-columns-key)
			  (user-error "No column to edit at point"))
		      "_ALL"))
	 (allowed (org-entry-get pom key t))
	 (new-value (read-string "Allowed: " allowed)))
    ;; FIXME: Cover editing TODO, TAGS etc in-buffer settings.????
    ;; FIXME: Write back to #+PROPERTY setting if that is needed.
    (org-entry-put
     (cond ((marker-position org-entry-property-inherited-from)
	    org-entry-property-inherited-from)
	   ((marker-position org-columns-top-level-marker)
	    org-columns-top-level-marker)
	   (t pom))
     key new-value)))

(defun org-columns--call (fun)
  "Call function FUN while preserving heading visibility.
FUN is a function called with no argument."
  (let ((hide-body (and (/= (line-end-position) (point-max))
			(save-excursion
			  (move-beginning-of-line 2)
			  (org-at-heading-p)))))
    (unwind-protect (funcall fun)
      (when hide-body (org-fold-hide-entry)))))

(defun org-columns-previous-allowed-value ()
  "Switch to the previous allowed value for this column."
  (interactive)
  (org-columns-next-allowed-value t))

(defun org-columns-next-allowed-value (&optional previous nth)
  "Switch to the next allowed value for this column.
When PREVIOUS is set, go to the previous value.  When NTH is
an integer, select that value."
  (interactive)
  (org-columns-check-computed)
  (let* ((column (org-current-text-column))
         (visible-column (current-column))
	 (key (get-char-property (point) 'org-columns-key))
	 (value (get-char-property (point) 'org-columns-value))
	 (pom (or (get-text-property (line-beginning-position) 'org-hd-marker)
		  (point)))
	 (allowed
	  (let ((all
		 (or (org-property-get-allowed-values pom key)
		     (pcase (nth column org-columns-current-fmt-compiled)
		       (`(,_ ,_ ,_ ,(or "X" "X/" "X%") ,_) org-columns-checkbox-allowed-values))
		     (org-colview-construct-allowed-dates value))))
	    (if previous (reverse all) all))))
    (when (equal key "ITEM") (error "Cannot edit item headline from here"))
    (unless (or allowed (member key '("SCHEDULED" "DEADLINE" "CLOCKSUM")))
      (error "Allowed values for this property have not been defined"))
    (let* ((l (length allowed))
	   (new
	    (cond
	     ((member key '("SCHEDULED" "DEADLINE" "CLOCKSUM"))
	      (if previous 'earlier 'later))
	     ((integerp nth)
	      (when (> (abs nth) l)
		(user-error "Only %d allowed values for property `%s'" l key))
	      (nth (mod (1- nth) l) allowed))
	     ((member value allowed)
	      (when (= l 1) (error "Only one allowed value for this property"))
	      (or (nth 1 (member value allowed)) (car allowed)))
	     (t (car allowed))))
	   (action (lambda () (org-entry-put pom key new))))
      (cond
       ((eq major-mode 'org-agenda-mode)
	(org-columns--call action)
	;; The following let preserves the current format, and makes
	;; sure that in only a single file things need to be updated.
	(let* ((org-overriding-columns-format org-columns-current-fmt)
	       (buffer (marker-buffer pom))
	       (org-agenda-contributing-files
		(list (with-current-buffer buffer
			(buffer-file-name (buffer-base-buffer))))))
	  (org-agenda-columns)))
       (t
	(let ((inhibit-read-only t))
	  (remove-text-properties (line-end-position 0) (line-end-position)
				  '(read-only t))
	  (org-columns--call action))
	;; Some properties can modify headline (e.g., "TODO"), and
	;; possible shuffle overlays.  Make sure they are still all at
	;; the right place on the current line.
	(let ((org-columns-inhibit-recalculation)) (org-columns-redo))
	(org-columns-update key)
	(org-move-to-column visible-column))))))

(defun org-colview-construct-allowed-dates (s)
  "Construct a list of three dates around the date in S.
This respects the format of the time stamp in S, active or non-active,
and also including time or not.  S must be just a time stamp, no text
around it."
  (when (and s (string-match (concat "^" org-ts-regexp3 "$") s))
    (let* ((time (org-parse-time-string s 'nodefaults))
	   (active (equal (string-to-char s) ?<))
	   (fmt (org-time-stamp-format (nth 1 time) (not active)))
	   time-before time-after)
      (setf (car time) (or (car time) 0))
      (setf (nth 1 time) (or (nth 1 time) 0))
      (setf (nth 2 time) (or (nth 2 time) 0))
      (setq time-before (copy-sequence time))
      (setq time-after (copy-sequence time))
      (setf (nth 3 time-before) (1- (nth 3 time)))
      (setf (nth 3 time-after) (1+ (nth 3 time)))
      (mapcar (lambda (x) (format-time-string fmt (org-encode-time x)))
	      (list time-before time time-after)))))

(defun org-columns-open-link (&optional arg)
  (interactive "P")
  (let ((value (get-char-property (point) 'org-columns-value)))
    (org-link-open-from-string value arg)))

;;;###autoload
(defun org-columns-get-format-and-top-level ()
  (let ((fmt (org-columns-get-format)))
    (org-columns-goto-top-level)
    fmt))

(defun org-columns-get-format (&optional fmt-string)
  "Return columns format specifications.
When optional argument FMT-STRING is non-nil, use it as the
current specifications.  This function also sets
`org-columns-current-fmt-compiled' and
`org-columns-current-fmt'."
  (interactive)
  (let ((format
	 (or fmt-string
	     (org-entry-get nil "COLUMNS" t)
	     (org-with-wide-buffer
	      (goto-char (point-min))
	      (catch :found
		(let ((case-fold-search t))
		  (while (re-search-forward "^[ \t]*#\\+COLUMNS: .+$" nil t)
		    (let ((element (org-element-at-point)))
		      (when (org-element-type-p element 'keyword)
			(throw :found (org-element-property :value element)))))
		  nil)))
	     org-columns-default-format)))
    (setq org-columns-current-fmt format)
    (org-columns-compile-format format)
    format))

(defun org-columns-goto-top-level ()
  "Move to the beginning of the column view area.
Also sets `org-columns-top-level-marker' to the new position."
  (unless (markerp org-columns-top-level-marker)
    (setq org-columns-top-level-marker (make-marker)))
  (goto-char
   (move-marker
    org-columns-top-level-marker
    (cond ((org-before-first-heading-p) (point-min))
	  ((org-entry-get nil "COLUMNS" t) org-entry-property-inherited-from)
	  (t (org-back-to-heading) (point))))))

;;;###autoload
(defun org-columns (&optional global columns-fmt-string)
  "Turn on column view on an Org mode file.

Column view applies to the whole buffer if point is before the first
headline.  Otherwise, it applies to the first ancestor setting
\"COLUMNS\" property.  If there is none, it defaults to the current
headline.  With a `\\[universal-argument]' prefix \ argument, GLOBAL,
turn on column view for the whole buffer unconditionally.

When COLUMNS-FMT-STRING is non-nil, use it as the column format."
  (interactive "P")
  (org-columns-remove-overlays)
  (setq-local org-columns-global global)
  (save-excursion
    (when global (goto-char (point-min)))
    (if (markerp org-columns-begin-marker)
	(move-marker org-columns-begin-marker (point))
      (setq org-columns-begin-marker (point-marker)))
    (org-columns-goto-top-level)
    ;; Initialize `org-columns-current-fmt' and
    ;; `org-columns-current-fmt-compiled'.
    (let ((org-columns--time (float-time)))
      (org-columns-get-format columns-fmt-string)
      (unless org-columns-inhibit-recalculation (org-columns-compute-all))
      (save-restriction
	(when (and (not global) (org-at-heading-p))
	  (narrow-to-region (point) (org-end-of-subtree t t)))
	(when (assoc "CLOCKSUM" org-columns-current-fmt-compiled)
	  (org-clock-sum))
	(when (assoc "CLOCKSUM_T" org-columns-current-fmt-compiled)
	  (org-clock-sum-today))
	(let ((cache
	       ;; Collect contents of columns ahead of time so as to
	       ;; compute their maximum width.
               (org-scan-tags
		(lambda () (cons (point-marker) (org-columns--collect-values))) t org--matcher-tags-todo-only)))
	  (when cache
	    (org-columns--set-widths cache)
	    (org-columns--display-here-title)
	    (when (setq-local org-columns-flyspell-was-active
			      (bound-and-true-p flyspell-mode))
	      (flyspell-mode 0))
	    (unless (local-variable-p 'org-colview-initial-truncate-line-value)
	      (setq-local org-colview-initial-truncate-line-value
			  truncate-lines))
            (if (not global-visual-line-mode)
                (setq truncate-lines t))
	    (dolist (entry cache)
	      (goto-char (car entry))
	      (org-columns--display-here (cdr entry)))))))))

(defun org-columns-new (&optional spec &rest attributes)
  "Insert a new column, to the left of the current column.
Interactively fill attributes for new column.  When column format
specification SPEC is provided, edit it instead.

When optional argument attributes can be a list of columns
specifications attributes to create the new column
non-interactively.  See `org-columns-compile-format' for
details."
  (interactive)
  (let ((new (or attributes
		 (let ((prop
			(completing-read
			 "Property: "
			 (mapcar #'list (org-buffer-property-keys t nil t))
			 nil nil (nth 0 spec))))
		   (list prop
                         ;; Discard useless whitespace-only titles.
			 (org-string-nw-p
                          (read-string (format "Column title [%s]: " prop)
				       (nth 1 spec)))
			 ;; Use `read-string' instead of `read-number'
			 ;; to allow empty width.
			 (let ((w (read-string
				   "Column width: "
				   (and (nth 2 spec)
					(number-to-string (nth 2 spec))))))
			   (and (org-string-nw-p w) (string-to-number w)))
			 (org-string-nw-p
			  (completing-read
			   "Summary: "
			   (delete-dups
			    (cons '("")	;Allow empty operator.
				  (mapcar (lambda (x) (list (car x)))
					  (append
					   org-columns-summary-types
					   org-columns-summary-types-default))))
			   nil t (nth 3 spec)))
			 (org-string-nw-p
			  (read-string "Format: " (nth 4 spec))))))))
    (if spec
	(progn (setcar spec (car new))
	       (setcdr spec (cdr new)))
      (push new (nthcdr (org-current-text-column) org-columns-current-fmt-compiled)))
    (org-columns-store-format)
    (org-columns-redo)))

(defun org-columns-delete ()
  "Delete the column at point from columns view."
  (interactive)
  (let ((spec (nth (org-current-text-column) org-columns-current-fmt-compiled)))
    (when (y-or-n-p (format "Are you sure you want to remove column %S? "
			    (nth 1 spec)))
      (setq org-columns-current-fmt-compiled
	    (delq spec org-columns-current-fmt-compiled))
      (org-columns-store-format)
      ;; This may leave a now wrong value in a node property.  However
      ;; updating it may prove counter-intuitive.  See comments in
      ;; `org-columns-move-right' for details.
      (let ((org-columns-inhibit-recalculation t)) (org-columns-redo))
      (when (>= (org-current-text-column) (length org-columns-current-fmt-compiled))
	(backward-char)))))

(defun org-columns-edit-attributes ()
  "Edit the attributes of the current column."
  (interactive)
  (org-columns-new (nth (org-current-text-column) org-columns-current-fmt-compiled)))

(defun org-columns-widen (arg)
  "Make the column wider by ARG characters."
  (interactive "p")
  (let* ((n (org-current-text-column))
	 (entry (nth n org-columns-current-fmt-compiled))
	 (width (aref org-columns-current-maxwidths n)))
    (setq width (max 1 (+ width arg)))
    (setcar (nthcdr 2 entry) width)
    (org-columns-store-format)
    (let ((org-columns-inhibit-recalculation t)) (org-columns-redo))))

(defun org-columns-narrow (arg)
  "Make the column narrower by ARG characters."
  (interactive "p")
  (org-columns-widen (- arg)))

(defun org-columns-move-up ()
  "In column view, move cursor up one row.
When in agenda column view, also call `org-agenda-do-context-action'."
  (interactive)
  (let ((col (current-column)))
    (forward-line -1)
    (while (and (org-invisible-p2) (not (bobp)))
      (forward-line -1))
    (move-to-column col)
    (if (eq major-mode 'org-agenda-mode)
	(org-agenda-do-context-action))))

(defun org-columns-move-down ()
  "In column view, move cursor down one row.
When in agenda column view, also call `org-agenda-do-context-action'."
  (interactive)
  (let ((col (current-column)))
    (forward-line 1)
    (while (and (org-invisible-p2) (not (eobp)))
      (forward-line 1))
    (move-to-column col)
    (if (derived-mode-p 'org-agenda-mode)
	(org-agenda-do-context-action))))

(defun org-columns-move-right ()
  "Swap this column with the one to the right."
  (interactive)
  (let* ((n (org-current-text-column))
	 (cell (nthcdr n org-columns-current-fmt-compiled))
	 e)
    (when (>= n (1- (length org-columns-current-fmt-compiled)))
      (error "Cannot shift this column further to the right"))
    (setq e (car cell))
    (setcar cell (car (cdr cell)))
    (setcdr cell (cons e (cdr (cdr cell))))
    (org-columns-store-format)
    ;; Do not compute again properties, since we're just moving
    ;; columns around.  It can put a property value a bit off when
    ;; switching between an non-computed and a computed value for the
    ;; same property, e.g. from "%A %A{+}" to "%A{+} %A".
    ;;
    ;; In this case, the value needs to be updated since the first
    ;; column related to a property determines how its value is
    ;; computed.  However, (correctly) updating the value could be
    ;; surprising, so we leave it as-is nonetheless.
    (let ((org-columns-inhibit-recalculation t)) (org-columns-redo))
    (forward-char 1)))

(defun org-columns-move-left ()
  "Swap this column with the one to the left."
  (interactive)
  (let* ((n (org-current-text-column)))
    (when (= n 0)
      (error "Cannot shift this column further to the left"))
    (backward-char 1)
    (org-columns-move-right)
    (backward-char 1)))

(defun org-columns--move-row (&optional up)
  "Move the current table row down.
With non-nil optional argument UP, move it up."
  (let ((inhibit-read-only t)
        (col (current-column)))
    (if up (org-move-subtree-up)
      (org-move-subtree-down))
    (let ((org-columns-inhibit-recalculation t))
      (org-columns-redo)
      (move-to-column col))))

(defun org-columns-move-row-down ()
  "Move the current table row down."
  (interactive)
  (org-columns--move-row))

(defun org-columns-move-row-up ()
  "Move the current table row up."
  (interactive)
  (org-columns--move-row 'up))

(defun org-columns-store-format ()
  "Store the text version of the current columns format.
The format is stored either in the COLUMNS property of the node
starting the current column display, or in a #+COLUMNS line of
the current buffer."
  (let ((fmt (org-columns-uncompile-format org-columns-current-fmt-compiled)))
    (setq-local org-columns-current-fmt fmt)
    (when org-columns-overlays
      (org-with-point-at org-columns-top-level-marker
	(if (and (org-at-heading-p) (org-entry-get nil "COLUMNS"))
	    (org-entry-put nil "COLUMNS" fmt)
	  (goto-char (point-min))
	  (let ((case-fold-search t))
	    ;; Try to replace the first COLUMNS keyword available.
	    (catch :found
	      (while (re-search-forward "^[ \t]*#\\+COLUMNS:\\(.*\\)" nil t)
		(let ((element (save-match-data (org-element-at-point))))
		  (when (and (org-element-type-p element 'keyword)
			     (equal (org-element-property :key element)
				    "COLUMNS"))
		    (replace-match (concat " " fmt) t t nil 1)
		    (throw :found nil))))
	      ;; No COLUMNS keyword in the buffer.  Insert one at the
	      ;; beginning, right before the first heading, if any.
	      (goto-char (point-min))
	      (unless (org-at-heading-p) (outline-next-heading))
	      (let ((inhibit-read-only t))
		(insert-before-markers "#+COLUMNS: " fmt "\n"))))
	  (setq-local org-columns-default-format fmt))))))

(defun org-columns-update (property)
  "Recompute PROPERTY, and update the columns display for it."
  (org-columns-compute property)
  (org-with-wide-buffer
   (let ((p (upcase property)))
     (dolist (ov org-columns-overlays)
       (let ((key (overlay-get ov 'org-columns-key)))
	 (when (and key (equal key p) (overlay-start ov))
	   (goto-char (overlay-start ov))
	   (let* ((spec (nth (org-current-text-column) org-columns-current-fmt-compiled))
		  (value
		   (or (cdr (assoc spec
				   (get-text-property (line-beginning-position)
						      'org-summaries)))
		       (org-entry-get (point) key))))
	     (when value
	       (let ((displayed (org-columns--displayed-value spec value))
		     (format (overlay-get ov 'org-columns-format))
		     (width
		      (aref org-columns-current-maxwidths (org-current-text-column))))
		 (overlay-put ov 'org-columns-value value)
		 (overlay-put ov 'org-columns-value-modified displayed)
		 (overlay-put ov
			      'display
			      (org-columns--overlay-text
			       displayed format width property value)))))))))))

(defun org-columns-redo ()
  "Construct the column display again."
  (interactive)
  (when org-columns-overlays
    (message "Recomputing columns...")
    (org-with-point-at org-columns-begin-marker
      (org-columns-remove-overlays)
      (if (derived-mode-p 'org-mode)
	  ;; Since we already know the columns format, provide it
	  ;; instead of computing again.
	  (funcall-interactively #'org-columns org-columns-global org-columns-current-fmt)
	(org-agenda-redo)
	(call-interactively #'org-agenda-columns)))
    (message "Recomputing columns...done")))

(defun org-columns-uncompile-format (compiled)
  "Turn the compiled columns format back into a string representation.

COMPILED is an alist, as returned by `org-columns-compile-format'."
  (mapconcat
   (lambda (spec)
     (pcase spec
       (`(,prop ,title ,width ,op ,printf)
	(concat "%"
		(and width (number-to-string width))
		prop
		(and title (not (equal prop title)) (format "(%s)" title))
		(cond ((not op) nil)
		      (printf (format "{%s;%s}" op printf))
		      (t (format "{%s}" op)))))))
   compiled " "))

(defun org-columns-compile-format (fmt)
  "Turn a column format string FMT into an alist of specifications.

The alist has one entry for each column in the format.  The elements of
that list are:
property    the property name, as an upper-case string
title       the title field for the columns, as a string
width       the column width in characters, can be nil for automatic width
operator    the summary operator, as a string, or nil
printf      a printf format for computed values, as a string, or nil

This function updates `org-columns-current-fmt-compiled'."
  (setq org-columns-current-fmt-compiled nil)
  (let ((start 0))
    (while (string-match
            (rx "%"
                (optional (group (+ digit)))
                (group (one-or-more (in alnum "_-")))
                (optional "(" (group (zero-or-more (not (any ")")))) ")")
                (optional "{" (group (zero-or-more (not (any "}")))) "}")
                (zero-or-more space))
            fmt start)
      (setq start (match-end 0))
      (let* ((width (and (match-end 1) (string-to-number (match-string 1 fmt))))
	     (prop (match-string-no-properties 2 fmt))
	     (title (or (org-string-nw-p (match-string-no-properties 3 fmt)) prop))
	     (operator (org-string-nw-p (match-string-no-properties 4 fmt))))
	(push (if (not operator) (list (upcase prop) title width nil nil)
		(let (printf)
		  (when (string-match ";" operator)
		    (setq printf (substring operator (match-end 0)))
		    (setq operator (substring operator 0 (match-beginning 0))))
		  (list (upcase prop) title width operator printf)))
	      org-columns-current-fmt-compiled)))
    (setq org-columns-current-fmt-compiled
	  (nreverse org-columns-current-fmt-compiled))))


;;;; Column View Summary

(defun org-columns--age-to-minutes (s)
  "Turn age string S into a number of minutes.
An age is either computed from a given timestamp, or indicated
as a canonical duration, i.e., using units defined in
`org-duration-canonical-units'."
  (cond
   ((string-match-p org-ts-regexp s)
    (/ (- org-columns--time
	  (float-time (org-time-string-to-time s)))
       60))
   ((org-duration-p s) (org-duration-to-minutes s t)) ;skip user units
   (t (user-error "Invalid age: %S" s))))

(defun org-columns--format-age (minutes)
  "Format MINUTES float as an age string."
  (org-duration-from-minutes minutes
			     '(("d" . nil) ("h" . nil) ("min" . nil))
			     t))	;ignore user's custom units

(defun org-columns--summary-apply-times (fun times)
  "Apply FUN to time values TIMES.
Return the result as a duration."
  (org-duration-from-minutes
   (apply fun (mapcar #'org-duration-to-minutes times))
   (org-duration-h:mm-only-p times)))

(defun org-columns--compute-spec (spec &optional update)
  "Update tree according to SPEC.
SPEC is a column format specification.  When optional argument
UPDATE is non-nil, summarized values can replace existing ones in
properties drawers."
  (let* ((lmax (if (bound-and-true-p org-inlinetask-max-level)
		   org-inlinetask-max-level
		 29))			;Hard-code deepest level.
	 (lvals (make-vector (1+ lmax) nil))
	 (level 0)
	 (inminlevel lmax)
	 (last-level lmax)
	 (property (car spec))
	 (printf (nth 4 spec))
         ;; Special properties cannot be collected nor summarized, as
         ;; they have their own way to be computed.  Therefore, ignore
         ;; any operator attached to them.
	 (operator (and (not (member property org-special-properties))
                        (nth 3 spec)))
	 (collect (and operator (org-columns--collect operator)))
	 (summarize (and operator (org-columns--summarize operator))))
    (org-with-wide-buffer
     ;; Find the region to compute.
     (goto-char org-columns-top-level-marker)
     (goto-char (condition-case nil (org-end-of-subtree t) (error (point-max))))
     ;; Walk the tree from the back and do the computations.
     (while (re-search-backward
	     org-outline-regexp-bol org-columns-top-level-marker t)
       (unless (or (= level 0) (eq level inminlevel))
	 (setq last-level level))
       (setq level (org-reduced-level (org-outline-level)))
       (let* ((pos (match-beginning 0))
              (value (if collect (funcall collect property)
		       (org-entry-get (point) property)))
	      (value-set (org-string-nw-p value)))
	 (cond
	  ((< level last-level)
	   ;; Collect values from lower levels and inline tasks here
	   ;; and summarize them using SUMMARIZE.  Store them in text
	   ;; property `org-summaries', in alist whose key is SPEC.
	   (let* ((summary
		   (and summarize
			(let ((values
                               (cl-loop for l from (1+ level) to lmax
                                        append (aref lvals l))))
			  (and values (funcall summarize values printf))))))
	     ;; Leaf values are not summaries: do not mark them.
	     (when summary
	       (let* ((summaries-alist (get-text-property pos 'org-summaries))
		      (old (assoc spec summaries-alist)))
		 (if old (setcdr old summary)
		   (push (cons spec summary) summaries-alist)
		   (with-silent-modifications
		     (add-text-properties
		      pos (1+ pos) (list 'org-summaries summaries-alist)))))
	       ;; When PROPERTY exists in current node, even if empty,
	       ;; but its value doesn't match the one computed, use
	       ;; the latter instead.
	       ;;
	       ;; Ignore leading or trailing white spaces that might
	       ;; have been introduced in summary, since those are not
	       ;; significant in properties value.
	       (let ((new-value (org-trim summary)))
		 (when (and update value (not (equal value new-value)))
		   (org-entry-put (point) property new-value))))
	     ;; Add current to current level accumulator.
	     (when (or summary value-set)
	       (push (or summary value) (aref lvals level)))
	     ;; Clear accumulators for deeper levels.
	     (cl-loop for l from (1+ level) to lmax do (aset lvals l nil))))
	  (value-set (push value (aref lvals level)))
	  (t nil)))))))

;;;###autoload
(defun org-columns-compute (property)
  "Summarize the values of PROPERTY hierarchically.
Also update existing values for PROPERTY according to the first
column specification."
  (interactive)
  (let ((main-flag t)
	(upcase-prop (upcase property)))
    (dolist (spec org-columns-current-fmt-compiled)
      (pcase spec
	(`(,(pred (equal upcase-prop)) . ,_)
	 (org-columns--compute-spec spec main-flag)
	 ;; Only the first summary can update the property value.
	 (when main-flag (setq main-flag nil)))))))

(defun org-columns-compute-all ()
  "Compute all columns that have operators defined."
  (with-silent-modifications
    (remove-text-properties (point-min) (point-max) '(org-summaries t)))
  (let ((org-columns--time (float-time))
	seen)
    (dolist (spec org-columns-current-fmt-compiled)
      (let ((property (car spec)))
	;; Property value is updated only the first time a given
	;; property is encountered.
	(org-columns--compute-spec spec (not (member property seen)))
	(push property seen)))))

(defun org-columns--summary-sum (values printf)
  "Compute the sum of VALUES.
When PRINTF is non-nil, use it to format the result."
  (format (or printf "%s") (apply #'+ (mapcar #'string-to-number values))))

(defun org-columns--summary-currencies (values _)
  "Compute the sum of VALUES, with two decimals."
  (format "%.2f" (apply #'+ (mapcar #'string-to-number values))))

(defun org-columns--summary-checkbox (check-boxes _)
  "Summarize CHECK-BOXES with a check-box."
  (let ((done (cl-count "[X]" check-boxes :test #'equal))
	(all (length check-boxes)))
    (cond ((= done all) "[X]")
	  ((> done 0) "[-]")
	  (t "[ ]"))))

(defun org-columns--summary-checkbox-count (check-boxes _)
  "Summarize CHECK-BOXES with a check-box cookie."
  (format "[%d/%d]"
	  (cl-count-if (lambda (b) (or (equal b "[X]")
				       (string-match-p "\\[\\([1-9]\\)/\\1\\]" b)))
		       check-boxes)
	  (length check-boxes)))

(defun org-columns--summary-checkbox-percent (check-boxes _)
  "Summarize CHECK-BOXES with a check-box percent."
  (format "[%d%%]"
	  (round (* 100.0 (cl-count-if (lambda (b) (member b '("[X]" "[100%]")))
				       check-boxes))
		 (length check-boxes))))

(defun org-columns--summary-min (values printf)
  "Compute the minimum of VALUES.
When PRINTF is non-nil, use it to format the result."
  (format (or printf "%s")
	  (apply #'min (mapcar #'string-to-number values))))

(defun org-columns--summary-max (values printf)
  "Compute the maximum of VALUES.
When PRINTF is non-nil, use it to format the result."
  (format (or printf "%s")
	  (apply #'max (mapcar #'string-to-number values))))

(defun org-columns--summary-mean (values printf)
  "Compute the mean of VALUES.
When PRINTF is non-nil, use it to format the result."
  (format (or printf "%s")
	  (/ (apply #'+ (mapcar #'string-to-number values))
	     (float (length values)))))

(defun org-columns--summary-sum-times (times _)
  "Sum TIMES."
  (org-columns--summary-apply-times #'+ times))

(defun org-columns--summary-min-time (times _)
  "Compute the minimum time among TIMES."
  (org-columns--summary-apply-times #'min times))

(defun org-columns--summary-max-time (times _)
  "Compute the maximum time among TIMES."
  (org-columns--summary-apply-times #'max times))

(defun org-columns--summary-mean-time (times _)
  "Compute the mean time among TIMES."
  (org-columns--summary-apply-times
   (lambda (&rest values) (/ (apply #'+ values) (float (length values))))
   times))

(defun org-columns--summary-min-age (ages _)
  "Compute the minimum age among AGES."
  (org-columns--format-age
   (apply #'min (mapcar #'org-columns--age-to-minutes ages))))

(defun org-columns--summary-max-age (ages _)
  "Compute the maximum age among AGES."
  (org-columns--format-age
   (apply #'max (mapcar #'org-columns--age-to-minutes ages))))

(defun org-columns--summary-mean-age (ages _)
  "Compute the mean age among AGES."
  (org-columns--format-age
   (/ (apply #'+ (mapcar #'org-columns--age-to-minutes ages))
      (float (length ages)))))

(defun org-columns--summary-estimate (estimates _)
  "Combine a list of estimates, using mean and variance.
The mean and variance of the result will be the sum of the means
and variances (respectively) of the individual estimates."
  (let ((mean 0)
        (var 0))
    (dolist (e estimates)
      (pcase (mapcar #'string-to-number (split-string e "-"))
	(`(,low ,high)
	 (let ((m (/ (+ low high) 2.0)))
	   (cl-incf mean m)
	   (cl-incf var (- (/ (+ (* low low) (* high high)) 2.0) (* m m)))))
	(`(,value) (cl-incf mean value))))
    (let ((sd (sqrt var)))
      (format "%s-%s"
	      (format "%.0f" (- mean sd))
	      (format "%.0f" (+ mean sd))))))



;;; Dynamic block for Column view

(defun org-columns--capture-view (maxlevel match skip-empty exclude-tags format local)
  "Get the column view of the current buffer.

MAXLEVEL sets the level limit.  SKIP-EMPTY tells whether to skip
empty rows, an empty row being one where all the column view
specifiers but ITEM are empty.  EXCLUDE-TAGS is a list of tags
that will be excluded from the resulting view.  FORMAT is a
format string for columns, or nil.  When LOCAL is non-nil, only
capture headings in current subtree.

This function returns a list containing the title row and all other
rows.  Each row is either a list, or the symbol `hline'.  The first list
is the heading row as a list of strings with the column titles according
to FORMAT.  All subsequent lists each represent a body row as a list
whose first element is an integer indicating the outline level of the
entry, and whose remaining elements are strings with the contents for
the columns according to FORMAT."
  (org-columns (not local) format)
  (goto-char org-columns-top-level-marker)
  (let ((columns (length org-columns-current-fmt-compiled))
	(has-item (assoc "ITEM" org-columns-current-fmt-compiled))
	table)
    (org-map-entries
     (lambda ()
       (when (get-char-property (point) 'org-columns-key)
	 (let (row)
	   (dotimes (i columns)
	     (let* ((col (+ (line-beginning-position) i))
		    (p (get-char-property col 'org-columns-key)))
	       (push (get-char-property col
					(if (string= p "ITEM")
					    'org-columns-value
					  'org-columns-value-modified))
		     row)))
	   (unless (or
		    (and skip-empty
			 (let ((r (delete-dups (remove "" row))))
			   (or (null r) (and has-item (= (length r) 1)))))
		    (and exclude-tags
			 (cl-some (lambda (tag) (member tag exclude-tags))
				  (org-get-tags))))
	     (push (cons (org-reduced-level (org-current-level)) (nreverse row))
		   table)))))
     (if match
         (concat match (and maxlevel (format "+LEVEL<=%d" maxlevel)))
       (and maxlevel (format "LEVEL<=%d" maxlevel)))
     (and local 'tree)
     'archive 'comment)
    (org-columns-quit)
    ;; Add column titles and a horizontal rule in front of the table.
    (cons (mapcar #'cadr org-columns-current-fmt-compiled)
	  (cons 'hline (nreverse table)))))

(defun org-columns--clean-item (item)
  "Remove sensitive contents from string ITEM.
This includes objects that may not be duplicated within
a document, e.g., a target, or those forbidden in tables, e.g.,
an inline src-block."
  (let ((data (org-element-parse-secondary-string
	       item (org-element-restriction 'headline))))
    (org-element-map data
	'(footnote-reference inline-babel-call inline-src-block target
			     radio-target statistics-cookie)
      #'org-element-extract)
    (org-quote-vert
     (org-no-properties
      (org-element-interpret-data data)))))

;;;###autoload
(defun org-dblock-write:columnview (params)
  "Write the column view table.

PARAMS is a property list of parameters:

`:id' (mandatory)

    The ID property of the entry where the columns view should be
    built.  When the symbol `local', call locally.  When `global'
    call column view with the cursor at the beginning of the
    buffer (usually this means that the whole buffer switches to
    column view).  When \"file:path/to/file.org\", invoke column
    view at the start of that file.  Otherwise, the ID is located
    using `org-id-find'.

`:exclude-tags'

    List of tags to exclude from column view table.

`:format'

    When non-nil, specify the column view format to use.

`:hlines'

    When non-nil, insert a hline before each item.  When
    a number, insert a hline before each level inferior or equal
    to that number.

`:indent'

    When non-nil, indent each ITEM field according to its level.

`:match'

    When set to a string, use this as a tags/property match filter.

`:maxlevel'

    When set to a number, don't capture headlines below this level.

`:skip-empty-rows'

    When non-nil, skip rows where all specifiers other than ITEM
    are empty.

`:vlines'

    When non-nil, make each column a column group to enforce
    vertical lines.

`:link'

    Link the item headlines in the table to their origins.

`:formatter'

    A function to format the data and insert it into the
    buffer.  Overrides the default formatting function set in
    `org-columns-dblock-formatter'."
  (let ((table
	 (let ((id (plist-get params :id))
	       view-file view-pos)
	   (pcase id
	     (`global nil)
	     ((or `local `nil) (setq view-pos (point)))
	     ((and (let id-string (format "%s" id))
		   (guard (string-match "^file:\\(.*\\)" id-string)))
	      (setq view-file (match-string-no-properties 1 id-string))
	      (unless (file-exists-p view-file)
		(user-error "No such file: %S" id-string)))
	     ((and (let idpos (org-find-entry-with-id id)) (guard idpos))
	      (setq view-pos idpos))
	     ((let `(,filename . ,position) (org-id-find id))
	      (setq view-file filename)
	      (setq view-pos position))
	     (_ (user-error "Cannot find entry with :ID: %s" id)))
	   (with-current-buffer (if view-file (org-get-agenda-file-buffer view-file)
				  (current-buffer))
	     (org-with-wide-buffer
	      (when view-pos (goto-char view-pos))
	      (org-columns--capture-view (plist-get params :maxlevel)
					 (plist-get params :match)
					 (plist-get params :skip-empty-rows)
					 (plist-get params :exclude-tags)
					 (plist-get params :format)
					 view-pos)))))
        (formatter (or (plist-get params :formatter)
                       org-columns-dblock-formatter
                       #'org-columns-dblock-write-default)))
    (funcall formatter (point) table params)))

(defun org-columns-dblock-write-default (ipos table params)
  "Write out a columnview table at position IPOS in the current buffer.
TABLE is a table with data as produced by `org-columns--capture-view'.
PARAMS is the parameter property list obtained from the dynamic block
definition."
  (let ((link (plist-get params :link))
	(width-specs
	 (mapcar (lambda (spec) (nth 2 spec))
		 org-columns-current-fmt-compiled)))
    (when table
      ;; Prune level information from the table.  Also normalize
      ;; headings: remove stars, add indentation entities, if
      ;; required, and possibly precede some of them with a horizontal
      ;; rule.
      (let ((item-index
	     (let ((p (assoc "ITEM" org-columns-current-fmt-compiled)))
	       (and p (cl-position p
				   org-columns-current-fmt-compiled
				   :test #'equal))))
	    (hlines (plist-get params :hlines))
	    (indent (plist-get params :indent))
	    new-table)
	;; Copy header and first rule.
	(push (pop table) new-table)
	(push (pop table) new-table)
	(dolist (row table (setq table (nreverse new-table)))
	  (let ((level (car row)))
	    (when (and (not (eq (car new-table) 'hline))
		       (or (eq hlines t)
			   (and (numberp hlines) (<= level hlines))))
	      (push 'hline new-table))
	    (when item-index
	      (let* ((raw (nth item-index (cdr row)))
		     (cleaned (org-columns--clean-item raw))
		     (item (if (not link) cleaned
			     (let ((search (org-link-heading-search-string raw)))
			       (org-link-make-string
				(if (not (buffer-file-name)) search
				  (format "file:%s::%s" (buffer-file-name) search))
				cleaned)))))
		(setf (nth item-index (cdr row))
		      (if (and indent (> level 1))
			  (concat "\\_" (make-string (* 2 (1- level)) ?\s) item)
			item))))
	    (push (cdr row) new-table))))
      (when (plist-get params :vlines)
	(setq table
	      (let ((size (length org-columns-current-fmt-compiled)))
		(append (mapcar (lambda (x) (if (eq 'hline x) x (cons "" x)))
				table)
			(list (cons "/" (make-list size "<>")))))))
      (when (seq-find #'identity width-specs)
        ;; There are width specifiers in column format.  Pass them
        ;; to the resulting table, adding alignment field as the first
        ;; row.
        (push (mapcar (lambda (width) (when width (format "<%d>" width))) width-specs) table))
      ;; now insert the table into the buffer
      (goto-char ipos)
      (let ((content-lines (org-split-string (plist-get params :content) "\n"))
	    recalc)
	;; Insert affiliated keywords before the table.
	(when content-lines
	  (while (string-match-p "\\`[ \t]*#\\+" (car content-lines))
	    (insert (string-trim-left (pop content-lines)) "\n")))
	(save-excursion
	  ;; Insert table at point.
	  (insert
	   (mapconcat (lambda (row)
			(if (eq row 'hline) "|-|"
			  (format "|%s|" (mapconcat #'identity row "|"))))
		      table
		      "\n"))
	  ;; Insert TBLFM lines following table.
	  (let ((case-fold-search t))
	    (dolist (line content-lines)
	      (when (string-match-p "\\`[ \t]*#\\+TBLFM:" line)
		(insert "\n" (string-trim-left line))
		(unless recalc (setq recalc t))))))
	(when recalc (org-table-recalculate 'all t))
	(org-table-align)
        (when (seq-find #'identity width-specs)
          (org-table-shrink))))))

;;;###autoload
(defun org-columns-insert-dblock ()
  "Create a dynamic block capturing a column view table."
  (interactive)
  (let ((id (completing-read
	     "Capture columns (local, global, entry with :ID: property) [local]: "
	     (append '(("global") ("local"))
		     (mapcar #'list (org-property-values "ID"))))))
    (org-create-dblock
     (list :name "columnview"
	   :hlines 1
	   :id (cond ((string= id "global") 'global)
		     ((member id '("" "local")) 'local)
		     (id)))))
  (org-update-dblock))

;;;###autoload
(eval-after-load 'org
  '(progn
     (org-dynamic-block-define "columnview" #'org-columns-insert-dblock)))


;;; Column view in the agenda

;;;###autoload
(defun org-agenda-columns ()
  "Turn on or update column view in the agenda."
  (interactive)
  (org-columns-remove-overlays)
  (if (markerp org-columns-begin-marker)
      (move-marker org-columns-begin-marker (point))
    (setq org-columns-begin-marker (point-marker)))
  (let* ((org-columns--time (float-time))
	 (org-done-keywords org-done-keywords-for-agenda)
	 (fmt
	  (cond
	   ((bound-and-true-p org-overriding-columns-format))
	   ((bound-and-true-p org-local-columns-format))
	   ((bound-and-true-p org-columns-default-format-for-agenda))
	   ((let ((m (org-get-at-bol 'org-hd-marker)))
	      (and m
		   (or (org-entry-get m "COLUMNS" t)
		       (with-current-buffer (marker-buffer m)
			 org-columns-default-format)))))
	   ((and (local-variable-p 'org-columns-current-fmt)
		 org-columns-current-fmt))
	   ((let ((m (next-single-property-change (point-min) 'org-hd-marker)))
	      (and m
		   (let ((m (get-text-property m 'org-hd-marker)))
		     (or (org-entry-get m "COLUMNS" t)
			 (with-current-buffer (marker-buffer m)
			   org-columns-default-format))))))
	   (t org-columns-default-format)))
	 (compiled-fmt (org-columns-compile-format fmt)))
    (setq org-columns-current-fmt fmt)
    (when org-agenda-columns-compute-summary-properties
      (org-agenda-colview-compute org-columns-current-fmt-compiled))
    (save-excursion
      ;; Collect properties for each headline in current view.
      (goto-char (point-min))
      (let (cache)
	(while (not (eobp))
	  (let ((m (org-get-at-bol 'org-hd-marker)))
	    (when m
	      (push (cons (line-beginning-position)
			  ;; `org-columns-current-fmt-compiled' is
			  ;; initialized but only set locally to the
			  ;; agenda buffer.  Since current buffer is
			  ;; changing, we need to force the original
			  ;; compiled-fmt there.
                          (let ((agenda-marker (point-marker)))
			    (org-with-point-at m
			      (org-columns--collect-values compiled-fmt agenda-marker))))
		    cache)))
	  (forward-line))
	(when cache
	  (org-columns--set-widths cache)
	  (org-columns--display-here-title)
	  (when (setq-local org-columns-flyspell-was-active
			    (bound-and-true-p flyspell-mode))
	    (flyspell-mode 0))
	  (dolist (entry cache)
	    (goto-char (car entry))
	    (org-columns--display-here (cdr entry)))
	  (setq-local org-agenda-columns-active t)
	  (when org-agenda-columns-show-summaries
	    (org-agenda-colview-summarize cache)))))))

(defun org-agenda-colview-summarize (cache)
  "Summarize the summarizable columns in column view in the agenda.
This will add overlays to the date lines, to show the summary for each day."
  (let ((fmt (mapcar
	      (lambda (spec)
		(pcase spec
		  (`(,property ,title ,width . ,_)
		   (if (member property '("CLOCKSUM" "CLOCKSUM_T"))
		       (list property title width ":" nil)
		     spec))))
	      org-columns-current-fmt-compiled)))
    ;; Ensure there's at least one summation column.
    (when (cl-some (lambda (spec) (nth 3 spec)) fmt)
      (goto-char (point-max))
      (catch :complete
	(while t
	  (when (or (get-text-property (point) 'org-date-line)
		    (eq (get-text-property (point) 'face)
			'org-agenda-structure))
	    ;; OK, this is a date line that should be used.
	    (let (entries)
	      (let (rest)
		(dolist (c cache)
		  (if (> (car c) (point))
		      (push c entries)
		    (push c rest)))
		(setq cache rest))
	      ;; ENTRIES contains entries below the current one.
	      ;; CACHE is the rest.  Compute the summaries for the
	      ;; properties we want, set nil properties for the rest.
	      (when (setq entries (mapcar #'cdr entries))
		(org-columns--display-here
		 (mapcar
		  (lambda (spec)
		    (pcase spec
		      (`("ITEM" . ,_)
		       ;; Replace ITEM with current date.  Preserve
		       ;; properties for fontification.
		       (let ((date (buffer-substring
				    (line-beginning-position)
				    (line-end-position))))
			 (list spec date date)))
		      (`(,_ ,_ ,_ nil ,_) (list spec "" ""))
		      (`(,_ ,_ ,_ ,operator ,printf)
		       (let* ((summarize (org-columns--summarize operator))
			      (values
			       ;; Use real values for summary, not
			       ;; those prepared for display.
			       (delq nil
				     (mapcar
				      (lambda (e) (org-string-nw-p
					           (nth 1 (assoc spec e))))
				      entries)))
			      (final (if values
					 (funcall summarize values printf)
				       "")))
			 (unless (equal final "")
			   (put-text-property 0 (length final)
					      'face 'bold final))
			 (list spec final final)))))
		  fmt)
		 'dateline))))
	  (if (bobp) (throw :complete t) (forward-line -1)))))))

(defun org-agenda-colview-compute (fmt)
  "Compute the relevant columns in the contributing source buffers."
  (dolist (file org-agenda-contributing-files)
    (let ((b (find-buffer-visiting file)))
      (with-current-buffer (or (buffer-base-buffer b) b)
	(org-with-wide-buffer
	 (with-silent-modifications
	   (remove-text-properties (point-min) (point-max) '(org-summaries t)))
	 (goto-char (point-min))
	 (org-columns-get-format-and-top-level)
	 (dolist (spec fmt)
	   (let ((prop (car spec)))
	     (cond
	      ((equal prop "CLOCKSUM") (org-clock-sum))
	      ((equal prop "CLOCKSUM_T") (org-clock-sum-today))
	      ((and (nth 3 spec)
		    (let ((a (assoc prop org-columns-current-fmt-compiled)))
		      (equal (nth 3 a) (nth 3 spec))))
	       (org-columns-compute prop))))))))))


(provide 'org-colview)

;; Local variables:
;; generated-autoload-file: "org-loaddefs.el"
;; End:

;;; org-colview.el ends here
