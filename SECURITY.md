# Privacy and security

The repository distributes source code and synthetic tests. It must not contain account credentials, real conversations, exported databases, personal screenshots, caches, local configuration, or build artifacts.

The app reads local conversation content and creates a sensitive search index. Display shortening is not anonymization: raw searchable text and paths remain in the index. Cache, alias and archive files are written with owner-only permissions; temporary SQLite and archive output directories are owner-only and removed after use. The app support directory should stay outside shared/cloud-synced projects. Backups follow your operating system's policies.

The application itself has no network client. The Codex executable invoked for archive/unarchive is third-party software under the user's control; its behavior and updates are outside this project's control. Recovery commands are copied for manual execution, preserve default permission prompts and explicitly select the source configuration directory. A malicious configured executable remains malicious; only configure trusted installations.

Do not publish raw errors, CLI scan output or screenshots before inspecting them: they can reveal paths, session identifiers or message text. Report a bug using an invented JSONL/SQLite example and the relevant software versions. In a private repository, share findings with its owner through the existing private collaboration channel; do not paste private records into public issues.

`python3 scripts/check-release.py` checks the tracked/candidate file inventory and common credentials/path patterns. It cannot guarantee privacy or detect every secret. Review staged diffs and Git history before sharing, and remove accidentally committed sensitive data from history before any push.
