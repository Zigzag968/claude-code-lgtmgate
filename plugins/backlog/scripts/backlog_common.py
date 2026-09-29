"""Pure helpers shared by the backlog scripts (ported from an internal reference implementation).

Stdlib only, no I/O beyond `load_json_list`, no `gh`. Every label constant now lives in the config
(`backlog_config.Config`); this module only reads issue payloads.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple, Union


def label_names(issue: dict) -> Set[str]:
    """Label names of a `gh` issue payload (`labels: [{"name": ...}]`); plain strings tolerated."""
    names: Set[str] = set()
    for label in issue.get("labels") or []:
        if isinstance(label, dict):
            name = label.get("name")
            if name:
                names.add(str(name))
        elif isinstance(label, str):
            names.add(label)
    return names


def axis_labels(names: Set[str], axis: str) -> List[str]:
    """Labels of `names` that belong to the `axis` namespace (`axis:...`), sorted."""
    prefix = "%s:" % axis
    return sorted(name for name in names if name.startswith(prefix))


def is_open(issue: dict) -> bool:
    return str(issue.get("state", "")).upper() == "OPEN"


def load_json_list(path: Union[str, Path]) -> list:
    """Read a JSON file that must hold a list (a `gh ... --json` payload)."""
    data = json.loads(Path(path).read_text())
    if not isinstance(data, list):
        raise ValueError("%s: expected a JSON list, got %s" % (path, type(data).__name__))
    return data


def full_labels(cfg, axis: str) -> Tuple[str, ...]:
    """`axis:value` labels of an axis, in configured order."""
    return tuple("%s:%s" % (axis, value) for value in cfg.labels.get(axis, ()))


def axis_rank(cfg, axis: str) -> Dict[str, int]:
    """Rank of each full label of an axis (list order = rank); unknown labels are ranked by the caller."""
    return {label: index for index, label in enumerate(full_labels(cfg, axis))}


@dataclass(frozen=True)
class LabelEdit:
    """One planned label change on one issue (a row of the rollback plan). Data only: nothing here applies it."""

    issue: int
    before: Tuple[str, ...]
    after: Tuple[str, ...]
    add: Tuple[str, ...]
    remove: Tuple[str, ...]
    reason: str = ""


def repo_assertion_error(cfg, asserted: Optional[str]) -> Optional[str]:
    """`--repo` is an ASSERTION about the target, never a selector: the target is always `cfg.repo`.
    Returns an error message when the assertion cannot be honoured, else None. Strict equality."""
    if asserted is None:
        return None
    if not cfg.repo:
        return "--repo %s asserted but `repo:` is absent from .claude/backlog.yml (the target is the config's repo)" % asserted
    if asserted != cfg.repo:
        return "--repo %s does not match the repo of .claude/backlog.yml (%s)" % (asserted, cfg.repo)
    return None


_CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f]")


def printable(text: str) -> str:
    """Neutralize control characters (terminal escapes from issue titles, labels or reasons) for display."""
    return _CONTROL_RE.sub("?", str(text))


def repo_slug(repo: str) -> str:
    """`OWNER/NAME` -> `OWNER__NAME`: one path component, never a separator (`..` cannot survive the join)."""
    return repo.replace("/", "__")
