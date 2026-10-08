# backlog

Config-driven backlog discipline for GitHub repos, shipped as a plugin of the `zigzag-plugins` marketplace. It generalizes reference tooling proven in production: one label taxonomy, an intake that cannot create a malformed issue, a propose-only triage and a deterministic "what is next" picker.

**Inert by default.** The plugin does nothing in a repo that has no `.claude/backlog.yml`: no `gh` call is reachable, the hook exits before reading anything, and the skills are user-invoked only.

## Install (once, user scope)

Install it ONCE for your user, at a pinned version. There are no per-repo copies.

```bash
claude plugin marketplace update zigzag-plugins
claude plugin install backlog@zigzag-plugins --scope user
```

Restart Claude Code, then confirm the install path ends with `/backlog/0.5.0`. A repo opts in by adding `.claude/backlog.yml` (copy `templates/backlog.template.yml`); until then nothing happens there. Publication of a new pin is the maintainer's gesture, see `MAINTAINING.md` section 10.

## Skills

All three are user-invoked (`disable-model-invocation: true`): nothing about them is loaded into a session until you type the command.

| Skill | What it does |
|-------|--------------|
| `/backlog:file` | Validates one new issue (exactly one `type:`, status forced to the intake one, no protected or human flag, caps, duplicate title, labels that exist in the repo). Dry run first; creates only as the repo mode allows. |
| `/backlog:triage` | Lists the issues awaiting triage, validates a proposals file and prints the review table. Propose-only: there is no apply path. |
| `/backlog:next` | Prints the next issue an agent may pick up (ready, agent executor, small, not blocked, no open PR). Read-only. |

`/backlog:file` also accepts `--blocked-by N` (repeatable) to declare GitHub native dependencies of the new issue. The dry run prints one `[backlog-file] planned blocked-by: #N` line per link and creates nothing; the sorted list is part of the payload digest, so `--confirm` covers it. After a successful create, each link is written through the REST dependencies endpoint (`DepGh`, never GraphQL; needs mode `write-supervised` or `free` AND `repo:`, checked BEFORE the create). A link that fails after the create prints an error naming the created issue and the missing links, exit 1. At most 10 links per call.

They run `python3 -B "${CLAUDE_PLUGIN_ROOT}/scripts/backlog_cli.py" <subcommand>` (subcommands: `config`, `next`, `lint`, `file`, `inbox`, `triage-check`, `label-sync`, `snapshot`, `rollback`, `catchup`, `set`, `guard`). Python 3.9+, standard library only: no PyYAML, no pip install.

## Modes

Set in `.claude/backlog.yml`. A missing file, a missing or invalid `mode`, a missing `contract`, an unknown key or any invalid value all resolve to `off`.

| Mode | Reads (`next`, `lint`, `inbox`, `triage-check`, dry runs) | `/backlog:file` creation |
|------|------|------|
| `off` | none: nothing runs, no `gh` call | never |
| `propose` | yes | never: always a proposal, "nothing created" |
| `write-supervised` | yes | only with `--apply --confirm <payload-digest>` (the digest printed by the dry run) |
| `free` | yes | with `--apply` |

The plugin's GitHub writes are exactly four: `gh issue create` (through `Gh`, `/backlog:file`), through the separate `ApplyGh` class and only behind the gate of the catch-up tooling or of the single-issue `set` below, `gh issue edit --add-label/--remove-label` and `gh label create`, and, through the third sibling `DepGh`, REST writes of the native "Blocked by" dependencies (`file --blocked-by`, `set --blocked-by/--unblock`). `snapshot` and `catchup propose --out` write local files outside any repo (the apply journals are local files too). Nothing closes, comments on or deletes an issue, and nothing edits, renames or deletes a label. **The mode is a ceiling**: `off` and `propose` never write anything to GitHub, and `write-supervised` and `free` write only when every condition of the apply gate holds (`free` waives none of them).

## The `gh` chokepoint

`scripts/backlog_gh.py` is the only module that spawns a process. It holds three classes. `Gh` refuses everything outside four reads (`issue list`, `issue view`, `pr list`, `label list`) and one write (`issue create`), builds the argv itself (a caller cannot pass a repo override, a browser/editor flag or an assignment), injects the configured `repo`, applies the mode rules and enforces a call cap and a write cap; `Gh.WRITE_ALLOW` stays exactly `{("issue", "create")}`. Reads fail closed: a failing call, an unparsable payload or a possibly truncated list is an error, never an empty queue.

`ApplyGh` is a sibling class (not a subclass) used only by the catch-up apply path and by the single-issue `set`. It allow-lists two verbs with their flags (`issue edit` with `--add-label` / `--remove-label`; `label create` with `--color` / `--description`), injects `-R <repo>` itself, validates every issue number and label name (`^[A-Za-z0-9][\w.:-]*$`, a trailing newline is refused), a 6-hex color, at most 50 issues per batch, and refuses to build without an `ApplyGrant`. Only `scripts/backlog_apply.py` mints a grant, after the whole gate passed, and a test enforces that it is the only constructor. There is no delete, rename or `label edit` verb, and no skill names or calls the applier.

## Config reference (`.claude/backlog.yml`, contract 1)

`templates/backlog.template.yml` writes every default out. Only `contract` and `mode` are required.

| Key | Meaning |
|-----|---------|
| `contract` | must be `1` |
| `mode` | `off`, `propose`, `write-supervised`, `free` |
| `repo` | optional `OWNER/NAME`, injected as `-R`; default: `gh` resolves it from the working directory |
| `labels` | axis to value list; the `<axis>:` prefix is implied. Axes are fixed by the contract: `type`, `status`, `priority`, `exec`, `size`, `area`. List order is the rank for `priority` and `size`. An empty `area` list means a free axis that is never validated. |
| `roles` | which values play which role: `intake`, `waiting`, `ready`, `epic`, `bug`, `split` (sizes that must be split before ready), `candidate_sizes`, `agent` and `human` (executors) |
| `executor_flags` | bare labels that count as an Executor (default `nightly`) |
| `exclusions` | bare labels that keep an issue out of the queue and that intake refuses to set |
| `protected` | labels a proposal or an intake must never touch; a trailing `*` is a prefix (`auto:*`) |
| `caps` | open-issue cap per full label, e.g. `"priority:0-now": 2` |
| `legacy_map` | optional block `legacy label: axis:value`; the target must be a label of `labels` and never the `ready` status nor an agent executor (promotion stays a human decision). Keys cannot be protected, axis labels, exclusions or executor flags. Used by `catchup` |
| `legacy_keep` | optional inline list of `legacy_map` keys that stay on the issue next to their canonical label |
| `label_colors` | optional block `axis: hex`, 6 hex characters without `#` (quote all-digit colors, an unquoted `123456` is refused). Default `ededed`. Used by `label-sync` |
| `apply_prompt` | `none` (default, silent) or `ask`. With `ask`, an agent Bash command that runs an apply subcommand of the plugin CLI gets a human confirmation prompt (hook rule H2). Any other value puts the repo in mode `off` |
| `promotion` | `none` (default) or `checked`. With `checked`, the single-issue `set` may add `status:ready` or an agent executor when the deterministic check passes (section "Single-issue changes and promotion"). `none` keeps every promotion a human decision. Any other value puts the repo in mode `off` |
| `exec_gating` | `promotion` (default) or `triage`. `promotion` keeps today's behaviour: `status:ready` OR an agent executor both require the deterministic promotion check. `triage`: an agent-executor add is a plain triage label, only `status:ready` still runs the check. Either way, a labelless issue's first `set --apply` is exempt from promotion as long as it isn't requesting `status:ready` itself (the bootstrap carve-out). Any other value puts the repo in mode `off` |
| `intake_required` | inline list of axes (default `[type]`); `/backlog:file` refuses to create an issue (dry run and apply) missing any of them. `status` is always covered by `lint()`'s own check regardless of this list. Any entry outside `type`/`status`/`priority`/`exec`/`size`/`area` puts the repo in mode `off` |
| `guard_issue_create` | `true` (default) or `false`. With the default, the hook denies a bare `gh issue create` in modes `write-supervised` and `free` (the only qualified creation path is `/backlog:file`); `false` opts a repo out of that denial. Any other value puts the repo in mode `off` |

The reader is a deliberately small YAML subset: comments, `key: scalar`, `key: [a, b]` and one nested level of two-space-indented `key: value` lines. Anchors, tags, tabs, block lists, flow maps, duplicate keys and deeper nesting are refused (mode `off`). Values are plain strings; the label values `in-review` and `done` are reserved and refused.

## Catch-up tooling (dry run first, then a gated apply)

Bring a repo that carries legacy labels onto the configured taxonomy. Every command is a dry run until you pass `--apply` and the whole apply gate below holds. The target repo is always the `repo:` of the config (`--repo OWNER/NAME` on any of these commands is an assertion that must match it, never a selector); `snapshot` and `rollback` refuse to run without `repo:`.

| Subcommand | What it does |
|------------|--------------|
| `label-sync` | Derives one label per `axis:value` of the config (colored by `label_colors`) and prints `create`, `ok` or `drift` (color only, case-insensitive) per label, then a `dry-run: create=N ok=N drift=N unmanaged=N` summary. Reads the live labels with `gh label list`. `--apply` creates the missing labels only (`drift` is reported and never touched, there is no label edit). |
| `snapshot` | Freezes the labels of every issue (all states) into `snapshot.json` + `snapshot.sha256` + an executable `rollback.sh`. |
| `rollback --snapshot-dir DIR --expect-sha SHA` | Recomputes from the snapshot which labels would have to be added or removed to restore it and prints the table with a `table-digest`. Checks the sha, the snapshot version and that the snapshot belongs to the config's repo. `--apply` restores the labels of the issues that were open in the snapshot AND are still open; a closed or absent issue is skipped with a `skip:` line, and the run ends with `restored=N skipped=M`. |
| `catchup propose` | Builds baseline proposals from `legacy_map` (`--issues-file` for offline use, `--out FILE` to save them). |
| `catchup check --proposals FILE` | Validates a proposals file with the triage rules plus the catch-up rules and prints the review table and a `table-digest` bound to the repo (the same table gives another digest for another repo). `--strict` exits 1 on any rejection. `--apply` applies the accepted proposals. |

**The apply gate.** `label-sync --apply`, `catchup check --apply` and `rollback --apply` write to GitHub only when ALL six conditions hold. Each missing one is exit 1 with `refused: <code>` and ZERO write call:

| Code | Condition |
|------|-----------|
| `mode` | the mode is `write-supervised` or `free` (`propose` and `off` never write; `free` waives none of the other five) |
| `repo` | `repo:` is present in the `.claude/backlog.yml` of the target |
| `apply` | `--apply` is passed (`--confirm` alone is refused) |
| `confirm` | `--confirm` equals the `table-digest` printed by the dry run. It is bound to the repo, to the table and, for `label-sync` and `catchup`, to the snapshot sha: pass the same `--snapshot-dir` and `--expect-sha` to the dry run |
| `snapshot` | a verified snapshot: `--snapshot-dir` (outside any repo) and `--expect-sha` match its sha256, its version and its repo, and it covers every proposed issue with the labels the proposal starts from (`labels_before`); otherwise take a fresh snapshot |
| `rejected` | the validation of the FRESH live data rejects nothing (`stale-before`, `issue-not-open`, `unknown-label`, `role-add-refused`, caps...) |

Typical run: `snapshot`, then the dry run with `--snapshot-dir DIR --expect-sha SHA` (read the table, note the digest), then the same command with `--apply --confirm <digest>`. There is no tty gate: the barrier is that digest bound to the repo and to the snapshot, the hook rule below (opt-in through `apply_prompt: ask`), and the fact that no skill can reach the applier.

**What an apply does.** It re-reads the live issues and re-validates at apply time, then, per issue, diffs against the live labels and runs two sequential calls: add, then remove. It refuses to ADD the `ready` status or an agent executor label (`role-add-refused`): promotion stays a human triage decision for every bulk path, and that includes a `rollback` that would re-add them (the line is skipped, restore it by hand). The only path that may promote is the single-issue `set` below, one issue at a time, behind `promotion: checked`. It never deletes, renames or edits a label, and never touches a protected label.

**Journals and batches.** After EVERY issue the run rewrites a journal next to the snapshot, atomically (temp file, `fsync`, `os.replace`): `applied.json` (catch-up), `rollback-applied.json`, `label-sync-applied.json`. A journal belongs to one table and one snapshot (another one is refused). The run stops at the first failure (exit 1, journal current, a half-done issue is `partial`) and works in batches of at most 50 issues: when more remain it prints `batch limit reached ... re-run the same command to resume` and exits 0; the same command line resumes without re-validating or re-editing the journaled issues.

**Local state.** `snapshot` writes ONLY local files, in a NEW directory outside any repo: by default `~/.backlog-snapshots/<OWNER>__<NAME>/<UTC yyyymmddThhmmssZ>/` (`--snapshot-dir` overrides it). The target is refused when it is under the project, under the plugin or under any directory that holds a `.git` (a `.git` directly in your home does not count), and an existing `snapshot.json` is never overwritten. The directory is `0700`, the files `0600`, `rollback.sh` `0700`. `catchup propose --out` follows the same rules for its one file. **The plugin never deletes state**: clean up old snapshots yourself with `rm -r`.

**Mapping rules (`catchup`).** Per axis except `area`, the labels an issue already has plus the mapped targets must resolve to ONE label, else the issue is `unresolved` with `<axis>-conflict`. Exception: `type` with no `type:` label yet and several mapped targets picks the FIRST one in the order of `labels.type` (confidence `medium`); this differs from the reference's fixed order (epic, bug, feature, chore). No type at all is `type-unmapped`. A missing status becomes the intake status. Mapped legacy labels are dropped unless they are in `legacy_keep`. Adding the `ready` status or an agent executor label is always refused (`role-add-refused`).

**Limits.** Labels have no description (the config carries none, `label-sync` never compares descriptions). The reference's `P3-parked` (a human decision) and `nightly` with `triage:interactive` (an executor conflict) cases are not expressible in the mapping. There is no `label edit` / rename path.

## Single-issue changes and promotion (`set`)

`backlog_cli.py set --issue N` changes the axis labels of ONE issue. Each of `--status`, `--type`, `--size`, `--exec`, `--priority` and `--area` takes a value of the config and REPLACES the labels of its axis on the issue (`--status needs-info` removes the live `status:*` label and adds `status:needs-info`); at least one flag is required (an axis flag, `--blocked-by` or `--unblock`). `--area` accepts any value when the axis is free (the default, empty `labels.area`). Adding a capped label (`--priority` by default) fetches the open issues and counts it the same way `label-sync`/`catchup` do: `cap-exceeded:<label>` refuses it, otherwise it is admitted. There is no way to name a raw label. `--reason` is written to the journal only, `--repo OWNER/NAME` is an assertion that must match `repo:`.

It is a dry run unless `--apply`. The change is validated like a triage proposal (owned axes only, protected labels never touched, labels that exist in the repo, the lint of the resulting state, a fresh read), then printed:

```
[set] #123 status:inbox -> status:needs-info (+status:needs-info -status:inbox)
[set] dry-run only: nothing was written (add --apply)
```

`--apply` writes only when the mode is `write-supervised` or `free` (for `set` the two behave the same: there is no digest to confirm), `repo:` is present, the fresh live read validates and the **journal line of the intent could be written BEFORE the write**: no journal, no write. The write is the same add-then-remove pair of `issue edit` calls as the catch-up, through `ApplyGh`. The journal is `<project>/.claude/.backlog-snapshots/set-journal.jsonl` (directory `0700`, file `0600`, INSIDE the project, gitignored, append-only): an `intent` line with the labels before, the change and the verdict counts, then an `applied`, `partial` or `failed` line. The plugin never deletes it. Unlike the bulk `snapshot`/`catchup`/`rollback` tooling above (which stays outside any repo on purpose, so a bulk mistake is recoverable even if the checkout is gone), the single-issue `set` journal lives in-project so it writes under a sandboxed Claude Code session's default scope (CWD + temp dir) without a harness-level config change — trade-off: it does not survive deletion of the checkout it was written from, and each worktree of the same repo gets its own journal.

**Dependencies.** `--blocked-by M` and `--unblock M` (both repeatable, alone or combined with axis flags) add or remove the native "Blocked by" links of the issue, REST only (`DepGh`, never GraphQL). Dry run prints `[set] #N planned blocked-by: +#M` / `-#M`; a `--blocked-by` already in the live `blockedBy` (or an `--unblock` of a link that is not there) is a noop for that link. `--blocked-by` on the issue itself, and a number in both lists, are refused before any call. `--apply` needs the same conditions as the label write (mode `write-supervised` or `free`, `repo:`), and each dependency change is journaled in `set-journal.jsonl` (an `intent` line with `"kind": "dependencies"` BEFORE the write, then `applied`, `partial` or `failed`). With axis flags, the label write runs first, then the dependencies.

**Promotion.** Adding `status:ready`, or an agent executor when `exec_gating: promotion` (the default — see `exec_gating` above), is refused (`promotion-off`, before any read) unless the repo opted in with `promotion: checked`. Then, on the same fresh read, a pure check (`scripts/backlog_promote.py`) must find none of these misses; all of them are listed at once:

**Bootstrap carve-out (fixes legacy#259).** A labelless issue's first `set --apply` that picks up its type/status/size/exec labels together (e.g. `--status inbox --type feature --size S --exec agent`) is a triage bootstrap, not a readiness promotion, as long as it does not itself request `status:ready`: it is exempt from the check above (no acceptance checklist required) in either `exec_gating` value. Requesting `status:ready` too, or a non-empty `before` state, falls back to the ordinary check.

| Code | Miss |
|------|------|
| `no-acceptance` | fewer than one checkbox line (`- [ ] text`) in the issue text |
| `size-not-candidate` | no size of `roles.candidate_sizes` after the change (`L` is not one by default) |
| `no-type` | no `type:` label after the change, or the epic type |
| `exclusion:<label>` | a label of `exclusions` (`cross-repo`, `money-path`) |
| `open-blocker:<n>` | an open issue blocks this one |
| `blockers-unknown` | the blocker data is missing or truncated (fail closed) |
| `human-executor` | the issue carries a human executor: the plugin never converts one |
| `protected-present:<label>` | a protected label (`nightly`, `cross-repo`, `auto:*`) is on the issue |

`nightly` is never set by any path of the plugin, so a promotion queues an issue for an interactive `/backlog:next` session, never for unattended overnight work. The bulk paths (`catchup`, `rollback`, `label-sync`) still refuse `ready` and agent executors, as before.

**What changed about reading issue text.** Until 0.3.0 the write path never read the free text of an issue. Now exactly one module, `backlog_promote.py`, interprets it, for one issue per `set` call, and only when that call asks for `status:ready` or an agent executor (a demotion or a lateral change never fetches it; the read is `gh issue view` with a fixed field list, `body` added only for a promotion). The text is never printed, never placed in a command line and never journaled: only the count of checkboxes is. A test keeps the list of modules that name it.

**Residual risk, stated plainly.** A checkbox is typed by whoever wrote the issue: no regex can tell a real acceptance list from a forged one, so the checkbox condition can be satisfied by an author who wants it to be. The check strips the cheap forgeries (a checkbox inside a code fence or an HTML comment, an empty item, a `[ ]` with no list marker, text beyond 65536 characters) and it is one condition of seven; the others read structured data an author cannot forge by typing. What remains: an agent that files or edits an issue and then promotes it in the same session passes the check by writing its own checkboxes. The opt-in default, the mode ceiling, the human prompt of rule H2 (when enabled), the journal and the fact that `nightly` is never set bound the damage; they do not remove it. No skill names or calls `set`: an agent reaches it only through a Bash command.

## The hook

One `PreToolUse` hook on `Bash`. Its first line tests for `.claude/backlog.yml` (resolved from `CLAUDE_PROJECT_DIR`, else the working directory) and exits 0 when it is absent: no stdin read, no `jq`, no Python. With a config it exits fast unless the command mentions `gh`, then applies four rules:

* **Deny, namespace-touch** (exit 2): RAW label writes naming an owned-axis label (`type:`, `status:`, `priority:`, `exec:`, `size:`) in modes `propose` and `write-supervised`. Modes `off` and `free` never deny here; `nightly`, `cross-repo`, `auto:*` and `area:*` are never blocked.
* **Deny, bare issue creation** (exit 2, modes `write-supervised` and `free`, opt-out `guard_issue_create: false`): a raw `gh issue create` is denied — the only qualified creation path is `/backlog:file`.
* **Deny, doctrine (taxonomy)** (exit 2, every mode but `off` — including `free`, which the first rule never gates): a label naming a declared axis (`type`/`status`/`priority`/`exec`/`size`) with a value NOT in `.claude/backlog.yml` is denied, naming the axis, the offending value and the declared values. A free axis (no declared values, e.g. the default `area: []`) and any bare flag are out of scope. This also covers the REST bypass: `gh api repos/OWNER/REPO/issues/N/labels` (or `/labels`) with a `-f`/`-F`/`--raw-field`/`--field` naming an undeclared value.
* **Ask, rule H2, opt-in** (`apply_prompt: ask` in `.claude/backlog.yml`; default `none`, silent, so normal work raises no permission prompt): when enabled, an agent Bash command that runs `backlog_cli.py` with `label-sync`, `catchup`, `rollback` or `set` and `--apply` (or the generated `rollback.sh --apply`) gets the human confirmation prompt (exit 0 with `permissionDecision: "ask"`), in every mode except `off`. The human validation already happens on the dry-run table, whose digest `--confirm` must equal (for `set`, on the printed plan of the dry run). `PreToolUse` supports `allow`, `deny`, `ask` and `defer` (Claude Code hooks reference). **Unverified**: what an `ask` does in a session with no human (`dontAsk`, a nightly runner) is not documented; the expected outcome is a refusal, but do not rely on it. All three deny rules and the ask rule are best effort (a regex over the command string, not a shell parser): the real gate is the applier's own conditions. The doctrine rule in particular does not parse a piped/`--input -` JSON body of a `gh api` call — a known gap, not full coverage.

The hook injects no context, fails open on any error and registers no other event.

## Context cost (measured)

Measured offline by `tests/test_skills.py` (`test_context_cost_report`). The always-loaded figure is the sum of the description characters of every skill that is NOT `disable-model-invocation: true`, i.e. what would ride in every request.

`[context-cost] always-loaded-description-chars=0 skills=3`

| Skill | Description chars (loaded only when invoked) |
|-------|------|
| `file` | 87 |
| `next` | 61 |
| `triage` | 71 |

## Reserved: cadence contract (not implemented)

A later phase may add an iteration cadence. It is reserved, not built: the `cadence` key is accepted only when empty (any content puts the repo in mode `off`), and the status values `in-review` and `done` are refused. The reserved contract is a `Status` field including `in-review` and `done`, a `Size` field, an empty `Iteration` field and `contract: 1`.

## Integration with lgtmgate: deferred (follow-up)

The pipeline's Sam and Morgan agents file non-blocking findings with a raw `gh issue create --title "tech-debt: ..."`. Routing that through `/backlog:file` is intentionally NOT part of this release: the plugin is not installed yet, and the skills are user-invoked, so an agent cannot call them through the Skill tool. The raw call carries no labels, so the guard above does not block it in the meantime.

## Follow-ups (not in this release)

1. Route the `tech-debt:` issue creation of the pipeline agents through `/backlog:file` once the plugin is published and an agent-callable path is decided.
2. Triage apply (label edits from `/backlog:triage` proposals) behind `write-supervised`, journaled. The catch-up write path shipped in 0.3.0 and the single-issue `set` in 0.4.0; triage still has none.
3. Optional hardening of promotion, not built: an author allow-list (the issue author must be listed) and a per-day promotion cap read from the `set` journal.

## Development

```bash
python3 -B -m unittest discover -s plugins/backlog/tests
```

Offline: a fake `gh` shim records every invocation and no test touches the network or a real repo. `bash tests/templates/test-canonical-guards.sh` runs this suite as its `backlog-suite` invariant.
