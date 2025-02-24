;;; calfw-org.el --- calendar view for org-agenda -*- lexical-binding: t -*-

;; Copyright (C) 2011  SAKURAI Masashi

;; Author: SAKURAI Masashi <m.sakurai at kiwanami.net>
;; Keywords: calendar, org
;; Package-Requires: ((cl-lib "0.5")(calfw "1.6"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Display org-agenda items in the calfw buffer.
;; (Because I don't use the org-agenda mainly,
;; I hope someone continue integration with the org.)

;; (require 'calfw-org)
;;
;; ;; use org agenda buffer style keybinding.
;; ;; (setq calfw-org-overwrite-default-keybinding t)
;;
;; M-x calfw-open-org-calendar

;;; Code:

(require 'cl-lib)
(require 'calfw)
(require 'org)
(require 'org-agenda)
(require 'org-element)
(require 'org-capture)

(defgroup calfw-org nil
  "Options about calfw-org."
  :tag "Calfw Org"
  :group 'org
  :group 'cfw)

(defcustom calfw-org-capture-template nil
  "org-capture template. If you use `org-capture' with `calfw', you shold set like
'(\"c\" \"calfw2org\" entry (file nil)  \"* %?\n %(calfw-org-capture-day)\")"
  :group 'calfw-org
  :version "24.1"
  :type
  '(list string string symbol (list symbol (choice file (const nil))) string))

(defsubst calfw-org-tp (text prop)
  "[internal] Return text property at position 0."
  (get-text-property 0 prop text))

(defvar calfw-org-agenda-schedule-args nil
  "Default arguments for collecting agenda entries.
If value is nil, `org-agenda-entry-types' is used.")

(defvar calfw-org-icalendars nil
  "Org buffers for exporting icalendars.
Setting a list of the custom agenda files, one can use the
different agenda files from the default agenda ones.")

(defvar calfw-org-overwrite-default-keybinding nil
  "Overwrites default keybinding. It needs restarting of Emacs(if not work)
For example,

 ------------------------------------------------
  key   | function
 ------------------------------------------------
    g   | calfw-refresh-calendar-buffer
    j   | calfw-org-goto-date
    k   | org-capture
    x   | calfw-org-clean-exit
    d   | calfw-change-view-day
    v d | calfw-change-view-day
    v w | calfw-change-view-week
    v m | calfw-change-view-month
 ------------------------------------------------")

(defvar calfw-org-face-agenda-item-foreground-color "Seagreen4"
  "Variable for org agenda item foreground color.")

(defvar calfw-org-todo-keywords-regexp nil)

(defun calfw-org-collect-schedules-period (begin end)
  "[internal] Return org schedule items between BEGIN and END."
  (let ((org-agenda-prefix-format " ")
        (_span 'day))
    (setq org-agenda-buffer
          (when (buffer-live-p org-agenda-buffer)
            org-agenda-buffer))
    (org-compile-prefix-format nil)
    (cl-loop for date in (calfw-enumerate-days begin end) append
             (cl-loop for file in (or calfw-org-icalendars (org-agenda-files nil 'ifmode))
                      append
                      (progn
                        (org-check-agenda-file file)
                        (apply 'org-agenda-get-day-entries
                               file date
                               calfw-org-agenda-schedule-args))))))

(defun calfw-org-onclick ()
  "Jump to the clicked org item."
  (interactive)
  (let ((marker (get-text-property (point) 'org-marker))
        (link   (get-text-property (point) 'org-link))
        (file   (get-text-property (point) 'calfw-org-file))
        (beg    (get-text-property (point) 'calfw-org-h-beg))
        (_loc    (get-text-property (point) 'calfw-org-loc)))
    (when link
      (org-open-link-from-string link))
    (when (and marker (marker-buffer marker))
      (org-mark-ring-push)
      (switch-to-buffer (marker-buffer marker))
      (widen)
      (goto-char (marker-position marker))
      (when (eq major-mode 'org-mode)
        (org-reveal)))
    (when beg
      (find-file file)
      (goto-char beg)
      (org-cycle))))

(defun calfw-org-clean-exit ()
  "Close buffers opened by calfw-org before closing Calendar Framework."
  (interactive)
  (org-release-buffers org-agenda-new-buffers)
  (setq org-agenda-new-buffers nil)
  (bury-buffer))

(defvar calfw-org-text-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] 'calfw-org-onclick)
    (define-key map (kbd "RET") 'calfw-org-onclick)
    (define-key map (kbd "C-c C-o") 'calfw-org-onclick)
    map)
  "key map on the calendar item text.")

(defun calfw-org-extract-summary (org-item)
  "[internal] Remove some strings."
  (let* ((item org-item) (tags (calfw-org-tp item 'tags)))
    ;; (when (string-match calfw-org-todo-keywords-regexp item) ; dynamic bind
    ;;   (setq item (replace-match "" nil nil item)))
    (if tags
        (when (string-match (concat "[\t ]*:+" (mapconcat 'identity tags ":+") ":+[\t ]*$") item)
          (setq item (replace-match "" nil nil item))))
    (when (string-match "[0-9]\\{2\\}:[0-9]\\{2\\}\\(-[0-9]\\{2\\}:[0-9]\\{2\\}\\)?[\t ]+" item)
      (setq item (replace-match "" nil nil item)))
    (when (string-match "^ +" item)
      (setq item (replace-match "" nil nil item)))
    (when (= 0 (length item))
      (setq item (calfw-org-tp org-item 'org-category)))
    item))

(defun calfw-org-summary-format (item)
  "Format an item. (How should be displayed?)"
  (let* ((_time (calfw-org-tp item 'time))
         (time-of-day (calfw-org-tp item 'time-of-day))
         (time-str (and time-of-day
                        (format "%02i:%02i " (/ time-of-day 100) (% time-of-day 100))))
         (_category (calfw-org-tp item 'org-category))
         (_tags (calfw-org-tp item 'tags))
         (marker (calfw-org-tp item 'org-marker))
         (_buffer (and marker (marker-buffer marker)))
         (text (calfw-org-extract-summary item))
         (props (calfw-extract-text-props item 'face 'keymap))
         (extra (calfw-org-tp item 'extra)))
    (setq text (substring-no-properties text))
    (when (string-match (concat "^" org-deadline-string ".*") extra)
      (add-text-properties 0 (length text) (list 'face (org-agenda-deadline-face 1.0)) text))
    (if org-todo-keywords-for-agenda
        (when (string-match (concat "^[\t ]*\\<\\(" (mapconcat 'identity org-todo-keywords-for-agenda "\\|") "\\)\\>") text)
          (add-text-properties (match-beginning 1) (match-end 1) (list 'face (org-get-todo-face (match-string 1 text))) text)))
    ;;; ------------------------------------------------------------------------
    ;;; act for org link
    ;;; ------------------------------------------------------------------------
    (setq text (replace-regexp-in-string "%[0-9A-F]\\{2\\}" " " text))
    (if (string-match org-bracket-link-regexp text)
        (let* ((desc (if (match-end 3) (match-string-no-properties 3 text)))
               (link (org-link-unescape (match-string-no-properties 1 text)))
               (help (concat "LINK: " link))
               (link-props (list
                            'face 'org-link
                            'mouse-face 'highlight
                            'help-echo help
                            'org-link link)))
          (if desc
              (progn
                (setq desc (apply 'propertize desc link-props))
                (setq text (replace-match desc nil nil text)))
            (setq link (apply 'propertize link link-props))
            (setq text (replace-match link nil nil text)))))
    (when time-str
      (setq text (concat time-str text)))
    (propertize
     (apply 'propertize text props)
     ;; include org filename
     ;; (and buffer (concat " " (buffer-name buffer)))
     'keymap calfw-org-text-keymap
     ;; Delete the display property, since displaying images will break our
     ;; table layout.
     'display nil)))

(defvar calfw-org-schedule-summary-transformer 'calfw-org-summary-format
  "Transformation function which transforms the org item string to calendar title.
If this function splits into a list of string, the calfw displays those string in multi-lines.")

(defun calfw-org-normalize-date (date)
  "Return a normalized date. (MM DD YYYY)."
  (cond
   ((numberp date)
    (calendar-gregorian-from-absolute date))
   (t date)))

(defun calfw-org-get-timerange (text)
  "Return a range object (begin end text).
If TEXT does not have a range, return nil."
  (let* ((dotime (calfw-org-tp text 'dotime)))
    (and (stringp dotime) (string-match org-ts-regexp dotime)
	 (let ((date-string  (match-string 1 dotime))
	       (extra (calfw-org-tp text 'extra)))
	   (if (string-match "(\\([0-9]+\\)/\\([0-9]+\\)): " extra)
	       (let* ((cur-day (string-to-number
				(match-string 1 extra)))
		      (total-days (string-to-number
				   (match-string 2 extra)))
		      (start-date (org-read-date nil t date-string))
		      (end-date (time-add
				 start-date
				 (seconds-to-time (* 3600 24 (- total-days 1))))))
		       (unless (= cur-day total-days)
             (list (calendar-gregorian-from-absolute (time-to-days start-date))
		                  (calendar-gregorian-from-absolute (time-to-days end-date)) text)))
	     )))))

(defun calfw-org-schedule-period-to-calendar (begin end)
  "[internal] Return calfw calendar items between BEGIN and END
from the org schedule data."
  (cl-loop with calfw-org-todo-keywords-regexp = (regexp-opt org-todo-keywords-for-agenda) ; dynamic bind
           with contents = nil with periods = nil
           for i in (calfw-org-collect-schedules-period begin end)
           for date = (calfw-org-tp i 'date)
           for line = (funcall calfw-org-schedule-summary-transformer i)
           for range = (calfw-org-get-timerange line)
           if range do
           (unless (member range periods)
             (push range periods))
           else do
           ;; dotime is not present if this event was already added as a timerange
           (if (calfw-org-tp i 'dotime)
               (setq contents (calfw-contents-add
                               (calfw-org-normalize-date date)
                               line contents)))
           finally return (nconc contents (list (cons 'periods periods)))))

(defun calfw-org-schedule-sorter (text1 text2)
  "[internal] Sorting algorithm for org schedule items.
TEXT1 < TEXT2."
  (condition-case nil
      (let ((time1 (calfw-org-tp text1 'time-of-day))
            (time2 (calfw-org-tp text2 'time-of-day)))
        (cond
         ((and time1 time2) (< time1 time2))
         (time1 t)   ; time object is moved to upper
         (time2 nil)
         (t (string-lessp text1 text2))))
    (error (string-lessp text1 text2))))

(defun calfw-org-schedule-sorter2 (text1 text2)
  "[internal] Sorting algorithm for org schedule items.
TEXT1 < TEXT2. This function makes no-time items in front of timed-items."
  (condition-case nil
      (let ((time1 (calfw-org-tp text1 'time-of-day))
            (time2 (calfw-org-tp text2 'time-of-day)))
        (cond
         ((and time1 time2) (< time1 time2))
         (time1 nil) ; time object is moved to upper
         (time2 t)
         (t (string-lessp text1 text2))))
    (error (string-lessp text1 text2))))

(defun calfw-org-format-title (file h-obj t-obj h-beg loc)
  (propertize
   (concat
    (when  (org-element-property :hour-start t-obj)
      (format "%02i:%02i "
              (org-element-property :hour-start t-obj)
              (org-element-property :minute-start t-obj)))
    (org-element-property :title h-obj))
   'keymap calfw-org-text-keymap
   'display nil
   'calfw-org-file file
   'calfw-org-h-beg h-beg
   'calfw-org-loc loc))

(defun calfw-org-format-date (t-obj lst)
  (mapcar
   (lambda (v)
     (org-element-property v t-obj)) lst))

(defun calfw-org-filter-datetime (t-obj lst)
  (if (car (calfw-org-format-date t-obj lst))
      (calfw-org-format-date t-obj lst)
    nil))

(defun calfw-org-convert-event (file h-obj t-obj h-beg)
  (let ((sdate '(:month-start :day-start :year-start))
        (stime '(:hour-start :minute-start))
        (edate '(:month-end :day-end :year-end))
        (etime '(:hour-end :minute-end))
        (loc (org-element-property :LOCATION h-obj)))
    (make-calfw-event
     :start-date  (calfw-org-format-date t-obj sdate)
     :start-time  (calfw-org-filter-datetime t-obj stime)
     :end-date    (calfw-org-filter-datetime t-obj edate)
     :end-time    (calfw-org-filter-datetime t-obj etime)
     :title       (calfw-org-format-title file h-obj t-obj h-beg loc)
     :location    loc
     :description (if (org-element-property :contents-begin h-obj)
                      (replace-regexp-in-string
                       " *:PROPERTIES:\n  \\(.*\\(?:\n.*\\)*?\\) :END:\n" ""
                       (buffer-substring (org-element-property :contents-begin h-obj)
                                         (org-element-property :contents-end h-obj)))
                    nil))))

(defun calfw-org-convert-org-to-calfw (file)
  (save-excursion
    (with-current-buffer
        (find-file-noselect file)
      (let*
          ((elem-obj (org-element-parse-buffer))
           (pos-lst `( ,@(org-element-map elem-obj 'timestamp
                           (lambda (hl) (org-element-property :begin hl) ))
                       ,@(org-element-map (org-element-map elem-obj 'headline
                                            (lambda (hl)
                                              (org-element-property :deadline hl) ) ) 'timestamp
                           (lambda (hl) (org-element-property :begin hl) ))
                       ,@(org-element-map (org-element-map elem-obj 'headline
                                            (lambda (hl)
                                              (org-element-property :scheduled hl) ) ) 'timestamp
                           (lambda (hl) (org-element-property :begin hl) )))))
        (cl-loop for pos in pos-lst
                 do (goto-char pos)
                 for t-obj =  (org-element-timestamp-parser)
                 for h-obj = (progn
                               (org-back-to-heading t)
                               (org-element-headline-parser (point-max) t))
                 for h-beg  = (point)
                 for event = (calfw-org-convert-event file h-obj t-obj h-beg)
                 for ts-type = (org-element-property :type t-obj)
                 if (eq 'active-range ts-type)
                 collect event into periods
                 else if (eq 'active ts-type)
                 collect event into contents
                 ;; else do
                 ;; (message "calfw-org: Cannot handle event")
                 finally
                 (kill-buffer (get-file-buffer file))
                 (cl-return `((periods ,periods) ,@contents)))))))

(defun calfw-org-to-calendar (file begin end)
  (cl-loop for event in (calfw-org-convert-org-to-calfw file)
           if (and (listp event)
                   (equal 'periods (car event)))
           collect
           (cons
            'periods
            (cl-loop for evt in (cadr event)
                     if (and
                         (calfw-date-less-equal-p begin (calfw-event-end-date evt))
                         (calfw-date-less-equal-p (calfw-event-start-date evt) end))
                     collect evt))
           else if (calfw-date-between begin end (calfw-event-start-date event))
           collect event))

(defun calfw-org-create-file-source (name file color)
  "Create org-element based source. "
  (let ((file file))
    (make-calfw-source
     :name (concat "Org:" name)
     :color color
     :data (lambda (begin end)
             (calfw-org-to-calendar file begin end)))))

(defun calfw-org-capture-day ()
  (with-current-buffer  (get-buffer-create calfw-calendar-buffer-name)
    (let ((pos (calfw-cursor-to-nearest-date)))
      (concat "<"
              (format-time-string  "%Y-%m-%d %a"
                                   (encode-time 0 0 0
                                                (calendar-extract-day pos)
                                                (calendar-extract-month pos)
                                                (calendar-extract-year pos)))
              ">"))))

(when calfw-org-capture-template
  (setq org-capture-templates
        (append org-capture-templates (list calfw-org-capture-template))))

(defun calfw-org-capture ()
  "Open org-agenda buffer on the selected date."
  (interactive)
  (if calfw-org-capture-template
      (org-capture nil (car calfw-org-capture-template))
    (message "The variable `calfw-org-capture-template' is not set yet.")))

(defun calfw-org-open-agenda-day ()
  "Open org-agenda buffer on the selected date."
  (interactive)
  (let ((date (calfw-cursor-to-nearest-date)))
    (when date
      (org-agenda-list nil (calendar-absolute-from-gregorian date) 'day))))

(define-key calfw-calendar-mode-map "c" 'calfw-org-capture)

(defvar calfw-org-schedule-map
  (calfw-define-keymap
   '(("q"   . bury-buffer)
     ("SPC" . calfw-org-open-agenda-day)))
  "Key map for the calendar buffer.")

(defvar calfw-org-custom-map
  (calfw-define-keymap
   '(("g"   . calfw-refresh-calendar-buffer)
     ("j"   . calfw-org-goto-date)
     ("k"   . org-capture)
     ("q"   . bury-buffer)
     ("d"   . calfw-change-view-day)
     ("v d" . calfw-change-view-day)
     ("v w" . calfw-change-view-week)
     ("v m" . calfw-change-view-month)
     ("x"   . calfw-org-clean-exit)
     ("SPC" . calfw-org-open-agenda-day)))
  "Key map for the calendar buffer.")

(defun calfw-org-create-source (&optional color)
  "Create org-agenda source."
  (make-calfw-source
   :name "org-agenda"
   :color (or color calfw-org-face-agenda-item-foreground-color)
   :data 'calfw-org-schedule-period-to-calendar))

(defun calfw-open-org-calendar ()
  "Open an org schedule calendar in the new buffer."
  (interactive)
  (save-excursion
    (let* ((source1 (calfw-org-create-source))
           (curr-keymap (if calfw-org-overwrite-default-keybinding calfw-org-custom-map calfw-org-schedule-map))
           (cp (calfw-create-calendar-component-buffer
                :view 'month
                :contents-sources (list source1)
                :custom-map curr-keymap
                :sorter 'calfw-org-schedule-sorter)))
      (switch-to-buffer (calfw-cp-get-buffer cp))
      (when (not org-todo-keywords-for-agenda)
        (message "Warn : open org-agenda buffer first.")))))

(defun calfw-org-from-calendar ()
  "Do something. This command should be executed on the calfw calendar."
  (interactive)
  (let* ((mdy (calfw-cursor-to-nearest-date))
         (_m (calendar-extract-month mdy))
         (_d (calendar-extract-day   mdy))
         (_y (calendar-extract-year  mdy)))
    ;; exec org-remember here?
    ))

(defun calfw-org-read-date-command ()
  "Move the cursor to the specified date."
  (interactive)
  (calfw-emacs-to-calendar (org-read-date nil 'to-time)))

(defun calfw-org-goto-date ()
  "Move the cursor to the specified date."
  (interactive)
  (calfw-navi-goto-date
   (calfw-org-read-date-command)))

;; (progn (eval-current-buffer) (calfw-open-org-calendar))
;; (setq org-agenda-files '("./org-samples/complex.org"))

;; Local Variables:
;; coding: utf-8-unix
;; End:

(provide 'calfw-org)
;;; calfw-org.el ends here
