'use strict'
// doctor-checks.cjs — the table behind scripts/doctor.cjs (#521). Data only: no logic, no filesystem, no environment.
// `script` is the repo-relative path of the existing script a check calls, or `new` for the one check written for the
// doctor (free disk space). `findings` are the names a consumer can meet, each with a row in docs/consumer-reference.md
// (section "Doctor findings", enforced by the `consumer-reference` guard).

const CHECKS = [
  { id: 'installs', label: 'plugin installs, channels and loaded cache', script: 'scripts/plugin-versions.sh', findings: ['channel-conflict', 'marketplace-conflict', 'version-mismatch', 'loaded-cache', 'installs-elsewhere'] },
  { id: 'config', label: 'pipeline config keys', script: 'scripts/config-check.cjs', findings: ['config-warn'] },
  { id: 'template-drift', label: 'copies made by init', script: 'scripts/template-drift.cjs', findings: ['template-drift-warn'] },
  { id: 'ca-bundle', label: 'sandbox certificate bundle', script: 'scripts/ca-bundle-check.sh', findings: ['ca-bundle-stale'] },
  { id: 'disk', label: 'free disk space under the worktree root', script: 'new', findings: ['low-disk-space'] },
  { id: 'agents-context', label: 'project specifics given to the agents', script: 'scripts/runtime/agent-context.cjs', findings: ['agents-context-refused', 'agents-context-oversize'] },
]

// Raised by the doctor itself when any check above could not run.
const CROSS_CHECK_FINDINGS = ['check-not-run']

const FINDING_NAMES = [...CHECKS.flatMap((check) => check.findings), ...CROSS_CHECK_FINDINGS]

module.exports = { CHECKS, CROSS_CHECK_FINDINGS, FINDING_NAMES }
