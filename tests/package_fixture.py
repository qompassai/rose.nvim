"""Offline real-manager tests; retain isolated fixtures and logs for inspection."""

import argparse
import os
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEADLINE_SECONDS = 45
MAX_LOG_BYTES = 1024 * 1024
MAX_TREE_FILES = 5000
MAX_TREE_BYTES = 64 * 1024 * 1024


def run(command, env, cwd, log, quiet=False):
    with (
        log.open("wb") as output,
        subprocess.Popen(
            command,
            env=env,
            cwd=cwd,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        ) as process,
    ):
        try:
            code = process.wait(timeout=DEADLINE_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise SystemExit(f"Deadline exceeded ({DEADLINE_SECONDS}s): {log}")
    if log.stat().st_size > MAX_LOG_BYTES:
        raise SystemExit(f"Package-test output exceeded {MAX_LOG_BYTES} bytes: {log}")
    text = log.read_text(errors="replace")
    if not quiet:
        print(text, end="" if text.endswith("\n") else "\n", flush=True)
    if code:
        raise SystemExit(f"Package fixture failed (exit {code}): {log}")
    return text


def environment(base, lazy):
    # An allowlist excludes credentials, Git overrides and executable user config.
    env = {key: os.environ[key] for key in ("PATH", "SYSTEMROOT") if key in os.environ}
    env.update(
        HOME=str(base / "home"),
        LANG="C.UTF-8",
        NVIM_APPNAME="nvim",
        GIT_CONFIG_NOSYSTEM="1",
        GIT_CONFIG_GLOBAL=os.devnull,
        GIT_TERMINAL_PROMPT="0",
        GIT_ALLOW_PROTOCOL="file",
        ROSE_PACKAGE_ROOT=str(ROOT),
        LAZY_ROOT=lazy,
    )
    for name in ("CONFIG", "DATA", "CACHE", "STATE"):
        path = base / name.lower()
        path.mkdir(parents=True)
        env[f"XDG_{name}_HOME"] = str(path)
    (base / "home").mkdir()
    (base / "work").mkdir()
    return env


def overlay(destination, env, base):
    """Keep the installed .git; test current tracked AND nonignored untracked files.

    vim.pack's local clone contains HEAD, not edits. Overlay before any Rose load,
    including deletions, so passing tests cannot accidentally validate old code.
    """
    listing = run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        env,
        ROOT,
        base / "overlay-files.log",
        quiet=True,
    )
    files = sorted(set(filter(None, listing.split("\0"))))
    if len(files) > MAX_TREE_FILES:
        raise SystemExit("Current tree exceeds package fixture file limit")
    size = 0
    for name in files:
        relative = Path(name)
        if relative.is_absolute() or {"..", ".git"}.intersection(relative.parts):
            raise SystemExit(f"Unsafe overlay path: {name}")
        source, target = ROOT / relative, destination / relative
        if not source.exists():
            target.unlink(missing_ok=True)
            continue
        if not source.is_file() or source.is_symlink():
            raise SystemExit(f"Overlay requires a regular file: {name}")
        size += source.stat().st_size
        if size > MAX_TREE_BYTES:
            raise SystemExit("Current tree exceeds package fixture byte limit")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    print(
        f"Overlay: {len(files)} current-tree paths, {size} bytes; .git not copied",
        flush=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--static", action="store_true", help="no manager installation required"
    )
    args = parser.parse_args()
    nvim = shutil.which(os.environ.get("NVIM", "nvim"))
    if not nvim:
        raise SystemExit("NVIM must name an installed Neovim executable")
    lazy = os.environ.get("LAZY_ROOT", "")
    if not args.static:
        if not lazy or not (Path(lazy) / "lua/lazy/init.lua").is_file():
            raise SystemExit(
                "LAZY_ROOT must name an existing real lazy.nvim checkout (no skip)"
            )
        lazy = str(Path(lazy).resolve())
    base = Path(tempfile.mkdtemp(prefix="rose-packages-"))
    print(f"Package fixture logs and isolated XDG roots: {base}", flush=True)
    cases = (
        ["static"]
        if args.static
        else ["pack", "lazy-speech", "lazy-webui", "lazy-eager"]
    )
    for case in cases:
        directory = base / case
        env = environment(directory, lazy)
        command = [
            nvim,
            "--headless",
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-n",
            "-l",
            str(ROOT / "tests/packages.lua"),
        ]
        if case == "pack":
            run(
                command + ["pack-install"],
                env,
                directory / "work",
                directory / "install.log",
            )
            installed = directory / "data/nvim/site/pack/core/opt/rose.nvim"
            if not (installed / ".git").exists():
                raise SystemExit(
                    "vim.pack did not install the expected local Git package"
                )
            overlay(installed, env, directory)
            case = "pack-load"
        run(command + [case], env, directory / "work", directory / "result.log")
    print(f"PASS {len(cases)} isolated package case(s)", flush=True)


if __name__ == "__main__":
    main()
