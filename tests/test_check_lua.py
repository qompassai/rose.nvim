"""Offline regression tests for the strict checker; no LuaLS installation needed."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "check_lua", Path(__file__).resolve().parents[1] / "scripts" / "check_lua.py"
)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class CheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "output"
        self.output.mkdir()
        self.settings = {
            "workspace": {
                "library": [],
                "ignoreDir": ["build"],
                "maxPreload": 5000,
                "preloadFileSize": 500,
            }
        }
        (self.root / ".luarc.json").write_text(json.dumps(self.settings))

    def result(self, exit_code=0, total=0, progress="2/2", complete=True, report=True):
        def fake_run(command, timeout):
            self.assertEqual(timeout, 120)
            raw = Path(
                next(x.split("=", 1)[1] for x in command if x.startswith("--check_out_path="))
            )
            items = [{"code": "need-check-nil", "severity": 1}] * total
            if report:
                data = {(self.root / "init.lua").as_uri(): items} if items else []
                raw.write_text(json.dumps(data))
            console = ">" * 20 + " " + progress + "\n"
            if complete:
                console += (
                    f"Diagnosis complete, {total} problems found"
                    if total
                    else "Diagnosis completed, no problems found"
                )
            return subprocess.CompletedProcess(command, exit_code, console, "")

        return fake_run

    def check(self, **options):
        with (
            patch.object(CHECKER, "expected_files", return_value=["init.lua", "test.lua"]),
            patch.object(CHECKER, "run", side_effect=self.result(**options)),
        ):
            return CHECKER.check(self.root, self.output, self.root, "fixture-luals")

    def test_clean_complete_report(self):
        records, count = self.check()
        self.assertEqual((records, count), ([], 2))

    def test_complete_report_with_findings(self):
        records, count = self.check(exit_code=1, total=1)
        self.assertEqual(count, 2)
        self.assertEqual(records[0]["code"], "need-check-nil")

    def test_unexpected_exit_with_valid_report_is_failure(self):
        for code in (1, 2, -9):
            with self.subTest(code=code), self.assertRaisesRegex(SystemExit, "Unexpected"):
                self.check(exit_code=code)

    def test_findings_cannot_exit_successfully(self):
        with self.assertRaisesRegex(SystemExit, "Unexpected"):
            self.check(total=1)

    def test_partial_or_mismatched_coverage_is_failure(self):
        for progress in ("1/2", "1/1", "3/3", ""):
            with (
                self.subTest(progress=progress),
                self.assertRaisesRegex(SystemExit, "completion/coverage"),
            ):
                self.check(progress=progress)

    def test_missing_completion_is_failure(self):
        with self.assertRaisesRegex(SystemExit, "completion/coverage"):
            self.check(complete=False)

    def test_stale_report_cannot_pass(self):
        (self.output / "diagnostics.json").write_text("{}")
        with self.assertRaisesRegex(SystemExit, "no report"):
            self.check(report=False)

    def test_preload_limits_cannot_silently_skip_files(self):
        (self.root / "init.lua").write_text("-- fixture")
        listed = subprocess.CompletedProcess([], 0, "init.lua\0", "")
        with patch.object(CHECKER, "run", return_value=listed):
            self.settings["workspace"]["maxPreload"] = 0
            with self.assertRaisesRegex(SystemExit, "preload limit"):
                CHECKER.expected_files(self.root, self.settings)
            self.settings["workspace"]["maxPreload"] = 5000
            self.settings["workspace"]["preloadFileSize"] = 0
            with self.assertRaisesRegex(SystemExit, "preload size"):
                CHECKER.expected_files(self.root, self.settings)

    def test_command_deadline_is_enforced(self):
        with self.assertRaisesRegex(SystemExit, "exceeded"):
            CHECKER.run([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)


if __name__ == "__main__":
    unittest.main()
