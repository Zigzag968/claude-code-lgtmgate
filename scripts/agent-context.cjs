#!/usr/bin/env node
// forwarder to scripts/runtime/agent-context.cjs, removed after one release (#312)
const real = require('path').join(__dirname, 'runtime', 'agent-context.cjs')
module.exports = require(real)
if (require.main === module) {
  const r = require('child_process').spawnSync(process.execPath, [real, ...process.argv.slice(2)], { stdio: 'inherit' })
  process.exit(r.status ?? 1)
}
