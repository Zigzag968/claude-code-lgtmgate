#!/usr/bin/env node
// forwarder to scripts/runtime/probe-run.cjs, removed after one release (#312)
const real = require('path').join(__dirname, '..', 'scripts', 'runtime', 'probe-run.cjs')
module.exports = require(real)
if (require.main === module) {
  const r = require('child_process').spawnSync(process.execPath, [real, ...process.argv.slice(2)], { stdio: 'inherit' })
  process.exit(r.status ?? 1)
}
