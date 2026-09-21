#!/usr/bin/env python3
"""End-to-end CLI regression using temporary, invented data only."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/acf").resolve()
if not binary.is_file():
    sys.exit("Build acf first: swift build --product acf")
with tempfile.TemporaryDirectory(prefix="acf-synthetic-") as temporary:
    root = pathlib.Path(temporary)
    primary, secondary, claude = (root / name for name in ("primary", "secondary", "claude"))
    for source in (primary, secondary):
        (source / "sessions").mkdir(parents=True)
        messages = [
            {"type": "session_meta", "payload": {"id": "same-fixture-id", "source": "cli", "cwd": "/tmp/synthetic-inventory", "timestamp": "2026-01-01T00:00:00Z"}},
            {"type": "event_msg", "timestamp": "2026-01-01T00:01:00Z", "payload": {"type": "user_message", "message": "Configure synthetic inventory index"}},
        ]
        (source / "sessions" / "fixture.jsonl").write_text("".join(json.dumps(x) + "\n" for x in messages))
    (claude / "projects" / "fixture").mkdir(parents=True)
    message = {"type": "user", "sessionId": "claude-fixture-id", "cwd": "/tmp/synthetic-inventory", "timestamp": "2026-01-01T00:00:00Z", "message": {"role": "user", "content": "Configure synthetic inventory index"}}
    (claude / "projects" / "fixture" / "claude-fixture-id.jsonl").write_text(json.dumps(message) + "\n")
    config = root / "config.json"
    config.write_text(json.dumps({"codexHome": str(primary), "secondaryCodexHome": str(secondary), "claudeHome": str(claude), "stateDirectory": str(root / "state")}))
    environment = {k: v for k, v in os.environ.items() if not k.startswith("ACF_")}
    environment["ACF_CONFIG"] = str(config)
    def run(*args):
        return subprocess.run([str(binary), *args], env=environment, capture_output=True, text=True, timeout=30)
    doctor = run("doctor")
    assert doctor.returncode == 0, doctor.stderr
    assert str(primary) in doctor.stdout and str(secondary) in doctor.stdout
    result = run("scan", "--query", "synthetic inventory", "--json")
    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert len(payload["records"]) == 3, payload
    assert not payload["warnings"], payload["warnings"]
    assert len({r["storageKey"] for r in payload["records"]}) == 3
    assert not (root / "state").exists(), "Stateless CLI should not write a cache"
    empty = run("scan", "--query", "unmatched fixture term", "--json")
    assert json.loads(empty.stdout)["records"] == []
    assert run("scan", "--query").returncode != 0
    config.write_text('{"unknownOption":"invalid"}')
    assert run("doctor").returncode != 0
print("CLI synthetic integration checks passed (three isolated sources, query, JSON, config errors, no cache writes).")
