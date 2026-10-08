import importlib.util
import unittest

import _support
import backlog_config


def load(text):
    with _support.tmpdir() as tmp:
        _support.write_config(tmp, text)
        return backlog_config.load_config(tmp)


class TestConfigDefaults(unittest.TestCase):
    def test_missing_file_is_mode_off(self):
        with _support.tmpdir() as tmp:
            cfg = backlog_config.load_config(tmp)
        self.assertEqual(cfg.mode, "off")
        self.assertIsNone(cfg.source)
        self.assertIn("no .claude/backlog.yml", cfg.reason)

    def test_missing_mode_defaults_to_off(self):
        cfg = load("contract: 1\n")
        self.assertEqual(cfg.mode, "off")
        self.assertIn("mode", cfg.reason)

    def test_missing_contract_defaults_to_off(self):
        cfg = load("mode: free\n")
        self.assertEqual(cfg.mode, "off")
        self.assertIn("contract", cfg.reason)

    def test_wrong_contract_defaults_to_off(self):
        self.assertEqual(load("contract: 2\nmode: free\n").mode, "off")

    def test_invalid_mode_defaults_to_off(self):
        cfg = load("contract: 1\nmode: yolo\n")
        self.assertEqual(cfg.mode, "off")
        self.assertIn("invalid mode", cfg.reason)

    def test_unknown_key_defaults_to_off(self):
        cfg = load("contract: 1\nmode: free\nbogus: 1\n")
        self.assertEqual(cfg.mode, "off")
        self.assertIn("unknown key", cfg.reason)

    def test_cadence_key_rejected_as_reserved(self):
        for body in ("cadence: [weekly]\n", "cadence:\n  cycle: 2\n", "cadence: on\n"):
            with self.subTest(body=body):
                cfg = load("contract: 1\nmode: free\n" + body)
                self.assertEqual(cfg.mode, "off")
                self.assertIn("reserved", cfg.reason)

    def test_empty_cadence_key_is_tolerated(self):
        self.assertEqual(load("contract: 1\nmode: propose\ncadence:\n").mode, "propose")

    def test_reserved_status_values_rejected(self):
        for value in ("in-review", "done"):
            with self.subTest(value=value):
                cfg = load("contract: 1\nmode: free\nlabels:\n  status: [inbox, needs-info, ready, %s]\n" % value)
                self.assertEqual(cfg.mode, "off")
                self.assertIn("reserved", cfg.reason)

    def test_valid_minimal_file_gets_reference_defaults(self):
        cfg = load("contract: 1\nmode: write-supervised\n")
        self.assertEqual(cfg.mode, "write-supervised")
        self.assertEqual(cfg.labels["size"], ("S", "M", "L"))
        self.assertEqual(cfg.caps, {"priority:0-now": 2, "priority:1-next": 8})
        self.assertEqual(cfg.exclusions, ("cross-repo", "money-path"))
        self.assertEqual(cfg.role_label("ready"), "status:ready")
        self.assertEqual(cfg.role_labels("agent"), ("exec:agent",))

    def test_mode_off_in_file_is_off(self):
        self.assertEqual(load("contract: 1\nmode: off\n").mode, "off")

    def test_overrides_replace_defaults(self):
        cfg = load(
            "contract: 1\nmode: propose\nrepo: acme/widgets\n"
            "labels:\n  size: [XS, S, M, L]\n  area: [web]\n"
            "roles:\n  split: [L]\n  candidate_sizes: [XS, S]\n"
            "exclusions: [epic]\nexecutor_flags: []\ncaps:\n  \"priority:0-now\": 1\n"
        )
        self.assertEqual(cfg.mode, "propose")
        self.assertEqual(cfg.repo, "acme/widgets")
        self.assertEqual(cfg.labels["size"], ("XS", "S", "M", "L"))
        self.assertEqual(cfg.exclusions, ("epic",))
        self.assertEqual(cfg.executor_flags, ())
        self.assertEqual(cfg.caps, {"priority:0-now": 1})
        self.assertEqual(cfg.owned_namespaces().count("area:"), 0)
        self.assertNotIn("area:", cfg.free_namespaces())

    def test_invalid_values_default_to_off(self):
        bad = {
            "repo": "contract: 1\nmode: free\nrepo: not a repo\n",
            "axis": "contract: 1\nmode: free\nlabels:\n  colour: [red]\n",
            "role-not-in-axis": "contract: 1\nmode: free\nroles:\n  ready: shipped\n",
            "cap-unknown-label": "contract: 1\nmode: free\ncaps:\n  \"priority:9-x\": 1\n",
            "cap-negative": "contract: 1\nmode: free\ncaps:\n  \"priority:0-now\": -1\n",
            "unknown-role": "contract: 1\nmode: free\nroles:\n  boss: x\n",
            "exec-gating": "contract: 1\nmode: free\nexec_gating: yolo\n",
            "intake-required-not-an-axis": "contract: 1\nmode: free\nintake_required: [type, bogus]\n",
            "intake-required-not-a-list": "contract: 1\nmode: free\nintake_required: type\n",
            "guard-issue-create": "contract: 1\nmode: free\nguard_issue_create: maybe\n",
        }
        for name, text in bad.items():
            with self.subTest(name=name):
                self.assertEqual(load(text).mode, "off")

    def test_exec_gating_defaults_to_promotion(self):
        self.assertEqual(load("contract: 1\nmode: free\n").exec_gating, "promotion")

    def test_exec_gating_triage_is_accepted(self):
        self.assertEqual(load("contract: 1\nmode: free\nexec_gating: triage\n").exec_gating, "triage")

    def test_intake_required_defaults_to_type_only(self):
        self.assertEqual(load("contract: 1\nmode: free\n").intake_required, ("type",))

    def test_intake_required_accepts_several_axes(self):
        cfg = load("contract: 1\nmode: free\nintake_required: [type, priority]\n")
        self.assertEqual(cfg.intake_required, ("type", "priority"))

    def test_intake_required_rejects_duplicates(self):
        self.assertEqual(load("contract: 1\nmode: free\nintake_required: [type, type]\n").mode, "off")

    def test_guard_issue_create_defaults_to_true(self):
        self.assertIs(load("contract: 1\nmode: free\n").guard_issue_create, True)

    def test_guard_issue_create_accepts_false(self):
        self.assertIs(load("contract: 1\nmode: free\nguard_issue_create: false\n").guard_issue_create, False)

    def test_new_additive_keys_reproduce_todays_behaviour_by_default(self):
        # every default (exec_gating: promotion, guard_issue_create: true, intake_required: [type]) matches the
        # pre-0.4.0 fixed behaviour byte for byte
        default = backlog_config.default_config("write-supervised", "acme/widgets")
        cfg = load("contract: 1\nmode: write-supervised\nrepo: acme/widgets\n")
        self.assertEqual(cfg.exec_gating, default.exec_gating)
        self.assertEqual(cfg.intake_required, default.intake_required)
        self.assertEqual(cfg.guard_issue_create, default.guard_issue_create)
        self.assertEqual((cfg.exec_gating, cfg.intake_required, cfg.guard_issue_create), ("promotion", ("type",), True))

    def test_unparsable_file_is_off_not_an_exception(self):
        cfg = load("contract: 1\nmode: free\n\tlabels:\n")
        self.assertEqual(cfg.mode, "off")
        self.assertIn("invalid config", cfg.reason)

    def test_project_dir_resolution_prefers_override(self):
        self.assertEqual(backlog_config.resolve_project_dir("/x/y"), "/x/y")


class TestParser(unittest.TestCase):
    def test_parser_rejects_anchors_tabs_block_lists(self):
        bad = {
            "anchor": "a: &x 1\n",
            "alias": "a: *x\n",
            "tab": "a:\n\tb: 1\n",
            "block-list": "a:\n  - one\n  - two\n",
            "flow-map": "a: {b: 1}\n",
            "tag": "a: !!str 1\n",
            "duplicate": "a: 1\na: 2\n",
            "duplicate-nested": "a:\n  b: 1\n  b: 2\n",
            "depth-3": "a:\n  b:\n    c: 1\n",
            "odd-indent": "a:\n   b: 1\n",
            "orphan-indent": "a: 1\n  b: 2\n",
            "doc-marker": "---\na: 1\n",
            "unterminated-list": "a: [x, y\n",
            "unterminated-quote": "a: \"x\n",
            "no-colon": "just words\n",
        }
        for name, text in bad.items():
            with self.subTest(name=name):
                with self.assertRaises(backlog_config.ConfigError):
                    backlog_config.parse_simple_yaml(text)

    def test_parser_accepts_the_subset(self):
        data = backlog_config.parse_simple_yaml(
            "# comment\n\nname: value  # trailing\nn: 12\nq: \"a: b # not a comment\"\nl: [a, 'b, c', 3]\nempty: []\n"
            "blk:\n  k: v\n  \"quoted:key\": 5\n  li: [x]\n"
        )
        self.assertEqual(
            data,
            {"name": "value", "n": 12, "q": "a: b # not a comment", "l": ["a", "b, c", 3], "empty": [],
             "blk": {"k": "v", "quoted:key": 5, "li": ["x"]}},
        )


class TestTemplate(unittest.TestCase):
    TEMPLATE = _support.PLUGIN_ROOT / "templates" / "backlog.template.yml"

    def test_template_matches_defaults(self):
        raw = backlog_config.parse_simple_yaml(self.TEMPLATE.read_text(encoding="utf-8"))
        expected = {
            "contract": 1,
            "mode": "propose",
            "labels": backlog_config.DEFAULT_LABELS,
            "roles": backlog_config.DEFAULT_ROLES,
            "executor_flags": backlog_config.DEFAULT_EXECUTOR_FLAGS,
            "exclusions": backlog_config.DEFAULT_EXCLUSIONS,
            "protected": backlog_config.DEFAULT_PROTECTED,
            "caps": backlog_config.DEFAULT_CAPS,
        }
        self.assertEqual(raw, expected)
        with _support.tmpdir() as tmp:
            _support.write_config(tmp, self.TEMPLATE.read_text(encoding="utf-8"))
            cfg = backlog_config.load_config(tmp)
        self.assertEqual(cfg.mode, "propose")
        default = backlog_config.default_config("propose")
        for attr in ("labels", "roles", "executor_flags", "exclusions", "protected", "caps"):
            self.assertEqual(getattr(cfg, attr), getattr(default, attr), attr)

    def test_template_ships_propose_explicitly(self):
        self.assertIn("mode: propose", self.TEMPLATE.read_text(encoding="utf-8"))

    @unittest.skipUnless(importlib.util.find_spec("yaml"), "PyYAML not installed")
    def test_parser_agrees_with_pyyaml_on_template(self):
        import yaml

        text = self.TEMPLATE.read_text(encoding="utf-8")
        self.assertEqual(backlog_config.parse_simple_yaml(text), yaml.safe_load(text))


if __name__ == "__main__":
    unittest.main()
