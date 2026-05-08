;;; org-roam-vector-search.el --- Vector embeddings and AI assistance for org-roam -*- lexical-binding: t; -*-

;; Author: David Cruver <dcruver@users.noreply.github.com>
;; URL: https://github.com/dcruver/org-roam-second-brain
;; Version: 1.4.0
;; Package-Requires: ((emacs "27.1") (org-roam "2.2"))

;;; Commentary:
;; This package adds vector embedding support and direct AI integration to org-roam.
;; It stores embeddings as org properties and provides semantic similarity search.
;; Supports OpenAI-compatible APIs (vLLM, Infinity, etc.) for embeddings and generation.

;;; Code:

(require 'org-roam)
(require 'json)
(require 'url)
(require 'org)
(require 'ox-md)
(require 'cl-lib)
(require 'subr-x)

;;; Version

(defconst org-roam-semantic-version "1.4.0"
  "Version of the org-roam-semantic package suite.")

(defun org-roam-semantic-version ()
  "Display the version of org-roam-semantic."
  (interactive)
  (message "org-roam-semantic version %s" org-roam-semantic-version))

;;; Configuration

(defgroup org-roam-vector-search nil
  "Vector embeddings and semantic search for org-roam."
  :group 'org-roam
  :prefix "org-roam-semantic-")

(defcustom org-roam-semantic-embedding-url "http://localhost:8080/v1"
  "Base URL for embeddings API server (OpenAI-compatible).
This should point to your embedding service, including the API version path.
Common values:
- http://localhost:8080/v1 (llama.cpp or Infinity local)
- http://localhost:11434/v1 (Ollama local)"
  :type 'string
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-generation-url "http://localhost:8000/v1"
  "Base URL for text generation API server (OpenAI-compatible).
This should point to your LLM service. Common values:
- http://localhost:8000/v1 (vLLM local)
- http://localhost:11434 (Ollama local)"
  :type 'string
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-embedding-model "nomic-ai/nomic-embed-text-v1.5"
  "Model to use for generating embeddings.
Must be available in your embedding service.
Recommended models:
- nomic-ai/nomic-embed-text-v1.5 (Infinity default)
- nomic-embed-text (Ollama)
- BAAI/bge-base-en-v1.5 (good alternative)"
  :type 'string
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-generation-model "casperhansen/llama-3.3-70b-instruct-awq"
  "Model to use for text generation and AI assistance.
Must be available in your LLM service.
Popular models:
- casperhansen/llama-3.3-70b-instruct-awq (vLLM)
- llama3.1:8b (Ollama)
- qwen2.5:7b (Ollama alternative)"
  :type 'string
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-embedding-dimensions 768
  "Number of dimensions in the embedding vectors.
This should match your embedding model:
- nomic-embed-text: 768
- all-minilm: 384
- mxbai-embed-large: 1024
Change this only if you switch embedding models."
  :type 'integer
  :group 'org-roam-vector-search)

;; Chunking is now always enabled for optimal semantic search performance

(defcustom org-roam-semantic-min-chunk-size 100
  "Minimum word count for a section to get its own embedding.
Sections smaller than this will not have embeddings generated."
  :type 'integer
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-max-chunk-size 1000
  "Maximum word count for a single chunk.
Sections longer than this will be split into smaller chunks."
  :type 'integer
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-similarity-cutoff 0.55
  "Similarity cutoff threshold for related notes.
Notes with similarity below this threshold will be excluded from results.
Higher values (closer to 1.0) mean more similar notes only."
  :type 'float
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-clean-old-properties nil
  "When non-nil, strip legacy EMBEDDING properties from org files during processing.
This is a transition aid for users migrating from property-based embedding
storage to the SQLite backend.  When nil, old EMBEDDING properties are silently
ignored.  When t, any EMBEDDING property found in a file being processed is
deleted from that file."
  :type 'boolean
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-result-limit 10
  "Default maximum number of results returned by semantic search functions."
  :type 'integer
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-db-location nil
  "Path to the embeddings SQLite database.
When nil, defaults to org-roam-embeddings.db in the same directory as
`org-roam-db-location'."
  :type '(choice (const :tag "Default" nil) file)
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-sqlite-vec-path nil
  "Path to the sqlite-vec extension shared library, or nil to skip loading it.
When set, the extension is loaded on DB open; if loading fails, the system
falls back to TEXT storage silently."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'org-roam-vector-search)

(defcustom org-roam-semantic-update-on-save t
  "When non-nil, automatically reindex the current org-roam file after saving.
Uses the async embedding pipeline; only nodes whose file hash changed are
re-embedded.  Set to nil to disable auto-indexing."
  :type 'boolean
  :group 'org-roam-vector-search)

;;; Utility Functions

(defun org-roam-semantic-get-similar-data (query-text &optional limit cutoff)
  "Get similarity data programmatically.
Returns list of (file similarity position heading-text) tuples.
Searches chunks within files when chunking is enabled.
If CUTOFF is provided, filters results to only include similarities above that threshold."
  (let ((limit (or limit 10))
        (cutoff (or cutoff 0.0))
        (similarities '()))
    ;; Generate embedding for query
    (let ((query-embedding (org-roam-ai-generate-embedding query-text)))
      (if query-embedding
          (progn
            ;; Compare with all notes that have embeddings
            (dolist (file (org-roam-list-files))
              ;; Search chunks within file
              (let ((all-embeddings (org-roam-semantic--get-all-embeddings file)))
                (dolist (chunk all-embeddings)
                  (let* ((position (nth 0 chunk))
                         (heading-text (nth 1 chunk))
                         (embedding (nth 2 chunk))
                         (similarity (org-roam-semantic--cosine-similarity query-embedding embedding)))
                    (when (and similarity (>= similarity cutoff))
                      (push (list file similarity position heading-text) similarities))))))
            ;; Sort by similarity and take top results
            (setq similarities (sort similarities (lambda (a b) (> (cadr a) (cadr b)))))
            (if (> (length similarities) limit)
                (butlast similarities (- (length similarities) limit))
              similarities))
        (message "Failed to generate embedding for query")
        nil))))

(defun org-roam-semantic--normalize-text (text)
  "Normalize text for embedding by removing extra whitespace and formatting."
  (when text
    (let ((normalized (replace-regexp-in-string "[ \t\n\r]+" " " text)))
      (string-trim normalized))))

(defun org-roam-semantic--get-content (file)
  "Extract content including title, properly skipping all front matter."
  (with-temp-buffer
    (insert-file-contents file)

    (let (title content)
      ;; Extract title
      (goto-char (point-min))
      (when (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
        (setq title (match-string 1)))

      ;; Skip to after properties drawer
      (goto-char (point-min))
      (when (re-search-forward "^:END:" nil t)
        (forward-line 1))

      ;; Skip ALL keyword lines (#+title:, #+filetags:, etc.)
      (while (and (not (eobp))
                  (looking-at "^#\\+[a-zA-Z_-]+:"))
        (forward-line 1))

      ;; Skip blank lines
      (while (and (not (eobp))
                  (looking-at "^\\s-*$"))
        (forward-line 1))

      ;; Get actual content
      (setq content (buffer-substring-no-properties (point) (point-max)))

      (org-roam-semantic--normalize-text
       (if title
           (concat title ". " content)
         content)))))

(defun org-roam-semantic--vector-magnitude (vector)
  "Calculate the magnitude of a vector."
  (sqrt (apply '+ (mapcar (lambda (x) (* x x)) vector))))

(defun org-roam-semantic--cosine-similarity (vec1 vec2)
  "Calculate cosine similarity between two vectors."
  (condition-case err
      (when (and vec1 vec2
                 (listp vec1) (listp vec2)
                 (= (length vec1) (length vec2))
                 (> (length vec1) 0))
        (let* ((dot-product 0.0)
               (mag1-sq 0.0)
               (mag2-sq 0.0)
               (valid-count 0))
          ;; Calculate dot product and magnitudes in one pass
          (dotimes (i (length vec1))
            (let ((v1 (nth i vec1))
                  (v2 (nth i vec2)))
              (when (and (numberp v1) (numberp v2))
                (setq dot-product (+ dot-product (* v1 v2)))
                (setq mag1-sq (+ mag1-sq (* v1 v1)))
                (setq mag2-sq (+ mag2-sq (* v2 v2)))
                (setq valid-count (1+ valid-count)))))
          ;; Only calculate if we have valid numbers
          (when (> valid-count 0)
            (let ((mag1 (sqrt mag1-sq))
                  (mag2 (sqrt mag2-sq)))
              (if (or (zerop mag1) (zerop mag2))
                  0.0
                (/ dot-product (* mag1 mag2)))))))
    (error
     (message "Error in cosine similarity calculation: %s" err)
     nil)))

;;; Chunking Functions

(defun org-roam-semantic--headline-ancestors (headline)
  "Return ancestor headline elements of HEADLINE, outermost first."
  (let ((ancestors '())
        (parent (org-element-property :parent headline)))
    (while parent
      (when (eq (org-element-type parent) 'headline)
        (push parent ancestors))
      (setq parent (org-element-property :parent parent)))
    ancestors))

(defun org-roam-semantic--discover-nodes (file)
  "Return all org-roam nodes in FILE as list of (element position level ancestors).
Nodes are org-roam headings (with :ID: property) plus the file itself if it
has a top-level :ID: before the first heading. File-level entries have level 0
and nil ancestors. Headline entries carry their ancestor chain for breadcrumbs."
  (with-temp-buffer
    (insert-file-contents file)
    (delay-mode-hooks (org-mode))
    (let* ((tree (org-element-parse-buffer))
           (nodes '()))
      ;; File-level node: :ID: in the section before the first headline.
      ;; no-recursion='headline ensures we only look in the preamble section.
      (let ((file-id (org-element-map tree 'node-property
                       (lambda (np)
                         (when (string= (org-element-property :key np) "ID")
                           (org-element-property :value np)))
                       nil t 'headline)))
        (when file-id
          (push (list tree 1 0 nil) nodes)))
      ;; Headline nodes at any depth
      (org-element-map tree 'headline
        (lambda (hl)
          (when (org-element-property :ID hl)
            (push (list hl
                        (org-element-property :begin hl)
                        (org-element-property :level hl)
                        (org-roam-semantic--headline-ancestors hl))
                  nodes))))
      (nreverse nodes))))

(defun org-roam-semantic--file-title (tree)
  "Return the #+title: string from parse TREE, or nil if absent."
  (org-element-map tree 'keyword
    (lambda (kw)
      (when (string= (org-element-property :key kw) "TITLE")
        (string-trim (org-element-property :value kw))))
    nil t))

(defun org-roam-semantic--node-body-text (element)
  "Return pre-child body text of ELEMENT (headline or org-data), or nil.
Excludes property drawers, planning lines, keyword lines, and clock entries."
  (let* ((first-child (car (org-element-contents element)))
         (section (when (eq (org-element-type first-child) 'section)
                    first-child)))
    (when section
      (let* ((body-elements
              (cl-remove-if
               (lambda (elt)
                 (memq (org-element-type elt)
                       '(property-drawer planning keyword comment clock)))
               (org-element-contents section)))
             (text (string-trim
                    (substring-no-properties
                     (mapconcat #'org-element-interpret-data body-elements "")))))
        (when (not (string-empty-p text)) text)))))

(defun org-roam-semantic--build-leading-chunk (node-entry file-title)
  "Return 'leading' chunk text for NODE-ENTRY.
NODE-ENTRY is a (element position level ancestors) list from
`org-roam-semantic--discover-nodes'. FILE-TITLE is the #+title: string or nil.
Format: 'FileTitle. AncestorTitle. NodeTitle. [pre-child body text]'"
  (let* ((element (nth 0 node-entry))
         (ancestors (nth 3 node-entry))
         (is-file-level (eq (org-element-type element) 'org-data))
         (breadcrumb-parts
          (append
           (when file-title (list file-title))
           (mapcar #'org-roam-semantic--normalize-headline-text ancestors)
           (unless is-file-level
             (list (org-roam-semantic--normalize-headline-text element)))))
         (breadcrumb (mapconcat (lambda (s) (concat s ". ")) breadcrumb-parts ""))
         (body (org-roam-semantic--node-body-text element)))
    (string-trim (if body (concat breadcrumb body) breadcrumb))))

(defun org-roam-semantic--build-full-chunk (node-entry file-title)
  "Return 'full' chunk text for NODE-ENTRY.
NODE-ENTRY is a (element position level ancestors) list from
`org-roam-semantic--discover-nodes'. FILE-TITLE is the #+title: string or nil.
Equals the leading chunk plus all descendant headline titles and their bodies."
  (let* ((element (nth 0 node-entry))
         (leading (org-roam-semantic--build-leading-chunk node-entry file-title))
         (descendant-parts
          (org-element-map (org-element-contents element) 'headline
            (lambda (hl)
              (let* ((title (org-roam-semantic--normalize-headline-text hl))
                     (body (org-roam-semantic--node-body-text hl)))
                (if (and body (not (string-empty-p body)))
                    (concat title ". " body)
                  (concat title "."))))))
         (descendant-text (mapconcat #'identity descendant-parts " ")))
    (string-trim
     (if (string-empty-p descendant-text)
         leading
       (concat leading " " descendant-text)))))

(defun org-roam-semantic--normalize-headline-text (headline)
  "Return clean title text from org-element HEADLINE node.
TODO keywords, priority cookies, and tags are separate org-element properties
and are never part of :title, so only timestamps need explicit removal."
  (let* ((title (org-element-property :title headline))
         (no-timestamps (cl-remove-if
                         (lambda (elt)
                           (and (listp elt)
                                (eq (org-element-type elt) 'timestamp)))
                         title))
         (text (string-trim
                (substring-no-properties
                 (org-element-interpret-data no-timestamps)))))
    text))

(defun org-roam-semantic--count-words (text)
  "Count words in TEXT."
  (length (split-string (org-roam-semantic--normalize-text text) "\\s-+" t)))

(defun org-roam-semantic--enforce-chunk-size (text node-id chunk-type)
  "Enforce word-count limits on TEXT for NODE-ID's CHUNK-TYPE chunk.
Returns nil if TEXT is below `org-roam-semantic-min-chunk-size', logging a
warning.  Returns TEXT truncated to `org-roam-semantic-max-chunk-size' words
if it exceeds the maximum, logging a warning.  Otherwise returns TEXT as-is."
  (let ((word-count (org-roam-semantic--count-words text)))
    (cond
     ((< word-count org-roam-semantic-min-chunk-size)
      (org-roam-semantic--log-error
       "Skipping %s chunk for %s: %d words below minimum %d"
       chunk-type node-id word-count org-roam-semantic-min-chunk-size)
      nil)
     ((> word-count org-roam-semantic-max-chunk-size)
      (org-roam-semantic--log-error
       "Truncating %s chunk for %s: %d words exceeds maximum %d"
       chunk-type node-id word-count org-roam-semantic-max-chunk-size)
      (mapconcat #'identity
                 (seq-take (split-string text "\\s-+" t)
                           org-roam-semantic-max-chunk-size)
                 " "))
     (t text))))

(defun org-roam-semantic--generate-chunk-id ()
  "Generate a unique ID for a chunk."
  (org-id-new))

(defun org-roam-semantic--parse-chunks (file)
  "Parse FILE and return list of chunks with metadata.
Returns list of (position heading-text content word-count level)."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let ((chunks '())
          (file-title nil))

      ;; Get file title for file-level chunk
      (goto-char (point-min))
      (when (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
        (setq file-title (match-string 1)))

      ;; Use org-mode outline navigation instead of org-map-entries
      (goto-char (point-min))
      (message "Debug Parse: Starting manual heading scan...")
      (let ((heading-count 0))
        (while (re-search-forward "^\\*+ " nil t)
          (save-excursion
            (beginning-of-line)
            (when (org-at-heading-p)
              (cl-incf heading-count)
              (let* ((heading-pos (point))
                     (heading-components (org-heading-components))
                     (heading-text (nth 4 heading-components))
                     (level (nth 0 heading-components))
                     (content-start (progn
                                      (forward-line 1)
                                      (point)))
                     (content-end (save-excursion
                                    (if (outline-next-heading)
                                        (point)
                                      (point-max))))
                     (content (buffer-substring-no-properties content-start content-end))
                     (full-content (concat heading-text ". " content))
                     (word-count (org-roam-semantic--count-words full-content)))

                ;; Debug: Show all sections found
                (message "Debug Parse: Found section '%s' at pos %d with %d words (level %d)"
                         heading-text heading-pos word-count level)

                ;; Include all chunks - mark those below threshold differently
                (if (>= word-count org-roam-semantic-min-chunk-size)
                    (progn
                      (message "Debug Parse: INCLUDING '%s' (%d words >= %d minimum)"
                               heading-text word-count org-roam-semantic-min-chunk-size)
                      (push (list heading-pos heading-text full-content word-count level :embedding) chunks))
                  (progn
                    (message "Debug Parse: INCLUDING (ID-only) '%s' (%d words < %d minimum)"
                             heading-text word-count org-roam-semantic-min-chunk-size)
                    (push (list heading-pos heading-text full-content word-count level :id-only) chunks)))))))
        (message "Debug Parse: Manual scan completed, found %d headings" heading-count))



      (nreverse chunks))))

(defun org-roam-semantic--get-chunk-content (file position)
  "Get the content for a chunk at POSITION in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char position)
    (if (= position (point-min))
        ;; File-level chunk
        (org-roam-semantic--get-content file)
      ;; Section-level chunk
      (let* ((level (save-excursion
                      (when (looking-at "^\\(\\*+\\)")
                        (length (match-string 1)))))
             (heading-text (save-excursion
                             (when (looking-at "^\\*+\\s-+\\(.+\\)$")
                               (match-string 1))))
             (content-start (progn (forward-line 1) (point)))
             (content-end (progn
                            (if (re-search-forward (format "^\\*\\{1,%d\\}\\s-" level) nil t)
                                (match-beginning 0)
                              (point-max))))
             (content (buffer-substring-no-properties content-start content-end)))
        (concat heading-text ". " content)))))

;;; OpenAI-Compatible API Functions

(defun org-roam-semantic--parse-embedding-openai (data)
  "Extract a float list from an OpenAI-format embedding response DATA.
Expected shape: {\"data\": [{\"embedding\": [...]}]}"
  (let* ((arr   (cdr (assoc 'data data)))
         (first (if (vectorp arr) (aref arr 0) (car arr)))
         (emb   (cdr (assoc 'embedding first))))
    (when emb
      (if (vectorp emb) (append emb nil) emb))))

(defun org-roam-semantic--parse-embedding-llamacpp (data)
  "Extract a float list from a llama.cpp-format embedding response DATA.
Expected shape: [{\"index\": 0, \"embedding\": [[...]]}]
The top level is an array; the embedding value is itself a 1-element array
wrapping the float vector."
  (let* ((first (if (vectorp data) (aref data 0) (car data)))
         (outer (cdr (assoc 'embedding first)))
         (emb   (if (vectorp outer) (aref outer 0) (car outer))))
    (when emb
      (if (vectorp emb) (append emb nil) emb))))

(defun org-roam-semantic--parse-embedding-response (data)
  "Extract a float list from embedding API response DATA.
Dispatches to the correct parser by inspecting the top-level JSON type:
a vector indicates llama.cpp native format; an alist indicates OpenAI format."
  (if (vectorp data)
      (org-roam-semantic--parse-embedding-llamacpp data)
    (org-roam-semantic--parse-embedding-openai data)))

(defun org-roam-ai-generate-embedding (text)
  "Call the embeddings API synchronously and return a float list.
Handles both OpenAI-compatible and llama.cpp native response formats."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data (encode-coding-string
                           (json-encode `((model . ,org-roam-semantic-embedding-model)
                                         (input . ,text)))
                           'utf-8))
        (url (concat org-roam-semantic-embedding-url "/embeddings")))
    (condition-case err
        (with-current-buffer (url-retrieve-synchronously url)
          (goto-char (point-min))
          (re-search-forward "^$" nil 'move)
          (let* ((json-response (decode-coding-string
                                 (buffer-substring (point) (point-max)) 'utf-8))
                 (data (json-read-from-string json-response))
                 (embedding (org-roam-semantic--parse-embedding-response data)))
            (kill-buffer (current-buffer))
            embedding))
      (error
       (message "Error calling embeddings API: %s" err)
       nil))))

(defun org-roam-ai-generate-text (prompt &optional system-prompt)
  "Call OpenAI-compatible chat completions API synchronously.
Works with vLLM, OpenAI, and other compatible services."
  (let* ((messages (if system-prompt
                       `[((role . "system") (content . ,system-prompt))
                         ((role . "user") (content . ,prompt))]
                     `[((role . "user") (content . ,prompt))]))
         (url-request-method "POST")
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (encode-coding-string
                            (json-encode `((model . ,org-roam-semantic-generation-model)
                                         (messages . ,messages)
                                         (stream . :json-false)))
                            'utf-8))
         (url (concat org-roam-semantic-generation-url "/chat/completions")))
    (condition-case err
        (with-current-buffer (url-retrieve-synchronously url)
          (goto-char (point-min))
          (re-search-forward "^$" nil 'move)
          (let* ((json-response (decode-coding-string
                                (buffer-substring (point) (point-max)) 'utf-8))
                 (data (json-read-from-string json-response))
                 ;; OpenAI format: {"choices": [{"message": {"content": "..."}}]}
                 (choices (cdr (assoc 'choices data)))
                 (first-choice (if (vectorp choices) (aref choices 0) (car choices)))
                 (message-obj (cdr (assoc 'message first-choice)))
                 (content (cdr (assoc 'content message-obj))))
            (kill-buffer (current-buffer))
            content))
      (error
       (message "Error calling chat API: %s" err)
       nil))))

;;; Embedding Storage and Retrieval
(defun org-roam-semantic--store-embedding (file embedding &optional identifier)
  "Store EMBEDDING vector in FILE at location specified by IDENTIFIER.
If IDENTIFIER is nil, stores at file level.
If IDENTIFIER is a string, finds heading by that text.
If IDENTIFIER is a number, treats it as a position.
Does NOT call `save-buffer` (so it is safe in save hooks)."
  (when embedding
    (with-current-buffer (find-file-noselect file)
      (require 'org)
      (save-excursion
        (org-with-wide-buffer
          (if identifier
              ;; Store at heading level - find heading by identifier
              (progn
                (cond
                 ;; String identifier - search by heading text
                 ((stringp identifier)
                  (goto-char (point-min))
                  (unless (re-search-forward (format "^\\*+\\s-+%s\\s-*$" (regexp-quote identifier)) nil t)
                    (error "Cannot find heading with text: %s" identifier))
                  (beginning-of-line))
                 ;; Numeric identifier - go to position
                 ((numberp identifier)
                  (goto-char identifier)
                  (beginning-of-line)
                  (unless (looking-at "^\\*")
                    (error "Position %d is not at a heading" identifier)))
                 (t
                  (error "Invalid identifier type: %s" identifier)))
                ;; Ensure heading has an ID
                (unless (org-entry-get (point) "ID")
                  (org-entry-put (point) "ID" (org-roam-semantic--generate-chunk-id)))
                ;; Store embedding
                (org-entry-put (point) "EMBEDDING"
                               (mapconcat (lambda (x) (format "%.6f" x)) embedding " "))
                ;; Mark buffer as modified to ensure save hooks trigger
                (set-buffer-modified-p t))
            ;; Store at file level
            (progn
              (goto-char (point-min))
              ;; Ensure a file-level property drawer exists
              (unless (org-get-property-block) (org-insert-property-drawer))
              ;; Replace the property value at the file level
              (org-entry-put (point) "EMBEDDING"
                             (mapconcat (lambda (x) (format "%.6f" x)) embedding " "))
              ;; Mark buffer as modified to ensure save hooks trigger
              (set-buffer-modified-p t))))
      ;; IMPORTANT: do NOT call (save-buffer) here
      ))))

(defun org-roam-semantic--ensure-heading-id (file heading-text)
  "Ensure HEADING-TEXT in FILE has an ID property, even without embedding.
This allows short sections to get IDs for future expansion."
  (with-current-buffer (find-file-noselect file)
    (require 'org)
    (save-excursion
      (org-with-wide-buffer
        (goto-char (point-min))
        (when (re-search-forward (format "^\\*+\\s-+%s\\s-*$" (regexp-quote heading-text)) nil t)
          (beginning-of-line)
          ;; Only add ID if one doesn't exist
          (unless (org-entry-get (point) "ID")
            (org-entry-put (point) "ID" (org-roam-semantic--generate-chunk-id))
            (message "Added ID to short section: %s" heading-text)
            ;; Mark buffer as modified
            (set-buffer-modified-p t)))))))

(defun org-roam-semantic--get-embedding (file &optional position)
  "Retrieve embedding vector from FILE at POSITION.
If POSITION is nil, gets file-level embedding.
If POSITION is specified, gets embedding from heading at that position."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (goto-char (or position (point-min)))
    (when (re-search-forward "^[ \t]*:EMBEDDING:[ \t]*\\(.*\\)$"
                             (if position
                                 (save-excursion
                                   (forward-line 10) ; Look within property drawer
                                   (point))
                               nil) t)
      (let ((embedding-str (match-string 1)))
        (when (and embedding-str (not (string-empty-p embedding-str)))
          (condition-case err
              (mapcar 'string-to-number (split-string embedding-str))
            (error
             (message "Error parsing embedding in %s: %s" (file-name-nondirectory file) err)
             nil)))))))

(defun org-roam-semantic--get-all-embeddings (file)
  "Retrieve all embeddings from FILE.
Returns list of (position heading-text embedding) tuples."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let ((embeddings '())
          (file-title nil))

      ;; Get file title
      (goto-char (point-min))
      (when (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
        (setq file-title (match-string 1)))

      ;; Check for file-level embedding
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*:EMBEDDING:[ \t]*\\(.*\\)$" nil t)
        (let ((embedding-str (match-string 1)))
          (when (and embedding-str (not (string-empty-p embedding-str)))
            (condition-case err
                (let ((embedding (mapcar 'string-to-number (split-string embedding-str))))
                  (push (list (point-min) (or file-title "File") embedding) embeddings))
              (error
               (message "Error parsing file-level embedding: %s" err))))))

      ;; Find all heading-level embeddings
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\*+\\)\\s-+\\(.+\\)$" nil t)
        (let* ((heading-pos (match-beginning 0))
               (heading-text (match-string 2))
               (property-end (save-excursion
                               (forward-line 1)
                               (when (looking-at "^[ \t]*:PROPERTIES:")
                                 (re-search-forward "^[ \t]*:END:" nil t)
                                 (point)))))
          (when property-end
            (save-excursion
              (goto-char heading-pos)
              (when (re-search-forward "^[ \t]*:EMBEDDING:[ \t]*\\(.*\\)$" property-end t)
                (let ((embedding-str (match-string 1)))
                  (when (and embedding-str (not (string-empty-p embedding-str)))
                    (condition-case err
                        (let ((embedding (mapcar 'string-to-number (split-string embedding-str))))
                          (push (list heading-pos heading-text embedding) embeddings))
                      (error
                       (message "Error parsing embedding for %s: %s" heading-text err))))))))))

      (nreverse embeddings))))

(defun org-roam-semantic--has-embedding-p (file)
  "Check if note already has chunk embeddings."
  (not (null (org-roam-semantic--get-all-embeddings file))))

(defun org-roam-semantic--remove-embedding-properties (file)
  "Delete all :EMBEDDING: properties from FILE when `org-roam-semantic-clean-old-properties' is t."
  (when org-roam-semantic-clean-old-properties
    (with-current-buffer (find-file-noselect file)
      (require 'org)
      (save-excursion
        (org-with-wide-buffer
          (goto-char (point-min))
          (while (re-search-forward "^[ \t]*:EMBEDDING:[ \t]*.*\n?" nil t)
            (replace-match "")
            (set-buffer-modified-p t)))))))

;;;###autoload
(defun org-roam-semantic-clean-properties ()
  "Remove all :EMBEDDING: properties from every org-roam file.
Scans all files tracked by org-roam, prompts for confirmation, then
deletes legacy EMBEDDING property lines left from the old property-based
storage backend.  Saves each modified file and reports how many files and
property entries were cleaned."
  (interactive)
  (let ((files (org-roam-list-files))
        (files-to-clean '())
        (total-count 0))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((count 0))
          (goto-char (point-min))
          (while (re-search-forward "^[ \t]*:EMBEDDING:[ \t]*.*$" nil t)
            (cl-incf count))
          (when (> count 0)
            (push (cons file count) files-to-clean)
            (cl-incf total-count count)))))
    (if (null files-to-clean)
        (message "No :EMBEDDING: properties found.")
      (when (yes-or-no-p
             (format "Remove %d :EMBEDDING: propert%s across %d file%s? "
                     total-count (if (= total-count 1) "y" "ies")
                     (length files-to-clean)
                     (if (= (length files-to-clean) 1) "" "s")))
        (let ((cleaned-files 0)
              (cleaned-props 0))
          (dolist (pair files-to-clean)
            (let ((file (car pair))
                  (count 0))
              (with-current-buffer (find-file-noselect file)
                (save-excursion
                  (org-with-wide-buffer
                    (goto-char (point-min))
                    (while (re-search-forward "^[ \t]*:EMBEDDING:[ \t]*.*\n?" nil t)
                      (replace-match "")
                      (cl-incf count))))
                (when (> count 0)
                  (save-buffer)
                  (cl-incf cleaned-files)
                  (cl-incf cleaned-props count)))))
          (message "Cleaned %d :EMBEDDING: propert%s from %d file%s."
                   cleaned-props (if (= cleaned-props 1) "y" "ies")
                   cleaned-files (if (= cleaned-files 1) "" "s")))))))

;;; Main Embedding Functions

(defvar org-roam-semantic--embed-queue nil
  "Queue of (node-id chunk-type text) triples pending async embedding generation.")

(defvar org-roam-semantic--embed-running nil
  "Non-nil while an async embedding HTTP request is in-flight.")

(defun org-roam-semantic--embed-enqueue (node-id chunk-type text)
  "Append (NODE-ID CHUNK-TYPE TEXT) to the queue and drain if idle."
  (setq org-roam-semantic--embed-queue
        (nconc org-roam-semantic--embed-queue (list (list node-id chunk-type text))))
  (org-roam-semantic--embed-drain))

(defun org-roam-semantic--embed-drain ()
  "Start processing the next queued item if no request is in-flight."
  (when (and org-roam-semantic--embed-queue
             (not org-roam-semantic--embed-running))
    (let* ((item (pop org-roam-semantic--embed-queue))
           (node-id (nth 0 item))
           (chunk-type (nth 1 item))
           (text (nth 2 item))
           (url-request-method "POST")
           (url-request-extra-headers '(("Content-Type" . "application/json")))
           (url-request-data (encode-coding-string
                              (json-encode `((model . ,org-roam-semantic-embedding-model)
                                             (input . ,text)))
                              'utf-8))
           (url (concat org-roam-semantic-embedding-url "/embeddings")))
      (setq org-roam-semantic--embed-running t)
      (url-retrieve url
                    (lambda (status)
                      (org-roam-semantic--embed-callback status node-id chunk-type))
                    nil 'silent))))

(defun org-roam-semantic--embed-callback (status node-id chunk-type)
  "Handle HTTP response for NODE-ID / CHUNK-TYPE.
STATUS is the plist from url-retrieve; current buffer is the response buffer."
  (unwind-protect
      (condition-case err
          (progn
            (when (plist-get status :error)
              (error "HTTP error: %s" (plist-get status :error)))
            (goto-char (point-min))
            (re-search-forward "^$" nil 'move)
            (let* ((json-response (decode-coding-string
                                   (buffer-substring (point) (point-max)) 'utf-8))
                   (data (json-read-from-string json-response))
                   (embedding (org-roam-semantic--parse-embedding-response data)))
              (when embedding
                (org-roam-semantic--db-upsert-embedding node-id chunk-type embedding))))
        (error
         (org-roam-semantic--log-error "Async embed failed for %s/%s: %s"
                                        node-id chunk-type err)))
    (kill-buffer (current-buffer))
    (setq org-roam-semantic--embed-running nil)
    (org-roam-semantic--embed-drain)))

(defun org-roam-semantic--embed-query-sync (query-text)
  "Generate embedding for QUERY-TEXT synchronously.
Uses url-retrieve-synchronously; appropriate for interactive search queries
where the user is already waiting.  This is the designated query path,
separate from the async pipeline used for indexing."
  (org-roam-ai-generate-embedding query-text))

(defun org-roam-semantic--generate-embedding (text)
  "Generate embedding for text synchronously."
  (org-roam-ai-generate-embedding text))

;;;###autoload
(defun org-roam-semantic-generate-embedding (file)
  "Generate and store chunk embeddings for a single note."
  (interactive (list (buffer-file-name)))
  (unless file
    (error "No file associated with current buffer"))
  (org-roam-semantic-generate-chunks-for-file file))

;;;###autoload
(defun org-roam-semantic-generate-chunks-for-file (file)
  "Generate embeddings for all chunks in FILE."
  (interactive (list (buffer-file-name)))
  (unless file
    (error "No file associated with current buffer"))
  (org-roam-semantic--remove-embedding-properties file)
  (let* ((chunks (org-roam-semantic--parse-chunks file))
         (total (length chunks))
         (processed 0)
         (skipped 0))
    (message "Generating embeddings for %d chunks in %s..." total (file-name-nondirectory file))

    (dolist (chunk chunks)
      (let* ((position (nth 0 chunk))
             (heading-text (nth 1 chunk))
             (content (nth 2 chunk))
             (word-count (nth 3 chunk))
             (level (nth 4 chunk))
             (chunk-type (nth 5 chunk))
             (existing-embedding (org-roam-semantic--get-embedding file position)))

        (message "Debug: Chunk '%s' at position %d with %d words (type: %s)" heading-text position word-count chunk-type)

        (cond
         ;; ID-only chunks - just ensure they have an ID
         ((eq chunk-type :id-only)
          (org-roam-semantic--ensure-heading-id file heading-text)
          (cl-incf processed)
          (message "Added ID to short section: %s [%d/%d]" heading-text (+ processed skipped) total))

         ;; Embedding chunks - check if already has embedding
         (existing-embedding
          (cl-incf skipped)
          (message "Skipping %s (already has embedding) [%d/%d]" heading-text (+ processed skipped) total))

         ;; Embedding chunks without embeddings - generate them
         (t
          (cl-incf processed)
          (message "Processing %s [%d/%d]..." heading-text (+ processed skipped) total)
          (condition-case err
              (let ((embedding (org-roam-ai-generate-embedding content)))
                (if embedding
                    (progn
                      (org-roam-semantic--store-embedding file embedding heading-text)
                      (message "Successfully stored embedding for %s" heading-text))
                  (message "Failed to generate embedding for %s" heading-text)))
            (error
             (message "Error processing %s: %s" heading-text (error-message-string err))))))))

    (message "Chunk embedding generation complete for %s: %d processed, %d skipped"
             (file-name-nondirectory file) processed skipped)))

;;;###autoload
(defun org-roam-semantic-generate-all-embeddings ()
  "Generate chunk embeddings for all org-roam notes that don't have them."
  (interactive)
  (org-roam-semantic-generate-all-chunks))

;;;###autoload
(defun org-roam-semantic-generate-all-chunks ()
  "Generate chunk embeddings for all org-roam notes."
  (interactive)

  (let* ((files (org-roam-list-files))
         (total-files (length files))
         (file-count 0)
         (total-chunks 0)
         (processed-chunks 0)
         (skipped-chunks 0))

    (message "Starting chunk embedding generation for %d files..." total-files)

    (dolist (file files)
      (cl-incf file-count)
      (message "Processing file %d/%d: %s" file-count total-files (file-name-nondirectory file))

      (let* ((chunks (org-roam-semantic--parse-chunks file))
             (file-chunk-count (length chunks)))
        (cl-incf total-chunks file-chunk-count)

        (dolist (chunk chunks)
          (let* ((position (nth 0 chunk))
                 (heading-text (nth 1 chunk))
                 (content (nth 2 chunk))
                 (word-count (nth 3 chunk))
                 (level (nth 4 chunk))
                 (chunk-type (nth 5 chunk))
                 (existing-embedding (org-roam-semantic--get-embedding file position)))

            (cond
             ;; ID-only chunks - just ensure they have an ID
             ((eq chunk-type :id-only)
              (org-roam-semantic--ensure-heading-id file heading-text)
              (cl-incf processed-chunks)
              (message "  Added ID to short section: %s [%d/%d]" heading-text (+ processed-chunks skipped-chunks) total-chunks))

             ;; Embedding chunks - check if already has embedding
             (existing-embedding
              (cl-incf skipped-chunks)
              (message "  Skipping %s (already has embedding) [%d/%d]" heading-text (+ processed-chunks skipped-chunks) total-chunks))

             ;; Embedding chunks without embeddings - generate them
             (t
              (cl-incf processed-chunks)
              (message "  Processing %s [%d/%d]..." heading-text (+ processed-chunks skipped-chunks) total-chunks)
              (let ((embedding (org-roam-ai-generate-embedding content)))
                (if embedding
                    (progn
                      (org-roam-semantic--store-embedding file embedding heading-text)
                      (message "  Successfully stored embedding for %s" heading-text))
                  (message "  Failed to generate embedding for %s" heading-text)))))))))

    (message "Chunk embedding generation complete: %d files processed, %d chunks total, %d processed, %d skipped"
             total-files total-chunks processed-chunks skipped-chunks)))

;;; Sync Commands

;;;###autoload
(defun org-roam-semantic-sync-file (&optional file)
  "Reindex FILE through the async embedding pipeline.
Invalidates stale embeddings if the content hash changed, then discovers
all :ID: nodes, builds both chunk types, and queues them for async
embedding.  Reports the number of nodes queued in the minibuffer.
FILE defaults to the current buffer's file."
  (interactive)
  (let* ((file (or file (buffer-file-name)))
         (_ (unless file (error "No file associated with current buffer")))
         (file (expand-file-name file))
         (file-title (org-roam-semantic--get-title file))
         (nodes (org-roam-semantic--discover-nodes file))
         (queued 0))
    (org-roam-semantic--invalidate-file-if-changed file)
    (dolist (node-entry nodes)
      (let* ((element (nth 0 node-entry))
             (level (nth 2 node-entry))
             (node-id (if (> level 0)
                          (org-element-property :ID element)
                        (org-element-map element 'node-property
                          (lambda (np)
                            (when (string= (org-element-property :key np) "ID")
                              (org-element-property :value np)))
                          nil t 'headline)))
             (leading (when node-id
                        (org-roam-semantic--enforce-chunk-size
                         (org-roam-semantic--build-leading-chunk node-entry file-title)
                         node-id "leading")))
             (full (when node-id
                     (org-roam-semantic--enforce-chunk-size
                      (org-roam-semantic--build-full-chunk node-entry file-title)
                      node-id "full"))))
        (when (and node-id (or leading full))
          (when leading (org-roam-semantic--embed-enqueue node-id "leading" leading))
          (when full (org-roam-semantic--embed-enqueue node-id "full" full))
          (cl-incf queued))))
    (message "org-roam-semantic: queued %d node%s for %s"
             queued (if (= queued 1) "" "s")
             (file-name-nondirectory file))))

;;;###autoload
(defun org-roam-semantic-sync-all ()
  "Reindex all org-roam files through the async embedding pipeline.
For each file, invalidates stale embeddings if the content hash changed,
then queues nodes whose embeddings are missing or whose file changed.
Unchanged files with complete embeddings are skipped.  Reports aggregate
progress in the minibuffer."
  (interactive)
  (let* ((files (org-roam-list-files))
         (total (length files))
         (db (org-roam-semantic--db-open))
         (embedded-ids (make-hash-table :test 'equal))
         (queued-files 0)
         (queued-nodes 0))
    (dolist (row (sqlite-select db "SELECT DISTINCT node_id FROM embeddings"))
      (puthash (car row) t embedded-ids))
    (let ((i 0))
      (dolist (file files)
        (cl-incf i)
        (message "org-roam-semantic: scanning %d/%d %s" i total
                 (file-name-nondirectory file))
        (let* ((changed (org-roam-semantic--invalidate-file-if-changed file))
               (file-title (org-roam-semantic--get-title file))
               (nodes (org-roam-semantic--discover-nodes file))
               (file-queued 0))
          (dolist (node-entry nodes)
            (let* ((element (nth 0 node-entry))
                   (level (nth 2 node-entry))
                   (node-id (if (> level 0)
                                (org-element-property :ID element)
                              (org-element-map element 'node-property
                                (lambda (np)
                                  (when (string= (org-element-property :key np) "ID")
                                    (org-element-property :value np)))
                                nil t 'headline))))
              (when (and node-id (or changed (not (gethash node-id embedded-ids))))
                (let* ((leading (org-roam-semantic--enforce-chunk-size
                                 (org-roam-semantic--build-leading-chunk node-entry file-title)
                                 node-id "leading"))
                       (full (org-roam-semantic--enforce-chunk-size
                              (org-roam-semantic--build-full-chunk node-entry file-title)
                              node-id "full")))
                  (when (or leading full)
                    (when leading (org-roam-semantic--embed-enqueue node-id "leading" leading))
                    (when full (org-roam-semantic--embed-enqueue node-id "full" full))
                    (cl-incf file-queued))))))
          (when (> file-queued 0)
            (cl-incf queued-files))
          (cl-incf queued-nodes file-queued))))
    (message "org-roam-semantic: queued %d node%s across %d file%s"
             queued-nodes (if (= queued-nodes 1) "" "s")
             queued-files (if (= queued-files 1) "" "s"))))

;;;###autoload
(defun org-roam-semantic-sync-heading ()
  "Synchronously regenerate embeddings for the org-roam node at point.
Finds the nearest enclosing heading with an :ID: property, builds both
chunk types, enforces size constraints, and writes to the DB immediately.
Errors are shown in the minibuffer."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let* ((file (or (buffer-file-name) (user-error "Buffer has no associated file")))
         (node-id (save-excursion
                    (unless (org-at-heading-p)
                      (or (ignore-errors (org-back-to-heading t))
                          (user-error "Not inside a heading")))
                    (let ((id (org-entry-get (point) "ID")))
                      (while (and (null id) (org-up-heading-safe))
                        (setq id (org-entry-get (point) "ID")))
                      id)))
         (_ (unless node-id
              (user-error "No enclosing org-roam node (:ID: heading) found")))
         (file-title (org-roam-semantic--get-title file))
         (nodes (org-roam-semantic--discover-nodes file))
         (node-entry
          (cl-find-if
           (lambda (entry)
             (let* ((element (nth 0 entry))
                    (level (nth 2 entry))
                    (eid (if (> level 0)
                             (org-element-property :ID element)
                           (org-element-map element 'node-property
                             (lambda (np)
                               (when (string= (org-element-property :key np) "ID")
                                 (org-element-property :value np)))
                             nil t 'headline))))
               (equal eid node-id)))
           nodes))
         (_ (unless node-entry
              (user-error "Node %s not found in parsed file" node-id)))
         (leading (org-roam-semantic--enforce-chunk-size
                   (org-roam-semantic--build-leading-chunk node-entry file-title)
                   node-id "leading"))
         (full (org-roam-semantic--enforce-chunk-size
                (org-roam-semantic--build-full-chunk node-entry file-title)
                node-id "full")))
    (condition-case err
        (progn
          (when leading
            (let ((vec (org-roam-semantic--embed-query-sync leading)))
              (if vec
                  (org-roam-semantic--db-upsert-embedding node-id "leading" vec)
                (error "Embedding API returned nil for leading chunk"))))
          (when full
            (let ((vec (org-roam-semantic--embed-query-sync full)))
              (if vec
                  (org-roam-semantic--db-upsert-embedding node-id "full" vec)
                (error "Embedding API returned nil for full chunk"))))
          (message "org-roam-semantic: updated %s" node-id))
      (error (message "org-roam-semantic sync-heading: %s"
                      (error-message-string err))))))

;;; Error Reporting

(defun org-roam-semantic--log-error (format-string &rest args)
  "Append a timestamped message to *org-roam-semantic-errors* without switching to it."
  (with-current-buffer (get-buffer-create "*org-roam-semantic-errors*")
    (goto-char (point-max))
    (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ")
            (apply #'format format-string args)
            "\n")))

;;;###autoload
(defun org-roam-semantic-show-errors ()
  "Display the *org-roam-semantic-errors* buffer."
  (interactive)
  (display-buffer (get-buffer-create "*org-roam-semantic-errors*")))

;;; SQLite Database

(defvar org-roam-semantic--db-connection nil
  "Singleton SQLite connection to the embeddings database.")

(defvar org-roam-semantic--vec-extension-loaded nil
  "Non-nil when the sqlite-vec extension was successfully loaded.")

(defun org-roam-semantic--db-location ()
  "Return the effective path to the embeddings database file."
  (or org-roam-semantic-db-location
      (file-name-concat (file-name-directory org-roam-db-location)
                        "org-roam-embeddings.db")))

(defun org-roam-semantic--db-open ()
  "Return the open DB connection, opening and initializing it if needed."
  (unless org-roam-semantic--db-connection
    (let ((db (sqlite-open (org-roam-semantic--db-location))))
      (sqlite-execute db "CREATE TABLE IF NOT EXISTS file_hashes (
        file TEXT PRIMARY KEY NOT NULL,
        content_hash TEXT NOT NULL,
        updated_at INTEGER NOT NULL)")
      (sqlite-execute db "CREATE TABLE IF NOT EXISTS embeddings (
        node_id TEXT NOT NULL,
        chunk_type TEXT NOT NULL,
        embedding BLOB NOT NULL,
        PRIMARY KEY (node_id, chunk_type))")
      (when org-roam-semantic-sqlite-vec-path
        (condition-case err
            (progn
              (sqlite-execute db (format "SELECT load_extension('%s')"
                                        org-roam-semantic-sqlite-vec-path))
              (setq org-roam-semantic--vec-extension-loaded t))
          (error
           (org-roam-semantic--log-error "sqlite-vec load failed: %s" err)
           (setq org-roam-semantic--vec-extension-loaded nil))))
      (setq org-roam-semantic--db-connection db)))
  org-roam-semantic--db-connection)

(defun org-roam-semantic--db-close ()
  "Close the embeddings database connection."
  (when org-roam-semantic--db-connection
    (sqlite-close org-roam-semantic--db-connection)
    (setq org-roam-semantic--db-connection nil)))

(defun org-roam-semantic--db-upsert-embedding (node-id chunk-type vector)
  "Store or replace VECTOR for NODE-ID / CHUNK-TYPE in the embeddings table."
  (let ((db (org-roam-semantic--db-open)))
    (sqlite-execute db
      "INSERT OR REPLACE INTO embeddings (node_id, chunk_type, embedding) VALUES (?, ?, ?)"
      (list node-id chunk-type (org-roam-semantic--vec-serialize vector)))))

(defun org-roam-semantic--vec-serialize (vec)
  "Serialize VEC (list of floats) to space-separated string for storage."
  (mapconcat (lambda (x) (format "%.8f" x)) vec " "))

(defun org-roam-semantic--vec-deserialize (blob)
  "Deserialize BLOB (space-separated text or bytes) to a list of floats."
  (let ((str (if (stringp blob) blob (decode-coding-string blob 'utf-8))))
    (mapcar #'string-to-number (split-string (string-trim str) " " t))))

(defun org-roam-semantic--file-content-hash (file)
  "Return a SHA256 hex hash of FILE's normalized semantic content.
Strips TODO keywords, priority cookies, tags, property drawers,
planning lines, timestamps, and file-level #+keyword: lines (except
#+title:) before hashing.  Used to detect meaningful content changes
while ignoring organizational edits (tag changes, rescheduling)."
  (with-temp-buffer
    (insert-file-contents file)
    ;; Remove :PROPERTIES:...:END: drawers
    (goto-char (point-min))
    (while (re-search-forward
            "^[ \t]*:PROPERTIES:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?" nil t)
      (replace-match ""))
    ;; Remove planning lines
    (goto-char (point-min))
    (while (re-search-forward
            "^[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):.*\n?" nil t)
      (replace-match ""))
    ;; Remove #+keyword: lines except #+title:
    ;; (Emacs regexp has no lookahead, so capture the keyword and skip "title")
    (goto-char (point-min))
    (while (re-search-forward "^#\\+\\([a-zA-Z_-]+\\):.*\n?" nil t)
      (unless (string-equal-ignore-case (match-string 1) "title")
        (replace-match "")))
    ;; Strip TODO keywords from headlines
    (goto-char (point-min))
    (while (re-search-forward
            "^\\(\\*+[ \t]+\\)\\(?:TODO\\|DONE\\|NEXT\\|WAITING\\|HOLD\\|CANCELLED\\|SOMEDAY\\)[ \t]+"
            nil t)
      (replace-match "\\1"))
    ;; Strip priority cookies from headlines
    (goto-char (point-min))
    (while (re-search-forward "^\\(\\*+.*?\\)\\[#[A-Z]\\][ \t]+" nil t)
      (replace-match "\\1"))
    ;; Strip tags from end of headlines
    (goto-char (point-min))
    (while (re-search-forward "[ \t]+:[a-zA-Z0-9_@#%:]+:[ \t]*$" nil t)
      (replace-match ""))
    ;; Strip active and inactive timestamps
    (goto-char (point-min))
    (while (re-search-forward
            "<[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^>\n]*>" nil t)
      (replace-match ""))
    (goto-char (point-min))
    (while (re-search-forward
            "\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^]\n]*\\]" nil t)
      (replace-match ""))
    ;; Normalize whitespace and hash
    (secure-hash 'sha256
                 (string-trim
                  (replace-regexp-in-string "[ \t\n\r]+" " " (buffer-string))))))

(defun org-roam-semantic--invalidate-file-if-changed (file)
  "Compare FILE's current content hash to the stored hash.
If different or absent, delete all embeddings for nodes in FILE and update
the file_hashes row in a single transaction.  Return t if invalidation
occurred (caller should re-queue embeddings), nil if file is up to date."
  (let* ((db (org-roam-semantic--db-open))
         (new-hash (org-roam-semantic--file-content-hash file))
         (stored (car (sqlite-select db
                        "SELECT content_hash FROM file_hashes WHERE file = ?"
                        (list file))))
         (stored-hash (when stored (car stored))))
    (if (equal new-hash stored-hash)
        nil
      (let ((node-ids (mapcar #'car
                               (org-roam-db-query
                                [:select id :from nodes :where (= file $s1)]
                                file))))
        (sqlite-execute db "BEGIN")
        (condition-case err
            (progn
              (dolist (node-id node-ids)
                (sqlite-execute db
                  "DELETE FROM embeddings WHERE node_id = ?"
                  (list node-id)))
              (sqlite-execute db
                "INSERT OR REPLACE INTO file_hashes (file, content_hash, updated_at) VALUES (?, ?, ?)"
                (list file new-hash (floor (float-time))))
              (sqlite-execute db "COMMIT"))
          (error
           (sqlite-execute db "ROLLBACK")
           (signal (car err) (cdr err)))))
      t)))

(defun org-roam-semantic--db-get-embeddings (&optional chunk-type)
  "Return list of (node-id chunk-type embedding-vector) triples from the DB.
If CHUNK-TYPE is non-nil ('leading' or 'full'), filter to that type only."
  (let* ((db (org-roam-semantic--db-open))
         (rows (if chunk-type
                   (sqlite-select db
                     "SELECT node_id, chunk_type, embedding FROM embeddings WHERE chunk_type = ?"
                     (list chunk-type))
                 (sqlite-select db
                   "SELECT node_id, chunk_type, embedding FROM embeddings"))))
    (mapcar (lambda (row)
              (list (nth 0 row)
                    (nth 1 row)
                    (org-roam-semantic--vec-deserialize (nth 2 row))))
            rows)))

(defun org-roam-semantic--db-get-node-metadata (node-id)
  "Return (file-path heading-text) for NODE-ID by querying org-roam's DB."
  (let ((rows (org-roam-db-query
               [:select [file title] :from nodes :where (= id $s1)]
               node-id)))
    (when rows
      (list (car (car rows)) (cadr (car rows))))))

;;; Semantic Search

(defun org-roam-semantic--find-by-chunk-type (query-vec chunk-types limit cutoff)
  "Search CHUNK-TYPES embeddings for QUERY-VEC, return top LIMIT above CUTOFF.
CHUNK-TYPES is a list of strings (e.g. '(\"leading\" \"full\")).
Returns list of (node-id similarity file-path heading-text)."
  (let ((best (make-hash-table :test 'equal)))
    (dolist (chunk-type chunk-types)
      (dolist (row (org-roam-semantic--db-get-embeddings chunk-type))
        (let* ((node-id (nth 0 row))
               (embedding (nth 2 row))
               (sim (org-roam-semantic--cosine-similarity query-vec embedding)))
          (when (and sim (>= sim cutoff))
            (let ((prev (gethash node-id best)))
              (when (or (null prev) (> sim prev))
                (puthash node-id sim best)))))))
    (let (pairs)
      (maphash (lambda (node-id sim) (push (cons node-id sim) pairs)) best)
      (setq pairs (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
      (when (> (length pairs) limit)
        (setq pairs (seq-take pairs limit)))
      (delq nil
            (mapcar (lambda (pair)
                      (let* ((node-id (car pair))
                             (sim (cdr pair))
                             (meta (org-roam-semantic--db-get-node-metadata node-id)))
                        (when meta
                          (list node-id sim (nth 0 meta) (nth 1 meta)))))
                    pairs)))))

(defun org-roam-semantic--display-results (query-text results)
  "Display RESULTS for QUERY-TEXT in the *Similar Notes* buffer."
  (with-current-buffer (get-buffer-create "*Similar Notes*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (org-mode)
      (insert (format "* Similar notes for: %s\n\n" query-text))
      (if results
          (dolist (r results)
            (let ((node-id (nth 0 r))
                  (sim (nth 1 r))
                  (heading (nth 3 r)))
              (insert (format "- %.3f [[id:%s][%s]]\n"
                              sim node-id (or heading node-id)))))
        (insert "No results above the similarity cutoff.\n"))
      (goto-char (point-min)))
    (display-buffer (current-buffer))))

;;;###autoload
(defun org-roam-semantic-find-best (query-text &optional limit cutoff)
  "Find org-roam nodes semantically similar to QUERY-TEXT, both chunk types.
Deduplicates by node-id, keeping the highest cosine score across chunk types.
LIMIT defaults to `org-roam-semantic-result-limit'.
CUTOFF defaults to `org-roam-semantic-similarity-cutoff'.
Returns list of (node-id similarity file-path heading-text) and displays
results in *Similar Notes* buffer with clickable org-id links."
  (interactive "sSearch query: ")
  (let* ((limit (or limit org-roam-semantic-result-limit))
         (cutoff (or cutoff org-roam-semantic-similarity-cutoff))
         (query-vec (org-roam-semantic--embed-query-sync query-text)))
    (if (null query-vec)
        (progn (org-roam-semantic--log-error "Failed to embed query: %s" query-text) nil)
      (let ((results (org-roam-semantic--find-by-chunk-type
                      query-vec '("leading" "full") limit cutoff)))
        (org-roam-semantic--display-results query-text results)
        results))))

;;;###autoload
(defun org-roam-semantic-find-best-full (query-text &optional limit cutoff)
  "Find org-roam nodes similar to QUERY-TEXT using full-content embeddings only.
LIMIT defaults to `org-roam-semantic-result-limit'.
CUTOFF defaults to `org-roam-semantic-similarity-cutoff'.
Returns list of (node-id similarity file-path heading-text) and displays
results in *Similar Notes* buffer with clickable org-id links."
  (interactive "sSearch query: ")
  (let* ((limit (or limit org-roam-semantic-result-limit))
         (cutoff (or cutoff org-roam-semantic-similarity-cutoff))
         (query-vec (org-roam-semantic--embed-query-sync query-text)))
    (if (null query-vec)
        (progn (org-roam-semantic--log-error "Failed to embed query: %s" query-text) nil)
      (let ((results (org-roam-semantic--find-by-chunk-type
                      query-vec '("full") limit cutoff)))
        (org-roam-semantic--display-results query-text results)
        results))))

;;;###autoload
(defun org-roam-semantic-find-best-leading (query-text &optional limit cutoff)
  "Find org-roam nodes similar to QUERY-TEXT using leading-text embeddings only.
LIMIT defaults to `org-roam-semantic-result-limit'.
CUTOFF defaults to `org-roam-semantic-similarity-cutoff'.
Returns list of (node-id similarity file-path heading-text) and displays
results in *Similar Notes* buffer with clickable org-id links."
  (interactive "sSearch query: ")
  (let* ((limit (or limit org-roam-semantic-result-limit))
         (cutoff (or cutoff org-roam-semantic-similarity-cutoff))
         (query-vec (org-roam-semantic--embed-query-sync query-text)))
    (if (null query-vec)
        (progn (org-roam-semantic--log-error "Failed to embed query: %s" query-text) nil)
      (let ((results (org-roam-semantic--find-by-chunk-type
                      query-vec '("leading") limit cutoff)))
        (org-roam-semantic--display-results query-text results)
        results))))

;;; Vector Search Functions

(defun org-roam-semantic--get-title (file)
  "Extract the title from an org-roam note file."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (if (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
            (string-trim (match-string 1))
          (file-name-sans-extension (file-name-nondirectory file))))
    (error (file-name-sans-extension (file-name-nondirectory file)))))

(defun org-roam-semantic--get-node-id (file)
  "Extract the node ID from an org-roam note file."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward "^:ID:\\s-*\\(.+\\)$" nil t)
          (string-trim (match-string 1))))
    (error nil)))

;;;###autoload
(defun org-roam-semantic-find-similar (query-text &optional limit chunk-level)
  "Find notes similar to the query text and display in a results buffer with clickable links.
If CHUNK-LEVEL is non-nil, searches chunks instead of whole files."
  (interactive "sSearch for concept: ")
  (let ((similarities (org-roam-semantic-get-similar-data query-text (or limit 10) chunk-level)))
    (if similarities
        (with-current-buffer (get-buffer-create (if chunk-level "*Similar Chunks*" "*Similar Notes*"))
          (erase-buffer)
          (org-mode) ; Enable org-mode for clickable links
          (insert (format "* Similar %s for: %s\n\n"
                         (if chunk-level "chunks" "notes") query-text))
          (insert "Click links to open notes, or copy the org-roam links below:\n\n")

          (dolist (result similarities)
            (let* ((file (car result))
                   (similarity (cadr result))
                   (position (when chunk-level (nth 2 result)))
                   (heading-text (when chunk-level (nth 3 result)))
                   (title (org-roam-semantic--get-title file))
                   (node-id (org-roam-semantic--get-node-id file)))

              (if chunk-level
                  ;; Chunk result
                  (progn
                    (insert (format "** %.3f - [[file:%s::%s][%s > %s]]\n"
                                   similarity file
                                   (if (= position (point-min)) title heading-text)
                                   title heading-text))
                    (when node-id
                      (insert (format "   Org-roam link: =[[id:%s][%s]]=\n" node-id title))))
                ;; File result
                (progn
                  (insert (format "** %.3f - [[file:%s][%s]]\n" similarity file title))
                  (when node-id
                    (insert (format "   Org-roam link: =[[id:%s][%s]]=\n" node-id title)))))
              (insert "\n")))

          (insert "\n** Usage:\n")
          (insert "- Click file links to open notes\n")
          (when chunk-level
            (insert "- File links will jump to the specific section\n"))
          (insert "- Copy org-roam links (the =[[id:...]]= parts) to insert elsewhere\n")
          (insert "- Use C-c C-c on org-roam links to follow them\n")

          (goto-char (point-min))
          (display-buffer (current-buffer))
          (message "Found %d similar %s - click links to open"
                  (length similarities) (if chunk-level "chunks" "notes")))
      (message "No similar %s found" (if chunk-level "chunks" "notes")))))

(defun org-roam-semantic-find-and-insert (query-text &optional limit)
  "Find similar notes and insert org-roam links into the current buffer."
  (interactive "sSearch for concept: ")
  (if (not (derived-mode-p 'org-mode))
      (message "This function only works in org-mode buffers")
    (let ((similarities (org-roam-semantic-get-similar-data query-text (or limit 5))))
      (if similarities
          (progn
            (insert (format "\n** Related Notes - %s\n" query-text))
            (dolist (result similarities)
              (let* ((file (car result))
                     (similarity (cadr result))
                     (title (org-roam-semantic--get-title file))
                     (node-id (org-roam-semantic--get-node-id file)))
                (if node-id
                    (insert (format "- [[id:%s][%s]] (%.3f)\n" node-id title similarity))
                  (insert (format "- [[file:%s][%s]] (%.3f)\n" file title similarity)))))
            (insert "\n")
            (message "Inserted %d similar note links" (length similarities)))
        (message "No similar notes found")))))

;;;###autoload
(defun org-roam-semantic-search (concept)
  "Interactive search for notes by concept - displays results buffer."
  (interactive "sConcept to search for: ")
  (org-roam-semantic-find-similar concept))

;;;###autoload
(defun org-roam-semantic-search-chunks (concept)
  "Interactive search for note chunks by concept - displays results buffer."
  (interactive "sConcept to search for (chunks): ")
  (org-roam-semantic-find-similar concept t))

;;;###autoload
(defun org-roam-semantic-insert-related (concept)
  "Search for related notes and insert links at point."
  (interactive "sConcept to find related notes for: ")
  (org-roam-semantic-find-and-insert concept))

;;;###autoload
(defun org-roam-semantic-insert-similar (&optional cutoff)
  "Find notes similar to current note and insert org-roam links at point.
Uses similarity cutoff from `org-roam-semantic-similarity-cutoff' or CUTOFF if provided.
All notes above the similarity threshold will be inserted."
  (interactive "P")
  (if (not (and (derived-mode-p 'org-mode) (org-roam-file-p)))
      (message "This function only works in org-roam files")
    (let* ((current-file (buffer-file-name))
           (title (or (org-roam-get-keyword "TITLE")
                     (file-name-sans-extension (file-name-nondirectory current-file))))
           (content (org-roam-semantic--get-content current-file))
           (query-text (or content title))
           (cutoff (or cutoff org-roam-semantic-similarity-cutoff))
           (similarities (org-roam-semantic-get-similar-data query-text nil cutoff))) ; Use cutoff, no limit

      ;; Filter out the current note from results
      (setq similarities (seq-remove (lambda (result)
                                      (string= (car result) current-file))
                                    similarities))

      (if similarities
          (progn
            (insert (format "\n** Related Notes (similarity >= %.2f)\n" cutoff))
            (dolist (result similarities)
              (let* ((file (car result))
                     (similarity (cadr result))
                     (title (org-roam-semantic--get-title file))
                     (node-id (org-roam-semantic--get-node-id file)))
                (if node-id
                    (insert (format "- [[id:%s][%s]] (%.3f)\n" node-id title similarity))
                  (insert (format "- [[file:%s][%s]] (%.3f)\n" file title similarity)))))
            (insert "\n")
            (message "Inserted %d similar note links (similarity >= %.2f)" (length similarities) cutoff))
        (message "No similar notes found above similarity threshold %.2f" cutoff)))))

;;; Status and Maintenance Functions

;;;###autoload
(defun org-roam-semantic-debug-embedding (file)
  "Debug embedding for a specific file."
  (interactive (list (read-file-name "Check embedding for file: "
                                     org-roam-directory nil t)))
  (let ((embedding (org-roam-semantic--get-embedding file)))
    (if embedding
        (message "File: %s\nEmbedding: %d dimensions\nFirst few values: %s"
                 (file-name-nondirectory file)
                 (length embedding)
                 (mapconcat 'number-to-string
                           (list (nth 0 embedding) (nth 1 embedding) (nth 2 embedding)
                                 (nth 3 embedding) (nth 4 embedding)) ", "))
      (message "File: %s has no embedding" (file-name-nondirectory file)))))

;;;###autoload
(defun org-roam-semantic-status ()
  "Show status of vector embeddings in the knowledge base."
  (interactive)
  (let* ((all-files (org-roam-list-files))
         (total-notes (length all-files))
         (notes-with-embeddings 0)
         (total-chunks 0)
         (chunks-with-embeddings 0)
         (notes-without-embeddings '())
         (embedding-sizes '()))

    (dolist (file all-files)
      ;; Count chunks and their embeddings
      (let ((all-embeddings (org-roam-semantic--get-all-embeddings file)))
        (let ((chunk-count (length (org-roam-semantic--parse-chunks file))))
          (setq total-chunks (+ total-chunks chunk-count))
          (setq chunks-with-embeddings (+ chunks-with-embeddings (length all-embeddings)))
          (when (> chunk-count 0)
            (cl-incf notes-with-embeddings))
          (dolist (chunk-embedding all-embeddings)
            (push (length (nth 2 chunk-embedding)) embedding-sizes)))))

    (let ((coverage (if (> total-notes 0)
                       (/ (* 100.0 notes-with-embeddings) total-notes)
                     0))
          (chunk-coverage (if (> total-chunks 0)
                             (/ (* 100.0 chunks-with-embeddings) total-chunks)
                           0))
          (unique-sizes (seq-uniq embedding-sizes)))

      (message "Vector Search Status: %d/%d files with chunks, %d/%d total chunks (%.1f%%) have embeddings. Sizes: %s"
               notes-with-embeddings total-notes
               chunks-with-embeddings total-chunks chunk-coverage unique-sizes)
      (with-current-buffer (get-buffer-create "*Embedding Status*")
        (erase-buffer)
        (insert (format "Chunk Embedding Coverage: %d/%d files have chunks, %d/%d chunks (%.1f%%) embedded\n"
                       notes-with-embeddings total-notes
                       chunks-with-embeddings total-chunks chunk-coverage))
        (insert (format "Embedding dimensions found: %s\n\n" unique-sizes))
        (display-buffer (current-buffer))))))

;;;;;; Minimal org → Markdown for n8n (ox-md), safe for files with leading drawers

(require 'org)
(require 'ox-md)

(defun org-roam-semantic--org-md-wrap-if-needed ()
  "If buffer has no headlines or starts with a :PROPERTIES: drawer,
wrap contents under a synthetic top-level heading using #+title or filename."
  (save-excursion
    (goto-char (point-min))
    (let* ((has-heading (save-excursion (re-search-forward org-heading-regexp nil t)))
           (starts-with-drawer (looking-at-p "\\`\\s-*:PROPERTIES:\\s-*\n")))
      (when (or (not has-heading) starts-with-drawer)
        (let* ((title (or (cadr (assoc "TITLE" (org-collect-keywords '("title"))))
                          (file-name-base (or buffer-file-name "note"))))
               (content (buffer-string)))
          (erase-buffer)
          (insert "* " title "\n\n" content))))))

(defun org-roam-semantic--org-strip-property-drawers ()
  "Remove all :PROPERTIES:…:END: drawers anywhere in the buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((rx (rx line-start (* blank) ":PROPERTIES:" (* blank) "\n"
                  (*? anything)
                  line-start (* blank) ":END:" (* blank) "\n")))
      (while (re-search-forward rx nil t)
        (replace-match "" t t)))))

(defun org-roam-semantic--with-org-file (org-file thunk)
  "Open ORG-FILE into a temp org buffer and run THUNK there."
  (unless (and org-file (file-readable-p org-file))
    (error "File not found or unreadable: %s" org-file))
  (with-temp-buffer
    (insert-file-contents org-file)
    (let ((default-directory (file-name-directory org-file)))
      (delay-mode-hooks (org-mode)))
    (org-roam-semantic--org-md-wrap-if-needed)
    (org-roam-semantic--org-strip-property-drawers)
    (let ((org-export-use-babel nil)
          (org-confirm-babel-evaluate nil)
          (org-export-with-broken-links 'mark)
          (org-export-with-toc nil)
          (org-export-with-section-numbers nil)
          (org-export-with-author nil)
          (org-export-with-creator nil)
          (org-export-with-email nil)
          (org-export-with-date nil)
          ;; also tell Org not to export any drawers (LOGBOOK, etc.)
          (org-export-with-drawers nil))
      (funcall thunk))))

(defun org-roam-semantic--export-md-string (org-file)
  "Export ORG-FILE to Markdown and return it as a Lisp string."
  (org-roam-semantic--with-org-file
   org-file
   (lambda ()
     ;; (org-export-as BACKEND SUBTREEP VISIBLE-ONLY BODY-ONLY EXT-PLIST)
     (org-export-as 'md nil nil t '(:explicit-links t)))))

(defun org-roam-semantic--temp-md-path (org-file)
  "Deterministic-but-unique temp filename for ORG-FILE."
  (let* ((abs (expand-file-name org-file))
         (mtime (or (nth 5 (file-attributes abs)) (current-time)))
         (sig  (secure-hash 'sha1 (format "%s::%s" abs mtime))))
    (expand-file-name (format "orgmd-%s.md" sig) temporary-file-directory)))

(defun org-roam-semantic--export-md-tempfile (org-file)
  "Export ORG-FILE to a deterministic temp file and return the path."
  (let* ((out (org-roam-semantic--temp-md-path org-file))
         (md  (org-roam-semantic--export-md-string org-file)))
    (with-temp-file out (insert md))
    out))

(defun org-roam-semantic--export-md-read-delete (org-file)
  "Export ORG-FILE, read result, delete temp, return Markdown as Lisp string."
  (let* ((path (org-roam-semantic--export-md-tempfile org-file))
         (contents (with-temp-buffer
                     (insert-file-contents path)
                     (buffer-string))))
    (ignore-errors (delete-file path))
    contents))

;;; Auto-embedding hook

(defun org-roam-semantic--after-save ()
  "Reindex the current org-roam file after saving, if enabled."
  (when org-roam-semantic-update-on-save
    (org-roam-semantic-sync-file (buffer-file-name))))

(defun org-roam-semantic--setup-buffer-hook ()
  "Add a buffer-local after-save-hook to reindex this org-roam file."
  (add-hook 'after-save-hook #'org-roam-semantic--after-save nil 'local))

(add-hook 'org-roam-find-file-hook #'org-roam-semantic--setup-buffer-hook)

;;; Key Bindings for Vector Search

(global-set-key (kbd "C-c v s") 'org-roam-semantic-search)
(global-set-key (kbd "C-c v i") 'org-roam-semantic-insert-similar)
(global-set-key (kbd "C-c v r") 'org-roam-semantic-insert-related)

;; Chunk-level search bindings
(global-set-key (kbd "C-c v c") 'org-roam-semantic-search-chunks)
(global-set-key (kbd "C-c v g") 'org-roam-semantic-generate-chunks-for-file)
(global-set-key (kbd "C-c v G") 'org-roam-semantic-generate-all-chunks)

(provide 'org-roam-vector-search)

;;; org-roam-vector-search.el ends here
