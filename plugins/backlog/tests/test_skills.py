import json
import re
import unittest

import _support as S

SKILLS_DIR = S.PLUGIN_ROOT / "skills"
README = S.PLUGIN_ROOT / "README.md"
MAX_DESCRIPTION = 90
EXPECTED = ("file", "next", "triage")


def frontmatter(path):
    text = path.read_text(encoding="utf-8")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    assert match, "%s has no frontmatter" % path
    fields = {}
    for line in match.group(1).splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def skills():
    return {p.parent.name: frontmatter(p) for p in sorted(SKILLS_DIR.glob("*/SKILL.md"))}


class TestSkills(unittest.TestCase):
    def test_the_three_skills_exist_with_matching_names(self):
        found = skills()
        self.assertEqual(tuple(sorted(found)), EXPECTED)
        for name, fields in found.items():
            self.assertEqual(fields["name"], name)

    def test_skills_disable_model_invocation(self):
        for name, fields in skills().items():
            with self.subTest(skill=name):
                self.assertEqual(fields.get("disable-model-invocation"), "true")

    def test_context_cost_report(self):
        found = skills()
        always_loaded = sum(len(f["description"]) for f in found.values() if f.get("disable-model-invocation") != "true")
        print("[context-cost] always-loaded-description-chars=%d skills=%d" % (always_loaded, len(found)), flush=True)
        for name, fields in sorted(found.items()):
            print("[context-cost] %s %d" % (name, len(fields["description"])), flush=True)
            self.assertLessEqual(len(fields["description"]), MAX_DESCRIPTION, name)
        self.assertEqual(always_loaded, 0)
        self.assertEqual(len(found), 3)

    def test_readme_table_matches_the_measured_descriptions(self):
        readme = README.read_text(encoding="utf-8")
        for name, fields in skills().items():
            self.assertIn("| `%s` | %d |" % (name, len(fields["description"])), readme, name)

    def test_skills_never_call_gh_directly(self):
        for path in SKILLS_DIR.glob("*/SKILL.md"):
            body = path.read_text(encoding="utf-8")
            self.assertNotRegex(body, r"(?m)^\s*gh\s", path.parent.name)
            self.assertNotIn("--scope", body)
            self.assertIn('${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py', body)

    def test_manifest_hooks_target_exists(self):
        manifest = json.loads((S.PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text())
        self.assertEqual(manifest["name"], "backlog")
        target = S.PLUGIN_ROOT / manifest["hooks"]
        self.assertTrue(target.is_file(), target)
        hooks = json.loads(target.read_text())["hooks"]
        self.assertEqual(sorted(hooks), ["PreToolUse"])
        command = hooks["PreToolUse"][0]["hooks"][0]["command"]
        script = command.split("${CLAUDE_PLUGIN_ROOT}/")[1].rstrip('"')
        self.assertTrue((S.PLUGIN_ROOT / script).is_file(), script)

    def test_manifest_has_no_settings_or_user_config_surface(self):
        manifest = json.loads((S.PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text())
        self.assertNotIn("userConfig", manifest)
        self.assertEqual(manifest["version"], "0.5.6")

    def test_reserved_words_stay_where_the_contract_puts_them(self):
        def offenders(pattern, allowed):
            allowed = (allowed,) if isinstance(allowed, str) else allowed
            out = []
            for path in sorted(S.SCRIPTS.glob("*.py")):
                if re.search(pattern, path.read_text(encoding="utf-8"), re.I) and path.name not in allowed:
                    out.append(path.name)
            return out

        self.assertEqual(offenders(r"cadence", "backlog_config.py"), [])
        self.assertEqual(offenders(r"issue edit|add-label|remove-label", ("backlog_guard.py", "backlog_gh.py")), [])
        self.assertEqual(offenders(r"subprocess", "backlog_gh.py"), [])


if __name__ == "__main__":
    unittest.main()
