;;; init.el --- Standalone org-roam-second-brain environment -*- lexical-binding: t; -*-

;;; run with:
;;;   emacs --init-directory /path/to/org-roam-second-brain/test

(setq inhibit-startup-message t
      inhibit-startup-screen t)

;;; Bootstrap straight.el

(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name "straight/repos/straight.el/bootstrap.el"
                         user-emacs-directory))
      (bootstrap-version 7))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

(straight-use-package 'use-package)
(setq straight-use-package-by-default t)

;;; Paths

(defconst my/sb-package-dir
  (expand-file-name ".." user-emacs-directory)
  "Local org-roam-second-brain package directory.")

(defconst my/org-roam-dir
  (expand-file-name "org" my/sb-package-dir)
  "Directory for org-roam notes.")


;;; Ensure directories exist

(dolist (dir (list my/org-roam-dir
                   (expand-file-name "people"   my/org-roam-dir)
                   (expand-file-name "projects" my/org-roam-dir)
                   (expand-file-name "ideas"    my/org-roam-dir)
                   (expand-file-name "admin"    my/org-roam-dir)
                   (expand-file-name "blog"     my/org-roam-dir)
                   (expand-file-name "daily"    my/org-roam-dir)))
  (unless (file-exists-p dir)
    (make-directory dir t)))

;;; Packages

(use-package transient) ; org-roam → magit-section → transient; must precede org-roam

(use-package org)

(use-package org-roam
  :after org
  :custom
  (org-roam-directory my/org-roam-dir)
  (org-roam-db-location (expand-file-name "org-roam.db" my/org-roam-dir))
  (org-roam-dailies-directory "daily/")
  (org-roam-dailies-capture-templates
   '(("d" "default" entry
      "* %<%H:%M> %?"
      :target (file+head "%<%Y-%m-%d>.org"
                         "#+title: %<%Y-%m-%d>\n#+filetags: :daily:\n\n"))))
  :bind (("C-c n f" . org-roam-node-find)
         ("C-c n i" . org-roam-node-insert)
         ("C-c n l" . org-roam-buffer-toggle)
         ("C-c n c" . org-roam-capture)
         ("C-c n g" . org-roam-graph)
         ("C-c n d t" . org-roam-dailies-goto-today)
         ("C-c n d T" . org-roam-dailies-goto-tomorrow)
         ("C-c n d y" . org-roam-dailies-goto-yesterday)
         ("C-c n d d" . org-roam-dailies-capture-today)
         ("C-c n d Y" . org-roam-dailies-capture-yesterday)
         ("C-c n d r" . org-roam-dailies-goto-date)
         ("C-c n d n" . org-roam-dailies-goto-next-note)
         ("C-c n d p" . org-roam-dailies-goto-previous-note))
  :config
  (org-roam-db-autosync-mode 1))

(use-package org-roam-second-brain
  :straight nil
  :load-path my/sb-package-dir
  :after org-roam
  :custom
  (sb/show-digest-on-startup nil)
  ;; Point at your llama-server instance
  (org-roam-semantic-embedding-url "http://localhost:8080")
  ;; Match the model name exactly as llama-server reports it
  ;; find name with:
  ;; curl http://localhost:8080/v1/models|jq '.models.[0].name'
  (org-roam-semantic-embedding-model "nomic-embed-text-v1.5.Q8_0.gguf")

  ;; nomic-embed-text-v1.5 produces 768-dimensional vectors
  (org-roam-semantic-embedding-dimensions 768)
  ;; Tune similarity threshold to taste (0.0–1.0)
  (org-roam-semantic-similarity-cutoff 0.55)
  ;; Chunking tuning — sections smaller than this get IDs but no embedding
  (org-roam-semantic-min-chunk-size 100)
  (org-roam-semantic-max-chunk-size 1000)
  :config


  (require 'org-roam-vector-search)
  (require 'org-roam-api)
  (require 'org-roam-mcp-http))

(use-package consult-org-roam
  :after org-roam
  :bind ("C-c n s" . consult-org-roam-search)
  :config
  (consult-org-roam-mode 1))

;;; Completion — vertico replaces vanilla minibuffer which binds SPC to
;;; minibuffer-complete-word, making it impossible to type node names with spaces

(use-package vertico
  :init
  (vertico-mode 1))

;;; Built-ins

(use-package emacs
  :straight nil
  :custom
  (auto-revert-verbose nil)
  (revert-without-query '(".*\\.org\\'"))
  :hook
  (org-mode . auto-revert-mode)
  :config
  (when (display-graphic-p)
    (tool-bar-mode -1)
    (scroll-bar-mode -1))
  (menu-bar-mode -1)
  (column-number-mode 1))

(global-visual-line-mode)

(provide 'init)
;;; init.el ends here
