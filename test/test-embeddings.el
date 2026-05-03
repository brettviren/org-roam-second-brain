;;; test-embeddings.el --- batch embedding smoke test -*- lexical-binding: t; -*-
;; Usage: emacs --init-directory=test --batch --load test/init.el --load test/test-embeddings.el

(require 'org-roam)
(require 'org-roam-vector-search)

(setq org-roam-directory             (expand-file-name "test/org"))
(setq org-roam-db-location           (expand-file-name "test/org/org-roam.db"))
(setq org-roam-semantic-db-location  (expand-file-name "test/org/org-roam-embeddings.db"))

(org-roam-db-sync)

(defun test-embed--node-id (node-entry)
  "Extract :ID: from a discover-nodes entry."
  (let* ((element (nth 0 node-entry))
         (level   (nth 2 node-entry)))
    (if (> level 0)
        (org-element-property :ID element)
      (org-element-map element 'node-property
        (lambda (np)
          (when (string= (org-element-property :key np) "ID")
            (org-element-property :value np)))
        nil t 'headline))))

(let ((total 0) (stored 0) (skipped 0))
  (dolist (file (org-roam-list-files))
    (let* ((title (org-roam-semantic--get-title file))
           (nodes (org-roam-semantic--discover-nodes file)))
      (message "--- %s (%d nodes)" (file-name-nondirectory file) (length nodes))
      (dolist (node-entry nodes)
        (cl-incf total)
        (let ((node-id (test-embed--node-id node-entry)))
          (when node-id
            (let* ((leading (org-roam-semantic--enforce-chunk-size
                             (org-roam-semantic--build-leading-chunk node-entry title)
                             node-id "leading"))
                   (full    (org-roam-semantic--enforce-chunk-size
                             (org-roam-semantic--build-full-chunk node-entry title)
                             node-id "full")))
              (if (not (or leading full))
                  (progn
                    (cl-incf skipped)
                    (message "    skip %s (too small)" node-id))
                (cl-incf stored)
                (when leading
                  (let ((v (org-roam-semantic--embed-query-sync leading)))
                    (if v
                        (progn
                          (org-roam-semantic--db-upsert-embedding node-id "leading" v)
                          (message "    stored %s/leading (%d dims)" node-id (length v)))
                      (message "    WARN nil vec %s/leading" node-id))))
                (when full
                  (let ((v (org-roam-semantic--embed-query-sync full)))
                    (if v
                        (progn
                          (org-roam-semantic--db-upsert-embedding node-id "full" v)
                          (message "    stored %s/full (%d dims)" node-id (length v)))
                      (message "    WARN nil vec %s/full" node-id)))))))))))
  (message "Summary: %d nodes, %d stored, %d skipped" total stored skipped))

(message "DB rows:")
(let* ((db   (org-roam-semantic--db-open))
       (rows (sqlite-select db
               "SELECT node_id, chunk_type FROM embeddings ORDER BY node_id, chunk_type")))
  (message "  %d rows total" (length rows))
  (dolist (r rows)
    (message "  %s / %s" (nth 0 r) (nth 1 r))))

(message "Errors buffer:")
(let ((b (get-buffer "*org-roam-semantic-errors*")))
  (if b
      (message "%s" (with-current-buffer b (buffer-string)))
    (message "  (none)")))
