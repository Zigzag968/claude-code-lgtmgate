"""`rollback --apply` and the snapshot -> catch-up apply -> rollback apply round trip (FakeRunner as GitHub)."""

import json
import re
import unittest

import _support as S
import backlog_catchup as K
import backlog_snapshot as SN


def labels_of(issue):
    return sorted(l["name"] for l in issue["labels"])


class RoundTrip(S.ApplyBase):
    def setUp(self):
        super().setUp()
        self.issues = self.bug_issues(3)
        self.original = self._copy.deepcopy(self.issues)
        self.dir, self.sha = self.take_snapshot(self._copy.deepcopy(self.issues))
        self.gh = self.new_runner(self.issues)

    def catchup(self):
        proposals = self.proposals_file([S.proposal(n) for n in (1, 2, 3)])
        argv = ["check", "--proposals", str(proposals), "--snapshot-dir", str(self.dir), "--expect-sha", self.sha]
        rc, out = self.call(K.main, argv, self.gh)
        self.assertEqual(rc, 0, out)
        rc, out = self.call(K.main, argv + ["--apply", "--confirm", self.digest(out)], self.gh)
        self.assertEqual(rc, 0, out)

    def rollback_argv(self, *extra):
        return ["--snapshot-dir", str(self.dir), "--expect-sha", self.sha] + list(extra)

    def rollback_digest(self):
        rc, out = self.call(SN.main_rollback, self.rollback_argv(), self.new_runner(self._copy.deepcopy(self.gh.issues)))
        self.assertEqual(rc, 0, out)
        return self.digest(out)

    def rollback(self, confirm=True):
        extra = ["--apply"] + (["--confirm", self.rollback_digest()] if confirm else [])
        return self.call(SN.main_rollback, self.rollback_argv(*extra), self.gh)


class TestRoundTrip(RoundTrip):
    def test_snapshot_catchup_apply_rollback_apply_restores_the_snapshot_labels(self):
        self.catchup()
        self.assertEqual({tuple(labels_of(i)) for i in self.gh.issues}, {("status:inbox", "type:bug")})
        writes_after_catchup = len(self.gh.writes())
        rc, out = self.rollback()
        self.assertEqual(rc, 0, out)
        self.assertEqual({tuple(labels_of(i)) for i in self.gh.issues}, {("bug",)})
        self.assertEqual([labels_of(i) for i in self.gh.issues], [labels_of(i) for i in self.original])
        self.assertGreater(len(self.gh.writes()), writes_after_catchup)
        self.assertIn("[rollback] restored #1 (+1 -2)", out)
        self.assertRegex(out, r"\[rollback\] restored=3 skipped=0 remaining=0 journal=.*rollback-applied\.json")
        journal = json.loads((self.dir / "rollback-applied.json").read_text())
        self.assertEqual((journal["kind"], journal["repo"]), ("rollback", "acme/widgets"))
        self.assertEqual([e["key"] for e in journal["entries"]], ["1", "2", "3"])

    def test_a_second_rollback_is_a_no_op_because_the_journal_and_the_live_state_agree(self):
        self.catchup()
        self.assertEqual(self.rollback()[0], 0)
        before = len(self.gh.writes())
        rc, out = self.rollback()
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.gh.writes()), before)
        self.assertIn("restored=0 skipped=0", out)

    def test_each_restore_adds_before_it_removes(self):
        self.catchup()
        start = len(self.gh.writes())
        self.rollback()
        first_two = [c[4].split("=")[0] for c in self.gh.writes()[start:start + 2]]
        self.assertEqual(first_two, ["--add-label", "--remove-label"])


class TestSkips(RoundTrip):
    def test_a_closed_or_absent_issue_is_skipped_with_a_line_and_counted(self):
        self.catchup()
        self.gh.issues[1]["state"] = "CLOSED"  # #2 closed since
        self.gh.issues.pop()  # #3 absent
        rc, out = self.rollback()
        self.assertEqual(rc, 0, out)
        self.assertIn("[rollback] skip: #2 is closed or absent live", out)
        self.assertIn("[rollback] skip: #3 is closed or absent live", out)
        self.assertRegex(out, r"restored=1 skipped=2 ")
        self.assertEqual(labels_of(self.gh.issues[0]), ["bug"])  # the open one was restored
        self.assertEqual(labels_of(self.gh.issues[1]), ["status:inbox", "type:bug"])  # the closed one was left alone
        self.assertEqual({int(c[3]) for c in self.gh.writes()[6:]}, {1})

    def test_a_label_that_disappeared_from_the_repo_skips_that_issue(self):
        self.catchup()
        self.gh.labels[:] = [n for n in self.gh.labels if n != "bug"]  # `bug` no longer exists: cannot be restored
        rc, out = self.rollback()
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(re.findall(r"missing-label: #\d needs bug", out)), 3)
        self.assertIn("restored=0 skipped=3", out)
        self.assertEqual({tuple(labels_of(i)) for i in self.gh.issues}, {("status:inbox", "type:bug")})

    def test_a_restore_that_would_re_add_a_role_label_is_skipped_never_applied(self):
        # #1 was `ready` + `agent` in the snapshot; a person (or a later catch-up) removed them since
        issues = [S.issue(1, "type:bug", "status:ready", "exec:agent"), S.issue(2, "bug")]
        directory, sha = self.take_snapshot(self._copy.deepcopy(issues), target=self.tmp / "snaps" / "roles")
        live = [S.issue(1, "type:bug"), S.issue(2, "type:bug", "status:inbox")]
        runner = self.new_runner(live)
        argv = ["--snapshot-dir", str(directory), "--expect-sha", sha]
        rc, out = self.call(SN.main_rollback, argv, self.new_runner(self._copy.deepcopy(live)))
        rc, out = self.call(SN.main_rollback, argv + ["--apply", "--confirm", self.digest(out)], runner)
        self.assertEqual(rc, 0, out)
        self.assertIn("skip: #1 role-add-refused", out)
        self.assertIn("restored=1 skipped=1", out)
        for call in runner.writes():
            self.assertNotIn("status:ready", call[4])
            self.assertNotIn("exec:agent", call[4])
        self.assertEqual(labels_of(runner.issues[0]), ["type:bug"])  # untouched
        self.assertEqual(labels_of(runner.issues[1]), ["bug"])


class TestRefusals(RoundTrip):
    def test_rollback_apply_without_confirm_is_exit_1_and_writes_nothing(self):
        self.catchup()
        before = len(self.gh.writes())
        rc, out = self.rollback(confirm=False)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: confirm", out)
        self.assertEqual(len(self.gh.writes()), before)
        self.assertFalse((self.dir / "rollback-applied.json").exists())

    def test_rollback_apply_in_propose_mode_writes_nothing(self):
        self.catchup()
        before = len(self.gh.writes())
        rc, out = self.call(SN.main_rollback, self.rollback_argv("--apply", "--confirm", "x"), self.gh, cfg=self.make_cfg("propose"))
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: mode", out)
        self.assertEqual(len(self.gh.writes()), before)

    def test_the_dry_run_prints_the_digest_apply_needs_and_stays_read_only(self):
        self.catchup()
        before = len(self.gh.writes())
        rc, out = self.call(SN.main_rollback, self.rollback_argv(), self.gh)
        self.assertEqual(rc, 0, out)
        self.assertIn("table-digest: %s" % SN.rollback_digest(json.loads((self.dir / "snapshot.json").read_text())["issues"], "acme/widgets"), out)
        self.assertEqual(len(self.gh.writes()), before)


if __name__ == "__main__":
    unittest.main()
