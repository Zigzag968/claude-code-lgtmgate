"""PreToolUse guard: deny RAW `gh` label writes that touch an owned-axis label, deny a bare issue creation, deny an
undeclared axis value in any mode but `off`, and ASK before an apply. Stdlib only, no I/O.

Three independent rules, in `check`:

1. **Namespace-touch** (modes `propose`, `write-supervised` only): a raw `gh issue create|edit` or `gh label
   create|edit|delete` naming a label of an owned axis (type, status, priority, exec, size) would bypass the
   intake validator and the allow-listed wrapper. Modes `off` and `free` never deny here, and neither does
   anything that does not touch an owned axis: bare flags (`nightly`, `cross-repo`), `auto:*` and `area:*`
   labels stay free for the repo's own automation.
2. **Bare issue creation** (modes `write-supervised`, `free`, opt-out `guard_issue_create: false`): a raw
   `gh issue create` is denied — the only qualified creation path is `/backlog:file`.
3. **Doctrine (taxonomy)**, every mode but `off`: a label naming a declared axis (type/status/priority/exec/size)
   with a value NOT in `.claude/backlog.yml` is denied — including in `free`, which rule 1 never gates. This
   closes the REST bypass too (`gh api repos/.../issues/N/labels`, not just the `gh issue`/`gh label` shapes of
   rule 1). A free axis (no declared values, e.g. the default `area: []`) and any bare flag are out of scope.

The wrapper's own `gh` calls run in a child process of the plugin script, not through the Bash tool, so this
guard never sees them. `check` is a regex pass over the raw command string (compound commands included), the
same approach as the lgtmgate destructive-git hook.

Rule H2 (`check_ask`) is OPT-IN through `apply_prompt: ask` in the config (default `none`: silent). When enabled, an
agent Bash command that runs the plugin CLI with an apply subcommand (`label-sync --apply`, `catchup ... --apply`,
`rollback --apply`, `set ... --apply`, or the generated `rollback.sh --apply`) is NOT denied: the hook answers `permissionDecision: ask`,
so the human confirms in the permission prompt. It applies in every mode except `off`. By default no prompt is raised:
the human validation happens on the dry-run table, whose digest `--confirm` must equal. Both checks are best effort
(a regex, not a shell parser): the real gate is the applier itself.
"""

from __future__ import annotations

import re
from typing import List, Optional

from backlog_config import AXES

_GATED_MODES = ("propose", "write-supervised")
_SEGMENT_END = r"[^;&|\n]*"
_ISSUE_WRITE = re.compile(r"(?:^|[^\w-])gh\s+issue\s+(?:create|edit)\b(" + _SEGMENT_END + ")")
_LABEL_WRITE = re.compile(r"(?:^|[^\w-])gh\s+label\s+(?:create|edit|delete)\b(" + _SEGMENT_END + ")")
_LABEL_FLAG = re.compile(r"""(?:--label|-l|--add-label|--remove-label|--name|-n)(?:=|\s+)("[^"]*"|'[^']*'|[^\s;&|]+)""")
_TOKEN = r"""(?:"[^"]*"|'[^']*'|\S+)"""
_APPLY_CLI = re.compile(
    r"backlog_cli\.py\s+(?:--project-dir(?:=|\s+)" + _TOKEN + r"\s+)?(?:label-sync|catchup|rollback|set)\b(" + _SEGMENT_END + ")"
)
_APPLY_WRAPPER = re.compile(r"rollback\.sh\b(" + _SEGMENT_END + ")")
_APPLY_FLAG = re.compile(r"(?:^|\s)--apply(?:[\s=\"']|$)")
_POSITIONAL = re.compile(r"""^\s*("[^"]*"|'[^']*'|[^\s;&|-][^\s;&|]*)""")
_BARE_ISSUE_CREATE = re.compile(r"(?:^|[^\w-])gh\s+issue\s+create\b")
_API_LABEL_WRITE = re.compile(
    r"""(?:^|[^\w-])gh\s+api\b(?:\s+-X\s+\S+)?\s+["']?repos/[^\s"']+/(?:issues/\d+/labels|labels)\b(""" + _SEGMENT_END + ")"
)
_API_FIELD_FLAG = re.compile(r"""(?:-f|-F|--raw-field|--field)(?:=|\s+)("[^"]*"|'[^']*'|[^\s;&|]+)""")


def _unquote(token: str) -> str:
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        return token[1:-1]
    return token


def _flag_values(segment: str) -> List[str]:
    values: List[str] = []
    for match in _LABEL_FLAG.finditer(segment):
        for part in _unquote(match.group(1)).split(","):
            part = part.strip()
            if part:
                values.append(part)
    return values


def touched_labels(command: str) -> List[str]:
    """Labels named by raw label-writing `gh` invocations found in the command."""
    found: List[str] = []
    for match in _ISSUE_WRITE.finditer(command):
        found += _flag_values(match.group(1))
    for match in _LABEL_WRITE.finditer(command):
        segment = match.group(1)
        first = _POSITIONAL.match(segment)
        if first:
            found.append(_unquote(first.group(1)))
        found += _flag_values(segment)
    return found


def _api_flag_values(segment: str) -> List[str]:
    values: List[str] = []
    for match in _API_FIELD_FLAG.finditer(segment):
        token = _unquote(match.group(1))
        if "=" not in token:
            continue
        _, value = token.split("=", 1)
        for part in value.split(","):
            part = part.strip()
            if part:
                values.append(part)
    return values


def api_touched_labels(command: str) -> List[str]:
    """Labels named by a raw `gh api repos/OWNER/REPO/(issues/N/labels|labels)` call (the REST bypass of rule 1)."""
    found: List[str] = []
    for match in _API_LABEL_WRITE.finditer(command):
        found += _api_flag_values(match.group(1))
    return found


def _taxonomy_violation(label: str, cfg) -> Optional[str]:
    """Doctrine rule 3: a label naming a declared axis with a value NOT in `.claude/backlog.yml`. A bare flag
    (no ':'), an axis outside the contract, or a free axis (no declared values) is out of scope: `None`."""
    if ":" not in label:
        return None
    axis, _, value = label.partition(":")
    if axis not in AXES:
        return None
    declared = cfg.labels.get(axis, ())
    if not declared or value in declared:
        return None
    return (
        "backlog guard: '%s' names the %s axis with a value not declared in .claude/backlog.yml (declared: %s). "
        "Add it to labels.%s first, or use a declared value." % (label, axis, ", ".join(declared), axis)
    )


def check(command: str, cfg) -> Optional[str]:
    """Return a denial reason, or None to allow. Three rules (see the module docstring); only mode `off` skips
    all of them."""
    if cfg.mode == "off":
        return None
    if cfg.mode in _GATED_MODES:
        owned = cfg.owned_namespaces()
        for label in touched_labels(command) if owned else ():
            if label.startswith(owned):
                return (
                    "backlog guard: a raw gh label write naming '%s' is denied in mode %s. "
                    "Owned-axis labels (%s) go through the backlog plugin: /backlog:file to create an issue, "
                    "/backlog:triage to propose label changes, or `backlog_cli.py set --issue N --status V --apply` for one issue. "
                    "Bare flags, auto:* and area:* labels are not affected."
                    % (label, cfg.mode, ", ".join(owned))
                )
    if cfg.mode in ("write-supervised", "free") and getattr(cfg, "guard_issue_create", True) and _BARE_ISSUE_CREATE.search(command):
        return (
            "backlog guard: raw 'gh issue create' is denied in mode %s — the only qualified creation path is "
            "/backlog:file (opt out per-repo with guard_issue_create: false in .claude/backlog.yml)." % cfg.mode
        )
    for label in touched_labels(command) + api_touched_labels(command):
        reason = _taxonomy_violation(label, cfg)
        if reason:
            return reason
    return None


def check_ask(command: str, cfg) -> Optional[str]:
    """Rule H2: return a reason to ASK the human about, or None. Never a denial."""
    if cfg.mode == "off" or getattr(cfg, "apply_prompt", "none") != "ask":
        return None
    for pattern in (_APPLY_CLI, _APPLY_WRAPPER):
        for match in pattern.finditer(command):
            if _APPLY_FLAG.search(match.group(1)):
                return (
                    "backlog guard: this command APPLIES label changes to GitHub (mode %s). Confirm you validated the "
                    "dry run (catch-up: --confirm must equal its table-digest and a verified snapshot must exist; "
                    "set: one issue, journaled)." % cfg.mode
                )
    return None
