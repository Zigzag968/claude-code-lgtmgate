"""`ApplyGh`: the label-write chokepoint. Every refusal is proved with a runner that must stay untouched."""

import subprocess
import unittest

import _support
import backlog_config
import backlog_gh
from backlog_gh import ApplyGh, ApplyGrant, Gh, ModeError, PartialApplyError

ROLE_ADDS = frozenset({"status:ready", "exec:agent"})


def cfg_for(mode="write-supervised", repo="acme/widgets"):
    return backlog_config.default_config(mode, repo)


def grant(repo="acme/widgets", issues=(1, 2, 3), labels=("type:bug", "status:inbox")):
    return ApplyGrant(repo=repo, digest="d" * 16, snapshot_sha="s" * 64, issues=frozenset(issues),
                      labels=frozenset(labels), refused_adds=ROLE_ADDS)


def apply_gh(**kw):
    runner = _support.FakeRunner(issues=[_support.issue(n) for n in (1, 2, 3)])
    return ApplyGh(cfg_for(), grant(**kw), runner=runner), runner


class TestAllowLists(unittest.TestCase):
    def test_the_apply_allow_list_and_flags_are_exact(self):
        self.assertEqual(backlog_gh.APPLY_ALLOW, frozenset({("issue", "edit"), ("label", "create")}))
        self.assertEqual(
            {k: sorted(v) for k, v in backlog_gh.APPLY_FLAGS.items()},
            {("issue", "edit"): ["--add-label", "--remove-label"], ("label", "create"): ["--color", "--description"]},
        )
        self.assertEqual(backlog_gh.MAX_APPLY_ISSUES, 50)

    def test_gh_keeps_exactly_four_reads_and_its_one_write(self):
        self.assertEqual(backlog_gh.WRITE_ALLOW, frozenset({("issue", "create")}))
        self.assertEqual(backlog_gh.READ_ALLOW, frozenset({("issue", "list"), ("issue", "view"), ("label", "list"), ("pr", "list")}))
        self.assertTrue(backlog_gh.APPLY_ALLOW.isdisjoint(backlog_gh.READ_ALLOW | backlog_gh.WRITE_ALLOW))

    def test_apply_gh_is_a_sibling_not_a_subclass(self):
        self.assertFalse(issubclass(ApplyGh, Gh))
        self.assertFalse(issubclass(Gh, ApplyGh))

    def test_gh_still_refuses_the_apply_verbs(self):
        runner = _support.FakeRunner()
        gh = Gh(cfg_for("free"), runner=runner, max_writes=5)
        for verb in (("issue", "edit"), ("label", "create")):
            with self.subTest(verb=verb), self.assertRaises(ModeError):
                gh.run(verb, ["--add-label=x"], write=True)
        self.assertEqual(runner.calls, [])


class TestConstruction(unittest.TestCase):
    def test_a_grant_is_required(self):
        for bad in (None, {"repo": "acme/widgets"}, "grant"):
            with self.subTest(bad=bad), self.assertRaises(ModeError):
                ApplyGh(cfg_for(), bad, runner=_support.FakeRunner())

    def test_only_write_supervised_and_free_can_build_one(self):
        for mode in ("off", "propose"):
            with self.subTest(mode=mode), self.assertRaises(ModeError):
                ApplyGh(cfg_for(mode), grant(), runner=_support.FakeRunner())
        for mode in ("write-supervised", "free"):
            with self.subTest(mode=mode):
                ApplyGh(cfg_for(mode), grant(), runner=_support.FakeRunner())

    def test_the_grant_must_belong_to_the_repo_of_the_config(self):
        with self.assertRaises(ModeError):
            ApplyGh(cfg_for(), grant(repo="acme/other"), runner=_support.FakeRunner())
        with self.assertRaises(ModeError):
            ApplyGh(cfg_for(repo=None), grant(), runner=_support.FakeRunner())

    def test_without_a_runner_the_real_gh_is_unreachable_from_tests(self):
        # positive control of the no-live-gh guard: a valid ApplyGh with no runner fails LOUDLY in a test
        gh = ApplyGh(cfg_for(), grant())
        with self.assertRaises(AssertionError) as raised:
            gh.edit_labels(1, ["type:bug"], [])
        self.assertIn("real gh", str(raised.exception))


class TestPerVerbFlags(unittest.TestCase):
    def test_a_flag_outside_the_verb_list_is_refused_with_zero_call(self):
        gh, runner = apply_gh()
        for verb, flags in (
            (("issue", "edit"), ["--web", "--assignee=me", "-R", "--repo=x/y", "--title=t", "--force", "--color=ffffff",
                                 "--description=d", "--body=b", "-a", "-e"]),
            (("label", "create"), ["--add-label=x", "--remove-label=x", "--force", "--web", "-R", "--repo=x/y"]),
        ):
            for flag in flags:
                with self.subTest(verb=verb, flag=flag), self.assertRaises(ModeError):
                    gh._run(verb, ["1", flag])
        self.assertEqual(runner.calls, [])

    def test_a_verb_outside_the_allow_list_is_refused(self):
        gh, runner = apply_gh()
        for verb in (("issue", "create"), ("issue", "close"), ("issue", "comment"), ("issue", "delete"), ("label", "edit"),
                     ("label", "delete"), ("label", "list"), ("issue", "list"), ("api", "x"), ("pr", "merge")):
            with self.subTest(verb=verb), self.assertRaises(ModeError):
                gh._run(verb, [])
        self.assertEqual(runner.calls, [])

    def test_the_repo_is_injected_exactly_once_and_last(self):
        gh, runner = apply_gh()
        gh.edit_labels(1, ["type:bug"], ["status:inbox"])
        gh.create_label("type:bug", "d73a4a", "a bug")
        for call in runner.calls:
            self.assertEqual(call[-2:], ["-R", "acme/widgets"])
            self.assertEqual(call.count("-R"), 1)
            self.assertEqual(call[0], "gh")


class TestEditLabels(unittest.TestCase):
    def test_add_then_remove_are_two_sequential_calls_in_that_order(self):
        gh, runner = apply_gh()
        gh.edit_labels(2, ["type:bug", "status:inbox"], ["bug"])
        self.assertEqual(runner.calls, [
            ["gh", "issue", "edit", "2", "--add-label=type:bug,status:inbox", "-R", "acme/widgets"],
            ["gh", "issue", "edit", "2", "--remove-label=bug", "-R", "acme/widgets"],
        ])

    def test_an_empty_side_makes_no_call(self):
        gh, runner = apply_gh()
        gh.edit_labels(1, ["type:bug"], [])
        gh.edit_labels(2, [], ["bug"])
        self.assertEqual([c[4].split("=")[0] for c in runner.calls], ["--add-label", "--remove-label"])
        with self.assertRaises(ModeError):
            gh.edit_labels(3, [], [])

    def test_the_issue_number_is_validated_and_must_be_granted(self):
        gh, runner = apply_gh()
        for bad in (0, -1, True, "5", "1", 1.0, None, 99):
            with self.subTest(issue=bad), self.assertRaises(ModeError):
                gh.edit_labels(bad, ["type:bug"], [])
        self.assertEqual(runner.calls, [])

    def test_label_names_are_validated_including_a_trailing_newline(self):
        gh, runner = apply_gh()
        for bad in ("", "-x", " x", "a b", "a,b", "a\n", "a\r", "../x", "x/y", "é\n", None, 5):
            with self.subTest(name=bad), self.assertRaises(ModeError):
                gh.edit_labels(1, [bad], [])
            with self.subTest(name=bad, side="remove"), self.assertRaises(ModeError):
                gh.edit_labels(1, [], [bad])
        self.assertEqual(runner.calls, [])

    def test_add_and_remove_must_be_disjoint_and_duplicate_free(self):
        gh, runner = apply_gh()
        for add, remove in ((["type:bug"], ["type:bug"]), (["type:bug", "type:bug"], []), ([], ["bug", "bug"])):
            with self.subTest(add=add, remove=remove), self.assertRaises(ModeError):
                gh.edit_labels(1, add, remove)
        self.assertEqual(runner.calls, [])

    def test_the_role_labels_can_never_be_added_but_can_be_removed(self):
        gh, runner = apply_gh()
        for name in ("status:ready", "exec:agent"):
            with self.subTest(name=name), self.assertRaises(ModeError):
                gh.edit_labels(1, [name], [])
        self.assertEqual(runner.calls, [])
        gh.edit_labels(1, [], ["status:ready", "exec:agent"])
        self.assertEqual(len(runner.calls), 1)

    def test_the_51st_distinct_issue_is_refused(self):
        numbers = range(1, 52)
        runner = _support.FakeRunner(issues=[_support.issue(n) for n in numbers])
        gh = ApplyGh(cfg_for(), grant(issues=numbers), runner=runner)
        for n in range(1, 51):
            gh.edit_labels(n, ["type:bug"], [])
        gh.edit_labels(1, [], ["bug"])  # an already-touched issue is not a new one
        with self.assertRaises(ModeError):
            gh.edit_labels(51, ["type:bug"], [])
        self.assertEqual(len({c[3] for c in runner.calls}), 50)

    def test_a_failed_remove_after_a_successful_add_is_reported_as_partial(self):
        runner = _support.FakeRunner(issues=[_support.issue(1)], fail_write_at=2)
        gh = ApplyGh(cfg_for(), grant(), runner=runner)
        with self.assertRaises(PartialApplyError):
            gh.edit_labels(1, ["type:bug"], ["bug"])
        runner = _support.FakeRunner(issues=[_support.issue(1)], fail_write_at=1)
        gh = ApplyGh(cfg_for(), grant(), runner=runner)
        with self.assertRaises(RuntimeError) as raised:
            gh.edit_labels(1, ["type:bug"], ["bug"])
        self.assertNotIsInstance(raised.exception, PartialApplyError)
        self.assertEqual(len(runner.calls), 1)  # the removal never ran

    def test_a_process_error_becomes_a_runtime_error(self):
        gh = ApplyGh(cfg_for(), grant(), runner=_support.FakeRunner(fail=subprocess.CalledProcessError(1, ["gh"])))
        with self.assertRaises(RuntimeError):
            gh.edit_labels(1, ["type:bug"], [])


class TestCreateLabel(unittest.TestCase):
    def test_argv_shape(self):
        gh, runner = apply_gh()
        gh.create_label("type:bug", "D73A4A")
        gh.create_label("status:inbox", "ededed", "intake")
        self.assertEqual(runner.calls, [
            ["gh", "label", "create", "type:bug", "--color=D73A4A", "-R", "acme/widgets"],
            ["gh", "label", "create", "status:inbox", "--color=ededed", "--description=intake", "-R", "acme/widgets"],
        ])

    def test_the_color_is_six_hex_characters_exactly(self):
        gh, runner = apply_gh()
        for bad in ("abcde", "abcdef0", "zzzzzz", "abcdef\n", "#abcdef", "", None, 123456):
            with self.subTest(color=bad), self.assertRaises(ModeError):
                gh.create_label("type:bug", bad)
        self.assertEqual(runner.calls, [])

    def test_the_name_must_be_granted_and_valid(self):
        gh, runner = apply_gh()
        for bad in ("size:L", "type:bug\n", "-x", "", "a b"):
            with self.subTest(name=bad), self.assertRaises(ModeError):
                gh.create_label(bad, "ededed")
        self.assertEqual(runner.calls, [])

    def test_the_description_is_bounded_and_control_free(self):
        gh, runner = apply_gh()
        for bad in ("x" * 101, "a\nb", "\x1b[31m", 5):
            with self.subTest(description=bad), self.assertRaises(ModeError):
                gh.create_label("type:bug", "ededed", bad)
        self.assertEqual(runner.calls, [])
        gh.create_label("type:bug", "ededed", "x" * 100)

    def test_at_most_fifty_creations_per_instance(self):
        names = ["l%d" % n for n in range(51)]
        runner = _support.FakeRunner()
        gh = ApplyGh(cfg_for(), grant(labels=names), runner=runner)
        for name in names[:50]:
            gh.create_label(name, "ededed")
        with self.assertRaises(ModeError):
            gh.create_label(names[50], "ededed")
        self.assertEqual(len(runner.calls), 50)


if __name__ == "__main__":
    unittest.main()
