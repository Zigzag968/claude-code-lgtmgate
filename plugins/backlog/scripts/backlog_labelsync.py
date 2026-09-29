"""Label sync: compare the labels the config declares with the live repo labels. Stdlib only.

The spec is DERIVED from `.claude/backlog.yml`: one label `<axis>:<value>` per configured value, colored by
`label_colors` (default grey). The plan is printed and, by default, nothing is written: this module has no `gh`
write verb of its own. `--apply` delegates to `backlog_apply.py`, which CREATES the missing labels only (never
an edit, rename or delete: `drift` is reported and left untouched) once every apply condition holds. Labels
outside the spec are counted as `unmanaged` and never touched. Descriptions are not compared (the config
carries none).
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

from backlog_common import load_json_list, printable, repo_assertion_error
from backlog_config import AXES


@dataclass(frozen=True)
class Action:
    kind: str  # create | ok | drift
    name: str


def spec_from_config(cfg) -> List[dict]:
    """One label per `axis:value` of the config, in axis then list order."""
    return [
        {"name": "%s:%s" % (axis, value), "color": cfg.label_color(axis), "description": ""}
        for axis in AXES
        for value in cfg.labels.get(axis, ())
    ]


def _live_index(live: List[dict]) -> Dict[str, dict]:
    return {str(label["name"]).lower(): label for label in live if isinstance(label, dict) and label.get("name")}


def plan(spec: List[dict], live: List[dict]) -> List[Action]:
    index = _live_index(live)
    actions: List[Action] = []
    for entry in spec:
        current = index.get(entry["name"].lower())
        if current is None:
            actions.append(Action("create", entry["name"]))
        elif str(current.get("color") or "").lower() != entry["color"].lower():
            actions.append(Action("drift", entry["name"]))
        else:
            actions.append(Action("ok", entry["name"]))
    return actions


def unmanaged(spec: List[dict], live: List[dict]) -> List[str]:
    known = {entry["name"].lower() for entry in spec}
    return sorted(str(label["name"]) for label in live if isinstance(label, dict) and label.get("name") and str(label["name"]).lower() not in known)


def labelsync_digest(creates: Sequence[Tuple[str, str]], repo: Optional[str], snapshot_sha: Optional[str]) -> str:
    """Digest of the labels a sync would create, bound to the target repo and to the snapshot the run rests on."""
    payload = json.dumps(
        {"kind": "label-sync", "repo": repo, "creates": [[name, color] for name, color in creates], "snapshot_sha": snapshot_sha},
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="backlog_cli.py label-sync",
        allow_abbrev=False,
        description="Compare the labels declared by .claude/backlog.yml with the live repo labels. Dry run unless --apply.",
    )
    parser.add_argument("--repo", help="assertion only: must equal `repo:` of .claude/backlog.yml")
    parser.add_argument("--live-file", help="repo labels, `gh label list --json name,color,description` shape (offline, dry run only)")
    parser.add_argument("--apply", action="store_true", help="create the missing labels (needs --snapshot-dir, --expect-sha, --confirm)")
    parser.add_argument("--confirm", help="the table-digest printed by the dry run")
    parser.add_argument("--snapshot-dir", help="a verified snapshot directory (outside any repo)")
    parser.add_argument("--expect-sha", help="sha256 of the snapshot.json")
    return parser


def main(argv: List[str], cfg, gh=None, apply_runner=None) -> int:
    args = build_parser().parse_args(argv)
    problem = repo_assertion_error(cfg, args.repo)
    if problem:
        print("[label-sync] error: %s" % problem)
        return 1
    if args.apply or args.confirm:
        from backlog_apply import apply_labelsync  # lazy: backlog_apply imports this module

        return apply_labelsync(args, cfg, gh, apply_runner)
    try:
        if args.live_file:
            live = load_json_list(args.live_file)
        else:
            if gh is None:
                from backlog_gh import Gh

                gh = Gh(cfg)
            live = gh.fetch_labels()
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as exc:
        print("[label-sync] error: %s" % printable(exc))
        return 1

    spec = spec_from_config(cfg)
    actions = plan(spec, live)
    for action in actions:
        print("[label-sync] %s %s" % (action.kind, printable(action.name)))
    counts = {kind: sum(1 for a in actions if a.kind == kind) for kind in ("create", "ok", "drift")}
    print(
        "[label-sync] dry-run: create=%d ok=%d drift=%d unmanaged=%d (nothing written; --apply creates the missing labels, see the README)"
        % (counts["create"], counts["ok"], counts["drift"], len(unmanaged(spec, live)))
    )
    if args.snapshot_dir and args.expect_sha:
        colors = {entry["name"]: entry["color"] for entry in spec}
        creates = [(a.name, colors[a.name]) for a in actions if a.kind == "create"]
        print("[label-sync] table-digest: %s" % labelsync_digest(creates, cfg.repo, args.expect_sha))
    else:
        print("[label-sync] applying needs --snapshot-dir and --expect-sha (a verified snapshot), then --confirm <table-digest>")
    return 0
