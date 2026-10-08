"""The shape of the write surface: one class writes, one module builds it, nothing that an agent reads calls it."""

import ast
import re
import unittest

import _support
import backlog_config
import backlog_gh


def construction_sites(name):
    """Files of `scripts/` that CALL `name(...)` (an AST oracle, immune to comments and docstrings)."""
    sites = []
    for path in sorted(_support.SCRIPTS.glob("*.py")):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", "")) == name:
                sites.append(path.name)
    return sorted(set(sites))


def files_matching(pattern):
    return [p.name for p in sorted(_support.SCRIPTS.glob("*.py")) if re.search(pattern, p.read_text(encoding="utf-8"), re.I)]


class TestOneWriteSurface(unittest.TestCase):
    def test_apply_gh_and_apply_grant_are_constructed_only_by_the_applier(self):
        self.assertEqual(construction_sites("ApplyGh"), ["backlog_apply.py"])
        self.assertEqual(construction_sites("ApplyGrant"), ["backlog_apply.py"])

    def test_the_oracle_can_find_a_construction(self):
        tree = ast.parse("g = ApplyGh(cfg, grant)\nx = mod.ApplyGrant(a)\n")
        names = {getattr(n.func, "id", getattr(n.func, "attr", "")) for n in ast.walk(tree) if isinstance(n, ast.Call)}
        self.assertEqual(names, {"ApplyGh", "ApplyGrant"})

    def test_the_write_verbs_live_in_the_chokepoint_and_the_guard_only(self):
        self.assertEqual(files_matching(r"issue edit|add-label|remove-label"), ["backlog_gh.py", "backlog_guard.py"])

    def test_only_the_chokepoint_spawns_a_process(self):
        self.assertEqual(files_matching(r"subprocess"), ["backlog_gh.py"])

    def test_gh_write_allow_is_unchanged(self):
        self.assertEqual(backlog_gh.WRITE_ALLOW, frozenset({("issue", "create")}))

    def test_the_write_path_never_reads_the_free_text_of_an_issue(self):
        # Only these modules name an issue's free text (`body`): the config (a reserved word list), the intake that
        # WRITES a new issue, the read chokepoint (`fetch_issue(with_body=)` and the PR field list), the promotion
        # check (the one reader of one issue's text) and the queue reader. The applier, the single-issue `set`,
        # catch-up, triage, snapshot and label-sync never name it.
        self.assertEqual(
            files_matching(r"\bbody\b"),
            ["backlog_config.py", "backlog_file.py", "backlog_gh.py", "backlog_promote.py", "next_item.py"],
        )

    def test_the_single_issue_set_reaches_the_write_chokepoint_only_through_the_applier(self):
        self.assertEqual(construction_sites("ApplyGh"), ["backlog_apply.py"])
        self.assertEqual(construction_sites("ApplyGrant"), ["backlog_apply.py"])
        self.assertEqual(files_matching(r"\bApplyGh\b|\bApplyGrant\b"), ["backlog_apply.py", "backlog_gh.py"])

    def test_the_applier_names_no_label_edit_delete_or_rename_verb(self):
        source = (_support.SCRIPTS / "backlog_gh.py").read_text(encoding="utf-8")
        for forbidden in ('"delete"', '("label", "edit")', '"rename"', "--force", "--web"):
            self.assertNotIn(forbidden, source)


class TestNoSkillNamesTheApplier(unittest.TestCase):
    """D-A.3: promotion of the write path is a human/Lead act; no skill (which an agent follows) can reach it."""

    def skills(self):
        found = sorted((_support.PLUGIN_ROOT / "skills").glob("*/SKILL.md"))
        self.assertGreaterEqual(len(found), 3)  # the glob really enumerates the skills
        return found

    def test_no_skill_mentions_the_catchup_tooling_or_the_applier(self):
        pattern = re.compile(r"label-sync|rollback|catchup|snapshot|backlog_apply|ApplyGh|ApplyGrant", re.I)
        for path in self.skills():
            with self.subTest(skill=path.parent.name):
                self.assertIsNone(pattern.search(path.read_text(encoding="utf-8")))

    def test_no_skill_names_the_single_issue_set_or_the_promotion(self):
        pattern = re.compile(r"backlog_set|backlog_promote|backlog_cli\.py\s+set|promotion", re.I)
        for path in self.skills():
            with self.subTest(skill=path.parent.name):
                self.assertIsNone(pattern.search(path.read_text(encoding="utf-8")))

    def test_apply_appears_only_in_the_file_skill(self):
        with_apply = [p.parent.name for p in self.skills() if "--apply" in p.read_text(encoding="utf-8")]
        self.assertEqual(with_apply, ["file"])

    def test_the_detector_can_fail(self):
        self.assertIsNotNone(re.search(r"label-sync|rollback", "run backlog_cli.py label-sync --apply"))


class TestModeIsACeilingInTheConfig(unittest.TestCase):
    def test_no_config_key_can_switch_the_write_path_on(self):
        self.assertNotIn("apply", backlog_config.TOP_KEYS)
        self.assertNotIn("confirm", backlog_config.TOP_KEYS)


if __name__ == "__main__":
    unittest.main()
