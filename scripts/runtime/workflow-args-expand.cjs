#!/usr/bin/env node
'use strict'

// PreToolUse(Workflow) hook (#520, epic #528, #605). Two jobs, both scoped to the lgtmgate engine and to nothing else:
//  1. One launch form. The engine is launched from a generated launch file, `<project>/.pipeline/launch/<sha12>/#<N> - <title>.js`
//     (scripts/lib/launch-file.cjs, printed by `launch-args.cjs --mode file`): the card in the conversation and the Background
//     tasks pane label a `scriptPath` launch with the file name. Every other form of the engine is refused here with
//     `engine-launch-form`: a call by its registered name, an inline script that carries the engine, a `deliver-pipeline.js` that
//     carries the engine marker. The engine itself throws the same code when this hook is off, crashed or timed out. A call that
//     is none of these is not ours and is never named, rewritten or blocked (empty stdout, exit 0): another plugin's workflow, a
//     saved workflow, an unrelated inline script, a `scriptPath` that is not the generated shape.
//  2. Expansion. The Lead passes `projectSpecificsRef {refSha, fp12}` and `configRef {path, digest64}` instead of retyping the
//     whole objects; for a launch of the generated file this script verifies them and expands them to the full objects through
//     `hookSpecificOutput.updatedInput` (only `args` changes; `scriptPath` is left as the call gave it).
// Classification follows the Workflow tool's own precedence (`scriptPath`, then `script`, then `name`; the Agent SDK `WorkflowInput`
// names `script`, `name`, `scriptPath`, `args`, `resumeFromRunId`, `title` and `description`, the last two ignored). A relative
// `scriptPath` is resolved against the hook's `cwd`; when the file is then not found the call fails open (the digest is not checked).
// The digest in the directory name proves the file was not edited after it was written. It does not prove the generator wrote it:
// a hand-edited flag is out of scope, the rule prevents accidental drift. `updatedInput` without a permission decision is
// documented for PreToolUse in general and measured live (Claude Code version recorded in MAINTAINING.md); it is not documented for
// the Workflow card, whose label is the file name. Deterministic: git and the assembler run here, no model, nothing is asked.
// Scope of integrity: copy fidelity (the objects the engine reads are the ones the references name), not adversarial integrity.
//
// Stdin: the hook JSON ({cwd, tool_name, tool_input}). Stdout: nothing for a call that is not this engine's, else
// {hookSpecificOutput:{hookEventName, updatedInput, additionalContext?}}, never a permission decision except `deny`.
// A launch of the generated file is expanded when args carries projectSpecificsRef, configRef or planRef. planRef (#533) is kept and gets a
// `planText` right after it: the bytes of .pipeline/plans/issue-<N>-sam.md under the worktree, read only when their sha256
// equals planRef.digest (the digest the engine pinned when it returned the plan); every failure is `plan-ref-mismatch`.
// Run state (#545): a launch that carries `title`, `parallel` or `decided` is also expanded. The hook deletes any typed
// `merged`/`epic`, then writes its own from scripts/runtime/merged-dependencies.cjs (the `depends-on:` issues closed as completed,
// and the epic parent; fail open: a failure writes no key). `title` (#599) is derived the same way, from the issue title cut to 80
// bytes at a word boundary, and replaces the typed one; the typed value is only the fallback when the issue cannot be read. A title
// derived from the issue that differs from the launch file's label gives an advisory (the file is never rewritten here);
// `parallel` is compared with the active runs as an advisory, never a refusal (two simultaneous launches cannot see each other's
// state file).
// Launch facts (#581): the hook also deletes any typed `launchFacts` and writes the plugin-version, session-root and config
// baseBranch answers it computes itself (scripts/runtime/launch-facts.cjs, bound to the launch by a digest; fail open).
// Fail closed: any unexpected error on a call that is this engine's (by name, or a classified engine form) is a deny; the text of
// a deny is one string, written identically to stderr and to the JSON reason.
// Exit: 0 ok or not ours · 2 deny (reason on stderr and in the JSON; the reason names no role and no specifics text).

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')

const launch = require('../lib/launch-file.cjs')
const { repositoryOf } = require('../lib/issue-title.cjs')

const ENGINE_NAME = 'lgtmgate:deliver-pipeline'
const FORM_CODE = 'engine-launch-form'
const FORM_REASONS = {
  name: 'the engine was called by its registered name',
  inline: 'the engine source was passed inline as the script',
  source: 'the engine source file was launched directly',
}
const FORM_FALLBACK = `${FORM_CODE}: the engine was not launched from its launch file. Print the launch file with launch-args.cjs --mode file and launch its scriptPath. See docs/consumer-reference.md (${FORM_CODE}).`
const SAFE_PATH_RE = /^[A-Za-z0-9._/+@-]+$/
const REFERENCE_WORDS = /projectSpecificsRef|configRef|planRef/
const ADVISORY_BRIEF_BYTES = 700
const ASSEMBLER_TIMEOUT_MS = 8000
const DERIVE_TIMEOUT_MS = 8000
const TITLE_MAX_BYTES = 80

class Deny extends Error {
  constructor(message, code, launchArguments) {
    super(message)
    this.code = code || 'specifics-ref-mismatch'
    this.args = launchArguments || null
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

function sha12Of(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex').slice(0, 12)
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8') } catch (error) { return null }
}

// The form of the call, by the tool's own precedence (scriptPath, then script, then name):
//   {kind: 'generated', path, digest, issue} | {kind: 'name' | 'inline' | 'source'} | {kind: 'other'}  (other = not ours).
function engineForm(toolInput, cwd) {
  if (typeof toolInput.scriptPath === 'string') {
    const given = toolInput.scriptPath
    const resolved = nodePath.isAbsolute(given) || typeof cwd !== 'string' || cwd === '' ? given : nodePath.resolve(cwd, given)
    const parsed = launch.parseLaunchPath(resolved)
    if (parsed !== null) return { kind: 'generated', path: resolved, digest: parsed.digest, issue: parsed.issue }
    if (nodePath.basename(resolved) !== 'deliver-pipeline.js') return { kind: 'other' }
    const held = readText(resolved)
    return held !== null && launch.ENGINE_MARKER_RE.test(held) ? { kind: 'source' } : { kind: 'other' }
  }
  for (const [key, value] of Object.entries(toolInput)) {
    if (key !== 'args' && typeof value === 'string' && launch.ENGINE_MARKER_RE.test(value)) return { kind: 'inline' }
  }
  if (typeof toolInput.script === 'string') return { kind: 'other' }
  return toolInput.name === ENGINE_NAME ? { kind: 'name' } : { kind: 'other' }
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
  const worktree = arguments_.worktreePath
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
  const worktree = arguments_.worktreePath
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

// Replaces any typed `merged`/`epic`/`launchFacts` by the derived ones (none written on any failure). Returns the new object
// and the title read from the issue (null when it was not read: the typed one is never reported as derived).
function withDerivedState(expanded, pluginRoot) {
  const out = { ...expanded }
  delete out.merged
  delete out.epic
  delete out.launchFacts
  const facts = require('./launch-facts.cjs').computeLaunchFacts(out, pluginRoot)
  if (Object.keys(facts).length > 0) out.launchFacts = facts
  const issue = Number(out.issue)
  if (!Number.isInteger(issue) || issue < 1) return { state: out, derivedTitle: null }
  const repository = repositoryOf(out)
  if (repository === null) return { state: out, derivedTitle: null }
  const { execFileSync } = require('child_process')
  let stdout = ''
  try {
    stdout = execFileSync('node', [nodePath.join(pluginRoot, 'scripts', 'runtime', 'merged-dependencies.cjs'), '--issue', String(issue), '--repo', repository], {
      encoding: 'utf8', timeout: DERIVE_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'ignore'],
    })
  } catch (error) {
    return { state: out, derivedTitle: null }
  }
  let parsed = null
  try { parsed = JSON.parse(stdout.trim().split('\n').pop() || '') } catch (error) { return { state: out, derivedTitle: null } }
  if (!parsed || typeof parsed !== 'object') return { state: out, derivedTitle: null }
  if (Array.isArray(parsed.merged) && parsed.merged.length > 0 && parsed.merged.length <= 20 && parsed.merged.every((n) => Number.isInteger(n) && n > 0)) out.merged = parsed.merged
  if (Number.isInteger(parsed.epic) && parsed.epic > 0) out.epic = parsed.epic
  let derivedTitle = null
  if (typeof parsed.title === 'string' && parsed.title.trim() !== '' && utf8Bytes(parsed.title) <= TITLE_MAX_BYTES && !/[\u0000-\u001f\u007f]/.test(parsed.title)) {
    out.title = parsed.title
    derivedTitle = parsed.title
  }
  return { state: out, derivedTitle }
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

// Reads the generated launch file and checks its bytes against the digest of its directory. -> the text, or null when the file
// cannot be read (fail open: a relative path read from another cwd, a file deleted since the launch).
function verifyGenerated(form) {
  let bytes
  try { bytes = fs.readFileSync(form.path) } catch (error) { return null }
  if (sha12Of(bytes) !== form.digest) {
    throw new Deny(`the launch file ${nodePath.basename(form.path)} was modified after it was written; delete it (scripts/runtime/clean-launch-files.cjs) and launch again`)
  }
  return bytes.toString('utf8')
}

// -> an advisory when the title read from the issue now differs from the label of the launch file, else null. Never a refusal,
// never computed from a typed title or the brief.
function driftAdvisory(source, derivedTitle, issue) {
  if (source === null || derivedTitle === null) return null
  const expected = launch.retitle(source, issue, { title: derivedTitle })
  if (expected === null || expected === source) return null
  const name = launch.metaName(source)
  return `Advisory: the launch file label reads "${name}" but the issue title reads "${derivedTitle}" now; the run goes on with this file; print a new one with launch-args.cjs --mode file to relabel.`
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
  const form = engineForm(toolInput, input.cwd)
  if (form.kind === 'other') return null
  const read = readArguments(toolInput)
  const known = read !== null && read !== 'unparseable' ? read.args : null
  if (form.kind !== 'generated') throw new Deny(FORM_REASONS[form.kind], FORM_CODE, known)
  const source = verifyGenerated(form)
  if (read === 'unparseable') throw new Deny('args is a string that is not valid JSON')
  if (read === null) return null
  const { args: arguments_, isString } = read
  if (arguments_.issue !== undefined && Number(arguments_.issue) !== form.issue) {
    throw new Deny(`the launch file ${nodePath.basename(form.path)} was made for issue #${form.issue} but the launch carries another issue`, FORM_CODE, arguments_)
  }
  const referenced = arguments_.projectSpecificsRef !== undefined || arguments_.configRef !== undefined || arguments_.planRef !== undefined ||
    arguments_.title !== undefined || arguments_.parallel !== undefined || arguments_.decided !== undefined
  if (!referenced) return null
  const projectDirectory = environment.CLAUDE_PROJECT_DIR || input.cwd
  if (typeof projectDirectory !== 'string' || projectDirectory === '') throw new Deny('the project directory is unknown')
  const pluginRoot = nodePath.resolve(__dirname, '..', '..')
  const { state: expanded, derivedTitle } = withDerivedState(expandedArguments(arguments_, projectDirectory, pluginRoot), pluginRoot)
  validateTitle(expanded)
  const updated = { ...toolInput, args: isString ? JSON.stringify(expanded) : expanded }
  const notes = [advisory(expanded), parallelAdvisory(expanded, projectDirectory, pluginRoot), driftAdvisory(source, derivedTitle, form.issue)].filter((n) => n !== null)
  return notes.length === 0 ? { updatedInput: updated } : { updatedInput: updated, additionalContext: notes.join('\n') }
}

// A value printed in a refusal only when it is plainly safe to paste in a shell: a positive safe integer, an absolute path of
// plain characters. Anything else prints as its placeholder; the brief is never echoed (#605, audit note 3).
function safeNumber(value) {
  const n = Number(value)
  return Number.isSafeInteger(n) && n >= 1 ? String(n) : '<N>'
}

function safePath(value, placeholder) {
  return typeof value === 'string' && nodePath.isAbsolute(value) && SAFE_PATH_RE.test(value) ? value : placeholder
}

function formText(reason, arguments_, environment) {
  const given = arguments_ && typeof arguments_ === 'object' ? arguments_ : {}
  const project = safePath(given.sessionRoot, safePath(environment.CLAUDE_PROJECT_DIR, '<project>'))
  const script = nodePath.resolve(__dirname, 'launch-args.cjs')
  return `${FORM_CODE}: ${reason}. Print the launch file and launch its scriptPath: node ${script} --mode file --issue ${safeNumber(given.issue)} --root ${safePath(given.worktreePath, '<worktree>')} --session-root ${project} --brief "<one line>". See docs/consumer-reference.md (${FORM_CODE}).`
}

// -> {code: 2, stdout, stderr}: one text, written identically to stderr and to the JSON reason. The text builder falls back to a
// constant when it throws.
function denyResult(reason, code, arguments_, environment) {
  let text
  try {
    text = code === FORM_CODE
      ? formText(reason, arguments_, environment)
      : `${code}: ${reason}. See docs/consumer-reference.md (${code}). To launch in full form: node ${nodePath.resolve(__dirname, 'launch-args.cjs')} --mode full ...`
  } catch (error) {
    text = FORM_FALLBACK
  }
  return {
    code: 2,
    stdout: JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: text } }) + '\n',
    stderr: `${text}\n`,
  }
}

// An unexpected error. Fail closed only for a call that is this engine's; a foreign call is never denied.
function failClosed(input, raw, environment) {
  const toolInput = input && typeof input === 'object' && input.tool_input && typeof input.tool_input === 'object' ? input.tool_input : null
  let kind = 'other'
  try { kind = toolInput === null ? 'other' : engineForm(toolInput, input.cwd).kind } catch (error) { kind = toolInput !== null && toolInput.name === ENGINE_NAME ? 'name' : 'other' }
  if (kind === 'other') return { code: 0, stdout: '', stderr: '' }
  if (kind === 'generated') {
    return REFERENCE_WORDS.test(raw) ? denyResult('the expansion failed unexpectedly', 'specifics-ref-mismatch', null, environment) : { code: 0, stdout: '', stderr: '' }
  }
  return denyResult('the launch could not be checked', FORM_CODE, null, environment)
}

// Pure: -> {code, stdout, stderr}. `main` only writes it.
function run(raw, environment) {
  let input = null
  try { input = JSON.parse(raw) } catch (error) {
    if (raw.includes(ENGINE_NAME)) return denyResult('the hook input is not valid JSON', FORM_CODE, null, environment)
    return REFERENCE_WORDS.test(raw) ? denyResult('the hook input is not valid JSON', 'specifics-ref-mismatch', null, environment) : { code: 0, stdout: '', stderr: '' }
  }
  try {
    const result = decide(input, environment)
    if (result === null) return { code: 0, stdout: '', stderr: '' }
    const output = { hookEventName: 'PreToolUse', updatedInput: result.updatedInput }
    if (result.additionalContext) output.additionalContext = result.additionalContext
    return { code: 0, stdout: JSON.stringify({ hookSpecificOutput: output }) + '\n', stderr: '' }
  } catch (error) {
    if (error instanceof Deny) return denyResult(error.message, error.code, error.args, environment)
    return failClosed(input, raw, environment)
  }
}

function main() {
  let raw = ''
  try { raw = fs.readFileSync(0, 'utf8') } catch (error) { return 0 }
  const result = run(raw, process.env)
  if (result.stdout !== '') process.stdout.write(result.stdout)
  if (result.stderr !== '') process.stderr.write(result.stderr)
  return result.code
}

module.exports = { decide, run, Deny }

if (require.main === module) process.exitCode = main()
