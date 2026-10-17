#!/usr/bin/env node
'use strict'

// Launch facts (#581): three Setup checks whose answer cannot change during a run are computed by the expansion hook
// (scripts/runtime/workflow-args-expand.cjs) instead of a probe agent copying a command line. Each fact is
// {for, exit, lines}: `for` is the sha256 of a binding string (the check name plus the paths it was computed for), so the
// engine uses a fact only for the launch it was computed for and probes otherwise. `exit` and `lines` are what the same
// script prints when the probe would run it. Fail open: any spawn failure, unreadable file or non-absolute path leaves the
// key out and the engine runs the probe as before. No model, no network, no CLI, nothing printed with a local path.
//
//   pluginVersion   templates/plugin-version.cjs of arguments_.pluginRoot (only with an absolute pluginRoot and no config.probeRunPath)
//   sessionRoot     templates/session-root.cjs of this plugin, cwd = the worktree, argument arguments_.sessionRoot
//   configBaseBranch  {"baseBranch":...} read from <worktree>/.claude/pipeline.config.json (only on a dev or review entry)

const fs = require('fs')
const crypto = require('crypto')
const nodePath = require('path')
const { execFileSync } = require('child_process')

const TIMEOUT_MS = 4000
const MAX_LINES = 4
const MAX_LINE_CHARS = 200

function digest(binding) { return crypto.createHash('sha256').update(binding, 'utf8').digest('hex') }

function isAbsolutePath(value) { return typeof value === 'string' && value !== '' && nodePath.isAbsolute(value) }

function hasControl(text) {
  for (const ch of text) {
    const cp = ch.codePointAt(0)
    if (cp < 0x20 || cp === 0x7f) return true
  }
  return false
}

// -> the printed lines when they fit the bounds the engine checks, else null.
function boundedLines(stdout) {
  const lines = String(stdout || '').split('\n').filter((line, index, all) => !(line === '' && index === all.length - 1))
  if (lines.length > MAX_LINES) return null
  if (lines.some((line) => line.length > MAX_LINE_CHARS || hasControl(line))) return null
  return lines
}

// -> {exit, lines} for a node script run without a shell, or null when it could not be started or timed out.
function runScript(script, scriptArguments, directory) {
  try {
    const stdout = execFileSync('node', [script, ...scriptArguments], { encoding: 'utf8', timeout: TIMEOUT_MS, cwd: directory, stdio: ['ignore', 'pipe', 'ignore'] })
    const lines = boundedLines(stdout)
    return lines === null ? null : { exit: 0, lines }
  } catch (error) {
    if (!error || typeof error.status !== 'number') return null
    const lines = boundedLines(error.stdout)
    return lines === null ? null : { exit: error.status, lines: [] }
  }
}

function pluginVersionFact(arguments_) {
  const root = arguments_.pluginRoot
  if (!isAbsolutePath(root)) return null
  if (arguments_.config && typeof arguments_.config === 'object' && arguments_.config.probeRunPath) return null
  const result = runScript(nodePath.join(root, 'templates', 'plugin-version.cjs'), [], undefined)
  return result === null ? null : { for: digest(`plugin-version\n${root}`), ...result }
}

function sessionRootFact(arguments_, hookPluginRoot) {
  if (!isAbsolutePath(arguments_.sessionRoot) || !isAbsolutePath(arguments_.worktreePath)) return null
  if (!fs.existsSync(arguments_.worktreePath)) return null
  const result = runScript(nodePath.join(hookPluginRoot, 'templates', 'session-root.cjs'), [arguments_.sessionRoot], arguments_.worktreePath)
  return result === null ? null : { for: digest(`session-root\n${arguments_.sessionRoot}\n${arguments_.worktreePath}`), ...result }
}

function configBaseBranchFact(arguments_) {
  if (arguments_.entryStage !== 'dev' && arguments_.entryStage !== 'review') return null
  if (!isAbsolutePath(arguments_.worktreePath)) return null
  let parsed
  try { parsed = JSON.parse(fs.readFileSync(nodePath.join(arguments_.worktreePath, '.claude', 'pipeline.config.json'), 'utf8')) } catch (error) { return null }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null
  const line = JSON.stringify({ baseBranch: parsed.baseBranch === undefined ? null : parsed.baseBranch })
  if (line.length > MAX_LINE_CHARS || hasControl(line)) return null
  return { for: digest(`config-base-branch\n${arguments_.worktreePath}`), exit: 0, lines: [line] }
}

// -> {pluginVersion?, sessionRoot?, configBaseBranch?}; a key is present only when its fact was computed.
function computeLaunchFacts(arguments_, hookPluginRoot) {
  const out = {}
  if (!arguments_ || typeof arguments_ !== 'object') return out
  const pluginVersion = pluginVersionFact(arguments_)
  if (pluginVersion) out.pluginVersion = pluginVersion
  const sessionRoot = sessionRootFact(arguments_, hookPluginRoot)
  if (sessionRoot) out.sessionRoot = sessionRoot
  const configBaseBranch = configBaseBranchFact(arguments_)
  if (configBaseBranch) out.configBaseBranch = configBaseBranch
  return out
}

module.exports = { computeLaunchFacts, digest }
