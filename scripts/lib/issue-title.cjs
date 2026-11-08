'use strict'

// The one derivation of an issue title (#599, #605): read by REST from GitHub, cut to 80 bytes at a word boundary. Shared by
// scripts/runtime/merged-dependencies.cjs (the hook's run state) and scripts/runtime/launch-args.cjs --mode file (the launch
// file label), so the two never disagree. REST only, no GraphQL, no model; every failure is a null (fail open).

const fs = require('fs')
const nodePath = require('path')
const { execFileSync } = require('child_process')

const { cutTitle } = require('./launch-file.cjs')

const TITLE_BYTES = 80
const TIMEOUT_MS = 6000

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

// -> the title of a REST issue object cut to 80 bytes, or null when it has none.
function titleOfIssue(issueJson) {
  if (!issueJson || typeof issueJson.title !== 'string') return null
  const title = cutTitle(issueJson.title, TITLE_BYTES)
  return title === '' ? null : title
}

// -> the cut title of an issue read from GitHub, or null on any failure.
function readIssueTitle(repository, issue) {
  return titleOfIssue(rest(`repos/${repository}/issues/${issue}`))
}

function gitOut(directory, arguments_) {
  return execFileSync('git', ['-C', directory, ...arguments_], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
}

// -> 'owner/repo' from `config.repo`, else from the github.com origin remote of the worktree, else null.
function repositoryOf({ config, worktreePath }) {
  const configured = config && typeof config === 'object' ? config.repo : undefined
  if (typeof configured === 'string' && /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(configured)) return configured
  if (typeof worktreePath !== 'string' || !nodePath.isAbsolute(worktreePath) || !fs.existsSync(worktreePath)) return null
  try {
    const remote = gitOut(worktreePath, ['remote', 'get-url', 'origin'])
    const found = /github\.com[:/]([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?$/.exec(remote)
    return found ? `${found[1]}/${found[2]}` : null
  } catch (error) {
    return null
  }
}

module.exports = { TITLE_BYTES, rest, titleOfIssue, readIssueTitle, repositoryOf }
