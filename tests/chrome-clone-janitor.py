#!/usr/bin/env python3
"""Isolated safety tests for Chrome's code-sign clone janitor."""

import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "shell" / "chrome-clone-janitor.py"
spec = importlib.util.spec_from_file_location("chrome_clone_janitor", SOURCE)
janitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(janitor)


class CloneJanitorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "com.google.Chrome.code_sign_clone"
        self.root.mkdir()

    def clone(self, name, age_days=5):
        path = self.root / name
        path.mkdir()
        (path / "Google Chrome.app.bundle").mkdir()
        old = time.time() - age_days * 86400
        os.utime(path, (old, old))
        return path

    @mock.patch.object(janitor, "lsof_works", return_value=True)
    @mock.patch.object(janitor, "held", return_value=False)
    def test_clean_only_old_exact_name_directory(self, _held, _works):
        old = self.clone("code_sign_clone.Abc123")
        recent = self.clone("code_sign_clone.Def456", 1)
        unrelated = self.clone("other.Abc123")
        self.assertEqual(janitor.scan(self.root, clean=True), (2, 1, 1))
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(unrelated.exists())

    @mock.patch.object(janitor, "lsof_works", return_value=True)
    @mock.patch.object(janitor, "held", side_effect=[False, True])
    def test_new_holder_blocks_last_moment_removal(self, _held, _works):
        path = self.clone("code_sign_clone.Abc123")
        self.assertEqual(janitor.scan(self.root, clean=True), (1, 1, 0))
        self.assertTrue(path.exists())

    @mock.patch.object(janitor, "lsof_works", return_value=False)
    def test_unusable_lsof_keeps_everything(self, _works):
        path = self.clone("code_sign_clone.Abc123")
        with self.assertRaises(RuntimeError):
            janitor.scan(self.root, clean=True)
        self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
