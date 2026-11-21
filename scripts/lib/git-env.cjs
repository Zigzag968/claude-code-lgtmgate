'use strict'
// git-env.cjs — a copy of an environment without the repo-scoped git variables. git exports some of them
// (GIT_DIR, GIT_INDEX_FILE, ...) to its hooks; a child git that inherits them acts on the hook's repository
// instead of its own -C directory. stdlib only.

const { execFileSync } = require('child_process')

// Fallback: the output of `git rev-parse --local-env-vars`, used when git is absent or the query fails.
const STATIC_LOCAL = [
  'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CONFIG', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT', 'GIT_OBJECT_DIRECTORY',
  'GIT_DIR', 'GIT_WORK_TREE', 'GIT_IMPLICIT_WORK_TREE', 'GIT_GRAFT_FILE', 'GIT_INDEX_FILE', 'GIT_NO_REPLACE_OBJECTS',
  'GIT_REPLACE_REF_BASE', 'GIT_PREFIX', 'GIT_SHALLOW_FILE', 'GIT_COMMON_DIR',
]
const INDEXED = /^GIT_CONFIG_(KEY|VALUE)_\d+$/

function strip(environment, names) {
  const result = {}
  for (const key of Object.keys(environment)) {
    if (names.has(key) || INDEXED.test(key)) continue
    result[key] = environment[key]
  }
  return result
}

let cached = null

function localNames() {
  if (cached) return cached
  const names = new Set(STATIC_LOCAL)
  try {
    // The query runs with the static list removed, so a leaking GIT_DIR cannot redirect it.
    const result = execFileSync('git', ['rev-parse', '--local-env-vars'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], env: strip(process.env, new Set(STATIC_LOCAL)) })
    for (const name of result.split('\n')) if (/^GIT_[A-Z0-9_]+$/.test(name.trim())) names.add(name.trim())
  } catch (error) { /* keep the static list */ }
  cached = names
  return cached
}

// cleanGitEnvironment(environment = process.env) -> a copy of the environment without the repo-scoped git variables.
function cleanGitEnvironment(environment = process.env) {
  return strip(environment, localNames())
}

module.exports = { cleanGitEnvironment }
