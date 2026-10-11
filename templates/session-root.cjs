#!/usr/bin/env node
// #490: the session-root probe command, as a short script run by path. argv[2] = the Lead's session root; the
// run's worktree is the current directory (the probe line starts with `cd '<worktree>'`). Prints exactly one
// line: SESSION-ROOT:same | SESSION-ROOT:differs | SESSION-ROOT-ERROR:unreadable. Never prints a path.
'use strict'
const cp = require('child_process')
const fs = require('fs')
try {
  const d = (p) => fs.realpathSync(cp.execFileSync('git', ['-C', p, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim())
  console.log(d(process.argv[2]) === d(process.cwd()) ? 'SESSION-ROOT:same' : 'SESSION-ROOT:differs')
} catch (error) {
  console.log('SESSION-ROOT-ERROR:unreadable')
}
