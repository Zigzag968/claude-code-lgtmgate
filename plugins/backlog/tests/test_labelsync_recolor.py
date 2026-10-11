"""`label-sync --apply` recolors a drifted label under the same gate as `create`. Fake `gh` only: no live repository."""

import re
import unittest

import _support
import backlog_labelsync


class TestLabelSyncRecolor(_support.ApplyBase):
    DRIFTED = "type:bug"
    MISSING = "type:chore"

    def setUp(self):
        super().setUp()
        self.spec = backlog_labelsync.spec_from_config(self.cfg)
        self.declared = {e["name"]: e["color"] for e in self.spec}
        self.directory, self.sha = self.take_snapshot([])

    def live(self):
        out = []
        for entry in self.spec:
            if entry["name"] == self.MISSING:
                continue
            color = "ffffff" if entry["name"] == self.DRIFTED else entry["color"]
            out.append({"name": entry["name"], "color": color, "description": ""})
        return out

    def runner(self):
        return self.new_runner([], labels=self.live())

    def run_sync(self, runner, apply=False, confirm=None, cfg=None):
        argv = ["--snapshot-dir", str(self.directory), "--expect-sha", self.sha]
        if apply:
            argv.append("--apply")
        if confirm:
            argv += ["--confirm", confirm]
        return self.call(backlog_labelsync.main, argv, runner, cfg=cfg)

    def digest(self, runner=None):
        rc, out = self.run_sync(runner or self.runner())
        self.assertEqual(rc, 0, out)
        return re.search(r"table-digest: ([0-9a-f]{16})", out).group(1), out

    def test_dry_run_names_the_recolor_and_writes_nothing(self):
        runner = self.runner()
        _, out = self.digest(runner)
        self.assertIn("[label-sync] recolor %s" % self.DRIFTED, out)
        self.assertIn("create=1 ok=%d recolor=1" % (len(self.spec) - 2), out)
        self.assertNotIn("] drift ", out)
        self.assertEqual(runner.writes(), [])

    def test_apply_recolors_the_drifted_label_creates_the_missing_one_and_a_second_run_is_clean(self):
        runner = self.runner()
        digest, _ = self.digest(runner)
        rc, out = self.run_sync(runner, apply=True, confirm=digest)
        self.assertEqual(rc, 0, out)
        self.assertEqual(
            [c[1:] for c in runner.writes()],
            [
                ["label", "create", self.MISSING, "--color=" + self.declared[self.MISSING], "-R", "acme/widgets"],
                ["label", "edit", self.DRIFTED, "--color=" + self.declared[self.DRIFTED], "-R", "acme/widgets"],
            ],
        )
        self.assertIn("[label-sync] recolored %s" % self.DRIFTED, out)
        self.assertIn("[label-sync] created %s" % self.MISSING, out)
        by_name = {e["name"]: e for e in runner.labels if isinstance(e, dict)}
        self.assertEqual(by_name[self.DRIFTED]["color"], self.declared[self.DRIFTED])
        # the fake gh round-trips the edit: a fresh dry run now sees nothing to do
        _, again = self.digest(runner)
        self.assertIn("create=0 ok=%d recolor=0" % len(self.spec), again)

    def test_the_confirm_digest_binds_the_recolor(self):
        with_drift, _ = self.digest()
        no_drift_runner = self.new_runner([], labels=[dict(e, color=self.declared[e["name"]]) for e in self.live()])
        without_drift, _ = self.digest(no_drift_runner)
        self.assertNotEqual(with_drift, without_drift)
        runner = self.runner()
        rc, out = self.run_sync(runner, apply=True, confirm=without_drift)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: confirm", out)
        self.assertEqual(runner.writes(), [])

    def test_propose_and_off_modes_refuse_with_zero_write(self):
        for mode in ("propose", "off"):
            with self.subTest(mode=mode):
                runner = self.runner()
                rc, out = self.run_sync(runner, apply=True, confirm="0" * 16, cfg=self.make_cfg(mode))
                self.assertEqual(rc, 1, out)
                self.assertIn("refused: mode", out)
                self.assertEqual(runner.writes(), [])

    def test_a_failing_recolor_stops_with_an_error_and_is_not_journaled(self):
        runner = self.runner()
        digest, _ = self.digest(runner)
        runner.fail_write_at = 2  # the create is write 1 and succeeds, the recolor is write 2 and fails
        rc, out = self.run_sync(runner, apply=True, confirm=digest)
        self.assertEqual(rc, 1, out)
        self.assertIn("error: %s" % self.DRIFTED, out)
        self.assertIn("stopped: applied=1 remaining=1", out)

    def test_the_recolor_only_touches_the_declared_label_and_never_a_rename(self):
        runner = self.runner()
        digest, _ = self.digest(runner)
        self.run_sync(runner, apply=True, confirm=digest)
        for call in runner.writes():
            self.assertNotIn("--name", " ".join(call))
            self.assertNotIn("--new-name", " ".join(call))


if __name__ == "__main__":
    unittest.main()
