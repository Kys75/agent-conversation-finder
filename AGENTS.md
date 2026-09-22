# Agent setup and maintenance

This is a local macOS application and a read-only search CLI. Read README.md before changing or configuring it.

Both the app and the bundled CLI target macOS 14 or later. This repository does not provide Windows, Linux or mobile builds; check the platform before following installation steps.

## First run

1. Check macOS >= 14, `swift --version`, `/usr/bin/sqlite3 --version`, and available Codex/Claude executables. Do not accept system licenses or disable security settings for the user.
2. Run `swift test`. Tests use only generated temporary fixtures.
3. Read `config.example.json`; create the user's config outside this repo at the location described in README. Never copy an existing account's auth files, provider config, or API keys into this project.
4. Run `swift run acf doctor` with the user's configuration. It prints paths; keep its output local. Do not scan actual conversations unless that is part of the user's request.
5. Build with `./scripts/build-app.sh`; install with `./scripts/install-app.sh` only when installation is requested. Existing app bundles are not overwritten.

## Configuration contract

- Primary Codex, optional secondary Codex, and Claude roots are independent. Never merge equal session IDs across roots.
- Persisted index, aliases, and local archives belong under the configured profile state directory, never the Git repository.
- Executable settings accept a program name or path, not a shell command. Recovery commands must quote every dynamic argument.
- Permission-bypass flags are not defaults. Claude resume uses a subshell with `cd`, without a personal wrapper.
- Codex archive/unarchive changes the user's Codex state and requires explicit user intent. Use the same configured root as scanning, retain the GUI confirmation, and fail on unsupported CLI versions. Never patch SQLite directly.

## Development and verification

- `Sources/AgentConversationFinderCore`: scanning, streaming JSONL, digest, search/filter/sort, persistence, commands, configuration.
- `Sources/AgentConversationFinderApp`: native SwiftUI interface and state.
- `Sources/AgentConversationFinderCLI`: doctor and scan command.
- Use synthetic fixtures under `Tests`; no real transcript snippets, database snapshots, real IDs, screenshots, personal paths, or contact information.
- Run `swift test`, `./scripts/build-app.sh`, `swift run acf --help`, and `python3 scripts/check-release.py` after relevant edits.
- Preserve folder-first navigation, multi-source filters, pagination, safe local aliases, reversible archive, manual refresh, and per-account cache isolation.
- Review the exact Git diff and tracked file list before publication. The privacy script is a guardrail, not evidence that every possible identifier has been removed.
- Do not attach `scan --json`, caches, `.build`, `build`, `.env`, `config.json`, or user state to issues or pull requests. Never push private data merely because the repository is private.
