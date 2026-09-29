"""The additive contract-1 keys of the catch-up tooling: legacy_map, legacy_keep, label_colors, apply_prompt, promotion."""

import unittest

import _support as S
import backlog_config as C

BASE = "contract: 1\nmode: propose\n"


def load(extra):
    with S.tmpdir() as tmp:
        S.write_config(tmp, BASE + extra)
        return C.load_config(tmp)


class TestCatchupKeys(unittest.TestCase):
    def test_absent_keys_default_to_nothing_mapped_and_grey(self):
        cfg = load("")
        self.assertEqual(cfg.mode, "propose")
        self.assertEqual(cfg.legacy_map, {})
        self.assertEqual(cfg.legacy_keep, ())
        self.assertEqual(cfg.label_colors, {})
        self.assertEqual(cfg.label_color("type"), C.DEFAULT_LABEL_COLOR)

    def test_empty_blocks_are_accepted(self):
        cfg = load("legacy_map:\nlabel_colors:\n")
        self.assertEqual((cfg.mode, cfg.legacy_map, cfg.label_colors), ("propose", {}, {}))

    def test_apply_prompt_defaults_to_none_and_accepts_none_or_ask(self):
        self.assertEqual(load("").apply_prompt, "none")
        self.assertEqual(load("apply_prompt:\n").apply_prompt, "none")
        self.assertEqual(load("apply_prompt: none\n").apply_prompt, "none")
        cfg = load("apply_prompt: ask\n")
        self.assertEqual((cfg.mode, cfg.apply_prompt), ("propose", "ask"), cfg.reason)

    def test_promotion_defaults_to_none_and_accepts_none_or_checked(self):
        self.assertEqual(load("").promotion, "none")
        self.assertEqual(load("promotion:\n").promotion, "none")
        self.assertEqual(load("promotion: none\n").promotion, "none")
        cfg = load("promotion: checked\n")
        self.assertEqual((cfg.mode, cfg.promotion), ("propose", "checked"), cfg.reason)
        self.assertEqual(C.default_config("propose").promotion, "none")

    def test_promotion_is_an_additive_key_of_contract_1(self):
        self.assertEqual(C.CONTRACT, 1)
        self.assertIn("promotion", C.TOP_KEYS)
        self.assertEqual(C.PROMOTIONS, ("none", "checked"))

    def test_promotion_does_not_change_the_reserved_legacy_targets(self):
        cfg = load("promotion: checked\nlegacy_map:\n  wip: status:ready\n")
        self.assertEqual(cfg.mode, "off")  # a legacy label still never maps onto the ready status

    def test_a_valid_mapping_is_loaded(self):
        cfg = load(
            "legacy_map:\n  bug: type:bug\n  P0-now: priority:0-now\n  triage:interactive: exec:founder\n"
            "legacy_keep: [triage:interactive]\n"
            'label_colors:\n  type: "D73A4A"\n  status: 0e8a16\n'
        )
        self.assertEqual(cfg.mode, "propose", cfg.reason)
        self.assertEqual(cfg.legacy_map, {"bug": "type:bug", "P0-now": "priority:0-now", "triage:interactive": "exec:founder"})
        self.assertEqual(cfg.legacy_keep, ("triage:interactive",))
        self.assertEqual(cfg.label_color("type"), "d73a4a")  # normalized to lowercase
        self.assertEqual(cfg.label_color("status"), "0e8a16")
        self.assertEqual(cfg.label_color("size"), C.DEFAULT_LABEL_COLOR)

    def test_a_quoted_all_digit_color_is_accepted_and_an_unquoted_one_is_refused(self):
        self.assertEqual(load('label_colors:\n  type: "123456"\n').label_color("type"), "123456")
        cfg = load("label_colors:\n  type: 123456\n")
        self.assertEqual(cfg.mode, "off")
        self.assertIn("quote all-digit colors", cfg.reason)

    def test_every_invalid_value_resolves_to_mode_off(self):
        cases = {
            "target-not-in-labels": "legacy_map:\n  bug: type:nope\n",
            "target-not-axis-value": "legacy_map:\n  bug: bug\n",
            "legacy-key-is-an-axis-label": "legacy_map:\n  type:bug: type:feature\n",
            "legacy-key-protected-exact": "legacy_map:\n  nightly: type:bug\n",
            "legacy-key-protected-prefix": "legacy_map:\n  auto:x: type:bug\n",
            "legacy-key-exclusion": "legacy_map:\n  cross-repo: type:bug\n",
            "promotion-to-ready": "legacy_map:\n  approved: status:ready\n",
            "promotion-to-agent": "legacy_map:\n  robot: exec:agent\n",
            "keep-not-a-key": "legacy_map:\n  bug: type:bug\nlegacy_keep: [enhancement]\n",
            "keep-without-map": "legacy_keep: [bug]\n",
            "unknown-color-axis": 'label_colors:\n  colour: "aabbcc"\n',
            "short-color": 'label_colors:\n  type: "abc"\n',
            "hash-color": 'label_colors:\n  type: "#aabbcc"\n',
            "non-hex-color": 'label_colors:\n  type: "gggggg"\n',
            "map-not-a-block": "legacy_map: [a]\n",
            "colors-not-a-block": "label_colors: aabbcc\n",
            "apply-prompt-unknown-value": "apply_prompt: maybe\n",
            "apply-prompt-boolean-like": "apply_prompt: true\n",
            "promotion-unknown-value": "promotion: maybe\n",
            "promotion-boolean-like": "promotion: true\n",
            "promotion-on": "promotion: on\n",
            "promotion-list": "promotion: [checked]\n",
        }
        for name, extra in cases.items():
            with self.subTest(case=name):
                cfg = load(extra)
                self.assertEqual(cfg.mode, "off", extra)
                self.assertTrue(cfg.reason.startswith("invalid config"), cfg.reason)

    def test_custom_taxonomy_targets_and_roles_are_honoured(self):
        cfg = load(
            "labels:\n  status: [new, triaged, go]\n  type: [bug, story]\n"
            "roles:\n  intake: new\n  waiting: triaged\n  ready: go\n  epic: story\n  bug: bug\n"
            "legacy_map:\n  wip: status:triaged\n  approved: status:go\n"
        )
        self.assertEqual(cfg.mode, "off")  # `status:go` is this config's ready role
        self.assertIn("human triage decision", cfg.reason)
        cfg = load(
            "labels:\n  status: [new, triaged, go]\n  type: [bug, story]\n"
            "roles:\n  intake: new\n  waiting: triaged\n  ready: go\n  epic: story\n  bug: bug\n"
            "legacy_map:\n  wip: status:triaged\n"
        )
        self.assertEqual(cfg.mode, "propose", cfg.reason)

    def test_the_contract_is_unchanged_and_the_new_keys_are_known(self):
        self.assertEqual(C.CONTRACT, 1)
        for key in ("legacy_map", "legacy_keep", "label_colors"):
            self.assertIn(key, C.TOP_KEYS)

    def test_default_config_still_matches_the_template(self):
        cfg = C.default_config("propose", "acme/widgets")
        self.assertEqual((cfg.repo, cfg.legacy_map, cfg.legacy_keep), ("acme/widgets", {}, ()))


if __name__ == "__main__":
    unittest.main()
