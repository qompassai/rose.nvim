#!/usr/bin/env python3
"""Rose's explicit-user Hub worker. JSON in on stdin, bounded JSONL events out.

No models are loaded or executed. The official SDK owns all network, auth,
Xet, retries and Hub cache behavior. Importing this module does no I/O.
"""

from __future__ import annotations

import concurrent.futures
import contextlib
import hashlib
import importlib.metadata
import inspect
import json
import os
import re
import stat
import sys
from pathlib import Path

ENDPOINT = "https://huggingface.co"
MAX_INPUT = 8 * 1024 * 1024
SHA = re.compile(r"^[a-fA-F0-9]{40,64}$")
SECRET_NAMES = {
    ".git",
    ".env",
    ".ssh",
    ".aws",
    ".azure",
    ".gnupg",
    ".netrc",
    ".npmrc",
    ".docker",
    ".kube",
    ".pypirc",
    ".huggingface",
    ".cache",
    "credentials",
    "credentials.json",
    "service-account.json",
    "service_account.json",
    "token",
    "tokens",
    "id_rsa",
    "id_dsa",
    "id_ecdsa",
    "id_ed25519",
    "authorized_keys",
}
SECRET_SUFFIXES = (".pem", ".key", ".p12", ".pfx", ".keystore", ".jks")


class GuardError(Exception):
    """A safe, locally generated message that may be shown to a user."""


def require(condition, message):
    if not condition:
        raise GuardError(message)


def emit(event, **data):
    print(json.dumps({"event": event, **data}, ensure_ascii=True), flush=True)


def text(value, label, maximum=1024):
    require(isinstance(value, str) and 0 < len(value) <= maximum, f"invalid {label}")
    require(value.isprintable(), f"control or invisible character in {label}")
    return value


def relative(value, label="path", empty=False):
    if value == "" and empty:
        return ""
    value = text(value, label)
    require(
        not value.startswith(("/", "~")) and "\\" not in value and ":" not in value,
        f"{label} must be relative",
    )
    parts = value.split("/")
    require(
        all(p not in ("", ".", "..") for p in parts), f"traversal or empty component in {label}"
    )
    require(not any(c in value for c in "*?[]"), f"wildcards are not permitted in {label}")
    return value


def safe_asset(path):
    for part in path.split("/"):
        name = part.lower()
        require(
            name not in SECRET_NAMES
            and not name.startswith(
                (
                    ".env",
                    "id_rsa.",
                    "id_ed25519.",
                    "credentials.",
                    "credentials-",
                    "secrets.",
                    "service-account",
                    "service_account",
                )
            ),
            "sensitive files/directories are not permitted",
        )
        require(not name.endswith(SECRET_SUFFIXES), "keyfiles are not permitted")
    return path


def integer(value, label, minimum, maximum):
    require(type(value) is int and minimum <= value <= maximum, f"invalid {label}")
    return value


def absolute(value, label):
    value = text(value, label, 4096)
    require(os.path.isabs(value) and "\\" not in value, f"{label} must be absolute")
    require(all(p not in (".", "..") for p in value.split("/")), f"invalid {label}")
    return os.path.normpath(value)


def check_directory(path, create=False):
    """No symlinks in even the absolute ancestry. Do not resolve through aliases."""
    require(
        os.name == "posix" and hasattr(os, "O_NOFOLLOW"),
        "secure transfers require POSIX O_NOFOLLOW",
    )
    current = Path("/")
    for part in Path(path).parts[1:]:
        current /= part
        if create:
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                pass
        st = current.lstat()
        require(stat.S_ISDIR(st.st_mode), "directory is missing, not a directory, or a symlink")
    return str(current)


@contextlib.contextmanager
def directory_fd(root, parent="", create=False):
    """Walk descriptors with NOFOLLOW, retaining the real parent for all file I/O."""
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        components = Path(root).parts[1:] + tuple(parent.split("/") if parent else [])
        for part in components:
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        yield fd
    finally:
        os.close(fd)


def stat_record(st):
    return {key: getattr(st, "st_" + key) for key in ("dev", "ino", "size", "mtime_ns", "ctime_ns")}


def root_record(root):
    with directory_fd(root) as fd:
        st = os.fstat(fd)
        return {"dev": st.st_dev, "ino": st.st_ino}


@contextlib.contextmanager
def source_file(root, name):
    parent, _, leaf = name.rpartition("/")
    with directory_fd(root, parent) as parent_fd:
        fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        with os.fdopen(fd, "rb") as stream:
            st = os.fstat(stream.fileno())
            require(
                stat.S_ISREG(st.st_mode) and st.st_nlink == 1,
                "selected files must be regular files, not symlinks or hardlinks",
            )
            yield stream, st


def fingerprint(root, name, absent=False, maximum=None):
    try:
        with source_file(root, name) as (stream, before):
            if maximum is not None:
                require(before.st_size <= maximum, "selected file exceeds max_total_bytes")
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
            require(
                stat_record(before) == stat_record(os.fstat(stream.fileno())),
                "file changed while reading",
            )
            return {**stat_record(before), "sha256": digest.hexdigest()}
    except FileNotFoundError:
        if absent:
            return None
        raise GuardError("selected file is missing") from None


def validate(request):
    require(isinstance(request, dict), "request must be an object")
    require(set(request) <= {"operation", "config", "spec", "preview"}, "unknown request field")
    operation = request.get("operation")
    require(
        operation in {"probe", "paper", "preview_download", "download", "preview_upload", "upload"},
        "unknown operation",
    )
    cfg = request.get("config", {})
    require(isinstance(cfg, dict), "config must be an object")
    require(
        set(cfg)
        <= {
            "workspace",
            "trusted",
            "cache_dir",
            "xet_cache",
            "max_workers",
            "xet",
            "high_performance",
            "max_files",
            "max_total_bytes",
        },
        "unknown config field",
    )
    cfg = {
        "max_workers": 4,
        "max_files": 256,
        "max_total_bytes": 10 * 1024**3,
        "trusted": False,
        "xet": "auto",
        "high_performance": False,
        **cfg,
    }
    cfg["workspace"] = absolute(cfg.get("workspace"), "workspace")
    cfg["cache_dir"] = absolute(cfg.get("cache_dir"), "cache_dir")
    check_directory(cfg["workspace"])
    require(
        cfg["cache_dir"] != cfg["workspace"]
        and not cfg["cache_dir"].startswith(cfg["workspace"].rstrip("/") + "/"),
        "cache_dir must be outside workspace",
    )
    integer(cfg["max_workers"], "max_workers", 1, 16)
    integer(cfg["max_files"], "max_files", 1, 4096)
    integer(cfg["max_total_bytes"], "max_total_bytes", 1, 2**53 - 1)
    require(
        type(cfg["trusted"]) is bool and type(cfg["high_performance"]) is bool,
        "invalid config boolean",
    )
    require(cfg["xet"] in {"auto", "disabled"}, "invalid xet option")
    if cfg.get("xet_cache"):
        cfg["xet_cache"] = absolute(cfg["xet_cache"], "xet_cache")
    spec = request.get("spec", {})
    require(isinstance(spec, dict), "spec must be an object")
    if operation == "probe":
        require(not spec, "probe has no spec")
        return operation, cfg, spec
    if operation == "paper":
        require(set(spec) == {"id"}, "paper metadata requires only id")
        require(
            re.fullmatch(
                r"(?:\d{4}\.\d{4,5}|[A-Za-z-]+(?:\.[A-Za-z-]+)?/\d{7})(?:v\d+)?",
                text(spec["id"], "paper id", 128),
            )
            is not None,
            "invalid arXiv paper id",
        )
        return operation, cfg, spec
    upload = operation.endswith("upload")
    allowed = {"repo_id", "repo_type", "revision", "files", "dry_run"}
    allowed |= {"path_in_repo"} if upload else {"destination"}
    require(
        set(spec) <= allowed,
        "unknown transfer field (tokens, URLs and approval booleans are forbidden)",
    )
    spec = {"repo_type": "model", "revision": "main", **spec}
    require(
        re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)?",
            text(spec.get("repo_id"), "repo_id", 192),
        )
        is not None,
        "invalid repo_id",
    )
    require(".." not in spec["repo_id"] and "--" not in spec["repo_id"], "invalid repo_id")
    require(
        spec["repo_type"] in {"model", "dataset"},
        "repo_type must be model or dataset; papers are assets",
    )
    text(spec["revision"], "revision", 256)
    require(
        not spec["revision"].startswith("-") and not any(c in spec["revision"] for c in "\\\t\n"),
        "invalid revision",
    )
    require(type(spec.get("dry_run", False)) is bool, "invalid dry_run")
    files = spec.get("files")
    require(
        isinstance(files, list) and 0 < len(files) <= cfg["max_files"],
        "select 1..max_files explicit files",
    )
    spec["files"] = sorted(safe_asset(relative(f, "selected file")) for f in files)
    require(len(set(spec["files"])) == len(files), "duplicate selected file")
    # A file cannot also be an ancestor of another selection.
    for a, b in zip(spec["files"], spec["files"][1:], strict=False):
        require(not b.startswith(a + "/"), "selected file is also a directory")
    if upload:
        require(cfg["trusted"], "upload requires a trusted workspace configured by the user")
        spec["path_in_repo"] = safe_asset(
            relative(spec.get("path_in_repo", ""), "path_in_repo", empty=True)
        )
    else:
        spec["destination"] = safe_asset(relative(spec.get("destination"), "destination"))
    return operation, cfg, spec


def environment(cfg):
    """Must precede importing the official SDK; never read HF_TOKEN here."""
    os.environ["HF_ENDPOINT"] = ENDPOINT
    os.environ["HF_HUB_CACHE"] = cfg["cache_dir"] + "/hub"
    os.environ["HF_XET_CACHE"] = cfg.get("xet_cache") or cfg["cache_dir"] + "/xet"
    os.environ["HF_XET_HIGH_PERFORMANCE"] = "1" if cfg["high_performance"] else "0"
    os.environ["HF_XET_HP"] = os.environ["HF_XET_HIGH_PERFORMANCE"]
    # Explicit disable in the user's environment always wins over auto mode.
    if cfg["xet"] == "disabled":
        os.environ["HF_HUB_DISABLE_XET"] = "1"
    os.environ["HF_DEBUG"] = "0"
    os.environ["HF_HUB_VERBOSITY"] = "error"
    os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    # hf_xet treats this value as a filesystem path, not a stream name.
    # Discard native SDK logs so signed URLs cannot persist in a local log.
    os.environ["HF_XET_LOG_DEST"] = os.devnull
    os.environ["HF_XET_LOG_LEVEL"] = "error"
    n = str(cfg["max_workers"])
    # Official current xet-core bounds; older versions may ignore new controls.
    os.environ.pop("HF_XET_FIXED_UPLOAD_CONCURRENCY", None)
    os.environ.pop("HF_XET_FIXED_DOWNLOAD_CONCURRENCY", None)
    for direction in ("UPLOAD", "DOWNLOAD"):
        for key, value in (("INITIAL", "1"), ("MIN", "1"), ("MAX", n)):
            os.environ[f"HF_XET_CLIENT_AC_{key}_{direction}_CONCURRENCY"] = value
    os.environ["HF_XET_DATA_MAX_CONCURRENT_FILE_INGESTION"] = n
    os.environ["HF_XET_NUM_CONCURRENT_RANGE_GETS"] = n


def supports(fn, key):
    return key in inspect.signature(fn).parameters


def sdk_load(cfg):
    environment(cfg)
    for path in (
        cfg["cache_dir"],
        cfg["cache_dir"] + "/hub",
        cfg.get("xet_cache") or cfg["cache_dir"] + "/xet",
    ):
        check_directory(path, create=True)
    try:
        import huggingface_hub as hub
    except ImportError:
        raise GuardError(
            "optional huggingface_hub is missing; install it in the configured Python environment"
        ) from None
    # An installed but broken optional binary must not break normal HTTP transfers.
    disabled = os.environ.get("HF_HUB_DISABLE_XET", "").upper() in {"1", "ON", "YES", "TRUE"}
    try:
        xet_version = importlib.metadata.version("hf-xet")
        if not disabled:
            import hf_xet  # noqa: F401
    except (ImportError, OSError, importlib.metadata.PackageNotFoundError):
        disabled = True
        xet_version = None
    if disabled:
        os.environ["HF_HUB_DISABLE_XET"] = "1"
        from huggingface_hub import constants

        constants.HF_HUB_DISABLE_XET = True
    api = hub.HfApi(endpoint=ENDPOINT)
    return (
        hub,
        api,
        {
            "hub_version": hub.__version__,
            "xet_version": xet_version,
            "transport": "http" if disabled else "xet",
            "download_dry_run": supports(hub.hf_hub_download, "dry_run"),
            "upload_folder": callable(getattr(api, "upload_folder", None)),
            "paper_info": callable(getattr(api, "paper_info", None)),
            "max_workers": cfg["max_workers"],
        },
    )


def repository(api, spec, files_metadata=False):
    info = api.repo_info(
        repo_id=spec["repo_id"],
        repo_type=spec["repo_type"],
        revision=spec["revision"],
        files_metadata=files_metadata,
    )
    require(isinstance(getattr(info, "private", None), bool), "repository visibility unavailable")
    require(
        isinstance(getattr(info, "sha", None), str) and SHA.fullmatch(info.sha),
        "repository has no usable commit; select an existing initialized repository",
    )
    return info


def base_preview(cfg, spec, info, capabilities, direction):
    return {
        "direction": direction,
        "repo_id": spec["repo_id"],
        "repo_type": spec["repo_type"],
        "revision": spec["revision"],
        "commit": info.sha,
        "private": info.private,
        "visibility": "private" if info.private else "public",
        "workspace": cfg["workspace"],
        "workspace_identity": root_record(cfg["workspace"]),
        "cache_dir": cfg["cache_dir"],
        "capabilities": capabilities,
        "files": [],
    }


def preview_upload(cfg, spec, api, capabilities):
    # Hash before any network call, so unsafe source paths never send even metadata.
    rows = []
    for name in spec["files"]:
        record = fingerprint(cfg["workspace"], name, maximum=cfg["max_total_bytes"])
        remote = "/".join(p for p in (spec["path_in_repo"], name) if p)
        rows.append(
            {"path": name, "remote_path": remote, "size": record["size"], "snapshot": record}
        )
        require(
            sum(r["size"] for r in rows) <= cfg["max_total_bytes"], "upload exceeds max_total_bytes"
        )
        emit("progress", phase="hashing", completed=len(rows), total=len(spec["files"]))
    info = repository(api, spec)
    preview = base_preview(cfg, spec, info, capabilities, "upload")
    preview.update(
        files=rows, path_in_repo=spec["path_in_repo"], total_bytes=sum(r["size"] for r in rows)
    )
    return preview


def target_name(spec, name):
    return spec["destination"] + "/" + name


def preview_download(cfg, spec, hub, api, capabilities):
    # Inspect all destination ancestors and existing files before Hub contact.
    local = {
        name: fingerprint(
            cfg["workspace"], target_name(spec, name), absent=True, maximum=cfg["max_total_bytes"]
        )
        for name in spec["files"]
    }
    info = repository(api, spec, files_metadata=True)
    preview = base_preview(cfg, spec, info, capabilities, "download")
    metadata = {s.rfilename: s for s in (getattr(info, "siblings", None) or [])}

    def inspect_file(name):
        if capabilities["download_dry_run"]:
            dry = hub.hf_hub_download(
                repo_id=spec["repo_id"],
                repo_type=spec["repo_type"],
                revision=info.sha,
                filename=name,
                cache_dir=cfg["cache_dir"] + "/hub",
                dry_run=True,
            )
            require(
                dry.filename == name and dry.commit_hash == info.sha, "dry-run identity mismatch"
            )
            size, cached = dry.file_size, dry.is_cached
        else:
            item = metadata.get(name)
            require(item is not None, "selected file not found at previewed commit")
            size = getattr(item, "size", None)
            cached_path = hub.try_to_load_from_cache(
                spec["repo_id"],
                name,
                revision=info.sha,
                repo_type=spec["repo_type"],
                cache_dir=cfg["cache_dir"] + "/hub",
            )
            cached = isinstance(cached_path, str) and Path(cached_path).is_file()
        integer(size, "file size from Hub", 0, 2**53 - 1)
        return {
            "path": name,
            "local_path": target_name(spec, name),
            "size": size,
            "is_cached": bool(cached),
            "will_download": not bool(cached),
            "local_before": local[name],
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=cfg["max_workers"]) as pool:
        rows = list(pool.map(inspect_file, spec["files"]))
    total = sum(row["size"] for row in rows)
    require(total <= cfg["max_total_bytes"], "download exceeds max_total_bytes")
    preview.update(
        files=rows,
        destination=spec["destination"],
        total_bytes=total,
        download_bytes=sum(row["size"] for row in rows if row["will_download"]),
        cached_bytes=sum(row["size"] for row in rows if row["is_cached"]),
    )
    return preview


def approved_preview(request, cfg, spec, direction):
    preview = request.get("preview")
    require(isinstance(preview, dict), "execution requires an approved preview")
    require(preview.get("direction") == direction, "preview direction mismatch")
    for key in ("repo_id", "repo_type", "revision"):
        require(preview.get(key) == spec[key], "preview repository/revision mismatch")
    require(
        preview.get("workspace") == cfg["workspace"]
        and preview.get("cache_dir") == cfg["cache_dir"],
        "preview configuration mismatch",
    )
    require(
        preview.get("workspace_identity") == root_record(cfg["workspace"]), "workspace root changed"
    )
    require(SHA.fullmatch(preview.get("commit", "")), "invalid preview commit")
    require(type(preview.get("private")) is bool, "preview visibility missing")
    require(
        isinstance(preview.get("files"), list)
        and [r.get("path") for r in preview["files"]] == spec["files"],
        "preview file manifest mismatch",
    )
    key = "path_in_repo" if direction == "upload" else "destination"
    require(preview.get(key) == spec[key], "preview destination mismatch")
    sizes = [
        integer(r.get("size"), "preview size", 0, cfg["max_total_bytes"]) for r in preview["files"]
    ]
    require(
        sum(sizes) <= cfg["max_total_bytes"] and preview.get("total_bytes") == sum(sizes),
        "preview byte total mismatch",
    )
    return preview


def atomic_copy(stream, root, name, expected_hash=None, expected_size=None, readonly=False):
    parent, _, leaf = name.rpartition("/")
    with directory_fd(root, parent, create=True) as fd:
        tmp = ".rose-" + os.urandom(16).hex()
        out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            digest, size = hashlib.sha256(), 0
            with os.fdopen(out, "wb") as dest:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    size += len(chunk)
                    require(
                        expected_size is None or size <= expected_size, "file exceeds approved size"
                    )
                    dest.write(chunk)
                    digest.update(chunk)
                require(expected_size is None or size == expected_size, "file size changed")
                require(
                    expected_hash is None or digest.hexdigest() == expected_hash,
                    "file content changed",
                )
                dest.flush()
                os.fsync(dest.fileno())
                if readonly:
                    os.fchmod(dest.fileno(), 0o400)
            os.replace(tmp, leaf, src_dir_fd=fd, dst_dir_fd=fd)
        finally:
            try:
                os.unlink(tmp, dir_fd=fd)
            except FileNotFoundError:
                pass


def stage_upload(cfg, spec, preview):
    for row in preview["files"]:
        require(
            row["remote_path"] == "/".join(p for p in (spec["path_in_repo"], row["path"]) if p),
            "preview remote path mismatch",
        )
        require(
            fingerprint(cfg["workspace"], row["path"], maximum=cfg["max_total_bytes"])
            == row["snapshot"],
            "source changed after preview; request a new preview",
        )
    manifest_id = hashlib.sha256(json.dumps(preview, sort_keys=True).encode()).hexdigest()
    stage = cfg["cache_dir"] + "/staging/" + manifest_id
    check_directory(stage, create=True)
    for i, row in enumerate(preview["files"], 1):
        with source_file(cfg["workspace"], row["path"]) as (stream, before):
            require(
                stat_record(before) == {k: row["snapshot"][k] for k in stat_record(before)},
                "source changed while staging",
            )
            atomic_copy(
                stream, stage, row["path"], row["snapshot"]["sha256"], row["size"], readonly=True
            )
            require(
                stat_record(before) == stat_record(os.fstat(stream.fileno())),
                "source changed while staging",
            )
        emit("progress", phase="staging", completed=i, total=len(preview["files"]))
    # Another file might have changed while later files were copied.
    for row in preview["files"]:
        require(
            fingerprint(cfg["workspace"], row["path"], maximum=cfg["max_total_bytes"])
            == row["snapshot"],
            "source changed after preview; request a new preview",
        )
    return stage


def execute_upload(cfg, spec, preview, hub, api, capabilities):
    stage = stage_upload(cfg, spec, preview)
    info = repository(api, spec)
    require(
        info.sha == preview["commit"] and info.private == preview["private"],
        "repository commit or visibility changed; request a new preview",
    )
    common = {
        "repo_id": spec["repo_id"],
        "repo_type": spec["repo_type"],
        "revision": spec["revision"],
        "parent_commit": preview["commit"],
        "commit_message": "Upload explicitly selected assets with Rose",
    }
    emit(
        "progress",
        phase="uploading",
        completed=0,
        total=len(spec["files"]),
        transport=capabilities["transport"],
    )
    if capabilities["transport"] == "xet" and capabilities["upload_folder"]:
        require(
            supports(api.upload_folder, "parent_commit"),
            "installed upload_folder lacks parent_commit; upgrade SDK",
        )
        kwargs = dict(
            common,
            folder_path=stage,
            path_in_repo=spec["path_in_repo"],
            allow_patterns=spec["files"],
        )
        # Never pass undocumented worker arguments; future versions may expose one.
        for key in ("max_workers", "num_threads"):
            if supports(api.upload_folder, key):
                kwargs[key] = cfg["max_workers"]
        result = api.upload_folder(**kwargs)
        strategy = "official-upload-folder"
    else:
        # Official bounded HTTP compatibility path; no deletion operations.
        require(
            supports(api.create_commit, "parent_commit")
            and supports(api.create_commit, "num_threads"),
            "installed create_commit lacks safe compatibility controls; upgrade SDK",
        )
        operations = [
            hub.CommitOperationAdd(
                path_in_repo=row["remote_path"], path_or_fileobj=stage + "/" + row["path"]
            )
            for row in preview["files"]
        ]
        result = api.create_commit(**common, operations=operations, num_threads=cfg["max_workers"])
        strategy = "official-http-commit"
    return {
        "direction": "upload",
        "repo_id": spec["repo_id"],
        "repo_type": spec["repo_type"],
        "revision": spec["revision"],
        "commit": getattr(result, "oid", None),
        "strategy": strategy,
        "files": spec["files"],
        "total_bytes": preview["total_bytes"],
    }


def execute_download(cfg, spec, preview, hub):
    for row in preview["files"]:
        require(row["local_path"] == target_name(spec, row["path"]), "preview destination mismatch")
        require(
            fingerprint(
                cfg["workspace"], row["local_path"], absent=True, maximum=cfg["max_total_bytes"]
            )
            == row["local_before"],
            "destination changed after preview",
        )

    def transfer(row):
        cached = hub.hf_hub_download(
            repo_id=spec["repo_id"],
            repo_type=spec["repo_type"],
            revision=preview["commit"],
            filename=row["path"],
            cache_dir=cfg["cache_dir"] + "/hub",
        )
        # Official cache snapshots may be symlinks to blobs; resolve ONLY in cache.
        cache_root = Path(cfg["cache_dir"] + "/hub").resolve()
        resolved = Path(cached).resolve(strict=True)
        require(resolved.is_relative_to(cache_root), "SDK cache path escaped configured Hub cache")
        require(
            resolved.is_file() and resolved.stat().st_size == row["size"],
            "download size differs from preview",
        )
        return resolved

    files = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=cfg["max_workers"]) as pool:
        cached_files = []
        for cached in pool.map(transfer, preview["files"]):
            cached_files.append(cached)
            emit(
                "progress",
                phase="downloading",
                completed=len(cached_files),
                total=len(preview["files"]),
            )
    # Publish only after all network transfers finish. A known Xet error can safely
    # fall back using the same pinned cache without invalidating destination state.
    assert len(preview["files"]) == len(cached_files), "every previewed file must be cached"
    for row, cached in zip(preview["files"], cached_files, strict=True):
        require(
            fingerprint(
                cfg["workspace"], row["local_path"], absent=True, maximum=cfg["max_total_bytes"]
            )
            == row["local_before"],
            "destination changed during transfer",
        )
        require(
            root_record(cfg["workspace"]) == preview["workspace_identity"], "workspace root changed"
        )
        with source_file(
            cfg["cache_dir"] + "/hub", str(cached.relative_to(cfg["cache_dir"] + "/hub"))
        ) as (stream, _):
            atomic_copy(stream, cfg["workspace"], row["local_path"], expected_size=row["size"])
        files.append(row["local_path"])
    return {
        "direction": "download",
        "repo_id": spec["repo_id"],
        "repo_type": spec["repo_type"],
        "commit": preview["commit"],
        "files": files,
        "total_bytes": preview["total_bytes"],
    }


def paper_info(spec, api):
    require(
        callable(getattr(api, "paper_info", None)),
        "installed SDK lacks paper_info; upgrade huggingface_hub",
    )
    paper = api.paper_info(id=spec["id"])
    # A small metadata allowlist: never forward arbitrary objects or author credentials.
    result = {"id": spec["id"], "url": ENDPOINT + "/papers/" + spec["id"]}
    for key in ("title", "summary", "published_at", "upvotes"):
        value = getattr(paper, key, None)
        if value is not None:
            result[key] = value if isinstance(value, (str, int, float, bool)) else str(value)
    authors = getattr(paper, "authors", None)
    if authors:
        result["authors"] = [
            str(getattr(a, "name", a.get("name", "") if isinstance(a, dict) else ""))
            for a in authors
        ]
    return result


def run(request):
    operation, cfg, spec = validate(request)
    hub, api, caps = sdk_load(cfg)
    emit("capabilities", **caps)
    if operation == "probe":
        return caps
    if operation == "paper":
        return paper_info(spec, api)
    if operation == "preview_upload":
        return preview_upload(cfg, spec, api, caps)
    if operation == "preview_download":
        return preview_download(cfg, spec, hub, api, caps)
    direction = operation
    preview = approved_preview(request, cfg, spec, direction)
    if direction == "upload":
        return execute_upload(cfg, spec, preview, hub, api, caps)
    return execute_download(cfg, spec, preview, hub)


def safe_error(exc):
    if isinstance(exc, GuardError):
        return str(exc)
    # SDK exceptions can contain auth headers, tokens and signed URLs: never log them.
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if status in {401, 403, 404}:
        return (
            "Hub access failed (401/403/404): check repo, revision, access and existing "
            "official authentication"
        )
    if status == 409 or status == 412:
        return "Hub revision conflict; obtain a fresh preview before retrying"
    if isinstance(exc, (FileNotFoundError, NotADirectoryError, PermissionError, OSError)):
        return "local file/cache inaccessible, changed, or unsafe"
    # Class names are not attacker-controlled response strings.
    return (
        "Hub operation failed; no automatic upload retry (check connectivity, access, or retry "
        "with xet='disabled')"
    )


def xet_failure(exc):
    """Classify only recognizable transport failures; never echo exception text."""
    if isinstance(exc, (GuardError, OSError)):
        return False
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if status is not None and status < 500:
        return False
    message = str(exc).lower()
    if any(
        s in message
        for s in ("401", "403", "404", "unauthorized", "forbidden", "not found", "permission")
    ):
        return False
    return any(s in message for s in ("xet", "cas service", "cas-client", "cas client")) and any(
        s in message for s in ("error", "failed", "timeout", "connection", "unavailable")
    )


def main():
    os.umask(0o077)
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        require(len(raw) <= MAX_INPUT, "request too large")
        request = json.loads(raw)
        result = run(request)
        emit("result", result=result)
        return 0
    # Catch everything: SDK tracebacks and credentials must never reach stderr.
    except (Exception, KeyboardInterrupt) as exc:  # noqa: BLE001
        message = (
            "cancelled; completed remote commits cannot be undone"
            if isinstance(exc, KeyboardInterrupt)
            else safe_error(exc)
        )
        emit("error", message=message, code="xet_transport" if xet_failure(exc) else "failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
