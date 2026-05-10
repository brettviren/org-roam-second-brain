;;; -*- lexical-binding: t; -*-
;;; org-roam-second-brain-transient.el --- Transient menus for org-roam-second-brain

;; Transient menus that mirror the C-c b key bindings defined in
;; org-roam-second-brain.el.  Invoke with C-c b t or `sb/transient'.

(require 'transient)
(require 'org-roam-second-brain)

;;; List sub-prefix

(transient-define-prefix sb/transient-list ()
  "List Second Brain nodes."
  ["List"
   ("p" "Projects" sb/projects)
   ("e" "People"   sb/people)
   ("i" "Ideas"    sb/ideas)
   ("b" "Blog"     sb/blog-list)])

;;; Blog sub-prefix

(transient-define-prefix sb/transient-blog ()
  "Blog commands."
  [["Create"
    ("b" "New post"       sb/blog)
    ("i" "From idea"      sb/blog-from-idea)
    ("p" "Publish"        sb/blog-publish)
    ("d" "Toggle draft"   sb/blog-set-draft)]
   ["Edit"
    ("o" "Generate outline" sb/blog-generate-outline)
    ("e" "Expand section"   sb/blog-expand-section)
    ("t" "Edit tone"        sb/blog-edit-tone)
    ("r" "Link research"    sb/blog-link-research)]
   ["Navigate"
    ("l" "List posts"     sb/blog-list)]])

;;; Daily sub-prefix

(transient-define-prefix sb/transient-daily ()
  "Daily note commands."
  ["Daily"
   ("l" "Link current"  sb/daily-link)
   ("L" "Link all"      sb/daily-link-all)
   ("c" "Connections"   sb/daily-connections)])

;;; Top-level prefix

(transient-define-prefix sb/transient ()
  "Second Brain  (C-c b)"
  [["Create"
    ("p" "Person"   sb/person)
    ("P" "Project"  sb/project)
    ("i" "Idea"     sb/idea)
    ("a" "Admin"    sb/admin)
    ("I" "Inbox"    sb/inbox)]
   ["Surface"
    ("d" "Digest"        sb/digest)
    ("f" "Followups"     sb/followups)
    ("s" "Stale"         sb/stale)
    ("u" "Dangling"      sb/dangling)
    ("L" "Suggest links" sb/suggest-links)
    ("w" "Weekly"        sb/weekly)]]
  [["Navigate"
    ("/" "Search"   sb/search)
    ("l" "List..."  sb/transient-list)
    ("B" "Blog..."  sb/transient-blog)
    ("D" "Daily..."  sb/transient-daily)]])

(global-set-key (kbd "C-c b t") 'sb/transient)

(provide 'org-roam-second-brain-transient)
;;; org-roam-second-brain-transient.el ends here
