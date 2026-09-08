"""Offline security/API tests: never contact the Hub or load a model."""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("rose_hub", ROOT / "scripts/rose_hub.py")
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)
COMMIT = "a" * 40
CONTENT = b"tiny offline asset\n"


class SDK:
    __version__ = "fixture-current"

    def __init__(self):
        self.calls = []
        self.cached = False
        self.CommitOperationAdd = lambda **kw: NS(**kw)

    def hf_hub_download(self, repo_id, filename, *, repo_type, revision, cache_dir, dry_run=False):
        self.calls.append(("file", repo_id, filename, revision, dry_run))
        if dry_run:
            return NS(
                filename=filename, commit_hash=COMMIT, file_size=len(CONTENT), is_cached=self.cached
            )
        path = Path(cache_dir) / "blobs" / "fixture"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(CONTENT)
        return str(path)

    def try_to_load_from_cache(self, *args, **kwargs):
        return None


class API:
    def __init__(self):
        self.calls = []
        self.sha, self.private = COMMIT, False

    def repo_info(self, *, repo_id, repo_type, revision, files_metadata=False):
        self.calls.append(("info", repo_id, repo_type, revision))
        return NS(
            sha=self.sha,
            private=self.private,
            siblings=[NS(rfilename="README.md", size=len(CONTENT))],
        )

    def upload_folder(
        self,
        *,
        repo_id,
        repo_type,
        revision,
        folder_path,
        path_in_repo,
        parent_commit,
        commit_message,
        allow_patterns,
    ):
        files = sorted(
            str(p.relative_to(folder_path)) for p in Path(folder_path).rglob("*") if p.is_file()
        )
        self.calls.append(("upload", files, allow_patterns, parent_commit, path_in_repo))
        return NS(oid="b" * 40)

    def create_commit(
        self,
        *,
        repo_id,
        repo_type,
        revision,
        parent_commit,
        commit_message,
        operations,
        num_threads,
    ):
        self.calls.append(("commit", operations, num_threads, parent_commit))
        return NS(oid="c" * 40)

    def paper_info(self, id):
        self.calls.append(("paper", id))
        return NS(title="An offline paper", summary="Metadata only", authors=[NS(name="A. Author")])


class HubTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="rose-hub-tests-")
        self.base = Path(self.tmp.name)
        self.workspace = self.base / "workspace"
        self.workspace.mkdir()
        (self.workspace / "README.md").write_bytes(CONTENT)
        self.cfg = {
            "workspace": str(self.workspace),
            "cache_dir": str(self.base / "cache"),
            "trusted": True,
        }
        self.spec = {
            "repo_id": "example/existing",
            "repo_type": "model",
            "revision": "main",
            "files": ["README.md"],
        }
        self.sdk, self.api = SDK(), API()
        self.caps = {
            "hub_version": "fixture",
            "xet_version": "fixture",
            "transport": "xet",
            "upload_folder": True,
            "download_dry_run": True,
            "paper_info": True,
            "max_workers": 4,
        }
        self.output = io.StringIO()
        self.stdout = contextlib.redirect_stdout(self.output)
        self.stdout.__enter__()
        self.loader = patch.object(hub, "sdk_load", return_value=(self.sdk, self.api, self.caps))
        self.loader.start()

    def tearDown(self):
        self.loader.stop()
        self.stdout.__exit__(None, None, None)
        self.tmp.cleanup()

    def request(self, operation, spec=None, preview=None):
        return {
            "operation": operation,
            "config": self.cfg,
            "spec": spec or self.spec,
            **({"preview": preview} if preview is not None else {}),
        }

    def upload_preview(self):
        return hub.run(self.request("preview_upload"))

    def download_preview(self):
        return hub.run(
            self.request("preview_download", {**self.spec, "destination": "models/tiny"})
        )

    def assert_no_remote_upload(self):
        self.assertFalse(any(c[0] in {"upload", "commit"} for c in self.api.calls))

    def test_import_does_no_network_or_sdk_import(self):
        self.assertNotIn("huggingface_hub", sys.modules)

    def test_invalid_paths_and_secrets_fail_before_network(self):
        for name in (
            "../secret",
            "/etc/passwd",
            "a/../secret",
            "./README.md",
            "a//b",
            "a\\b",
            "*.md",
            "a[1].md",
            ".env",
            ".env.local",
            ".envrc",
            ".git/config",
            ".ssh/id_rsa",
            "cert.pem",
            "key.p12",
            ".aws/credentials",
            "id_ed25519",
            "a\x00b",
            "a\nb",
            "secrets.json",
            "service-account-production.json",
            "a\u202eb",
        ):
            with self.subTest(name=name), self.assertRaises((hub.GuardError, OSError)):
                hub.run(self.request("preview_upload", {**self.spec, "files": [name]}))
        self.assertEqual(self.api.calls, [])

    def test_unknown_credentials_approval_endpoint_and_repo_types(self):
        for key in (
            "token",
            "approved",
            "confirmed",
            "endpoint",
            "trust_remote_code",
            "create_repo",
            "delete_patterns",
        ):
            with self.subTest(key=key), self.assertRaises(hub.GuardError):
                hub.run(self.request("preview_upload", {**self.spec, key: True}))
        for kind in ("paper", "papers", "space"):
            with self.assertRaises(hub.GuardError):
                hub.run(self.request("preview_upload", {**self.spec, "repo_type": kind}))
        self.assertEqual(self.api.calls, [])

    def test_explicit_selection_no_cwd_directory_or_duplicate(self):
        for files in ([], [".", "README.md"], ["README.md", "README.md"], ["folder"]):
            with self.assertRaises((hub.GuardError, OSError)):
                hub.run(self.request("preview_upload", {**self.spec, "files": files}))
        self.assertEqual(self.api.calls, [])

    def test_untrusted_and_invalid_limits(self):
        self.cfg["trusted"] = False
        with self.assertRaisesRegex(hub.GuardError, "trusted"):
            self.upload_preview()
        self.cfg["trusted"] = True
        for value in (0, 17, True, 2.5):
            self.cfg["max_workers"] = value
            with self.assertRaises(hub.GuardError):
                self.upload_preview()

    def test_symlink_file_directory_and_hardlink(self):
        (self.workspace / "alias").symlink_to(self.workspace / "README.md")
        (self.workspace / "dir").symlink_to(self.base, target_is_directory=True)
        os.link(self.workspace / "README.md", self.workspace / "hard")
        for name in ("alias", "dir/workspace/README.md", "hard"):
            with self.assertRaises((hub.GuardError, OSError)):
                hub.run(self.request("preview_upload", {**self.spec, "files": [name]}))
        self.assertEqual(self.api.calls, [])

    def test_cache_cannot_be_workspace_or_symlink(self):
        self.cfg["cache_dir"] = str(self.workspace / "cache")
        with self.assertRaises(hub.GuardError):
            self.upload_preview()
        link = self.base / "alias"
        link.symlink_to(self.workspace, target_is_directory=True)
        with self.assertRaises((hub.GuardError, OSError)):
            hub.check_directory(str(link))

    def test_upload_preview_exact_hash_existing_visibility_parent(self):
        p = self.upload_preview()
        self.assertEqual(p["commit"], COMMIT)
        self.assertEqual(p["visibility"], "public")
        self.assertEqual(p["total_bytes"], len(CONTENT))
        self.assertEqual(
            p["files"][0]["snapshot"]["sha256"], hub.hashlib.sha256(CONTENT).hexdigest()
        )
        self.assert_no_remote_upload()

    def test_upload_exact_manifest_stage_and_no_large_folder(self):
        (self.workspace / "unselected.txt").write_text("never upload")
        (self.workspace / ".env").write_text("HF_TOKEN=never")
        p = self.upload_preview()
        result = hub.run(self.request("upload", preview=p))
        call = next(c for c in self.api.calls if c[0] == "upload")
        self.assertEqual(call, ("upload", ["README.md"], ["README.md"], COMMIT, ""))
        self.assertEqual(result["strategy"], "official-upload-folder")
        self.assertTrue(list((self.base / "cache/staging").rglob("README.md")))

    def test_snapshot_revalidated_even_same_length_content(self):
        p = self.upload_preview()
        original = (self.workspace / "README.md").stat()
        (self.workspace / "README.md").write_bytes(b"x" * len(CONTENT))
        os.utime(self.workspace / "README.md", ns=(original.st_atime_ns, original.st_mtime_ns))
        with self.assertRaisesRegex(hub.GuardError, "changed"):
            hub.run(self.request("upload", preview=p))
        self.assert_no_remote_upload()

    def test_changed_repo_commit_or_visibility_refuses_upload(self):
        for attr, value in (("sha", "d" * 40), ("private", True)):
            p = self.upload_preview()
            before = getattr(self.api, attr)
            setattr(self.api, attr, value)
            with self.assertRaisesRegex(hub.GuardError, "repository commit or visibility changed"):
                hub.run(self.request("upload", preview=p))
            setattr(self.api, attr, before)
        self.assert_no_remote_upload()

    def test_tampered_preview_refused(self):
        p = self.upload_preview()
        for key, value in (
            ("repo_id", "other/repo"),
            ("commit", "main"),
            ("workspace", "/"),
            ("files", []),
            ("total_bytes", 0),
            ("path_in_repo", "other"),
        ):
            with self.subTest(key=key), self.assertRaises(hub.GuardError):
                hub.run(self.request("upload", preview={**p, key: value}))
        self.assert_no_remote_upload()

    def test_http_fallback_bounded_official_commit(self):
        self.caps["transport"] = "http"
        self.cfg["max_workers"] = 2
        p = self.upload_preview()
        result = hub.run(self.request("upload", preview=p))
        call = next(c for c in self.api.calls if c[0] == "commit")
        self.assertEqual(call[2:], (2, COMMIT))
        self.assertEqual([op.path_in_repo for op in call[1]], ["README.md"])
        self.assertEqual(result["strategy"], "official-http-commit")

    def test_prefix_exact_preview_and_upload(self):
        self.spec["path_in_repo"] = "papers/2026"
        p = self.upload_preview()
        self.assertEqual(p["files"][0]["remote_path"], "papers/2026/README.md")
        hub.run(self.request("upload", preview=p))
        self.assertEqual(self.api.calls[-1][-1], "papers/2026")

    def test_download_dryrun_only_and_pinned_execution(self):
        p = self.download_preview()
        self.assertEqual(p["download_bytes"], len(CONTENT))
        self.assertEqual(p["cached_bytes"], 0)
        self.assertTrue(all(c[-1] is True for c in self.sdk.calls))
        self.assertFalse((self.workspace / "models").exists())
        result = hub.run(self.request("download", {**self.spec, "destination": "models/tiny"}, p))
        self.assertEqual((self.workspace / "models/tiny/README.md").read_bytes(), CONTENT)
        self.assertEqual(result["commit"], COMMIT)
        self.assertTrue(all(c[3] == COMMIT for c in self.sdk.calls))

    def test_download_legacy_preview_uses_metadata_no_content(self):
        self.caps["download_dry_run"] = False
        p = self.download_preview()
        self.assertEqual(self.sdk.calls, [])
        self.assertEqual(p["total_bytes"], len(CONTENT))

    def test_download_cached_preview(self):
        self.sdk.cached = True
        p = self.download_preview()
        self.assertEqual(p["download_bytes"], 0)
        self.assertEqual(p["cached_bytes"], len(CONTENT))

    def test_destination_symlink_and_race(self):
        p = self.download_preview()
        (self.workspace / "models").symlink_to(self.base, target_is_directory=True)
        with self.assertRaises((hub.GuardError, OSError)):
            hub.run(self.request("download", {**self.spec, "destination": "models/tiny"}, p))
        self.assertTrue(all(c[-1] is True for c in self.sdk.calls))

    def test_destination_existing_overwrite_snapshot(self):
        dest = self.workspace / "models/tiny"
        dest.mkdir(parents=True)
        (dest / "README.md").write_bytes(b"existing")
        p = self.download_preview()
        self.assertIsInstance(p["files"][0]["local_before"], dict)
        (dest / "README.md").write_bytes(b"changed")
        with self.assertRaisesRegex(hub.GuardError, "destination changed"):
            hub.run(self.request("download", {**self.spec, "destination": "models/tiny"}, p))

    def test_download_size_limit(self):
        self.cfg["max_total_bytes"] = 1
        with self.assertRaisesRegex(hub.GuardError, "exceeds max_total_bytes"):
            self.download_preview()

    def test_paper_metadata_only_and_unsupported(self):
        p = hub.run(self.request("paper", {"id": "2501.00001"}))
        self.assertEqual(p["title"], "An offline paper")
        self.assertEqual(self.sdk.calls, [])
        self.api.paper_info = None
        with self.assertRaisesRegex(hub.GuardError, "lacks paper_info"):
            hub.run(self.request("paper", {"id": "2501.00001"}))
        with self.assertRaises(hub.GuardError):
            hub.run(self.request("paper", {"id": "https://evil.invalid/paper"}))

    def test_environment_fixed_endpoint_tuning_no_token_copy(self):
        _, cfg, _ = hub.validate(self.request("preview_upload"))
        cfg["high_performance"] = True
        cfg["max_workers"] = 3
        with patch.dict(
            os.environ,
            {
                "HF_ENDPOINT": "https://untrusted.invalid",
                "HF_TOKEN": "secret",
                "HF_XET_LOG_DEST": str(self.base / "unwanted-sdk.log"),
                "HF_XET_FIXED_UPLOAD_CONCURRENCY": "999",
            },
            clear=True,
        ):
            hub.environment(cfg)
            self.assertEqual(os.environ["HF_ENDPOINT"], hub.ENDPOINT)
            self.assertEqual(os.environ["HF_XET_LOG_DEST"], os.devnull)
            self.assertEqual(os.environ["HF_XET_HIGH_PERFORMANCE"], "1")
            self.assertEqual(os.environ["HF_XET_CLIENT_AC_MAX_UPLOAD_CONCURRENCY"], "3")
            self.assertEqual(os.environ["HF_XET_CLIENT_AC_MIN_DOWNLOAD_CONCURRENCY"], "1")
            self.assertNotIn("HF_XET_FIXED_UPLOAD_CONCURRENCY", os.environ)
            self.assertEqual(os.environ["HF_TOKEN"], "secret")
            self.assertNotIn("secret", json.dumps(cfg))

    def test_errors_redact_credentials_and_classify_only_xet(self):
        for exc in (
            RuntimeError("hf_secret Bearer secret https://signed.invalid?token=secret"),
            OSError("secret"),
            ValueError("secret"),
        ):
            self.assertNotIn("secret", hub.safe_error(exc))
            self.assertFalse(hub.xet_failure(exc))
        self.assertTrue(hub.xet_failure(RuntimeError("Xet CAS service connection failed")))
        for message in (
            "Xet 401 unauthorized error",
            "CAS service 403 error",
            "Xet 404 error",
            "connection failed",
            "invalid filename",
            "Xet permission denied error",
        ):
            self.assertFalse(hub.xet_failure(RuntimeError(message)), message)

    def test_actual_helper_subprocess_rejects_unsafe_without_network(self):
        req = self.request("preview_upload", {**self.spec, "files": ["../secret"]})
        result = subprocess.run(
            [sys.executable, "-I", str(ROOT / "scripts/rose_hub.py")],
            input=json.dumps(req),
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        event = json.loads(result.stdout)
        self.assertEqual(event["event"], "error")
        self.assertIn("traversal", event["message"])
        self.assertEqual(result.stderr, "")

    def test_actual_helper_offline_sdk_probe_without_persistent_logs(self):
        req = {"operation": "probe", "config": self.cfg, "spec": {}}
        unwanted_log = self.base / "unwanted-sdk.log"
        result = subprocess.run(
            [sys.executable, "-I", str(ROOT / "scripts/rose_hub.py")],
            input=json.dumps(req),
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
            cwd=self.base,
            env={
                **os.environ,
                "HF_HUB_OFFLINE": "1",
                "HF_ENDPOINT": "https://never.invalid",
                "HF_XET_LOG_DEST": str(unwanted_log),
            },
        )
        self.assertFalse(
            unwanted_log.exists(), "inherited Xet logging destination must be overridden"
        )
        self.assertFalse(
            (self.base / "stderr").exists(), "stderr must not become a literal log file"
        )
        self.assertFalse(
            list((self.base / "cache").rglob("*.log")), "SDK logs must not persist in cache"
        )
        self.assertEqual(result.stderr, "")
        events = [json.loads(line) for line in result.stdout.splitlines()]
        if result.returncode == 0:
            self.assertEqual(events[-1]["event"], "result")
            self.assertIn("hub_version", events[-1]["result"])
            self.assertNotIn("token", json.dumps(events).lower())
        else:
            self.assertIn("huggingface_hub is missing", events[-1]["message"])

    def test_cache_return_escape_and_size_mismatch_fail_without_publish(self):
        p = self.download_preview()
        bad = self.base / "outside"
        bad.write_bytes(CONTENT)
        with (
            patch.object(self.sdk, "hf_hub_download", return_value=str(bad)),
            self.assertRaisesRegex(hub.GuardError, "cache path escaped"),
        ):
            hub.run(self.request("download", {**self.spec, "destination": "models/tiny"}, p))
        self.assertFalse((self.workspace / "models").exists())
        cached = self.base / "cache/hub/blobs/bad"
        cached.parent.mkdir(parents=True)
        cached.write_bytes(b"too short")
        with (
            patch.object(self.sdk, "hf_hub_download", return_value=str(cached)),
            self.assertRaisesRegex(hub.GuardError, "size differs"),
        ):
            hub.run(self.request("download", {**self.spec, "destination": "models/tiny"}, p))

    def test_source_directory_replaced_after_preview_fails(self):
        p = self.upload_preview()
        moved = self.base / "moved"
        self.workspace.rename(moved)
        self.workspace.mkdir()
        (self.workspace / "README.md").write_bytes(CONTENT)
        with self.assertRaisesRegex(hub.GuardError, "workspace root changed"):
            hub.run(self.request("upload", preview=p))
        self.assert_no_remote_upload()


if __name__ == "__main__":
    unittest.main()
