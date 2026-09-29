import contextlib
import hashlib
import io
import json
import unittest
from pathlib import Path

import _support as S
import backlog_catchup as K
import backlog_config as C
import backlog_triage as T
from backlog_gh import Gh

MAPPING = (
    "legacy_map:\n  bug: type:bug\n  enhancement: type:feature\n  tech-debt: type:chore\n  epic: type:epic\n"
    "  P0-now: priority:0-now\n  P1-next: priority:1-next\n  triage:interactive: exec:founder\n"
    "legacy_keep: [epic, triage:interactive]\n"
)
LIVE = {"type:bug", "type:feature", "type:chore", "type:epic", "status:inbox", "status:needs-info", "status:ready",
        "exec:agent", "exec:founder", "size:S", "size:M", "size:L", "priority:0-now", "priority:1-next", "priority:2-later"}


def load(extra="", repo="acme/widgets"):
    with S.tmpdir() as tmp:
        S.write_repo_config(tmp, repo, "propose", extra)
        cfg = C.load_config(tmp)
    assert cfg.mode == "propose", cfg.reason
    return cfg


MAPPED = load(MAPPING)
DEFAULT = load()


def after(names, cfg=MAPPED):
    result = K.map_legacy(set(names), cfg)
    return result


class TestMapLegacy(unittest.TestCase):
    def test_default_config_maps_nothing_but_still_forces_the_intake_status(self):
        got = after(["type:chore"], DEFAULT)
        self.assertEqual(got.after, frozenset({"type:chore", "status:inbox"}))
        self.assertEqual((got.reason, got.confidence), ("no status->status:inbox", "high"))

    def test_default_config_without_a_type_is_type_unmapped(self):
        got = after(["bug", "enhancement"], DEFAULT)
        self.assertEqual((got.after, got.unresolved), (None, "type-unmapped"))

    def test_a_canonical_issue_is_already_canonical(self):
        got = after(["type:chore", "status:inbox", "priority:1-next", "nightly"], DEFAULT)
        self.assertEqual((got.reason, got.after), ("already canonical", frozenset({"type:chore", "status:inbox", "priority:1-next", "nightly"})))

    def test_custom_mapping_replaces_legacy_labels_and_keeps_unrelated_ones(self):
        got = after(["bug", "P0-now", "nightly", "docs"])
        self.assertEqual(got.after, frozenset({"type:bug", "priority:0-now", "status:inbox", "nightly", "docs"}))
        self.assertEqual(got.confidence, "high")
        for part in ("bug->type:bug", "P0-now->priority:0-now", "no status->status:inbox"):
            self.assertIn(part, got.reason)

    def test_legacy_keep_keeps_the_legacy_label_next_to_its_canonical_one(self):
        got = after(["epic", "triage:interactive"])
        self.assertEqual(got.after, frozenset({"epic", "type:epic", "triage:interactive", "exec:founder", "status:inbox"}))
        self.assertIn("epic->type:epic (kept)", got.reason)

    def test_a_kept_legacy_label_whose_canonical_twin_exists_is_already_canonical(self):
        got = after(["epic", "type:epic", "status:inbox"])
        self.assertEqual(got.reason, "already canonical")

    def test_each_axis_conflict_is_unresolved(self):
        cases = [
            ("type-conflict", ["type:bug", "enhancement", "status:inbox"]),
            ("priority-conflict", ["bug", "P0-now", "P1-next"]),
            ("priority-conflict", ["bug", "P0-now", "priority:1-next"]),
            ("status-conflict", ["bug", "status:inbox", "status:needs-info"]),
            ("exec-conflict", ["bug", "exec:agent", "triage:interactive"]),
        ]
        for code, names in cases:
            with self.subTest(code=code, names=names):
                got = after(names)
                self.assertEqual(got.unresolved, code)
                self.assertIsNone(got.after)

    def test_two_existing_types_are_a_conflict(self):
        self.assertEqual(after(["type:bug", "type:chore"]).unresolved, "type-conflict")

    def test_type_precedence_follows_the_configured_order_at_medium_confidence(self):
        got = after(["enhancement", "tech-debt"])
        self.assertEqual(got.after, frozenset({"type:feature", "status:inbox"}))  # feature is before chore
        self.assertEqual(got.confidence, "medium")
        self.assertIn("type precedence feature>chore", got.reason)
        reordered = load(MAPPING.replace("legacy_map:", "labels:\n  type: [chore, feature, bug, epic]\nlegacy_map:", 1))
        self.assertEqual(after(["enhancement", "tech-debt"], reordered).after, frozenset({"type:chore", "status:inbox"}))

    def test_a_single_mapped_type_is_not_a_precedence_call(self):
        self.assertEqual(after(["bug"]).confidence, "high")

    def test_an_explicit_status_wins_over_the_default(self):
        got = after(["bug", "status:needs-info"])
        self.assertEqual(got.after, frozenset({"type:bug", "status:needs-info"}))

    def test_an_area_target_is_added_without_a_conflict_check(self):
        cfg = load("labels:\n  area: [web, api]\nlegacy_map:\n  bug: type:bug\n  ui: area:web\n  backend: area:api\n")
        got = after(["bug", "ui", "backend"], cfg)
        self.assertEqual(got.after, frozenset({"type:bug", "area:web", "area:api", "status:inbox"}))


class TestValidateCatchup(unittest.TestCase):
    def check(self, entry, issue, cfg=MAPPED):
        results = K.validate_catchup(T.parse_proposals([entry]), [issue], LIVE, cfg)
        return results[0].codes

    def prop(self, before, after_, issue=1):
        return {"issue": issue, "labels_before": sorted(before), "labels_after": sorted(after_), "reason": "r", "confidence": "high"}

    def test_removing_a_mapped_legacy_label_is_allowed_only_with_the_mapping(self):
        before, after_ = ("bug", "status:inbox"), ("type:bug", "status:inbox")
        issue = S.issue(1, *before)
        self.assertEqual(self.check(self.prop(before, after_), issue), [])
        self.assertIn("remove-not-allowed", self.check(self.prop(before, after_), issue, DEFAULT))

    def test_a_kept_legacy_label_can_never_be_removed(self):
        before, after_ = ("epic", "type:epic", "status:inbox"), ("type:epic", "status:inbox")
        self.assertIn("remove-not-allowed", self.check(self.prop(before, after_), S.issue(1, *before)))

    def test_adding_ready_or_an_agent_executor_is_refused(self):
        before = ("type:chore", "status:inbox")
        issue = S.issue(1, *before)
        promoted = self.prop(before, ("type:chore", "status:ready", "exec:agent", "size:S"))
        self.assertEqual(T.validate(T.parse_proposals([promoted]), [issue], LIVE, MAPPED)[0].codes, [])  # triage alone accepts it
        self.assertEqual(self.check(promoted, issue), ["role-add-refused"])
        only_agent = self.prop(before, before + ("exec:agent",))
        self.assertEqual(self.check(only_agent, issue), ["role-add-refused"])

    def test_keeping_ready_is_not_adding_it(self):
        before = ("type:chore", "status:ready", "exec:agent", "size:S")
        after_ = before + ("priority:1-next",)
        self.assertEqual(self.check(self.prop(before, after_), S.issue(1, *before)), [])

    def test_the_code_is_reported_once_and_not_for_a_schema_error(self):
        before = ("type:chore", "status:inbox")
        results = K.validate_catchup(
            T.parse_proposals([{"issue": 1}, self.prop(before, ("type:chore", "status:ready", "exec:agent", "size:S"), 2)]),
            [S.issue(2, *before)], LIVE, MAPPED)
        codes = {r.proposal.issue: r.codes for r in results}
        self.assertEqual(codes[2], ["role-add-refused"])
        self.assertEqual(codes[1], ["bad-schema"])


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = S.tmpdir()
        self.tmp = Path(self._tmp.name)
        self.project = self.tmp / "repo"
        self.project.mkdir()
        S.write_repo_config(self.project, "acme/widgets", "propose", MAPPING)
        self.cfg = C.load_config(str(self.project))
        self.assertEqual(self.cfg.mode, "propose", self.cfg.reason)
        self.issues = self.tmp / "issues.json"
        self.issues.write_text(json.dumps([
            S.issue(1, "bug", "P0-now"),
            S.issue(2, "type:chore", "status:inbox"),                # already canonical
            S.issue(3, "enhancement", "P0-now", "P1-next"),           # priority conflict
            S.issue(4, "docs"),                                       # type-unmapped
            S.issue(5, "tech-debt", state="CLOSED"),                  # closed: ignored
        ]))
        self.labels = self.tmp / "labels.json"
        self.labels.write_text(json.dumps([{"name": n} for n in sorted(LIVE)]))

    def tearDown(self):
        self._tmp.cleanup()

    def call(self, argv, cfg=None, gh=None):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = K.main(argv, cfg or self.cfg, gh)
        return rc, buf.getvalue()


class TestPropose(Base):
    def test_propose_prints_unresolved_and_the_proposals(self):
        rc, out = self.call(["propose", "--issues-file", str(self.issues)])
        self.assertEqual(rc, 0, out)
        self.assertIn("[catch-up] unresolved #3: priority-conflict", out)
        self.assertIn("[catch-up] unresolved #4: type-unmapped", out)
        self.assertIn("[catch-up] proposed=1", out)
        self.assertIn("[catch-up] #1 (high): P0-now->priority:0-now; bug->type:bug; no status->status:inbox", out)
        self.assertNotIn("#2", out)
        self.assertNotIn("#5", out)

    def test_out_writes_one_new_local_file_outside_the_repo_and_never_overwrites(self):
        target = self.tmp / "out" / "proposals.json"
        rc, out = self.call(["propose", "--issues-file", str(self.issues), "--out", str(target)])
        self.assertEqual(rc, 0, out)
        self.assertEqual(oct(target.stat().st_mode & 0o777), "0o600")
        data = json.loads(target.read_text())
        self.assertEqual([e["issue"] for e in data], [1])
        self.assertEqual(data[0]["labels_after"], ["priority:0-now", "status:inbox", "type:bug"])
        first = target.read_bytes()
        rc, out = self.call(["propose", "--issues-file", str(self.issues), "--out", str(target)])
        self.assertEqual(rc, 1)
        self.assertIn("[catch-up] error:", out)
        self.assertEqual(target.read_bytes(), first)

    def test_out_inside_the_project_is_refused_and_nothing_is_written(self):
        target = self.project / "proposals.json"
        rc, out = self.call(["propose", "--issues-file", str(self.issues), "--out", str(target)])
        self.assertEqual(rc, 1)
        self.assertIn("OUTSIDE", out)
        self.assertFalse(target.exists())

    def test_the_proposals_round_trip_through_check(self):
        target = self.tmp / "p.json"
        self.assertEqual(self.call(["propose", "--issues-file", str(self.issues), "--out", str(target)])[0], 0)
        rc, out = self.call(["check", "--proposals", str(target), "--issues-file", str(self.issues), "--labels-file", str(self.labels), "--strict"])
        self.assertEqual(rc, 0, out)
        self.assertIn("proposals=1 accepted=1 rejected=0", out)

    def test_live_read_uses_the_open_issue_list_only(self):
        runner = S.FakeRunner(issues=json.loads(self.issues.read_text()))
        rc, _ = self.call(["propose"], gh=Gh(self.cfg, runner=runner))
        self.assertEqual((rc, runner.verbs()), (0, [("issue", "list")]))
        self.assertTrue(runner.calls[0][-2:] == ["-R", "acme/widgets"])


class TestCheck(Base):
    def proposals(self, entries):
        path = self.tmp / "proposals.json"
        path.write_text(json.dumps(entries))
        return path

    def check(self, entries, cfg=None, *extra):
        path = self.proposals(entries)
        return self.call(["check", "--proposals", str(path), "--issues-file", str(self.issues), "--labels-file", str(self.labels)] + list(extra), cfg)

    GOOD = {"issue": 1, "labels_before": ["P0-now", "bug"], "labels_after": ["priority:0-now", "status:inbox", "type:bug"], "reason": "map", "confidence": "high"}

    def test_a_good_proposal_prints_the_table_the_digest_and_writes_nothing(self):
        rc, out = self.check([self.GOOD])
        self.assertEqual(rc, 0, out)
        self.assertIn("[catch-up] open=4 proposals=1 accepted=1 rejected=0", out)
        self.assertIn("| #1 | P0-now, bug | priority:0-now, status:inbox, type:bug | map | high | ok |", out)
        digest = K.catchup_digest(T.parse_proposals([self.GOOD]), "acme/widgets")
        self.assertIn("[catch-up] table-digest: %s" % digest, out)
        self.assertTrue(out.rstrip().endswith("(--apply needs --snapshot-dir, --expect-sha and --confirm <table-digest>)"))

    def test_the_digest_is_bound_to_the_repo(self):
        proposals = T.parse_proposals([self.GOOD])
        a, b = K.catchup_digest(proposals, "acme/widgets"), K.catchup_digest(proposals, "acme/other")
        self.assertNotEqual(a, b)
        self.assertEqual(a, hashlib.sha256(("acme/widgets\n" + T.table_digest(proposals)).encode()).hexdigest()[:16])
        self.assertNotEqual(a, T.table_digest(proposals))
        other = load(MAPPING, "acme/other")
        self.assertIn("table-digest: %s" % b, self.check([self.GOOD], other)[1])

    def test_a_rejected_proposal_shows_its_codes_and_strict_exits_1(self):
        bad = dict(self.GOOD, labels_after=["priority:0-now", "status:ready", "exec:agent", "size:S", "type:bug"])
        rc, out = self.check([bad])
        self.assertEqual(rc, 0)
        self.assertIn("REJECT(", out)
        self.assertIn("role-add-refused", out)
        rc, _ = self.check([bad], None, "--strict")
        self.assertEqual(rc, 1)

    def test_control_characters_are_neutralized_in_the_table_but_not_in_the_digest(self):
        evil = dict(self.GOOD, reason="see \x1b[31mred\x1b[0m\rnow")
        rc, out = self.check([evil])
        self.assertEqual(rc, 0)
        self.assertNotIn("\x1b", out)
        self.assertNotIn("\r", out)
        self.assertIn("see ?[31mred?[0m?now", out)
        self.assertIn("table-digest: %s" % K.catchup_digest(T.parse_proposals([evil]), "acme/widgets"), out)

    def test_live_read_fetches_the_open_issues_and_the_labels(self):
        runner = S.FakeRunner(issues=json.loads(self.issues.read_text()), labels=sorted(LIVE))
        path = self.proposals([self.GOOD])
        rc, out = self.call(["check", "--proposals", str(path)], gh=Gh(self.cfg, runner=runner))
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.verbs(), [("issue", "list"), ("label", "list")])

    def test_unreadable_input_is_an_error(self):
        rc, out = self.call(["check", "--proposals", str(self.tmp / "missing.json"), "--issues-file", str(self.issues), "--labels-file", str(self.labels)])
        self.assertEqual(rc, 1)
        self.assertIn("[catch-up] error:", out)


class TestNoWritePath(Base):
    def test_propose_has_no_apply_flags_check_has_them_and_no_batch_flag_exists(self):
        apply_flags = (["--apply"], ["--confirm", "x"], ["--snapshot-dir", "d"], ["--expect-sha", "x"])
        for flag in apply_flags:
            with self.subTest(sub="propose", flag=flag), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    K.build_parser().parse_args(["propose"] + flag)
                self.assertEqual(raised.exception.code, 2)
            with self.subTest(sub="check", flag=flag):
                K.build_parser().parse_args(["check", "--proposals", "p.json"] + flag)
        for base in (["propose"], ["check", "--proposals", "p.json"]):
            with self.subTest(base=base), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    K.build_parser().parse_args(base + ["--batch-size", "5"])
                self.assertEqual(raised.exception.code, 2)

    def test_the_repo_flag_is_an_assertion(self):
        rc, out = self.call(["propose", "--issues-file", str(self.issues), "--repo", "acme/other"])
        self.assertEqual(rc, 1)
        self.assertIn("does not match", out)
        self.assertEqual(self.call(["propose", "--issues-file", str(self.issues), "--repo", "acme/widgets"])[0], 0)


if __name__ == "__main__":
    unittest.main()
