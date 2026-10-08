import contextlib
import io
import json
import re
import unittest

import _support
import backlog_config
import backlog_triage
from backlog_gh import Gh

CFG = backlog_config.default_config("propose")
LIVE = {"type:bug", "type:feature", "type:chore", "status:inbox", "status:needs-info", "status:ready",
        "exec:agent", "exec:human", "size:S", "size:M", "size:L", "priority:0-now", "priority:1-next", "priority:2-later"}


def prop(issue, before, after, reason="because", confidence="high"):
    return {"issue": issue, "labels_before": list(before), "labels_after": list(after), "reason": reason, "confidence": confidence}


def verdicts(proposals, issues, live=LIVE, cfg=CFG):
    results = backlog_triage.validate(backlog_triage.parse_proposals(proposals), issues, live, cfg)
    return {(r.proposal.issue, r.proposal.index): r.codes for r in results}


def codes_for(entry, issue):
    return list(verdicts([entry], [issue]).values())[0]


INBOX = ("type:chore", "status:inbox")
GOOD = prop(1, INBOX, ("type:chore", "status:ready", "exec:agent", "size:S"))


class TestValidate(unittest.TestCase):
    def issue(self, labels=INBOX, number=1, state="OPEN"):
        return _support.issue(number, *labels, state=state)

    def test_a_good_proposal_is_accepted(self):
        self.assertEqual(codes_for(GOOD, self.issue()), [])

    def test_each_rejection_code_fires_with_a_positive_twin(self):
        base = self.issue()
        cases = [
            ("bad-schema", {"issue": 1}, base),
            ("bad-schema", prop(1, INBOX, INBOX, confidence="sure"), base),
            ("issue-not-found", prop(99, INBOX, ("type:chore", "status:ready", "exec:agent", "size:S")), base),
            ("issue-not-open", GOOD, self.issue(state="CLOSED")),
            ("noop", prop(1, INBOX, INBOX), base),
            ("stale-before", prop(1, ("type:chore", "status:needs-info"), ("type:chore", "status:ready", "exec:agent", "size:S")), base),
            ("protected-label-changed", prop(1, INBOX + ("nightly",), INBOX), self.issue(INBOX + ("nightly",))),
            ("protected-label-changed", prop(1, INBOX, INBOX + ("auto:pr-ready",)), base),
            ("add-not-allowed", prop(1, INBOX, INBOX + ("money-path",)), base),
            ("remove-not-allowed", prop(1, INBOX + ("money-path",), INBOX), self.issue(INBOX + ("money-path",))),
            ("unknown-label", prop(1, INBOX, INBOX + ("priority:1-next",)), base),
            ("lint:ready-no-size", prop(1, INBOX, ("type:chore", "status:ready", "exec:agent")), base),
            ("lint:ready-size-l", prop(1, INBOX, ("type:chore", "status:ready", "exec:agent", "size:L")), base),
            ("lint:type-multiple", prop(1, INBOX, ("type:chore", "type:bug", "status:inbox")), base),
        ]
        for code, entry, issue in cases:
            with self.subTest(code=code, entry=entry):
                live = LIVE - {"priority:1-next"} if code == "unknown-label" else LIVE
                got = list(verdicts([entry], [issue], live).values())[0]
                self.assertIn(code, got)
        # positive twins: the same shapes, made valid, carry none of these codes
        self.assertEqual(codes_for(prop(1, INBOX, INBOX + ("priority:1-next",)), self.issue()), [])

    def test_free_axis_labels_may_be_proposed_but_still_need_a_real_repo_label(self):
        # add-not-allowed is lifted for a free namespace (area:* by default), but unknown-label still requires
        # the label to actually exist in the repo
        got = codes_for(prop(1, INBOX, INBOX + ("area:web",)), self.issue())
        self.assertNotIn("add-not-allowed", got)
        self.assertIn("unknown-label", got)
        self.assertEqual(list(verdicts([prop(1, INBOX, INBOX + ("area:web",))], [self.issue()], LIVE | {"area:web"}).values())[0], [])

    def test_duplicate_issue_rejects_both(self):
        got = verdicts([GOOD, prop(1, INBOX, INBOX + ("priority:1-next",))], [self.issue()])
        self.assertEqual(list(got.values()), [["duplicate-issue"], ["duplicate-issue"]])

    def test_cap_goes_to_the_lowest_issue_number(self):
        issues = [self.issue(number=n) for n in (1, 2, 3)]
        issues += [_support.issue(n, "type:chore", "status:inbox", "priority:0-now") for n in (10, 11)]
        proposals = [prop(n, INBOX, INBOX + ("priority:0-now",)) for n in (1, 2)]
        got = verdicts(proposals, issues)
        self.assertEqual(got[(1, 0)], ["cap-exceeded:priority:0-now"])
        self.assertEqual(got[(2, 1)], ["cap-exceeded:priority:0-now"])

    def test_cap_admits_up_to_the_limit_in_issue_order(self):
        issues = [self.issue(number=n) for n in (1, 2, 3)] + [_support.issue(10, "type:chore", "status:inbox", "priority:0-now")]
        proposals = [prop(n, INBOX, INBOX + ("priority:0-now",)) for n in (3, 2)]
        got = verdicts(proposals, issues)
        self.assertEqual(got[(2, 1)], [])
        self.assertEqual(got[(3, 0)], ["cap-exceeded:priority:0-now"])

    def test_results_are_ordered_by_issue_number(self):
        issues = [self.issue(number=n) for n in (5, 2)]
        results = backlog_triage.validate(backlog_triage.parse_proposals([prop(5, INBOX, INBOX + ("priority:2-later",)), prop(2, INBOX, INBOX + ("priority:2-later",))]), issues, LIVE, CFG)
        self.assertEqual([r.proposal.issue for r in results], [2, 5])


class TestInboxAndTable(unittest.TestCase):
    def test_list_inbox_returns_intake_and_waiting_open_issues(self):
        issues = [
            _support.issue(3, "type:bug", "status:needs-info"),
            _support.issue(1, "type:bug", "status:inbox"),
            _support.issue(2, "type:bug", "status:ready", "exec:agent", "size:S"),
            _support.issue(4, "type:bug", "status:inbox", state="CLOSED"),
        ]
        self.assertEqual([i["number"] for i in backlog_triage.list_inbox(issues, CFG)], [1, 3])

    def test_render_table_and_digest(self):
        proposals = backlog_triage.parse_proposals([GOOD, prop(2, INBOX, INBOX, reason="a | b")])
        results = backlog_triage.validate(proposals, [_support.issue(1, *INBOX), _support.issue(2, *INBOX)], LIVE, CFG)
        table = backlog_triage.render_table(results)
        self.assertIn("| #1 |", table)
        self.assertIn("REJECT(noop)", table)
        self.assertIn("a \\| b", table)
        digest = backlog_triage.table_digest(proposals)
        self.assertRegex(digest, r"^[0-9a-f]{16}$")
        self.assertEqual(digest, backlog_triage.table_digest(list(reversed(proposals))))
        self.assertNotEqual(digest, backlog_triage.table_digest(backlog_triage.parse_proposals([GOOD])))


def run(fn, argv, gh=None, cfg=CFG):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = fn(argv, cfg, gh)
    return rc, out.getvalue()


class TestCli(unittest.TestCase):
    def files(self, tmp, proposals, issues):
        tmp = _support.Path(tmp)
        (tmp / "p.json").write_text(json.dumps(proposals))
        (tmp / "i.json").write_text(json.dumps(issues))
        (tmp / "l.json").write_text(json.dumps([{"name": n} for n in sorted(LIVE)]))
        return tmp

    def test_triage_check_offline_prints_table_and_digest_and_writes_nothing(self):
        with _support.tmpdir() as tmp:
            tmp = self.files(tmp, [GOOD], [_support.issue(1, *INBOX)])
            rc, out = run(backlog_triage.main_check, ["--proposals", str(tmp / "p.json"), "--issues-file", str(tmp / "i.json"), "--labels-file", str(tmp / "l.json")])
        self.assertEqual(rc, 0)
        self.assertIn("accepted=1 rejected=0", out)
        self.assertRegex(out, r"table-digest: [0-9a-f]{16}")
        self.assertIn("propose-only: nothing was written", out)

    def test_strict_fails_on_a_rejected_row(self):
        with _support.tmpdir() as tmp:
            tmp = self.files(tmp, [prop(1, INBOX, INBOX)], [_support.issue(1, *INBOX)])
            rc, out = run(backlog_triage.main_check, ["--proposals", str(tmp / "p.json"), "--issues-file", str(tmp / "i.json"), "--labels-file", str(tmp / "l.json"), "--strict"])
        self.assertEqual(rc, 1)
        self.assertIn("REJECT(noop)", out)

    def test_triage_check_uses_reads_only_when_fetching(self):
        runner = _support.FakeRunner(issues=[_support.issue(1, *INBOX)], labels=sorted(LIVE))
        with _support.tmpdir() as tmp:
            tmp = self.files(tmp, [GOOD], [])
            rc, out = run(backlog_triage.main_check, ["--proposals", str(tmp / "p.json")], Gh(CFG, runner=runner))
        self.assertEqual(rc, 0)
        self.assertEqual(runner.verbs(), [("issue", "list"), ("label", "list")])

    def test_fetch_failure_is_an_error(self):
        with _support.tmpdir() as tmp:
            tmp = self.files(tmp, [GOOD], [])
            rc, out = run(backlog_triage.main_check, ["--proposals", str(tmp / "p.json")], Gh(CFG, runner=_support.FakeRunner(fail=FileNotFoundError("gh"))))
        self.assertEqual(rc, 1)
        self.assertIn("error", out)

    def test_inbox_prints_json(self):
        runner = _support.FakeRunner(issues=[_support.issue(1, *INBOX), _support.issue(2, "type:bug", "status:ready", "exec:agent", "size:S")])
        rc, out = run(backlog_triage.main_inbox, [], Gh(CFG, runner=runner))
        self.assertEqual(rc, 0)
        self.assertEqual([i["number"] for i in json.loads(out)], [1])

    def test_no_apply_flag_exists_anywhere(self):
        for parser in (backlog_triage.build_check_parser(), backlog_triage.build_inbox_parser()):
            self.assertNotIn("--apply", parser.format_help())
            self.assertNotIn("--confirm", parser.format_help())
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    parser.parse_args(["--apply"])

    def test_module_has_no_write_surface(self):
        source = (_support.SCRIPTS / "backlog_triage.py").read_text(encoding="utf-8")
        self.assertEqual(re.findall(r"create_issue|write=True|confirmed", source), [])


if __name__ == "__main__":
    unittest.main()
