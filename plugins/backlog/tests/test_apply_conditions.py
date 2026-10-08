"""The six apply conditions (mode, repo, apply, confirm, snapshot, rejected): each missing one is exit 1 and ZERO write
call, for `label-sync`, `catchup check` and `rollback`. Drives the real commands in-process against a FakeRunner that
plays GitHub, so a write that slipped through would show in `runner.writes()`."""

import shutil
import unittest

import _support
import backlog_apply
import backlog_catchup
import backlog_labelsync
import backlog_snapshot

COMMANDS = ("catchup", "rollback", "label-sync")
GOOD = "good"


class World(_support.ApplyBase):
    """Two `bug` issues frozen in a snapshot; what each command would do on the live state is prepared per command."""

    def prepare(self, command):
        base = self.bug_issues(2)
        self._prepared = getattr(self, "_prepared", 0) + 1
        directory, sha = self.take_snapshot(self._copy.deepcopy(base), target=self.tmp / "snaps" / ("s%d" % self._prepared))
        self.dir, self.sha = directory, sha
        self.__dict__.pop("_digest", None)
        if command == "catchup":
            live, labels = self._copy.deepcopy(base), None
        elif command == "rollback":  # the live labels drifted from the snapshot: there is something to restore
            live, labels = self.bug_issues(2, labels=("type:bug", "status:inbox")), None
        else:
            live, labels = [], []  # no label exists yet: every label of the config is a `create`
        self.command = command
        self.runner = self.runner_for(live, labels)
        self.proposals = self.proposals_file([_support.proposal(1), _support.proposal(2)])

    def runner_for(self, live, labels):
        return self.new_runner(live, labels=labels)

    def argv(self, directory=GOOD, sha=GOOD, apply=True, confirm=GOOD):
        directory = self.dir if directory == GOOD else directory
        sha = self.sha if sha == GOOD else sha
        args = []
        if self.command == "catchup":
            args += ["check", "--proposals", str(self.proposals)]
        if directory is not None:
            args += ["--snapshot-dir", str(directory)]
        if sha is not None:
            args += ["--expect-sha", sha]
        if apply:
            args.append("--apply")
        if confirm is not None:
            args += ["--confirm", self.good_digest() if confirm == GOOD else confirm]
        return args

    def fn(self):
        return {"catchup": backlog_catchup.main, "rollback": backlog_snapshot.main_rollback, "label-sync": backlog_labelsync.main}[self.command]

    def good_digest(self):
        if not hasattr(self, "_digest"):
            probe = self.runner_for(self._copy.deepcopy(self.runner.issues), list(self.runner.labels))
            rc, out = self.call(self.fn(), self.argv(apply=False, confirm=None), probe)
            assert rc == 0, out
            self._digest = self.digest(out)
        return self._digest

    def dry_digest_for(self, command, sha, digest_only=False):
        """The digest a dry run prints when `--expect-sha` is `sha` (bound to it even if it is wrong)."""
        probe = self.runner_for(self._copy.deepcopy(self.runner.issues), list(self.runner.labels))
        argv = self.argv(sha=sha, apply=False, confirm=None)
        rc, out = self.call(self.fn(), argv, probe)
        return self.digest(out) if digest_only else out

    def refuse(self, command, code, cfg=None, **kw):
        """One refusal: exit 1, the code named on the output, and not a single write verb ever reached gh."""
        self.prepare(command)
        rc, out = self.call(self.fn(), self.argv(**kw), self.runner, cfg=cfg)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: %s" % code, out)
        self.assertEqual(self.runner.writes(), [], out)
        return out


class TestConditions(World):
    def test_refused_mode(self):
        propose = self.make_cfg("propose")
        for command in COMMANDS:
            with self.subTest(command=command):
                self.refuse(command, "mode", cfg=propose)

    def test_refused_repo(self):
        no_repo = self.make_cfg(repo=None)
        for command in COMMANDS:
            with self.subTest(command=command):
                self.prepare(command)
                rc, out = self.call(self.fn(), self.argv(), self.runner, cfg=no_repo)
                self.assertEqual(rc, 1, out)
                self.assertRegex(out, r"refused: repo|`repo:` is required")  # rollback keeps its S1 message
                self.assertEqual(self.runner.calls, [])  # not even a read of an ambiguous repo

    def test_refused_apply(self):
        for command in COMMANDS:
            with self.subTest(command=command):
                self.refuse(command, "apply", apply=False)  # --confirm without --apply
        for command in COMMANDS:
            with self.subTest(command=command, dry_run=True):
                self.prepare(command)
                rc, out = self.call(self.fn(), self.argv(apply=False, confirm=None), self.runner)
                self.assertEqual(rc, 0, out)
                self.assertIn("dry-run", out)
                self.assertEqual(self.runner.writes(), [])

    def test_refused_confirm(self):
        for command in COMMANDS:
            for label, confirm in (("absent", None), ("wrong", "0" * 16), ("empty", "")):
                with self.subTest(command=command, confirm=label):
                    self.refuse(command, "confirm", confirm=confirm)

    def test_the_digest_without_a_snapshot_binding_is_not_accepted(self):
        self.prepare("catchup")
        import backlog_triage

        s1 = backlog_catchup.catchup_digest(backlog_triage.parse_proposals([_support.proposal(1), _support.proposal(2)]), "acme/widgets")
        rc, out = self.call(backlog_catchup.main, self.argv(confirm=s1), self.runner)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: confirm", out)
        self.assertEqual(self.runner.writes(), [])

    def test_refused_snapshot(self):
        for command in COMMANDS:
            with self.subTest(command=command, why="no snapshot flags"):
                self.prepare(command)
                rc, out = self.call(self.fn(), self.argv(directory=None, sha=None, confirm="0" * 16) if command != "rollback"
                                    else ["--snapshot-dir", str(self.tmp / "nope"), "--expect-sha", "x", "--apply", "--confirm", "x"],
                                    self.runner)
                self.assertEqual(rc, 1, out)
                self.assertRegex(out, r"refused: (snapshot|confirm)")
                self.assertEqual(self.runner.writes(), [])
            with self.subTest(command=command, why="wrong sha"):
                self.prepare(command)
                wrong = "0" * 64  # a catch-up / label-sync digest is bound to the sha: confirm the digest of the wrong one
                digest = self.good_digest() if command == "rollback" else self.dry_digest_for(command, wrong, True)
                rc, out = self.call(self.fn(), self.argv(sha=wrong, confirm=digest), self.runner)
                self.assertEqual(rc, 1, out)
                self.assertIn("refused: snapshot", out)
                self.assertIn("sha256 mismatch", out)
                self.assertEqual(self.runner.writes(), [])
            with self.subTest(command=command, why="another repo"):
                self.prepare(command)
                other_cfg = self.make_cfg(repo="acme/other")
                other_dir, other_sha = self.take_snapshot([], cfg=other_cfg, target=self.tmp / "snaps" / ("other%d" % self._prepared))
                digest = backlog_snapshot.rollback_digest([], "acme/widgets") if command == "rollback" else self.dry_digest_for(command, other_sha, True)
                rc, out = self.call(self.fn(), self.argv(directory=other_dir, sha=other_sha, confirm=digest), self.runner)
                self.assertEqual(rc, 1, out)
                self.assertIn("refused: snapshot", out)
                self.assertIn("belongs to acme/other", out)
                self.assertEqual(self.runner.writes(), [])
            with self.subTest(command=command, why="inside the repo"):
                self.prepare(command)
                inside = self.dir_inside_the_repo()
                digest = self.dry_digest_for(command, self.sha, True) if command != "rollback" else self.good_digest()
                rc, out = self.call(self.fn(), self.argv(directory=inside, confirm=digest), self.runner)
                self.assertEqual(rc, 1, out)
                self.assertIn("refused: snapshot", out)
                self.assertIn("OUTSIDE the repo", out)
                self.assertEqual(self.runner.writes(), [])

    def dir_inside_the_repo(self):
        project = backlog_apply.project_dir_of(self.cfg)
        target = project / ("snapshots-in-repo-%d" % self._prepared)
        shutil.copytree(str(self.dir), str(target))
        return target

    def test_refused_snapshot_when_the_snapshot_does_not_cover_a_proposed_issue(self):
        self.prepare("catchup")
        self.proposals = self.proposals_file([_support.proposal(1), _support.proposal(2), _support.proposal(3)])
        self.runner.issues.append(_support.issue(3, "bug"))  # opened after the snapshot
        rc, out = self.call(backlog_catchup.main, self.argv(confirm=self.dry_digest_for("catchup", self.sha, True)), self.runner)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: snapshot", out)
        self.assertIn("#3 is not in the snapshot", out)
        self.assertEqual(self.runner.writes(), [])

    def test_refused_snapshot_when_the_labels_changed_since_the_snapshot(self):
        self.prepare("catchup")
        self.proposals = self.proposals_file([_support.proposal(1, before=("bug", "nightly"), after=("nightly", "status:inbox", "type:bug")),
                                              _support.proposal(2)])
        self.runner.issues[0]["labels"].append({"name": "nightly"})  # relabelled after the snapshot
        rc, out = self.call(backlog_catchup.main, self.argv(confirm=self.dry_digest_for("catchup", self.sha, True)), self.runner)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: snapshot", out)
        self.assertIn("#1 changed since the snapshot", out)
        self.assertEqual(self.runner.writes(), [])

    def test_refused_rejected(self):
        role = _support.proposal(1, after=("status:ready", "exec:agent", "type:bug", "size:S", "priority:1-next"))
        cases = {
            "role-add-refused": (lambda w: None, [role, _support.proposal(2)]),
            "stale-before": (lambda w: w.runner.issues[1]["labels"].append({"name": "size:L"}), [_support.proposal(1), _support.proposal(2)]),
            "issue-not-open": (lambda w: w.runner.issues[1].update(state="CLOSED"), [_support.proposal(1), _support.proposal(2)]),
        }
        for code, (mutate, entries) in cases.items():
            with self.subTest(code=code):
                self.prepare("catchup")
                self.proposals = self.proposals_file(entries, name="p-%s.json" % code)
                mutate(self)
                # the snapshot still covers the issues: only the LIVE validation rejects
                digest = self.dry_digest_for("catchup", self.sha, True)
                rc, out = self.call(backlog_catchup.main, self.argv(confirm=digest), self.runner)
                self.assertEqual(rc, 1, out)
                self.assertIn("refused: rejected", out)
                self.assertIn(code, out)
                self.assertEqual(self.runner.writes(), [])

    def test_check_gate_refuses_rejections_on_its_own_too(self):
        with self.assertRaises(backlog_apply.RefusedError) as raised:
            backlog_apply.check_gate(self.cfg, apply=True, confirm="d", digest="d", verify=lambda: "sha", rejected=1)
        self.assertEqual(raised.exception.code, "rejected")

    def test_the_six_codes_are_the_documented_ones(self):
        self.assertEqual(backlog_apply.CODES, ("mode", "repo", "apply", "confirm", "snapshot", "rejected"))

    def test_check_gate_orders_the_conditions_mode_first(self):
        propose = self.make_cfg("propose")
        for kw in ({"apply": False}, {"apply": True, "confirm": None}):
            with self.subTest(kw=kw), self.assertRaises(backlog_apply.RefusedError) as raised:
                backlog_apply.check_gate(propose, confirm=kw.get("confirm", "d"), digest="d", verify=lambda: "sha", rejected=1, apply=kw["apply"])
            self.assertEqual(raised.exception.code, "mode")

    def test_the_apply_path_refuses_offline_inputs(self):
        self.prepare("catchup")
        rc, out = self.call(backlog_catchup.main, self.argv() + ["--issues-file", str(self.tmp / "x.json"), "--labels-file", str(self.tmp / "y.json")], self.runner)
        self.assertEqual(rc, 1, out)
        self.assertIn("refused: apply", out)
        self.assertEqual(self.runner.calls, [])


class TestFreeWaivesNothing(World):
    MODE = "free"

    def test_free_still_needs_apply_confirm_and_a_snapshot(self):
        for command in COMMANDS:
            with self.subTest(command=command, missing="apply"):
                self.refuse(command, "apply", apply=False)
            with self.subTest(command=command, missing="confirm"):
                self.refuse(command, "confirm", confirm=None)
            with self.subTest(command=command, missing="confirm (wrong)"):
                self.refuse(command, "confirm", confirm="0" * 16)
            with self.subTest(command=command, missing="snapshot"):
                self.prepare(command)
                digest = self.good_digest() if command == "rollback" else self.dry_digest_for(command, "0" * 64, True)
                rc, out = self.call(self.fn(), self.argv(sha="0" * 64, confirm=digest), self.runner)
                self.assertEqual(rc, 1, out)
                self.assertIn("refused: snapshot", out)
                self.assertEqual(self.runner.writes(), [])


class TestPositiveControl(World):
    """The refusals above prove something only if the same setup DOES write once every condition holds."""

    def test_every_condition_met_writes_in_both_writing_modes(self):
        for mode in ("write-supervised", "free"):
            for command in COMMANDS:
                with self.subTest(mode=mode, command=command):
                    self.prepare(command)
                    rc, out = self.call(self.fn(), self.argv(), self.runner, cfg=self.make_cfg(mode))
                    self.assertEqual(rc, 0, out)
                    self.assertGreater(len(self.runner.writes()), 0, out)
                    for call in self.runner.writes():
                        self.assertEqual(call[-2:], ["-R", "acme/widgets"])


if __name__ == "__main__":
    unittest.main()
