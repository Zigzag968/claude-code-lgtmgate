## A PR's acceptance checklist is a living gate

> Hard rule. A PR's acceptance checklist (its **Acceptance checklist** section) is an **executable
> gate**, not decoration. A checked box is a verification claim ; an unchecked or stale box blocks
> the merge.

### Who writes it — Sam
Sam drafts the checklist in the plan (posted on the issue). Every item MUST be :
- **Relevant** — an acceptance criterion that actually matters for what the PR ships.
- **Verifiable by Morgan** — a concrete command Morgan can run, or an artifact he can inspect.
  Never an item Morgan cannot verify (no "looks good", no manual step out of his reach).
- **Marked `[human-gate]` only for a decision, an authorization or an action to perform, or a judgement no
  read-only command can confirm.** A human-gate item carries no `command`; a command written in its text is
  judged by the plan check (a command that could decide the item is not conforming; a judgement about
  wording, layout or taste is).

**When `[human-gate]` applies.** Before tagging an item `[human-gate]`, ask whether the box asks someone to decide, authorize or perform an action (tag it), or only to confirm that an action already happened (do not tag it). A confirmation has a read-only command (a run-status query, a policy read, a log read): write that command as a normal Morgan-verifiable box and cite the earlier human decision inline in the item text. Default to a normal box whenever a read-only command exists; tag only a genuine judgment call or an action no read-only command can confirm.

Each item is a `- [ ]` line. Nick copies the checklist **verbatim** into the PR body when it opens,
**between the markers** `<!-- acceptance:start -->` and `<!-- acceptance:end -->`.

An issue filed by an agent declares its dependencies (`backlog_cli.py file --blocked-by N`) or states `depends-on: none` in its body.

### Who proves & checks it — Morgan
Morgan runs / inspects each item, then :
- Checks the box `- [x]` in the PR body (`gh pr edit <N> --body ...`) **only** after having seen
  the proof.
- Cites that proof (command + output, or the artifact) in his review comment.
- Only renders **LGTM once every box is checked** (with ids: once every box is proven in `boxes`, the
  workflow doing the checking). A single remaining `- [ ]` (with ids: a box not proven), or a box that
  contradicts the diff, is **REQUIRED_CHANGES** — never LGTM.
- An absent or empty acceptance block (no `acceptance:start`/`acceptance:end` marker pair, or no
  `- [ ]`/`- [x]` line between them) is **REQUIRED_CHANGES**, never LGTM; Morgan's `items` carries the
  literal line `Acceptance block absent or empty`.
- With ids (an `<!-- ac:N -->` comment after each checkbox) Morgan does not edit the body: she returns
  `boxes` (`{id, proven, proof}` for EACH box, one that already reads `[x]` included: she proves every box
  again at every round, and a box with no proven entry this round is not proven whatever the body shows) and
  the workflow ticks the proven ids through the write probe. A `[human-gate]` box is never ticked by the
  workflow and is settled only by the body showing it checked by a person (her `proven` means nothing for it).
  If the write is refused the workflow parks the run itself (`verified-untickable`, no Nick round,
  `untickableItems[]` = `{id, item, proof}`); the Lead re-verifies the proofs and checks the boxes by hand. A run without ids keeps the manual tick: Morgan checks the box
  after the proof, and a refused tick is left open with a one-line `tick pending (permissions)` entry.

### Markers (mandatory)
The acceptance block lives between two HTML markers in the body :

```
<!-- acceptance:start -->
- [ ] <verifiable criterion>
- [ ] <verifiable criterion>
<!-- acceptance:end -->
```

The hook (below) inspects **only** the `- [ ]` boxes located between these two markers. The
template's other checkboxes (remoteconfig section) are out of scope and never block the merge.

Each line carries an id comment, `- [ ] <!-- ac:N --> <criterion>` (N = the 1-based position; a
human-gate box reads `- [ ] <!-- ac:N --> [human-gate] <criterion>`). The workflow renders the lines
from the `acceptanceItems` Sam returns, Nick pastes them verbatim and Morgan returns a `boxes` entry
(`id`, `proven`, `proof`) per id, repeating the `<!-- ac:N -->` comment wherever he quotes a box. A
body without ids (opened before this format) still parses.

### Body order (artifact-first)
The PR body follows a fixed, artifact-first order : `Closes #N` on the first line ->
`## What this ships` (bullet summary of the diff) -> optional `## <Human> — N gestures`
(ONLY IF a `[human-gate]` item exists in the checklist, otherwise omit the H2 — never ship
an empty stub section) -> `## Acceptance checklist` (the block between the markers
`<!-- acceptance:start -->`/`<!-- acceptance:end -->`) -> an EMPTY pair
`<!-- decision-log:start -->`/`<!-- decision-log:end -->` (workflow-owned, never hand-filled) ->
fold `<details><summary>Technical detail</summary>` (test plan / feature flag / risk). This is the
order the `pr-body-structure` invariant (`templates/test-canonical-guards.sh`) mechanically checks
against Nick's Dev-phase prompt and against `agents/nick.md`.

### Scope pivots
If the scope changes mid-PR, the checklist is updated in the **same PR** (Sam amends it ; Nick
syncs the body). A checklist that contradicts the diff blocks the merge — a stale criterion is a
defect, not a detail.

### Enforcement
- **Morgan is the primary gate** (above) — no LGTM with an open or unproven box.
- A `PreToolUse` hook (`.claude/hooks/block-merge-unchecked.sh`) refuses `gh pr merge` as long as
  the body's acceptance block contains a `- [ ]`. **Known limitation** (like the `pre-push` hook) :
  it only intercepts `gh` merges inside a hooked session — a merge via the GitHub UI is not
  caught, so Morgan's gate remains the real control.

## Autonomy in unsupervised sessions (hard rule)

> Applies to any pipeline session with no human present to answer a prompt (a scheduled runner,
> an unattended long-running session, etc.) — Sam, Nick, Morgan, Mia, Theo are all held to it
> equally.

- **Deletions**: `git rm <file>` for any tracked file, never a bare `rm`/`rm -rf`. Untracked
  temporary files -> the session scratchpad or `$TMPDIR`, never deletion in place.
- **Renames**: `git mv <src> <dst>`, never a bare `mv` on a tracked file.
- **Zero interactive commands**: never a shell prompt (no `-i`, no interactive editing, no
  blocking pager) — everything must run fully non-interactively.
- **Zero sudo, zero global install**: no privilege elevation, no `npm install -g` /
  `pip install --user` / `brew install` outside the project's `.venv`/`node_modules`.
- **Stay inside the worktree**: every read/write stays under the worktree assigned to the issue
  (`$WT_PATH`) ; never crossing into another worktree, another repo, or outside the assigned tree.
- **A refused/blocked command: work around it first, within bounds** — try an alternative within
  the allowed surface (e.g. `rm` refused -> `git rm` ; missing tool -> an equivalent already
  available). Maximum **2-3 DIFFERENT approaches** per blocker ; NEVER re-run the identical command
  hoping for a different result ; never loop on the same obstacle. Alternatives exhausted ->
  explicit failure status — an external orchestrator translates it into `no-go`/`escalate`/error and
  then into a blocking label for human handling (see also the `Stop` in-flight run guard hook,
  which detects a non-terminal run gone silent past a configurable threshold).
- **TLS/certificate failure on a dependency install under sandbox** (`OSStatus -26276`,
  `problem confirming the ssl certificate`, `tls: failed to verify certificate`, `x509`) is a
  **known tooling limitation**, not a broken environment : never bypass the sandbox for it
  regardless — explicit failure status, blocker reported to the Lead/human. Never `sudo` nor a
  global install ; stay inside the project's `.venv`/`node_modules`.
- **Strict prohibitions, even as an attempted alternative**: an interactive command, `sudo`, a
  global install, bypassing a guard (hook, merge assert), disabling or bypassing the tooling
  sandbox. These limits are never one of the 2-3 approaches — they fail the blocker immediately.
- **Never push to the base branch outside a feature branch**: the merge is a gesture external to
  the pipeline (a dedicated merge script), never a direct `gh pr merge` by an agent.

## Relationship with `code-review-impartial.md`

The two rules complement each other, **zero overlap** :

| Rule | Nature | What it guarantees |
|-------|--------|---------------------|
| **pr-acceptance** (this rule) | **Mechanical** gate | Criteria are checked + proven, enforced by the hook. Binary objective: every box checked with proof, otherwise merge refused. |
| **code-review-impartial** | **Human** process | The reviewer is **impartial** (distinct from the Sam/Nick fixers), re-reviews after every substantial update. Objective: a cold-eyed judgment of the code, free of complacency bias. |

**Morgan applies both**: he checks the acceptance boxes (mechanical gate) AND conducts the
impartial review (qualitative judgment of the diff). A PR only merges when both converge —
checklist fully proven AND the reviewer's YES with no blocking reservation (or the <Human>
decides).

## Why
A checklist nobody runs or maintains is a *false verification signal*. This rule forces every box
to be either proven-and-checked, or removed — never decorative.

## Self-reference false positive (`self-reference-preflight`, legacy#83)

> PR class: the diff modifies the pipeline's own preflight/gate-generation surface
> (`workflows/deliver-pipeline.js`, the preflight prompt, or a project's preflight support
> script). A PR of this class can wrongly fail the very HARD-check it fixes.

- **Mechanism** — the running `Workflow()` executes the script snapshot read at DISPATCH time ; it
  therefore observes a POST-PR branch with PRE-PR gate logic.
- **Rule** — when the requirement stated by a HARD-check failure is literally what the diff
  removes/changes AND the worktree state matches the post-merge state the PR targets (verified
  independently, never by re-running the stale check), this is a known false positive ->
  escalate to the Lead, never mutate the worktree to satisfy the check.
- **Consequence on acceptance** — for this PR class, every checklist item must be verifiable
  **offline against the branch's files** (grep/diff/scripts run against the branch), never "the
  live preflight passes".
