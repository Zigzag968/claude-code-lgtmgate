"""The deterministic promotion check: the checkbox counter and the verdict (pure, no gh, no I/O)."""

import dataclasses
import unittest

import _support as S
import backlog_config as C
import backlog_promote as P

BODY = "## Acceptance\n- [ ] the thing works\n- [x] and is tested\n"
AFTER = frozenset({"type:feature", "status:ready", "exec:agent", "size:S"})


def cfg(promotion="checked"):
    return C.replace(C.default_config("write-supervised", "acme/widgets"), promotion=promotion)


def live(*labels, body=BODY, blockers=(), number=7):
    return S.issue(number, *(labels or ("type:feature", "status:inbox", "size:S")), blockers=list(blockers), body=body)


class TestCheckboxCounter(unittest.TestCase):
    def test_counts_the_usual_list_markers(self):
        text = "\n".join(
            [
                "- [ ] dash",
                "- [x] done",
                "- [X] done upper",
                "* [ ] star",
                "+ [ ] plus",
                "1. [ ] numbered",
                "12) [x] paren",
                "    - [ ] indented",
                "\t- [ ] tabbed",
            ]
        )
        self.assertEqual(P.count_checkboxes(text), 9)

    def test_does_not_count_lookalikes(self):
        text = "\n".join(
            [
                "[ ] no list marker",
                "- [] no space in the box",
                "-[ ] no space after the marker",
                "- [y] not a box value",
                "- [ ]",
                "- [ ]    ",
                "- [ ]x no space after the box",
                "text - [ ] not at the start of the line",
                "-- [ ] two markers",
                "1234. [ ] too many digits",
            ]
        )
        self.assertEqual(P.count_checkboxes(text), 0)

    def test_ignores_backtick_fences(self):
        self.assertEqual(P.count_checkboxes("```\n- [ ] in code\n```\n"), 0)
        self.assertEqual(P.count_checkboxes("   ```md\n- [ ] in code\n   ```\n- [ ] real\n"), 1)

    def test_ignores_tilde_fences(self):
        self.assertEqual(P.count_checkboxes("~~~\n- [ ] in code\n~~~\n"), 0)

    def test_a_fence_is_closed_by_its_own_marker_only(self):
        self.assertEqual(P.count_checkboxes("~~~\n```\n- [ ] still code\n```\n~~~\n- [ ] real\n"), 1)

    def test_an_unclosed_fence_hides_the_rest(self):
        self.assertEqual(P.count_checkboxes("- [ ] before\n```\n- [ ] after\n- [ ] after too\n"), 1)

    def test_ignores_html_comments(self):
        self.assertEqual(P.count_checkboxes("<!-- - [ ] hidden -->\n- [ ] real\n"), 1)
        self.assertEqual(P.count_checkboxes("<!--\n- [ ] hidden\n- [ ] hidden\n-->\n"), 0)

    def test_an_unterminated_comment_hides_the_rest(self):
        self.assertEqual(P.count_checkboxes("- [ ] before\n<!-- never closed\n- [ ] after\n"), 1)

    def test_counts_after_a_closed_comment_and_a_closed_fence(self):
        text = "<!-- c -->\n```\n- [ ] code\n```\n- [ ] one\n<!-- d -->\n- [x] two\n"
        self.assertEqual(P.count_checkboxes(text), 2)

    def test_crlf_lines_count(self):
        self.assertEqual(P.count_checkboxes("- [ ] a\r\n- [x] b\r\n"), 2)

    def test_a_missing_or_non_text_value_is_zero(self):
        for value in (None, 5, ["- [ ] x"], {"a": 1}, b"- [ ] x"):
            with self.subTest(value=value):
                self.assertEqual(P.count_checkboxes(value), 0)

    def test_only_the_first_max_body_characters_are_read(self):
        cut = "x" * (P.MAX_BODY - 2) + "\n"  # two characters left: a box cannot even start
        self.assertEqual(P.count_checkboxes(cut + "- [ ] beyond the limit\n"), 0)
        self.assertEqual(P.count_checkboxes("- [ ] first\n" + "x" * P.MAX_BODY + "\n- [ ] beyond\n"), 1)

    def test_a_pathological_text_returns(self):
        for chunk in ("- [", "<!--", "```\n", "- [ ] ", "\t", "~~~ ", "1) [x] "):
            with self.subTest(chunk=chunk):
                self.assertIsInstance(P.count_checkboxes(chunk * 60000), int)


class TestVerdict(unittest.TestCase):
    def verdict(self, issue=None, after=AFTER, config=None):
        return P.check_promotion(issue or live(), after, config or cfg())

    def test_the_baseline_is_ok(self):
        verdict = self.verdict()
        self.assertTrue(verdict.ok, verdict.codes)
        self.assertEqual(verdict.codes, ())
        self.assertEqual(verdict.issue, 7)
        self.assertEqual(verdict.facts, {"checkboxes": 2, "size": "size:S", "type": "type:feature", "blockers": 0})

    def test_promotion_off_is_a_code_of_its_own(self):
        self.assertEqual(self.verdict(config=cfg("none")).codes, ("promotion-off",))

    def test_no_acceptance(self):
        for body in ("", None, "no boxes here", "```\n- [ ] x\n```\n", "<!-- - [ ] x -->", "- [ ]\n"):
            with self.subTest(body=body):
                self.assertEqual(self.verdict(live(body=body)).codes, ("no-acceptance",))

    def test_size_not_candidate_for_a_split_size_and_for_no_size(self):
        self.assertEqual(self.verdict(after=(AFTER - {"size:S"}) | {"size:L"}).codes, ("size-not-candidate",))
        self.assertEqual(self.verdict(after=AFTER - {"size:S"}).codes, ("size-not-candidate",))
        self.assertTrue(self.verdict(after=(AFTER - {"size:S"}) | {"size:M"}).ok)

    def test_no_type_and_epic(self):
        self.assertEqual(self.verdict(after=AFTER - {"type:feature"}).codes, ("no-type",))
        self.assertEqual(self.verdict(after=(AFTER - {"type:feature"}) | {"type:epic"}).codes, ("no-type",))

    def test_exclusion_labels(self):
        for label in ("cross-repo", "money-path"):
            with self.subTest(label=label):
                codes = self.verdict(live("type:feature", "status:inbox", "size:S", label)).codes
                self.assertIn("exclusion:%s" % label, codes)

    def test_an_open_blocker_blocks_and_a_closed_one_does_not(self):
        opened = self.verdict(live(blockers=[{"number": 9, "state": "OPEN"}, {"number": 10, "state": "CLOSED"}]))
        self.assertEqual(opened.codes, ("open-blocker:9",))
        self.assertEqual(opened.facts["blockers"], 1)
        self.assertTrue(self.verdict(live(blockers=[{"number": 10, "state": "CLOSED"}])).ok)

    def test_blockers_unknown_fails_closed(self):
        base = live()
        without = {k: v for k, v in base.items() if k != "blockedBy"}
        cases = {
            "missing key": without,
            "not a dict": dict(base, blockedBy=[]),
            "truncated nodes": dict(base, blockedBy={"nodes": [{"number": 9, "state": "CLOSED"}], "totalCount": 2}),
            "no total": dict(base, blockedBy={"nodes": []}),
            "no nodes": dict(base, blockedBy={"totalCount": 0}),
            "boolean total": dict(base, blockedBy={"nodes": [], "totalCount": True}),
            "node without number": dict(base, blockedBy={"nodes": [{"state": "OPEN"}], "totalCount": 1}),
        }
        for name, issue in cases.items():
            with self.subTest(case=name):
                self.assertEqual(self.verdict(issue).codes, ("blockers-unknown",))

    def test_a_founder_issue_is_never_converted(self):
        codes = self.verdict(live("type:feature", "status:inbox", "size:S", "exec:founder")).codes
        self.assertEqual(codes, ("founder-executor",))

    def test_protected_labels_present_block(self):
        for label in ("auto:blocked", "nightly"):
            with self.subTest(label=label):
                codes = self.verdict(live("type:feature", "status:inbox", "size:S", label)).codes
                self.assertEqual(codes, ("protected-present:%s" % label,))

    def test_every_miss_is_listed_never_short_circuited(self):
        issue = live("type:feature", "status:inbox", "size:S", "cross-repo", body="", blockers=[{"number": 9, "state": "OPEN"}])
        codes = self.verdict(issue, after=frozenset({"status:ready", "exec:agent"}), config=cfg("none")).codes
        self.assertEqual(
            sorted(codes),
            sorted(
                [
                    "promotion-off",
                    "no-acceptance",
                    "size-not-candidate",
                    "no-type",
                    "exclusion:cross-repo",
                    "open-blocker:9",
                    "protected-present:cross-repo",
                ]
            ),
        )

    def test_the_verdict_is_frozen_and_carries_no_text(self):
        verdict = self.verdict(live(body="SECRET - [ ] x"))
        with self.assertRaises(dataclasses.FrozenInstanceError):
            verdict.ok = False
        self.assertNotIn("SECRET", repr(verdict))

    def test_wants_and_is_promotion(self):
        config = cfg()
        self.assertTrue(P.wants_promotion(["status:ready"], config))
        self.assertTrue(P.wants_promotion(["size:S", "exec:agent"], config))
        self.assertFalse(P.wants_promotion(["status:needs-info", "exec:founder", "size:M"], config))
        self.assertTrue(P.is_promotion({"status:inbox"}, {"status:ready"}, config))
        self.assertFalse(P.is_promotion({"status:ready"}, {"status:ready", "size:S"}, config))
        self.assertFalse(P.is_promotion({"status:ready"}, {"status:inbox"}, config))


class TestExecGating(unittest.TestCase):
    """`exec_gating` (default `promotion`, opt-in `triage`): whether an agent-executor add is reserved."""

    def test_promotion_gating_reserves_ready_and_agent(self):
        self.assertEqual(P.reserved_adds(cfg()), frozenset({"status:ready", "exec:agent"}))

    def test_triage_gating_reserves_only_ready(self):
        config = C.replace(cfg(), exec_gating="triage")
        self.assertEqual(P.reserved_adds(config), frozenset({"status:ready"}))

    def test_triage_gating_makes_an_agent_only_add_non_promoting(self):
        config = C.replace(cfg(), exec_gating="triage")
        self.assertFalse(P.is_promotion({"status:inbox"}, {"status:inbox", "exec:agent"}, config))
        self.assertTrue(P.is_promotion({"status:inbox"}, {"status:ready"}, config))

    def test_promotion_gating_is_unchanged_from_today(self):
        config = cfg()
        self.assertTrue(P.is_promotion({"status:inbox"}, {"status:inbox", "exec:agent"}, config))


class TestEffectivePromotion(unittest.TestCase):
    """The bootstrap carve-out of `set` (fixes #259): a labelless issue's first `set --apply` that picks up an
    agent executor without requesting `status:ready` is a triage bootstrap, not a readiness promotion."""

    def test_bootstrap_carve_out_a_labelless_issue_adding_exec_agent_without_ready(self):
        after = {"type:feature", "status:inbox", "size:S", "exec:agent"}
        self.assertFalse(P.effective_promotion(frozenset(), after, cfg()))

    def test_the_carve_out_does_not_apply_once_ready_is_requested_too(self):
        after = {"type:feature", "status:ready", "size:S", "exec:agent"}
        self.assertTrue(P.effective_promotion(frozenset(), after, cfg()))

    def test_the_carve_out_does_not_apply_to_a_non_empty_before(self):
        self.assertTrue(P.effective_promotion({"status:inbox"}, {"status:inbox", "exec:agent"}, cfg()))

    def test_under_triage_gating_only_a_ready_request_is_ever_a_promotion(self):
        config = C.replace(cfg(), exec_gating="triage")
        after = {"type:feature", "status:inbox", "size:S", "exec:agent"}
        self.assertFalse(P.effective_promotion(frozenset(), after, config))
        self.assertTrue(P.effective_promotion(frozenset(), {"status:ready"}, config))


if __name__ == "__main__":
    unittest.main()
