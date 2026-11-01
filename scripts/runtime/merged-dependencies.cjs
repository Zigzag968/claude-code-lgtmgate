#!/usr/bin/env node
'use strict'

// Merged dependencies and epic of an issue (#545): what the Lead used to type in `brief` ("#530 is merged, epic #528") is
// computed here from GitHub, by REST only. Run by scripts/runtime/workflow-args-expand.cjs on every launch that carries run
// state; the engine renders the result as `merged:` / `epic:` lines (workflows/deliver-pipeline.js, RUN_STATE_LINES).
//
// Usage: node merged-dependencies.cjs --issue <N> --repo <owner/repo>
// Reads the body of issue N, takes the line that starts with `depends-on:` and its `#<n>` tokens (at most 20; `none` or no
// line -> none), keeps each dependency that is closed with state_reason `completed`, and asks `issues/<N>/parent` for the epic.
// Also the issue title (#599), cut to 80 bytes at a word boundary with an ellipsis, from the same read of the issue.
// Stdout: one JSON line, `{"merged":[530,531],"epic":528,"title":"..."}` with only the keys that have a value, nothing at all
// when all are empty. Exit 0 on every data or network problem (fail open: the launch goes on without the derived lines), 2 on a usage error.
// Calls `gh` by name from PATH (the tests stub it). Writes no file. No GraphQL, no model.

const { execFileSync } = require('child_process')

const { cutTitle } = require('../lib/launch-file.cjs')

const TITLE_BYTES = 80
const MAX_DEPENDENCIES = 20
const TIMEOUT_MS = 6000

function usage() {
  process.stderr.write('usage: merged-dependencies.cjs --issue <N> --repo <owner/repo>\n')
  return 2
}

function argumentOf(list, flag) {
  const index = list.indexOf(flag)
  return index >= 0 && index + 1 < list.length ? list[index + 1] : undefined
}

// -> the parsed JSON of a REST call, or null on any failure (missing gh, 404, timeout, bad JSON).
function rest(path) {
  try {
    const stdout = execFileSync('gh', ['api', path], { encoding: 'utf8', timeout: TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'] })
    const parsed = JSON.parse(stdout)
    return parsed && typeof parsed === 'object' ? parsed : null
  } catch (error) {
    return null
  }
}

// -> the issue numbers named on the `depends-on:` line of a body (first such line), at most MAX_DEPENDENCIES, deduplicated.
function dependenciesOf(body) {
  if (typeof body !== 'string') return []
  for (const line of body.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed.toLowerCase().startsWith('depends-on:')) continue
    const found = []
    for (const token of trimmed.slice('depends-on:'.length).split(/[\s,;]+/)) {
      if (!token.startsWith('#')) continue
      const digits = token.slice(1)
      if (digits === '' || digits.length > 9 || [...digits].some((c) => c < '0' || c > '9')) continue
      const number = Number(digits)
      if (number >= 1 && !found.includes(number)) found.push(number)
      if (found.length >= MAX_DEPENDENCIES) break
    }
    return found
  }
  return []
}

function main(list) {
  const issueText = argumentOf(list, '--issue')
  const repository = argumentOf(list, '--repo')
  const issue = Number(issueText)
  if (!Number.isInteger(issue) || issue < 1 || typeof repository !== 'string' || !/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repository)) return usage()
  const result = {}
  const own = rest(`repos/${repository}/issues/${issue}`)
  if (own && typeof own.title === 'string') {
    const title = cutTitle(own.title, TITLE_BYTES)
    if (title !== '') result.title = title
  }
  const merged = []
  for (const dependency of dependenciesOf(own ? own.body : null)) {
    const held = rest(`repos/${repository}/issues/${dependency}`)
    if (held && held.state === 'closed' && held.state_reason === 'completed') merged.push(dependency)
  }
  if (merged.length > 0) result.merged = merged
  const parent = rest(`repos/${repository}/issues/${issue}/parent`)
  if (parent && Number.isInteger(parent.number) && parent.number >= 1) result.epic = parent.number
  if (Object.keys(result).length > 0) process.stdout.write(`${JSON.stringify(result)}\n`)
  return 0
}

module.exports = { dependenciesOf }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
