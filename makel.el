;;; makel.el --- Makefile target picker with compilation buffers  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Dmitry Akatov
;; Author: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; URL: https://github.com/rails-to-cosmos/makel
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.4"))
;; Keywords: tools, processes

;;; Commentary:
;; Pick Makefile targets with \[makel-run] and run them in interactive
;; compilation buffers.  Use \[makel-menu] to run or switch targets.
;; Enable \[makel-mode-line-mode] to track their status globally.

;;; Code:

(require 'cl-lib)
(require 'compile)
(require 'comint)
(require 'ansi-color)
(require 'transient)

;;; Per-buffer state

(defvar makel--buffers nil
  "List of tracked make output buffers (newest first).")

(defvar-local makel--target nil
  "Make target running in this buffer.")

(defvar-local makel--project nil
  "Project name (basename of the directory containing the Makefile).")

(defvar-local makel--status 'running
  "Buffer-local status: `running', `ok', or (fail . EXIT-CODE).")

(defvar-local makel--start-time nil
  "Time the make process was spawned (for elapsed-time display).")

;;; Faces

(defface makel-status-running-face
  '((t :inherit warning))
  "Face for a running make in the mode line."
  :group 'makel)

(defface makel-status-ok-face
  '((t :inherit success))
  "Face for a successful make in the mode line."
  :group 'makel)

(defface makel-status-fail-face
  '((t :inherit error))
  "Face for a failed make in the mode line."
  :group 'makel)

(defface makel-header-face
  '((t :inherit header-line :slant italic))
  "Face for the output buffer header line."
  :group 'makel)

;;; Customization

(defgroup makel nil
  "Makefile target picker with compilation buffers."
  :group 'tools
  :prefix "makel-")

(defcustom makel-mode-line-cleanup-delay 60
  "Seconds after completion before the mode-line entry auto-disappears.
Nil disables auto-cleanup."
  :type '(choice (integer :tag "Seconds")
                 (const :tag "Never" nil))
  :group 'makel)

;;; Keys

(defvar makel-done-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map compilation-mode-map)
    (define-key map (kbd "q")       #'quit-window)
    (define-key map (kbd "C-c C-k") #'quit-window)
    (define-key map (kbd "C-c C-q") #'quit-window)
    map)
  "Local map installed once the make process has exited.
Inherits compilation navigation bindings.")

;;; Commands

(defun makel-kill-process ()
  "Kill the running make process."
  (interactive)
  (let ((process (get-buffer-process (current-buffer))))
    (when (and process (process-live-p process))
      (kill-process process)
      (message "make %s: killed" makel--target))))

;;; Mode-line construct

(defun makel--status-glyph (status)
  "Mode-line label + face for STATUS."
  (pcase status
    ('running     (propertize "[RUN]"  'face 'makel-status-running-face))
    ('ok          (propertize "[OK]"   'face 'makel-status-ok-face))
    (`(fail . ,n) (propertize (format "[FAIL %d]" n)
                              'face 'makel-status-fail-face))
    (_            "[?]")))

(defun makel--status-label (status)
  "Plain-text label for STATUS."
  (pcase status
    ('running     "running")
    ('ok          "ok")
    (`(fail . ,n) (format "failed (%d)" n))
    (_            "?")))

(defun makel--elapsed ()
  "Seconds since the make process in this buffer was spawned."
  (if makel--start-time
      (float-time (time-since makel--start-time))
    0.0))

(defun makel--entry-help (buf)
  "Help-echo for BUF's mode-line entry."
  (with-current-buffer buf
    (format "%s\nstatus: %s\nelapsed: %.1fs\nmouse-1 show, mouse-3 kill"
            (buffer-name buf)
            (makel--status-label makel--status)
            (makel--elapsed))))

(defun makel--entry-keymap (buf)
  "Mode-line keymap for BUF: mouse-1 shows buffer, mouse-3 kills."
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1]
                (lambda (_e) (interactive "e") (makel--show-buffer buf)))
    (define-key m [mode-line mouse-3]
                (lambda (_e)
                  (interactive "e")
                  (when (y-or-n-p (format "Kill %s? " (buffer-name buf)))
                    (let ((kill-buffer-query-functions nil))
                      (kill-buffer buf)))))
    m))

(defun makel--mode-line-entry (buf)
  "Propertized mode-line string for BUF."
  (with-current-buffer buf
    (propertize (format "%s%s%s"
                        (if makel--project (concat makel--project "/") "")
                        (or makel--target "?")
                        (makel--status-glyph makel--status))
                'mouse-face 'mode-line-highlight
                'help-echo (makel--entry-help buf)
                'local-map (makel--entry-keymap buf))))

(defun makel--mode-line-construct ()
  "Mode-line value: tracked make buffers with status, or empty when none."
  (setq makel--buffers (cl-remove-if-not #'buffer-live-p makel--buffers))
  (when makel--buffers
    (concat " make:"
            (mapconcat #'makel--mode-line-entry makel--buffers " "))))

(defvar makel-mode-line-format '(:eval (makel--mode-line-construct))
  "Construct added to `global-mode-string' to surface tracked makes.")
(put 'makel-mode-line-format 'risky-local-variable t)

;;;###autoload
(define-minor-mode makel-mode-line-mode
  "Show tracked Makefile processes in the global mode line."
  :global t
  :group 'makel
  (if makel-mode-line-mode
      (unless (member makel-mode-line-format (default-value 'global-mode-string))
        (setq-default global-mode-string
                      (append (default-value 'global-mode-string)
                              (list makel-mode-line-format))))
    (setq-default global-mode-string
                  (remove makel-mode-line-format
                          (default-value 'global-mode-string))))
  (force-mode-line-update t))

;;; Tracker

(defun makel--register (buf)
  "Add BUF to the tracker; replace any previous entry with the same name."
  (setq makel--buffers
        (cons buf (cl-remove buf makel--buffers
                             :test (lambda (a b)
                                     (equal (buffer-name a) (buffer-name b))))))
  (force-mode-line-update t))

(defun makel--unregister ()
  "Drop the current buffer from the tracker (kill-buffer-hook target)."
  (setq makel--buffers (delq (current-buffer) makel--buffers))
  (force-mode-line-update t))

;;; Process plumbing

(defun makel--header (keys)
  "Header line for the current make buffer, ending with the KEYS hint."
  (propertize (format " make %s/%s %s  %s"
                      makel--project makel--target
                      (makel--status-glyph makel--status)
                      keys)
              'face 'makel-header-face))

(defun makel--sentinel (proc _event)
  "Record PROC's exit status; update header, mode line and keys."
  (when (and (memq (process-status proc) '(exit signal))
             (buffer-live-p (process-buffer proc)))
    (with-current-buffer (process-buffer proc)
      (let ((code (process-exit-status proc)))
        (setq-local makel--status (if (zerop code) 'ok (cons 'fail code))))
      (use-local-map makel-done-map)
      (setq buffer-read-only t)
      (setq header-line-format
            (makel--header (format "(%.1fs)  q close" (makel--elapsed))))
      (force-mode-line-update t)
      (message "make %s: %s" makel--target (makel--status-label makel--status))
      (when makel-mode-line-cleanup-delay
        (let ((buf (current-buffer)))
          (run-at-time makel-mode-line-cleanup-delay nil
                       (lambda ()
                         (when (buffer-live-p buf)
                           (setq makel--buffers (delq buf makel--buffers))
                           (force-mode-line-update t)))))))))

;;; Show buffer

(defun makel--show-buffer (buf)
  "Show BUF in another window."
  (pop-to-buffer buf))

;;; Spawn

(defun makel--spawn (buffer-name target project dir)
  "Run TARGET for PROJECT in DIR, using BUFFER-NAME for output."
  (when-let* ((old (get-buffer buffer-name)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer old)))
  (let* ((default-directory dir)
         (process-connection-type t)
         (buf (compilation-start
               (concat "make -- " (shell-quote-argument target)) t
               (lambda (_mode) buffer-name))))
    (with-current-buffer buf
      (setq-local makel--target target
                  makel--project project
                  makel--status 'running
                  makel--start-time (current-time))
      (setq header-line-format (makel--header "C-c C-c interrupt"))
      (local-set-key (kbd "C-c C-k") #'makel-kill-process)
      (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter nil t)
      (add-hook 'comint-output-filter-functions #'ansi-color-process-output nil t)
      (add-hook 'comint-output-filter-functions
                #'comint-watch-for-password-prompt nil t)
      (add-hook 'kill-buffer-hook #'makel--unregister nil t)
      (makel--register buf)
      (let* ((proc (get-buffer-process buf))
             (sentinel (process-sentinel proc)))
        (set-process-sentinel
         proc (lambda (process event)
                (funcall sentinel process event)
                (makel--sentinel process event)))))
    buf))

;;; Makefile parsing

(defconst makel--rule-regexp "^\\([^#\t\n][^:#=\n]*\\):"
  "Match a rule line, capturing every target it names before the colon.
One rule may name several targets, as in `major minor patch:'.
Assignments are excluded by `makel--targets'.")

(defun makel--own-target-p (target)
  "Is TARGET one make itself reads rather than one a user would pick?
Covers make's dot-targets (`.PHONY' and its like), pattern rules, and
targets spelled through a variable."
  (or (string-prefix-p "." target)
      (string-match-p "[%$]" target)))

(defun makel--targets (makefile)
  "Every target MAKEFILE offers, sorted and without repeats."
  (with-temp-buffer
    (insert-file-contents makefile)
    (cl-loop while (re-search-forward makel--rule-regexp nil t)
             unless (looking-at "[=:]*=")
             append (split-string (match-string 1) "[ \t]+" t) into ts
             finally (return (sort (cl-remove-if #'makel--own-target-p
                                                 (delete-dups ts))
                                   #'string<)))))

;;; Entry point

;;;###autoload
(defun makel-run ()
  "Pick a target from the dominating Makefile and run it."
  (interactive)
  (let* ((dir (or (locate-dominating-file default-directory "Makefile")
                  (user-error "No Makefile found above %s"
                              (abbreviate-file-name default-directory))))
         (default-directory dir)
         (makefile (expand-file-name "Makefile" dir))
         (targets (makel--targets makefile))
         (_ (unless targets (user-error "No targets in %s" makefile)))
         (target (completing-read "Make: " targets nil t))
         (project (file-name-base (directory-file-name dir)))
         (buf-name (format "*makel-%s-%s*" project target)))
    (makel--spawn buf-name target project dir)))

;;;###autoload
(defun makel-switch-buffer ()
  "Switch between tracked make buffers, showing status."
  (interactive)
  (setq makel--buffers (cl-remove-if-not #'buffer-live-p makel--buffers))
  (unless makel--buffers
    (user-error "No make buffers"))
  (let ((entries (cl-loop for buf in makel--buffers
                          collect (cons (with-current-buffer buf
                                         (format "%s/%s %s"
                                                 (or makel--project "?")
                                                 (or makel--target "?")
                                                 (makel--status-glyph makel--status)))
                                        buf))))
    (let* ((choice (completing-read "Make buffer: "
                                    (mapcar #'car entries) nil t))
           (buf (cdr (assoc choice entries))))
      (makel--show-buffer buf))))

;;; Transient

;;;###autoload
(transient-define-prefix makel-menu ()
  "Make commands."
  [["Make"
    ("m" "Run target"       makel-run)
    ("b" "Switch buffer"    makel-switch-buffer)]])

(provide 'makel)

;;; makel.el ends here
