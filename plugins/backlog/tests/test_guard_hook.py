import json
import shutil
import subprocess
import unittest

import _support
import backlog_config
import backlog_guard


def hook(project, command, tmp_bin=None):
    env = _support.cli_env(tmp_bin, {"CLAUDE_PROJECT_DIR": str(project), "CLAUDE_PLUGIN_ROOT": str(_support.PLUGIN_ROOT)})
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    return subprocess.run(["bash", str(_support.GUARD_HOOK)], input=payload, env=env, capture_output=True, text=True, cwd=str(project))


@unittest.skipUnless(shutil.which("jq"), "jq not installed")
class TestGuardHook(unittest.TestCase):
    def setUp(self):
        self._tmp = _support.tmpdir()
        self.project = _support.Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_no_config_silent_allow(self):
        proc = hook(self.project, "gh issue edit 5 --add-label status:ready")
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_propose_denies_raw_owned_axis_write(self):
        _support.write_mode(self.project, "propose")
        proc = hook(self.project, "gh issue edit 5 --add-label status:ready")
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        out = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "PreToolUse")
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("status:ready", out["permissionDecisionReason"])
        self.assertIn("/backlog:file", out["permissionDecisionReason"])
        self.assertIn("backlog_cli.py set", out["permissionDecisionReason"])

    def test_a_raw_status_ready_write_is_denied_or_allowed_by_mode(self):
        command = "gh issue edit 5 --add-label status:ready"
        for mode, expected in (("propose", 2), ("write-supervised", 2), ("free", 0)):
            with self.subTest(mode=mode):
                _support.write_mode(self.project, mode)
                self.assertEqual(hook(self.project, command).returncode, expected)

    def test_write_supervised_denies_too(self):
        _support.write_mode(self.project, "write-supervised")
        self.assertEqual(hook(self.project, "gh issue create --title x --label type:bug").returncode, 2)

    def test_non_owned_labels_and_flags_are_allowed(self):
        _support.write_mode(self.project, "propose")
        for command in (
            "gh issue edit 5 --add-label auto:pr-ready",
            "gh issue edit 5 --add-label nightly",
            "gh issue edit 5 --add-label cross-repo,area:web",
            "gh issue create --title x",
            "gh issue list --label status:ready",
            "gh pr create --title x",
            "echo hello",
            "python3 backlog_cli.py file --title x --label type:bug",
        ):
            with self.subTest(command=command):
                proc = hook(self.project, command)
                self.assertEqual((proc.returncode, proc.stdout), (0, ""))

    def test_free_and_off_allow_everything(self):
        for mode in ("free", "off"):
            with self.subTest(mode=mode):
                _support.write_mode(self.project, mode)
                self.assertEqual(hook(self.project, "gh issue edit 5 --add-label status:ready").returncode, 0)

    def test_free_mode_still_denies_an_undeclared_axis_value(self):
        # doctrine rule 3 (§4): unlike the namespace-touch rule above, this one is NOT lifted in free mode
        _support.write_mode(self.project, "free")
        proc = hook(self.project, "gh issue edit 5 --add-label priority:not-a-declared-value")
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        out = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("priority:not-a-declared-value", out["permissionDecisionReason"])
        self.assertIn("priority", out["permissionDecisionReason"])

    def test_free_mode_still_allows_a_declared_axis_value(self):
        # no over-blocking regression: status:ready is a DECLARED value, stays allowed in free (see the test above
        # this replaces: test_a_raw_status_ready_write_is_denied_or_allowed_by_mode also covers free -> 0)
        _support.write_mode(self.project, "free")
        proc = hook(self.project, "gh issue edit 5 --add-label status:ready")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_free_mode_still_denies_the_rest_api_bypass(self):
        _support.write_mode(self.project, "free")
        proc = hook(
            self.project,
            'gh api repos/acme/widgets/issues/5/labels -f "labels[]=priority:not-a-declared-value"',
        )
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        out = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("priority:not-a-declared-value", out["permissionDecisionReason"])

    def test_bare_issue_create_denied_by_default_in_write_supervised_and_free(self):
        for mode in ("write-supervised", "free"):
            with self.subTest(mode=mode):
                _support.write_mode(self.project, mode)
                proc = hook(self.project, "gh issue create --title x")
                self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
                out = json.loads(proc.stdout)["hookSpecificOutput"]
                self.assertEqual(out["permissionDecision"], "deny")
                self.assertIn("/backlog:file", out["permissionDecisionReason"])

    def test_bare_issue_create_allowed_with_guard_issue_create_false(self):
        for mode in ("write-supervised", "free"):
            with self.subTest(mode=mode):
                _support.write_repo_config(self.project, mode=mode, extra="guard_issue_create: false\n")
                proc = hook(self.project, "gh issue create --title x")
                self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_bare_issue_create_never_denied_in_propose(self):
        # propose already refuses every gh-level creation through mode alone; the new rule targets write-supervised/free
        _support.write_mode(self.project, "propose")
        proc = hook(self.project, "gh issue create --title x")
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_missing_python_fails_open(self):
        _support.write_mode(self.project, "propose")
        proc = hook(self.project, "gh issue edit 5 --add-label status:ready", None)
        self.assertEqual(proc.returncode, 2)  # control: it denies when python works
        env = _support.cli_env(None, {"CLAUDE_PROJECT_DIR": str(self.project), "CLAUDE_PLUGIN_ROOT": "/nonexistent"})
        payload = json.dumps({"tool_input": {"command": "gh issue edit 5 --add-label status:ready"}})
        broken = subprocess.run(["bash", str(_support.GUARD_HOOK)], input=payload, env=env, capture_output=True, text=True, cwd=str(self.project))
        self.assertEqual(broken.returncode, 0)


class TestGuardCheck(unittest.TestCase):
    def check(self, command, mode="propose"):
        return backlog_guard.check(command, backlog_config.default_config(mode))

    def test_denies_each_owned_axis_write_shape(self):
        for command in (
            "gh issue edit 5 --add-label status:ready",
            "gh issue edit 5 --remove-label size:S",
            "gh issue edit 5 --add-label=type:bug",
            'gh issue edit 5 --add-label "priority:0-now,nightly"',
            "gh issue create --title x -l exec:agent",
            "cd repo && gh issue edit 5 --add-label exec:human",
            "gh label create status:ready",
            "gh label edit size:S --color fff",
            "gh label delete type:bug --yes",
        ):
            with self.subTest(command=command):
                self.assertIsNotNone(self.check(command))

    def test_allows_the_rest(self):
        for command in (
            "gh issue edit 5 --add-label nightly",
            "gh issue edit 5 --add-label auto:blocked --remove-label auto:pr-ready",
            "gh label create area:web",
            "gh issue view 5",
            "gh issue edit 5 --title 'status:ready is a label'",
            "echo done",
        ):
            with self.subTest(command=command):
                self.assertIsNone(self.check(command))

    def test_off_and_free_never_deny_the_namespace_touch_rule(self):
        # rule 1 (namespace-touch) only: status:ready is a DECLARED value, so the doctrine rule (3) is silent too
        for mode in ("off", "free"):
            self.assertIsNone(self.check("gh issue edit 5 --add-label status:ready", mode))

    def test_compound_command_second_segment_is_still_checked(self):
        self.assertIsNotNone(self.check("gh issue list; gh issue edit 5 --add-label size:M"))
        self.assertIsNone(self.check("gh issue edit 5 --add-label nightly; echo status:ready"))

    def test_off_alone_skips_the_doctrine_rule_too(self):
        self.assertIsNone(self.check("gh issue edit 5 --add-label priority:not-a-declared-value", "off"))

    def test_doctrine_denies_an_undeclared_axis_value_in_every_mode_but_off(self):
        # in propose/write-supervised, rule 1 (namespace-touch) already denies ANY raw owned-axis write, declared
        # or not, so it fires first; the doctrine rule (3) is the one that newly denies `free`, and its own
        # reason (checked directly below) names the declared values
        for mode in ("propose", "write-supervised", "free"):
            with self.subTest(mode=mode):
                self.assertIsNotNone(self.check("gh issue edit 5 --add-label priority:not-a-declared-value", mode))
        reason = self.check("gh issue edit 5 --add-label priority:not-a-declared-value", "free")
        self.assertIn("priority:not-a-declared-value", reason)
        self.assertIn("0-now", reason)  # names a declared value too

    def test_doctrine_allows_a_declared_value_in_free_and_off(self):
        # propose/write-supervised deny it regardless (rule 1, checked elsewhere): only free and off isolate
        # what the doctrine rule alone decides
        for mode in ("off", "free"):
            self.assertIsNone(self.check("gh issue edit 5 --add-label priority:0-now", mode))

    def test_doctrine_is_silent_on_a_bare_flag_and_on_an_axis_outside_the_contract(self):
        self.assertIsNone(self.check("gh issue edit 5 --add-label nightly", "free"))
        self.assertIsNone(self.check("gh issue edit 5 --add-label auto:custom-flag", "free"))

    def test_doctrine_is_silent_on_a_free_axis(self):
        self.assertIsNone(self.check("gh issue edit 5 --add-label area:anything", "free"))

    def test_doctrine_denies_the_gh_api_rest_bypass(self):
        for command in (
            'gh api repos/acme/widgets/issues/5/labels -f "labels[]=priority:not-a-declared-value"',
            "gh api -X POST repos/acme/widgets/labels -f name=priority:not-a-declared-value",
        ):
            with self.subTest(command=command):
                reason = self.check(command, "free")
                self.assertIsNotNone(reason)
                self.assertIn("priority:not-a-declared-value", reason)

    def test_doctrine_allows_a_declared_value_via_the_gh_api_shape(self):
        self.assertIsNone(self.check('gh api repos/acme/widgets/issues/5/labels -f "labels[]=priority:0-now"', "free"))

    def test_doctrine_is_silent_on_an_unrelated_gh_api_call(self):
        self.assertIsNone(self.check("gh api repos/acme/widgets/issues/5", "free"))

    def test_dependency_endpoints_are_not_label_writes_and_stay_allowed(self):
        for command in (
            "gh api -X POST repos/o/r/issues/5/dependencies/blocked_by -F issue_id=1",
            "gh api -X DELETE repos/o/r/issues/5/dependencies/blocked_by/1",
            "gh api repos/o/r/issues/5 --jq .id",
        ):
            for mode in ("propose", "write-supervised", "free"):
                with self.subTest(command=command, mode=mode):
                    self.assertIsNone(self.check(command, mode))
                    self.assertIsNone(backlog_guard.check_ask(command, backlog_config.default_config(mode)))

    def test_bare_issue_create_denied_only_in_write_supervised_and_free(self):
        self.assertIsNone(self.check("gh issue create --title x", "propose"))
        self.assertIsNone(self.check("gh issue create --title x", "off"))
        for mode in ("write-supervised", "free"):
            with self.subTest(mode=mode):
                reason = self.check("gh issue create --title x", mode)
                self.assertIsNotNone(reason)
                self.assertIn("/backlog:file", reason)

    def test_bare_issue_create_opt_out(self):
        cfg = backlog_config.replace(backlog_config.default_config("free"), guard_issue_create=False)
        self.assertIsNone(backlog_guard.check("gh issue create --title x", cfg))


class TestApiTouchedLabels(unittest.TestCase):
    def test_extracts_values_from_dash_f_and_dash_capital_f(self):
        self.assertEqual(
            backlog_guard.api_touched_labels('gh api repos/o/r/issues/5/labels -f "labels[]=priority:bogus" -F name=type:bug'),
            ["priority:bogus", "type:bug"],
        )

    def test_ignores_calls_to_other_endpoints(self):
        self.assertEqual(backlog_guard.api_touched_labels("gh api repos/o/r/issues/5 -f title=x"), [])
        self.assertEqual(backlog_guard.api_touched_labels("gh api repos/o/r/pulls/5 -f labels[]=type:bug"), [])

    def test_matches_the_bare_labels_endpoint_too(self):
        self.assertEqual(backlog_guard.api_touched_labels("gh api repos/o/r/labels -f name=type:bug -f color=fff"), ["type:bug", "fff"])


APPLY_COMMANDS = (
    "python3 -B /x/plugins/backlog/scripts/backlog_cli.py label-sync --apply --confirm abc",
    "python3 -B /x/backlog_cli.py --project-dir /work/repo catchup check --proposals p.json --apply --confirm abc",
    "python3 -B /x/backlog_cli.py --project-dir '/work/my repo' rollback --snapshot-dir d --expect-sha s --apply",
    "bash /home/user/.backlog-snapshots/acme__widgets/20260919T120000Z/rollback.sh --apply --confirm abc",
    "cd /repo && python3 backlog_cli.py catchup check --proposals p --apply",
    "bash -c \"python3 backlog_cli.py label-sync --apply\"",
    "python3 -B /x/backlog_cli.py set --issue 5 --status needs-info --apply",
    "python3 -B /x/backlog_cli.py --project-dir /work/repo set --issue 5 --size S --apply --reason x",
)
NOT_APPLY_COMMANDS = (
    "python3 backlog_cli.py file --title x --label type:bug --apply --confirm abc",
    "python3 backlog_cli.py snapshot --snapshot-dir d",
    "python3 backlog_cli.py label-sync",
    "python3 backlog_cli.py label-sync --live-file l.json",
    "python3 backlog_cli.py catchup propose --out p.json",
    "python3 backlog_cli.py rollback --snapshot-dir d --expect-sha s",
    "bash d/rollback.sh",
    "python3 backlog_cli.py config",
    "echo backlog_cli.py label-sync; echo --apply",
    "python3 backlog_cli.py set --issue 5 --status needs-info",
    "python3 backlog_cli.py settings --apply",
)


@unittest.skipUnless(shutil.which("jq"), "jq not installed")
class TestApplyAskRuleH2(unittest.TestCase):
    """Rule H2: an apply command gets `permissionDecision: ask` (exit 0), in every mode except off."""

    def setUp(self):
        self._tmp = _support.tmpdir()
        self.project = _support.Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_an_apply_command_is_silent_by_default(self):
        # apply_prompt defaults to "none": normal work raises no permission prompt
        for mode in ("propose", "write-supervised", "free"):
            _support.write_mode(self.project, mode)
            for command in APPLY_COMMANDS:
                with self.subTest(mode=mode, command=command):
                    proc = hook(self.project, command)
                    self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_an_apply_command_asks_when_apply_prompt_is_ask(self):
        for mode in ("propose", "write-supervised", "free"):
            _support.write_repo_config(self.project, mode=mode, extra="apply_prompt: ask\n")
            for command in APPLY_COMMANDS:
                with self.subTest(mode=mode, command=command):
                    proc = hook(self.project, command)
                    self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                    self.assertEqual(proc.stderr, "")
                    out = json.loads(proc.stdout)["hookSpecificOutput"]
                    self.assertEqual(out["hookEventName"], "PreToolUse")
                    self.assertEqual(out["permissionDecision"], "ask")
                    self.assertIn("APPLIES label changes", out["permissionDecisionReason"])

    def test_off_and_no_config_stay_silent(self):
        _support.write_mode(self.project, "off")
        for command in APPLY_COMMANDS:
            with self.subTest(mode="off", command=command):
                proc = hook(self.project, command)
                self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))
        empty = _support.Path(self._tmp.name) / "empty"
        empty.mkdir()
        for command in APPLY_COMMANDS:
            with self.subTest(config="none", command=command):
                proc = hook(empty, command)
                self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_everything_that_is_not_an_apply_stays_silent(self):
        for mode in ("propose", "write-supervised", "free"):
            _support.write_mode(self.project, mode)
            for command in NOT_APPLY_COMMANDS:
                with self.subTest(mode=mode, command=command):
                    proc = hook(self.project, command)
                    self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_the_raw_owned_axis_deny_is_still_a_deny(self):
        _support.write_mode(self.project, "propose")
        proc = hook(self.project, "gh issue edit 5 --add-label status:ready")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(json.loads(proc.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
        # deny wins when one command does both
        proc = hook(self.project, "gh issue edit 5 --add-label status:ready; python3 backlog_cli.py label-sync --apply")
        self.assertEqual(proc.returncode, 2)

    def test_no_config_means_no_stdin_read_no_jq_and_no_python(self):
        # inert before anything: an EMPTY PATH would break jq/python/grep, and the hook must still exit 0 silently
        env = {"PATH": "", "CLAUDE_PROJECT_DIR": str(self.project), "CLAUDE_PLUGIN_ROOT": str(_support.PLUGIN_ROOT)}
        bash = shutil.which("bash")
        proc = subprocess.run([bash, str(_support.GUARD_HOOK)], input="{}", env=env, capture_output=True, text=True, cwd=str(self.project))
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr), (0, "", ""))

    def test_a_broken_plugin_root_fails_open(self):
        _support.write_mode(self.project, "propose")
        env = _support.cli_env(None, {"CLAUDE_PROJECT_DIR": str(self.project), "CLAUDE_PLUGIN_ROOT": "/nonexistent"})
        payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": APPLY_COMMANDS[0]}})
        proc = subprocess.run(["bash", str(_support.GUARD_HOOK)], input=payload, env=env, capture_output=True, text=True, cwd=str(self.project))
        self.assertEqual((proc.returncode, proc.stdout), (0, ""))

    def test_the_first_executable_line_is_still_the_config_test(self):
        lines = [l for l in _support.GUARD_HOOK.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")]
        self.assertEqual(lines[0], '[ -f "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/backlog.yml" ] || exit 0')
        self.assertIn('"ask"', _support.GUARD_HOOK.read_text())


class TestCheckAsk(unittest.TestCase):
    def check(self, command, mode="propose"):
        return backlog_guard.check_ask(command, backlog_config.default_config(mode))

    def test_off_never_asks(self):
        for command in APPLY_COMMANDS:
            self.assertIsNone(self.check(command, "off"))

    def test_apply_commands_ask_in_the_other_modes_when_enabled(self):
        for mode in ("propose", "write-supervised", "free"):
            cfg = backlog_config.replace(backlog_config.default_config(mode), apply_prompt="ask")
            for command in APPLY_COMMANDS:
                with self.subTest(mode=mode, command=command):
                    self.assertIn(mode, backlog_guard.check_ask(command, cfg))

    def test_apply_commands_never_ask_by_default(self):
        for mode in ("propose", "write-supervised", "free"):
            for command in APPLY_COMMANDS:
                with self.subTest(mode=mode, command=command):
                    self.assertIsNone(self.check(command, mode))

    def test_other_commands_do_not(self):
        for command in NOT_APPLY_COMMANDS:
            with self.subTest(command=command):
                self.assertIsNone(self.check(command))

    def test_check_itself_is_unchanged_and_never_asks(self):
        self.assertIsNone(backlog_guard.check("python3 backlog_cli.py label-sync --apply", backlog_config.default_config("propose")))


if __name__ == "__main__":
    unittest.main()
