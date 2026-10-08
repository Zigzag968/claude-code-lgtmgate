import ast
import json
import subprocess
import unittest

import _support
import backlog_config
from backlog_gh import Gh, ModeError, READ_ALLOW, WRITE_ALLOW


def gh_for(mode="free", repo=None, runner=None, **kw):
    cfg = backlog_config.default_config(mode, repo)
    runner = runner or _support.FakeRunner()
    return Gh(cfg, runner=runner, **kw), runner


class TestWrapper(unittest.TestCase):
    def test_allow_lists_are_exactly_four_reads_and_one_write(self):
        self.assertEqual(READ_ALLOW, {("issue", "list"), ("issue", "view"), ("pr", "list"), ("label", "list")})
        self.assertEqual(WRITE_ALLOW, {("issue", "create")})

    def test_denied_verbs_raise(self):
        denied = [
            (("issue", "edit"), ["5", "--title=x"], True),
            (("issue", "close"), ["5"], True),
            (("issue", "comment"), ["5", "--body=x"], True),
            (("label", "create"), ["x"], True),
            (("label", "delete"), ["x"], True),
            (("api",), ["repos/o/r"], False),
            (("pr", "merge"), ["5"], True),
        ]
        for verb, args, write in denied:
            for mode in ("propose", "write-supervised", "free"):
                with self.subTest(verb=verb, mode=mode):
                    gh, runner = gh_for(mode)
                    with self.assertRaises(ModeError):
                        gh.run(verb, args, write=write, confirmed=True)
                    self.assertEqual(runner.calls, [])

    def test_read_verb_cannot_be_used_as_a_write_and_vice_versa(self):
        gh, runner = gh_for("free")
        with self.assertRaises(ModeError):
            gh.run(("issue", "list"), [], write=True)
        with self.assertRaises(ModeError):
            gh.run(("issue", "create"), ["--title=x"], write=False)
        self.assertEqual(runner.calls, [])

    def test_mode_off_reaches_nothing_even_reads(self):
        gh, runner = gh_for("off")
        with self.assertRaises(ModeError):
            gh.fetch_issues()
        with self.assertRaises(ModeError):
            gh.create_issue("t", "b", ["type:bug"], confirmed=True)
        self.assertEqual(runner.calls, [])

    def test_propose_refuses_create(self):
        gh, runner = gh_for("propose")
        with self.assertRaises(ModeError):
            gh.create_issue("t", "b", ["type:bug"], confirmed=True)
        self.assertEqual(runner.calls, [])
        self.assertEqual(gh.fetch_issues(), [])  # reads are fine

    def test_write_supervised_needs_confirmed(self):
        gh, runner = gh_for("write-supervised")
        with self.assertRaises(ModeError):
            gh.create_issue("t", "b", ["type:bug"])
        self.assertEqual(runner.calls, [])
        self.assertEqual(gh.create_issue("t", "b", ["type:bug"], confirmed=True), "https://github.com/o/r/issues/1")
        self.assertEqual(runner.verbs(), [("issue", "create")])

    def test_free_creates(self):
        gh, runner = gh_for("free")
        url = gh.create_issue("a title", "a body", ["type:bug", "status:inbox"])
        self.assertEqual(url, "https://github.com/o/r/issues/1")
        argv = runner.calls[0]
        self.assertEqual(argv[:3], ["gh", "issue", "create"])
        self.assertIn("--title=a title", argv)
        self.assertIn("--label=type:bug", argv)
        self.assertNotIn("--web", argv)

    def test_call_cap(self):
        gh, runner = gh_for("free", max_calls=2)
        gh.fetch_label_names()
        gh.fetch_label_names()
        with self.assertRaises(ModeError):
            gh.fetch_label_names()
        self.assertEqual(len(runner.calls), 2)

    def test_write_cap(self):
        gh, runner = gh_for("free", max_writes=1)
        gh.create_issue("one", "b", ["type:bug"])
        with self.assertRaises(ModeError):
            gh.create_issue("two", "b", ["type:bug"])
        self.assertEqual(runner.verbs(), [("issue", "create")])

    def test_repo_injected_and_caller_repo_impossible(self):
        gh, runner = gh_for("free", repo="acme/widgets")
        gh.fetch_issues()
        argv = runner.calls[0]
        self.assertEqual(argv[-2:], ["-R", "acme/widgets"])
        self.assertEqual(argv.count("-R"), 1)
        for smuggled in (["-R", "evil/repo"], ["--repo", "evil/repo"], ["--repo=evil/repo"], ["--web"], ["--editor"]):
            with self.subTest(smuggled=smuggled):
                with self.assertRaises(ModeError):
                    gh.run(("issue", "list"), smuggled)
        for smuggled in ("--assignee=me", "--project=p", "--milestone=m", "--template=t", "--recover=x", "-R=evil/repo", "--web"):
            with self.subTest(create_flag=smuggled):
                with self.assertRaises(ModeError):
                    gh.run(("issue", "create"), ["--title=t", smuggled], write=True)
        self.assertEqual(len(runner.calls), 1)

    def test_no_repo_means_no_r_flag(self):
        gh, runner = gh_for("propose")
        gh.fetch_issues()
        self.assertNotIn("-R", runner.calls[0])

    def test_truncation_fails_closed(self):
        runner = _support.FakeRunner(issues=[{"number": n} for n in range(3)])
        gh, _ = gh_for("propose", runner=runner)
        with self.assertRaises(RuntimeError) as ctx:
            gh.fetch_issues("open", 3)
        self.assertIn("truncation", str(ctx.exception))
        self.assertEqual(len(gh.fetch_issues("open", 4)), 3)

    def test_label_list_truncation_fails_closed(self):
        runner = _support.FakeRunner(labels=["l%d" % n for n in range(200)])
        gh, _ = gh_for("propose", runner=runner)
        with self.assertRaises(RuntimeError):
            gh.fetch_label_names()

    def test_failures_fail_closed(self):
        cases = {
            "nonzero": _support.FakeRunner(fail=subprocess.CalledProcessError(1, "gh")),
            "missing-binary": _support.FakeRunner(fail=FileNotFoundError("gh")),
        }
        for name, runner in cases.items():
            with self.subTest(name=name):
                gh, _ = gh_for("propose", runner=runner)
                with self.assertRaises(RuntimeError):
                    gh.fetch_issues()

    def test_non_json_and_non_list_payloads_fail_closed(self):
        for payload in ("not json", '{"a": 1}'):
            with self.subTest(payload=payload):
                def runner(argv, **kw):
                    return subprocess.CompletedProcess(argv, 0, stdout=payload, stderr="")

                gh, _ = gh_for("propose", runner=runner)
                with self.assertRaises(RuntimeError):
                    gh.fetch_issues()

    def test_invalid_state_refused(self):
        gh, runner = gh_for("propose")
        with self.assertRaises(ModeError):
            gh.fetch_issues(state="--web")
        self.assertEqual(runner.calls, [])

    def test_reads_use_limits(self):
        gh, runner = gh_for("propose")
        gh.fetch_issues()
        gh.fetch_prs()
        gh.fetch_label_names()
        self.assertTrue(all("--limit" in c for c in runner.calls))
        self.assertEqual(len(runner.calls), 3)


def spawners(source):
    """Names of modules imported that can spawn a process (the oracle)."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            found += [a.name for a in node.names if a.name.split(".")[0] in ("subprocess", "pty")]
        if isinstance(node, ast.ImportFrom) and (node.module or "").split(".")[0] in ("subprocess", "pty"):
            found.append(node.module)
    return found


class TestSingleChokepoint(unittest.TestCase):
    def test_only_backlog_gh_imports_subprocess(self):
        offenders = []
        for path in sorted(_support.SCRIPTS.glob("*.py")):
            if spawners(path.read_text(encoding="utf-8")) and path.name != "backlog_gh.py":
                offenders.append(path.name)
        self.assertEqual(offenders, [])
        self.assertTrue(spawners((_support.SCRIPTS / "backlog_gh.py").read_text(encoding="utf-8")))

    def test_oracle_can_fail_poisoned_source_twin(self):
        for poisoned in ("import subprocess\n", "from subprocess import run\n", "import subprocess as sp\n"):
            with self.subTest(poisoned=poisoned):
                self.assertNotEqual(spawners(poisoned), [])
        self.assertEqual(spawners("import json\n"), [])

    def test_no_os_system_or_popen_calls_anywhere(self):
        for path in sorted(_support.SCRIPTS.glob("*.py")):
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if isinstance(node, ast.Attribute) and node.attr in ("system", "popen", "spawnv", "execv"):
                    self.fail("%s uses %s" % (path.name, node.attr))


if __name__ == "__main__":
    unittest.main()
