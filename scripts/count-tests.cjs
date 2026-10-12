#!/usr/bin/env node
'use strict'
// count-tests.cjs — prints the offline test counts of the suites' own summary lines (#159).
//   node scripts/count-tests.cjs                      one line per suite, then `[count-tests] total=<n> suites=<k>`
//   node scripts/count-tests.cjs --endpoint <file>    also writes the Shields endpoint JSON of the Tests badge
// The README states these numbers; the `readme-contract` guard of scripts/guards.cjs fails when they differ.
const fs = require('fs')
const path = require('path')
const { countAll, endpointJson, SUITES } = require('./lib/count-tests.cjs')

const arguments_ = process.argv.slice(2)
const flag = arguments_.indexOf('--endpoint')
const endpointFile = flag === -1 ? null : arguments_[flag + 1]
if (flag !== -1 && !endpointFile) {
  console.log('FAIL: count-tests: --endpoint needs a file path')
  process.exit(1)
}

try {
  const { counts, total } = countAll(path.resolve(__dirname, '..'))
  for (const suite of SUITES) console.log(`[count-tests] ${suite.label} ${counts[suite.label]}`)
  console.log(`[count-tests] total=${total} suites=${SUITES.length}`)
  if (endpointFile) {
    fs.mkdirSync(path.dirname(path.resolve(endpointFile)), { recursive: true })
    fs.writeFileSync(endpointFile, JSON.stringify(endpointJson(total)))
  }
} catch (error) {
  console.log(`FAIL: count-tests: ${error.message}`)
  process.exit(1)
}
