"""Shared test helpers: path setup, a config writer, a fake `gh` shim and a fake wrapper runner.

Nothing here touches the real `gh`, the network, or anything outside `tempfile` directories.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import types
from pathlib import Path

sys.dont_write_bytecode = True

TESTS = Path(__file__).resolve().parent
PLUGIN_ROOT = TESTS.parent
SCRIPTS = PLUGIN_ROOT / "scripts"
FIXTURES = TESTS / "fixtures"
CLI = SCRIPTS / "backlog_cli.py"
GUARD_HOOK = PLUGIN_ROOT / "hooks" / "backlog-gh-guard.sh"

if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def install_no_live_gh():
    """Make a real `gh` unreachable from IN-PROCESS tests: `backlog_gh` (the only module that spawns a process)
    gets a stand-in for its `subprocess` name whose `run` raises. A `Gh` built without a `runner=` therefore fails
    loudly instead of calling the real CLI. The global `subprocess.run` is left alone (`run_cli` needs it), and
    CLI subprocesses are covered by the fake `gh` shim on PATH instead."""
    import backlog_gh

    def _refuse(*args, **kwargs):
        raise AssertionError("a test reached the real gh: pass a runner= (FakeRunner) to Gh")

    backlog_gh.subprocess = types.SimpleNamespace(run=_refuse, CalledProcessError=subprocess.CalledProcessError)


install_no_live_gh()

MINIMAL_CONFIG = "contract: 1\nmode: {mode}\n"


def tmpdir():
    return tempfile.TemporaryDirectory(prefix="backlog-test-")


def write_config(project_dir, text):
    path = Path(project_dir) / ".claude" / "backlog.yml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def write_mode(project_dir, mode):
    return write_config(project_dir, MINIMAL_CONFIG.format(mode=mode))


def write_repo_config(project_dir, repo="acme/widgets", mode="propose", extra=""):
    """A config with a `repo:` (required by every subcommand that names local state after the repo)."""
    return write_config(project_dir, "contract: 1\nmode: %s\nrepo: %s\n%s" % (mode, repo, extra))


def fake_gh(bin_dir):
    """Install a `gh` shim in bin_dir that appends its argv to <bin_dir>/gh.log and prints `[]`.
    Returns the log path. The shim proves (by its log staying empty) that no gh call was made."""
    bin_dir = Path(bin_dir)
    bin_dir.mkdir(parents=True, exist_ok=True)
    log = bin_dir / "gh.log"
    shim = bin_dir / "gh"
    shim.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(log) + '"\nprintf "[]\\n"\n')
    shim.chmod(shim.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return log


def gh_calls(log):
    log = Path(log)
    return log.read_text().splitlines() if log.exists() else []


def cli_env(bin_dir=None, extra=None):
    """Environment for a CLI/hook subprocess: no CLAUDE_PROJECT_DIR, the fake gh first on PATH."""
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT")}
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if bin_dir is not None:
        env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    env.update(extra or {})
    return env


def run_cli(args, cwd, env):
    return subprocess.run(
        [sys.executable, "-B", str(CLI)] + list(args), cwd=str(cwd), env=env, capture_output=True, text=True
    )


class FakeRunner:
    """Stands in for the process runner of `Gh`: records argv, answers per verb pair."""

    WRITE_VERBS = (("issue", "edit"), ("label", "create"))

    def __init__(self, issues=None, prs=None, labels=None, create_url="https://github.com/o/r/issues/1\n", fail=None,
                 fail_write_at=None, before_write=None):
        self.calls = []
        self.fail_write_at = fail_write_at  # 1-based number of the write call that fails
        self.before_write = before_write  # called with argv before each write is applied
        self.issues = [] if issues is None else issues
        self.prs = [] if prs is None else prs
        self.labels = [] if labels is None else labels
        self.create_url = create_url
        self.fail = fail

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        if self.fail is not None:
            raise self.fail
        verb = tuple(argv[1:3])
        if verb == ("issue", "list"):
            out = json.dumps(self.issues)
        elif verb == ("issue", "view"):
            out = self._view(argv)
        elif verb == ("pr", "list"):
            out = json.dumps(self.prs)
        elif verb == ("label", "list"):
            out = json.dumps([{"name": n} if isinstance(n, str) else n for n in self.labels])
        elif verb == ("issue", "create"):
            out = self.create_url
        elif verb in self.WRITE_VERBS:
            out = self._write(verb, argv)
        else:
            out = "[]"
        return subprocess.CompletedProcess(argv, 0, stdout=out, stderr="")

    def _view(self, argv):
        """`gh issue view N --json FIELDS`: the issue with that number; the free-text field only when it was asked for."""
        number = int(argv[3])
        fields = argv[argv.index("--json") + 1]
        target = next((i for i in self.issues if int(i["number"]) == number), None)
        if target is None:
            raise subprocess.CalledProcessError(1, argv)
        wanted = fields.split(",")
        return json.dumps({k: v for k, v in target.items() if k != "body" or "body" in wanted})

    def _write(self, verb, argv):
        """`issue edit` mutates the matching issue's labels, `label create` adds the label: a round trip is real."""
        if self.before_write is not None:
            self.before_write(list(argv))
        if self.fail_write_at is not None and len(self.writes()) == self.fail_write_at:
            raise subprocess.CalledProcessError(1, argv)
        if verb == ("label", "create"):
            self.labels.append(argv[3])
            return ""
        number = int(argv[3])
        target = next((i for i in self.issues if int(i["number"]) == number), None)
        if target is None:
            raise subprocess.CalledProcessError(1, argv)
        names = [l["name"] if isinstance(l, dict) else l for l in target.get("labels", [])]
        for arg in argv[4:]:
            if arg.startswith("--add-label="):
                names += [n for n in arg.split("=", 1)[1].split(",") if n not in names]
            elif arg.startswith("--remove-label="):
                names = [n for n in names if n not in arg.split("=", 1)[1].split(",")]
        target["labels"] = [{"name": n} for n in names]
        return ""

    def verbs(self):
        return [tuple(c[1:3]) for c in self.calls]

    def writes(self):
        return [c for c in self.calls if tuple(c[1:3]) in self.WRITE_VERBS]


def issue(number, *labels, state="OPEN", created="2026-09-10T00:00:00Z", title=None, blockers=None, body=None):
    out = {
        "number": number,
        "state": state,
        "createdAt": created,
        "title": title if title is not None else "issue %d" % number,
        "labels": [{"name": name} for name in labels],
    }
    if blockers is not None:
        out["blockedBy"] = {"nodes": blockers, "totalCount": len(blockers)}
    if body is not None:
        out["body"] = body
    return out


# --- apply-path fixtures (fake runner only: nothing here can reach a real gh) ---------------------------

APPLY_MAPPING = "legacy_map:\n  bug: type:bug\n  enhancement: type:feature\n"
APPLY_LIVE_LABELS = [
    "bug", "enhancement", "type:bug", "type:feature", "type:chore", "type:epic", "status:inbox", "status:needs-info",
    "status:ready", "exec:agent", "exec:founder", "size:S", "size:M", "size:L", "priority:0-now", "priority:1-next",
    "priority:2-later", "nightly",
]


def proposal(number, before=("bug",), after=("status:inbox", "type:bug"), reason="map", confidence="high"):
    return {"issue": number, "labels_before": sorted(before), "labels_after": sorted(after), "reason": reason, "confidence": confidence}


class ApplyBase(__import__("unittest").TestCase):
    """A write-supervised target repo, a snapshot directory outside it, and helpers to drive the three apply commands
    in-process with ONE FakeRunner playing GitHub (reads and the two write verbs)."""

    MODE = "write-supervised"
    NOW_STAMP = "2026-09-19T12:00:00Z"

    def setUp(self):
        import contextlib
        import copy
        from unittest import mock

        self._copy = copy
        self._contextlib = contextlib
        self._tmp = tmpdir()
        self.tmp = Path(self._tmp.name)
        self.project = self.tmp / "repo"
        self.project.mkdir()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.snap = self.tmp / "snaps" / "s1"
        patcher = mock.patch.dict(os.environ, {"HOME": str(self.home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.cfg = self.make_cfg()

    def tearDown(self):
        self._tmp.cleanup()

    def make_cfg(self, mode=None, repo="acme/widgets", extra=APPLY_MAPPING):
        import backlog_config as C

        self._cfg_count = getattr(self, "_cfg_count", 0) + 1
        target = self.tmp / ("cfg-%d" % self._cfg_count)
        target.mkdir()
        text = "contract: 1\nmode: %s\n%s%s" % (mode or self.MODE, "repo: %s\n" % repo if repo else "", extra)
        write_config(target, text)
        cfg = C.load_config(str(target))
        assert cfg.mode == (mode or self.MODE), cfg.reason
        return cfg

    def bug_issues(self, count, first=1, labels=("bug",)):
        return [issue(n, *labels) for n in range(first, first + count)]

    def new_runner(self, issues, labels=None, **kw):
        return FakeRunner(issues=issues, labels=list(APPLY_LIVE_LABELS if labels is None else labels), **kw)

    def take_snapshot(self, issues, labels=None, cfg=None, target=None):
        """Freeze `issues` (a deep copy) with the real snapshot command; returns (directory, sha)."""
        import hashlib

        import backlog_snapshot as SN
        from datetime import datetime, timezone

        issues_file, labels_file = self.tmp / "snap-issues.json", self.tmp / "snap-labels.json"
        issues_file.write_text(json.dumps(issues))
        labels_file.write_text(json.dumps([{"name": n} for n in (APPLY_LIVE_LABELS if labels is None else labels)]))
        directory = Path(target or self.snap)
        buf = __import__("io").StringIO()
        with self._contextlib.redirect_stdout(buf):
            rc = SN.main_snapshot(
                ["--issues-file", str(issues_file), "--labels-file", str(labels_file), "--snapshot-dir", str(directory)],
                cfg or self.cfg, now=datetime(2026, 9, 19, 12, 0, 0, tzinfo=timezone.utc))
        assert rc == 0, buf.getvalue()
        return directory, hashlib.sha256((directory / "snapshot.json").read_bytes()).hexdigest()

    def proposals_file(self, entries, name="proposals.json"):
        path = self.tmp / name
        path.write_text(json.dumps(entries))
        return path

    def call(self, fn, argv, runner, cfg=None):
        """Run `fn(argv, cfg, gh=Gh(runner), apply_runner=runner)`; returns (rc, stdout)."""
        from backlog_gh import Gh

        cfg = cfg or self.cfg
        buf = __import__("io").StringIO()
        with self._contextlib.redirect_stdout(buf):
            rc = fn(argv, cfg, gh=Gh(cfg, runner=runner), apply_runner=runner)
        return rc, buf.getvalue()

    def digest(self, line_out, key="table-digest: "):
        for line in line_out.splitlines():
            if key in line:
                return line.split(key, 1)[1].split()[0]
        raise AssertionError("no digest in %r" % line_out)
