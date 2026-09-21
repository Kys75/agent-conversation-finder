#!/usr/bin/env python3
"""Check tracked files (or a clean pre-git allowlist) without reading user data."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
try:
    git_root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
    if pathlib.Path(git_root).resolve() != root:
        raise ValueError("Not an independent repository yet")
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode().split("\0")
    paths = [root / name for name in names if name]
except (subprocess.CalledProcessError, ValueError, FileNotFoundError):
    paths = [p for p in root.rglob("*") if p.is_file() and not any(part in (".git", ".build", "build", "__pycache__") for part in p.relative_to(root).parts)]

allowed_root = {"Package.swift", "Info.plist", "README.md", "AGENTS.md", "SECURITY.md", "PROVENANCE.md", ".gitignore", "config.example.json"}
errors = []
for path in paths:
    rel = path.relative_to(root)
    allowed = (str(rel) in allowed_root or str(rel) == "Assets/AppIcon.icns" or
               rel.parts[0] in ("Sources", "Tests") and path.suffix == ".swift" or
               rel.parts[0] == "docs" and path.suffix == ".md" or
               rel.parts[0] == "scripts" and path.suffix in (".sh", ".py") or
               str(rel) == ".github/workflows/ci.yml")
    if not allowed or path.is_symlink():
        errors.append(f"Unexpected release file: {rel}")
        continue
    if str(rel) == "Assets/AppIcon.icns":
        data = path.read_bytes()
        if not data.startswith(b"icns") or b"/Users/" in data or b"bplist00" in data:
            errors.append("Unexpected icon metadata")
        continue
    text = path.read_text(encoding="utf-8")
    if str(pathlib.Path.home()) in text:
        errors.append(f"Current user's home path in {rel}")
    if re.search(r"(?:gh[pousr]_[A-Za-z0-9]{25,}|sk-[A-Za-z0-9_-]{25,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)", text):
        errors.append(f"Possible credential in {rel}")
    if re.search(r"/Users/(?!fixture(?:/|\b)|test(?:/|\b))[A-Za-z0-9._-]+/", text):
        errors.append(f"Non-fixture macOS user path in {rel}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Release file checks passed ({len(paths)} files). Manual review is still required.")
