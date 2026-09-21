# Provenance and design decisions

This standalone project derives from an existing local SwiftUI conversation browser. Its original project conversations and implementation were reviewed locally to recover the intent; no source conversation, account index, personal test prompt, author identity, screenshot or user-specific performance inventory is included here.

The following generalized decisions were retained from that design history:

- Workspace folders are the first navigation level because a flat list becomes difficult to use as conversations accumulate. A separate sortable table remains available for bulk browsing.
- Original first-message titles are often poor labels. Local rule-based themes, evolving summaries, recent user messages and editable local aliases help identify the right session without altering the source record.
- Codex data roots represent separate environments. Identical IDs must not cross those boundaries, including when archiving or generating recovery instructions.
- Startup uses a local cache; refresh is deliberate, runs off the UI thread, and reuses incremental JSONL checkpoints. Pagination and streaming address large local histories.
- Native Codex archive/unarchive and local-only Claude archive have different effects, which the UI explains before changing state.
- The app supplies recovery instructions and copies commands; it does not automatically continue a conversation.

For this shareable edition, fixed personal environment assumptions became explicit configuration; permission-bypass defaults and private shell-wrapper requirements were removed. The optional second Codex environment uses a generic label. Personalized topic rules and prompt-based regression samples were replaced with generic behavior and invented fixtures. Codex response-item transcripts gained tested compatibility, and a diagnostic/search CLI was added for Agent use.

The code uses Apple Foundation, SwiftUI, AppKit, XCTest and the system SQLite command. No third-party Swift packages or external service credentials are required. Codex and Claude Code are separate products; their local storage formats and CLI interfaces may change. This repository does not redistribute those products and does not claim affiliation with their vendors.

No public open-source license is asserted here. Access and reuse should follow the repository owner's permissions; choose a license explicitly before any future public release.

The original conversation-grid application icon is retained as a single required ICNS asset. Its ICNS info property list and any PNG text/time/EXIF chunks are removed; generation references and unused bitmap variants are not distributed.
