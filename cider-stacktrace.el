;;; cider-stacktrace.el --- Stacktrace navigator -*- lexical-binding: t -*-

;; Copyright © 2014-2025 Jeff Valk, Bozhidar Batsov and CIDER contributors

;; Author: Jeff Valk <jv@jeffvalk.com>

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Stacktrace filtering and stack frame source navigation

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'easymenu)
(require 'map)
(require 'seq)
(require 'subr-x)

(require 'cider-common)
(require 'cider-client)
(require 'cider-popup)
(require 'cider-util)

;; Variables

(defgroup cider-stacktrace nil
  "Stacktrace filtering and navigation."
  :prefix "cider-stacktrace-"
  :group 'cider)

(defcustom cider-stacktrace-fill-column t
  "Fill column for error messages in stacktrace display.
If nil, messages will not be wrapped.  If truthy but non-numeric,
`fill-column' will be used."
  :type '(radio
          (integer :tag "Fill Column")
          (const :tag "None" nil)
          (const :tag "Use default fill-column" t))
  :package-version '(cider . "0.7.0"))

(defcustom cider-stacktrace-default-filters '(tooling dup)
  "Frame types to omit from initial stacktrace display."
  :type '(repeat symbol)
  :package-version '(cider . "0.6.0"))

(defcustom cider-stacktrace-navigate-to-other-window t
  "If truthy, navigating from a stack frame will use other window.
Pick nil if you prefer the same window as *cider-error*."
  :type 'boolean
  :package-version '(cider . "1.8.0"))

(defvar cider-stacktrace-detail-max 2
  "The maximum detail level for causes.")

(defvar-local cider-stacktrace-hidden-frame-count 0)
(defvar-local cider-stacktrace-filters nil)
(defvar-local cider-stacktrace-cause-visibility nil)
(defvar-local cider-stacktrace-positive-filters nil)

(defconst cider-error-buffer "*cider-error*")

(defcustom cider-stacktrace-suppressed-errors '()
  "Errors that won't make the stacktrace buffer pop over your active window.
The error types are represented as strings."
  :type '(list string)
  :package-version '(cider . "0.12.0"))

;; Faces

(defface cider-stacktrace-error-class-face
  '((t (:inherit font-lock-warning-face)))
  "Face for exception class names."
  :package-version '(cider . "0.6.0"))

(defface cider-stacktrace-error-message-face
  '((t (:inherit font-lock-doc-face)))
  "Face for exception messages."
  :package-version '(cider . "0.7.0"))

(defface cider-stacktrace-filter-active-face
  '((t (:inherit button :underline t :weight normal)))
  "Face for filter buttons representing frames currently visible."
  :package-version '(cider . "0.6.0"))

(defface cider-stacktrace-filter-inactive-face
  '((t (:inherit button :underline nil :weight normal)))
  "Face for filter buttons representing frames currently filtered out."
  :package-version '(cider . "0.6.0"))

(defface cider-stacktrace-face
  '((t (:inherit default)))
  "Face for stack frame text."
  :package-version '(cider . "0.6.0"))

(defface cider-stacktrace-ns-face
  '((t (:inherit font-lock-comment-face)))
  "Face for stack frame namespace name."
  :package-version '(cider . "0.6.0"))

(defface cider-stacktrace-fn-face
  '((t (:inherit default :weight bold)))
  "Face for stack frame function name."
  :package-version '(cider . "0.6.0"))

(defface cider-stacktrace-promoted-button-face
  '((((type graphic))
     :box (:line-width 3 :style released-button)
     :inherit error)
    (t :inverse-video t))
  "A button with this face represents a promoted (non-suppressed) error type."
  :package-version '(cider . "0.12.0"))

(defface cider-stacktrace-suppressed-button-face
  '((((type graphic))
     :box (:line-width 3 :style pressed-button)
     :inherit widget-inactive)
    (t :inverse-video t))
  "A button with this face represents a suppressed error type."
  :package-version '(cider . "0.12.0"))

;; Colors & Theme Support

(defvar cider-stacktrace-frames-background-color
  (cider-scale-background-color)
  "Background color for stacktrace frames.")

(advice-add 'enable-theme  :after #'cider--stacktrace-adapt-to-theme)
(advice-add 'disable-theme :after #'cider--stacktrace-adapt-to-theme)
(defun cider--stacktrace-adapt-to-theme (&rest _)
  "When theme is changed, update `cider-stacktrace-frames-background-color'."
  (setq cider-stacktrace-frames-background-color
        (cider-scale-background-color)))


;; Mode & key bindings

(defvar cider-stacktrace-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-p") #'cider-stacktrace-previous-cause)
    (define-key map (kbd "M-n") #'cider-stacktrace-next-cause)
    (define-key map (kbd "M-.") #'cider-stacktrace-jump)
    (define-key map "q" #'cider-popup-buffer-quit-function)
    (define-key map "j" #'cider-stacktrace-toggle-java)
    (define-key map "c" #'cider-stacktrace-toggle-clj)
    (define-key map "r" #'cider-stacktrace-toggle-repl)
    (define-key map "t" #'cider-stacktrace-toggle-tooling)
    (define-key map "d" #'cider-stacktrace-toggle-duplicates)
    (define-key map "p" #'cider-stacktrace-show-only-project)
    (define-key map "a" #'cider-stacktrace-toggle-all)
    (define-key map "1" #'cider-stacktrace-cycle-cause-1)
    (define-key map "2" #'cider-stacktrace-cycle-cause-2)
    (define-key map "3" #'cider-stacktrace-cycle-cause-3)
    (define-key map "4" #'cider-stacktrace-cycle-cause-4)
    (define-key map "5" #'cider-stacktrace-cycle-cause-5)
    (define-key map "0" #'cider-stacktrace-cycle-all-causes)
    (define-key map (kbd "TAB") #'cider-stacktrace-cycle-current-cause)
    (define-key map [backtab] #'cider-stacktrace-cycle-all-causes)
    (easy-menu-define cider-stacktrace-mode-menu map
      "Menu for CIDER's stacktrace mode"
      '("Stacktrace"
        ["Previous cause" cider-stacktrace-previous-cause]
        ["Next cause" cider-stacktrace-next-cause]
        "--"
        ["Jump to frame source" cider-stacktrace-jump]
        "--"
        ["Cycle current cause detail" cider-stacktrace-cycle-current-cause]
        ["Cycle cause #1 detail" cider-stacktrace-cycle-cause-1]
        ["Cycle cause #2 detail" cider-stacktrace-cycle-cause-2]
        ["Cycle cause #3 detail" cider-stacktrace-cycle-cause-3]
        ["Cycle cause #4 detail" cider-stacktrace-cycle-cause-4]
        ["Cycle cause #5 detail" cider-stacktrace-cycle-cause-5]
        ["Cycle all cause detail" cider-stacktrace-cycle-all-causes]
        "--"
        ["Show/hide Java frames" cider-stacktrace-toggle-java]
        ["Show/hide Clojure frames" cider-stacktrace-toggle-clj]
        ["Show/hide REPL frames" cider-stacktrace-toggle-repl]
        ["Show/hide tooling frames" cider-stacktrace-toggle-tooling]
        ["Show/hide duplicate frames" cider-stacktrace-toggle-duplicates]
        ["Toggle only project frames" cider-stacktrace-show-only-project]
        ["Show/hide all frames" cider-stacktrace-toggle-all]))
    map))

(define-derived-mode cider-stacktrace-mode special-mode "Stacktrace"
  "Major mode for filtering and navigating CIDER stacktraces.

\\{cider-stacktrace-mode-map}"
  (when cider-special-mode-truncate-lines
    (setq-local truncate-lines t))
  (setq-local sesman-system 'CIDER)
  (setq-local electric-indent-chars nil)
  (setq-local cider-stacktrace-hidden-frame-count 0)
  (setq-local cider-stacktrace-filters cider-stacktrace-default-filters)
  ;; Expand all exception causes to "detail level 1" by default, meaning they
  ;; will show the message and the data (but not the stacktrace).
  (setq-local cider-stacktrace-cause-visibility (make-vector 10 1))
  (buffer-disable-undo))


;; Stacktrace filtering

(defvar cider-stacktrace--all-negative-filters
  '(clj tooling dup java repl)
  "Filters that remove stackframes.")

(defvar cider-stacktrace--all-positive-filters
  '(project all)
  "Filters that ensure stackframes are shown.")

(defun cider-stacktrace--face-for-filter (filter neg-filters pos-filters)
  "Return whether we should mark the FILTER is active or not.

NEG-FILTERS and POS-FILTERS are lists of filters to check FILTER's type.

NEG-FILTERS dictate which frames should be hidden while POS-FILTERS can
override this and ensure that those frames are shown."
  (cond ((member filter cider-stacktrace--all-negative-filters)
         (if (member filter neg-filters)
             'cider-stacktrace-filter-active-face
           'cider-stacktrace-filter-inactive-face))
        ((member filter cider-stacktrace--all-positive-filters)
         (if (member filter pos-filters)
             'cider-stacktrace-filter-active-face
           'cider-stacktrace-filter-inactive-face))))

(defun cider-stacktrace-indicate-filters (filters pos-filters)
  "Update enabled state of filter buttons.

Find buttons with a 'filter property; if filter is a member of FILTERS, or
if filter is nil ('show all') and the argument list is non-nil, fontify the
button as disabled.  Upon finding text with a 'hidden-count property, stop
searching and update the hidden count text.  POS-FILTERS is the list of
positive filters to always include."
  (with-current-buffer cider-error-buffer
    (save-excursion
      (goto-char (point-min))
      (let ((inhibit-read-only t))
        ;; Toggle buttons
        (while (not (or (get-text-property (point) 'hidden-count) (eobp)))
          (let ((button (button-at (point))))
            (when button
              (let* ((filter (button-get button 'filter))
                     (face (cider-stacktrace--face-for-filter filter
                                                              filters
                                                              pos-filters)))
                (button-put button 'face face)))
            (goto-char (or (next-property-change (point))
                           (point-max)))))
        ;; Update hidden count
        (when (and (get-text-property (point) 'hidden-count)
                   (re-search-forward "[0-9]+" (line-end-position) t))
          (replace-match
           (number-to-string cider-stacktrace-hidden-frame-count)))))))

(defun cider-stacktrace-frame-p ()
  "Indicate if the text at point is a stack frame."
  (get-text-property (point) 'cider-stacktrace-frame))

(defun cider-stacktrace-collapsed-p ()
  "Indicate if the stackframe was collapsed."
  (get-text-property (point) 'collapsed))

(defun cider-stacktrace--should-hide-p (neg-filters pos-filters flags)
  "Decide whether a stackframe should be hidden or not.
NEG-FILTERS dictate which frames should be hidden while POS-FILTERS can
override this and ensure that those frames are shown.
Argument FLAGS are the flags set on the stackframe, ie: clj dup, etc."
  (let ((neg (seq-intersection neg-filters flags))
        (pos (seq-intersection pos-filters flags))
        (all (memq 'all pos-filters)))
    (cond (all nil) ;; if all filter is on then we should not hide
          ((and pos neg) nil) ;; if hidden and "resurrected" we should not hide
          (pos nil)
          (neg t)
          (t nil))))

(defun cider-stacktrace--apply-filters (neg-filters pos-filters)
  "Set visibility on stack frames.
Should be called by `cider-stacktrace-apply-filters' which has the logic of
how to interpret the combinations of the positive and negative filters.
For instance, the presence of the positive filter `project' requires all of
the other negative filters to be applied so that only project frames are
shown.  NEG-FILTERS are the tags that should be hidden.  POS-FILTERS are
the tags that must be shown."
  (with-current-buffer cider-error-buffer
    (save-excursion
      (goto-char (point-min))
      (let ((inhibit-read-only t)
            (hidden 0))
        (while (not (eobp))
          (when (and (cider-stacktrace-frame-p)
                     (not (cider-stacktrace-collapsed-p)))
            (let* ((flags (get-text-property (point) 'flags))
                   (hide (cider-stacktrace--should-hide-p neg-filters
                                                          pos-filters
                                                          flags)))
              (when hide (cl-incf hidden))
              (put-text-property (point) (line-beginning-position 2)
                                 'invisible hide)))
          (forward-line 1))
        (setq cider-stacktrace-hidden-frame-count hidden)))
    (cider-stacktrace-indicate-filters neg-filters pos-filters)))

(defun cider-stacktrace-apply-filters (filters)
  "Takes a single list of filters and applies them.
Update `cider-stacktrace-hidden-frame-count' and indicate
filters applied.  Currently collapsed stacktraces are ignored, and do not
contribute to the hidden count.  FILTERS is the list of filters to be
applied, positive and negative all together.  This function defines how
those choices interact and separates them into positive and negative
filters for the resulting machinery."
  (let ((neg-filters (seq-intersection filters cider-stacktrace--all-negative-filters))
        (pos-filters (seq-intersection filters cider-stacktrace--all-positive-filters)))
    ;; project and all are mutually exclusive. when both are present we check to
    ;; see the most recent one (as cons onto the list would put it) and use that
    ;; interaction.
    (cond
     ((memq 'all (memq 'project pos-filters)) ;; project is most recent
      (cider-stacktrace--apply-filters cider-stacktrace--all-negative-filters '(project)))
     ((memq 'project (memq 'all pos-filters)) ;; all is most recent
      (cider-stacktrace--apply-filters nil '(all)))
     ((memq 'all pos-filters) (cider-stacktrace--apply-filters nil '(all)))
     ((memq 'project pos-filters) (cider-stacktrace--apply-filters cider-stacktrace--all-negative-filters
                                                                   pos-filters))
     (t (cider-stacktrace--apply-filters neg-filters pos-filters)))))

(defun cider-stacktrace-apply-cause-visibility ()
  "Apply `cider-stacktrace-cause-visibility' to causes and reapply filters."
  (with-current-buffer cider-error-buffer
    (save-excursion
      (goto-char (point-min))
      (cl-flet ((next-detail (end)
                             (when-let* ((pos (next-single-property-change (point) 'detail)))
                               (when (< pos end)
                                 (goto-char pos)))))
        (let ((inhibit-read-only t))
          ;; For each cause...
          (while (cider-stacktrace-next-cause)
            (let* ((num   (get-text-property (point) 'cause))
                   (level (elt cider-stacktrace-cause-visibility num))
                   (cause-end (cadr (cider-property-bounds 'cause))))
              ;; For each detail level within the cause, set visibility.
              (while (next-detail cause-end)
                (let* ((detail (get-text-property (point) 'detail))
                       (detail-end (cadr (cider-property-bounds 'detail)))
                       (hide (if (> detail level) t nil)))
                  (add-text-properties (point) detail-end
                                       (list 'invisible hide
                                             'collapsed hide))))))))
      (cider-stacktrace-apply-filters cider-stacktrace-filters))))

;;; Internal/Middleware error suppression

(defun cider-stacktrace-some-suppressed-errors-p (error-types)
  "Return intersection of ERROR-TYPES and CIDER-STACKTRACE-SUPPRESSED-ERRORS.
I.e, Return non-nil if the seq ERROR-TYPES shares any elements with
`cider-stacktrace-suppressed-errors'.  This means that even a
'well-behaved' (ie, promoted) error type will be 'guilty by association' if
grouped with a suppressed error type."
  (seq-intersection error-types cider-stacktrace-suppressed-errors))

(defun cider-stacktrace-suppress-error (error-type)
  "Destructively add ERROR-TYPE to the `cider-stacktrace-suppressed-errors' set."
  (setq cider-stacktrace-suppressed-errors
        (cl-adjoin error-type cider-stacktrace-suppressed-errors :test 'equal)))

(defun cider-stacktrace-promote-error (error-type)
  "Destructively remove ERROR-TYPE from `cider-stacktrace-suppressed-errors'."
  (setq cider-stacktrace-suppressed-errors
        (remove error-type cider-stacktrace-suppressed-errors)))

(defun cider-stacktrace-suppressed-error-p (error-type)
  "Return non-nil if ERROR-TYPE is in `cider-stacktrace-suppressed-errors'."
  (member error-type cider-stacktrace-suppressed-errors))

;; Interactive functions

(defun cider-stacktrace-previous-cause ()
  "Move point to the previous exception cause, if one exists."
  (interactive)
  (with-current-buffer cider-error-buffer
    (when-let* ((pos (previous-single-property-change (point) 'cause)))
      (goto-char pos))))

(defun cider-stacktrace-next-cause ()
  "Move point to the next exception cause, if one exists."
  (interactive)
  (with-current-buffer cider-error-buffer
    (when-let* ((pos (next-single-property-change (point) 'cause)))
      (goto-char pos))))

(defun cider-stacktrace-cycle-cause (num &optional level)
  "Update element NUM of `cider-stacktrace-cause-visibility'.
If LEVEL is specified, it is used, otherwise its current value is incremented.
When it reaches 3, it wraps to 0."
  (let ((level (or level (1+ (elt cider-stacktrace-cause-visibility num)))))
    (aset cider-stacktrace-cause-visibility num (mod level 3))
    (cider-stacktrace-apply-cause-visibility)))

(defun cider-stacktrace-cycle-all-causes ()
  "Cycle the visibility of all exception causes."
  (interactive)
  (with-current-buffer cider-error-buffer
    (save-excursion
      ;; Find nearest cause.
      (unless (get-text-property (point) 'cause)
        (cider-stacktrace-next-cause)
        (unless (get-text-property (point) 'cause)
          (cider-stacktrace-previous-cause)))
      ;; Cycle its level, and apply that to all causes.
      (let* ((num (get-text-property (point) 'cause))
             (level (1+ (elt cider-stacktrace-cause-visibility num))))
        (setq-local cider-stacktrace-cause-visibility
                    (make-vector 10 (mod level 3)))
        (cider-stacktrace-apply-cause-visibility)))))

(defun cider-stacktrace-cycle-current-cause ()
  "Cycle the visibility of current exception at point, if any."
  (interactive)
  (with-current-buffer cider-error-buffer
    (when-let* ((num (get-text-property (point) 'cause)))
      (cider-stacktrace-cycle-cause num))))

(defun cider-stacktrace-cycle-cause-1 ()
  "Cycle the visibility of exception cause #1."
  (interactive)
  (cider-stacktrace-cycle-cause 1))

(defun cider-stacktrace-cycle-cause-2 ()
  "Cycle the visibility of exception cause #2."
  (interactive)
  (cider-stacktrace-cycle-cause 2))

(defun cider-stacktrace-cycle-cause-3 ()
  "Cycle the visibility of exception cause #3."
  (interactive)
  (cider-stacktrace-cycle-cause 3))

(defun cider-stacktrace-cycle-cause-4 ()
  "Cycle the visibility of exception cause #4."
  (interactive)
  (cider-stacktrace-cycle-cause 4))

(defun cider-stacktrace-cycle-cause-5 ()
  "Cycle the visibility of exception cause #5."
  (interactive)
  (cider-stacktrace-cycle-cause 5))

(defun cider-stacktrace-toggle (flag)
  "Update `cider-stacktrace-filters' to add or remove FLAG, and apply filters."
  (cider-stacktrace-apply-filters
   (setq cider-stacktrace-filters
         (if (memq flag cider-stacktrace-filters)
             (remq flag cider-stacktrace-filters)
           (cons flag cider-stacktrace-filters)))))

(defun cider-stacktrace-toggle-all ()
  "Toggle `all' in filter list."
  (interactive)
  (cider-stacktrace-toggle 'all))

(defun cider-stacktrace-show-only-project ()
  "Display only the stackframes from the project."
  (interactive)
  (cider-stacktrace-toggle 'project))

(defun cider-stacktrace-toggle-java ()
  "Toggle display of Java stack frames."
  (interactive)
  (cider-stacktrace-toggle 'java))

(defun cider-stacktrace-toggle-clj ()
  "Toggle display of Clojure stack frames."
  (interactive)
  (cider-stacktrace-toggle 'clj))

(defun cider-stacktrace-toggle-repl ()
  "Toggle display of REPL stack frames."
  (interactive)
  (cider-stacktrace-toggle 'repl))

(defun cider-stacktrace-toggle-tooling ()
  "Toggle display of tooling stack frames.

These include:

  * Clojure compiler and runtime internals
     * may be `.clj' or `.java' files.
  * nREPL internals
  * CIDER internals."
  (interactive)
  (cider-stacktrace-toggle 'tooling))

(defun cider-stacktrace-toggle-duplicates ()
  "Toggle display of stack frames that are duplicates of their descendents."
  (interactive)
  (cider-stacktrace-toggle 'dup))

;; Text button functions

(defun cider-stacktrace-filter (button)
  "Apply filter(s) indicated by the BUTTON."
  (with-temp-message "Filters may also be toggled with the keyboard."
    (let ((flag (button-get button 'filter)))
      (cond ((member flag cider-stacktrace--all-negative-filters)
             (cider-stacktrace-toggle flag))
            ((member flag cider-stacktrace--all-positive-filters)
             (cider-stacktrace-show-only-project))
            (t (cider-stacktrace-toggle-all))))
    (sit-for 5)))

(defun cider-stacktrace-toggle-suppression (button)
  "Toggle stacktrace pop-over/pop-under behavior for the `error-type' in BUTTON.
Achieved by destructively manipulating `cider-stacktrace-suppressed-errors'."
  (with-current-buffer cider-error-buffer
    (let ((inhibit-read-only t)
          (suppressed (button-get button 'suppressed))
          (error-type (button-get button 'error-type)))
      (if suppressed
          (progn
            (cider-stacktrace-promote-error error-type)
            (button-put button 'face 'cider-stacktrace-promoted-button-face)
            (button-put button 'help-echo "Click to suppress these stacktraces."))
        (cider-stacktrace-suppress-error error-type)
        (button-put button 'face 'cider-stacktrace-suppressed-button-face)
        (button-put button 'help-echo "Click to promote these stacktraces."))
      (button-put button 'suppressed (not suppressed)))))

(defun cider-stacktrace-navigate (button)
  "Navigate to the stack frame source represented by the BUTTON."
  (let* ((var (button-get button 'var))
         (class (button-get button 'class))
         (method (button-get button 'method))
         (info (or (and var (cider-var-info var))
                   (and class method (cider-member-info class method))
                   (nrepl-dict)))
         ;; Stacktrace returns more accurate line numbers, but if the function's
         ;; line was unreliable, then so is the stacktrace by the same amount.
         ;; Set `line-shift' to the number of lines from the beginning of defn.
         (line-shift (- (or (button-get button 'line) 0)
                        (or (nrepl-dict-get info "line") 1)))
         (file (or
                (nrepl-dict-get info "file")
                (button-get button 'file)))
         ;; give priority to `info` files as `info` returns full paths.
         (info (nrepl-dict-put info "file" file)))
    (cider--jump-to-loc-from-info info cider-stacktrace-navigate-to-other-window)
    (forward-line line-shift)
    (back-to-indentation)))

(declare-function cider-find-var "cider-find")

(defun cider-stacktrace-jump (&optional arg)
  "Find definition for stack frame at point, if available.
The prefix ARG and `cider-prompt-for-symbol' decide whether to
prompt and whether to use a new window.  Similar to `cider-find-var'."
  (interactive "P")
  (let ((button (button-at (point))))
    (if (and button (button-get button 'line))
        (cider-stacktrace-navigate button)
      (cider-find-var arg))))


;; Rendering
(defvar cider-use-tooltips)
(defun cider-stacktrace-tooltip (tooltip)
  "Return TOOLTIP if `cider-use-tooltips' is set to true, nil otherwise."
  (when cider-use-tooltips tooltip))

(defun cider-stacktrace-emit-indented (text &optional indent fill fontify)
  "Insert TEXT, and optionally FILL and FONTIFY as clojure the entire block.
INDENT is a string to insert before each line.  When INDENT is nil, first
line is not indented and INDENT defaults to a white-spaced string with
length given by `current-column'."
  (let ((text (if fontify
                  (cider-font-lock-as-clojure text)
                text))
        (do-first indent)
        (indent (or indent (make-string (current-column) ? )))
        (beg (point)))
    (insert text)
    (goto-char beg)
    (when do-first
      (insert indent))
    (forward-line)
    (while (not (eobp))
      (insert indent)
      (forward-line))
    (when (and fill cider-stacktrace-fill-column)
      (when (and (numberp cider-stacktrace-fill-column))
        (setq-local fill-column cider-stacktrace-fill-column))
      (setq-local fill-prefix indent)
      (fill-region beg (point)))))

(defun cider-stacktrace-render-filters (buffer special-filters filters)
  "Emit into BUFFER toggle buttons for each of the FILTERS.
SPECIAL-FILTERS are filters that show stack certain stack frames, hiding
others."
  (with-current-buffer buffer
    (insert "  Show: ")
    (dolist (filter special-filters)
      (insert-text-button (car filter)
                          'filter (cadr filter)
                          'follow-link t
                          'action #'cider-stacktrace-filter
                          'help-echo (cider-stacktrace-tooltip
                                      (format "Toggle %s stack frames"
                                              (car filter))))
      (insert " "))
    (insert "\n")
    (insert "  Hide: ")
    (dolist (filter filters)
      (insert-text-button (car filter)
                          'filter (cadr filter)
                          'follow-link t
                          'action #'cider-stacktrace-filter
                          'help-echo (cider-stacktrace-tooltip
                                      (format "Toggle %s stack frames"
                                              (car filter))))
      (insert " "))

    (let ((hidden "(0 frames hidden)"))
      (put-text-property 0 (length hidden) 'hidden-count t hidden)
      (insert " " hidden "\n"))))

(defun cider-stacktrace-render-suppression-toggle (buffer error-types)
  "Emit toggle buttons for each of the ERROR-TYPES leading this stacktrace BUFFER."
  (with-current-buffer buffer
    (when error-types
      (insert "  This is a CIDER middleware error.
  It may be a due to a bug, or perhaps simply to bad user input.
  If you believe it's a bug, please submit an issue report via `")
      (insert-text-button "M-x cider-report-bug"
                          'follow-link t
                          'action (lambda (_button) (cider-report-bug))
                          'help-echo (cider-stacktrace-tooltip
                                      "Report bug to the CIDER team."))
      (insert "`.\n\n")
      (insert "\
  If these stacktraces are occurring frequently, consider using the
  button(s) below to suppress these types of errors for the duration of
  your current CIDER session. The stacktrace buffer will still be
  generated, but it will \"pop under\" your current buffer instead of
  \"popping over\". The button toggles this behavior.\n\n ")
      (dolist (error-type error-types)
        (let ((suppressed (cider-stacktrace-suppressed-error-p error-type)))
          (insert-text-button (format "%s %s" (if suppressed "Promote" "Suppress") error-type)
                              'follow-link t
                              'error-type error-type
                              'action #'cider-stacktrace-toggle-suppression
                              'suppressed suppressed
                              'face (if suppressed
                                        'cider-stacktrace-suppressed-button-face
                                      'cider-stacktrace-promoted-button-face)
                              'help-echo (cider-stacktrace-tooltip
                                          (format "Click to %s these stacktraces."
                                                  (if suppressed "promote" "suppress")))))
        (insert " ")))))

(defun cider-stacktrace-render-frame (buffer frame)
  "Emit into BUFFER function call site info for the stack FRAME.
This associates text properties to enable filtering and source navigation."
  (with-current-buffer buffer
    (if (null frame) ;; Probably caused by OmitStackTraceInFastThrow
        (let ((url "https://docs.cider.mx/cider/troubleshooting.html#empty-java-stacktraces"))
          (insert "  No stacktrace available!\n  Please see ")
          (insert-text-button url
                              'url url
                              'follow-link t
                              'action (lambda (x) (browse-url (button-get x 'url)))))
      (nrepl-dbind-response frame (file line flags class method name var ns fn)
        (when (or class file fn method ns name)
          (let ((flags (mapcar #'intern flags))) ; strings -> symbols
            (insert-text-button (format "%26s:%5d  %s/%s"
                                        (if (member 'repl flags) "REPL" file) (or line -1)
                                        (if (member 'clj flags) ns class)
                                        (if (member 'clj flags) fn method))
                                'var var 'class class 'method method
                                'name name 'file file 'line line
                                'flags flags 'follow-link t
                                'action #'cider-stacktrace-navigate
                                'help-echo (cider-stacktrace-tooltip
                                            "View source at this location")
                                'font-lock-face 'cider-stacktrace-face
                                'type 'cider-plain-button)
            (save-excursion
              (let ((p4 (point))
                    (p1 (search-backward " "))
                    (p2 (search-forward "/"))
                    (p3 (search-forward-regexp "[^/$]+")))
                (put-text-property p1 p4 'font-lock-face 'cider-stacktrace-ns-face)
                (put-text-property p2 p3 'font-lock-face 'cider-stacktrace-fn-face)
                (put-text-property (line-beginning-position) (line-end-position)
                                   'cider-stacktrace-frame t)))))))))

(defun cider-stacktrace-render-compile-error (buffer cause)
  "Emit into BUFFER the compile error CAUSE, and enable jumping to it."
  (with-current-buffer buffer
    (nrepl-dbind-response cause (file path line column)
      (let ((indent "   ")
            (message-face 'cider-stacktrace-error-message-face))
        (insert indent)
        (insert (propertize "Error compiling " 'font-lock-face  message-face))
        (insert-text-button path 'compile-error t
                            'file file 'line line 'column column 'follow-link t
                            'action (lambda (_button)
                                      (cider-jump-to (cider-find-file file)
                                                     (cons line column)))
                            'help-echo (cider-stacktrace-tooltip
                                        "Jump to the line that caused the error"))
        (insert (propertize (format " at (%d:%d)" line column)
                            'font-lock-face message-face))))))

(defun cider-stacktrace--toggle-visibility (id)
  "Toggle visibility of the region with ID invisibility prop.
ID can also be a button, in which case button's property :id is used
instead.  This function can be used directly in button actions."
  (let ((id (if (or (numberp id) (symbolp id))
                ;; There is no proper way to identify buttons. Assuming that
                ;; id's can be either numbers or symbols.
                id
              (button-get id :id))))
    (if (and (consp buffer-invisibility-spec)
             (assoc id buffer-invisibility-spec))
        (remove-from-invisibility-spec (cons id t))
      (add-to-invisibility-spec (cons id t)))))

(defun cider-stacktrace--insert-named-group (indent name &rest vals)
  "Insert named group with the ability to toggle visibility.
NAME is a string naming the group.  VALS are strings to be inserted after
the NAME.  The whole group is prefixed by string INDENT."
  (let* ((str (and vals (replace-regexp-in-string "\n+\\'" "" (apply #'concat vals))))
         (id (and str
                  (string-match "\n" str)
                  (cl-gensym name))))
    (insert indent)
    (if id
        (let* ((beg-link (string-match "[^ :]" name))
               (end-link (string-match "[ :]" name (1+ beg-link))))
          (insert (substring name 0 beg-link))
          (insert-text-button (substring name beg-link end-link)
                              :id id
                              'face '((:weight bold) (:underline t))
                              'follow-link t
                              'help-echo "Toggle visibility"
                              'action #'cider-stacktrace--toggle-visibility)
          (insert (substring name end-link)))
      (insert (propertize name 'face '((:weight bold)))))
    (let ((pos (point)))
      (when str
        (cider-stacktrace-emit-indented (concat str "\n") nil nil t)
        (when id
          (remove-from-invisibility-spec (cons id t))
          (let ((hide-beg (save-excursion (goto-char pos) (point-at-eol)))
                (hide-end (1- (point-at-bol))))
            (overlay-put (make-overlay hide-beg hide-end) 'invisible id)))))))

(defun cider-stacktrace--emit-spec-problems (spec-data indent)
  "Emit SPEC-DATA indented with INDENT."
  (nrepl-dbind-response spec-data (spec value problems)
    (insert "\n")
    (cider-stacktrace--insert-named-group indent "    Spec: " spec)
    (cider-stacktrace--insert-named-group indent "   Value: " value)
    (insert "\n")
    (cider-stacktrace--insert-named-group indent "Problems: \n")
    (let ((indent2 (concat indent "    ")))
      (dolist (prob problems)
        (nrepl-dbind-response prob (in val predicate reason spec at extra)
          (insert "\n")
          (when (not (string= val value))
            (cider-stacktrace--insert-named-group indent2 "   val: " val))
          (when in
            (cider-stacktrace--insert-named-group indent2 "    in: " in))
          (cider-stacktrace--insert-named-group indent2   "failed: " predicate)
          (when spec
            (cider-stacktrace--insert-named-group indent2 "  spec: " spec))
          (when at
            (cider-stacktrace--insert-named-group indent2 "    at: " at))
          (when reason
            (cider-stacktrace--insert-named-group indent2 "reason: " reason))
          (when extra
            (cider-stacktrace--insert-named-group indent2 "extras: \n")
            (cider-stacktrace-emit-indented extra (concat indent2 "  ") nil t)))))))

(declare-function cider-inspector-inspect-last-exception "cider-inspector")

(defun cider-stacktrace--inspect-mouse (event &optional ex-data)
  "Mouse handler for EVENT.
If EX-DATA is true, inspect ex-data of the exception instead."
  (interactive "e")
  (let* ((pos (posn-point (event-end event)))
         (window (posn-window (event-end event)))
         (buffer (window-buffer window))
         (inspect-index (with-current-buffer buffer
                          (get-text-property pos 'inspect-index))))
    (cider-inspector-inspect-last-exception inspect-index ex-data)))

(defun cider-stacktrace--inspect-kbd (&optional ex-data)
  "Keyboard handler.
If EX-DATA is true, inspect ex-data of the exception instead."
  (interactive)
  (when-let ((inspect-index (get-text-property (point) 'inspect-index)))
    (cider-inspector-inspect-last-exception inspect-index ex-data)))

(defun cider-stacktrace--inspect-ex-data-mouse (event)
  "Mouse handler for EVENT."
  (interactive "e")
  (cider-stacktrace--inspect-mouse event t))

(defun cider-stacktrace--inspect-ex-data-kbd ()
  "Keyboard handler."
  (interactive)
  (cider-stacktrace--inspect-kbd t))

(defvar cider-stacktrace-exception-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'cider-stacktrace--inspect-mouse)
    (define-key map (kbd "p") #'cider-stacktrace--inspect-kbd)
    (define-key map (kbd "i") #'cider-stacktrace--inspect-kbd)
    (define-key map (kbd "RET") #'cider-stacktrace--inspect-kbd)
    map))

(defvar cider-stacktrace-ex-data-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'cider-stacktrace--inspect-ex-data-mouse)
    (define-key map (kbd "p") #'cider-stacktrace--inspect-ex-data-kbd)
    (define-key map (kbd "i") #'cider-stacktrace--inspect-ex-data-kbd)
    (define-key map (kbd "RET") #'cider-stacktrace--inspect-ex-data-kbd)
    map))

(defun cider-stacktrace-render-cause (buffer cause num note &optional inspect-index)
  "Emit into BUFFER the CAUSE NUM, exception class, message, data, and NOTE,
make INSPECT-INDEX actionable if present."
  (with-current-buffer buffer
    (nrepl-dbind-response cause (class message data spec triage stacktrace)
      (let ((indent "   ")
            (class-face 'cider-stacktrace-error-class-face)
            (message-face 'cider-stacktrace-error-message-face))
        (cider-propertize-region `(cause ,num)
          ;; Detail level 0: exception class
          (cider-propertize-region `(detail
                                     0

                                     inspect-index
                                     ,inspect-index

                                     keymap
                                     ,cider-stacktrace-exception-map)
            (insert (format "%d. " num)
                    (propertize note 'font-lock-face 'font-lock-comment-face) " "
                    (propertize class 'font-lock-face class-face 'mouse-face 'highlight)
                    "\n"))
          ;; Detail level 1: message + ex-data
          (cider-propertize-region '(detail 1)
            (if (equal class "clojure.lang.Compiler$CompilerException")
                (cider-stacktrace-render-compile-error buffer cause)
              (cider-stacktrace-emit-indented
               (propertize (or message "(No message)")
                           'font-lock-face  message-face)
               indent t))
            (when triage
              (insert "\n")
              (cider-stacktrace-emit-indented
               (propertize (string-trim triage) 'font-lock-face  message-face)
               indent nil))
            (when spec
              (insert "\n")
              (cider-stacktrace--emit-spec-problems spec (concat indent "  ")))
            (when data
              (insert "\n")
              (cider-propertize-region `(inspect-index
                                         ,inspect-index
                                         keymap
                                         ,cider-stacktrace-ex-data-map
                                         mouse-face
                                         highlight)
                (cider-stacktrace-emit-indented data indent nil t)))
            (insert "\n"))
          ;; Detail level 2: stacktrace
          (cider-propertize-region '(detail 2)
            (let ((beg (point))
                  (bg `(:background ,cider-stacktrace-frames-background-color :extend t)))
              (dolist (frame stacktrace)
                (cider-stacktrace-render-frame buffer frame)
                (insert "\n"))
              (overlay-put (make-overlay beg (point)) 'font-lock-face bg)))
          ;; Add line break between causes, even when collapsed.
          (cider-propertize-region '(detail 0)
            (insert "\n")))))))

(defun cider-stacktrace-initialize (causes)
  "Set and apply CAUSES initial visibility, filters, and cursor position."
  (nrepl-dbind-response (car causes) (class)
    (let ((compile-error-p (equal class "clojure.lang.Compiler$CompilerException")))
      ;; Fully display innermost cause. This also applies visibility/filters.
      (cider-stacktrace-cycle-cause 1 cider-stacktrace-detail-max)
      ;; Move point (DWIM) to the compile error location if present, or to the
      ;; first stacktrace frame in displayed cause otherwise. If the error
      ;; buffer is visible in a window, ensure that window is selected while moving
      ;; point, so as to move both the buffer's and the window's point.
      (with-selected-window (or (get-buffer-window cider-error-buffer)
                                (selected-window))
        (with-current-buffer cider-error-buffer
          (goto-char (point-min))
          (if compile-error-p
              (goto-char (next-single-property-change (point) 'compile-error))
            (progn
              (while (cider-stacktrace-next-cause))
              (when-let (position (next-single-property-change (point) 'flags))
                (goto-char position)))))))))

(defun cider-stacktrace-render (buffer causes &optional error-types)
  "Emit into BUFFER useful stacktrace information for the CAUSES.
Takes an optional ERROR-TYPES list which will render a 'suppression' toggle
that alters the pop-over/pop-under behavorior of the stacktrace buffers
created by these types of errors.  The suppressed errors set can be customized
through the `cider-stacktrace-suppressed-errors' variable."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "\n")
      ;; Stacktrace filters
      (cider-stacktrace-render-filters
       buffer
       `(("Project-Only" project) ("All" all))
       `(("Clojure" clj) ("Java" java) ("REPL" repl)
         ("Tooling" tooling) ("Duplicates" dup)))
      (insert "\n")
      ;; Option to suppress internal/middleware errors
      (when error-types
        (cider-stacktrace-render-suppression-toggle buffer error-types)
        (insert "\n\n"))
      ;; Stacktrace exceptions & frames
      (let* ((causes-length (length causes))
             (num causes-length))
        (dolist (cause causes)
          (let ((note (if (= num causes-length) "Unhandled" "Caused by")))
            (cider-stacktrace-render-cause buffer cause num note (- causes-length num))
            (setq num (1- num))))))
    (cider-stacktrace-initialize causes)
    (font-lock-refresh-defaults)))

(defun cider-stacktrace-analyze-at-point ()
  "Removed."
  (interactive)
  (message "This function has been removed.
You can jump to functions and methods directly from the printed stacktrace now."))
(make-obsolete 'cider-stacktrace-analyze-at-point nil "1.18")

(defun cider-stacktrace-analyze-in-region (&rest _)
  "Removed."
  (interactive)
  (message "This function has been removed.
You can jump to functions and methods directly from the printed stacktrace now."))
(make-obsolete 'cider-stacktrace-analyze-in-region nil "1.18")

(provide 'cider-stacktrace)

;;; cider-stacktrace.el ends here
