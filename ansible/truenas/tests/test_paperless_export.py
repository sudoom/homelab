"""Tests for roles/truenas-tasks/files/paperless-export.py. No real Docker: a fake
`docker` shell script prints from environment variables and is passed with --docker."""
import contextlib
import importlib.util
import io
import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "roles/truenas-tasks/files/paperless-export.py"

FAKE_DOCKER = """#!/bin/sh
# ps -q ... prints $FAKE_PS; exec ... exits $FAKE_EXEC_RC and logs its argv.
case "$1" in
  ps) printf '%s' "$FAKE_PS"; exit 0 ;;
  exec) echo "$@" >> "$FAKE_LOG"; exit "${FAKE_EXEC_RC:-0}" ;;
esac
exit 99
"""


def load():
    spec = importlib.util.spec_from_file_location("paperless_export", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ExportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.prom_dir = root / "textfile"
        self.export = root / "export"
        self.prom_dir.mkdir()
        self.export.mkdir()
        self.docker = root / "docker"
        self.docker.write_text(FAKE_DOCKER)
        self.docker.chmod(self.docker.stat().st_mode | stat.S_IXUSR)
        self.log = root / "docker.log"
        self.prom = self.prom_dir / "paperless-export.prom"
        self.mod = load()

    def manifest(self, n=3):
        recs = [{"model": "documents.document", "pk": i} for i in range(n)]
        recs += [{"model": "documents.tag", "pk": 1}, {"model": "auth.user", "pk": 1}]
        (self.export / "manifest.json").write_text(json.dumps(recs))

    def run_main(self, ps="abc123\n", rc="0"):
        env = {"FAKE_PS": ps, "FAKE_EXEC_RC": rc, "FAKE_LOG": str(self.log)}
        argv = [str(self.prom_dir), "--app-name", "paperless",
                "--export-host-path", str(self.export),
                "--export-container-path", "/paperless/export",
                "--docker", str(self.docker)]
        err = io.StringIO()
        with mock.patch.dict(os.environ, env), contextlib.redirect_stderr(err):
            code = self.mod.main(argv)
        return code, err.getvalue()

    def assert_fails_untouched(self, **kw):
        self.prom.write_text("old\n")
        before = self.prom.read_bytes()
        code, err = self.run_main(**kw)
        self.assertNotEqual(code, 0)
        self.assertTrue(err.strip())
        self.assertEqual(self.prom.read_bytes(), before)
        self.assertEqual([p.name for p in self.prom_dir.iterdir()], ["paperless-export.prom"])

    def test_success_writes_prom(self):
        self.manifest(3)
        seen = {}
        real = os.replace

        def spy(src, dst):
            seen["src"] = str(src)
            seen["prom_existed"] = Path(dst).exists()
            seen["tmp_is_prom"] = str(src).endswith(".prom")
            return real(src, dst)

        start = time.time()
        with mock.patch.object(self.mod.os, "replace", spy):
            code, err = self.run_main()
        self.assertEqual((code, err), (0, ""))
        # atomic: nothing named .prom existed during the write, the temp did not end in .prom
        self.assertFalse(seen["prom_existed"])
        self.assertFalse(seen["tmp_is_prom"])
        text = self.prom.read_text()
        vals = {}
        for line in text.splitlines():
            if line and not line.startswith("#"):
                k, v = line.split()
                vals[k] = float(v)
        self.assertEqual(vals["truenas_paperless_export_documents"], 3)
        ts = vals["truenas_paperless_export_last_success_timestamp_seconds"]
        self.assertTrue(start - 1 <= ts <= time.time() + 1)
        self.assertEqual([p.name for p in self.prom_dir.iterdir()], ["paperless-export.prom"])
        args = self.log.read_text().split()
        self.assertEqual(args[:2], ["exec", "abc123"])
        self.assertIn("document_exporter", args)
        self.assertIn("/paperless/export", args)
        self.assertIn("-d", args)
        self.assertIn("--no-progress-bar", args)
        self.assertNotIn("-u", args)

    def test_no_container(self):
        self.manifest()
        self.assert_fails_untouched(ps="")

    def test_two_containers(self):
        self.manifest()
        self.assert_fails_untouched(ps="abc123\ndef456\n")

    def test_exporter_fails(self):
        self.manifest()
        self.assert_fails_untouched(rc="1")

    def test_manifest_missing(self):
        self.assert_fails_untouched()


if __name__ == "__main__":
    unittest.main()
