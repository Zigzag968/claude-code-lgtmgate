"""`backlog_cli.py set`: one issue, dry run first, journaled apply. In-process, fake runner only (no live gh)."""

import contextlib
import io
import json
import os
import stat
import unittest

import _support as S
import backlog_apply as A
import backlog_promote as P
import backlog_set
from backlog_gh import Gh


def edit_argv(number, flag, labels, repo="acme/widgets"):
    return ["gh", "issue", "edit", str(number), "%s=%s" % (flag, ",".join(labels)), "-R", repo]


class SetBase(S.ApplyBase):
    """A write-supervised acme/widgets config with the reference taxonomy and no legacy mapping."""

    def setUp(self):
        super().setUp()
        self.cfg = self.make_cfg(extra="")

    def journal_path(self, cfg=None):
        return A.project_dir_of(cfg or self.cfg) / ".claude" / ".backlog-snapshots" / "set-journal.jsonl"

    def journal_lines(self):
        return [json.loads(line) for line in self.journal_path().read_text().splitlines()]

    def run_set(self, argv, issues=None, cfg=None, labels=None, **kw):
        cfg = cfg or self.cfg
        issues = [S.issue(1, "type:bug", "status:inbox")] if issues is None else issues
        runner = self.new_runner(issues, labels=labels, **kw)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = backlog_set.main(list(argv), cfg, gh=Gh(cfg, runner=runner), apply_runner=runner)
        return rc, buf.getvalue(), runner

    def parse_error(self, argv, cfg=None):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as raised:
            backlog_set.main(list(argv), cfg or self.cfg)
        self.assertEqual(raised.exception.code, 2)
        return err.getvalue()


class TestDryRun(SetBase):
    def test_dry_run_prints_the_plan_and_makes_no_write_call(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info"])
        self.assertEqual(rc, 0, out)
        self.assertIn("[set] #1 status:inbox -> status:needs-info (+status:needs-info -status:inbox)", out)
        self.assertIn("dry-run only: nothing was written", out)
        self.assertEqual(runner.writes(), [])
        self.assertFalse(self.journal_path().exists())

    def test_dry_run_works_in_propose_mode_and_without_repo(self):
        cfg = self.make_cfg(mode="propose", repo=None, extra="")
        rc, out, runner = self.run_set(["--issue", "1", "--size", "M"], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [])
        self.assertEqual(set(runner.verbs()), {("issue", "view"), ("label", "list")})

    def test_dry_run_reads_the_issue_without_its_free_text(self):
        _, _, runner = self.run_set(["--issue", "1", "--status", "needs-info"])
        view = next(c for c in runner.calls if tuple(c[1:3]) == ("issue", "view"))
        self.assertNotIn("body", view[view.index("--json") + 1].split(","))

    def test_dry_run_of_a_noop_says_so(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "inbox"])
        self.assertEqual(rc, 0)
        self.assertIn("noop", out)
        self.assertEqual(runner.writes(), [])

    def test_dry_run_replaces_the_labels_of_the_axis_only(self):
        issues = [S.issue(1, "type:bug", "status:inbox", "size:S", "area:web")]
        rc, out, _ = self.run_set(["--issue", "1", "--size", "M"], issues=issues)
        self.assertEqual(rc, 0, out)
        self.assertIn("size:S -> size:M (+size:M -size:S)", out)


class TestRefusedBeforeAnyCall(SetBase):
    def test_refused_apply_in_mode_propose_makes_no_call(self):
        cfg = self.make_cfg(mode="propose", extra="")
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], cfg=cfg)
        self.assertEqual(rc, 1)
        self.assertIn("refused: mode:", out)
        self.assertEqual(runner.calls, [])

    def test_refused_apply_without_repo_makes_no_call(self):
        cfg = self.make_cfg(repo=None, extra="")
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], cfg=cfg)
        self.assertEqual(rc, 1)
        self.assertIn("refused: repo:", out)
        self.assertEqual(runner.calls, [])

    def test_refused_repo_assertion_mismatch_makes_no_call(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply", "--repo", "other/repo"])
        self.assertEqual(rc, 1)
        self.assertIn("does not match", out)
        self.assertEqual(runner.calls, [])

    def test_refused_promotion_makes_no_call(self):
        for argv in (["--status", "ready"], ["--exec", "agent"], ["--status", "ready", "--exec", "agent"]):
            with self.subTest(argv=argv):
                rc, out, runner = self.run_set(["--issue", "1", "--apply"] + argv)
                self.assertEqual(rc, 1)
                self.assertIn("promotion-off", out)
                self.assertEqual(runner.calls, [])


class TestRefusedAfterTheRead(SetBase):
    def test_refused_issue_absent_is_an_error_with_no_write(self):
        rc, out, runner = self.run_set(["--issue", "9", "--status", "needs-info", "--apply"])
        self.assertEqual(rc, 1)
        self.assertIn("error:", out)
        self.assertEqual(runner.writes(), [])

    def test_refused_closed_issue_writes_nothing(self):
        issues = [S.issue(1, "type:bug", "status:inbox", state="CLOSED")]
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], issues=issues)
        self.assertEqual(rc, 1)
        self.assertIn("issue-not-open", out)
        self.assertEqual(runner.writes(), [])

    def test_refused_unknown_label_writes_nothing(self):
        labels = [n for n in S.APPLY_LIVE_LABELS if n != "status:needs-info"]
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], labels=labels)
        self.assertEqual(rc, 1)
        self.assertIn("unknown-label", out)
        self.assertEqual(runner.writes(), [])

    def test_refused_second_executor_writes_nothing(self):
        issues = [S.issue(1, "type:bug", "status:inbox", "nightly")]
        rc, out, runner = self.run_set(["--issue", "1", "--exec", "founder", "--apply"], issues=issues)
        self.assertEqual(rc, 1)
        self.assertIn("lint:executor-multiple", out)
        self.assertEqual(runner.writes(), [])

    def test_refused_axis_replacement_that_would_drop_an_unknown_label(self):
        issues = [S.issue(1, "type:bug", "status:inbox", "size:XL")]
        rc, out, runner = self.run_set(["--issue", "1", "--size", "M", "--apply"], issues=issues)
        self.assertEqual(rc, 1)
        self.assertIn("remove-not-allowed", out)
        self.assertEqual(runner.writes(), [])

    def test_cap_admits_the_change_when_a_real_count_is_under_the_limit(self):
        cfg = self.make_cfg(extra='caps:\n  "size:M": 1\n')
        rc, out, runner = self.run_set(["--issue", "1", "--size", "M", "--apply"], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [edit_argv(1, "--add-label", ["size:M"])])

    def test_refused_cap_exceeded_after_a_real_open_issue_count(self):
        cfg = self.make_cfg(extra='caps:\n  "size:M": 1\n')
        issues = [S.issue(1, "type:bug", "status:inbox"), S.issue(2, "type:bug", "status:inbox", "size:M")]
        rc, out, runner = self.run_set(["--issue", "1", "--size", "M", "--apply"], issues=issues, cfg=cfg)
        self.assertEqual(rc, 1)
        self.assertIn("cap-exceeded:size:M", out)
        self.assertEqual(runner.writes(), [])

    def test_cap_count_ignores_closed_issues(self):
        cfg = self.make_cfg(extra='caps:\n  "size:M": 1\n')
        issues = [S.issue(1, "type:bug", "status:inbox"), S.issue(2, "type:bug", "status:inbox", "size:M", state="CLOSED")]
        rc, out, runner = self.run_set(["--issue", "1", "--size", "M", "--apply"], issues=issues, cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [edit_argv(1, "--add-label", ["size:M"])])

    def test_a_gh_failure_on_a_capped_change_is_an_error_with_no_write(self):
        cfg = self.make_cfg(extra='caps:\n  "size:M": 1\n')
        rc, out, runner = self.run_set(["--issue", "1", "--size", "M", "--apply"], cfg=cfg, fail=FileNotFoundError("gh"))
        self.assertEqual(rc, 1)
        self.assertIn("error", out)
        self.assertEqual(runner.writes(), [])

    def test_refused_when_the_journal_cannot_be_created(self):
        project_dir = A.project_dir_of(self.cfg)
        (project_dir / ".claude" / ".backlog-snapshots").write_text("a file where the directory should be")
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"])
        self.assertEqual(rc, 1)
        self.assertIn("refused: journal:", out)
        self.assertEqual(runner.writes(), [])


class TestArgumentSurface(SetBase):
    def test_priority_and_area_are_real_flags_but_there_is_no_raw_label_flag(self):
        # --priority/--area take a value restricted to the config (no "invalid choice" for a bogus flag name)
        self.assertIn("invalid choice", self.parse_error(["--issue", "1", "--priority", "not-a-value"]))
        for flag in ("--label", "--add-label", "--remove-label", "--confirm"):
            with self.subTest(flag=flag):
                self.parse_error(["--issue", "1", flag, "x"])

    def test_help_offers_priority_and_area(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            backlog_set.main(["--help"], self.cfg)
        self.assertEqual(raised.exception.code, 0)
        self.assertIn("--priority", out.getvalue())
        self.assertIn("--area", out.getvalue())
        self.assertIn("--status", out.getvalue())

    def test_area_accepts_any_value_when_the_axis_is_free(self):
        # the reference taxonomy's `area` is free (no fixed values): argparse must not refuse every value, and
        # the shared triage validator must not flag it add-not-allowed (unknown-label still fires: the repo
        # label itself does not exist in this fixture's live label set)
        rc, out, _ = self.run_set(["--issue", "1", "--area", "anything-at-all"])
        self.assertEqual(rc, 1, out)
        self.assertIn("unknown-label", out)
        self.assertNotIn("add-not-allowed", out)

    def test_area_restricted_to_declared_values_when_the_config_declares_a_fixed_list(self):
        cfg = self.make_cfg(extra="labels:\n  area: [web, mobile]\n")
        err = self.parse_error(["--issue", "1", "--area", "not-a-declared-value"], cfg=cfg)
        self.assertIn("invalid choice", err)
        rc, out, _ = self.run_set(
            ["--issue", "1", "--area", "web"], cfg=cfg, labels=list(S.APPLY_LIVE_LABELS) + ["area:web"]
        )
        self.assertEqual(rc, 0, out)
        rc, out, _ = self.run_set(
            ["--issue", "1", "--area", "anything-at-all"], labels=list(S.APPLY_LIVE_LABELS) + ["area:anything-at-all"]
        )
        self.assertEqual(rc, 0, out)

    def test_the_nightly_executor_flag_cannot_be_requested(self):
        self.assertIn("invalid choice", self.parse_error(["--issue", "1", "--exec", "nightly"]))

    def test_values_are_restricted_to_the_config(self):
        self.assertIn("invalid choice", self.parse_error(["--issue", "1", "--status", "done"]))
        self.assertIn("invalid choice", self.parse_error(["--issue", "1", "--size", "XL"]))

    def test_an_axis_flag_is_required_and_the_issue_must_be_positive(self):
        self.parse_error(["--issue", "1"])
        self.parse_error(["--issue", "0", "--status", "inbox"])
        self.parse_error(["--issue", "x", "--status", "inbox"])
        self.parse_error(["--status", "inbox"])


class TestApply(SetBase):
    def test_a_lateral_change_writes_add_then_remove_and_nothing_else(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply", "--reason", "needs a repro"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(
            runner.writes(),
            [edit_argv(1, "--add-label", ["status:needs-info"]), edit_argv(1, "--remove-label", ["status:inbox"])],
        )
        self.assertIn("[set] applied: added=status:needs-info removed=status:inbox journal=", out)

    def test_free_mode_applies_too(self):
        cfg = self.make_cfg(mode="free", extra="")
        rc, out, runner = self.run_set(["--issue", "1", "--size", "S", "--apply"], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [edit_argv(1, "--add-label", ["size:S"])])

    def test_two_axes_in_one_call(self):
        issues = [S.issue(1, "type:bug", "status:inbox", "size:S")]
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--size", "M", "--apply"], issues=issues)
        self.assertEqual(rc, 0, out)
        self.assertEqual(
            runner.writes(),
            [
                edit_argv(1, "--add-label", ["size:M", "status:needs-info"]),
                edit_argv(1, "--remove-label", ["size:S", "status:inbox"]),
            ],
        )

    def test_protected_and_bare_labels_never_reach_an_argv(self):
        issues = [S.issue(1, "type:bug", "status:inbox", "nightly", "cross-repo", "auto:blocked")]
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], issues=issues)
        self.assertEqual(rc, 0, out)
        argv_text = " ".join(" ".join(call) for call in runner.writes())
        for name in ("nightly", "cross-repo", "auto:blocked"):
            self.assertNotIn(name, argv_text)

    def test_the_noop_apply_writes_nothing_and_leaves_no_journal(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "inbox", "--apply"])
        self.assertEqual(rc, 0)
        self.assertEqual(runner.writes(), [])
        self.assertFalse(self.journal_path().exists())

    def test_a_failed_first_write_is_journaled_as_failed(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], fail_write_at=1)
        self.assertEqual(rc, 1)
        self.assertIn("error:", out)
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "failed"])

    def test_a_failed_removal_after_the_add_is_journaled_as_partial(self):
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], fail_write_at=2)
        self.assertEqual(rc, 1)
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "partial"])


class TestJournal(SetBase):
    def test_the_intent_line_precedes_the_applied_line(self):
        seen = []

        def before_write(argv):
            seen.append(self.journal_lines() if self.journal_path().exists() else None)

        rc, out, _ = self.run_set(
            ["--issue", "1", "--status", "needs-info", "--apply", "--reason", "needs a repro"], before_write=before_write
        )
        self.assertEqual(rc, 0, out)
        self.assertEqual([e["status"] for e in seen[0]], ["intent"])  # the intent was on disk BEFORE the first write
        lines = self.journal_lines()
        self.assertEqual([e["status"] for e in lines], ["intent", "applied"])
        intent = lines[0]
        self.assertEqual(intent["issue"], 1)
        self.assertEqual(intent["before"], ["status:inbox", "type:bug"])
        self.assertEqual(intent["add"], ["status:needs-info"])
        self.assertEqual(intent["remove"], ["status:inbox"])
        self.assertEqual(intent["reason"], "needs a repro")

    def test_the_journal_is_private_and_inside_the_project(self):
        self.run_set(["--issue", "1", "--status", "needs-info", "--apply"])
        path = self.journal_path()
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(path.parent).st_mode), 0o700)
        project_dir = A.project_dir_of(self.cfg)
        self.assertEqual(path.parent, project_dir / ".claude" / ".backlog-snapshots")
        self.assertIn(str(project_dir), str(path))

    def test_the_journal_is_appended_never_rewritten(self):
        self.run_set(["--issue", "1", "--status", "needs-info", "--apply"])
        self.run_set(["--issue", "1", "--size", "S", "--apply"])
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "applied", "intent", "applied"])

    def test_the_journal_never_holds_free_text_of_the_issue(self):
        issues = [S.issue(1, "type:bug", "status:inbox", body="SECRET-TEXT - [ ] x")]
        self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], issues=issues)
        text = self.journal_path().read_text()
        self.assertNotIn("SECRET-TEXT", text)
        for entry in self.journal_lines():
            self.assertNotIn("body", entry)


BODY = "## Acceptance\n- [ ] the thing works\n- [x] and is tested\n"
PROMOTE = ["--issue", "1", "--status", "ready", "--exec", "agent"]


class PromotionBase(SetBase):
    """A repo that opted in with `promotion: checked`; the baseline issue passes every condition of the check."""

    def setUp(self):
        super().setUp()
        self.cfg = self.make_cfg(extra="promotion: checked\n")

    def candidate(self, *extra, body=BODY, blockers=(), state="OPEN", labels=("type:feature", "status:inbox", "size:S")):
        return S.issue(1, *(tuple(labels) + extra), blockers=list(blockers), body=body, state=state)

    def views(self, runner):
        return [c for c in runner.calls if tuple(c[1:3]) == ("issue", "view")]


class TestPromotion(PromotionBase):
    def test_dry_run_of_a_promotion_prints_the_facts_and_writes_nothing(self):
        rc, out, runner = self.run_set(PROMOTE, issues=[self.candidate()])
        self.assertEqual(rc, 0, out)
        self.assertIn("[set] #1 promotion requested (+exec:agent +status:ready -status:inbox)", out)
        self.assertIn("[set] promotion: checkboxes=2 size=size:S type=type:feature blockers=0 verdict=ok", out)
        self.assertIn("dry-run only", out)
        self.assertEqual(runner.writes(), [])
        self.assertFalse(self.journal_path().exists())

    def test_an_ok_promotion_writes_the_adds_then_the_removal_and_journals_the_verdict(self):
        rc, out, runner = self.run_set(PROMOTE + ["--apply", "--reason", "spec is clear"], issues=[self.candidate()])
        self.assertEqual(rc, 0, out)
        self.assertEqual(
            runner.writes(),
            [edit_argv(1, "--add-label", ["exec:agent", "status:ready"]), edit_argv(1, "--remove-label", ["status:inbox"])],
        )
        self.assertIn("[set] applied: added=exec:agent,status:ready removed=status:inbox", out)
        intent = self.journal_lines()[0]
        self.assertEqual(intent["promotion"]["ok"], True)
        self.assertEqual(intent["promotion"]["codes"], [])
        self.assertEqual(intent["promotion"]["facts"], {"checkboxes": 2, "size": "size:S", "type": "type:feature", "blockers": 0})
        self.assertNotIn("the thing works", self.journal_path().read_text())

    def test_only_a_promotion_reads_the_free_text_of_the_issue(self):
        _, _, promoting = self.run_set(PROMOTE, issues=[self.candidate()])
        _, _, demoting = self.run_set(["--issue", "1", "--status", "needs-info"], issues=[self.candidate()])
        _, _, lateral = self.run_set(["--issue", "1", "--size", "M"], issues=[self.candidate()])
        (view,) = self.views(promoting)
        self.assertIn("body", view[view.index("--json") + 1].split(","))
        for runner in (demoting, lateral):
            (view,) = self.views(runner)
            self.assertNotIn("body", view[view.index("--json") + 1].split(","))

    def test_refused_promotion_whose_only_checkbox_is_in_a_code_fence(self):
        issue = self.candidate(body="## Acceptance\n```\n- [ ] not a real item\n```\n")
        rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[issue])
        self.assertEqual(rc, 1)
        self.assertIn("refused: promotion: no-acceptance", out)
        self.assertEqual(runner.writes(), [])
        self.assertFalse(self.journal_path().exists())

    def test_refused_promotion_whose_only_checkbox_is_in_a_comment(self):
        rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[self.candidate(body="<!-- - [ ] hidden -->")])
        self.assertEqual(rc, 1)
        self.assertIn("no-acceptance", out)
        self.assertEqual(runner.writes(), [])

    def test_refused_promotion_for_each_code_writes_nothing(self):
        cases = {
            "no-acceptance": self.candidate(body="no list here"),
            "open-blocker:9": self.candidate(blockers=[{"number": 9, "state": "OPEN"}]),
            "blockers-unknown": S.issue(1, "type:feature", "status:inbox", "size:S", body=BODY),
            "founder-executor": self.candidate("exec:founder"),
            "protected-present:auto:blocked": self.candidate("auto:blocked"),
            "exclusion:cross-repo": self.candidate("cross-repo"),
            "exclusion:money-path": self.candidate("money-path"),
            "no-type": self.candidate(labels=("type:epic", "status:inbox", "size:S")),
            "lint:ready-size-l": self.candidate(labels=("type:feature", "status:inbox", "size:L")),
            "lint:ready-no-size": self.candidate(labels=("type:feature", "status:inbox")),
        }
        for code, issue in cases.items():
            with self.subTest(code=code):
                rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[issue])
                self.assertEqual(rc, 1, out)
                self.assertIn(code, out)
                self.assertEqual(runner.writes(), [])

    def test_refused_promotion_lists_every_miss(self):
        issue = self.candidate("cross-repo", body="", blockers=[{"number": 9, "state": "OPEN"}])
        rc, out, runner = self.run_set(PROMOTE, issues=[issue])
        self.assertEqual(rc, 1)
        for code in ("no-acceptance", "open-blocker:9", "exclusion:cross-repo", "protected-present:cross-repo"):
            self.assertIn(code, out)
        self.assertEqual(runner.writes(), [])

    def test_refused_promotion_of_a_closed_or_absent_issue(self):
        rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[self.candidate(state="CLOSED")])
        self.assertEqual((rc, runner.writes()), (1, []))
        rc, out, runner = self.run_set(["--issue", "5", "--status", "ready", "--exec", "agent", "--apply"], issues=[self.candidate()])
        self.assertEqual((rc, runner.writes()), (1, []))

    def test_refused_promotion_of_an_issue_that_carries_nightly(self):
        # nightly is never set, and an issue that already carries it cannot get a second executor
        issue = self.candidate("nightly")
        rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[issue])
        self.assertEqual(rc, 1)
        self.assertIn("lint:executor-multiple", out)
        self.assertEqual(runner.writes(), [])
        for call in runner.calls:
            self.assertNotIn("--add-label=nightly", call)

    def test_refused_promotion_in_mode_propose_makes_no_call(self):
        cfg = self.make_cfg(mode="propose", extra="promotion: checked\n")
        rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[self.candidate()], cfg=cfg)
        self.assertEqual((rc, runner.calls), (1, []))

    def test_a_propose_mode_dry_run_can_check_a_promotion(self):
        cfg = self.make_cfg(mode="propose", extra="promotion: checked\n")
        rc, out, runner = self.run_set(PROMOTE, issues=[self.candidate()], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertIn("verdict=ok", out)
        self.assertEqual(runner.writes(), [])

    def test_status_ready_alone_is_checked_too(self):
        issue = self.candidate(labels=("type:feature", "status:inbox", "size:S", "exec:agent"))
        rc, out, runner = self.run_set(["--issue", "1", "--status", "ready", "--apply"], issues=[issue])
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes()[0], edit_argv(1, "--add-label", ["status:ready"]))

    def test_a_demotion_from_ready_needs_no_verdict(self):
        issue = self.candidate(labels=("type:feature", "status:ready", "size:S", "exec:agent"), body="")
        rc, out, runner = self.run_set(["--issue", "1", "--status", "needs-info", "--apply"], issues=[issue])
        self.assertEqual(rc, 0, out)
        self.assertIsNone(self.journal_lines()[0]["promotion"])

    def test_an_already_ready_issue_is_a_noop(self):
        issue = self.candidate(labels=("type:feature", "status:ready", "size:S", "exec:agent"))
        rc, out, runner = self.run_set(PROMOTE + ["--apply"], issues=[issue])
        self.assertEqual(rc, 0)
        self.assertIn("noop", out)
        self.assertEqual(runner.writes(), [])


class TestBootstrapCarveOut(SetBase):
    """Fix #259: a labelless issue's first `set --apply` picking up type/status:inbox/size/an agent executor
    together is a triage bootstrap, not a readiness promotion — it succeeds without an acceptance checklist,
    under `promotion: checked` and either value of `exec_gating`."""

    BOOTSTRAP_ARGV = ["--issue", "1", "--status", "inbox", "--type", "feature", "--size", "S", "--exec", "agent", "--apply"]

    def test_succeeds_under_promotion_checked_default_exec_gating(self):
        cfg = self.make_cfg(extra="promotion: checked\n")
        rc, out, runner = self.run_set(self.BOOTSTRAP_ARGV, issues=[S.issue(1)], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("no-acceptance", out)
        self.assertEqual(runner.writes(), [edit_argv(1, "--add-label", ["exec:agent", "size:S", "status:inbox", "type:feature"])])

    def test_succeeds_under_promotion_checked_and_exec_gating_triage(self):
        cfg = self.make_cfg(extra="promotion: checked\nexec_gating: triage\n")
        rc, out, runner = self.run_set(self.BOOTSTRAP_ARGV, issues=[S.issue(1)], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [edit_argv(1, "--add-label", ["exec:agent", "size:S", "status:inbox", "type:feature"])])

    def test_still_refused_without_promotion_checked(self):
        cfg = self.make_cfg(extra="")
        rc, out, runner = self.run_set(self.BOOTSTRAP_ARGV, issues=[S.issue(1)], cfg=cfg)
        self.assertEqual(rc, 1)
        self.assertIn("promotion-off", out)
        self.assertEqual(runner.writes(), [])

    def test_requesting_ready_too_is_not_carved_out_and_needs_the_full_check(self):
        cfg = self.make_cfg(extra="promotion: checked\n")
        argv = ["--issue", "1", "--status", "ready", "--type", "feature", "--size", "S", "--exec", "agent", "--apply"]
        rc, out, runner = self.run_set(argv, issues=[S.issue(1)], cfg=cfg)
        self.assertEqual(rc, 1)
        self.assertIn("no-acceptance", out)
        self.assertEqual(runner.writes(), [])


class TestTheGrantOfASet(PromotionBase):
    """Defence in depth: the applier relaxes the refusal only for an ok verdict of THIS issue on an opted-in repo."""

    def edit(self, issue=1):
        return A.LabelEdit(
            issue=issue, before=("status:inbox", "type:feature"), after=("exec:agent", "status:ready", "type:feature"),
            add=("exec:agent", "status:ready"), remove=("status:inbox",), reason="x",
        )

    def verdict(self, issue=1, ok=True):
        return P.PromotionVerdict(issue=issue, ok=ok, codes=() if ok else ("no-acceptance",), facts={})

    def test_the_bulk_refusal_is_the_default(self):
        self.assertEqual(A.mint_set_grant(self.cfg, self.edit()).refused_adds, frozenset({"status:ready", "exec:agent"}))

    def test_an_ok_verdict_of_the_same_issue_lifts_it(self):
        self.assertEqual(A.mint_set_grant(self.cfg, self.edit(), self.verdict()).refused_adds, frozenset())

    def test_no_other_verdict_lifts_it(self):
        for name, verdict in (
            ("another issue", self.verdict(issue=2)),
            ("not ok", self.verdict(ok=False)),
            ("not a verdict", {"ok": True, "issue": 1}),
            ("none", None),
        ):
            with self.subTest(case=name):
                self.assertEqual(A.mint_set_grant(self.cfg, self.edit(), verdict).refused_adds, frozenset({"status:ready", "exec:agent"}))

    def test_a_repo_that_did_not_opt_in_never_lifts_it(self):
        cfg = self.make_cfg(extra="")
        self.assertEqual(A.mint_set_grant(cfg, self.edit(), self.verdict()).refused_adds, frozenset({"status:ready", "exec:agent"}))

    def test_the_grant_covers_one_issue_and_no_label_creation(self):
        grant = A.mint_set_grant(self.cfg, self.edit(), self.verdict())
        self.assertEqual((grant.issues, grant.labels), (frozenset({1}), frozenset()))

    def test_refused_execute_without_a_verdict_never_writes_a_promotion(self):
        runner = S.FakeRunner(issues=[self.candidate()])
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = A.execute_set(self.cfg, self.edit(), "x", None, apply_runner=runner)
        self.assertEqual(rc, 1)
        self.assertEqual(runner.writes(), [])
        # journaled first, then the chokepoint itself refused the add
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "failed"])

    def test_the_bulk_grant_still_refuses_ready_and_agent(self):
        gate = A.Gate(digest="d", confirm="d", sha="s", rejected=0)
        grant = A.mint_grant(self.cfg, gate, issues=[1])
        self.assertEqual(grant.refused_adds, frozenset({"status:ready", "exec:agent"}))


if __name__ == "__main__":
    unittest.main()
