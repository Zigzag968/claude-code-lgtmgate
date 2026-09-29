# lgtmgate

A stack-agnostic **feature delivery pipeline** for Claude Code. Four specialized agents take a GitHub issue from framing to a merge-ready PR, orchestrated by a small per-project workflow and configured entirely through `.claude/pipeline.config.json` — no stack assumptions baked into the plugin.

```
Mia (PM, optional)  ->  Sam (scout + plan)  ->  Nick (dev + tests + PR)  ->  Morgan (review)
                                                          ^                        |
                                                          +---- loop on changes ---+
```

- **Mia** — frames the feature (acceptance criteria + success metrics tied to existing analytics events). Runs only when the issue's `pm_review` box is checked. (haiku)
- **Sam** — scouts the codebase, produces an *anchored* impact table + implementation plan + acceptance checklist, posts it on the issue. Never writes app code. (sonnet)
- **Nick** — implements Sam's plan with meaningful tests, opens a draft PR, copies the acceptance checklist into the body. (sonnet)
- **Morgan** — impartial reviewer: regression guard + convention review + acceptance-checklist gate + CI verification, posts a verdict. Never commits. (sonnet)

The Lead (you, or the orchestrator) creates a **shared worktree** and drives the workflow; the agents share that worktree so plan, code, and review sit on the same frozen base.

## Prerequisites

- **`gh` CLI, installed and authenticated** (`gh auth login`, scopes `repo` + `project`) — required structurally by nearly every hook, script and agent in this pipeline. See `/lgtmgate:init` for the GH Project field detail.
- **`jq`** — required by `hooks/block-merge-unchecked.sh` and `hooks/deny-destructive-git.sh` (PreToolUse gates on every Bash call) — both hooks fail closed (exit 2) if `jq` is missing.
- **Node.js** — runs `workflows/feature-pipeline.js`, `scripts/run-flow-suite.cjs`, and the consumer's copied `.claude/workflows/test-feature-pipeline.js`.
- **Python 3** — runs `hooks/SessionStart/inject_stub.py`.
- **`git`** with a `github.com` remote.
- **`bash`** (3.2 floor — see the `bash-3.2-floor` invariant in `templates/test-canonical-guards.sh`).

## Install

1. Add the marketplace and enable the plugin in your `settings.json` (project `.claude/settings.json` or global). Note the **object** forms — `source` is a nested object and `enabledPlugins` is a map:

   ```json
   {
     "extraKnownMarketplaces": {
       "zigzag-plugins": {
         "source": { "source": "github", "repo": "Zigzag968/lgtmgate" }
       }
     },
     "enabledPlugins": {
       "lgtmgate@zigzag-plugins": true
     }
   }
   ```

   Or via the CLI: `claude plugin marketplace add Zigzag968/lgtmgate` then `claude plugin install lgtmgate@zigzag-plugins`.

2. **Restart the session** so the plugin loads (its agents, hooks, and commands become available).

3. In the target project, run:

   ```
   /lgtmgate:init
   ```

   This copies the project-facing machinery into `.claude/` (`workflows/test-feature-pipeline.js`, `scripts/gh-pipeline-status.sh`, `rules/pr-acceptance.md`) and generates `.claude/pipeline.config.json` (detecting/asking for your stack's build/test/format commands, base branch, worktree root, CI checks, GH Project), then offers to wire the GitHub issue/PR templates. **Commit what `init` produces.** The pipeline itself, `workflows/feature-pipeline.js`, ships as this plugin's own workflow component and resolves as `lgtmgate:feature-pipeline` — it is NOT copied into the consuming project (see `MAINTAINING.md` for the S2→S4 migration window and the enablement gesture below).

4. Deliver a feature:

   ```
   /lgtmgate:feature <issue> "<brief>"
   ```

## Update

```
claude plugin marketplace update zigzag-plugins
claude plugin update lgtmgate
```

Restart Claude Code to apply. The marketplace's `lgtmgate` entry carries `ref: "main"` **and** a pinned `sha` — an unbumped `plugin.json` version is never delivered, and only a maintainer moving that `sha` on `main` publishes a new release. See `MAINTAINING.md` for the full release/rollback runbook, the trust-root wording, and why `version` is declared rather than omitted here. This repo's own marketplace is **private**; per the docs, private-marketplace background auto-updates "may fail intermittently" — always run the two commands above explicitly rather than relying on the background refresh.

## How it stays generic

Nothing stack-specific lives in the plugin. Everything project-dependent is read from `.claude/pipeline.config.json` and passed into the workflow + agent prompts:

| Config key | Used for |
|------------|----------|
| `commands.{build,test,format}` | exact commands Nick/Morgan run |
| `conventionsRule` | the project's code-convention rule Sam/Nick/Morgan align on |
| `baseBranch`, `branchPrefix` | branching for the shared worktree + PR target |
| `worktreeRoot` | where the Lead creates the shared worktree — logical/versioned default; precedence `$AGENT_PIPELINE_WORKTREE_ROOT` > `.claude/pipeline.config.local.json` (gitignored) > this value > wtPath's parent dir for the Dev-phase prompt context (legacy#61) — `/feature` itself still needs this key set to CREATE the worktree (legacy#101) |
| `ciChecks` | checks Morgan must see green before LGTM |
| `regressionGuard.{testGlob,testFnPattern,baselineCmd}` | Morgan's regression guard: no-checkout test scoping plus the exact baseline-capture command run for the SET-DIFF |
| `ghProject` | optional GH Project "Pipeline Status" updates |
| `planAudit` | adversarial plan-soundness audit before Dev, default `false`; worst case is `maxAuditRounds × maxPlanAttempts` extra spawns |
| `branchOverride` (arg, else `config.branchOverride`) | exact branch name used verbatim instead of `<branchPrefix>issue-<N>` (rebase-without-force-push, numbered slices); chars limited to `[A-Za-z0-9._/-]`; skips the config-prefix reconcile. A top-level `branchPrefix` arg is ignored (config wins) and logs a warning + trace `branch-prefix-arg-ignored`; config.branchPrefix absent/blank additionally traces branch-prefix-fallback-default (legacy#267) |
| `planFreshness` | plan-freshness check before Dev: `advisory` (default) warns Nick + traces `plan-stale:<n>` when a plan-declared target file moved on `origin/<baseBranch>`; `gate` escalates before Nick is spawned; `off` skips the probe entirely |
| `models` | per-role model override `{ scout?, planAudit?, morgan? }`, default `sonnet` for all three; resolution is `arg > config.models > 'sonnet'` (same precedence as `planAudit`) — Theo/Nick are not overridable |
| `stack` | target stack string handed to the plan auditor; empty → inferred from the worktree |
| `preflight.envNote` | free-form operator note injected verbatim ahead of every preflight check, notably the HARD test-command check — see the trust warning below |
| `preflight.envSymlink` | `required` (default, current behavior) / `forbidden` (envless-by-contract projects: preflight asserts `.env` is ABSENT) / `ignore` (check omitted) — enum-validated, the value is never interpolated into agent text |
| `provision.extraLinks[].optional` | marks a configured link as soft: absent at provision time degrades to a loud skip instead of a hard `provision-failed` escalate |

A dependency install blocked by sandbox TLS is reported as a blocker, never bypassed — the two
levers that make the install unnecessary in the first place are (a) pre-linking the project's
`.venv`/`node_modules` into the worktree via `provision.extraLinks` (consumed by
`scripts/provision_worktree.sh`) and (b) `preflight.envNote` for run-specific environment
constraints.

The agents (`agents/*.md`) are fully de-specialized and reusable on any stack: Swift/iOS, Node, Python, Rust, etc.

**Trust warning: TRUSTED-OPERATOR input.** Every value in `.claude/pipeline.config.json` reaches an
agent as command text or as authoritative instruction — `commands.build`, `commands.test`,
`commands.format`, `regressionGuard.baselineCmd`, `baseBranch`, `branchPrefix`,
`preflight.envNote`, `stack` are all interpolated raw into strings an agent is instructed to run or
treat as authoritative, with no quoting or validation — EXCEPT `provision.extraLinks`, the only key
validated in-code (the `safeLinkPath` traversal/metacharacter guard in
`workflows/feature-pipeline.js`). A pull request touching only `pipeline.config.json` is therefore
a **code-review surface, not data**: review it with the same scrutiny as a change to the workflow
script itself.

## Structure

```
.claude-plugin/
  plugin.json            # manifest
  marketplace.json       # marketplace zigzag-plugins
agents/                  # Mia, Sam, Nick, Morgan (generic)
commands/                # /lgtmgate:init, /lgtmgate:feature
hooks/
  plugin-hooks.json      # SessionStart stub + PreToolUse merge gate + SubagentStop warn + Stop watchdog
  SessionStart/inject_stub.py
  block-merge-unchecked.sh
  SubagentStop-worktree-cleanup.sh
  Stop-supervise-runs.sh # watchdog for stale .pipeline/ runs — see below
  test-Stop-supervise-runs.sh # zero-dependency regression test for the watchdog above
workflows/               # this plugin's own workflow component (default-scanned)
  feature-pipeline.js    # resolves as lgtmgate:feature-pipeline — NOT copied
templates/               # copied into the consuming project by /lgtmgate:init
  test-feature-pipeline.js
  pr-acceptance.md
  gh-pipeline-status.sh
  test-gh-pipeline-status.sh # offline regression test for the resolver above
  blocked-by-check.sh    # read-only cross-repo blockedBy resolver — see below
  test-blocked-by-check.sh # offline regression test for the resolver above
  pipeline.config.template.json
  test-canonical-guards.sh # this repo's own release guard net — see MAINTAINING.md
  github/                # snippets for the project's GH issue/PR templates
plugins/
  backlog/               # second plugin of this marketplace — see "Second plugin: backlog" below
```

## Second plugin: backlog

`plugins/backlog/` is a separate, independently versioned plugin (`backlog@zigzag-plugins`): `/backlog:file`, `/backlog:triage` (propose-only) and `/backlog:next`, driven by a per-repo `.claude/backlog.yml`. It is inert in any repo without that file. Install it once at user scope: `claude plugin install backlog@zigzag-plugins --scope user`. See `plugins/backlog/README.md` for the modes and config, and `MAINTAINING.md` section 10 for its release and publication sequence.

See `MAINTAINING.md` for the dev loop (`--plugin-dir`), naming (`lgtmgate:feature-pipeline`), the release/rollback runbook, and the trust-root of the marketplace pin.

## Supervision of runs in flight

Any orchestrator built on this plugin (a one-shot `/lgtmgate:feature` session, a scheduled
runner, anything else) is expected to persist per-run state and supervise it — a run left silently
stuck is exactly the failure mode this plugin exists to prevent.

- **State-file convention**: `<project>/.pipeline/**/<id>.json`, one JSON object per run. Must
  include a top-level `"status"` string field — a `.json` file with no `"status"` field isn't a
  state file per this convention and is ignored by the watchdog. The watchdog uses a whitelist:
  only `"in-progress"`, `"plan"`, `"dev"`, `"review"` count as in-flight and are eligible for
  staleness. Everything else is skipped — terminal values (`"merged"`, `"blocked"`, `"done"`),
  awaiting-human values (`"pr-ready"`, `"needs-founder"` — the run is correctly parked waiting on a
  human, not silently stuck; see [PR-awaiting-merge reminder](#pr-awaiting-merge-reminder) below,
  the dedicated channel for that wait), the awaiting-EXTERNAL value `"blocked-by"` (the run is
  correctly parked waiting on an issue in ANOTHER repo — see "Cross-repo blockedBy signal" below),
  an absent status, and any unrecognized/typo'd value (fails safe: never flagged as stuck).
- **Staleness threshold**: `.claude/pipeline.config.json` -> `{"supervision": {"staleMinutes": N}}`,
  default `30`. A whitelisted in-flight state file whose own mtime is older than the threshold is stale.
  Timestamps are always the file's mtime (code), never model-reported.
- **The `Stop` hook (`hooks/Stop-supervise-runs.sh`)** scans `.pipeline/` on every `Stop` event
  (millisecond-fast, no network, no `gh`). If it finds a stale run it blocks the stop (exit 2) and
  re-prompts: *"Pipeline run(s) in flight with no activity... Do a guard round: resume if resumable
  / block / escalate."* An anti-spam sidecar (`<state-file>.nudged`) rate-limits re-nudging the
  **same** run to at most once per threshold window.
- **The mechanism is the floor; the doctrine is the why.** `SessionStart`'s injected stub and
  `/lgtmgate:feature`'s runbook both carry the same bounded supervision doctrine (alive -> don't
  touch; resumable -> resume, 2-3 attempts max, never loop; silent past the threshold -> block and
  escalate) so an orchestrator does the right thing even before the hook would catch it.
- **Regression test**: `hooks/test-Stop-supervise-runs.sh` (bash, zero dependency — no `jq`, no
  `gh`, no network). Run `bash hooks/test-Stop-supervise-runs.sh` after any change to the hook's
  status vocabulary or staleness logic.
- **Contamination check (opportunistic)**: `"runId"` is an optional top-level state-file field
  (e.g. `"wf_<hex>-<hex>"`). When a whitelisted in-flight state file carries it, the `Stop` hook
  also resolves that run's `Workflow` transcript dir and calls `scripts/verify-workflow-launch.sh`
  on it — the mechanical detector for the harness stale-message-injection bug
  (anthropics/claude-code#96640, #95369). No `"runId"` -> skipped, exactly like an absent
  `"status"` is skipped. The transcript-dir lookup root is overridable via `CLAUDE_PROJECTS_DIR`
  (defaults to `~/.claude/projects`, used by the hook's own tests for a hermetic fixture) and its
  result is cached per-run in a `.transcriptdir` sidecar. On a detected injection the hook blocks
  the Stop (exit 2) via the same anti-spam pattern as staleness, rate-limited by a
  `.contam-nudged` sidecar. Remove this wiring once anthropics/claude-code#96640/#95369 ship a fix upstream.

### Cross-repo `blockedBy` signal

One-sided, machine-readable: a run parked on a precondition in ANOTHER repo un-parks itself
instead of being hand-polled by the Lead. The blocked side stores `blockedBy` locally and READS
the blocker's public labels via `gh` — the blocker repo needs zero cooperation, it just carries
its normal label. State MUTATION stays the orchestrator's job; the plugin only ships the schema
and a read-only probe.

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

**Resolver**: `bash .claude/scripts/blocked-by-check.sh <state-file>` (installed by
`/lgtmgate:init` from `templates/blocked-by-check.sh`) — read-only, always prints a fixed
trailer as its last line:

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
human merges by hand — the nightly runner is one consumer of it, not the only possible one) and
injects a one-line reminder: `⏳ N PR nightly awaiting founder review: #a, #b`.

- **Never blocks or slows down session start beyond its own short timeouts**: 2s for the `git remote`
  check, 3s for the `gh issue list` call — both well under the hook's 15s manifest timeout.
- **Silent on any failure**: no git, no `gh`, no network, rate-limited, not a `github.com` remote,
  anything — the reminder is just omitted, never an error, never a delay beyond the timeouts above.
- Only runs at all if `origin` resolves to a `github.com` remote (SSH or HTTPS).

## License

MIT
