;;; test-makel.el --- makel tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'makel)

(defconst makel-test--fixture
  (expand-file-name "Makefile.fixture" (file-name-directory load-file-name)))

(ert-deftest makel-targets ()
  (should (equal (makel--targets makel-test--fixture)
                 '("all" "last" "major" "minor" "patch"))))

(ert-deftest makel-target-at-eof ()
  (let ((file (make-temp-file "makel")))
    (unwind-protect
        (progn
          (write-region "target:" nil file nil 'silent)
          (should (equal (makel--targets file) '("target"))))
      (delete-file file))))

(ert-deftest makel-mode-line-toggle ()
  (let ((global-mode-string nil))
    (unwind-protect
        (progn
          (makel-mode-line-mode 1)
          (makel-mode-line-mode 1)
          (should (= 1 (length global-mode-string)))
          (makel-mode-line-mode -1)
          (should-not global-mode-string))
      (makel-mode-line-mode -1))))

(ert-deftest makel-interactive-compilation ()
  (let* ((dir (make-temp-file "makel-project" t))
         (makel-mode-line-cleanup-delay nil)
         (makel--buffers nil)
         (buf nil))
    (unwind-protect
        (progn
          (write-region "ask:\n\t@read answer; echo GOT:$$answer; echo 'sample.c:3:2: error: sample'; exit 1\n"
                        nil (expand-file-name "Makefile" dir) nil 'silent)
          (write-region "one
two
three
" nil (expand-file-name "sample.c" dir) nil 'silent)
          (setq buf (makel--spawn "*makel-test*" "ask" "test" (file-name-as-directory dir)))
          (with-current-buffer buf
            (let ((proc (get-buffer-process buf))
                  (deadline (+ (float-time) 10)))
              (should (process-tty-name proc))
              (process-send-string proc "hello\n")
              (while (and (process-live-p proc) (< (float-time) deadline))
                (accept-process-output proc 0.1))
              (should-not (process-live-p proc))
              (should (equal makel--status '(fail . 2)))
              (should buffer-read-only)
              (should (eq (lookup-key (current-local-map) "q") #'quit-window))
              (should (eq next-error-function #'compilation-next-error-function))
              (goto-char (point-min))
              (should (search-forward "GOT:hello" nil t))
              (let ((inhibit-read-only t))
                (compilation-parse-errors (point-min) (point-max)))
              (goto-char (point-min))
              (should (text-property-search-forward 'compilation-message))
              (compilation-next-error-function 1 t)
              (should (equal (buffer-file-name) (expand-file-name "sample.c" dir)))
              (should (= (line-number-at-pos) 3)))))
      (when (buffer-live-p buf)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))
      (when-let* ((source (get-file-buffer (expand-file-name "sample.c" dir))))
        (kill-buffer source))
      (delete-directory dir t))))
