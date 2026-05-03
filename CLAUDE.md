# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

This is an Emacs Lisp package — there is no build step. Byte-compile to check for errors:

```bash
emacs --batch -L . -f batch-byte-compile org-roam-vector-search.el
```

Note: batch-byte-compile will fail with "Cannot open load file: org-roam" unless you
add all transitive dependencies to `-L`. This is expected — use it only to catch
syntax errors in isolated Lisp forms.

### Interactive Test Environment

A self-contained Emacs environment lives in `test/`:

```bash
emacs --init-directory=test
```

- **First run** requires network access; straight.el downloads and compiles all packages
  into `test/straight/` (cached for subsequent runs).
- The test org-roam directory is `test/org/` — pre-seeded with nodes in
  `people/`, `projects/`, `ideas/`, `admin/`, and `blog/`.
- The embedding server must be running at `http://localhost:8080` for semantic
  search features. Start it with:
  ```bash
  llama-server --model nomic-embed-text-v1.5.Q8_0.gguf --port 8080 --embedding
  ```
- After launching Emacs, run `M-x org-roam-db-sync` once to populate the org-roam
  database from the test nodes.

**Resetting test state** (drops both databases, keeps org files):

```bash
rm -f test/org/org-roam.db test/org/org-roam-embeddings.db
```

**Adding test nodes**: drop `.org` files into the appropriate `test/org/<type>/`
subdirectory and re-run `M-x org-roam-db-sync`. Each node needs a file-level
`:ID:` property; use `test-<type>-<slug>-NNNN` as the ID format to avoid
collisions with real notes.

### Batch Testing

Use `emacs --batch` to run non-interactive tests against the already-cached
straight.el packages in `test/straight/`.

**Key rules:**

1. **`--load test/init.el` does not auto-load packages.** `use-package :after`
   deferral does not fire in batch mode. Always explicitly require what you need:
   ```bash
   emacs --init-directory=test --batch \
     --load test/init.el \
     --eval "(require 'org-roam) (require 'org-roam-vector-search)" \
     --eval "..."
   ```

2. **Use separate `--eval` flags for separate expressions**, not one large
   single-quoted string. Long `--eval` strings are hard to debug and shell
   quoting errors are silent.

3. **Test scripts must be pure ASCII.** Non-ASCII characters (em-dashes, box
   drawing, curly quotes) in `.el` script files cause `end-of-file during
   parsing` errors in `--batch` mode. Write scripts with a heredoc and verify:
   ```bash
   python3 -c "
   data = open('test/myscript.el','rb').read()
   print('non-ASCII:', len([b for b in data if b>127]))
   "
   ```

4. **The async embedding queue does not drain in batch mode.** `url-retrieve`
   callbacks require the Emacs event loop. For batch tests, use the synchronous
   path (`org-roam-semantic--embed-query-sync`) and call
   `org-roam-semantic--db-upsert-embedding` directly. See
   `test/test-embeddings.el` for a working example.

5. **`message` output goes to stderr.** Pipe through `grep` or `2>&1` to
   capture it alongside stdout.

## Architecture Overview

This package (`org-roam-vector-search.el`) adds vector embedding support and semantic
search to org-roam. It calls an OpenAI-compatible embeddings API, stores vectors in a
dedicated SQLite database, and provides cosine-similarity search over org-roam nodes.

### Primary source file

All work happens in `org-roam-vector-search.el`. Read it before implementing any task.

### Key architectural decisions

Retrieve the full record with `bd memories architecture`. Summary:

- **Storage**: `org-roam-embeddings.db` — a separate SQLite file alongside `org-roam.db`.
  Uses Emacs 29 built-in sqlite API (`sqlite-open`, `sqlite-execute`, `sqlite-select`).
  **Never use emacsql.**
- **DB schema**: two tables — `file_hashes (file, content_hash, updated_at)` and
  `embeddings (node_id, chunk_type, embedding)`. `chunk_type` is `'leading'` or `'full'`.
- **Chunking**: only org-roam nodes (headings with `:ID:`) are embedded. Each gets two
  chunk types. Heading text is normalized (strip TODO keywords, priority cookies, tags,
  timestamps). `'leading'` = ancestor breadcrumb + node's pre-child body.
  `'full'` = leading + all recursive descendant content.
- **Async indexing**: embedding generation uses `url-retrieve` with a sequential drain
  queue. **Search queries use synchronous** `url-retrieve-synchronously`.
- **Change detection**: file-level SHA256 hash of normalized content. Hash change deletes
  all embeddings for nodes in that file and requeues them.
- **sqlite-vec**: optional extension; fall back to TEXT storage if unavailable. Cosine
  similarity is always computed in Emacs Lisp.
- **Errors**: all async errors and chunk-size warnings go to `*org-roam-semantic-errors*`.

## Working on a Beads Issue

Each session is assigned one issue ID. Follow this orientation sequence:

```bash
bd prime                        # load workflow context
bd show <your-issue-id>         # read description AND design notes
# For each dependency listed under "Blocked by":
bd show <blocker-id>            # understand the APIs you build on
bd memories architecture        # review cross-cutting decisions
```

Then read `org-roam-vector-search.el` to understand existing code.

Claim the issue before writing code:
```bash
bd update <your-issue-id> --claim
```

If a dependency's issue describes a function signature or table schema, implement exactly
what is specified there — do not invent alternatives. If you find a genuine conflict or
ambiguity, file a new beads issue describing it rather than silently choosing an approach.

## Conventions & Patterns

- **Naming**: public functions `org-roam-semantic-<verb>-<noun>`, internal functions
  `org-roam-semantic--<verb>-<noun>` (double dash), customizable variables
  `org-roam-semantic-<noun>`.
- **No comments explaining what code does** — only comments for non-obvious WHY.
- **No emacsql** — use only Emacs 29 built-in sqlite functions.
- **No property drawer writes** — embeddings live in the DB only, never written back to
  org files (unless `org-roam-semantic-clean-old-properties` is set, which removes old
  EMBEDDING properties).
- **Lexical binding** — all files must have `;;; -*- lexical-binding: t; -*-`.
- **Error routing**: use `org-roam-semantic--log-error` (defined in issue `w82`) to send
  warnings and errors to `*org-roam-semantic-errors*`; never use `error` for async paths.
