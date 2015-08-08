;;; exwm-workspace.el --- Workspace Module for EXWM  -*- lexical-binding: t -*-

;; Copyright (C) 2015 Chris Feng

;; Author: Chris Feng <chris.w.feng@gmail.com>
;; Keywords: unix

;; This file is not part of GNU Emacs.

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This module adds workspace support for EXWM.

;; Todo:
;; + prevent from deleting frames of Emacs client (`frame-delete-functions')

;;; Code:

(defvar exwm-workspace-number 4 "Number of workspaces (1 ~ 10).")
(defvar exwm-workspace--list nil "List of all workspaces (Emacs frames).")
(defvar exwm-workspace--switch-map
  (let ((map (make-sparse-keymap)))
    (define-key map [t] (lambda () (interactive)))
    (dotimes (i 10)
      (define-key map (int-to-string i)
        `(lambda ()
           (interactive)
           (when (< ,i exwm-workspace-number)
             (goto-history-element ,(1+ i))
             (exit-minibuffer)))))
    (define-key map "\C-a" (lambda () (interactive) (goto-history-element 1)))
    (define-key map "\C-e" (lambda ()
                             (interactive)
                             (goto-history-element exwm-workspace-number)))
    (define-key map "\C-g" 'abort-recursive-edit)
    (define-key map "\C-]" 'abort-recursive-edit)
    (define-key map "\C-j" 'exit-minibuffer)
    ;; (define-key map "\C-m" 'exit-minibuffer) ;not working
    (define-key map [return] 'exit-minibuffer)
    (define-key map " " 'exit-minibuffer)
    (define-key map "\C-f" 'previous-history-element)
    (define-key map "\C-b" 'next-history-element)
    ;; Alternative keys
    (define-key map [right] 'previous-history-element)
    (define-key map [left] 'next-history-element)
    map)
  "Keymap used for interactively switch workspace.")

(defvar exwm-workspace--switch-history nil
  "History for `read-from-minibuffer' to interactively switch workspace.")

(defun exwm-workspace--update-switch-history ()
  "Update the history for switching workspace to reflect the latest status."
  (let ((sequence (number-sequence 0 (1- exwm-workspace-number)))
        (not-empty (make-vector exwm-workspace-number nil)))
    (dolist (i exwm--id-buffer-alist)
      (with-current-buffer (cdr i)
        (when exwm--frame
          (setf (elt not-empty (cl-position exwm--frame exwm-workspace--list))
                t))))
    (setq exwm-workspace--switch-history
          (mapcar
           (lambda (i)
             (mapconcat
              (lambda (j)
                (format (if (= i j) "[%s]" " %s ")
                        (propertize
                         (int-to-string j)
                         'face
                         (cond ((frame-parameter (elt exwm-workspace--list j)
                                                 'exwm--urgency)
                                '(:foreground "orange"))
                               ((elt not-empty j) '(:foreground "green"))
                               (t nil)))))
              sequence ""))
           sequence))))

(defvar exwm-workspace--current nil "Current active workspace.")
(defvar exwm-workspace-current-index 0 "Index of current active workspace.")
(defvar exwm-workspace--switch-lock nil "Non-nil to prevent workspace switch.")

(defun exwm-workspace-switch (index &optional force)
  "Switch to workspace INDEX. Query for INDEX if it's not specified.

The optional FORCE option is for internal use only."
  (interactive
   (list
    (unless (and (eq major-mode 'exwm-mode) exwm--fullscreen) ;it's invisible
      (let* ((history-add-new-input nil)  ;prevent modifying history
             (idx (read-from-minibuffer
                   "Workspace: " (elt exwm-workspace--switch-history
                                      exwm-workspace-current-index)
                   exwm-workspace--switch-map nil
                   `(exwm-workspace--switch-history
                     . ,(1+ exwm-workspace-current-index)))))
        (cl-position idx exwm-workspace--switch-history :test 'equal)))))
  (unless (or exwm-workspace--switch-lock (not index))
    (setq exwm-workspace--switch-lock t)
    (unless (and (<= 0 index) (< index exwm-workspace-number))
      (user-error "[EXWM] Workspace index out of range: %d" index))
    (when (or force (/= exwm-workspace-current-index index))
      (let ((frame (elt exwm-workspace--list index)))
        (setq exwm-workspace--current frame
              exwm-workspace-current-index index)
        (select-frame-set-input-focus frame)
        ;; Move mouse when necessary
        (let ((position (mouse-pixel-position))
              x y w h)
          (unless (eq frame (car position))
            (setq x (cadr position)
                  y (cddr position)
                  w (frame-pixel-width frame)
                  h (frame-pixel-height frame))
            (when (or (> x w) (> y h))
              (setq x (/ w 2)
                    y (/ h 2)))
            (set-mouse-pixel-position frame x y)))
        (setq default-minibuffer-frame frame)
        ;; Hide windows in other workspaces by preprending a space
        (dolist (i exwm--id-buffer-alist)
          (with-current-buffer (cdr i)
            (let ((name (replace-regexp-in-string "^\\s-*" "" (buffer-name))))
              (exwm-workspace-rename-buffer (if (eq frame exwm--frame)
                                                name
                                              (concat " " name))))))
        ;; Update demands attention flag
        (set-frame-parameter frame 'exwm--urgency nil)
        ;; Update switch workspace history
        (exwm-workspace--update-switch-history)
        (exwm--make-emacs-idle-for 0.1) ;FIXME
        ;; Update _NET_CURRENT_DESKTOP
        (xcb:+request exwm--connection
            (make-instance 'xcb:ewmh:set-_NET_CURRENT_DESKTOP
                           :window exwm--root :data index))
        (xcb:flush exwm--connection)))
    (setq exwm-workspace--switch-lock nil)))

(defun exwm-workspace--on-focus-in ()
  "Fix unexpected frame switch."
  (unless exwm-workspace--switch-lock
    (let ((index (cl-position (selected-frame) exwm-workspace--list)))
      (exwm--log "Focus on workspace %s" index)
      (when (and index (/= index exwm-workspace-current-index))
        (exwm--log "Workspace was switched unexpectedly")
        (exwm-workspace-switch index)))))

(defun exwm-workspace-move-window (index &optional id)
  "Move window ID to workspace INDEX."
  (interactive
   (list
    (let* ((history-add-new-input nil)  ;prevent modifying history
           (idx (read-from-minibuffer
                 "Workspace: " (elt exwm-workspace--switch-history
                                    exwm-workspace-current-index)
                 exwm-workspace--switch-map nil
                 `(exwm-workspace--switch-history
                   . ,(1+ exwm-workspace-current-index)))))
      (cl-position idx exwm-workspace--switch-history :test 'equal))))
  (unless id (setq id (exwm--buffer->id (window-buffer))))
  (unless (and (<= 0 index) (< index exwm-workspace-number))
    (user-error "[EXWM] Workspace index out of range: %d" index))
  (when (/= exwm-workspace-current-index index)
    (let ((frame (elt exwm-workspace--list index)))
      (with-current-buffer (exwm--id->buffer id)
        (setq exwm--frame frame)
        (exwm-workspace-rename-buffer
         (concat " " (replace-regexp-in-string "^\\s-*" "" (buffer-name))))
        (if exwm--floating-frame
            ;; Move the floating frame is enough
            (xcb:+request exwm--connection
                (make-instance 'xcb:ReparentWindow
                               :window (frame-parameter exwm--floating-frame
                                                        'exwm-outer-id)
                               :parent (frame-parameter frame 'exwm-window-id)
                               :x 0 :y 0))
          ;; Move the window itself
          (bury-buffer)
          (exwm-layout--hide id)
          ;; Force update input focus
          (setq exwm-input--focus-id xcb:Window:None)
          (exwm-input--update-focus)
          (xcb:+request exwm--connection
              (make-instance 'xcb:ReparentWindow
                             :window id
                             :parent (frame-parameter frame 'exwm-window-id)
                             :x 0 :y 0)))))
    (xcb:flush exwm--connection)
    (exwm-workspace--update-switch-history)))

(defun exwm-workspace-rename-buffer (newname)
  "Rename a buffer."
  (if (/= ?\s (aref newname 0))
      (rename-buffer newname t)
    ;; If a buffer name is prefixed with a space, Emacs append a random
    ;; number before renaming it. This is not desired behavior.
    (let ((name (replace-regexp-in-string "<[0-9]+>$" "" newname))
          (counter 1))
      (while (and (get-buffer newname)
                  (not (eq (get-buffer newname) (current-buffer))))
        (setq newname (format "%s<%d>" name (cl-incf counter)))))
    (rename-buffer newname)))

(defun exwm-workspace--init ()
  "Initialize workspace module."
  (cl-assert (and (< 0 exwm-workspace-number) (>= 10 exwm-workspace-number)))
  ;; Prevent unexpected exit
  (setq confirm-kill-emacs
        (lambda (prompt)
          (pcase (length exwm--id-buffer-alist)
            (0 (y-or-n-p prompt))
            (x (yes-or-no-p (format "[EXWM] %d window%s currently alive. %s"
                                    x (if (= x 1) "" "s") prompt))))))
  ;; Initialize workspaces
  (setq exwm-workspace--list (frame-list))
  (when (< 1 (length exwm-workspace--list))
    ;; Emacs client creates an extra (but unusable) frame
    (dolist (i exwm-workspace--list)
      (unless (frame-parameter i 'window-id)
        (setq exwm-workspace--list (delq i exwm-workspace--list)))))
  (cl-assert (= 1 (length exwm-workspace--list)))
  (exwm--make-emacs-idle-for 0.1)      ;wait for the frame ready
  ;; Configure the existing frame
  (set-frame-parameter (car exwm-workspace--list) 'fullscreen 'fullboth)
  ;; Create remaining frames
  (dotimes (i (1- exwm-workspace-number))
    (nconc exwm-workspace--list
           (list (make-frame '((window-system . x) (fullscreen . fullboth))))))
  ;; Configure workspaces
  (dolist (i exwm-workspace--list)
    (let ((window-id (string-to-int (frame-parameter i 'window-id)))
          (outer-id (string-to-int (frame-parameter i 'outer-window-id))))
      ;; Save window IDs
      (set-frame-parameter i 'exwm-window-id window-id)
      (set-frame-parameter i 'exwm-outer-id outer-id)
      ;; Set OverrideRedirect on all frames
      (xcb:+request exwm--connection
          (make-instance 'xcb:ChangeWindowAttributes
                         :window outer-id :value-mask xcb:CW:OverrideRedirect
                         :override-redirect 1))
      ;; Select events on all virtual roots
      (xcb:+request exwm--connection
          (make-instance 'xcb:ChangeWindowAttributes
                         :window window-id :value-mask xcb:CW:EventMask
                         :event-mask xcb:EventMask:SubstructureRedirect))))
  (xcb:flush exwm--connection)
  ;; Handle unexpected frame switch
  (add-hook 'focus-in-hook 'exwm-workspace--on-focus-in)
  ;; Switch to the first workspace
  (exwm-workspace-switch 0 t))



(provide 'exwm-workspace)

;;; exwm-workspace.el ends here