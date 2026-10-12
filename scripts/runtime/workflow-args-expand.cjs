#!/usr/bin/env node
'use strict'

// PreToolUse(Workflow) expansion (#520, epic #528): the Lead passes `projectSpecificsRef {refSha, fp12}` and
// `configRef {path, digest64}` instead of retyping the whole objects; this script verifies them, expands them to the
// full objects through `hookSpecificOutput.updatedInput`, and (for a launch of this engine) swaps the engine for a copy
// whose progress titles carry the issue number (scripts/lib/launch-file.cjs, under .pipeline/launch/).
// Deterministic: git and the assembler run here, no model, nothing is asked. Scope of integrity: copy fidelity (the
// objects the engine reads are the ones the references name), not adversarial integrity.
//
// Stdin: the hook JSON ({cwd, tool_name, tool_input}). Stdout: nothing for a call that is not this engine's, else
// {hookSpecificOutput:{hookEventName, updatedInput, additionalContext?}}, never a permission decision except `deny`.
// A call is ours when it targets this engine (name `lgtmgate:deliver-pipeline`, or a scriptPath named deliver-pipeline.js
// or issue-<N>-<12 hex>.js) AND args carries projectSpecificsRef, configRef or planRef. planRef is left untouched (#533).
// Exit: 0 ok or not ours · 2 deny (reason on stderr and in the JSON; the reason names no role and no specifics text).

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const ENGINE_NAME = 'lgtmgate:deliver-pipeline'
const GENERATED_RE = /^issue-([0-9]+)-([0-9a-f]{12})\.js$/
const REFERENCE_WORDS = /projectSpecificsRef|configRef|planRef/
const ADVISORY_BRIEF_BYTES = 700
const ASSEMBLER_TIMEOUT_MS = 8000

class Deny extends Error {}

function gitOut(directory, arguments_) {
  const { execFileSync } = require('child_process')
  return execFileSync('git', ['-C', directory, ...arguments_], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
}

function isInside(root, candidate) {
  const relative = nodePath.relative(root, candidate)
  return relative !== '' && !relative.startsWith('..') && !nodePath.isAbsolute(relative)
}

function targetsEngine(toolInput) {
  if (toolInput.name === ENGINE_NAME) return true
  if (typeof toolInput.scriptPath !== 'string') return false
  const base = nodePath.basename(toolInput.scriptPath)
  return base === 'deliver-pipeline.js' || GENERATED_RE.test(base)
}

// -> {args, isString} or null when the args are not an object (nothing to expand).
function readArguments(toolInput) {
  let args = toolInput.args
  const isString = typeof args === 'string'
  if (isString) {
    try { args = JSON.parse(args) } catch (error) { return REFERENCE_WORDS.test(toolInput.args) ? 'unparseable' : null }
  }
  return args && typeof args === 'object' && !Array.isArray(args) ? { args, isString } : null
}

function expandConfig(args, projectDirectory) {
  const ref = args.configRef
  if (!ref || typeof ref !== 'object' || typeof ref.path !== 'string' || !/^[0-9a-f]{64}$/.test(String(ref.digest64))) throw new Deny('the configuration reference is malformed')
  if (args.config !== undefined) throw new Deny('args carries both config and configRef')
  if (!/^[A-Za-z0-9._/-]+$/.test(ref.path) || ref.path.startsWith('/') || ref.path.split('/').includes('..') || !ref.path.endsWith('.json')) throw new Deny('the configuration reference path is not a relative .json path')
  let bytes
  try {
    const root = fs.realpathSync(projectDirectory)
    const file = fs.realpathSync(nodePath.resolve(root, ref.path))
    if (!isInside(root, file)) throw new Deny('the configuration reference path leaves the project')
    bytes = fs.readFileSync(file)
  } catch (error) {
    if (error instanceof Deny) throw error
    throw new Deny('the referenced configuration file cannot be read')
  }
  if (crypto.createHash('sha256').update(bytes).digest('hex') !== ref.digest64) throw new Deny('the configuration file changed since the reference was printed (digest mismatch)')
  let parsed
  try { parsed = JSON.parse(bytes.toString('utf8')) } catch (error) { throw new Deny('the referenced configuration is not valid JSON') }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Deny('the referenced configuration is not a JSON object')
  return parsed
}

function sameRepository(worktree, projectDirectory) {
  try {
    const common = (directory) => fs.realpathSync(nodePath.resolve(directory, gitOut(directory, ['rev-parse', '--git-common-dir'])))
    return common(worktree) === common(projectDirectory)
  } catch (error) {
    return false
  }
}

function expandSpecifics(args, projectDirectory, pluginRoot) {
  const ref = args.projectSpecificsRef
  if (!ref || typeof ref !== 'object' || !/^[0-9a-f]{40}$/.test(String(ref.refSha)) || !/^[0-9a-f]{12}$/.test(String(ref.fp12))) throw new Deny('the specifics reference is malformed')
  if (args.projectSpecifics !== undefined) throw new Deny('args carries both projectSpecifics and projectSpecificsRef')
  const worktree = args.worktreePath || args.wtPath
  if (typeof worktree !== 'string' || !nodePath.isAbsolute(worktree) || !fs.existsSync(worktree) || !fs.statSync(worktree).isDirectory()) throw new Deny('the worktree named by the launch is not an existing directory')
  if (!sameRepository(worktree, projectDirectory)) throw new Deny('the worktree is not a worktree of this repository')
  const { execFileSync } = require('child_process')
  let stdout
  try {
    stdout = execFileSync('node', [
      nodePath.join(pluginRoot, 'scripts', 'runtime', 'agent-context.cjs'), '--root', worktree, '--sha', ref.refSha,
      '--local', nodePath.join(projectDirectory, '.claude', 'pipeline.config.local.json'),
    ], { encoding: 'utf8', timeout: ASSEMBLER_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] })
  } catch (error) {
    throw new Deny('the specifics could not be assembled at the referenced commit (stale commit, refused file or timeout)')
  }
  let payload
  try { payload = JSON.parse(stdout) } catch (error) { throw new Deny('the specifics assembler printed no JSON') }
  const { fingerprint12 } = require('../lib/agent-context-text.cjs')
  if (fingerprint12(payload) !== ref.fp12) throw new Deny('the specifics fingerprint differs from the reference')
  return payload
}

// The args with the references replaced in place (key order kept); planRef stays.
function expandedArguments(args, projectDirectory, pluginRoot) {
  const out = {}
  const hasConfig = args.configRef !== undefined
  const hasSpecifics = args.projectSpecificsRef !== undefined
  const config = hasConfig ? expandConfig(args, projectDirectory) : undefined
  const specifics = hasSpecifics ? expandSpecifics(args, projectDirectory, pluginRoot) : undefined
  for (const key of Object.keys(args)) {
    if (key === 'configRef') out.config = config
    else if (key === 'projectSpecificsRef') out.projectSpecifics = specifics
    else out[key] = args[key]
  }
  return out
}

function isIgnored(projectDirectory, relative) {
  const { execFileSync } = require('child_process')
  try {
    execFileSync('git', ['-C', projectDirectory, 'check-ignore', '-q', '--', relative], { stdio: 'ignore' })
    return true
  } catch (error) {
    return false
  }
}

// -> an absolute scriptPath to use instead of `name`/`scriptPath`, or null (the call keeps what it named). Throws Deny
// when a launch file of that name holds other bytes than expected.
function contextualScript(toolInput, args, projectDirectory, pluginRoot) {
  const launch = require('../lib/launch-file.cjs')
  const issue = Number(args.issue)
  if (toolInput.name === undefined && typeof toolInput.scriptPath !== 'string') return null
  if (!Number.isInteger(issue) || issue < 1) return null
  const given = typeof toolInput.scriptPath === 'string' ? toolInput.scriptPath : nodePath.join(pluginRoot, 'workflows', 'deliver-pipeline.js')
  let source
  try { source = fs.readFileSync(given, 'utf8') } catch (error) { return null }
  const made = GENERATED_RE.exec(nodePath.basename(given))
  if (made && crypto.createHash('sha256').update(source, 'utf8').digest('hex').slice(0, 12) !== made[2]) {
    throw new Deny(`the launch file ${nodePath.basename(given)} was modified after it was written; delete it (scripts/runtime/clean-launch-files.cjs) and launch again`)
  }
  const expected = launch.retitle(source, issue)
  if (expected === null) return null
  const file = launch.launchPath(projectDirectory, issue, expected)
  if (!isIgnored(projectDirectory, nodePath.relative(projectDirectory, file))) return null
  const result = launch.ensureLaunchFile(projectDirectory, issue, expected)
  if (result.denied) throw new Deny(`the launch file ${result.denied} was modified after it was written; delete it (scripts/runtime/clean-launch-files.cjs) and launch again`)
  return result.path
}

function advisory(args) {
  const bytes = typeof args.brief === 'string' ? Buffer.byteLength(args.brief, 'utf8') : 0
  if (bytes <= ADVISORY_BRIEF_BYTES) return null
  return `Advisory: the brief is ${bytes} bytes, over ${ADVISORY_BRIEF_BYTES}; every launch and resume re-sends it. Keep it to the issue number and one line: the engine reads the issue itself.`
}

// -> null (not ours) | {updatedInput, additionalContext?}; throws Deny.
function decide(input, env) {
  if (!input || typeof input !== 'object') return null
  if (input.tool_name !== undefined && input.tool_name !== 'Workflow') return null
  const toolInput = input.tool_input
  if (!toolInput || typeof toolInput !== 'object') return null
  const read = readArguments(toolInput)
  if (read === 'unparseable') throw new Deny('args is a string that is not valid JSON')
  if (read === null) return null
  const { args, isString } = read
  const referenced = args.projectSpecificsRef !== undefined || args.configRef !== undefined || args.planRef !== undefined
  if (!targetsEngine(toolInput) || !referenced) return null
  const projectDirectory = env.CLAUDE_PROJECT_DIR || input.cwd
  if (typeof projectDirectory !== 'string' || projectDirectory === '') throw new Deny('the project directory is unknown')
  const pluginRoot = nodePath.resolve(__dirname, '..', '..')
  const expanded = expandedArguments(args, projectDirectory, pluginRoot)
  const updated = { ...toolInput, args: isString ? JSON.stringify(expanded) : expanded }
  const script = contextualScript(toolInput, expanded, projectDirectory, pluginRoot)
  if (script !== null) {
    delete updated.name
    updated.scriptPath = script
  }
  const note = advisory(expanded)
  return note === null ? { updatedInput: updated } : { updatedInput: updated, additionalContext: note }
}

function denyOutput(reason) {
  const text = `specifics-ref-mismatch: ${reason}. See docs/consumer-reference.md (specifics-ref-mismatch). To launch in full form: node ${nodePath.resolve(__dirname, 'launch-args.cjs')} --mode full ...`
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: text } }) + '\n')
  process.stderr.write(`${text}\n`)
  return 2
}

function main() {
  let raw = ''
  try { raw = fs.readFileSync(0, 'utf8') } catch (error) { return 0 }
  let input = null
  try { input = JSON.parse(raw) } catch (error) {
    return REFERENCE_WORDS.test(raw) ? denyOutput('the hook input is not valid JSON') : 0
  }
  try {
    const result = decide(input, process.env)
    if (result === null) return 0
    const output = { hookEventName: 'PreToolUse', updatedInput: result.updatedInput }
    if (result.additionalContext) output.additionalContext = result.additionalContext
    process.stdout.write(JSON.stringify({ hookSpecificOutput: output }) + '\n')
    return 0
  } catch (error) {
    if (error instanceof Deny) return denyOutput(error.message)
    const referenced = REFERENCE_WORDS.test(raw)
    return referenced ? denyOutput('the expansion failed unexpectedly') : 0
  }
}

module.exports = { decide, Deny }

if (require.main === module) process.exitCode = main()
