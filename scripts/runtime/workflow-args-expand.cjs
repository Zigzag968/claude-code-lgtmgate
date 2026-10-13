#!/usr/bin/env node
'use strict'

// PreToolUse(Workflow) expansion (#520, epic #528): the Lead passes `projectSpecificsRef {refSha, fp12}` and
// `configRef {path, digest64}` instead of retyping the whole objects; this script verifies them, expands them to the
// full objects through `hookSpecificOutput.updatedInput`, and (for a launch of this engine) swaps the engine for a copy
// whose workflow name is the issue title and whose description carries the issue number (scripts/lib/launch-file.cjs, under .pipeline/launch/).
// Deterministic: git and the assembler run here, no model, nothing is asked. Scope of integrity: copy fidelity (the
// objects the engine reads are the ones the references name), not adversarial integrity.
//
// Stdin: the hook JSON ({cwd, tool_name, tool_input}). Stdout: nothing for a call that is not this engine's, else
// {hookSpecificOutput:{hookEventName, updatedInput, additionalContext?}}, never a permission decision except `deny`.
// A call is ours when it targets this engine (name `lgtmgate:deliver-pipeline`, or a scriptPath named deliver-pipeline.js
// or issue-<N>-<12 hex>.js) AND args carries projectSpecificsRef, configRef or planRef. planRef (#533) is kept and gets a
// `planText` right after it: the bytes of .pipeline/plans/issue-<N>-sam.md under the worktree, read only when their sha256
// equals planRef.digest (the digest the engine pinned when it returned the plan); every failure is `plan-ref-mismatch`.
// Run state (#545): a launch of the engine that carries `title`, `parallel` or `decided` is also ours. The hook deletes any typed
// `merged`/`epic`, then writes its own from scripts/runtime/merged-dependencies.cjs (the `depends-on:` issues closed as completed,
// and the epic parent; fail open: a failure writes no key). `title` goes to the launch file name and description; `parallel` is
// compared with the active runs as an advisory, never a refusal (two simultaneous launches cannot see each other's state file).
// Exit: 0 ok or not ours · 2 deny (reason on stderr and in the JSON; the reason names no role and no specifics text).

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const ENGINE_NAME = 'lgtmgate:deliver-pipeline'
const GENERATED_RE = /^issue-([0-9]+)-([0-9a-f]{12})\.js$/
const REFERENCE_WORDS = /projectSpecificsRef|configRef|planRef/
const ADVISORY_BRIEF_BYTES = 700
const ASSEMBLER_TIMEOUT_MS = 8000
const DERIVE_TIMEOUT_MS = 8000
const TITLE_MAX_BYTES = 80

class Deny extends Error {
  constructor(message, code) {
    super(message)
    this.code = code || 'specifics-ref-mismatch'
  }
}

class PlanDeny extends Deny {
  constructor(message) { super(message, 'plan-ref-mismatch') }
}

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
  let arguments_ = toolInput.args
  const isString = typeof arguments_ === 'string'
  if (isString) {
    try { arguments_ = JSON.parse(arguments_) } catch (error) { return REFERENCE_WORDS.test(toolInput.args) ? 'unparseable' : null }
  }
  return arguments_ && typeof arguments_ === 'object' && !Array.isArray(arguments_) ? { args: arguments_, isString } : null
}

function expandConfig(arguments_, projectDirectory) {
  const reference = arguments_.configRef
  if (!reference || typeof reference !== 'object' || typeof reference.path !== 'string' || !/^[0-9a-f]{64}$/.test(String(reference.digest64))) throw new Deny('the configuration reference is malformed')
  if (arguments_.config !== undefined) throw new Deny('args carries both config and configRef')
  if (!/^[A-Za-z0-9._/-]+$/.test(reference.path) || reference.path.startsWith('/') || reference.path.split('/').includes('..') || !reference.path.endsWith('.json')) throw new Deny('the configuration reference path is not a relative .json path')
  let bytes
  try {
    const root = fs.realpathSync(projectDirectory)
    const file = fs.realpathSync(nodePath.resolve(root, reference.path))
    if (!isInside(root, file)) throw new Deny('the configuration reference path leaves the project')
    bytes = fs.readFileSync(file)
  } catch (error) {
    if (error instanceof Deny) throw error
    throw new Deny('the referenced configuration file cannot be read')
  }
  if (crypto.createHash('sha256').update(bytes).digest('hex') !== reference.digest64) throw new Deny('the configuration file changed since the reference was printed (digest mismatch)')
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

function expandSpecifics(arguments_, projectDirectory, pluginRoot) {
  const reference = arguments_.projectSpecificsRef
  if (!reference || typeof reference !== 'object' || !/^[0-9a-f]{40}$/.test(String(reference.refSha)) || !/^[0-9a-f]{12}$/.test(String(reference.fp12))) throw new Deny('the specifics reference is malformed')
  if (arguments_.projectSpecifics !== undefined) throw new Deny('args carries both projectSpecifics and projectSpecificsRef')
  const worktree = arguments_.worktreePath || arguments_.wtPath
  if (typeof worktree !== 'string' || !nodePath.isAbsolute(worktree) || !fs.existsSync(worktree) || !fs.statSync(worktree).isDirectory()) throw new Deny('the worktree named by the launch is not an existing directory')
  if (!sameRepository(worktree, projectDirectory)) throw new Deny('the worktree is not a worktree of this repository')
  const { execFileSync } = require('child_process')
  let stdout
  try {
    stdout = execFileSync('node', [
      nodePath.join(pluginRoot, 'scripts', 'runtime', 'agent-context.cjs'), '--root', worktree, '--sha', reference.refSha,
    ], { encoding: 'utf8', timeout: ASSEMBLER_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] })
  } catch (error) {
    throw new Deny('the specifics could not be assembled at the referenced commit (stale commit, refused file or timeout)')
  }
  let payload
  try { payload = JSON.parse(stdout) } catch (error) { throw new Deny('the specifics assembler printed no JSON') }
  const { fingerprint12 } = require('../lib/agent-context-text.cjs')
  if (fingerprint12(payload) !== reference.fp12) throw new Deny('the specifics fingerprint differs from the reference')
  return payload
}

// -> the plan artifact text named by planRef (#533). The reference carries no path: the file is derived from the issue.
function expandPlan(arguments_, projectDirectory) {
  const reference = arguments_.planRef
  if (!reference || typeof reference !== 'object' || Array.isArray(reference) || !Number.isInteger(reference.issue) || reference.issue < 1 || !/^[0-9a-f]{64}$/.test(String(reference.digest))) throw new PlanDeny('the plan reference is malformed')
  if (arguments_.planText !== undefined) throw new PlanDeny('args carries both planText and planRef')
  if (reference.issue !== Number(arguments_.issue)) throw new PlanDeny('the plan reference names another issue than the launch')
  const worktree = arguments_.worktreePath || arguments_.wtPath
  if (typeof worktree !== 'string' || !nodePath.isAbsolute(worktree) || !fs.existsSync(worktree) || !fs.statSync(worktree).isDirectory()) throw new PlanDeny('the worktree named by the launch is not an existing directory')
  if (!sameRepository(worktree, projectDirectory)) throw new PlanDeny('the worktree is not a worktree of this repository')
  let bytes
  try {
    const root = fs.realpathSync(worktree)
    const file = fs.realpathSync(nodePath.join(root, '.pipeline', 'plans', `issue-${reference.issue}-sam.md`))
    if (!isInside(root, file)) throw new PlanDeny('the plan artifact leaves the worktree')
    bytes = fs.readFileSync(file)
  } catch (error) {
    if (error instanceof Deny) throw error
    throw new PlanDeny('the plan artifact cannot be read')
  }
  if (crypto.createHash('sha256').update(bytes).digest('hex') !== reference.digest) throw new PlanDeny('the plan artifact changed since the reference was returned (digest mismatch)')
  const text = bytes.toString('utf8')
  if (!Buffer.from(text, 'utf8').equals(bytes)) throw new PlanDeny('the plan artifact is not valid UTF-8')
  return text
}

// The args with the references replaced in place (key order kept); planRef stays, planText follows it.
function expandedArguments(arguments_, projectDirectory, pluginRoot) {
  const out = {}
  const hasConfig = arguments_.configRef !== undefined
  const hasSpecifics = arguments_.projectSpecificsRef !== undefined
  const config = hasConfig ? expandConfig(arguments_, projectDirectory) : undefined
  const specifics = hasSpecifics ? expandSpecifics(arguments_, projectDirectory, pluginRoot) : undefined
  const planText = arguments_.planRef !== undefined ? expandPlan(arguments_, projectDirectory) : undefined
  for (const key of Object.keys(arguments_)) {
    if (key === 'configRef') out.config = config
    else if (key === 'projectSpecificsRef') out.projectSpecifics = specifics
    else out[key] = arguments_[key]
    if (key === 'planRef') out.planText = planText
  }
  return out
}

function utf8Bytes(text) { return Buffer.byteLength(text, 'utf8') }

// #545: `title` is a string of at most 80 bytes with no control character (newline included); otherwise a Deny.
function validateTitle(arguments_) {
  const title = arguments_.title
  if (title === undefined) return undefined
  if (typeof title !== 'string' || title.trim() === '') throw new Deny('title is not a non-empty string', 'launch-argument-invalid')
  if (/[\u0000-\u001f\u007f]/.test(title)) throw new Deny('title holds a newline or control character', 'launch-argument-invalid')
  const bytes = utf8Bytes(title)
  if (bytes > TITLE_MAX_BYTES) throw new Deny(`title is ${bytes} bytes, over the ${TITLE_MAX_BYTES}-byte bound; shorten the issue title to one line`, 'launch-argument-invalid')
  return title
}

// -> 'owner/repo' from the config, else from the origin remote of the worktree (github.com only), else null.
function repositoryOf(arguments_) {
  const configured = arguments_.config && typeof arguments_.config === 'object' ? arguments_.config.repo : undefined
  if (typeof configured === 'string' && /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(configured)) return configured
  const worktree = arguments_.worktreePath || arguments_.wtPath
  if (typeof worktree !== 'string' || !nodePath.isAbsolute(worktree) || !fs.existsSync(worktree)) return null
  try {
    const remote = gitOut(worktree, ['remote', 'get-url', 'origin'])
    const found = /github\.com[:/]([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?$/.exec(remote)
    return found ? `${found[1]}/${found[2]}` : null
  } catch (error) {
    return null
  }
}

// Replaces any typed `merged`/`epic` by the derived ones (none written on any failure). Returns the new object.
function withDerivedState(expanded, pluginRoot) {
  const out = { ...expanded }
  delete out.merged
  delete out.epic
  const issue = Number(out.issue)
  if (!Number.isInteger(issue) || issue < 1) return out
  const repository = repositoryOf(out)
  if (repository === null) return out
  const { execFileSync } = require('child_process')
  let stdout = ''
  try {
    stdout = execFileSync('node', [nodePath.join(pluginRoot, 'scripts', 'runtime', 'merged-dependencies.cjs'), '--issue', String(issue), '--repo', repository], {
      encoding: 'utf8', timeout: DERIVE_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'],
    })
  } catch (error) {
    return out
  }
  let parsed = null
  try { parsed = JSON.parse(stdout.trim().split('\n').pop() || '') } catch (error) { return out }
  if (!parsed || typeof parsed !== 'object') return out
  if (Array.isArray(parsed.merged) && parsed.merged.length > 0 && parsed.merged.length <= 20 && parsed.merged.every((n) => Number.isInteger(n) && n > 0)) out.merged = parsed.merged
  if (Number.isInteger(parsed.epic) && parsed.epic > 0) out.epic = parsed.epic
  return out
}

// -> a one-line advisory comparing `parallel` with the active runs, or null. Never a refusal.
function parallelAdvisory(arguments_, projectDirectory, pluginRoot) {
  if (!Array.isArray(arguments_.parallel)) return null
  const issue = Number(arguments_.issue)
  const { execFileSync } = require('child_process')
  let listing = ''
  try {
    listing = execFileSync('bash', [nodePath.join(pluginRoot, 'scripts', 'list-active-runs.sh'), projectDirectory], { encoding: 'utf8', timeout: DERIVE_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'] })
  } catch (error) {
    return null
  }
  const active = []
  for (const line of listing.split('\n')) {
    const found = /issue-([0-9]+)\.json/.exec(line)
    if (found && Number(found[1]) !== issue) active.push(Number(found[1]))
  }
  const declared = arguments_.parallel.filter((n) => Number.isInteger(n))
  const missing = declared.filter((n) => !active.includes(n))
  const unlisted = active.filter((n) => !declared.includes(n))
  const parts = []
  if (missing.length > 0) parts.push(`parallel lists ${missing.map((n) => `#${n}`).join(', ')} with no active run (fine if it launches at the same time)`)
  if (unlisted.length > 0) parts.push(`active runs not listed in parallel: ${unlisted.map((n) => `#${n}`).join(', ')}`)
  return parts.length === 0 ? null : `Advisory: ${parts.join('; ')}.`
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
function contextualScript(toolInput, arguments_, projectDirectory, pluginRoot, title) {
  const launch = require('../lib/launch-file.cjs')
  const issue = Number(arguments_.issue)
  if (toolInput.name === undefined && typeof toolInput.scriptPath !== 'string') return null
  if (!Number.isInteger(issue) || issue < 1) return null
  const given = typeof toolInput.scriptPath === 'string' ? toolInput.scriptPath : nodePath.join(pluginRoot, 'workflows', 'deliver-pipeline.js')
  let source
  try { source = fs.readFileSync(given, 'utf8') } catch (error) { return null }
  const made = GENERATED_RE.exec(nodePath.basename(given))
  if (made && crypto.createHash('sha256').update(source, 'utf8').digest('hex').slice(0, 12) !== made[2]) {
    throw new Deny(`the launch file ${nodePath.basename(given)} was modified after it was written; delete it (scripts/runtime/clean-launch-files.cjs) and launch again`)
  }
  const expected = launch.retitle(source, issue, { title, brief: arguments_.brief, pr: Number(arguments_.prNumber) })
  if (expected === null) return null
  const file = launch.launchPath(projectDirectory, issue, expected)
  if (!isIgnored(projectDirectory, nodePath.relative(projectDirectory, file))) return null
  const result = launch.ensureLaunchFile(projectDirectory, issue, expected)
  if (result.denied) throw new Deny(`the launch file ${result.denied} was modified after it was written; delete it (scripts/runtime/clean-launch-files.cjs) and launch again`)
  return result.path
}

function advisory(arguments_) {
  const bytes = typeof arguments_.brief === 'string' ? Buffer.byteLength(arguments_.brief, 'utf8') : 0
  if (bytes <= ADVISORY_BRIEF_BYTES) return null
  return `Advisory: the brief is ${bytes} bytes, over ${ADVISORY_BRIEF_BYTES}; every launch and resume re-sends it. Keep it to the issue number and one line: the engine reads the issue itself.`
}

// -> null (not ours) | {updatedInput, additionalContext?}; throws Deny.
function decide(input, environment) {
  if (!input || typeof input !== 'object') return null
  if (input.tool_name !== undefined && input.tool_name !== 'Workflow') return null
  const toolInput = input.tool_input
  if (!toolInput || typeof toolInput !== 'object') return null
  const read = readArguments(toolInput)
  if (read === 'unparseable') throw new Deny('args is a string that is not valid JSON')
  if (read === null) return null
  const { args: arguments_, isString } = read
  const referenced = arguments_.projectSpecificsRef !== undefined || arguments_.configRef !== undefined || arguments_.planRef !== undefined ||
    arguments_.title !== undefined || arguments_.parallel !== undefined || arguments_.decided !== undefined
  if (!targetsEngine(toolInput) || !referenced) return null
  const projectDirectory = environment.CLAUDE_PROJECT_DIR || input.cwd
  if (typeof projectDirectory !== 'string' || projectDirectory === '') throw new Deny('the project directory is unknown')
  const pluginRoot = nodePath.resolve(__dirname, '..', '..')
  const title = validateTitle(arguments_)
  const expanded = withDerivedState(expandedArguments(arguments_, projectDirectory, pluginRoot), pluginRoot)
  const updated = { ...toolInput, args: isString ? JSON.stringify(expanded) : expanded }
  const script = contextualScript(toolInput, expanded, projectDirectory, pluginRoot, title)
  if (script !== null) {
    delete updated.name
    updated.scriptPath = script
  }
  const notes = [advisory(expanded), parallelAdvisory(expanded, projectDirectory, pluginRoot)].filter((n) => n !== null)
  return notes.length === 0 ? { updatedInput: updated } : { updatedInput: updated, additionalContext: notes.join('\n') }
}

function denyOutput(reason, code = 'specifics-ref-mismatch') {
  const text = `${code}: ${reason}. See docs/consumer-reference.md (${code}). To launch in full form: node ${nodePath.resolve(__dirname, 'launch-args.cjs')} --mode full ...`
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
    if (error instanceof Deny) return denyOutput(error.message, error.code)
    const referenced = REFERENCE_WORDS.test(raw)
    return referenced ? denyOutput('the expansion failed unexpectedly') : 0
  }
}

module.exports = { decide, Deny }

if (require.main === module) process.exitCode = main()
