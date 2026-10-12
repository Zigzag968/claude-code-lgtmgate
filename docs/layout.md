# Repository layout

The root folders are enforced by `.ls-lint.yml` and `node scripts/audit.cjs --check`: a folder not listed here is rejected.

| Folder | Audience | Role | Key files |
|---|---|---|---|
| `workflows/` | Claude Code `Workflow` tool | the pipeline engine, one file | `deliver-pipeline.js` |
| `agents/` | the pipeline (agent personas) | one persona per role | `sam.md`, `nick.md`, `morgan.md` |
| `skills/` | Claude Code users | the skills shipped with the plugin; each is a slash command /lgtmgate:<name> | `deliver/SKILL.md`, `init/SKILL.md`, `context/SKILL.md` |
| `hooks/` | Claude Code (plugin hooks) | hook scripts named after their event | `plugin-hooks.json`, `block-merge-unchecked.sh` |
| `templates/` | consumer repos and the engine | files `/lgtmgate:init` copies (the provisioning script, the cross-repo signal helper), templates the engine reads | `pr-acceptance.md`, `pipeline.config.template.json` |
| `tests/` | maintainers and CI | every test suite, in `hooks/`, `scripts/` or `templates/` after the folder it exercises (`templates/test-deliver-pipeline.js` stays: `scripts/run-flow-suite.cjs` loads it, init no longer copies it) | `scripts/test-guards.sh`, `templates/test-canonical-guards.sh` |
| `scripts/` | maintainers and CI | audit, guards, merge and CI helpers; `scripts/runtime/` holds the engine runtime scripts (probe-run.cjs, pr-state.sh, pr-write.sh, preflight.sh, pr-body-splice.cjs, gh-read-class.sh, agent-context.cjs, init-specifics.cjs) | `audit.cjs`, `guards.cjs`, `lead-merge.sh` |
| `plugins/` | marketplace users | the second plugin of this marketplace | `backlog/` |
| `docs/` | maintainers and readers | reference pages, no code | `supervision.md`, `critical-paths.md`, `layout.md` |
| `evals/` | maintainers | probe evals: prompts and graders | `probe-pr-state/` |
| `fixtures/` | tests | replayed captures and fixtures shared by the suites | `README.md` |
| `.claude/` | the Lead working on this repo | this repo's own config and rules | `CLAUDE.md`, `pipeline.config.json`, `rules/` |
| `.claude-plugin/` | Claude Code | plugin and marketplace manifests | `plugin.json`, `marketplace.json` |
| `.github/` | GitHub | workflows, issue and PR templates | `workflows/`, `PULL_REQUEST_TEMPLATE.md` |
| `.githooks/` | contributors | local git hooks | `pre-commit`, `pre-push` |
| `.devcontainer/` | contributors | development container and the pinned Claude Code CLI install | `devcontainer.json`, `package.json`, `package-lock.json` |

## Never

- `workflows/deliver-pipeline.js` imports no module.
- `agents/` and `skills/` hold no code file (`.ls-lint.yml` `exists:0`).
- `skills/` ships with the plugin; `.claude/skills/` is repo-only (this repo's own maintainer skills, never shipped).
- `fixtures/` and `plugins/*/tests/fixtures/` are the only fixture folders (`scripts/audit.cjs` `fixtures-location`).
- A new root folder is added to `.ls-lint.yml` and to this page in the same change.

## Checks

- Checks: `node scripts/guards.cjs` and `bash tests/templates/test-canonical-guards.sh`; a failure names its rule.
