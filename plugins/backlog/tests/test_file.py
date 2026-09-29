import contextlib
import io
import re
import unittest

import _support as S
import backlog_config as C
from backlog_file import final_labels, main, normalize_title, payload_digest, validate_intake
from backlog_gh import Gh

REPO_LABELS = {"type:bug", "type:feature", "type:chore", "type:epic", "status:inbox", "status:ready",
               "priority:0-now", "priority:1-next", "area:web", "size:S"}


def cfg_for(mode):
    return C.default_config(mode)


def codes(title="A clear title", body="body", labels=("type:bug",), issues=(), repo_labels=REPO_LABELS, mode="propose"):
    return validate_intake(title, body, list(labels), cfg_for(mode), list(issues), repo_labels)


class TestValidate(unittest.TestCase):
    def test_a_good_payload_is_accepted(self):
        self.assertEqual(codes(), [])

    def test_rejections_each_with_a_positive_twin(self):
        cases = [
            ("title-empty", dict(title="   "), dict(title="ok")),
            ("title-multiline", dict(title="a\nb"), dict(title="a b")),
            ("title-too-long", dict(title="x" * 257), dict(title="x" * 256)),
            ("lint:type-missing", dict(labels=()), dict(labels=("type:bug",))),
            ("lint:type-multiple", dict(labels=("type:bug", "type:chore")), dict(labels=("type:bug",))),
            ("status-not-intake", dict(labels=("type:bug", "status:ready")), dict(labels=("type:bug", "status:inbox"))),
            ("protected-label", dict(labels=("type:bug", "nightly")), dict(labels=("type:bug",))),
            ("protected-label", dict(labels=("type:bug", "auto:pr-ready")), dict(labels=("type:bug",))),
            ("flag-not-allowed", dict(labels=("type:bug", "money-path")), dict(labels=("type:bug",))),
            ("unknown-label", dict(labels=("type:bug", "wontfix")), dict(labels=("type:bug", "area:web"))),
            ("unknown-label", dict(labels=("type:bug", "priority:9-never")), dict(labels=("type:bug", "priority:1-next"))),
            ("label-missing-in-repo:type:bug", dict(repo_labels={"status:inbox"}), dict(repo_labels=REPO_LABELS)),
        ]
        for code, bad, good in cases:
            with self.subTest(code=code, bad=bad):
                self.assertIn(code, codes(**bad))
                self.assertNotIn(code, codes(**good))

    def test_free_axis_area_labels_pass(self):
        self.assertEqual(codes(labels=("type:bug", "area:anything-at-all"), repo_labels=None), [])

    def test_intake_required_default_only_needs_type(self):
        self.assertEqual(codes(labels=("type:bug",)), [])

    def test_intake_required_refuses_a_missing_required_axis(self):
        cfg = C.replace(cfg_for("propose"), intake_required=("type", "priority"))
        codes_missing = validate_intake("A clear title", "body", ["type:bug"], cfg, [], REPO_LABELS)
        self.assertIn("priority-missing", codes_missing)
        codes_present = validate_intake("A clear title", "body", ["type:bug", "priority:0-now"], cfg, [], REPO_LABELS)
        self.assertNotIn("priority-missing", codes_present)

    def test_intake_required_missing_type_does_not_duplicate_lints_own_code(self):
        # type is already refused unconditionally by lint(); the default `intake_required: [type]` must not add
        # a second, differently-spelled code for the same miss
        cfg = C.replace(cfg_for("propose"), intake_required=("type",))
        codes_missing = validate_intake("A clear title", "body", [], cfg, [], REPO_LABELS)
        self.assertNotIn("type-missing", codes_missing)
        self.assertIn("lint:type-missing", codes_missing)
        self.assertEqual(codes_missing, codes(labels=()))

    def test_status_is_forced_to_intake(self):
        self.assertEqual(final_labels(["type:bug"], cfg_for("propose")), ["type:bug", "status:inbox"])
        self.assertEqual(final_labels(["type:bug", "status:inbox"], cfg_for("propose")), ["type:bug", "status:inbox"])

    def test_priority_cap_would_be_exceeded(self):
        open_issues = [S.issue(n, "type:chore", "status:inbox", "priority:0-now") for n in (1, 2)]
        self.assertIn("cap-exceeded:priority:0-now", codes(labels=("type:bug", "priority:0-now"), issues=open_issues))
        self.assertNotIn("cap-exceeded:priority:0-now", codes(labels=("type:bug", "priority:0-now"), issues=open_issues[:1]))
        closed = [S.issue(n, "type:chore", "status:inbox", "priority:0-now", state="CLOSED") for n in (1, 2, 3)]
        self.assertNotIn("cap-exceeded:priority:0-now", codes(labels=("type:bug", "priority:0-now"), issues=closed))

    def test_duplicate_title_of_an_open_issue(self):
        open_issue = S.issue(42, "type:bug", "status:inbox", title="Login  button -- broken!")
        self.assertIn("duplicate-of:#42", codes(title="login button broken", issues=[open_issue]))
        closed = S.issue(42, "type:bug", "status:inbox", title="Login button broken", state="CLOSED")
        self.assertNotIn("duplicate-of:#42", codes(title="login button broken", issues=[closed]))
        self.assertNotIn("duplicate-of:#42", codes(title="something else", issues=[open_issue]))

    def test_normalize_title(self):
        self.assertEqual(normalize_title("  Fix: the  THING!! "), "fix the thing")

    def test_digest_is_stable_and_sensitive(self):
        base = payload_digest("t", "b", ["type:bug", "status:inbox"], "o/r")
        self.assertEqual(base, payload_digest("t", "b", ["status:inbox", "type:bug"], "o/r"))
        self.assertRegex(base, r"^[0-9a-f]{16}$")
        for changed in (
            payload_digest("t2", "b", ["type:bug", "status:inbox"], "o/r"),
            payload_digest("t", "b2", ["type:bug", "status:inbox"], "o/r"),
            payload_digest("t", "b", ["type:chore", "status:inbox"], "o/r"),
            payload_digest("t", "b", ["type:bug", "status:inbox"], "o/other"),
        ):
            self.assertNotEqual(base, changed)


def run_main(argv, mode, runner=None):
    runner = runner or S.FakeRunner(labels=sorted(REPO_LABELS))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = main(argv, cfg_for(mode), Gh(cfg_for(mode), runner=runner))
    return rc, out.getvalue(), runner


def creates(runner):
    return [c for c in runner.calls if c[1:3] == ["issue", "create"]]


ARGS = ["--title", "A clear title", "--body", "b", "--label", "type:bug"]


class TestModes(unittest.TestCase):
    def digest(self, mode):
        _, out, _ = run_main(ARGS, mode)
        return re.search(r"payload-digest=([0-9a-f]{16})", out).group(1)

    def test_dry_run_never_creates_in_any_mode(self):
        for mode in ("propose", "write-supervised", "free"):
            with self.subTest(mode=mode):
                rc, out, runner = run_main(ARGS, mode)
                self.assertEqual(rc, 0)
                self.assertIn("verdict=ok", out)
                self.assertIn("dry-run: nothing created", out)
                self.assertEqual(creates(runner), [])

    def test_propose_never_creates_even_with_apply(self):
        rc, out, runner = run_main(ARGS + ["--apply"], "propose")
        self.assertEqual(rc, 0)
        self.assertIn("proposal only", out)
        self.assertEqual(creates(runner), [])

    def test_write_supervised_needs_the_matching_digest(self):
        rc, out, runner = run_main(ARGS + ["--apply"], "write-supervised")
        self.assertEqual(rc, 1)
        self.assertEqual(creates(runner), [])
        rc, out, runner = run_main(ARGS + ["--apply", "--confirm", "0123456789abcdef"], "write-supervised")
        self.assertEqual(rc, 1)
        self.assertEqual(creates(runner), [])
        rc, out, runner = run_main(ARGS + ["--apply", "--confirm", self.digest("write-supervised")], "write-supervised")
        self.assertEqual(rc, 0, out)
        self.assertIn("created https://github.com/o/r/issues/1", out)
        self.assertEqual(len(creates(runner)), 1)

    def test_confirm_of_another_payload_is_refused(self):
        other = ["--title", "Another title", "--body", "b", "--label", "type:bug"]
        _, out, _ = run_main(other, "write-supervised")
        stale = re.search(r"payload-digest=([0-9a-f]{16})", out).group(1)
        rc, _, runner = run_main(ARGS + ["--apply", "--confirm", stale], "write-supervised")
        self.assertEqual(rc, 1)
        self.assertEqual(creates(runner), [])

    def test_free_creates_with_apply_and_forced_status(self):
        rc, out, runner = run_main(ARGS + ["--apply"], "free")
        self.assertEqual(rc, 0, out)
        argv = creates(runner)[0]
        self.assertIn("--label=status:inbox", argv)
        self.assertIn("--label=type:bug", argv)

    def test_a_refused_payload_is_never_created(self):
        for mode in ("write-supervised", "free"):
            with self.subTest(mode=mode):
                rc, out, runner = run_main(["--title", "t", "--label", "type:bug", "--label", "money-path", "--apply"], mode)
                self.assertEqual(rc, 1)
                self.assertIn("verdict=refused", out)
                self.assertIn("flag-not-allowed", out)
                self.assertEqual(creates(runner), [])

    def test_offline_inputs_are_dry_run_only(self):
        with S.tmpdir() as tmp:
            issues = S.Path(tmp) / "i.json"
            issues.write_text("[]")
            rc, out, runner = run_main(ARGS + ["--issues-file", str(issues), "--apply"], "free")
        self.assertEqual(rc, 1)
        self.assertIn("dry-run only", out)
        self.assertEqual(runner.calls, [])

    def test_fetch_failure_is_an_error_not_a_verdict(self):
        rc, out, runner = run_main(ARGS, "propose", S.FakeRunner(fail=FileNotFoundError("gh")))
        self.assertEqual(rc, 1)
        self.assertIn("error", out)
        self.assertNotIn("verdict=ok", out)

    def test_body_file_is_read(self):
        with S.tmpdir() as tmp:
            body = S.Path(tmp) / "b.md"
            body.write_text("from a file")
            _, out_file, _ = run_main(["--title", "A clear title", "--body-file", str(body), "--label", "type:bug"], "propose")
        _, out_inline, _ = run_main(["--title", "A clear title", "--body", "from a file", "--label", "type:bug"], "propose")
        self.assertEqual(out_file, out_inline)

    def test_missing_body_file_is_an_error(self):
        rc, out, _ = run_main(["--title", "t", "--body-file", "/nonexistent/body.md"], "propose")
        self.assertEqual(rc, 1)
        self.assertIn("error", out)


if __name__ == "__main__":
    unittest.main()
