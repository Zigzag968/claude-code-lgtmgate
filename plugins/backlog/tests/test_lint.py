import contextlib
import io
import json
import unittest

import _support
import backlog_config
from backlog_gh import Gh, ModeError
from backlog_lint import lint, main

SNAPSHOT = _support.FIXTURES / "backlog_issues_snapshot.json"
EMPTY_QUEUE = _support.FIXTURES / "backlog_issues_empty_queue.json"
CFG = backlog_config.default_config("propose")


def _issue(number, *labels, state="OPEN"):
    return _support.issue(number, *labels, state=state)


def _clean(number=1, *extra):
    return _issue(number, "type:chore", "status:inbox", *extra)


def _codes(issues, cfg=CFG):
    return [v.code for v in lint(issues, cfg)]


def run_main(argv, cfg=CFG, gh=None):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = main(argv, cfg, gh)
    return rc, out.getvalue()


class TestLint(unittest.TestCase):
    def test_clean_issue_yields_nothing(self):
        self.assertEqual(lint([_clean()], CFG), [])

    def test_ready_clean_issue_yields_nothing(self):
        self.assertEqual(lint([_issue(1, "type:bug", "status:ready", "exec:agent", "size:S")], CFG), [])

    def test_each_rule_code_fires(self):
        table = [
            (("status:inbox",), "type-missing"),
            (("type:bug", "type:chore", "status:inbox"), "type-multiple"),
            (("type:bug",), "status-missing"),
            (("type:bug", "status:inbox", "status:needs-info"), "status-multiple"),
            (("type:bug", "status:inbox", "priority:0-now", "priority:1-next"), "priority-multiple"),
            (("type:bug", "status:inbox", "size:S", "size:M"), "size-multiple"),
            (("type:bug", "status:inbox", "exec:agent", "exec:human"), "executor-multiple"),
            (("type:bug", "status:ready", "size:S"), "ready-no-executor"),
            (("type:bug", "status:ready", "exec:agent"), "ready-no-size"),
            (("type:bug", "status:ready", "exec:agent", "size:L"), "ready-size-l"),
            (("type:bug", "status:inbox", "size:XL"), "unknown-value"),
            (("type:bug", "status:inbox", "priority:9-never"), "unknown-value"),
        ]
        for labels, code in table:
            with self.subTest(code=code, labels=labels):
                self.assertIn(code, _codes([_issue(7, *labels)]))

    def test_nightly_alone_is_a_valid_executor(self):
        self.assertEqual(lint([_issue(1, "type:chore", "status:ready", "nightly", "size:S")], CFG), [])

    def test_nightly_plus_exec_agent_violates_executor_multiple(self):
        self.assertIn("executor-multiple", _codes([_issue(1, "type:chore", "status:inbox", "nightly", "exec:agent")]))

    def test_flags_and_free_axes_are_ignored(self):
        issue = _issue(1, "type:chore", "status:inbox", "cross-repo", "epic", "bug", "area:product", "auto:blocked")
        self.assertEqual(lint([issue], CFG), [])

    def test_closed_issues_are_ignored(self):
        self.assertEqual(lint([_issue(1, state="CLOSED")], CFG), [])

    def test_caps_boundary_exactly_at_cap_is_clean(self):
        issues = [_clean(n, "priority:0-now") for n in (1, 2)] + [_clean(n, "priority:1-next") for n in range(10, 18)]
        self.assertNotIn("cap-exceeded", _codes(issues))

    def test_caps_exceeded_by_one_violates_at_repo_level(self):
        issues = [_clean(n, "priority:0-now") for n in (1, 2, 3)] + [_clean(n, "priority:1-next") for n in range(10, 19)]
        violations = [v for v in lint(issues, CFG) if v.code == "cap-exceeded"]
        self.assertEqual(len(violations), 2)
        self.assertTrue(all(v.number is None for v in violations))
        self.assertTrue(violations[0].render().startswith("[backlog-lint] #- cap-exceeded:"))

    def test_closed_issues_do_not_count_toward_caps(self):
        issues = [_clean(n, "priority:0-now") for n in (1, 2)] + [_issue(3, "priority:0-now", state="CLOSED")]
        self.assertNotIn("cap-exceeded", _codes(issues))

    def test_explicit_empty_caps_override_config_caps(self):
        issues = [_clean(n, "priority:0-now") for n in (1, 2, 3)]
        self.assertEqual([v.code for v in lint(issues, CFG, caps={})], [])

    def test_ordering_is_deterministic_by_number_then_code(self):
        issues = [_issue(9), _issue(3, "type:bug", "type:chore")]
        first = lint(issues, CFG)
        self.assertEqual(first, lint(list(reversed(issues)), CFG))
        self.assertEqual([(v.number, v.code) for v in first], sorted((v.number, v.code) for v in first))

    def test_labels_come_from_the_config_not_from_constants(self):
        with _support.tmpdir() as tmp:
            _support.write_config(
                tmp,
                "contract: 1\nmode: propose\nlabels:\n  size: [XS, S]\n  status: [new, todo, ready]\n"
                "roles:\n  intake: new\n  waiting: todo\n  ready: ready\n  split: [S]\n  candidate_sizes: [XS]\ncaps:\n",
            )
            cfg = backlog_config.load_config(tmp)
        self.assertEqual(cfg.mode, "propose")
        codes = [v.code for v in lint([_issue(1, "type:bug", "status:ready", "exec:agent", "size:S")], cfg)]
        self.assertIn("ready-size-l", codes)  # S is the split size in this config
        self.assertIn("unknown-value", [v.code for v in lint([_issue(2, "type:bug", "status:inbox")], cfg)])
        self.assertEqual(lint([_issue(3, "type:bug", "status:todo", "size:M")], cfg)[0].code, "unknown-value")


class TestLintCli(unittest.TestCase):
    def test_main_snapshot_strict_fails_and_names_codes(self):
        rc, out = run_main(["--issues-file", str(SNAPSHOT), "--strict"])
        self.assertEqual(rc, 1)
        for code in ("type-missing", "status-multiple", "executor-multiple", "ready-size-l", "ready-no-executor"):
            self.assertIn(" %s:" % code, out)
        self.assertIn("violations=", out)

    def test_main_snapshot_without_strict_exits_zero(self):
        rc, out = run_main(["--issues-file", str(SNAPSHOT)])
        self.assertEqual(rc, 0)
        self.assertIn("[backlog-lint] violations=", out)

    def test_main_empty_queue_fixture_is_lint_clean(self):
        rc, out = run_main(["--issues-file", str(EMPTY_QUEUE), "--strict"])
        self.assertEqual(rc, 0)
        self.assertIn("violations=0", out)

    def test_main_fetch_failure_returns_1(self):
        runner = _support.FakeRunner(fail=FileNotFoundError("gh"))
        rc, out = run_main([], gh=Gh(CFG, runner=runner))
        self.assertEqual(rc, 1)
        self.assertTrue(out.startswith("[backlog-lint] error:"))
        self.assertNotIn("violations=0", out)

    def test_main_refused_gh_returns_1(self):
        rc, out = run_main([], gh=Gh(backlog_config.default_config("off"), runner=_support.FakeRunner()))
        self.assertEqual(rc, 1)
        self.assertIn("error", out)

    def test_fetch_passes_a_limit(self):
        runner = _support.FakeRunner()
        rc, _ = run_main([], gh=Gh(CFG, runner=runner))
        self.assertEqual(rc, 0)
        self.assertIn("--limit", runner.calls[0])


if __name__ == "__main__":
    unittest.main()
