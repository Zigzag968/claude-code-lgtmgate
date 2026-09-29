# Maintaining lgtmgate

This file is for whoever maintains this plugin: the release/rollback runbook, the dev loop, and
the trust model of the delivery channel it ships through. Linked from `README.md`.

## 1. Dev loop (`--plugin-dir`)

Edit `workflows/feature-pipeline.js` (or any component) in a worktree, never on `main` directly.
Local pre-check: `git config core.hooksPath .githooks` runs `templates/test-canonical-guards.sh`
on every commit (a local pre-check only — see §5 Enforcement below for why it is not the real
gate).

Run the edited pipeline without publishing anything, via `--plugin-dir`:

```bash
printf '%s' '<prompt>' | claude --print --model claude-sonnet-5 --plugin-dir <WT> --allowed-tools Workflow
```

The prompt MUST arrive on stdin — a trailing prompt arg after `--allowed-tools` errors *"Input
must be provided"* (recorded on claude-agent-pipeline#50). Never publish to test: run the
`--plugin-dir` invocation and inspect its own output.

**`--plugin-dir` collision datum (P3, this session).** A `--plugin-dir` tree *contributes*
components under a colliding namespace — proven live: a throwaway plugin named `lgtmgate`
under `--plugin-dir` DID surface its own `workflows/collision-probe.js` under the
`lgtmgate:` namespace. **Precedence when the SAME namespaced name exists in BOTH the dev
tree and the installed cache is NOT proven** — contribution proven, precedence not proven. This is
unambiguous only until founder-gate item 18 (below) publishes 0.8.0. From that day the installed
cache also ships `lgtmgate:feature-pipeline`, so this is a **mandatory disambiguation
procedure, not a caveat**:

1. Before trusting ANY `--plugin-dir` dev run, set a dev-only version in the worktree — **both**
   `BUILD.version` in `workflows/feature-pipeline.js` **and** `.claude-plugin/plugin.json`'s
   `version` — to the same value, e.g. `0.9.0-dev` (this keeps `test-canonical-guards.sh`'s
   `stamp-parity` invariant green while making the run's origin unambiguous).
2. Run it, then CONFIRM the run's `logs[0]` / `result.buildStamp` (see §9) carries that
   `-dev` string.
3. **A stamp reading the published version (e.g. `lgtmgate@0.8.0` with no `-dev` suffix)
   means the installed cache served the run: the result is VOID.** Discard it and re-check the
   `--plugin-dir` flag actually reached the invocation.

The `-dev` value is never committed — it exists only in the worktree for the duration of the dev
loop. §4 (Release) governs what IS committed.

## 2. Names, S2→S4 window

The canonical pipeline component is `lgtmgate:feature-pipeline` (`workflows/` is a
default-scanned plugin directory). **Always use the namespaced name** — a bare `feature-pipeline`
can be shadowed by another `--plugin-dir` tree or a different installed plugin of the same
component name (claude-agent-pipeline#526's trap, inverted).

Until every consumer project migrates (S4), a not-yet-migrated project keeps its own copy at
`.claude/workflows/feature-pipeline.js`, launched by its explicit `scriptPath`, never by a bare or
namespaced name — see `commands/feature.md` step 1/4 for the resolution logic the Lead runbook
follows.

**Bare-name probe answer, recorded verbatim (this session, `--plugin-dir`, before 0.8.0 was
published) — UNSTABLE across invocations, never a reliable error.** The same headless runner,
invoked with the bare name `"feature-pipeline"` against this worktree, returned **three different
answers on the same day** depending on invocation context:

1. An isolated `--plugin-dir` capture returned a hard error, the Workflow tool's own message
   verbatim:
   ```json
   {"error": "Workflow \"feature-pipeline\" not found. Available: deep-research, lgtmgate:feature-pipeline"}
   ```
2. A re-capture invoked with the CLI's cwd pointed at an **unrelated project's** session
   directory (a mistake made while re-verifying this datum) silently "resolved" — but to a STALE,
   unrelated workflow script cached under that other project's own prior session, not this plugin
   at all: `status: "dry-run-ok"` with `agentCount: 0`, `logs: []`, and **no `buildStamp` field**.
   Wrong, plausible-looking, and not an error — the worse failure mode of the two.
3. A re-capture invoked with the CLI's cwd correctly set to **this worktree** resolved to the
   correct canonical component, `buildStamp` included:
   ```json
   {"logs": ["[pipeline] lgtmgate@0.8.0 cutFrom=c040169 workflow=feature-pipeline"], "result": {"buildStamp": "[pipeline] lgtmgate@0.8.0 cutFrom=c040169 workflow=feature-pipeline", "status": "dry-run-ok", "issue": 54, "mode": "semi", "entryStage": "plan"}}
   ```

So the bare name is **not safe to treat as either "always errors" or "always resolves"** — its
resolution depends on invocation state (cwd, concurrent sessions, uncontrolled ambient caches) that
a caller does not fully control. This raises "always use the namespaced name" (above) from a
convenience to a correctness requirement: whichever behavior you observe locally is not a promise
about the next invocation, and answer (2) shows the failure can be **silent and wrong**, not just a
loud "not found".

## 3. Enabling the plugin

This repo's own `.claude/settings.json` registers the `zigzag-plugins` catalog
(`extraKnownMarketplaces`) but does **NOT** ship `enabledPlugins`. This plugin declares
`"hooks": "./hooks/plugin-hooks.json"` — a SessionStart hook (`python3 inject_stub.py`), two
PreToolUse Bash hooks, a SubagentStop hook, and a Stop hook. Per the docs, a marketplace declared
in a repo's shared settings is registered "once they trust the project folder, with no separate
prompt" — trusting a folder must never, by itself, cause code to be fetched from GitHub and
executed on every session start and before every Bash call. Enabling is therefore an explicit,
per-user gesture, never implied by folder trust:

```bash
claude plugin install lgtmgate@zigzag-plugins
```

## 4. Release

Bump `.claude-plugin/plugin.json`'s `version` **and** `BUILD.version` in
`workflows/feature-pipeline.js` together; set `BUILD.cutFrom` to the short SHA the artifact's
content was **cut FROM** — the base commit it was derived from (a commit cannot carry its own SHA
— `cutFrom` is CONTEXT, not the identity key, and it is deliberately **unguarded**,
release-checklist-only; `version` is the guarded identity key). This is a **different** value from
the SHA the artifact is **published AT** — the catalog pin (`.claude-plugin/marketplace.json`
`source.sha`), moved by the founder's own publish commit below; the two frequently diverge (0.8.0's
`cutFrom` is `c040169`, its catalog pin moved to `f59e4e0`). `version` is declared rather than omitted, against the docs' own named idiom for an
"internal or actively developed plugin" (which would resolve to the source's commit SHA and
auto-deliver every commit on the pinned SHA), for two reasons: `version` is the stamp's
human-legible identity key (a 40-char SHA is not), and it gives the installed cache a legible
`lgtmgate/<version>` path — what founder-gate item 18 below inspects.

**An unbumped release delivers nothing at all** — a github-source plugin only updates a
consumer's cache when the manifest version differs from what they already have.

**No `CHANGELOG.md` file — the version-bump commit subject IS the changelog** (founder decision,
2026-09-15, legacy#86). Every paired bump above ships as its own conventional-commit subject (`fix:`,
`feat:`, `chore(publish):`, ...) referencing the issue/PR it closes, e.g. `fix: test-infra/guards
hygiene — stale counts, bash-3.2 floor, headless log pointer, pr-acceptance doctrine (legacy#157) (legacy#166)`.
`git log --oneline -- .claude-plugin/plugin.json` is the canonical, always-current release history
to consult — no separate file to keep in sync.

**`config.preflight.envNote` is TRUSTED-OPERATOR input, injected unescaped ahead of the hard
preflight checks** — same exposure class as `commands.test` / `regressionGuard.baselineCmd` (see
README.md's "How it stays generic" trust warning for the full enumeration). A PR touching only
`pipeline.config.json` is a code-review surface, not inert data.

**Enforcement is human, not mechanical, on this repo.** `.github/workflows/guards.yml` runs
`templates/test-canonical-guards.sh` and the offline flow suite on every PR to `main` and
**reports** — it **CANNOT be a required check on this repo**: branch protection and repository
rulesets are both unavailable here (verified 2026-08-23 — see §5 Trust root for the exact probe).
The bump is therefore enforced by a **reviewed acceptance-checklist line on every PR that touches
the shipped surface**, never by CI blocking a merge; `.githooks/pre-commit` (per-clone
`core.hooksPath` opt-in) is a local pre-check one layer below that, not the enforcement either.

**Publishing (founder decision, 2026-08-23, route confirmed 2026-09-12): merging the publish PR
is the founder-only gesture — never an agent, never the unattended nightly runner.** A commit
cannot carry its own SHA, so publishing moves `.claude-plugin/marketplace.json`'s `lgtmgate`
entry's `source.sha` forward to the just-merged release commit via a **separate, one-line PR**,
never a raw push to `main`:
1. Prepare the one-line `source.sha` bump on a branch and push **the branch**, not `main`.
2. Open a PR.
3. The founder merges it — clicking Merge on GitHub, or running `gh pr merge <N> --squash` himself
   from an interactive session. This is the confirmation point; the squash-merge commit this
   produces on `main` IS the publish commit, there is no separate manual commit step beyond it.

A raw `git push origin main` for this gesture is refused by the Claude Code auto-mode classifier
(confirmed from both the main checkout and a throwaway worktree, `dangerouslyDisableSandbox:true`
in both — ruling out a sandbox-filesystem cause) on top of `.claude/settings.json`'s own
`git push origin main` deny rule — so the branch+PR route is the only working one, for the founder's
own session as much as any agent's.

**Non-goal:** an agent must never run `gh pr merge` on this publish PR itself — barred by this
repo's own `.claude/rules/pr-acceptance.md` "Autonomie en session non supervisee" hard rule
("jamais un `gh pr merge` direct par un agent"). Whether an agent should ever be allowed to run
`gh pr merge` on this repo's own publish PR, once the founder is comfortable with the pattern, is a
distinct, not-yet-decided policy change — tracked separately at issue legacy#140, not documented as
canonical here.

**This marketplace is PRIVATE — never rely on background auto-update.** The docs state plainly:
*"private-marketplace auto-updates may fail intermittently."* Every release and every rollback is
therefore always the same explicit three-step sequence, never a wait-and-see:

```bash
claude plugin marketplace update zigzag-plugins
claude plugin update lgtmgate
# restart Claude Code — required to apply
```
Followed by a **mandatory stamp verification** (§9) — do not consider a release or a rollback
landed until the installed cache's `buildStamp` / `installPath` actually shows the intended
version.

## 5. Trust root

**The trust root is push access to `Zigzag968/lgtmgate`'s `main`, ALONE.** This repo
is private on a plan where branch protection and rulesets are both **unavailable** — verified this
session: `gh api repos/Zigzag968/lgtmgate/branches/main/protection` and
`gh api repos/Zigzag968/lgtmgate/rulesets` both return HTTP 403, *"Upgrade to GitHub
Pro or make this repository public to enable this feature."* So `main` accepts any push from any
credential with write access, unreviewed: no required reviews, no required status checks, no
force-push protection. The `sha` pin on the marketplace entry is a **release gate**, not an
integrity control — it stops unreviewed commits *between* releases from being auto-delivered, and
it makes "which commit is live" an explicit, reviewable value — but **there is no second control
behind it**. The marketplace **catalog** that carries the pin is itself fetched from the same
mutable `ref: main` (git-based marketplace sources support `ref`, not `sha`), so one push to
`main` moves the catalog and the pin together, in one gesture.

This is an **accepted residual** (founder decision, 2026-08-23, option (c)): the repo stays
private on the free plan; no branch protection/rulesets are purchased. The mitigations actually in
place are (1) the publish commit is a founder-only interactive gesture (§4), never automatable,
and (2) this repo's `.claude/settings.json` denies any agent session from pushing to `main`
outright. Making the repo public (free rulesets would then apply) was considered and declined for
this slice; revisit if the residual proves costly in practice.

## 6. Post-merge ordering (hard)

After this slice (S2) merges, **publish + update + restart is the FIRST thing done**, before any
further slice (S3a–S5) is launched — those later slices are themselves run BY this pipeline, so
the pipeline must be live on the artifact they touch. Until publish happens, run the pipeline via:

```
Workflow({ scriptPath: '<repo>/workflows/feature-pipeline.js', args: {...} })
```

**This is also the rollback runbook's end state** (§7) — after any rollback, the repo returns to
exactly this same "publish + update + restart is the first thing done" state, and the same
`scriptPath` interim path applies until the pin is moved forward again.

## 7. Rollback

No `--version` pin exists on install, and there is no downgrade-on-install
(anthropics/claude-code#62446, anthropics/claude-code#33302) — a rollback is always: move the `lgtmgate` entry's
`source.sha` on `main` back to the target commit, push (founder-only, §4), then:

```bash
claude plugin marketplace update zigzag-plugins
claude plugin update lgtmgate
# restart — required to apply
```

**Hard warning: any SHA before this slice (S2) has no `workflows/` directory at all.** Pinning
there does not restore an "older pipeline" — it removes the component ENTIRELY. Harmless pre-S4
while every consumer still carries its own `.claude/workflows/feature-pipeline.js` copy; a dead
plugin pipeline everywhere once S4 retires those copies. Valid rollback targets are therefore
always **>= the S2 merge commit**.

Because this repo ships no `enabledPlugins` (§3), the auto-updating population during a rollback
window is bounded to the founder's own machines that have explicitly installed the plugin — a
known, owned window, not the open internet. Move the pin forward again immediately after any
rehearsal; do not leave it pointed backward.

## 8. Emergency override

If the marketplace pin is stuck, broken, or you need to run a patched copy that has not been
published: `Workflow({ scriptPath: '<abs path to a locally patched copy>' })`, and for the flow
suite, `args.fpScriptPath` pointing at the same patched copy. Never re-add a tracked
`.claude/workflows/feature-pipeline.js` copy to this repo as a workaround — that is exactly the
drift class this slice retired.

## 9. Which artifact served a run (forensics)

To find out which artifact actually served a given run:

- **`logs[0]`** of a headless run's `output_file` (see `scripts/run-workflow-headless.sh`), or
- **`buildStamp`** on any recorded return (every terminal return of the pipeline carries it — see
  the `finish()` wrapper at the top of `workflows/feature-pipeline.js`).

`version` is the identity key (guarded by `templates/test-canonical-guards.sh`'s `stamp-parity`
invariant); `cutFrom` is context and does **not** contain the artifact — to fetch what actually
served a run, check out the release commit whose `.claude-plugin/plugin.json` version equals the
stamp's `version`.

**`installed_plugins.json`'s `gitCommitSha` is written at first install and is NOT refreshed on
update.** Observed this session: `installPath .../lgtmgate/0.7.1`, `lastUpdated
2026-08-20`, `gitCommitSha 2644c16` — a 2026-06-11 *"bump 0.1.1"* commit, four releases stale.
Never read `gitCommitSha` as "what's currently live" — read the `installPath` version segment and
cross-check the `buildStamp` from an actual run instead.

## 10. The backlog plugin

`plugins/backlog/` is a **second, independent plugin** of this marketplace (`backlog`, issue legacy#218).
The repo root stays the `lgtmgate` plugin root, so `backlog` lives in
a subdirectory and is delivered through a path-scoped catalog source
(`source: git-subdir`, `path: plugins/backlog`) instead of the root. It is inert unless a repo has
`.claude/backlog.yml` (see `plugins/backlog/README.md`), and it has NO effect on the S2→S4 window
(§2): it adds no workflow, agent or command, and the `lgtmgate` catalog pin is untouched.

**Independent version.** `plugins/backlog/.claude-plugin/plugin.json` carries its own `version`
(starts at `0.1.0`). Invariant 1 of `templates/test-canonical-guards.sh` excludes `plugins/backlog/`
by name (a deliberate exemption, like `scripts/`), and invariant 16 (`backlog-bump-required`) applies
the same "unbumped release delivers nothing" rule to that manifest, with `tests/` and `README.md`
exempt. Invariant 17 (`backlog-marketplace-pin`) validates the catalog entry and invariant 18
(`backlog-suite`) runs the plugin's offline unittest suite. Changing anything under `plugins/backlog/`
other than tests/README therefore needs a `backlog` version bump; it does NOT need an `lgtmgate`
bump. (Editing `templates/test-canonical-guards.sh` itself does, as it is watched surface.)

**The placeholder pin, and why it fails closed.** The `backlog` catalog entry ships with
`source.sha` set to the `lgtmgate` entry's current pin: a real, resolvable commit that has NO
`plugins/backlog/` directory. Until the founder publishes, an install therefore fails instead of
silently tracking `main` (a `git-subdir` source without `sha` would follow `ref: main`, unpinned; per
the marketplace docs, when both `ref` and `sha` are set the `sha` is the effective pin). A relative
`./plugins/backlog` source is not used either: it has no per-plugin pin.

**Publication and install are the founder's gestures, never an agent's** — same rule as §4. Order:

1. Merge the PR that adds `plugins/backlog/` (the founder, per the acceptance checklist).
2. Prepare a **one-line PR** that moves the `backlog` entry's `source.sha` to the merge commit of
   step 1 (branch + PR, never a raw push to `main`, §4) and merge it. That merge is the publish.
3. Install ONCE, at user scope, then restart Claude Code:
   ```bash
   claude plugin marketplace update zigzag-plugins
   claude plugin install backlog@zigzag-plugins --scope user
   ```
4. Verify the `installPath` in `installed_plugins.json` ends with `/backlog/0.1.0` (never trust
   `gitCommitSha`, §9). A repo then opts in by adding `.claude/backlog.yml`; without it the plugin
   does nothing there.

There is no per-repo copy, no `enabledPlugins` and no repo-level install anywhere (§3: enabling is an
explicit per-user gesture). **Rollback** is the §7 logic for this entry: move the `backlog` entry's
`source.sha` back to the previous release commit (founder-only), then run the same marketplace update
and restart; a target commit before the merge of step 1 has no `plugins/backlog/`, which uninstalls it.

**Caveats to settle at install time (only the founder can observe them).** `git-subdir` is a newer
marketplace source type: an older Claude Code client that does not know it rejects the whole catalog
(anthropics/claude-code#35805), `lgtmgate` included, so update the client first. And because the
`url` points at this PRIVATE repo, the clone relies on the user's git credentials.

## 11. Public-switch checklist (not yet scheduled)

If this repo is ever made public, revisit:

- (a) `README.md`'s "This repo's own marketplace is **private**..." line — the behavior it
  describes ("auto-updates may fail intermittently") no longer applies once the marketplace is
  public; correct or remove that sentence at that point.
- (b) `## 5. Trust root` above — the 2026-08-23 founder decision accepts staying private (with no
  branch protection/rulesets) as a residual; re-evaluate that decision explicitly before any
  switch, since going public also changes the trust-root analysis (free rulesets would then
  apply).
- (c) This switch is **not planned by issue legacy#257** (scope S, non-blocking) — this section is a
  pointer for whoever picks it up later, not a decision made here.
