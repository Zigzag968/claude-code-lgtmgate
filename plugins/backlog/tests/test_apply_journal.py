"""Journal, batches, resume and stop-at-first-failure of the apply path (catch-up flavour, FakeRunner as GitHub)."""

import ast
import json
import os
import unittest
from unittest import mock

import _support
import backlog_apply
import backlog_catchup


class Journaled(_support.ApplyBase):
    def setup_run(self, count, **runner_kw):
        self.issues = self.bug_issues(count)
        self.dir, self.sha = self.take_snapshot(self._copy.deepcopy(self.issues))
        self.proposals = self.proposals_file([_support.proposal(n) for n in range(1, count + 1)])
        self.gh = self.new_runner(self.issues, **runner_kw)
        return self.gh

    def argv(self, apply=True, confirm=None):
        args = ["check", "--proposals", str(self.proposals), "--snapshot-dir", str(self.dir), "--expect-sha", self.sha]
        if apply:
            args.append("--apply")
            args += ["--confirm", confirm or self.confirm()]
        return args

    def confirm(self):
        rc, out = self.call(backlog_catchup.main, self.argv(apply=False), self.new_runner(self._copy.deepcopy(self.issues)))
        self.assertEqual(rc, 0, out)
        return self.digest(out)

    def run_apply(self, runner=None):
        return self.call(backlog_catchup.main, self.argv(), runner or self.gh)

    def journal(self, name="applied.json"):
        return json.loads((self.dir / name).read_text())

    def edited(self, runner=None):
        return [int(c[3]) for c in (runner or self.gh).writes()]


class TestJournalAfterEveryIssue(Journaled):
    def test_the_journal_is_rewritten_after_every_issue_and_always_valid_json(self):
        seen = []

        def before_write(argv):
            if "--add-label" in " ".join(argv):  # the first call of each issue
                path = self.dir / "applied.json"
                seen.append(len(json.loads(path.read_text())["entries"]) if path.exists() else 0)

        runner = self.setup_run(4, before_write=before_write)
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertEqual(seen, [0, 1, 2, 3])  # issue N starts once N-1 issues are journaled
        journal = self.journal()
        self.assertEqual([e["key"] for e in journal["entries"]], ["1", "2", "3", "4"])
        self.assertEqual({e["status"] for e in journal["entries"]}, {"applied"})
        self.assertEqual((journal["kind"], journal["repo"], journal["version"]), ("catchup", "acme/widgets", 1))
        self.assertEqual(journal["snapshot_sha"], self.sha)
        self.assertEqual(oct(os.stat(str(self.dir / "applied.json")).st_mode & 0o777), "0o600")

    def test_an_atomic_write_failure_keeps_the_previous_journal_intact(self):
        runner = self.setup_run(3)
        real_replace, calls = os.replace, []

        def flaky(src, dst):
            calls.append(dst)
            if len(calls) == 3:
                raise OSError("disk full")
            return real_replace(src, dst)

        with mock.patch("backlog_apply.os.replace", side_effect=flaky):
            rc, out = self.run_apply(runner)
        self.assertEqual(rc, 1, out)
        self.assertIn("disk full", out)
        journal = self.journal()  # valid JSON, never truncated: the state after the 2nd issue
        self.assertEqual([e["key"] for e in journal["entries"]], ["1", "2"])
        self.assertEqual(self.edited(runner), [1, 1, 2, 2, 3, 3])  # the third edit went out, its journal line did not
        self.assertIn("stopped: applied=2", out)

    def test_a_rerun_after_a_lost_journal_line_is_harmless(self):
        runner = self.setup_run(3)
        real_replace, calls = os.replace, []

        def flaky(src, dst):
            calls.append(dst)
            if len(calls) == 3:
                raise OSError("disk full")
            return real_replace(src, dst)

        with mock.patch("backlog_apply.os.replace", side_effect=flaky):
            self.run_apply(runner)
        before = len(runner.writes())
        rc, out = self.run_apply(runner)  # #3 is already in its target state on the live side: journaled as a no-op
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(runner.writes()), before)
        self.assertEqual([e["status"] for e in self.journal()["entries"]], ["applied", "applied", "noop"])


class TestStopAtFirstFailure(Journaled):
    def test_stop_at_first_failure_no_call_after_it_and_the_journal_is_current(self):
        runner = self.setup_run(3, fail_write_at=3)  # write 3 = the add of the 2nd issue
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(runner.writes()), 3)  # nothing was tried after the failure
        self.assertEqual([e["key"] for e in self.journal()["entries"]], ["1"])
        self.assertIn("[catch-up] error: #2:", out)
        self.assertIn("stopped: applied=1 remaining=2", out)

    def test_an_add_that_passed_before_a_failed_remove_is_journaled_partial(self):
        runner = self.setup_run(2, fail_write_at=2)  # the remove of the 1st issue
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(runner.writes()), 2)
        entries = self.journal()["entries"]
        self.assertEqual([(e["key"], e["status"], e["add"]) for e in entries], [("1", "partial", ["status:inbox", "type:bug"])])
        # the partial issue is not "done": a fixed rerun finishes it (remove only) and then does the next one
        runner.fail_write_at = None
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertEqual([tuple(c[4].split("=")[0:1]) for c in runner.writes()[2:]], [("--remove-label",), ("--add-label",), ("--remove-label",)])
        self.assertEqual(self.edited(runner), [1, 1, 1, 2, 2])
        self.assertEqual([(e["key"], e["status"]) for e in self.journal()["entries"]], [("1", "partial"), ("1", "applied"), ("2", "applied")])

    def test_journaled_issues_are_neither_revalidated_nor_reedited_on_resume(self):
        runner = self.setup_run(3, fail_write_at=3)
        self.run_apply(runner)
        runner.fail_write_at = None
        runner.issues[0]["state"] = "CLOSED"  # #1 is done and journaled: even a closed issue must not be looked at again
        writes_before = len(runner.writes())
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted({int(c[3]) for c in runner.writes()[writes_before:]}), [2, 3])
        self.assertIn("proposals=2 accepted=2 rejected=0", out)


class TestBatches(Journaled):
    def test_51_issues_run_one_edits_50_then_the_same_command_resumes_with_the_last(self):
        runner = self.setup_run(51)
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted(set(self.edited(runner))), list(range(1, 51)))
        self.assertEqual(len(set(self.edited(runner))), 50)
        self.assertIn("remaining=1", out)
        self.assertIn("batch limit reached: applied=50 remaining=1; re-run the same command to resume", out)
        self.assertEqual(len(self.journal()["entries"]), 50)

        writes_before = len(runner.writes())
        rc, out = self.run_apply(runner)  # the very same command line
        self.assertEqual(rc, 0, out)
        self.assertEqual({int(c[3]) for c in runner.writes()[writes_before:]}, {51})
        self.assertIn("remaining=0", out)
        self.assertNotIn("batch limit", out)
        journal = self.journal()
        self.assertEqual(len(journal["entries"]), 51)
        self.assertEqual(sorted(int(e["key"]) for e in journal["entries"]), list(range(1, 52)))
        self.assertEqual({tuple(sorted(l["name"] for l in i["labels"])) for i in runner.issues}, {("status:inbox", "type:bug")})

    def test_exactly_fifty_issues_is_one_run_with_nothing_left(self):
        runner = self.setup_run(50)
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertIn("remaining=0", out)
        self.assertNotIn("batch limit", out)


class TestDiffAgainstLiveAndOrdering(Journaled):
    def test_add_precedes_remove_and_a_label_already_present_is_not_added_again(self):
        runner = self.setup_run(1)
        runner.issues[0]["labels"].append({"name": "type:bug"})  # already there on the live side (and in no snapshot)
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertEqual([c[4] for c in runner.writes()], ["--add-label=status:inbox", "--remove-label=bug"])

    def test_an_issue_already_in_the_target_state_is_a_noop_without_any_call(self):
        runner = self.setup_run(1)
        runner.issues[0]["labels"] = [{"name": "status:inbox"}, {"name": "type:bug"}]
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [])
        self.assertIn("noop #1", out)
        self.assertEqual(self.journal()["entries"][0]["status"], "noop")


class TestJournalIsBoundToItsTable(Journaled):
    def test_a_journal_of_another_table_or_snapshot_is_refused_with_zero_write(self):
        runner = self.setup_run(2)
        self.run_apply(runner)
        other = self.proposals_file([_support.proposal(1)], name="other.json")  # another table: another digest
        self.proposals, kept = other, self.proposals
        fresh = self.new_runner(self._copy.deepcopy(self.issues))
        rc, out = self.call(backlog_catchup.main, self.argv(), fresh)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: snapshot", out)
        self.assertIn("journal of another table", out)
        self.assertEqual(fresh.writes(), [])
        self.proposals = kept

    def test_an_unreadable_journal_is_refused(self):
        runner = self.setup_run(1)
        (self.dir / "applied.json").write_text("{not json")
        rc, out = self.run_apply(runner)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: snapshot", out)
        self.assertEqual(runner.writes(), [])


class TestApplierSourceHasNoDeletePath(unittest.TestCase):
    FORBIDDEN = {"unlink", "remove", "rmtree", "rmdir", "removedirs", "rename"}

    def calls(self):
        tree = ast.parse((_support.SCRIPTS / "backlog_apply.py").read_text())
        out = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                func = node.func
                out.append((func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", ""), node))
        return tree, out

    def test_the_applier_never_deletes_removes_or_renames(self):
        _, calls = self.calls()
        self.assertEqual({name for name, _ in calls} & self.FORBIDDEN, set())

    def test_its_only_replace_is_os_replace_inside_the_journal(self):
        tree, calls = self.calls()
        replaces = [node for name, node in calls if name == "replace"]
        self.assertEqual(len(replaces), 1)
        func = replaces[0].func
        self.assertEqual((func.value.id, func.attr), ("os", "replace"))
        journal = next(n for n in ast.walk(tree) if isinstance(n, ast.ClassDef) and n.name == "Journal")
        self.assertIn(replaces[0], list(ast.walk(journal)))

    def test_the_detector_flags_a_deleting_call(self):
        tree = ast.parse("import os\nos.remove('x')\nPath('y').unlink()\n")
        names = {n.func.attr for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)}
        self.assertEqual(names & self.FORBIDDEN, {"remove", "unlink"})


class TestJournalClass(unittest.TestCase):
    def test_a_missing_file_is_a_new_journal_and_done_only_counts_applied_and_noop(self):
        with _support.tmpdir() as tmp:
            path = os.path.join(tmp, "j.json")
            journal = backlog_apply.Journal.load(path, "catchup", "acme/widgets", "d", "s")
            self.assertEqual(journal.done(), set())
            journal.record("1", "applied", ["a"], [])
            journal.record("2", "partial", ["b"], [])
            journal.record("3", "noop")
            again = backlog_apply.Journal.load(path, "catchup", "acme/widgets", "d", "s")
            self.assertEqual(again.done(), {"1", "3"})
            for kind, repo, digest, sha in (("rollback", "acme/widgets", "d", "s"), ("catchup", "acme/o", "d", "s"),
                                            ("catchup", "acme/widgets", "x", "s"), ("catchup", "acme/widgets", "d", "y")):
                with self.subTest(kind=kind, repo=repo, digest=digest, sha=sha), self.assertRaises(backlog_apply.RefusedError):
                    backlog_apply.Journal.load(path, kind, repo, digest, sha)


if __name__ == "__main__":
    unittest.main()
