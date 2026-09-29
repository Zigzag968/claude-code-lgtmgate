"""The catch-up subcommands are inert without a config, and target `repo:` of the config they were given.

Oracle: a fake `gh` on PATH that logs every invocation (as in test_inert.py). HOME is redirected into the temp
directory so a snapshot can never land in the developer's real home.
"""

import re
import unittest
from pathlib import Path

import _support as S

SUBCOMMANDS = {
    "label-sync": ["label-sync"],
    "snapshot": ["snapshot"],
    "rollback": ["rollback", "--snapshot-dir", "/nonexistent/s", "--expect-sha", "x"],
    "catchup-propose": ["catchup", "propose"],
    "catchup-check": ["catchup", "check", "--proposals", "/nonexistent/p.json"],
    "label-sync-apply": ["label-sync", "--apply"],
    "rollback-apply": ["rollback", "--snapshot-dir", "/nonexistent/s", "--expect-sha", "x", "--apply", "--confirm", "x"],
    "catchup-check-apply": ["catchup", "check", "--proposals", "/nonexistent/p.json", "--apply", "--confirm", "x"],
    "set": ["set", "--issue", "1", "--status", "needs-info"],
    "set-apply": ["set", "--issue", "1", "--status", "needs-info", "--apply"],
}


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = S.tmpdir()
        self.tmp = Path(self._tmp.name)
        self.project = self.tmp / "repo"
        self.project.mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.bin = self.tmp / "bin"
        self.log = S.fake_gh(self.bin)
        self.env = S.cli_env(self.bin, {"HOME": str(self.home)})

    def tearDown(self):
        self._tmp.cleanup()


class TestInertWithoutConfig(Base):
    def _run_all(self):
        for name, args in SUBCOMMANDS.items():
            with self.subTest(subcommand=name):
                proc = S.run_cli(args, self.project, self.env)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn("mode=off", proc.stdout)
        self.assertEqual(S.gh_calls(self.log), [])
        self.assertEqual(list(self.home.iterdir()), [])  # no snapshot directory, nothing at all

    def test_no_config(self):
        self.assertFalse((self.project / ".claude" / "backlog.yml").exists())
        self._run_all()

    def test_mode_off(self):
        S.write_mode(self.project, "off")
        self._run_all()

    def test_invalid_config(self):
        S.write_config(self.project, "contract: 1\nmode: propose\nrepo: acme/widgets\nlegacy_map:\n  bug: type:nope\n")
        self._run_all()

    def test_help_never_reaches_gh(self):
        for name in ("label-sync", "snapshot", "rollback", "catchup", "set"):
            with self.subTest(subcommand=name):
                proc = S.run_cli([name, "--help"], self.project, self.env)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertIn("usage:", proc.stdout)
        self.assertEqual(S.gh_calls(self.log), [])

    def test_positive_control_propose_mode_does_call_gh(self):
        S.write_repo_config(self.project, "acme/widgets", "propose")
        proc = S.run_cli(["label-sync"], self.project, self.env)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        calls = S.gh_calls(self.log)
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("label list"))
        self.assertIn("dry-run: create=15", proc.stdout)


class TestTargetsTheConfiguredRepo(Base):
    """Run from ANOTHER repo's directory with --project-dir: every gh call names the target repo."""

    def setUp(self):
        super().setUp()
        self.target = self.tmp / "target"
        self.target.mkdir()
        S.write_repo_config(self.target, "acme/widgets", "propose")
        self.elsewhere = self.tmp / "elsewhere"
        self.elsewhere.mkdir()
        self.snap = self.tmp / "snaps" / "s1"

    def cli(self, *args):
        return S.run_cli(["--project-dir", str(self.target)] + list(args), self.elsewhere, self.env)

    def test_every_gh_call_of_every_subcommand_names_the_configured_repo_and_none_writes(self):
        empty = self.tmp / "empty.json"
        empty.write_text("[]")
        snap = self.cli("snapshot", "--snapshot-dir", str(self.snap))
        self.assertEqual(snap.returncode, 0, snap.stdout + snap.stderr)
        sha = re.search(r"sha256=([0-9a-f]{64})", snap.stdout).group(1)
        runs = [
            self.cli("label-sync"),
            self.cli("catchup", "propose"),
            self.cli("catchup", "check", "--proposals", str(empty)),
            self.cli("rollback", "--snapshot-dir", str(self.snap), "--expect-sha", sha),
        ]
        for proc in runs:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        calls = S.gh_calls(self.log)
        self.assertGreaterEqual(len(calls), 8, calls)
        for call in calls:
            self.assertTrue(call.endswith("-R acme/widgets"), call)
            self.assertRegex(call, r"^(issue list|label list) ")
            self.assertFalse(call.startswith(("issue edit", "issue create", "label create", "label edit", "label delete")), call)

    def test_the_snapshot_is_named_after_the_repo_not_the_directories(self):
        proc = self.cli("snapshot")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        made = list((self.home / ".backlog-snapshots").iterdir())
        self.assertEqual([p.name for p in made], ["acme__widgets"])
        self.assertEqual(len(list(made[0].glob("*/snapshot.json"))), 1)
        self.assertEqual(list(self.target.rglob("snapshot.json")), [])
        self.assertEqual(list(self.elsewhere.rglob("*")), [])

    def test_the_repo_flag_cannot_redirect_a_command(self):
        for args in (["label-sync"], ["snapshot"], ["catchup", "propose"]):
            with self.subTest(args=args):
                proc = self.cli(*(args + ["--repo", "acme/other"]))
                self.assertEqual(proc.returncode, 1, proc.stdout)
                self.assertIn("does not match", proc.stdout)
        self.assertEqual(S.gh_calls(self.log), [])
        self.assertFalse((self.home / ".backlog-snapshots").exists())

    def test_snapshot_has_no_apply_flag(self):
        proc = self.cli("snapshot", "--apply")
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertEqual(S.gh_calls(self.log), [])

    def test_apply_in_propose_mode_is_refused_and_no_write_verb_ever_reaches_gh(self):
        proposals = self.tmp / "p.json"
        proposals.write_text("[]")
        for args in (["label-sync", "--apply", "--confirm", "x"],
                     ["catchup", "check", "--proposals", str(proposals), "--apply", "--confirm", "x"],
                     ["rollback", "--snapshot-dir", str(self.snap), "--expect-sha", "x", "--apply", "--confirm", "x"]):
            with self.subTest(args=args):
                proc = self.cli(*args)
                self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
                self.assertIn("refused: mode", proc.stdout)
        for call in S.gh_calls(self.log):
            self.assertFalse(call.startswith(("issue edit", "label create")), call)


if __name__ == "__main__":
    unittest.main()
