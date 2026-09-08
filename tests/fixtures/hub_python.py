#!/usr/bin/env python3
"""Native-process protocol fixture. Ignores Python flags; never uses the network."""

import json
import sys
import time
from pathlib import Path

request = json.load(sys.stdin)
cfg, spec, op = request["config"], request["spec"], request["operation"]
cache = Path(cfg["cache_dir"])
cache.mkdir(parents=True, exist_ok=True)
with (cache / "fixture-requests.jsonl").open("a") as log:
    log.write(json.dumps(request) + "\n")
if spec.get("repo_id") == "example/slow":
    print(json.dumps({"event": "progress", "phase": "waiting", "completed": 0}), flush=True)
    time.sleep(30)

if op.startswith("preview_"):
    direction = op.removeprefix("preview_")
    files = sorted(spec["files"])
    preview = {
        "direction": direction,
        "repo_id": spec["repo_id"],
        "repo_type": spec.get("repo_type", "model"),
        "revision": spec.get("revision", "main"),
        "commit": "a" * 40,
        "private": False,
        "visibility": "public",
        "workspace": cfg["workspace"],
        "cache_dir": cfg["cache_dir"],
        "workspace_identity": {"dev": 1, "ino": 2},
        "total_bytes": 10 * len(files),
        "download_bytes": 10 * len(files),
        "cached_bytes": 0,
        "files": [],
    }
    for name in files:
        if direction == "download":
            preview["destination"] = spec["destination"]
            preview["files"].append(
                {
                    "path": name,
                    "local_path": spec["destination"] + "/" + name,
                    "size": 10,
                    "is_cached": False,
                    "will_download": True,
                    "local_before": None,
                }
            )
        else:
            preview["path_in_repo"] = spec.get("path_in_repo", "")
            preview["files"].append(
                {
                    "path": name,
                    "remote_path": "/".join(p for p in (spec.get("path_in_repo"), name) if p),
                    "size": 10,
                    "snapshot": {"sha256": "b" * 64, "size": 10},
                }
            )
    raw = json.dumps({"event": "result", "result": preview}) + "\n"
    sys.stdout.write(raw[:23])
    sys.stdout.flush()
    time.sleep(0.01)
    sys.stdout.write(raw[23:])
elif op in {"download", "upload"}:
    repo = spec["repo_id"]
    if repo == "example/auth-error":
        print(json.dumps({"event": "error", "message": "Hub access failed", "code": "failed"}))
        sys.exit(1)
    if repo == "example/xet-fail" and cfg["xet"] != "disabled":
        print(
            json.dumps(
                {"event": "error", "message": "Xet transport failed", "code": "xet_transport"}
            )
        )
        sys.exit(1)
    print(json.dumps({"event": "progress", "phase": "transferring", "completed": 1, "total": 1}))
    print(
        json.dumps(
            {
                "event": "result",
                "result": {
                    "direction": op,
                    "commit": request["preview"]["commit"],
                    "files": spec["files"],
                },
            }
        )
    )
elif op == "paper":
    print(json.dumps({"event": "result", "result": {"id": spec["id"], "title": "Offline paper"}}))
else:
    sys.exit(2)
