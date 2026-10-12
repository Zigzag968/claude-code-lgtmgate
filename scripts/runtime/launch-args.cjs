#!/usr/bin/env node
'use strict'

// Prints the `args` object of the workflow launch (skills/deliver/SKILL.md, section 4) as one minified JSON
// line: the Lead passes it as `args`, and the guard `launch-bytes` measures it (docs/bench/launch-speed.md).
// Mode full carries the config and the specifics in full; mode ref (#520) carries `configRef` and `projectSpecificsRef`,
// which the PreToolUse hook hooks/workflow-args-expand.sh expands before the engine reads them.
// Nothing here reads git for the config (the working-tree file is the one the Lead reads) and no model runs.
//
// Usage: node scripts/runtime/launch-args.cjs --root <worktree> --ref origin/<base> --stage plan|dev|review
//          [--mode full|ref] [--issue N] [--brief text] [--pr N] [--plan-file f] [--worktree <path>]
// Stdout: JSON.stringify(args) + newline. Key order (full): issue, brief, worktreePath, mode, pmReview, config, configLocal,
//        projectSpecifics (only when the config sets projectSpecifics or agentContext), pluginRoot, sessionRoot;
//        (ref): issue, brief, worktreePath, mode, pmReview, configRef {path, digest64}, configLocal, projectSpecificsRef
//        {refSha, fp12} (same condition), pluginRoot, sessionRoot; stage dev|review adds entryStage, review adds prNumber,
//        --plan-file adds planText (never behind a reference). --worktree sets worktreePath (default: --root).
// Exit:  0 ok · 2 any argument or read error (one line on stderr, stdout empty).

const fs = require('fs')
const nodePath = require('path')
const crypto = require('crypto')
const { assemble } = require('./agent-context.cjs')
const { fingerprint12 } = require('../lib/agent-context-text.cjs')

const DEFAULT_BRIEF = 'implement the issue'
const STAGES = ['plan', 'dev', 'review']

class UsageError extends Error {}

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
  const localFile = nodePath.join(root, '.claude', 'pipeline.config.local.json')
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
  arguments_.sessionRoot = options.sessionRoot === undefined ? root : options.sessionRoot
  if (stage !== 'plan') arguments_.entryStage = stage
  if (stage === 'review') arguments_.prNumber = options.pr === undefined ? 1 : options.pr
  if (options.planFile !== undefined) arguments_.planText = fs.readFileSync(options.planFile, 'utf8')
  return arguments_
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
    else if (a === '--worktree') o.worktreePath = value()
    else throw new UsageError(`unknown argument: ${a}`)
  }
  return o
}

function main(argv) {
  try {
    const arguments_ = build(parseArguments(argv))
    process.stdout.write(JSON.stringify(arguments_) + '\n')
    return 0
  } catch (error) {
    const first = String(error && error.errors ? error.errors[0] : error && error.message ? error.message : error).split('\n')[0]
    process.stderr.write(`launch-args: ${first}\n`)
    return 2
  }
}

module.exports = { build, main, DEFAULT_BRIEF }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
