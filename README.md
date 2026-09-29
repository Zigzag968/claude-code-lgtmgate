# lgtmgate

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code Plugin](https://img.shields.io/badge/Claude%20Code-plugin-5A32FB)](https://code.claude.com/docs/en/plugins)

**Agents open the PR. They never merge it.** A stack-agnostic feature delivery pipeline for Claude Code: five specialized agents take a GitHub issue from framing to a merge-ready PR behind a mechanical acceptance gate — configured entirely through `.claude/pipeline.config.json`, no stack assumptions baked into the plugin.

## Why lgtmgate

- **The merge gate is mechanical, not vibes.** Every PR carries an acceptance checklist written by the planner and ticked only against cited proof (a command's output, an artifact) — a hook refuses `gh pr merge` while any box is unchecked.
- **The reviewer never fixes, the fixer never merges.** Morgan (review) is a separate role from Nick (dev) — no agent reviews its own work, and merging stays a human gesture throughout this codebase, including in this repo's own release process.
- **Diagnosis before code.** Theo reproduces a claimed bug for real (never "a code read as proof") or sanity-checks a feature before Sam ever plans on it — catches issues that don't hold up before they cost a dev cycle.

## Example

```
$ /lgtmgate:feature 142 "Login page shows a stale error after a successful retry"
```

1. **Theo** reproduces the stale-error state, confirms it's real, hands off to Sam.
2. **Sam** posts an anchored plan on issue #142: impact table, `file:symbol` implementation steps, an acceptance checklist Morgan can verify offline.
3. **Nick** implements it in the shared worktree, opens a draft PR with the checklist copied into the body — unticked.
4. **Morgan** runs the regression guard, checks conventions, ticks each box against real proof, posts a verdict:
   - `REQUIRED_CHANGES` → Nick fixes, Morgan re-reviews. Loops until resolved.
   - `LGTM` → PR undrafted, ready. **You merge it.**

## Engineering highlights

Nothing here is asserted — every number is `bash <script>` away from a stranger's own terminal:

- **709 offline test cases, zero network/mocked-API dependency**, across 6 suites: `templates/test-canonical-guards.sh` (20 release invariants), `scripts/run-flow-suite.cjs` (177 pipeline-logic cases), `plugins/backlog/tests/` (467 Python unit tests), `templates/test-blocked-by-check.sh` (9), `hooks/test-Stop-supervise-runs.sh` (17), `hooks/test-deny-destructive-git.sh` (19).
- **Adversarial plan audit** (opt-in, `planAudit`): a separate auditor agent challenges Sam's plan before Nick writes a line of code, bounded to a hard round ceiling so a disagreement can't spiral into runaway spawns.
- **Regression guard by SET-DIFF, not a blind re-run**: Morgan captures a baseline against the pre-change branch and diffs the exact test set the change touched — catches a newly-broken adjacent test without re-running the whole suite on every PR.
- **Isolated by construction**: every run gets its own git worktree; Theo, Sam, Nick and Morgan share it so plan, code and review sit on the identical frozen base — the pipeline never touches your own working checkout.
- **A documented trust boundary, not a claimed sandbox**: `SECURITY.md` states plainly what this plugin does and doesn't protect against (`.claude/pipeline.config.json` is trusted-operator input, not sandboxed against injected prompt content) — see the full threat model there.

## Agents

```
Theo (diagnose, mandatory) -> Mia (PM, optional) -> Sam (scout + plan) -> Nick (dev + tests + PR) -> Morgan (review)
                                                                                    ^                        |
                                                                                    +---- loop on changes ---+
```

- **Theo** — qualifies the issue before Sam plans on it: actually reproduces a claimed bug (never a code read as proof), or sanity-checks that a feature/chore is justified. Runs on every dispatch, no opt-out. Never proposes a fix. (sonnet)
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
script itself. See `SECURITY.md` for the full threat model.

## Structure

```
.claude-plugin/
  plugin.json            # manifest
  marketplace.json       # marketplace zigzag-plugins
agents/                  # Theo, Mia, Sam, Nick, Morgan (generic)
commands/                # /lgtmgate:init, /lgtmgate:feature
hooks/
  plugin-hooks.json      # SessionStart stub + PreToolUse merge gate + SubagentStop warn + Stop watchdog
  SessionStart/inject_stub.py
  block-merge-unchecked.sh
  SubagentStop-worktree-cleanup.sh
  Stop-supervise-runs.sh # watchdog for stale .pipeline/ runs — see docs/supervision.md
  test-Stop-supervise-runs.sh # zero-dependency regression test for the watchdog above
workflows/               # this plugin's own workflow component (default-scanned)
  feature-pipeline.js    # resolves as lgtmgate:feature-pipeline — NOT copied
templates/               # copied into the consuming project by /lgtmgate:init
  test-feature-pipeline.js
  pr-acceptance.md
  gh-pipeline-status.sh
  test-gh-pipeline-status.sh # offline regression test for the resolver above
  blocked-by-check.sh    # read-only cross-repo blockedBy resolver — see docs/supervision.md
  test-blocked-by-check.sh # offline regression test for the resolver above
  pipeline.config.template.json
  test-canonical-guards.sh # this repo's own release guard net — see MAINTAINING.md
  github/                # snippets for the project's GH issue/PR templates
plugins/
  backlog/               # second plugin of this marketplace — see "Second plugin: backlog" below
docs/
  supervision.md         # full reference for run supervision, staleness, cross-repo blockedBy
```

## Second plugin: backlog

`plugins/backlog/` is a separate, independently versioned plugin (`backlog@zigzag-plugins`): `/backlog:file`, `/backlog:triage` (propose-only) and `/backlog:next`, driven by a per-repo `.claude/backlog.yml`. It is inert in any repo without that file. Install it once at user scope: `claude plugin install backlog@zigzag-plugins --scope user`. See `plugins/backlog/README.md` for the modes and config, and `MAINTAINING.md` section 10 for its release and publication sequence.

## Supervision of runs in flight

Any orchestrator built on this plugin is expected to persist per-run state (`.pipeline/**/<id>.json`) and supervise it: a `Stop` hook watchdog detects a run that's gone silent past a configurable threshold and blocks/re-prompts instead of letting it die unnoticed, with a matching one-sided signal for a run blocked on another repo's issue. **Full mechanism, state-file schema, and the cross-repo `blockedBy` protocol: [docs/supervision.md](docs/supervision.md).**

## Contributing & learn more

- **Contributing**: see [CONTRIBUTING.md](CONTRIBUTING.md) for the dev loop, conventions, and PR expectations.
- **Maintaining / releasing**: see [MAINTAINING.md](MAINTAINING.md) for the `--plugin-dir` dev loop, naming (`lgtmgate:feature-pipeline`), the release/rollback runbook, and the trust-root of the marketplace pin.
- **Security**: see [SECURITY.md](SECURITY.md) for the threat model and how to report a vulnerability privately.
- **Code of conduct**: see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## License

MIT
