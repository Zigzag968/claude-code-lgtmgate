# Supervising runs in flight

Reference material for orchestrator builders. See the [README](../README.md#supervision-of-runs-in-flight)
for the one-paragraph summary; this doc has the full mechanism.

Any orchestrator built on this plugin (a one-shot `/lgtmgate:deliver` session, a scheduled
runner, anything else) is expected to persist per-run state and supervise it — a run left silently
stuck is exactly the failure mode this plugin exists to prevent.

## State-file convention

`<project>/.pipeline/**/<id>.json`, one JSON object per run. Must include a top-level `"status"`
string field — a `.json` file with no `"status"` field isn't a state file per this convention and
is ignored by the watchdog. The watchdog uses a whitelist: only `"in-progress"`, `"plan"`, `"dev"`,
`"review"` count as in-flight and are eligible for staleness. Everything else is skipped — terminal
values (`"merged"`, `"blocked"`, `"done"`), awaiting-human values (`"pr-ready"`, `"needs-founder"` —
the run is correctly parked waiting on a human, not silently stuck; see
[PR-awaiting-merge reminder](#pr-awaiting-merge-reminder) below, the dedicated channel for that
wait), the awaiting-EXTERNAL value `"blocked-by"` (the run is correctly parked waiting on an issue
in ANOTHER repo — see [Cross-repo blockedBy signal](#cross-repo-blockedby-signal) below), an absent
status, and any unrecognized/typo'd value (fails safe: never flagged as stuck).

## Staleness threshold

`.claude/pipeline.config.json` -> `{"supervision": {"staleMinutes": N}}`, default `30`. A
whitelisted in-flight state file whose own mtime is older than the threshold is stale. Timestamps
are always the file's mtime (code), never model-reported.

## The `Stop` hook

`hooks/Stop-supervise-runs.sh` scans `.pipeline/` on every `Stop` event (millisecond-fast, no
network, no `gh`). If it finds a stale run it blocks the stop (exit 2) and re-prompts: *"Pipeline
run(s) in flight with no activity... Do a guard round: resume if resumable / block / escalate."*
An anti-spam sidecar (`<state-file>.nudged`) rate-limits re-nudging the **same** run to at most
once per threshold window.

The mechanism is the floor; the doctrine is the why. `SessionStart`'s injected stub and
`/lgtmgate:deliver`'s runbook both carry the same bounded supervision doctrine (alive -> don't
touch; resumable -> resume, 2-3 attempts max, never loop; silent past the threshold -> block and
escalate) so an orchestrator does the right thing even before the hook would catch it.

Regression test: `hooks/test-Stop-supervise-runs.sh` (bash, zero dependency — no `jq`, no `gh`, no
network). Run it after any change to the hook's status vocabulary or staleness logic.

## Contamination check (opportunistic)

`"runId"` is an optional top-level state-file field (e.g. `"wf_<hex>-<hex>"`). When a whitelisted
in-flight state file carries it, the `Stop` hook also resolves that run's `Workflow` transcript dir
and calls `scripts/verify-workflow-launch.sh` on it — the mechanical detector for the harness
stale-message-injection bug (anthropics/claude-code#96640, #95369). No `"runId"` -> skipped, exactly
like an absent `"status"` is skipped. The transcript-dir lookup root is overridable via
`CLAUDE_PROJECTS_DIR` (defaults to `~/.claude/projects`, used by the hook's own tests for a hermetic
fixture) and its result is cached per-run in a `.transcriptdir` sidecar. On a detected injection the
hook blocks the Stop (exit 2) via the same anti-spam pattern as staleness, rate-limited by a
`.contam-nudged` sidecar. Remove this wiring once anthropics/claude-code#96640/#95369 ship a fix
upstream.

## Cross-repo `blockedBy` signal

One-sided, machine-readable: a run parked on a precondition in ANOTHER repo un-parks itself instead
of being hand-polled by the Lead. The blocked side stores `blockedBy` locally and READS the
blocker's public labels via `gh` — the blocker repo needs zero cooperation, it just carries its
normal label. State MUTATION stays the orchestrator's job; the plugin only ships the schema and a
read-only probe.

State file — `<project>/.pipeline/<id>.json`, additive, every `blockedBy` key optional except
`repo`/`issue`:

```json
{
  "issue": 799,
  "status": "blocked-by",
  "blockedBy": {
    "repo": "Zigzag968/lgtmgate",
    "issue": 100,
    "resolveOnLabel": "auto:merged",
    "since": "2026-08-30T09:12:00Z",
    "note": "S4 needs resolveWorktreeRoot() to land upstream"
  },
  "lastTouchedAt": "2026-08-30T09:12:00Z"
}
```

`resolveOnLabel` defaults to `auto:merged` when absent.

**Resolver**: `bash .claude/scripts/blocked-by-check.sh <state-file>` (installed by `/lgtmgate:init`
from `templates/blocked-by-check.sh`) — read-only, always prints a fixed trailer as its last line:

```
[blocked-by] status=resolved repo=Zigzag968/lgtmgate issue=100 label=auto:merged
```

| verdict | exit | meaning / orchestrator action |
|---------|------|-------------------------------|
| `none` | 0 | no `blockedBy` key — nothing to do |
| `resolved` | 0 | `resolveOnLabel` present on the referenced issue — unblock the run |
| `pending` | 10 | label absent, issue not finally closed — stay parked |
| `abandoned` | 11 | referenced issue CLOSED with `stateReason: NOT_PLANNED` and no label — will never resolve, escalate to a human |
| `unknown` | 20 | probe failed, or state file / `blockedBy` malformed — fail-closed on the unblock decision, stay parked |

`BLOCKED_BY_PROBE_CMD` env var overrides the `gh` call with a command printing the same JSON — the
offline test seam used by `templates/test-blocked-by-check.sh`.

## PR-awaiting-merge reminder

`SessionStart`'s stub also does a best-effort check for open issues/PRs labeled `auto:pr-ready` on
the current repo (an orchestrator convention where CI-green-and-undrafted is a terminal state and a
human merges by hand — a scheduled/unattended runner is one consumer of it, not the only possible
one) and injects a one-line reminder: `⏳ N PR(s) awaiting founder review: #a, #b`.

- **Never blocks or slows down session start beyond its own short timeouts**: 2s for the `git
  remote` check, 3s for the `gh issue list` call — both well under the hook's 15s manifest timeout.
- **Silent on any failure**: no git, no `gh`, no network, rate-limited, not a `github.com` remote,
  anything — the reminder is just omitted, never an error, never a delay beyond the timeouts above.
- Only runs at all if `origin` resolves to a `github.com` remote (SSH or HTTPS).
