"""Inert-without-config: no `.claude/backlog.yml` (or mode off) means no gh call is reachable.

The oracle is a fake `gh` on PATH that logs every invocation; a positive control proves the shim records calls
when the mode allows them, so an empty log means something.
"""

import json
import os
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

import _support

SUBCOMMANDS = {
    "config": ["config"],
    "next": ["next"],
    "next-json": ["next", "--json"],
    "lint": ["lint", "--strict"],
    "file": ["file", "--title", "a title", "--label", "type:bug"],
    "file-apply-confirm": ["file", "--title", "a title", "--label", "type:bug", "--apply", "--confirm", "x"],
    "inbox": ["inbox"],
    "triage-check": ["triage-check", "--proposals", "/nonexistent/p.json"],
    "guard": ["guard", "--command", "gh issue create --label type:bug --title x"],
}


class TestInert(unittest.TestCase):
    def setUp(self):
        self._tmp = _support.tmpdir()
        self.tmp = Path(self._tmp.name)
        self.project = self.tmp / "repo"
        self.project.mkdir()
        self.bin = self.tmp / "bin"
        self.log = _support.fake_gh(self.bin)
        self.env = _support.cli_env(self.bin)

    def tearDown(self):
        self._tmp.cleanup()

    def _run_all(self):
        for name, args in SUBCOMMANDS.items():
            with self.subTest(subcommand=name):
                proc = _support.run_cli(args, self.project, self.env)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                if name not in ("config", "guard"):
                    self.assertIn("mode=off", proc.stdout)
        self.assertEqual(_support.gh_calls(self.log), [])

    def test_no_config_every_subcommand_never_invokes_gh(self):
        self.assertFalse((self.project / ".claude" / "backlog.yml").exists())
        self._run_all()

    def test_no_config_with_project_dir_flag_never_invokes_gh(self):
        proc = subprocess_run_flag(self.project, self.env)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(_support.gh_calls(self.log), [])

    def test_off_mode_with_config_never_invokes_gh(self):
        _support.write_mode(self.project, "off")
        self._run_all()

    def test_invalid_config_never_invokes_gh(self):
        _support.write_config(self.project, "contract: 1\nmode: propose\nbogus: 1\n")
        self._run_all()

    def test_missing_mode_never_invokes_gh(self):
        _support.write_config(self.project, "contract: 1\n")
        self._run_all()

    def test_positive_control_propose_mode_does_call_gh(self):
        _support.write_mode(self.project, "propose")
        proc = _support.run_cli(["next"], self.project, self.env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        calls = _support.gh_calls(self.log)
        self.assertEqual(len(calls), 2, calls)
        self.assertTrue(calls[0].startswith("issue list"))
        self.assertTrue(calls[1].startswith("pr list"))
        self.assertIn("queue empty", proc.stdout)

    def test_propose_mode_file_apply_never_creates(self):
        _support.write_mode(self.project, "propose")
        proc = _support.run_cli(SUBCOMMANDS["file-apply-confirm"], self.project, self.env)
        self.assertEqual(proc.returncode, 1, proc.stdout)  # the fake repo has no labels: refused
        self.assertFalse([c for c in _support.gh_calls(self.log) if c.startswith("issue create")])

    def test_hook_no_config_never_spawns_python_or_jq(self):
        # PATH holds only recording shims for python3/jq/gh; the hook must exit before reaching any of them.
        shims = self.tmp / "shims"
        shims.mkdir()
        marker = self.tmp / "spawned.log"
        for name in ("python3", "jq", "grep", "gh"):
            path = shims / name
            path.write_text('#!/bin/sh\necho "%s" >> "%s"\nexit 0\n' % (name, marker))
            path.chmod(0o755)
        env = _support.cli_env(None, {"PATH": str(shims), "CLAUDE_PROJECT_DIR": str(self.project), "CLAUDE_PLUGIN_ROOT": str(_support.PLUGIN_ROOT)})
        payload = json.dumps({"tool_input": {"command": "gh issue edit 5 --add-label status:ready"}})
        proc = subprocess.run(["/bin/bash", str(_support.GUARD_HOOK)], input=payload, env=env, capture_output=True, text=True, cwd=str(self.project))
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertFalse(marker.exists())

    def test_hook_positive_control_spawns_when_config_exists(self):
        if shutil.which("jq") is None:
            self.skipTest("jq not installed")
        _support.write_mode(self.project, "propose")
        env = _support.cli_env(None, {"CLAUDE_PROJECT_DIR": str(self.project), "CLAUDE_PLUGIN_ROOT": str(_support.PLUGIN_ROOT)})
        payload = json.dumps({"tool_input": {"command": "gh issue edit 5 --add-label status:ready"}})
        proc = subprocess.run(["/bin/bash", str(_support.GUARD_HOOK)], input=payload, env=env, capture_output=True, text=True, cwd=str(self.project))
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)


def subprocess_run_flag(project, env):
    return subprocess.run(
        [sys.executable, "-B", str(_support.CLI), "--project-dir", str(project), "file", "--title", "x", "--apply", "--confirm", "x"],
        cwd=str(project.parent), env=env, capture_output=True, text=True,
    )


if __name__ == "__main__":
    unittest.main()
