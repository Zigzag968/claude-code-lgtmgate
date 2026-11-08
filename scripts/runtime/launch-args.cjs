#!/usr/bin/env node
'use strict'

// Prints the `args` object of the workflow launch (skills/deliver/SKILL.md, section 4) as one minified JSON
// line: the Lead passes it as `args`, and the guard `launch-bytes` measures it (docs/bench/launch-speed.md).
// Mode full carries the config and the specifics in full; mode ref (#520) carries `configRef` and `projectSpecificsRef`,
// which the PreToolUse hook hooks/workflow-args-expand.sh expands before the engine reads them.
// Nothing here reads git for the config (the working-tree file is the one the Lead reads) and no model runs.
// Mode file (#605) prints no args: it writes the launch file of the run (scripts/lib/launch-file.cjs) and prints its absolute
// path, the one `scriptPath` the Lead launches the engine from. The title of the label is the issue title read by REST (the same
// helper as the hook, scripts/lib/issue-title.cjs), else the first line of --brief, else `#<N>`; there is no title flag.
//
// Usage: node scripts/runtime/launch-args.cjs --root <worktree> --ref origin/<base> --stage plan|dev|review
//          [--mode full|ref] [--issue N] [--brief text] [--pr N] [--plan-file f | --plan-ref '<json>'] [--worktree <path>]
//          [--session-root <abs>] (required in mode ref)
//        node scripts/runtime/launch-args.cjs --mode file --issue N --root <worktree> --session-root <abs> [--brief text]
//          [--engine <abs path of the engine source>]   (default: <plugin root>/workflows/deliver-pipeline.js)
// Stdout: JSON.stringify(args) + newline. Key order (full): issue, brief, worktreePath, mode, pmReview, config, configLocal,
//        projectSpecifics (only when the config sets projectSpecifics or agentContext), pluginRoot, sessionRoot;
//        (ref): issue, brief, worktreePath, mode, pmReview, configRef {path, digest64}, configLocal, projectSpecificsRef
//        {refSha, fp12} (same condition), pluginRoot, sessionRoot; stage dev|review adds entryStage, review adds prNumber,
//        --plan-file adds planText (the full form); --plan-ref (#533, mode ref, stage dev|review only) adds planRef, the one
//        a plan-ready, dev-done or needs-revision result returned, copied as is (the hook expands it to planText; the digest
//        was pinned by the engine, never computed here). Both together, or --plan-ref in mode full, is a usage error.
//        --worktree sets worktreePath (default: --root).
//        sessionRoot is the --session-root value (the directory the Lead's session was opened in); it defaults to --root in mode full only.
//        Mode file: stdout is the absolute path of the launch file and one newline, nothing else.
// Exit:  0 ok · 2 any argument or read error (one line on stderr, stdout empty); in mode file also an engine source that lacks
//        the launch-copy shape, a launch directory that git does not ignore, and a git that cannot answer `check-ignore`.

const fs = require('fs')
const nodePath = require('path')
const crypto = require('crypto')
const { assemble, localConfigFile } = require('./agent-context.cjs')
const { fingerprint12 } = require('../lib/agent-context-text.cjs')
const launch = require('../lib/launch-file.cjs')
const { readIssueTitle, repositoryOf } = require('../lib/issue-title.cjs')

const DEFAULT_BRIEF = 'implement the issue'
const STAGES = ['plan', 'dev', 'review']

class UsageError extends Error {}

// The shape of a planRef (the engine and the hook check the same; the digest is the engine's, never computed here).
function checkPlanReference(reference) {
  const bad = (what) => { throw new UsageError(`--plan-ref: ${what}`) }
  if (reference === null || typeof reference !== 'object' || Array.isArray(reference)) bad('not a JSON object')
  if (!Number.isInteger(reference.issue) || reference.issue < 1) bad('issue must be a positive integer')
  if (typeof reference.digest !== 'string' || !/^[0-9a-f]{64}$/.test(reference.digest)) bad('digest must be 64 lowercase hex characters')
  if (reference.targets !== undefined && (!Array.isArray(reference.targets) || reference.targets.length > 25 || reference.targets.some((t) => typeof t !== 'string'))) bad('targets must be at most 25 paths')
  if (reference.designStep !== undefined && reference.designStep !== true) bad('designStep must be true when present')
  if (reference.lanes !== undefined && (!Array.isArray(reference.lanes) || reference.lanes.some((n) => typeof n !== 'string'))) bad('lanes must be a list of names')
  return reference
}

function readJson(file, optional) {
  let text
  try {
    text = fs.readFileSync(file, 'utf8')
  } catch (error) {
    if (optional) return {}
    throw new UsageError(`${file}: cannot be read`)
  }
  try {
    return JSON.parse(text)
  } catch (error) {
    throw new UsageError(`${file}: not valid JSON`)
  }
}

function build(options) {
  const root = options.root
  const stage = options.stage || 'plan'
  if (!STAGES.includes(stage)) throw new UsageError(`unknown stage: ${stage}`)
  const mode = options.mode || 'full'
  if (!['full', 'ref'].includes(mode)) throw new UsageError(`unknown mode: ${mode}`)
  const configFile = nodePath.join(root, '.claude', 'pipeline.config.json')
  const config = readJson(configFile, false)
  const localFile = localConfigFile(root)
  const configLocal = readJson(localFile, true)
  const arguments_ = {
    issue: options.issue === undefined ? 1 : options.issue,
    brief: options.brief === undefined ? DEFAULT_BRIEF : options.brief,
    worktreePath: options.worktreePath === undefined ? root : options.worktreePath,
    mode: 'auto',
    pmReview: false,
  }
  if (mode === 'ref') {
    arguments_.configRef = { path: '.claude/pipeline.config.json', digest64: crypto.createHash('sha256').update(fs.readFileSync(configFile)).digest('hex') }
  } else arguments_.config = config
  arguments_.configLocal = configLocal
  if (config.projectSpecifics || config.agentContext) {
    const { files, ...wire } = assemble({ root, ref: options.ref || 'origin/main', local: localFile })
    if (mode === 'ref') arguments_.projectSpecificsRef = { refSha: wire.refSha, fp12: fingerprint12(wire) }
    else arguments_.projectSpecifics = wire
  }
  arguments_.pluginRoot = options.pluginRoot === undefined ? nodePath.resolve(__dirname, '..', '..') : options.pluginRoot
  if (mode === 'ref') {
    if (options.sessionRoot === undefined) throw new UsageError('--session-root is required with --mode ref: the directory this session was opened in (see docs/consumer-reference.md, entry --session-root)')
    if (!nodePath.isAbsolute(options.sessionRoot)) throw new UsageError('--session-root must be an absolute path (see docs/consumer-reference.md, entry --session-root)')
  }
  arguments_.sessionRoot = options.sessionRoot === undefined ? root : options.sessionRoot
  if (stage !== 'plan') arguments_.entryStage = stage
  if (stage === 'review') arguments_.prNumber = options.pr === undefined ? 1 : options.pr
  if (options.planRef !== undefined) {
    if (mode !== 'ref') throw new UsageError('--plan-ref needs --mode ref (mode full carries --plan-file)')
    if (options.planFile !== undefined) throw new UsageError('--plan-file and --plan-ref are exclusive')
    if (stage === 'plan') throw new UsageError('--plan-ref needs --stage dev or review')
    arguments_.planRef = checkPlanReference(options.planRef)
  }
  if (options.planFile !== undefined) arguments_.planText = fs.readFileSync(options.planFile, 'utf8')
  return arguments_
}

// Mode file (#605): writes the launch file of the run and returns its absolute path.
function buildFile(options) {
  const issue = options.issue
  if (!Number.isSafeInteger(issue) || issue < 1) throw new UsageError('--issue is required with --mode file and must be a positive integer')
  if (options.sessionRoot === undefined) throw new UsageError('--session-root is required with --mode file: the directory this session was opened in (see docs/consumer-reference.md, entry --session-root)')
  if (!nodePath.isAbsolute(options.sessionRoot)) throw new UsageError('--session-root must be an absolute path (see docs/consumer-reference.md, entry --session-root)')
  const pluginRoot = options.pluginRoot === undefined ? nodePath.resolve(__dirname, '..', '..') : options.pluginRoot
  const enginePath = options.engine === undefined ? nodePath.join(pluginRoot, 'workflows', 'deliver-pipeline.js') : options.engine
  if (!nodePath.isAbsolute(enginePath)) throw new UsageError('--engine must be an absolute path')
  let source
  try { source = fs.readFileSync(enginePath, 'utf8') } catch (error) { throw new UsageError(`${enginePath}: cannot be read`) }
  const config = readJson(nodePath.join(options.root, '.claude', 'pipeline.config.json'), true)
  const repository = repositoryOf({ config, worktreePath: options.root })
  const title = repository === null ? null : readIssueTitle(repository, issue)
  const bytes = launch.retitle(source, issue, title === null ? { brief: options.brief } : { title })
  if (bytes === null) throw new UsageError(`${enginePath}: not an engine copy the launch file can be made from (see docs/consumer-reference.md, entry --mode file)`)
  const target = launch.launchPath(options.sessionRoot, bytes)
  const state = launch.ignoredState(options.sessionRoot, nodePath.relative(options.sessionRoot, target))
  if (state === 'not-ignored') throw new UsageError('.pipeline/ is not ignored by git in the session root, and the launch file is written there: add the line `.pipeline/` to .gitignore, then run this again (see docs/consumer-reference.md, entry --mode file)')
  if (state === 'git-failed') throw new UsageError('git check-ignore failed in the session root, so it cannot be told whether .pipeline/ is ignored: run this from a git repository with git installed (see docs/consumer-reference.md, entry --mode file)')
  const written = launch.ensureLaunchFile(options.sessionRoot, bytes)
  if (written.denied) throw new UsageError(`the launch file ${written.denied} was modified after it was written; delete it (scripts/runtime/clean-launch-files.cjs) and run this again`)
  return written.path
}

function parseArguments(argv) {
  const o = { root: process.cwd(), ref: 'origin/main', stage: 'plan', mode: 'full' }
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index]
    const value = () => {
      if (index + 1 >= argv.length) throw new UsageError(`${a} needs a value`)
      return argv[++index]
    }
    const number = () => {
      const v = value()
      if (!/^[0-9]+$/.test(v)) throw new UsageError(`${a} needs a number`)
      return Number(v)
    }
    if (a === '--root') o.root = value()
    else if (a === '--ref') o.ref = value()
    else if (a === '--stage') o.stage = value()
    else if (a === '--mode') o.mode = value()
    else if (a === '--issue') o.issue = number()
    else if (a === '--pr') o.pr = number()
    else if (a === '--brief') o.brief = value()
    else if (a === '--plan-file') o.planFile = value()
    else if (a === '--plan-ref') {
      try { o.planRef = JSON.parse(value()) } catch (error) { throw new UsageError('--plan-ref: not valid JSON') }
    }
    else if (a === '--worktree') o.worktreePath = value()
    else if (a === '--session-root') o.sessionRoot = value()
    else if (a === '--engine') o.engine = value()
    else throw new UsageError(`unknown argument: ${a}`)
  }
  return o
}

function main(argv) {
  try {
    const options = parseArguments(argv)
    if (options.mode === 'file') {
      process.stdout.write(`${buildFile(options)}\n`)
      return 0
    }
    process.stdout.write(JSON.stringify(build(options)) + '\n')
    return 0
  } catch (error) {
    const first = String(error && error.errors ? error.errors[0] : error && error.message ? error.message : error).split('\n')[0]
    process.stderr.write(`launch-args: ${first}\n`)
    return 2
  }
}

module.exports = { build, buildFile, main, DEFAULT_BRIEF }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
