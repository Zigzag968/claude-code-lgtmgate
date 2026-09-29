"""Deterministic promotion check of the single-issue `set`: may THIS issue become ready for an agent? Stdlib only.

Pure: no I/O, no `gh`, no logging of the issue text. `check_promotion` returns a `PromotionVerdict` listing EVERY
miss (never short-circuited), so a refusal names all of them at once.

This is the only module that interprets the free text of an issue, for exactly one issue per `set` call and only
when that call asks for `status:ready` or an agent executor. It reads nothing but a count: the number of checkbox
lines (`- [ ] text`), never the text itself. A checkbox is typed by whoever wrote the issue, so no rule here can
prove an acceptance list is real: what it does is refuse the cheap forgeries (a checkbox inside a code fence or an
HTML comment, an empty item, a `[ ]` with no list marker) and leave the other conditions to structured data an
issue author cannot forge by typing (labels, the `blockedBy` graph, the state). It is one condition among several.

Codes (a verdict is ok only with none): promotion-off, no-acceptance, size-not-candidate, no-type,
exclusion:<label>, open-blocker:<n>, blockers-unknown, founder-executor, protected-present:<label>.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, FrozenSet, Iterable, List, Tuple

from backlog_common import label_names
from next_item import open_blockers

MAX_BODY = 65536  # GitHub's own limit for an issue text; anything beyond is not read
_FENCE = re.compile(r"^[ \t]{0,3}(```|~~~)")
# A list marker, a box, and at least one character of text after it. Anchored, no nested quantifier.
_ITEM = re.compile(r"^[ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+\[[ xX]\][ \t]+\S")


def _strip_comments(text: str) -> str:
    """Drop `<!-- ... -->` (linear). An unterminated comment drops the rest of the text."""
    out: List[str] = []
    position = 0
    while True:
        start = text.find("<!--", position)
        if start < 0:
            out.append(text[position:])
            break
        out.append(text[position:start])
        end = text.find("-->", start + 4)
        if end < 0:
            break
        position = end + 3
    return "".join(out)


def count_checkboxes(text) -> int:
    """Number of checkbox list items outside fenced code blocks and HTML comments. Not a str = 0."""
    if not isinstance(text, str):
        return 0
    count = 0
    fence = None
    for line in _strip_comments(text[:MAX_BODY]).splitlines():
        found = _FENCE.match(line)
        if found:
            marker = found.group(1)
            if fence is None:
                fence = marker
            elif marker == fence:
                fence = None
            continue
        if fence is None and _ITEM.match(line):
            count += 1
    return count


@dataclass(frozen=True)
class PromotionVerdict:
    """Proof that `check_promotion` ran on one issue. Only `check_promotion` builds one."""

    issue: int
    ok: bool
    codes: Tuple[str, ...]
    facts: Dict[str, object] = field(default_factory=dict)


def reserved_adds(cfg) -> FrozenSet[str]:
    """The labels only a promotion may add: the ready status, plus the agent executors when
    `exec_gating` is `promotion` (default). Under `exec_gating: triage` an agent executor is a plain
    triage label: only the ready status stays reserved."""
    agent = set(cfg.role_labels("agent")) if cfg.exec_gating == "promotion" else set()
    return frozenset({cfg.role_label("ready")} | agent)


def wants_promotion(requested: Iterable[str], cfg) -> bool:
    """Decided from the REQUESTED labels, before any read."""
    return bool(set(requested) & reserved_adds(cfg))


def is_promotion(before: Iterable[str], after: Iterable[str], cfg) -> bool:
    return bool((set(after) - set(before)) & reserved_adds(cfg))


def effective_promotion(before: Iterable[str], after: Iterable[str], cfg) -> bool:
    """`is_promotion` with a bootstrap carve-out: a labelless issue's first `set --apply` that picks up
    its type/status/size/exec labels together (e.g. `--exec agent` on intake) is a triage bootstrap, not
    a readiness promotion, as long as it does not itself request the ready status."""
    before_set, after_set = frozenset(before), frozenset(after)
    if not before_set and cfg.role_label("ready") not in (after_set - before_set):
        return False
    return is_promotion(before_set, after_set, cfg)


def _blockers_known(issue: dict) -> bool:
    blocked_by = issue.get("blockedBy")
    if not isinstance(blocked_by, dict):
        return False
    nodes, total = blocked_by.get("nodes"), blocked_by.get("totalCount")
    if not isinstance(nodes, list) or isinstance(total, bool) or not isinstance(total, int):
        return False
    return total <= len(nodes)


def check_promotion(issue: dict, after: Iterable[str], cfg) -> PromotionVerdict:
    """Every condition on the live issue plus the labels it would have after the change."""
    after_set = frozenset(after)
    live = frozenset(label_names(issue))
    codes: List[str] = []

    if cfg.promotion != "checked":
        codes.append("promotion-off")

    checkboxes = count_checkboxes(issue.get("body"))
    if checkboxes < 1:
        codes.append("no-acceptance")

    sizes = ["size:%s" % value for value in cfg.roles["candidate_sizes"]]
    size = next((label for label in sorted(after_set) if label in sizes), "")
    if not size:
        codes.append("size-not-candidate")

    types = sorted(label for label in after_set if label.startswith("type:"))
    if not types or cfg.role_label("epic") in after_set:
        codes.append("no-type")

    for label in sorted(set(cfg.exclusions) & (live | after_set)):
        codes.append("exclusion:%s" % label)

    try:
        known = _blockers_known(issue)
        blockers = open_blockers(issue) if known else []
    except (KeyError, TypeError, ValueError):  # a node without a usable number: fail closed
        known, blockers = False, []
    if not known:
        codes.append("blockers-unknown")
    for number in blockers:
        codes.append("open-blocker:%d" % number)

    if live & set(cfg.role_labels("founder")):
        codes.append("founder-executor")

    for label in sorted(live):
        if cfg.is_protected(label):
            codes.append("protected-present:%s" % label)

    facts = {
        "checkboxes": checkboxes,
        "size": size,
        "type": types[0] if types else "",
        "blockers": len(blockers),
    }
    return PromotionVerdict(issue=int(issue["number"]), ok=not codes, codes=tuple(codes), facts=facts)
