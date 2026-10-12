#!/usr/bin/env node
'use strict'

// Prints the `args` object of the workflow launch (skills/deliver/SKILL.md, section 4) as one minified JSON
// line, so the maintainers can measure the bytes of a launch (guard `launch-bytes`, docs/bench/launch-speed.md).
// The Lead still builds the real launch by hand; this script is the deterministic measure of what it pastes.
// Nothing here reads git for the config (the working-tree file is the one the Lead reads) and no model runs.
//
// Usage: node scripts/runtime/launch-args.cjs --root <worktree> --ref origin/<base> --stage plan|dev|review
//          [--mode full|ref] [--issue N] [--brief text] [--pr N] [--plan-file f]
// Stdout: JSON.stringify(args) + newline. Key order: issue, brief, worktreePath, mode, pmReview, config, configLocal,
//        projectSpecifics (only when the config sets projectSpecifics or agentContext), pluginRoot, sessionRoot;
//        stage dev|review adds entryStage, review adds prNumber, --plan-file adds planText.
// Exit:  0 ok · 2 any argument or read error (one line on stderr, stdout empty). `--mode ref` is refused until #520.

const fs = require('fs')
const nodePath = require('path')
const { assemble } = require('./agent-context.cjs')

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
  if ((options.mode || 'full') !== 'full') throw new UsageError('mode ref is not available until #520')
  const config = readJson(nodePath.join(root, '.claude', 'pipeline.config.json'), false)
  const localFile = nodePath.join(root, '.claude', 'pipeline.config.local.json')
  const configLocal = readJson(localFile, true)
  const args = {
    issue: options.issue === undefined ? 1 : options.issue,
    brief: options.brief === undefined ? DEFAULT_BRIEF : options.brief,
    worktreePath: options.worktreePath === undefined ? root : options.worktreePath,
    mode: 'auto',
    pmReview: false,
    config,
    configLocal,
  }
  if (config.projectSpecifics || config.agentContext) {
    const { files, ...wire } = assemble({ root, ref: options.ref || 'origin/main', local: localFile })
    args.projectSpecifics = wire
  }
  args.pluginRoot = options.pluginRoot === undefined ? nodePath.resolve(__dirname, '..', '..') : options.pluginRoot
  args.sessionRoot = options.sessionRoot === undefined ? root : options.sessionRoot
  if (stage !== 'plan') args.entryStage = stage
  if (stage === 'review') args.prNumber = options.pr === undefined ? 1 : options.pr
  if (options.planFile !== undefined) args.planText = fs.readFileSync(options.planFile, 'utf8')
  return args
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
    else throw new UsageError(`unknown argument: ${a}`)
  }
  return o
}

function main(argv) {
  try {
    const args = build(parseArguments(argv))
    process.stdout.write(JSON.stringify(args) + '\n')
    return 0
  } catch (error) {
    const first = String(error && error.errors ? error.errors[0] : error && error.message ? error.message : error).split('\n')[0]
    process.stderr.write(`launch-args: ${first}\n`)
    return 2
  }
}

module.exports = { build, main, DEFAULT_BRIEF }

if (require.main === module) process.exitCode = main(process.argv.slice(2))
