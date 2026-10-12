#!/usr/bin/env node
'use strict'

// Removes the launch files the expansion hook wrote (#520): `issue-<N>-<12 hex>.js` under <root>/.pipeline/launch/, all of
// them or those of one issue, then the directory when it is empty. Nothing else of .pipeline/ is touched and a symlinked
// directory is never followed. The Lead runs it after a merge (skills/deliver/SKILL.md, section 6).
//
// Usage: node scripts/runtime/clean-launch-files.cjs [--root <project>] [--issue <N>]
// Stdout: `removed <n>`. Exit: 0 ok · 2 usage error (one line on stderr).

const fs = require('fs')
const nodePath = require('path')

const FILE_RE = /^issue-([0-9]+)-[0-9a-f]{12}\.js$/

function clean(root, issue) {
  const directory = nodePath.join(root, '.pipeline', 'launch')
  let status
  try { status = fs.lstatSync(directory) } catch (error) { return 0 }
  if (!status.isDirectory()) return 0 // absent, a file, or a symlink: nothing to follow
  let removed = 0
  for (const name of fs.readdirSync(directory)) {
    const m = FILE_RE.exec(name)
    if (!m || (issue !== null && Number(m[1]) !== issue)) continue
    const file = nodePath.join(directory, name)
    if (!fs.lstatSync(file).isFile()) continue
    fs.unlinkSync(file)
    removed += 1
  }
  if (fs.readdirSync(directory).length === 0) fs.rmdirSync(directory)
  return removed
}

function parse(argv) {
  const o = { root: process.cwd(), issue: null }
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    const value = () => {
      if (index + 1 >= argv.length) throw new Error(`${a} needs a value`)
      return argv[++index]
    }
    if (a === '--root') o.root = value()
    else if (a === '--issue') {
      const v = value()
      if (!/^[0-9]+$/.test(v)) throw new Error('--issue needs a number')
      o.issue = Number(v)
    } else throw new Error(`unknown argument: ${a}`)
  }
  return o
}

function main(argv) {
  try {
    const o = parse(argv)
    process.stdout.write(`removed ${clean(o.root, o.issue)}\n`)
    return 0
  } catch (error) {
    process.stderr.write(`clean-launch-files: ${String(error && error.message).split('\n')[0]}\n`)
    return 2
  }
}

module.exports = { clean, main }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
