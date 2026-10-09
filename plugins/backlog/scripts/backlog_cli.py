#!/usr/bin/env python3
"""Single entry point of the backlog plugin: `python3 -B backlog_cli.py [--project-dir DIR] <subcommand> ...`.

Subcommands: config, next, lint, file, inbox, triage-check, label-sync, snapshot, rollback, catchup, set, guard.
label-sync, rollback, `catchup check` and `set` (one issue) are dry runs unless `--apply` (gated by backlog_apply.py);
snapshot and `catchup propose --out` write local files outside any repo.

The config is loaded first. For every subcommand except `config` and `guard`, mode `off` (which is what a
missing or invalid `.claude/backlog.yml` resolves to) prints one line and returns 0 BEFORE any `gh` wrapper
is constructed: without a config, no `gh` path is reachable from here.
"""

from __future__ import annotations

import os
import sys
from typing import List, Optional

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import backlog_catchup
import backlog_config
import backlog_file
import backlog_guard
import backlog_labelsync
import backlog_lint
import backlog_set
import backlog_snapshot
import backlog_triage
import next_item

USAGE = "usage: backlog_cli.py [--project-dir DIR] {config,next,lint,file,inbox,triage-check,label-sync,snapshot,rollback,catchup,set,guard} ..."

_HELP_PARSERS = {
    "lint": lambda cfg: backlog_lint.build_parser(),
    "next": lambda cfg: next_item.build_parser(cfg),
    "file": lambda cfg: backlog_file.build_parser(),
    "inbox": lambda cfg: backlog_triage.build_inbox_parser(),
    "triage-check": lambda cfg: backlog_triage.build_check_parser(),
    "label-sync": lambda cfg: backlog_labelsync.build_parser(),
    "snapshot": lambda cfg: backlog_snapshot.build_snapshot_parser(),
    "rollback": lambda cfg: backlog_snapshot.build_rollback_parser(),
    "catchup": lambda cfg: backlog_catchup.build_parser(),
    "set": lambda cfg: backlog_set.build_parser(cfg),
}
_RUNNERS = {
    "lint": backlog_lint.main,
    "next": next_item.main,
    "file": backlog_file.main,
    "inbox": backlog_triage.main_inbox,
    "triage-check": backlog_triage.main_check,
    "label-sync": backlog_labelsync.main,
    "snapshot": backlog_snapshot.main_snapshot,
    "rollback": backlog_snapshot.main_rollback,
    "catchup": backlog_catchup.main,
    "set": backlog_set.main,
}


def _guard(rest: List[str], cfg) -> int:
    """Exit 0 = allow; exit 1 = deny (reason on stdout); exit 3 = ask the human (reason on stdout); any internal
    problem = allow (fail open)."""
    try:
        if len(rest) != 2 or rest[0] != "--command":
            return 0
        reason = backlog_guard.check(rest[1], cfg)
        ask = None if reason else backlog_guard.check_ask(rest[1], cfg)
    except Exception:  # fail open: a guard bug must never block the user's shell
        return 0
    if reason:
        print(reason)
        return 1
    if ask:
        print(ask)
        return 3
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    project_dir = None
    if len(argv) >= 2 and argv[0] == "--project-dir":
        project_dir, argv = argv[1], argv[2:]
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0 if argv else 2
    sub, rest = argv[0], argv[1:]
    if sub not in ("config", "guard") and sub not in _RUNNERS:
        print(USAGE)
        return 2

    cfg = backlog_config.load_config(project_dir)

    if sub == "config":
        print("[backlog] mode=%s source=%s reason=%s" % (cfg.mode, cfg.source or "none", cfg.reason or "ok"))
        return 0
    if sub == "guard":
        return _guard(rest, cfg)

    if any(arg in ("-h", "--help") for arg in rest):
        _HELP_PARSERS[sub](cfg).parse_args(rest)  # prints the help and exits 0; no gh involved
        return 0
    if cfg.mode == "off":
        print("[backlog] mode=off (%s): nothing to do" % cfg.reason)
        return 0
    return _RUNNERS[sub](rest, cfg)


if __name__ == "__main__":
    raise SystemExit(main())
