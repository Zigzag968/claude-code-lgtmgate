import contextlib
import io
import json
import subprocess
import unittest

import _support as S
import backlog_config as C
from backlog_gh import Gh
from next_item import main, open_blockers, open_pr_references, select_next

SNAPSHOT = S.FIXTURES / "backlog_issues_snapshot.json"
EMPTY_QUEUE = S.FIXTURES / "backlog_issues_empty_queue.json"
PRS = S.FIXTURES / "backlog_prs_open.json"

# The reference implementation also excludes its two legacy flags from the queue: they are plain `exclusions` here.
with S.tmpdir() as _tmp:
    S.write_config(_tmp, "contract: 1\nmode: propose\nexclusions: [cross-repo, money-path, epic, triage:interactive]\n")
    CFG = C.load_config(_tmp)
assert CFG.mode == "propose", CFG.reason

BASE = ("status:ready", "exec:agent", "size:S", "type:chore")


def _issue(number, *labels, created="2026-09-10T00:00:00Z", state="OPEN", blockers=None):
    return S.issue(number, *(labels or BASE), state=state, created=created, blockers=blockers)


def _labels(*extra, drop=()):
    return tuple(name for name in BASE if name not in drop) + extra


def _picked(issues, prs=(), **kwargs):
    selection = select_next(list(issues), list(prs), CFG, **kwargs)
    return selection.selected["number"] if selection.selected else None


def run_main(argv, gh=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = main(argv, CFG, gh)
    return rc, out.getvalue()


class TestSort(unittest.TestCase):
    def test_baseline_issue_is_selected(self):
        self.assertEqual(_picked([_issue(1)]), 1)

    def test_priority_beats_bug(self):
        p0_chore = _issue(1, *_labels("priority:0-now"))
        p1_bug = _issue(2, *_labels("priority:1-next", "type:bug", drop=("type:chore",)))
        self.assertEqual(_picked([p1_bug, p0_chore]), 1)

    def test_any_priority_beats_no_priority(self):
        self.assertEqual(_picked([_issue(1), _issue(2, *_labels("priority:2-later"))]), 2)

    def test_bug_beats_size(self):
        self.assertEqual(_picked([_issue(1), _issue(2, "status:ready", "exec:agent", "size:M", "type:bug")]), 2)

    def test_size_beats_age(self):
        old_medium = _issue(1, "status:ready", "exec:agent", "size:M", "type:chore", created="2026-01-01T00:00:00Z")
        new_small = _issue(2, created="2026-09-01T00:00:00Z")
        self.assertEqual(_picked([old_medium, new_small]), 2)

    def test_age_beats_number(self):
        self.assertEqual(_picked([_issue(1, *BASE, created="2026-09-02T00:00:00Z"), _issue(9, created="2026-09-01T00:00:00Z")]), 9)

    def test_number_is_the_last_tiebreak(self):
        self.assertEqual(_picked([_issue(5), _issue(3)]), 3)

    def test_priority_rank_follows_configured_order(self):
        with S.tmpdir() as tmp:
            S.write_config(tmp, "contract: 1\nmode: propose\nlabels:\n  priority: [2-later, 1-next, 0-now]\ncaps:\n")
            cfg = C.load_config(tmp)
        first = _issue(1, *_labels("priority:0-now"))
        second = _issue(2, *_labels("priority:2-later"))
        self.assertEqual(select_next([first, second], [], cfg).selected["number"], 2)


class TestExclusions(unittest.TestCase):
    def test_never_selects_intake_status(self):
        self.assertIsNone(_picked([_issue(1, *_labels("status:inbox"))]))

    def test_never_selects_waiting_status(self):
        self.assertIsNone(_picked([_issue(1, *_labels("status:needs-info"))]))

    def test_never_selects_not_ready(self):
        self.assertIsNone(_picked([_issue(1, *_labels(drop=("status:ready",)))]))

    def test_never_selects_human_executor(self):
        self.assertIsNone(_picked([_issue(1, "status:ready", "exec:human", "size:S", "type:chore")]))
        self.assertIsNone(_picked([_issue(1, *_labels("exec:human"))], allowed_executors=("exec:agent",)))

    def test_never_selects_epic_type(self):
        self.assertIsNone(_picked([_issue(1, "status:ready", "exec:agent", "size:S", "type:epic")]))

    def test_never_selects_configured_exclusion_flags(self):
        for flag in ("epic", "cross-repo", "money-path", "triage:interactive"):
            with self.subTest(flag=flag):
                self.assertIsNone(_picked([_issue(1, *_labels(flag))]))

    def test_exclusions_are_configurable(self):
        cfg = C.default_config("propose")  # reference defaults: no `triage:interactive` exclusion
        issue = _issue(1, *_labels("triage:interactive"))
        self.assertEqual(select_next([issue], [], cfg).selected["number"], 1)

    def test_never_selects_split_size_or_no_size(self):
        self.assertIsNone(_picked([_issue(1, "status:ready", "exec:agent", "size:L", "type:chore")]))
        self.assertIsNone(_picked([_issue(1, *_labels(drop=("size:S",)))]))

    def test_never_selects_closed_issue(self):
        self.assertIsNone(_picked([_issue(1, state="CLOSED")]))

    def test_open_blocker_blocks_closed_blocker_does_not(self):
        self.assertIsNone(_picked([_issue(1, blockers=[{"number": 9, "state": "OPEN"}])]))
        self.assertEqual(_picked([_issue(1, blockers=[{"number": 9, "state": "CLOSED"}])]), 1)

    def test_missing_blocked_by_key_is_tolerated(self):
        issue = _issue(1)
        self.assertNotIn("blockedBy", issue)
        self.assertEqual(open_blockers(issue), [])
        self.assertEqual(_picked([issue]), 1)

    def test_open_pr_references_exclude(self):
        closing = {"number": 50, "title": "x", "body": "", "closingIssuesReferences": [{"number": 1}]}
        body = {"number": 50, "title": "x", "body": "Part of the work on #1.", "closingIssuesReferences": []}
        title = {"number": 50, "title": "feat: thing (#1)", "body": "", "closingIssuesReferences": []}
        for pr in (closing, body, title):
            with self.subTest(pr=pr["title"]):
                self.assertIsNone(_picked([_issue(1)], [pr]))

    def test_pr_reference_to_4330_does_not_exclude_433(self):
        pr = {"number": 50, "title": "x", "body": "Closes #4330", "closingIssuesReferences": []}
        self.assertEqual(open_pr_references([pr]), {4330})
        self.assertEqual(_picked([_issue(433)], [pr]), 433)

    def test_pr_reference_inside_another_repo_path_is_not_a_match(self):
        pr = {"number": 50, "title": "x", "body": "see other/repo#1", "closingIssuesReferences": []}
        self.assertEqual(_picked([_issue(1)], [pr]), 1)

    def test_pr_missing_closing_refs_key_is_tolerated(self):
        self.assertEqual(open_pr_references([{"number": 50, "title": "x", "body": None}]), set())

    def test_default_executor_excludes_flag_executors_and_opt_in_includes_them(self):
        nightly = _issue(1, "status:ready", "nightly", "size:S", "type:chore")
        self.assertIsNone(_picked([nightly]))
        self.assertEqual(_picked([nightly], allowed_executors=("exec:agent", "nightly")), 1)

    def test_no_executor_is_never_selected(self):
        self.assertIsNone(_picked([_issue(1, *_labels(drop=("exec:agent",)))]))


class TestCli(unittest.TestCase):
    def test_snapshot_fixture_winner_and_candidates(self):
        selection = select_next(json.loads(SNAPSHOT.read_text()), json.loads(PRS.read_text()), CFG)
        self.assertEqual(selection.selected["number"], 101)
        self.assertEqual(selection.candidates, [101, 102, 104])

    def test_snapshot_fixture_with_nightly_executor_adds_113(self):
        selection = select_next(json.loads(SNAPSHOT.read_text()), json.loads(PRS.read_text()), CFG, allowed_executors=("exec:agent", "nightly"))
        self.assertEqual(selection.candidates, [101, 102, 104, 113])

    def test_main_selected_output(self):
        rc, out = run_main(["--issues-file", str(SNAPSHOT), "--prs-file", str(PRS)])
        self.assertEqual(rc, 0)
        lines = out.splitlines()
        self.assertEqual(lines[0], "[next-item] selected=#101 priority=priority:0-now size=size:S title=winner: ready agent bug S p0")
        self.assertEqual(lines[1], "[next-item] candidates=3")

    def test_queue_empty_exact_line(self):
        rc, out = run_main(["--issues-file", str(EMPTY_QUEUE), "--prs-file", str(PRS)])
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "[next-item] queue empty: inbox=3 needs-info=1")

    def test_json_output_shape(self):
        rc, out = run_main(["--issues-file", str(SNAPSHOT), "--prs-file", str(PRS), "--json"])
        payload = json.loads(out)
        self.assertEqual(set(payload), {"selected", "queue_empty", "inbox", "needs_info", "candidates"})
        self.assertEqual(payload["selected"]["number"], 101)
        self.assertFalse(payload["queue_empty"])
        self.assertEqual(payload["candidates"], [101, 102, 104])

    def test_json_output_when_empty(self):
        rc, out = run_main(["--issues-file", str(EMPTY_QUEUE), "--prs-file", str(PRS), "--json"])
        payload = json.loads(out)
        self.assertIsNone(payload["selected"])
        self.assertTrue(payload["queue_empty"])
        self.assertEqual((payload["inbox"], payload["needs_info"]), (3, 1))

    def test_cli_executor_flag_is_repeatable(self):
        argv = ["--issues-file", str(SNAPSHOT), "--prs-file", str(PRS), "--json", "--executor", "exec:agent", "--executor", "nightly"]
        rc, out = run_main(argv)
        self.assertEqual(json.loads(out)["candidates"], [101, 102, 104, 113])

    def test_fetch_failure_returns_1_and_is_never_queue_empty(self):
        gh = Gh(CFG, runner=S.FakeRunner(fail=subprocess.CalledProcessError(1, "gh")))
        rc, out = run_main([], gh)
        self.assertEqual(rc, 1)
        self.assertTrue(out.startswith("[next-item] error:"))
        self.assertNotIn("queue empty", out)

    def test_fetch_failure_on_unparseable_json_returns_1(self):
        def runner(argv, **kw):
            return subprocess.CompletedProcess(argv, 0, stdout="not json", stderr="")

        rc, out = run_main([], Gh(CFG, runner=runner))
        self.assertEqual(rc, 1)
        self.assertNotIn("queue empty", out)

    def test_truncated_fetch_is_an_error_not_an_empty_queue(self):
        runner = S.FakeRunner(issues=[{"number": n} for n in range(500)])
        rc, out = run_main([], Gh(CFG, runner=runner))
        self.assertEqual(rc, 1)
        self.assertIn("truncation", out)
        self.assertNotIn("queue empty", out)

    def test_fetch_uses_limits(self):
        runner = S.FakeRunner()
        rc, _ = run_main([], Gh(CFG, runner=runner))
        self.assertEqual(rc, 0)
        self.assertEqual(len(runner.calls), 2)
        self.assertTrue(all("--limit" in c for c in runner.calls))

    def test_bad_issues_file_returns_1(self):
        with S.tmpdir() as tmp:
            bad = S.Path(tmp) / "issues.json"
            bad.write_text('{"not": "a list"}')
            rc, out = run_main(["--issues-file", str(bad), "--prs-file", str(PRS)])
        self.assertEqual(rc, 1)
        self.assertNotIn("queue empty", out)

    def test_human_and_unknown_executor_are_not_selectable(self):
        for bad in ("exec:human", "bogus"):
            with self.subTest(bad=bad):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        main(["--issues-file", str(SNAPSHOT), "--prs-file", str(PRS), "--executor", bad], CFG)


if __name__ == "__main__":
    unittest.main()
