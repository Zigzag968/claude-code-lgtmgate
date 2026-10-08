"""In-process tests can never reach the real `gh`: `_support` swaps the `subprocess` name of `backlog_gh`."""

import subprocess
import unittest

import _support
import backlog_config
import backlog_gh
from backlog_gh import Gh


class TestNoLiveGh(unittest.TestCase):
    def test_a_gh_without_a_runner_raises_instead_of_spawning(self):
        gh = Gh(backlog_config.default_config("propose", "acme/widgets"))
        with self.assertRaises(AssertionError) as raised:
            gh.fetch_issues()
        self.assertIn("real gh", str(raised.exception))
        with self.assertRaises(AssertionError):
            gh.fetch_labels()

    def test_a_gh_with_a_fake_runner_still_works(self):
        runner = _support.FakeRunner(issues=[_support.issue(1, "type:bug")])
        gh = Gh(backlog_config.default_config("propose"), runner=runner)
        self.assertEqual(len(gh.fetch_issues()), 1)

    def test_mode_off_is_still_refused_before_any_spawn(self):
        with self.assertRaises(backlog_gh.ModeError):
            Gh(backlog_config.default_config("off")).fetch_issues()

    def test_the_global_subprocess_run_is_untouched_and_the_error_type_is_shared(self):
        self.assertIs(backlog_gh.subprocess.CalledProcessError, subprocess.CalledProcessError)
        self.assertNotEqual(subprocess.run.__name__, "_refuse")  # run_cli() spawns real interpreters with it


if __name__ == "__main__":
    unittest.main()
