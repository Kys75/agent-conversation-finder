# Architecture and compatibility

`ConversationIndexService` combines independent scanners. Each record retains source, environment, storage key, route, timestamps and transcript checkpoint. The GUI applies local aliases and Claude local archives after scanning. Source failures retain that source's previous GUI records and report a warning; the stateless CLI has no previous records to retain.

## Source formats

Codex prefers a read-only `sqlite3 -json` query of `state_5.sqlite` (including its legacy `sqlite/` location), selecting main `cli` and `vscode` records. The scanner also merges the `sessions` and `archived_sessions` trees even after a successful query, retaining sessions not yet indexed in SQLite; database metadata takes priority for duplicates. A failed query falls back to those files. Source paths are resolved against their configured root, including symlink checks. A copied absolute transcript path can relocate by its `sessions` / `archived_sessions` suffix only inside the current root; foreign paths are never read. JSONL parsing supports `session_meta` and textual user/assistant messages from either `event_msg` or `response_item`. A transcript selects its first encountered message representation and persists that choice in the checkpoint, so mirrored representations are not indexed twice. A file that changes message representation halfway through a session is not currently supported; rebuild/convert the input copy or extend this parser with a synthetic regression before relying on such a file.

Claude scans `projects/**/*.jsonl`, excludes `subagents` directories, ignores sidechain messages and tool-result content, and reads `history.jsonl` for recent human inputs. AI/custom title events take priority. Runtime data is read only except when the user explicitly confirms a native Codex archive operation.

Timestamps prefer the newest available transcript/history/database activity; file timestamps are a fallback. Incomplete JSON at an active writer's final line is retried after append rather than committed as a permanent parse error. Checkpoints detect truncation or a changed first-line fingerprint, but an in-place edit of an already-indexed body with the same header is not guaranteed to invalidate every cache. Delete only the relevant generated `index-v1.json` after exiting the app if a full rebuild is needed; aliases and local archive files are separate.

## State

Default config and state root: `~/Library/Application Support/Agent Conversation Finder Shared`.

Each source-root combination gets `profiles/<stable-hash>/` containing:

- `index-v1.json`: derived records, summaries, searchable text and checkpoints.
- `aliases-v1.json`: local display titles.
- `local-archives-v1.json`: Claude records hidden by local archive.

The profile hash is an isolation key, not encryption. State remains sensitive. Files are written atomically and then set to `0600`; created directories are `0700`. Existing ancestor permissions remain the user's responsibility. Sort preference is stored in the app's user defaults. Nothing belongs in Git.

## Search and summaries

Search folds case, diacritics and character width and uses AND matching across whitespace-separated terms. Rule-based digests summarize the initial request, selected milestones and current focus. They do not call an LLM, perform vector search or guarantee semantic accuracy. Search stores at most approximately 300,000 characters per conversation; later recent-message/summary fields still update after the bound, but the full later transcript is not searchable through this cache.

## Verification scope

Tests create temporary JSONL/SQLite data for indexing, incremental updates, duplicate message representations, hidden sources, pagination/filter/sort models, command quoting, configuration isolation, caches, aliases and archive planning/execution errors. They do not sign into accounts, execute real archive commands or exercise GUI mouse interaction. The CI also compiles the full native app and CLI. UI inspection against a synthetic dataset remains useful after visual changes.
