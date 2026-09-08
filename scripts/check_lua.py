"""Run the strict LuaLS profile with this Neovim's runtime; never fetch addons."""

import argparse
import json
import os
import re
import signal
import subprocess
import tempfile
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlparse


def run(command, timeout, **kwargs):
    """Bound the entire checker process group, including LuaLS's worker."""
    with subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=os.name != "nt",
        **kwargs,
    ) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                process.kill()
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise SystemExit(f"Validation command exceeded {timeout} seconds: {command[0]}")
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def discover_runtime(nvim):
    # A clean editor discovers the runtime belonging to the selected executable,
    # without loading user plugins, executable project config, or network addons.
    result = run(
        [
            nvim,
            "--headless",
            "-u",
            "NONE",
            "--cmd",
            "lua io.stdout:write(vim.env.VIMRUNTIME)",
            "+qa",
        ],
        timeout=15,
    )
    result.check_returncode()
    runtime = Path(result.stdout.strip())
    if not (runtime / "lua" / "vim" / "_meta.lua").is_file():
        raise SystemExit("Neovim runtime metadata was not found")
    return runtime


def expected_files(root, settings):
    listed = run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.lua"],
        timeout=15,
        cwd=root,
    )
    listed.check_returncode()
    ignored = set(settings["workspace"]["ignoreDir"])
    paths = sorted(
        {
            name
            for name in listed.stdout.split("\0")
            if name and not ignored.intersection(Path(name).parts)
        }
    )
    if not paths or len(paths) > settings["workspace"]["maxPreload"]:
        raise SystemExit("Lua workspace is empty or exceeds the profile's preload limit")
    for name in paths:
        if (root / name).stat().st_size > settings["workspace"]["preloadFileSize"] * 1024:
            raise SystemExit(f"Lua file exceeds the profile's preload size limit: {name}")
    return paths


def check(root, output, runtime, luals):
    settings = json.loads((root / ".luarc.json").read_text())
    settings["workspace"]["library"] = [str(runtime)]
    # Older runtimes do not bundle UV declarations. Use LuaLS's installed luv
    # addon in that case; do not load duplicate classes on newer Neovim.
    if not (runtime / "lua" / "uv" / "_meta.lua").is_file():
        settings["workspace"]["library"].append("${3rd}/luv/library")
    paths = expected_files(root, settings)
    (output / "files.json").write_text(json.dumps(paths, indent=2) + "\n")
    config = output / "settings.json"
    config.write_text(json.dumps(settings, indent=2) + "\n")
    diagnostics = output / "diagnostics.json"
    # A previous result must never be mistaken for the current run.
    with tempfile.TemporaryDirectory(prefix="rose-luals-run-") as run_dir:
        raw = Path(run_dir) / "diagnostics.json"
        command = [
            luals,
            f"--check={root}",
            f"--configpath={config}",
            "--checklevel=Hint",
            "--check_format=json",
            "--locale=en-us",
            f"--check_out_path={raw}",
            f"--logpath={output / 'logs'}",
        ]
        checked = run(command, timeout=120)
        console = checked.stdout + checked.stderr
        (output / "console.log").write_text(console)
        if not raw.is_file():
            raise SystemExit(f"LuaLS produced no report (exit {checked.returncode}); see {output}")
        data = json.loads(raw.read_text())
    # LuaLS 3.19.1 serializes an empty diagnostics map as [], not {}.
    if data == []:
        data = {}
    if not isinstance(data, dict):
        raise SystemExit(f"LuaLS produced an invalid diagnostics map; see {output}")
    total = sum(len(items) for items in data.values())
    expected_exit = 1 if total else 0
    progress = re.findall(r"[>=]{20}\s+(\d+)/(\d+)", console)
    if checked.returncode != expected_exit:
        raise SystemExit(f"Unexpected LuaLS exit {checked.returncode}; see {output}")
    completion = (
        "Diagnosis completed, no problems found"
        if not total
        else (f"Diagnosis complete, {total} problems found")
    )
    if (
        completion not in console
        or not progress
        or tuple(map(int, progress[-1])) != (len(paths), len(paths))
    ):
        raise SystemExit(f"LuaLS completion/coverage could not be verified; see {output}")
    diagnostics.write_text(json.dumps(data, indent=2) + "\n")
    records = []
    for uri, items in data.items():
        filename = Path(unquote(urlparse(uri).path)).relative_to(root).as_posix()
        for item in items:
            records.append({"file": filename, **item})
    return records, len(paths)


def counts(records):
    return {
        "total": len(records),
        "codes": dict(sorted(Counter(x["code"] for x in records).items())),
        "severities": dict(sorted(Counter(x["severity"] for x in records).items())),
        "files": dict(sorted(Counter(x["file"] for x in records).items())),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=("runtime", "all"), default="runtime")
    parser.add_argument("--output", type=Path, help="keep settings, diagnostics and counts here")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    runtime = discover_runtime(os.environ.get("NVIM", "nvim"))
    output = (args.output or Path(tempfile.mkdtemp(prefix="rose-luals-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    records, checked_files = check(
        root, output, runtime, os.environ.get("LUALS", "lua-language-server")
    )
    # LuaLS always checks every repository Lua file, including tests/legacy.
    # Scope changes only the reported gate, never workspace/type-check settings.
    selected = [
        item
        for item in records
        if args.scope == "all" or not item["file"].startswith(("tests/", "scripts/"))
    ]
    summary = {
        "scope": args.scope,
        "runtime": str(runtime),
        "checked_files": checked_files,
        "whole_repository": counts(records),
        "selected": counts(selected),
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    print(f"Full diagnostics: {output / 'diagnostics.json'}")
    return 1 if selected else 0


if __name__ == "__main__":
    raise SystemExit(main())
