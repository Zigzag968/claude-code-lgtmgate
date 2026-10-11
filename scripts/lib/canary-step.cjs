'use strict'
// canary-step.cjs — the rule behind the `canary-step` guard (#432). Pure function, stdlib only: MAINTAINING.md keeps
// the step "Canary re-initialised from scratch" and, below its heading, names the three scripts of the first proof.
// Only the heading phrase and the script names are pinned, never the rest of the wording. Nothing here reads git.

const PATH = 'MAINTAINING.md'
const HEADING = 'Canary re-initialised from scratch'
const SCRIPTS = ['template-drift.cjs', 'config-check.cjs', 'agent-context.cjs']

// problems(text) -> one message per failure; text is null when the file is missing.
function problems(text) {
  if (text === null) return [`FAIL: canary-step: ${PATH} is missing`]
  const lines = text.split('\n')
  const at = lines.findIndex((line) => /^#{2,4} /.test(line) && line.includes(HEADING))
  if (at === -1) return [`FAIL: canary-step: ${PATH} has no heading '${HEADING}'`]
  const below = lines.slice(at).join('\n')
  return SCRIPTS.filter((name) => !below.includes(name)).map((name) => `FAIL: canary-step: ${PATH} step does not name ${name}`)
}

module.exports = { PATH, HEADING, SCRIPTS, problems }
