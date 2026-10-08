import contextlib
import io
import json
import unittest
from pathlib import Path

import _support
import backlog_config
import backlog_labelsync
from backlog_gh import Gh

CFG = backlog_config.default_config("propose", "acme/widgets")


def run(argv, cfg=CFG, gh=None):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = backlog_labelsync.main(argv, cfg, gh)
    return rc, buf.getvalue()


def live(name, color="ededed", description=""):
    return {"name": name, "color": color, "description": description}


class TestSpec(unittest.TestCase):
    def test_one_label_per_axis_value_in_axis_order(self):
        names = [e["name"] for e in backlog_labelsync.spec_from_config(CFG)]
        self.assertEqual(names[:4], ["type:bug", "type:feature", "type:chore", "type:epic"])
        self.assertEqual(len(names), 4 + 3 + 3 + 2 + 3)  # area is empty: nothing to declare
        self.assertEqual(len(set(names)), len(names))

    def test_colors_come_from_the_config_with_a_grey_default(self):
        with _support.tmpdir() as tmp:
            _support.write_config(tmp, 'contract: 1\nmode: propose\nlabel_colors:\n  type: "D73A4A"\n')
            cfg = backlog_config.load_config(tmp)
        colors = {e["name"]: e["color"] for e in backlog_labelsync.spec_from_config(cfg)}
        self.assertEqual(colors["type:bug"], "d73a4a")
        self.assertEqual(colors["size:S"], backlog_config.DEFAULT_LABEL_COLOR)


class TestPlan(unittest.TestCase):
    def test_create_ok_and_drift_with_case_insensitive_matching(self):
        spec = [{"name": "type:bug", "color": "d73a4a", "description": ""},
                {"name": "type:feature", "color": "0e8a16", "description": ""},
                {"name": "type:chore", "color": "ededed", "description": ""}]
        current = [live("TYPE:BUG", "D73A4A"), live("type:feature", "ffffff", "ignored description")]
        kinds = {a.name: a.kind for a in backlog_labelsync.plan(spec, current)}
        self.assertEqual(kinds, {"type:bug": "ok", "type:feature": "drift", "type:chore": "create"})

    def test_unmanaged_lists_only_labels_outside_the_spec(self):
        spec = [{"name": "type:bug", "color": "d73a4a", "description": ""}]
        self.assertEqual(backlog_labelsync.unmanaged(spec, [live("type:bug"), live("nightly"), live("bug")]), ["bug", "nightly"])

    def test_a_label_without_a_color_is_drift(self):
        spec = [{"name": "type:bug", "color": "d73a4a", "description": ""}]
        self.assertEqual(backlog_labelsync.plan(spec, [{"name": "type:bug"}])[0].kind, "drift")


class TestCli(unittest.TestCase):
    def test_offline_plan_output_and_summary(self):
        with _support.tmpdir() as tmp:
            path = Path(tmp) / "live.json"
            path.write_text(json.dumps([live("type:bug"), live("type:feature", "0e8a16"), live("legacy-thing")]))
            rc, out = run(["--live-file", str(path)])
        self.assertEqual(rc, 0)
        self.assertIn("[label-sync] ok type:bug", out)
        self.assertIn("[label-sync] drift type:feature", out)
        self.assertIn("[label-sync] create type:chore", out)
        self.assertIn("dry-run: create=13 ok=1 drift=1 unmanaged=1 (nothing written; --apply creates the missing labels, see the README)", out)

    def test_live_read_goes_through_fetch_labels_with_all_fields(self):
        runner = _support.FakeRunner(labels=[live("type:bug", "d73a4a", "bad"), "nightly"])
        rc, out = run([], gh=Gh(CFG, runner=runner))
        self.assertEqual(rc, 0, out)
        self.assertEqual(runner.verbs(), [("label", "list")])
        argv = runner.calls[0]
        self.assertIn("name,color,description", argv)
        self.assertEqual(argv[-2:], ["-R", "acme/widgets"])
        self.assertIn("unmanaged=1", out)  # the plain-string label `nightly`

    def test_a_truncated_label_list_fails_closed(self):
        runner = _support.FakeRunner(labels=[live("l%d" % i) for i in range(200)])
        rc, out = run([], gh=Gh(CFG, runner=runner))
        self.assertEqual(rc, 1)
        self.assertIn("possible silent truncation", out)

    def test_a_gh_failure_is_an_error_not_an_empty_plan(self):
        rc, out = run([], gh=Gh(CFG, runner=_support.FakeRunner(fail=FileNotFoundError("gh"))))
        self.assertEqual(rc, 1)
        self.assertIn("[label-sync] error:", out)

    def test_the_repo_flag_is_an_assertion(self):
        with _support.tmpdir() as tmp:
            path = Path(tmp) / "live.json"
            path.write_text("[]")
            rc, out = run(["--live-file", str(path), "--repo", "acme/other"])
            self.assertEqual(rc, 1)
            self.assertIn("does not match", out)
            rc, _ = run(["--live-file", str(path), "--repo", "acme/widgets"])
            self.assertEqual(rc, 0)
            rc, out = run(["--live-file", str(path), "--repo", "acme/widgets"], cfg=backlog_config.default_config("propose"))
            self.assertEqual(rc, 1)
            self.assertIn("`repo:` is absent", out)

    def test_apply_flags_exist_but_no_rename_or_edit_flag_does(self):
        for flag in (["--apply"], ["--confirm", "x"], ["--snapshot-dir", "d"], ["--expect-sha", "x"]):
            with self.subTest(flag=flag):
                backlog_labelsync.build_parser().parse_args(flag)
        for flag in (["--allow-rename"], ["--update"], ["--delete"]):
            with self.subTest(flag=flag), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    backlog_labelsync.build_parser().parse_args(flag)
                self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
