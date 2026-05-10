;;; -*- lexical-binding: t; -*-
;;; org-roam-second-brain-hydra.el --- Hydra menus for org-roam-second-brain -*- lexical-binding: t; -*-

;; Hydra menus that mirror the C-c b key bindings defined in org-roam-second-brain.el.
;; Invoke the top-level menu with C-c b h (or call `sb/hydra/body' directly).

(require 'hydra)
(require 'org-roam-second-brain)

;;; Blog sub-menu

(defhydra sb/hydra-blog (:color blue :hint nil)
  "
Blog  (C-c b B)
_b_ new post    _l_ list      _d_ toggle draft
_i_ from idea   _o_ outline   _e_ expand section
_t_ edit tone   _r_ research  _p_ publish
_q_ quit
"
  ("b" sb/blog)
  ("l" sb/blog-list)
  ("d" sb/blog-set-draft)
  ("i" sb/blog-from-idea)
  ("o" sb/blog-generate-outline)
  ("e" sb/blog-expand-section)
  ("t" sb/blog-edit-tone)
  ("r" sb/blog-link-research)
  ("p" sb/blog-publish)
  ("q" nil))

;;; Daily sub-menu

(defhydra sb/hydra-daily (:color blue :hint nil)
  "
Daily  (C-c b D)
_l_ link current   _L_ link all   _c_ connections
_q_ quit
"
  ("l" sb/daily-link)
  ("L" sb/daily-link-all)
  ("c" sb/daily-connections)
  ("q" nil))

;;; Top-level menu

(defhydra sb/hydra (:color blue :hint nil)
  "
Second Brain  (C-c b)
 Create ──────────────────────────────────────────────────
  _p_ person   _P_ project   _i_ idea   _a_ admin   _I_ inbox
 List ────────────────────────────────────────────────────
  _l p_ projects   _l e_ people   _l i_ ideas   _l b_ blog
 Search ──────────────────────────────────────────────────
  _/_ search
 Surface ─────────────────────────────────────────────────
  _d_ digest   _f_ followups   _s_ stale   _u_ dangling
  _L_ suggest links   _w_ weekly
 Submenus ────────────────────────────────────────────────
  _B_ blog...   _D_ daily...
  _q_ quit
"
  ;; Create
  ("p"   sb/person)
  ("P"   sb/project)
  ("i"   sb/idea)
  ("a"   sb/admin)
  ("I"   sb/inbox)
  ;; List
  ("l p" sb/projects)
  ("l e" sb/people)
  ("l i" sb/ideas)
  ("l b" sb/blog-list)
  ;; Search
  ("/"   sb/search)
  ;; Surface
  ("d"   sb/digest)
  ("f"   sb/followups)
  ("s"   sb/stale)
  ("u"   sb/dangling)
  ("L"   sb/suggest-links)
  ("w"   sb/weekly)
  ;; Submenus — exit this hydra then open the sub-menu
  ("B"   sb/hydra-blog/body  :exit t)
  ("D"   sb/hydra-daily/body :exit t)
  ("q"   nil))

(global-set-key (kbd "C-c b h") 'sb/hydra/body)

(provide 'org-roam-second-brain-hydra)
;;; org-roam-second-brain-hydra.el ends here
