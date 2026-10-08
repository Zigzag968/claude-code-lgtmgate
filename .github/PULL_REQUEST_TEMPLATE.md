Closes #

## What this ships

<!-- Bullet summary of the diff. Link the issue it addresses. -->

## Acceptance checklist

<!-- Copied verbatim from Sam's plan; the merge script refuses any unchecked box between the markers. -->
<!-- acceptance:start -->
- [ ] <verifiable criterion>
<!-- acceptance:end -->

<!-- decision-log:start -->
<!-- decision-log:end -->

<details><summary>Technical detail</summary>

- Test plan: `bash tests/templates/test-canonical-guards.sh`, `node scripts/run-flow-suite.cjs`
- Docs updated if behavior or config changed (`README.md`, `MAINTAINING.md`, or the relevant `agents/*.md`)
- No new third-party dependency (this repo is stdlib-only)

</details>
