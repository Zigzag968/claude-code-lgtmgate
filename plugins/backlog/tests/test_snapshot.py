import ast
import contextlib
import hashlib
import io
import json
import os
import stat
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

import _support
import backlog_config
import backlog_snapshot
from backlog_gh import Gh

NOW = datetime(2026, 9, 19, 12, 0, 0, tzinfo=timezone.utc)
ISSUES = [
    {"number": 2, "title": "second", "state": "OPEN", "updatedAt": "2026-09-01T00:00:00Z",
     "labels": [{"name": "type:bug"}, {"name": "status:ready"}, {"name": "exec:agent"}, {"name": "size:S"}]},
    {"number": 1, "title": "first", "state": "OPEN", "updatedAt": "2026-09-02T00:00:00Z",
     "labels": [{"name": "type:chore"}, {"name": "status:inbox"}, {"name": "priority:1-next"}]},
    {"number": 3, "title": "done", "state": "CLOSED", "updatedAt": "2026-08-01T00:00:00Z", "labels": [{"name": "type:bug"}]},
]
LABELS = ["type:bug", "type:chore", "status:inbox", "status:ready", "exec:agent", "size:S", "priority:1-next", "nightly"]


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = _support.tmpdir()
        self.tmp = Path(self._tmp.name)
        self.project = self.tmp / "repo"
        self.project.mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()
        _support.write_repo_config(self.project, "acme/widgets")
        self.cfg = backlog_config.load_config(str(self.project))
        self.assertEqual(self.cfg.mode, "propose", self.cfg.reason)
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.issues_file = self.tmp / "issues.json"
        self.labels_file = self.tmp / "labels.json"
        self.issues_file.write_text(json.dumps(ISSUES))
        self.labels_file.write_text(json.dumps([{"name": n} for n in LABELS]))

    def tearDown(self):
        self._tmp.cleanup()

    def call(self, fn, argv, cfg=None, **kw):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = fn(argv, cfg or self.cfg, **kw)
        return rc, buf.getvalue()

    def snapshot(self, *extra, cfg=None, now=NOW, **kw):
        argv = ["--issues-file", str(self.issues_file), "--labels-file", str(self.labels_file)] + list(extra)
        return self.call(backlog_snapshot.main_snapshot, argv, cfg, now=now, **kw)

    def default_dir(self):
        return self.home / ".backlog-snapshots" / "acme__widgets" / "20260919T120000Z"


class TestSnapshot(Base):
    def test_default_location_is_named_after_the_target_repo_not_the_cwd(self):
        rc, out = self.snapshot()
        self.assertEqual(rc, 0, out)
        target = self.default_dir()
        self.assertTrue((target / "snapshot.json").is_file())
        sha = hashlib.sha256((target / "snapshot.json").read_bytes()).hexdigest()
        self.assertIn("[snapshot] repo=acme/widgets issues=3 labels=8 sha256=%s" % sha, out)
        self.assertIn("(snapshot.json, snapshot.sha256, rollback.sh)", out)
        self.assertEqual((target / "snapshot.sha256").read_text(), "%s  snapshot.json\n" % sha)

    def test_content_is_deterministic_and_repo_bound(self):
        self.snapshot()
        data = json.loads((self.default_dir() / "snapshot.json").read_text())
        self.assertEqual((data["version"], data["repo"], data["taken_at"]), (1, "acme/widgets", "2026-09-19T12:00:00Z"))
        self.assertEqual([i["number"] for i in data["issues"]], [1, 2, 3])
        self.assertEqual(data["issues"][0]["labels"], ["priority:1-next", "status:inbox", "type:chore"])
        self.assertEqual(data["labels"], sorted(LABELS))

    def test_permissions_and_the_rollback_script(self):
        self.snapshot()
        target = self.default_dir()
        def mode(p):
            return stat.S_IMODE(p.stat().st_mode)
        self.assertEqual(mode(target), 0o700)
        self.assertEqual(mode(target / "snapshot.json"), 0o600)
        self.assertEqual(mode(target / "snapshot.sha256"), 0o600)
        self.assertEqual(mode(target / "rollback.sh"), 0o700)
        script = (target / "rollback.sh").read_text()
        sha = hashlib.sha256((target / "snapshot.json").read_bytes()).hexdigest()
        self.assertIn("backlog_cli.py", script)
        self.assertIn("--project-dir %s" % self.project.resolve(), script)
        self.assertIn("rollback --snapshot-dir %s --expect-sha %s" % (target.resolve(), sha), script)
        self.assertNotIn("--apply", script)

    def test_the_project_directory_is_left_untouched(self):
        before = sorted(str(p.relative_to(self.project)) for p in self.project.rglob("*"))
        rc, _ = self.snapshot()
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(str(p.relative_to(self.project)) for p in self.project.rglob("*")), before)

    def test_it_never_overwrites_an_existing_snapshot(self):
        self.assertEqual(self.snapshot()[0], 0)
        original = (self.default_dir() / "snapshot.json").read_bytes()
        rc, out = self.snapshot()  # same second: same directory
        self.assertEqual(rc, 1)
        self.assertIn("refusing to overwrite", out)
        self.assertEqual((self.default_dir() / "snapshot.json").read_bytes(), original)

    def test_refuses_a_target_under_the_project_the_plugin_or_a_git_repository(self):
        elsewhere = self.tmp / "other-repo"
        (elsewhere / ".git").mkdir(parents=True)
        for target in (self.project / "snaps", self.project, _support.PLUGIN_ROOT / "snaps", elsewhere / "snaps" / "x"):
            with self.subTest(target=str(target)):
                rc, out = self.snapshot("--snapshot-dir", str(target))
                self.assertEqual(rc, 1, out)
                self.assertIn("[snapshot] error:", out)
                self.assertFalse((target / "snapshot.json").exists())

    def test_a_git_directory_directly_in_home_is_tolerated(self):
        (self.home / ".git").mkdir()  # a dotfiles repo
        rc, out = self.snapshot()
        self.assertEqual(rc, 0, out)
        self.assertTrue((self.default_dir() / "snapshot.json").is_file())

    def test_an_explicit_directory_outside_everything_is_allowed(self):
        target = self.tmp / "elsewhere" / "s1"
        rc, out = self.snapshot("--snapshot-dir", str(target))
        self.assertEqual(rc, 0, out)
        self.assertTrue((target / "snapshot.json").is_file())

    def test_an_existing_directory_keeps_its_permissions(self):
        target = self.tmp / "shared"
        target.mkdir()
        target.chmod(0o755)
        self.assertEqual(self.snapshot("--snapshot-dir", str(target))[0], 0)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)

    def test_repo_is_required_and_the_flag_is_only_an_assertion(self):
        rc, out = self.snapshot(cfg=backlog_config.default_config("propose"))
        self.assertEqual(rc, 1)
        self.assertIn("`repo:` is required", out)
        rc, out = self.snapshot("--repo", "acme/other")
        self.assertEqual(rc, 1)
        self.assertIn("does not match", out)
        self.assertFalse((self.home / ".backlog-snapshots").exists())
        self.assertEqual(self.snapshot("--repo", "acme/widgets")[0], 0)

    def test_live_read_uses_gh_all_states_and_the_snapshot_fields(self):
        runner = _support.FakeRunner(issues=ISSUES, labels=LABELS)
        rc, out = self.call(backlog_snapshot.main_snapshot, [], gh=Gh(self.cfg, runner=runner), now=NOW)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.verbs(), [("issue", "list"), ("label", "list")])
        issue_call = runner.calls[0]
        self.assertEqual(issue_call[issue_call.index("--state") + 1], "all")
        self.assertIn("number,title,state,updatedAt,labels", issue_call)
        self.assertTrue(all(call[-2:] == ["-R", "acme/widgets"] for call in runner.calls))

    def test_a_possibly_truncated_read_writes_nothing(self):
        runner = _support.FakeRunner(issues=[{"number": n, "state": "OPEN", "labels": []} for n in range(backlog_snapshot.SNAPSHOT_LIMIT)], labels=LABELS)
        rc, out = self.call(backlog_snapshot.main_snapshot, [], gh=Gh(self.cfg, runner=runner), now=NOW)
        self.assertEqual(rc, 1)
        self.assertIn("possible silent truncation", out)
        self.assertFalse(self.default_dir().exists())


class TestRollback(Base):
    def setUp(self):
        super().setUp()
        self.assertEqual(self.snapshot()[0], 0)
        self.dir = self.default_dir()
        self.sha = hashlib.sha256((self.dir / "snapshot.json").read_bytes()).hexdigest()
        live = [
            {"number": 1, "state": "OPEN", "labels": [{"name": "type:chore"}, {"name": "status:ready"}, {"name": "exec:agent"}, {"name": "nightly"}]},
            {"number": 2, "state": "OPEN", "labels": [{"name": "type:bug"}, {"name": "status:ready"}, {"name": "exec:agent"}, {"name": "size:S"}]},
            {"number": 3, "state": "CLOSED", "labels": []},
        ]
        self.live_file = self.tmp / "live.json"
        self.live_file.write_text(json.dumps(live))

    def rollback(self, *extra, sha=None, cfg=None, labels=None):
        argv = ["--snapshot-dir", str(self.dir), "--expect-sha", sha or self.sha,
                "--issues-file", str(self.live_file), "--labels-file", str(labels or self.labels_file)] + list(extra)
        return self.call(backlog_snapshot.main_rollback, argv, cfg)

    def test_plan_restores_only_axis_labels_and_never_touches_protected_ones(self):
        rc, out = self.rollback()
        self.assertEqual(rc, 0, out)
        self.assertIn("| #issue | live | restored | add | remove |", out)
        row = [line for line in out.splitlines() if line.startswith("| #1 ")][0]
        cells = [c.strip() for c in row.strip("|").split("|")]
        self.assertEqual(cells[3], "priority:1-next, status:inbox")  # add
        self.assertEqual(cells[4], "exec:agent, status:ready")   # remove: axis labels only
        self.assertIn("nightly", cells[1])                       # live keeps the protected flag...
        self.assertIn("nightly", cells[2])                       # ...and so does the restored state
        self.assertNotIn("| #2 ", out)                           # already at the snapshot state
        self.assertIn("edits=1 table-digest: ", out)
        self.assertTrue(out.rstrip().endswith("(--apply needs --confirm <table-digest>)"))
        self.assertIn("dry-run: nothing written", out)

    def test_a_closed_at_snapshot_issue_is_ignored_and_a_now_closed_one_is_skipped(self):
        live = json.loads(self.live_file.read_text())
        live[1]["state"] = "CLOSED"
        self.live_file.write_text(json.dumps(live))
        rc, out = self.rollback()
        self.assertEqual(rc, 0)
        self.assertIn("[rollback] skip: #2 is closed or absent live", out)
        self.assertNotIn("#3", out)

    def test_a_label_that_no_longer_exists_is_reported_and_blocks_that_issue(self):
        no_label = self.tmp / "labels2.json"
        no_label.write_text(json.dumps([{"name": n} for n in LABELS if n != "priority:1-next"]))
        rc, out = self.rollback(labels=no_label)
        self.assertEqual(rc, 0)
        self.assertIn("[rollback] missing-label: #1 needs priority:1-next which does not exist in the repo", out)
        self.assertIn("edits=0", out)

    def test_a_wrong_sha_is_refused(self):
        rc, out = self.rollback(sha="0" * 64)
        self.assertEqual(rc, 1)
        self.assertIn("sha256 mismatch", out)
        self.assertNotIn("table-digest", out)

    def test_a_tampered_snapshot_is_refused(self):
        (self.dir / "snapshot.json").write_text((self.dir / "snapshot.json").read_text().replace("first", "hacked"))
        rc, out = self.rollback()
        self.assertEqual(rc, 1)
        self.assertIn("sha256 mismatch", out)

    def test_a_snapshot_of_another_repo_is_refused(self):
        other = self.tmp / "repo-b"
        other.mkdir()
        _support.write_repo_config(other, "acme/other")
        rc, out = self.rollback(cfg=backlog_config.load_config(str(other)))
        self.assertEqual(rc, 1)
        self.assertIn("belongs to acme/widgets, the config targets acme/other", out)

    def test_repo_is_required(self):
        rc, out = self.rollback(cfg=backlog_config.default_config("propose"))
        self.assertEqual(rc, 1)
        self.assertIn("`repo:` is required", out)

    def test_the_digest_is_stable_and_bound_to_the_repo(self):
        snapshot = json.loads((self.dir / "snapshot.json").read_text())["issues"]
        a = backlog_snapshot.rollback_digest(snapshot, "acme/widgets")
        self.assertEqual(a, backlog_snapshot.rollback_digest(snapshot, "acme/widgets"))
        self.assertNotEqual(a, backlog_snapshot.rollback_digest(snapshot, "acme/other"))
        self.assertEqual(len(a), 16)
        _, out = self.rollback()
        self.assertIn("table-digest: %s" % a, out)

    def test_apply_and_confirm_exist_but_no_batch_flag_does(self):
        for flag in (["--apply"], ["--confirm", "x"]):
            with self.subTest(flag=flag):
                backlog_snapshot.build_rollback_parser().parse_args(["--snapshot-dir", "d", "--expect-sha", "s"] + flag)
        for flag in (["--batch-size", "5"], ["--snap"]):
            with self.subTest(flag=flag), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    backlog_snapshot.build_rollback_parser().parse_args(["--snapshot-dir", "d", "--expect-sha", "s"] + flag)
                self.assertEqual(raised.exception.code, 2)

    def test_a_terminal_escape_in_a_snapshot_label_is_neutralized(self):
        data = json.loads((self.dir / "snapshot.json").read_text())
        data["issues"][0]["labels"].append("bad\x1b[31mlabel")
        payload = json.dumps(data, indent=2, sort_keys=True) + "\n"
        (self.dir / "snapshot.json").write_text(payload)
        rc, out = self.rollback(sha=hashlib.sha256(payload.encode()).hexdigest())
        self.assertEqual(rc, 0)
        self.assertNotIn("\x1b", out)
        self.assertIn("bad?[31mlabel", out)


class TestModuleHasNoDeletePath(unittest.TestCase):
    MODULES = ("backlog_snapshot.py", "backlog_catchup.py", "backlog_labelsync.py")
    FORBIDDEN = {"unlink", "rmtree", "remove", "rmdir", "removedirs", "rename", "replace"}

    def test_no_call_that_deletes_or_removes_a_file(self):
        # S1 writes local files (snapshot, propose --out) but must never delete state:
        # every new S1 module is covered, not only the snapshot one.
        for module in self.MODULES:
            with self.subTest(module=module):
                tree = ast.parse((_support.SCRIPTS / module).read_text())
                called = set()
                for node in ast.walk(tree):
                    if isinstance(node, ast.Call):
                        func = node.func
                        called.add(func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", ""))
                self.assertEqual(called & self.FORBIDDEN, set())

    def test_the_detector_flags_a_deleting_call(self):
        tree = ast.parse("import os\nos.remove('x')\n")
        called = {n.func.attr for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)}
        self.assertEqual(called & self.FORBIDDEN, {"remove"})


if __name__ == "__main__":
    unittest.main()
