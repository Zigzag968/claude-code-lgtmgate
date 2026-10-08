"""Native issue dependencies ("Blocked by") through REST: `DepGh`, `file --blocked-by`, `set --blocked-by/--unblock`.

In-process, fake runner only: no live gh.
"""

import contextlib
import io
import json
import re
import subprocess
import unittest

import _support
import backlog_apply
import backlog_config
import backlog_file
import backlog_gh
import backlog_set
from backlog_gh import DepGh, Gh, ModeError
from test_set import SetBase

REPO_LABELS = {"type:bug", "status:inbox"}
FILE_ARGS = ["--title", "A clear title", "--body", "b", "--label", "type:bug"]


def cfg_for(mode="write-supervised", repo="acme/widgets"):
    return backlog_config.default_config(mode, repo)


def dep_gh(mode="write-supervised", repo="acme/widgets", **kw):
    runner = _support.FakeRunner()
    return DepGh(cfg_for(mode, repo), runner=runner, **kw), runner


class TestDepGh(unittest.TestCase):
    def test_the_two_existing_allow_lists_are_untouched(self):
        self.assertEqual(backlog_gh.WRITE_ALLOW, frozenset({("issue", "create")}))
        self.assertEqual(backlog_gh.APPLY_ALLOW, frozenset({("issue", "edit"), ("label", "create")}))

    def test_it_is_a_sibling_not_a_subclass(self):
        self.assertFalse(issubclass(DepGh, Gh))
        self.assertFalse(issubclass(DepGh, backlog_gh.ApplyGh))

    def test_the_three_rest_shapes(self):
        gh, runner = dep_gh()
        self.assertEqual(gh.issue_id(90), 1090)
        gh.add_blocked_by(5, 90)
        gh.remove_blocked_by(5, 91)
        self.assertEqual(runner.calls, [
            ["gh", "api", "repos/acme/widgets/issues/90", "--jq", ".id"],
            ["gh", "api", "repos/acme/widgets/issues/90", "--jq", ".id"],
            ["gh", "api", "-X", "POST", "repos/acme/widgets/issues/5/dependencies/blocked_by", "-F", "issue_id=1090"],
            ["gh", "api", "repos/acme/widgets/issues/91", "--jq", ".id"],
            ["gh", "api", "-X", "DELETE", "repos/acme/widgets/issues/5/dependencies/blocked_by/1091"],
        ])

    def test_write_supervised_and_free_can_build_one_propose_and_off_cannot(self):
        for mode in ("write-supervised", "free"):
            DepGh(cfg_for(mode), runner=_support.FakeRunner())
        for mode in ("propose", "off"):
            with self.subTest(mode=mode), self.assertRaises(ModeError):
                DepGh(cfg_for(mode), runner=_support.FakeRunner())

    def test_a_missing_or_malformed_repo_refuses(self):
        for repo in (None, "", "noslash", "a/b/c", "a/..", "a/b\n", "-x/y", "a b/c"):
            with self.subTest(repo=repo), self.assertRaises(ModeError):
                DepGh(cfg_for(repo=repo), runner=_support.FakeRunner())

    def test_bad_numbers_are_refused_with_zero_call(self):
        gh, runner = dep_gh()
        for bad in (0, -1, True, "5", None, 1.5):
            with self.subTest(bad=bad):
                for call in (lambda: gh.issue_id(bad), lambda: gh.add_blocked_by(bad, 1),
                             lambda: gh.add_blocked_by(1, bad), lambda: gh.remove_blocked_by(1, bad)):
                    with self.assertRaises(ModeError):
                        call()
        self.assertEqual(runner.calls, [])

    def test_a_self_link_is_refused(self):
        gh, runner = dep_gh()
        with self.assertRaises(ModeError):
            gh.add_blocked_by(5, 5)
        self.assertEqual(runner.calls, [])

    def test_an_unusable_id_fails_closed(self):
        for out in ("", "null\n", "0\n", "-3\n", "12abc\n", "1 2\n"):
            with self.subTest(out=out):
                gh = DepGh(cfg_for(), runner=lambda argv, **kw: subprocess.CompletedProcess(argv, 0, stdout=out, stderr=""))
                with self.assertRaises(RuntimeError):
                    gh.add_blocked_by(1, 2)

    def test_the_call_cap(self):
        gh, runner = dep_gh(max_calls=4)
        gh.add_blocked_by(1, 2)
        gh.add_blocked_by(1, 3)
        with self.assertRaises(ModeError):
            gh.add_blocked_by(1, 4)
        self.assertEqual(len(runner.calls), 4)
        self.assertEqual(backlog_gh.MAX_DEP_LINKS * 2, backlog_gh.MAX_DEP_CALLS)

    def test_a_process_error_becomes_a_runtime_error(self):
        gh = DepGh(cfg_for(), runner=_support.FakeRunner(fail=FileNotFoundError("gh")))
        with self.assertRaises(RuntimeError):
            gh.issue_id(3)
        gh = DepGh(cfg_for(), runner=_support.FakeRunner(fail=subprocess.CalledProcessError(1, ["gh"])))
        with self.assertRaises(RuntimeError):
            gh.add_blocked_by(1, 2)


def run_file(argv, mode, runner=None, cfg=None):
    runner = runner or _support.FakeRunner(labels=sorted(REPO_LABELS))
    cfg = cfg or cfg_for(mode)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = backlog_file.main(list(argv), cfg, Gh(cfg, runner=runner), dep_runner=runner)
    return rc, out.getvalue(), runner


class TestFileBlockedBy(unittest.TestCase):
    def test_dry_run_prints_the_plan_and_creates_nothing(self):
        for mode in ("propose", "write-supervised", "free"):
            with self.subTest(mode=mode):
                rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "91", "--blocked-by", "90"], mode)
                self.assertEqual(rc, 0, out)
                self.assertIn("[backlog-file] planned blocked-by: #90\n[backlog-file] planned blocked-by: #91\n", out)
                self.assertIn("dry-run: nothing created", out)
                self.assertEqual([c for c in runner.calls if c[1] != "issue" and c[1] != "label"], [])
                self.assertFalse([c for c in runner.calls if c[1:3] == ["issue", "create"]])

    def test_the_dependencies_are_part_of_the_digest(self):
        _, plain, _ = run_file(FILE_ARGS, "write-supervised")
        _, with_dep, _ = run_file(FILE_ARGS + ["--blocked-by", "90"], "write-supervised")
        _, other_dep, _ = run_file(FILE_ARGS + ["--blocked-by", "91"], "write-supervised")
        digests = [re.search(r"payload-digest=([0-9a-f]{16})", o).group(1) for o in (plain, with_dep, other_dep)]
        self.assertEqual(len(set(digests)), 3)
        self.assertEqual(
            backlog_file.payload_digest("t", "b", ["x"], "o/r"), backlog_file.payload_digest("t", "b", ["x"], "o/r", ()))
        self.assertEqual(
            backlog_file.payload_digest("t", "b", ["x"], "o/r", [90, 91]), backlog_file.payload_digest("t", "b", ["x"], "o/r", [91, 90, 90]))

    def test_a_confirm_of_the_payload_without_dependencies_is_refused(self):
        _, out, _ = run_file(FILE_ARGS, "write-supervised")
        stale = re.search(r"payload-digest=([0-9a-f]{16})", out).group(1)
        rc, _, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--apply", "--confirm", stale], "write-supervised")
        self.assertEqual(rc, 1)
        self.assertFalse([c for c in runner.calls if c[1:3] == ["issue", "create"]])
        self.assertEqual(runner.dep_writes(), [])

    def test_apply_creates_then_resolves_the_id_then_posts(self):
        _, out, _ = run_file(FILE_ARGS + ["--blocked-by", "90"], "write-supervised")
        digest = re.search(r"payload-digest=([0-9a-f]{16})", out).group(1)
        rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--apply", "--confirm", digest], "write-supervised")
        self.assertEqual(rc, 0, out)
        tail = runner.calls[-3:]
        self.assertEqual(tail[0][1:3], ["issue", "create"])
        self.assertEqual(tail[1], ["gh", "api", "repos/acme/widgets/issues/90", "--jq", ".id"])
        self.assertEqual(tail[2], ["gh", "api", "-X", "POST", "repos/acme/widgets/issues/1/dependencies/blocked_by", "-F", "issue_id=1090"])
        self.assertIn("linked #1 blocked-by #90", out)

    def test_free_mode_links_every_blocker(self):
        rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--blocked-by", "91", "--apply"], "free")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(runner.dep_writes()), 2)

    def test_a_failed_link_after_the_create_is_reported_with_the_missing_links(self):
        runner = _support.FakeRunner(labels=sorted(REPO_LABELS), fail_dep_at=1)
        rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--blocked-by", "91", "--apply"], "free", runner=runner)
        self.assertEqual(rc, 1)
        self.assertIn("created https://github.com/o/r/issues/1", out)
        self.assertIn("error: created #1 (https://github.com/o/r/issues/1) but these blocked-by links are missing: #90", out)
        self.assertNotIn("#91 (", out)
        self.assertIn("linked #1 blocked-by #91", out)

    def test_an_unreadable_created_url_is_reported(self):
        runner = _support.FakeRunner(labels=sorted(REPO_LABELS), create_url="created\n")
        rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--apply"], "free", runner=runner)
        self.assertEqual(rc, 1)
        self.assertIn("missing blocked-by links: #90", out)
        self.assertEqual(runner.dep_writes(), [])

    def test_no_repo_refuses_before_the_create(self):
        rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--apply"], "free", cfg=cfg_for("free", None))
        self.assertEqual(rc, 1)
        self.assertIn("refusing to create", out)
        self.assertFalse([c for c in runner.calls if c[1:3] == ["issue", "create"]])

    def test_propose_with_apply_stays_a_proposal(self):
        rc, out, runner = run_file(FILE_ARGS + ["--blocked-by", "90", "--apply"], "propose")
        self.assertEqual(rc, 0)
        self.assertIn("proposal only", out)
        self.assertEqual(runner.dep_writes(), [])

    def test_too_many_links_and_bad_numbers_are_refused(self):
        many = []
        for n in range(1, backlog_gh.MAX_DEP_LINKS + 2):
            many += ["--blocked-by", str(n)]
        rc, out, runner = run_file(FILE_ARGS + many + ["--apply"], "free")
        self.assertEqual(rc, 1)
        self.assertIn("too-many-blocked-by", out)
        self.assertFalse([c for c in runner.calls if c[1:3] == ["issue", "create"]])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run_file(FILE_ARGS + ["--blocked-by", "0"], "propose")


class TestSetBlockedBy(SetBase):
    def run_dep(self, argv, issues=None, cfg=None, **kw):
        return self.run_set(argv, issues=issues, cfg=cfg, **kw)

    def test_dry_run_prints_the_link_changes_and_writes_nothing(self):
        issues = [_support.issue(1, "type:bug", "status:inbox", blockers=[{"number": 7, "state": "OPEN"}])]
        rc, out, runner = self.run_dep(["--issue", "1", "--blocked-by", "90", "--unblock", "7"], issues=issues)
        self.assertEqual(rc, 0, out)
        self.assertIn("[set] #1 planned blocked-by: +#90", out)
        self.assertIn("[set] #1 planned blocked-by: -#7", out)
        self.assertIn("dry-run only", out)
        self.assertEqual(runner.dep_writes(), [])
        self.assertFalse(self.journal_path().exists())

    def test_a_dependency_flag_alone_satisfies_the_at_least_one_rule_and_works_in_propose(self):
        cfg = self.make_cfg(mode="propose", repo=None, extra="")
        rc, out, runner = self.run_dep(["--issue", "1", "--blocked-by", "90"], cfg=cfg)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.calls[0][1:3], ["issue", "view"])
        self.assertEqual(runner.dep_writes(), [])

    def test_no_flag_at_all_is_still_a_usage_error(self):
        self.assertIn("--blocked-by", self.parse_error(["--issue", "1"]))

    def test_a_link_already_in_the_live_blocked_by_is_a_noop(self):
        issues = [_support.issue(1, "type:bug", "status:inbox", blockers=[{"number": 90, "state": "CLOSED"}])]
        rc, out, runner = self.run_dep(["--issue", "1", "--blocked-by", "90", "--apply"], issues=issues)
        self.assertEqual(rc, 0, out)
        self.assertIn("blocked-by #90 noop", out)
        self.assertIn("noop (already in the target state)", out)
        self.assertEqual(runner.dep_writes(), [])
        self.assertFalse(self.journal_path().exists())

    def test_an_unblock_of_a_link_that_is_not_there_is_a_noop(self):
        rc, out, runner = self.run_dep(["--issue", "1", "--unblock", "5", "--apply"])
        self.assertEqual(rc, 0, out)
        self.assertIn("unblock #5 noop", out)
        self.assertEqual(runner.dep_writes(), [])

    def test_apply_writes_the_links_and_journals_the_intent_first(self):
        seen = []

        def before_write(argv):
            seen.append(self.journal_lines() if self.journal_path().exists() else None)

        issues = [_support.issue(1, "type:bug", "status:inbox", blockers=[{"number": 7, "state": "OPEN"}])]
        rc, out, runner = self.run_dep(
            ["--issue", "1", "--blocked-by", "90", "--unblock", "7", "--apply", "--reason", "order"],
            issues=issues, before_write=before_write)
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.writes(), [])  # no label write
        self.assertEqual(runner.dep_writes(), [
            ["gh", "api", "-X", "POST", "repos/acme/widgets/issues/1/dependencies/blocked_by", "-F", "issue_id=1090"],
            ["gh", "api", "-X", "DELETE", "repos/acme/widgets/issues/1/dependencies/blocked_by/1007"],
        ])
        self.assertEqual([e["status"] for e in seen[0]], ["intent"])  # on disk BEFORE the first write
        lines = self.journal_lines()
        self.assertEqual([e["status"] for e in lines], ["intent", "applied"])
        self.assertEqual(lines[0]["kind"], "dependencies")
        self.assertEqual(lines[0]["blocked_by_add"], [90])
        self.assertEqual(lines[0]["blocked_by_remove"], [7])
        self.assertEqual(lines[0]["reason"], "order")
        self.assertIn("[set] applied: blocked-by added=#90 removed=#7", out)

    def test_combined_with_an_axis_flag_the_labels_are_written_first(self):
        rc, out, runner = self.run_dep(["--issue", "1", "--status", "needs-info", "--blocked-by", "90", "--apply"])
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(runner.writes()), 2)
        self.assertEqual(len(runner.dep_writes()), 1)
        first_dep = runner.calls.index(runner.dep_writes()[0])
        self.assertTrue(all(runner.calls.index(w) < first_dep for w in runner.writes()))
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "applied", "intent", "applied"])

    def test_a_failed_second_link_is_journaled_as_partial(self):
        rc, out, runner = self.run_dep(["--issue", "1", "--blocked-by", "90", "--blocked-by", "91", "--apply"], fail_dep_at=2)
        self.assertEqual(rc, 1)
        self.assertIn("partial: added=#90", out)
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "partial"])

    def test_a_failed_first_link_is_journaled_as_failed(self):
        rc, out, _ = self.run_dep(["--issue", "1", "--blocked-by", "90", "--apply"], fail_dep_at=1)
        self.assertEqual(rc, 1)
        self.assertEqual([e["status"] for e in self.journal_lines()], ["intent", "failed"])

    def test_refused_apply_makes_no_call(self):
        for cfg in (self.make_cfg(mode="propose", extra=""), self.make_cfg(repo=None, extra="")):
            rc, out, runner = self.run_dep(["--issue", "1", "--blocked-by", "90", "--apply"], cfg=cfg)
            self.assertEqual(rc, 1)
            self.assertIn("refused", out)
            self.assertEqual(runner.calls, [])

    def test_a_self_link_and_an_overlap_are_refused_before_any_call(self):
        for argv, text in (
            (["--issue", "1", "--blocked-by", "1"], "cannot block itself"),
            (["--issue", "1", "--unblock", "1"], "cannot block itself"),
            (["--issue", "1", "--blocked-by", "5", "--unblock", "5"], "same issue"),
        ):
            with self.subTest(argv=argv):
                rc, out, runner = self.run_dep(argv + ["--apply"])
                self.assertEqual(rc, 1)
                self.assertIn(text, out)
                self.assertEqual(runner.calls, [])

    def test_the_apply_stays_off_without_the_flag(self):
        rc, out, runner = self.run_dep(["--issue", "1", "--blocked-by", "90"])
        self.assertEqual(rc, 0)
        self.assertEqual(runner.dep_writes(), [])


class TestSurface(unittest.TestCase):
    def test_dep_gh_is_built_only_by_the_file_intake_and_the_applier(self):
        import ast

        sites = []
        for path in sorted(_support.SCRIPTS.glob("*.py")):
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", "")) == "DepGh":
                    sites.append(path.name)
        self.assertEqual(sorted(set(sites)), ["backlog_apply.py", "backlog_file.py"])

    def test_no_graphql_shape_exists_in_the_dependency_chokepoint(self):
        source = (_support.SCRIPTS / "backlog_gh.py").read_text(encoding="utf-8")
        self.assertNotIn('"graphql"', source)
        self.assertNotIn("api graphql", source)

    def test_the_cli_reaches_the_dependencies_only_in_an_apply(self):
        # a dry run through the real CLI, fake gh shim on PATH: the only calls are reads, never an `api` call
        with _support.tmpdir() as tmp:
            project = _support.Path(tmp) / "repo"
            project.mkdir()
            _support.write_repo_config(project, "acme/widgets", "free")
            log = _support.fake_gh(_support.Path(tmp) / "bin")
            env = _support.cli_env(_support.Path(tmp) / "bin", {"HOME": tmp})
            issues, labels = _support.Path(tmp) / "i.json", _support.Path(tmp) / "l.json"
            issues.write_text("[]")
            labels.write_text(json.dumps([{"name": "type:tech-debt"}, {"name": "status:inbox"}]))
            proc = _support.run_cli(["file", "--title", "t", "--body", "b", "--label", "type:tech-debt", "--blocked-by", "90",
                              "--issues-file", str(issues), "--labels-file", str(labels)], project, env)
            self.assertEqual(_support.gh_calls(log), [])
        self.assertIn("planned blocked-by: #90", proc.stdout)


if __name__ == "__main__":
    unittest.main()
