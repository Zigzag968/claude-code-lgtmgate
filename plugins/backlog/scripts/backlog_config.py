"""Config loader for the backlog plugin: `.claude/backlog.yml`, contract 1. Stdlib only.

`load_config` NEVER raises. No file, an unreadable file, an unparsable file or an invalid value all
resolve to mode `off`, and mode `off` is what keeps every write path (and every `gh` call) unreachable.

The restricted YAML reader below accepts only what the contract needs (see `parse_simple_yaml`); it
exists so the agent-time path never depends on PyYAML.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

CONTRACT = 1
MODES = ("off", "propose", "write-supervised", "free")
CONFIG_RELPATH = os.path.join(".claude", "backlog.yml")

AXES = ("type", "status", "priority", "exec", "size", "area")
RESERVED_STATUS_VALUES = ("in-review", "done")
TOP_KEYS = (
    "contract",
    "mode",
    "repo",
    "labels",
    "roles",
    "executor_flags",
    "exclusions",
    "protected",
    "caps",
    "legacy_map",
    "legacy_keep",
    "label_colors",
    "apply_prompt",
    "promotion",
    "exec_gating",
    "intake_required",
    "guard_issue_create",
    "cadence",
)
APPLY_PROMPTS = ("none", "ask")
PROMOTIONS = ("none", "checked")
EXEC_GATINGS = ("promotion", "triage")
DEFAULT_INTAKE_REQUIRED: Tuple[str, ...] = ("type",)
SCALAR_ROLES = ("intake", "waiting", "ready", "epic", "bug")
LIST_ROLES = ("split", "candidate_sizes", "agent", "human")
ROLE_AXIS = {
    "intake": "status",
    "waiting": "status",
    "ready": "status",
    "epic": "type",
    "bug": "type",
    "split": "size",
    "candidate_sizes": "size",
    "agent": "exec",
    "human": "exec",
}

# The reference taxonomy (the source implementation's scripts/backlog_common.py): every absent key falls back to this.
DEFAULT_LABELS: Dict[str, List[str]] = {
    "type": ["bug", "feature", "chore", "epic"],
    "status": ["inbox", "needs-info", "ready"],
    "priority": ["0-now", "1-next", "2-later"],
    "exec": ["agent", "human"],
    "size": ["S", "M", "L"],
    "area": [],
}
DEFAULT_ROLES: Dict[str, Any] = {
    "intake": "inbox",
    "waiting": "needs-info",
    "ready": "ready",
    "epic": "epic",
    "bug": "bug",
    "split": ["L"],
    "candidate_sizes": ["S", "M"],
    "agent": ["agent"],
    "human": ["human"],
}
DEFAULT_EXECUTOR_FLAGS: List[str] = ["nightly"]
DEFAULT_EXCLUSIONS: List[str] = ["cross-repo", "money-path"]
DEFAULT_PROTECTED: List[str] = ["nightly", "cross-repo", "auto:*"]
DEFAULT_CAPS: Dict[str, int] = {"priority:0-now": 2, "priority:1-next": 8}

_REPO_RE = re.compile(r"^[\w.-]+/[\w.-]+$")
_VALUE_RE = re.compile(r"^[A-Za-z0-9][\w.-]*$")
_FLAG_RE = re.compile(r"^[A-Za-z0-9][\w.:*-]*$")
_KEY_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.:*-]*$")
_LEGACY_RE = re.compile(r"^[A-Za-z0-9][\w.:-]*$")
_COLOR_RE = re.compile(r"^[0-9a-fA-F]{6}$")

# GitHub's neutral grey: the color `label-sync` proposes for an axis that has no `label_colors` entry.
DEFAULT_LABEL_COLOR = "ededed"


class ConfigError(ValueError):
    """The config file is not valid contract-1 input."""


# --- restricted YAML reader ----------------------------------------------------------------------


def _strip_comment(line: str) -> str:
    quote = None
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == "#" and (index == 0 or line[index - 1] in " \t"):
            return line[:index].rstrip()
    return line.rstrip()


def _split_commas(text: str) -> List[str]:
    items: List[str] = []
    quote = None
    current: List[str] = []
    for char in text:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            current.append(char)
        elif char == ",":
            items.append("".join(current))
            current = []
        else:
            current.append(char)
    if quote:
        raise ConfigError("unterminated quote in inline list")
    items.append("".join(current))
    return items


def _scalar(token: str) -> Any:
    token = token.strip()
    if token == "":
        return None
    if token[0] in "\"'":
        quote = token[0]
        if len(token) < 2 or token[-1] != quote or quote in token[1:-1]:
            raise ConfigError("malformed quoted scalar: " + token)
        return token[1:-1]
    if token[0] in "{[&*!|>%@`" or token.startswith("- "):
        raise ConfigError("unsupported YAML construct in value: " + token)
    if re.fullmatch(r"-?[0-9]+", token):
        return int(token)
    return token


def _value(token: str) -> Any:
    token = token.strip()
    if token.startswith("["):
        if not token.endswith("]"):
            raise ConfigError("unterminated inline list: " + token)
        parts = _split_commas(token[1:-1])
        if len(parts) == 1 and parts[0].strip() == "":
            return []
        if parts and parts[-1].strip() == "":
            parts = parts[:-1]
        out: List[Any] = []
        for part in parts:
            item = _scalar(part)
            if item is None:
                raise ConfigError("empty item in inline list: " + token)
            out.append(item)
        return out
    return _scalar(token)


def _split_key(body: str) -> Tuple[str, str]:
    if body[0] in "\"'":
        quote = body[0]
        end = body.find(quote, 1)
        if end < 0:
            raise ConfigError("unterminated quoted key: " + body)
        key, rest = body[1:end], body[end + 1 :]
        if not rest.startswith(":") or (len(rest) > 1 and rest[1] != " "):
            raise ConfigError("expected 'key: value': " + body)
        return key, rest[1:]
    for index, char in enumerate(body):
        if char == ":" and (index + 1 == len(body) or body[index + 1] == " "):
            key = body[:index].strip()
            if not _KEY_RE.match(key):
                raise ConfigError("unsupported key: " + key)
            return key, body[index + 1 :]
    raise ConfigError("expected 'key: value': " + body)


def parse_simple_yaml(text: str) -> Dict[str, Any]:
    """Parse the restricted subset: comments, blank lines, `key: scalar`, `key: [a, b]`, and ONE nested level
    of 2-space-indented `key: scalar|[list]` lines under a bare `key:`. Anything else raises ConfigError."""
    data: Dict[str, Any] = {}
    current: Optional[str] = None
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = _strip_comment(raw)
        if not line.strip():
            continue
        if "\t" in line:
            raise ConfigError("line %d: tabs are not supported" % lineno)
        body = line.strip()
        if body.startswith("-") or body.startswith("---") or body.startswith("..."):
            raise ConfigError("line %d: block lists and document markers are not supported" % lineno)
        indent = len(line) - len(line.lstrip(" "))
        key, rest = _split_key(body)
        if indent == 0:
            if key in data:
                raise ConfigError("line %d: duplicate key %r" % (lineno, key))
            if rest.strip() == "":
                data[key] = None
                current = key
            else:
                data[key] = _value(rest)
                current = None
        elif indent == 2:
            if current is None:
                raise ConfigError("line %d: unexpected indentation" % lineno)
            if data[current] is None:
                data[current] = {}
            block = data[current]
            if key in block:
                raise ConfigError("line %d: duplicate key %r under %r" % (lineno, key, current))
            if rest.strip() == "":
                raise ConfigError("line %d: nesting deeper than 2 levels is not supported" % lineno)
            block[key] = _value(rest)
        else:
            raise ConfigError("line %d: indentation must be 0 or 2 spaces" % lineno)
    return data


# --- Config ---------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Config:
    mode: str = "off"
    repo: Optional[str] = None
    labels: Dict[str, Tuple[str, ...]] = field(default_factory=dict)
    roles: Dict[str, Any] = field(default_factory=dict)
    executor_flags: Tuple[str, ...] = ()
    exclusions: Tuple[str, ...] = ()
    protected: Tuple[str, ...] = ()
    caps: Dict[str, int] = field(default_factory=dict)
    reason: str = ""
    source: Optional[str] = None
    # Additive keys of the catch-up tooling (empty = nothing mapped, default colors).
    legacy_map: Dict[str, str] = field(default_factory=dict)
    legacy_keep: Tuple[str, ...] = ()
    label_colors: Dict[str, str] = field(default_factory=dict)
    # Whether an agent Bash apply command raises a human permission prompt (rule H2): "none" (default) or "ask".
    apply_prompt: str = "none"
    # Whether the single-issue `set` may promote to `ready` / an agent executor when the deterministic check passes.
    promotion: str = "none"
    # Whether an agent-executor add is gated like a promotion ("promotion", default) or a plain triage label ("triage").
    exec_gating: str = "promotion"
    # Axes `/backlog:file` refuses to create an issue without (default: type only).
    intake_required: Tuple[str, ...] = DEFAULT_INTAKE_REQUIRED
    # Whether the guard hook denies a bare `gh issue create` in write-supervised/free (opt-out).
    guard_issue_create: bool = True

    def axis_label_names(self) -> frozenset:
        return frozenset("%s:%s" % (axis, value) for axis, values in self.labels.items() for value in values)

    def owned_namespaces(self) -> Tuple[str, ...]:
        return tuple("%s:" % axis for axis, values in self.labels.items() if axis != "area" and values)

    def free_namespaces(self) -> Tuple[str, ...]:
        return tuple("%s:" % axis for axis, values in self.labels.items() if axis == "area" and not values)

    def is_protected(self, name: str) -> bool:
        for entry in self.protected:
            if entry.endswith("*"):
                if name.startswith(entry[:-1]):
                    return True
            elif name == entry:
                return True
        return False

    def role_label(self, role: str) -> str:
        """Full label (`axis:value`) of a scalar role."""
        return "%s:%s" % (ROLE_AXIS[role], self.roles[role])

    def role_labels(self, role: str) -> Tuple[str, ...]:
        """Full labels of a list role."""
        return tuple("%s:%s" % (ROLE_AXIS[role], value) for value in self.roles[role])

    def label_color(self, axis: str) -> str:
        """Hex color (no `#`) `label-sync` proposes for the labels of an axis."""
        return self.label_colors.get(axis, DEFAULT_LABEL_COLOR)


def _defaults(mode: str, reason: str, source: Optional[str]) -> Config:
    return _build(dict(DEFAULT_LABELS), dict(DEFAULT_ROLES), mode, None, reason, source)


def _build(labels: Dict[str, Any], roles: Dict[str, Any], mode: str, repo: Optional[str], reason: str,
           source: Optional[str], executor_flags=None, exclusions=None, protected=None, caps=None) -> Config:
    return Config(
        mode=mode,
        repo=repo,
        labels={axis: tuple(labels.get(axis, ())) for axis in AXES},
        roles={k: (tuple(v) if isinstance(v, list) else v) for k, v in roles.items()},
        executor_flags=tuple(DEFAULT_EXECUTOR_FLAGS if executor_flags is None else executor_flags),
        exclusions=tuple(DEFAULT_EXCLUSIONS if exclusions is None else exclusions),
        protected=tuple(DEFAULT_PROTECTED if protected is None else protected),
        caps=dict(DEFAULT_CAPS if caps is None else caps),
        reason=reason,
        source=source,
    )


def default_config(mode: str = "propose", repo: Optional[str] = None) -> Config:
    """The reference taxonomy in the given mode (tests and the template drift check use this)."""
    if mode not in MODES:
        raise ValueError("invalid mode: " + mode)
    cfg = _defaults(mode, "defaults", None)
    return Config(**{**cfg.__dict__, "repo": repo})


def _str_list(value: Any, what: str, pattern: "re.Pattern[str]") -> List[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ConfigError("%s must be an inline list of strings" % what)
    for item in value:
        if not pattern.match(item):
            raise ConfigError("%s: invalid value %r" % (what, item))
    if len(set(value)) != len(value):
        raise ConfigError("%s: duplicate values" % what)
    return list(value)


def _block(data: Dict[str, Any], key: str) -> Dict[str, Any]:
    """A nested `key:` block; absent or empty = {}."""
    raw = data.get(key)
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ConfigError("`%s` must be a block of `key: value` lines" % key)
    return raw


def _legacy_map(cfg: Config, data: Dict[str, Any]) -> Dict[str, str]:
    targets = cfg.axis_label_names()
    reserved_targets = {cfg.role_label("ready")} | set(cfg.role_labels("agent"))
    legacy_map: Dict[str, str] = {}
    for legacy, target in _block(data, "legacy_map").items():
        if not _LEGACY_RE.match(legacy):
            raise ConfigError("legacy_map: invalid legacy label %r" % legacy)
        if not isinstance(target, str) or target not in targets:
            raise ConfigError("legacy_map.%s: %r is not an axis:value label of this config" % (legacy, target))
        if cfg.is_protected(legacy) or legacy in targets or legacy in cfg.exclusions or legacy in cfg.executor_flags:
            raise ConfigError("legacy_map: %r is protected, an axis label, an exclusion or an executor flag" % legacy)
        if target in reserved_targets:
            raise ConfigError("legacy_map.%s: promotion to %s stays a human triage decision" % (legacy, target))
        legacy_map[legacy] = target
    return legacy_map


def _legacy_keep(data: Dict[str, Any], legacy_map: Dict[str, str]) -> List[str]:
    raw_keep = data.get("legacy_keep")
    legacy_keep: List[str] = []
    if raw_keep is not None:
        legacy_keep = _str_list(raw_keep, "legacy_keep", _LEGACY_RE)
        for name in legacy_keep:
            if name not in legacy_map:
                raise ConfigError("legacy_keep: %r is not a key of legacy_map" % name)
    return legacy_keep


def _label_colors(data: Dict[str, Any]) -> Dict[str, str]:
    label_colors: Dict[str, str] = {}
    for axis, color in _block(data, "label_colors").items():
        if axis not in AXES:
            raise ConfigError("label_colors: unknown axis %r (one of %s)" % (axis, ", ".join(AXES)))
        if isinstance(color, int) and not isinstance(color, bool):
            raise ConfigError("label_colors.%s: quote all-digit colors (\"123456\")" % axis)
        if not isinstance(color, str) or not _COLOR_RE.match(color):
            raise ConfigError("label_colors.%s must be 6 hex characters without '#'" % axis)
        label_colors[axis] = color.lower()
    return label_colors


def _choice(data: Dict[str, Any], key: str, default: str, allowed: Any) -> str:
    raw = data.get(key)
    value = default if raw in (None, "") else raw
    if value not in allowed:
        raise ConfigError("%s must be one of %s" % (key, ", ".join(allowed)))
    return value


def _intake_required(data: Dict[str, Any]) -> Tuple[str, ...]:
    raw_intake = data.get("intake_required")
    if raw_intake is None:
        return DEFAULT_INTAKE_REQUIRED
    if not isinstance(raw_intake, list) or not all(isinstance(item, str) for item in raw_intake):
        raise ConfigError("intake_required must be an inline list of strings")
    for item in raw_intake:
        if item not in AXES:
            raise ConfigError("intake_required: %r is not an axis (one of %s)" % (item, ", ".join(AXES)))
    if len(set(raw_intake)) != len(raw_intake):
        raise ConfigError("intake_required: duplicate values")
    return tuple(raw_intake)


def _guard_issue_create(data: Dict[str, Any]) -> bool:
    raw_guard_create = data.get("guard_issue_create")
    if raw_guard_create is None:
        return True
    if raw_guard_create in ("true", "false"):
        return raw_guard_create == "true"
    raise ConfigError("guard_issue_create must be true or false")


def _with_catchup_keys(cfg: Config, data: Dict[str, Any]) -> Config:
    """Validate the additive catch-up keys against the already-validated taxonomy."""
    legacy_map = _legacy_map(cfg, data)
    legacy_keep = _legacy_keep(data, legacy_map)
    label_colors = _label_colors(data)
    apply_prompt = _choice(data, "apply_prompt", "none", APPLY_PROMPTS)
    promotion = _choice(data, "promotion", "none", PROMOTIONS)
    exec_gating = _choice(data, "exec_gating", "promotion", EXEC_GATINGS)
    intake_required = _intake_required(data)
    guard_issue_create = _guard_issue_create(data)
    return replace(cfg, legacy_map=legacy_map, legacy_keep=tuple(legacy_keep), label_colors=label_colors,
                   apply_prompt=apply_prompt, promotion=promotion, exec_gating=exec_gating,
                   intake_required=intake_required, guard_issue_create=guard_issue_create)


def _check_header(data: Dict[str, Any]) -> str:
    unknown = sorted(set(data) - set(TOP_KEYS))
    if unknown:
        raise ConfigError("unknown key(s): " + ", ".join(unknown))
    cadence = data.get("cadence")
    if cadence not in (None, "", []):
        raise ConfigError("`cadence` is a reserved contract key and must stay empty")
    if "contract" not in data:
        raise ConfigError("`contract` is missing (must be %d)" % CONTRACT)
    contract = data["contract"]
    if isinstance(contract, bool) or contract != CONTRACT:
        raise ConfigError("`contract` must be %d, got %r" % (CONTRACT, contract))
    if "mode" not in data:
        raise ConfigError("`mode` is missing (one of %s)" % ", ".join(MODES))
    mode = data["mode"]
    if mode not in MODES:
        raise ConfigError("invalid mode %r (one of %s)" % (mode, ", ".join(MODES)))
    return mode


def _labels_of(data: Dict[str, Any]) -> Dict[str, Any]:
    labels: Dict[str, Any] = dict(DEFAULT_LABELS)
    raw_labels = data.get("labels")
    if raw_labels is not None:
        if not isinstance(raw_labels, dict):
            raise ConfigError("`labels` must be a block of `axis: [values]`")
        for axis, values in raw_labels.items():
            if axis not in AXES:
                raise ConfigError("labels: unknown axis %r (fixed by contract 1: %s)" % (axis, ", ".join(AXES)))
            labels[axis] = _str_list(values, "labels.%s" % axis, _VALUE_RE)
    reserved = [v for v in labels["status"] if v in RESERVED_STATUS_VALUES]
    if reserved:
        raise ConfigError("labels.status: %s reserved for the cadence contract" % ", ".join(reserved))
    return labels


def _roles_of(data: Dict[str, Any], labels: Dict[str, Any]) -> Dict[str, Any]:
    roles: Dict[str, Any] = dict(DEFAULT_ROLES)
    raw_roles = data.get("roles")
    if raw_roles is not None:
        if not isinstance(raw_roles, dict):
            raise ConfigError("`roles` must be a block of `role: value`")
        for role, value in raw_roles.items():
            if role in SCALAR_ROLES:
                if not isinstance(value, str):
                    raise ConfigError("roles.%s must be a single value" % role)
                roles[role] = value
            elif role in LIST_ROLES:
                roles[role] = _str_list(value, "roles.%s" % role, _VALUE_RE)
            else:
                raise ConfigError("roles: unknown role %r" % role)
    for role, axis in ROLE_AXIS.items():
        values = [roles[role]] if role in SCALAR_ROLES else roles[role]
        for value in values:
            if value not in labels[axis]:
                raise ConfigError("roles.%s: %r is not a value of labels.%s" % (role, value, axis))
    return roles


def _flag_list(data: Dict[str, Any], key: str, default: List[str]) -> List[str]:
    if key not in data:
        return list(default)
    return _str_list(data[key], key, _FLAG_RE)


def _caps_of(data: Dict[str, Any], labels: Dict[str, Any]) -> Dict[str, int]:
    if "caps" not in data:
        return dict(DEFAULT_CAPS)
    raw_caps = data["caps"]
    if raw_caps is None:
        return {}
    if not isinstance(raw_caps, dict):
        raise ConfigError("`caps` must be a block of `\"axis:value\": N`")
    caps: Dict[str, int] = {}
    known = frozenset("%s:%s" % (axis, v) for axis, vs in labels.items() for v in vs)
    for name, cap in raw_caps.items():
        if name not in known:
            raise ConfigError("caps: %r is not an axis:value label of this config" % name)
        if isinstance(cap, bool) or not isinstance(cap, int) or cap < 0:
            raise ConfigError("caps.%s must be an integer >= 0" % name)
        caps[name] = cap
    return caps


def _validate(data: Dict[str, Any], source: str) -> Config:
    mode = _check_header(data)

    repo = data.get("repo")
    if repo is not None and (not isinstance(repo, str) or not _REPO_RE.match(repo)):
        raise ConfigError("`repo` must look like OWNER/NAME")

    labels = _labels_of(data)
    roles = _roles_of(data, labels)
    executor_flags = _flag_list(data, "executor_flags", DEFAULT_EXECUTOR_FLAGS)
    exclusions = _flag_list(data, "exclusions", DEFAULT_EXCLUSIONS)
    protected = _flag_list(data, "protected", DEFAULT_PROTECTED)
    caps = _caps_of(data, labels)

    cfg = _build(labels, roles, mode, repo, "ok" if mode != "off" else "mode is off in the config", source,
                 executor_flags, exclusions, protected, caps)
    return _with_catchup_keys(cfg, data)


def resolve_project_dir(override: Optional[str] = None) -> str:
    """`--project-dir` override, else CLAUDE_PROJECT_DIR, else the working directory."""
    return override or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def load_config(project_dir: Optional[str] = None) -> Config:
    """Load `<project_dir>/.claude/backlog.yml`. Never raises: every failure is mode `off` plus a reason."""
    path = Path(resolve_project_dir(project_dir)) / CONFIG_RELPATH
    if not path.is_file():
        return _defaults("off", "no .claude/backlog.yml", None)
    try:
        return _validate(parse_simple_yaml(path.read_text(encoding="utf-8")), str(path))
    except (ConfigError, OSError, UnicodeDecodeError) as exc:
        return _defaults("off", "invalid config (%s)" % exc, str(path))
