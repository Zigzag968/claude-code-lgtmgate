#!/usr/bin/env node
'use strict'

// One read-only verdict on the setup, before the first launch (#521). It runs the checks that /lgtmgate:deliver
// steps 0 and 1 run one at a time (plugin installs, config keys, init copies, sandbox certificate bundle, agents
// context) plus one new check (free disk space), prints one line per finding with the exact command to run, and ends
// with a single verdict that is never `ok` when a check could not run. It implements no check twice: each one calls the
// existing script, exactly as deliver does. Read-only: nothing is written, no printed command is ever run, no fetch.
//
// Usage: node scripts/doctor.cjs [--root <project>] [--plugin-root <dir>] [--target <version>] [--base <branch>] [--min-free-gb <n>] [--help]
//   --root          the project (default: the current directory)
//   --plugin-root   the plugin (default: the parent of scripts/); its .claude-plugin/plugin.json gives the default --target
//   --target        the plugin version the installs must equal (default: the version of the plugin root)
//   --base          the base branch whose origin/<base> ref feeds the agents context (default: baseBranch of the config, else main)
//   --min-free-gb   free space below which the disk check stops the launch (default 5)
// Stdout: one line per finding, `stop|warn|not-run <name>: <detail> | run: <exact command>`, indented detail lines under
//         a finding, the agents context table when it ran, then the last line
//         [doctor] verdict=ok|warn|stop|incomplete stop=<n> warn=<n> not-run=<n>
// Exit: 1 when any `stop`, else 2 when any check did not run (verdict incomplete), else 0 (ok or warn).

const fs = require('fs')
const path = require('path')
const { spawnSync } = require('child_process')
const { CHECKS } = require('./lib/doctor-checks.cjs')

const DEFAULT_MIN_FREE_GB = 5
const USAGE = 'usage: doctor.cjs [--root <project>] [--plugin-root <dir>] [--target <version>] [--base <branch>] [--min-free-gb <n>] [--help]'

class UsageError extends Error {}

function parseArguments(argv) {
  const options = { root: process.cwd(), pluginRoot: path.join(__dirname, '..'), target: null, base: null, minFreeGb: DEFAULT_MIN_FREE_GB, help: false }
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index]
    const value = () => {
      if (index + 1 >= argv.length) throw new UsageError(`${argument} needs a value`)
      return argv[++index]
    }
    if (argument === '--help' || argument === '-h') options.help = true
    else if (argument === '--root') options.root = path.resolve(value())
    else if (argument === '--plugin-root') options.pluginRoot = path.resolve(value())
    else if (argument === '--target') options.target = value()
    else if (argument === '--base') options.base = value()
    else if (argument === '--min-free-gb') {
      const raw = value()
      const number = Number(raw)
      if (raw.trim() === '' || !Number.isFinite(number) || number < 0) throw new UsageError(`--min-free-gb needs a number >= 0, got ${JSON.stringify(raw)}`)
      options.minFreeGb = number
    } else throw new UsageError(`unknown argument: ${argument}`)
  }
  return options
}

function helpText() {
  const lines = [USAGE, '', 'Checks, in order (each calls the existing script named, or is new):']
  for (const check of CHECKS) {
    const calls = check.script === 'new' ? 'new' : `calls ${check.script}`
    lines.push(`  ${check.id}: ${check.label}; ${calls}; findings: ${check.findings.join(', ')}`)
  }
  lines.push('', 'Any check that cannot run is reported as `not-run check-not-run` and the verdict is `incomplete`, never `ok`.')
  return lines.join('\n') + '\n'
}

// ---- running the existing scripts (argv arrays, no shell) -----------------------------------

function run(command, commandArguments, cwd) {
  const result = spawnSync(command, commandArguments, { cwd, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })
  if (result.error) return { failed: `${command} did not start (${result.error.message})`, status: null, stdout: '', stderr: '' }
  if (result.status === null) return { failed: `${command} was stopped by ${result.signal || 'a signal'}`, status: null, stdout: '', stderr: '' }
  return { failed: null, status: result.status, stdout: result.stdout || '', stderr: result.stderr || '' }
}

const lines = (text) => text.split('\n').map((line) => line.replace(/\s+$/, '')).filter((line) => line !== '')
const firstLine = (...texts) => {
  for (const text of texts) {
    const found = lines(text)[0]
    if (found) return found
  }
  return 'no output'
}

// ---- findings ---------------------------------------------------------------------------------

function createReport() {
  const out = []
  const count = { stop: 0, warn: 0, 'not-run': 0 }
  return {
    out,
    count,
    finding(level, name, detail, command, more) {
      count[level]++
      out.push(`${level} ${name}: ${detail}${command ? ` | run: ${command}` : ''}`)
      for (const extra of more || []) out.push(`  ${extra}`)
    },
    notRun(checkId, reason) {
      count['not-run']++
      out.push(`not-run check-not-run: ${checkId}: ${reason} | run: run the script of that check by hand to see its error (doctor.cjs --help names it), fix it, then rerun the doctor`)
    },
  }
}

// ---- the checks ---------------------------------------------------------------------------------

function readJson(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'))
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : null
  } catch (error) {
    return null
  }
}

function checkInstalls(report, context) {
  const { options, target } = context
  if (!target) return report.notRun('installs', `cannot read the target version from ${path.join(options.pluginRoot, '.claude-plugin/plugin.json')} (pass --target <version>)`)
  const script = path.join(options.pluginRoot, 'scripts/plugin-versions.sh')
  const result = run('bash', [script, '--loaded-root', options.pluginRoot, '--project', options.root, '--target', target], options.root)
  if (result.failed) return report.notRun('installs', result.failed)
  if (result.status !== 0 && result.status !== 1) return report.notRun('installs', `plugin-versions.sh exit ${result.status}: ${firstLine(result.stderr, result.stdout)}`)
  const output = lines(result.stdout)
  if (!output.length || !output[output.length - 1].startsWith('plugin-versions:')) return report.notRun('installs', 'plugin-versions.sh printed no summary line')
  let recognised = 0
  for (const line of output) {
    const installLine = /^(\S+) project=(\S+) channel=(\S+) enabled=(\S+) version=(\S+)(.*)$/.exec(line)
    if (line.startsWith('CONFLICT:')) {
      recognised++
      const commands = line.match(/claude plugin disable \S+ --scope [^\s;]+/g) || []
      report.finding('stop', 'channel-conflict', line.replace(/;\s*keep one and disable the other:.*$/, ''), `${commands.join(' or ')}, then restart the session`)
    } else if (line.startsWith('MARKETPLACE-CONFLICT:')) {
      recognised++
      const fix = /Fix: (.*)$/.exec(line)
      report.finding('stop', 'marketplace-conflict', line.replace(/\.\s*Fix:.*$/, ''), `${fix ? fix[1] : 'give the marketplace one source in the files named'}, then restart the session`)
    } else if (line.startsWith('LOADED-CACHE:')) {
      recognised++
      const uninstall = /remove the loaded one: (.*)$/.exec(line)
      report.finding('stop', 'loaded-cache', line.replace(/;\s*remove the loaded one:.*$/, ''), `${uninstall ? uninstall[1] : 'claude plugin uninstall <plugin>@<channel> --scope <scope>'}, then restart the session`)
    } else if (installLine && installLine[6].includes(' MISMATCH:')) {
      recognised++
      const [, scope, project, channel, , version] = installLine
      const mismatch = /MISMATCH: (.*?)(?: OTHER-PROJECT|$)/.exec(installLine[6])
      report.finding('stop', 'version-mismatch', `${scope} install of ${channel} (project=${project}): ${mismatch ? mismatch[1] : `found ${version}`}`, `claude plugin update lgtmgate@${channel} --scope ${scope}, then restart the session`)
    } else if (installLine && installLine[6].includes(' OTHER-PROJECT:')) {
      recognised++
      const [, scope, project, channel, , version] = installLine
      report.finding('warn', 'installs-elsewhere', `${scope} install of ${channel} version ${version} belongs to project ${project}, not loaded here`, `claude plugin uninstall lgtmgate@${channel} --scope ${scope} (from ${project}, only if it is not needed there)`)
    }
  }
  if (result.status === 1 && recognised === 0) report.notRun('installs', 'plugin-versions.sh exit 1 with a line the doctor does not know')
}

function checkConfig(report, context) {
  const { options } = context
  const file = path.join(options.root, '.claude/pipeline.config.json')
  const result = run('node', [path.join(options.pluginRoot, 'scripts/config-check.cjs'), file], options.root)
  if (result.failed) return report.notRun('config', result.failed)
  const output = lines(result.stdout)
  const trailer = /^\[config-check\] status=(ok|warn) /.exec(output[output.length - 1] || '')
  if (result.status !== 0 || !trailer) return report.notRun('config', `config-check.cjs gave no status line (exit ${result.status}): ${firstLine(result.stderr, result.stdout)}`)
  const warns = output.filter((line) => line.startsWith('warn:'))
  if (trailer[1] === 'warn') report.finding('warn', 'config-warn', `${warns.length} warning(s) on ${file}`, '/lgtmgate:init and choose "complete" (an existing config is never overwritten), then commit and push on the base branch', warns)
}

function checkTemplateDrift(report, context) {
  const { options } = context
  const result = run('node', [path.join(options.pluginRoot, 'scripts/template-drift.cjs'), '--root', options.root], options.root)
  if (result.failed) return report.notRun('template-drift', result.failed)
  const output = lines(result.stdout)
  const trailer = /^\[template-drift\] status=(ok|warn) /.exec(output[output.length - 1] || '')
  if (result.status !== 0 || !trailer) return report.notRun('template-drift', `template-drift.cjs gave no status line (exit ${result.status}): ${firstLine(result.stderr, result.stdout)}`)
  const asks = output.filter((line) => /^(warn|obsolete):/.test(line))
  if (trailer[1] === 'warn') report.finding('warn', 'template-drift-warn', `${asks.length} copy(ies) made by init to fix`, 'the command on each line below, then commit and push on the base branch', asks)
}

function checkCaBundle(report, context) {
  const { options } = context
  const result = run('bash', [path.join(options.pluginRoot, 'scripts/ca-bundle-check.sh')], options.root)
  if (result.failed) return report.notRun('ca-bundle', result.failed)
  if (result.status === 1 && result.stdout.startsWith('sandbox-ca-stale')) {
    return report.finding('stop', 'ca-bundle-stale', firstLine(result.stdout), 'restart the session, then relaunch (docs/long-lived-sessions.md)')
  }
  if (result.status !== 0) return report.notRun('ca-bundle', `ca-bundle-check.sh exit ${result.status}: ${firstLine(result.stderr, result.stdout)}`)
}

function nearestExisting(start) {
  let current = start
  for (;;) {
    if (fs.existsSync(current)) return current
    const parent = path.dirname(current)
    if (parent === current) return current
    current = parent
  }
}

function checkDisk(report, context) {
  const { options } = context
  const resolved = run('bash', ['-c', '. "$1"; resolve_worktree_root', '_', path.join(options.pluginRoot, 'hooks/lib-worktree-root.sh')], options.root)
  if (resolved.failed) return report.notRun('disk', resolved.failed)
  const worktreeRoot = resolved.stdout.trim()
  if (resolved.status !== 0 || !worktreeRoot) return report.notRun('disk', `no worktree root resolves for ${options.root} (set an absolute worktreeRoot in .claude/pipeline.config.json)`)
  let freeGb
  const probe = nearestExisting(worktreeRoot)
  try {
    const stats = fs.statfsSync(probe)
    freeGb = (Number(stats.bavail) * Number(stats.bsize)) / 1024 ** 3
  } catch (error) {
    return report.notRun('disk', `cannot read the free space of ${probe} (${error.message})`)
  }
  if (freeGb < options.minFreeGb) {
    report.finding('stop', 'low-disk-space', `${freeGb.toFixed(1)} GB free under ${worktreeRoot}, below the ${options.minFreeGb} GB minimum`, `df -h ${worktreeRoot}`)
  }
}

function checkAgentsContext(report, context) {
  const { options, base } = context
  const script = path.join(options.pluginRoot, 'scripts/runtime/agent-context.cjs')
  const common = ['--root', options.root, '--ref', `origin/${base}`]
  const result = run('node', [script, ...common], options.root)
  if (result.failed) return report.notRun('agents-context', result.failed)
  if ([2, 3, 4].includes(result.status)) {
    return report.finding('stop', 'agents-context-refused', `agent-context.cjs exit ${result.status}: ${firstLine(result.stderr)}`, `fix the file named, then /lgtmgate:context to check (the ref read is origin/${base})`, lines(result.stderr).slice(1, 6))
  }
  if (result.status !== 0) return report.notRun('agents-context', `agent-context.cjs exit ${result.status}: ${firstLine(result.stderr, result.stdout)}`)
  let payload
  try {
    payload = JSON.parse(lines(result.stdout)[0] || '')
  } catch (error) {
    return report.notRun('agents-context', 'agent-context.cjs printed no JSON line')
  }
  if (!payload || !Array.isArray(payload.warnings)) return report.notRun('agents-context', 'agent-context.cjs JSON holds no warnings list')
  const oversize = payload.warnings.filter((warning) => warning && ['oversize', 'total-oversize', 'shared-oversize'].includes(warning.kind))
  if (oversize.length) {
    const detail = oversize.map((warning) => `${warning.kind}${warning.role ? ` ${warning.role}` : ''} ${warning.bytes} bytes against ${warning.recommended}`).join('; ')
    report.finding('warn', 'agents-context-oversize', detail, '/lgtmgate:context audit')
  }
  const table = run('node', [script, ...common, '--print'], options.root)
  if (!table.failed && table.status === 0) report.out.push(...lines(table.stdout).map((line) => `  ${line}`))
}

// ---- main ---------------------------------------------------------------------------------------

function main(argv) {
  let options
  try {
    options = parseArguments(argv)
  } catch (error) {
    if (!(error instanceof UsageError)) throw error
    process.stderr.write(`doctor: ${error.message}\n${USAGE}\n`)
    return 2
  }
  if (options.help) {
    process.stdout.write(helpText())
    return 0
  }
  const manifest = readJson(path.join(options.pluginRoot, '.claude-plugin/plugin.json'))
  const target = options.target || (manifest && typeof manifest.version === 'string' && manifest.version ? manifest.version : null)
  const config = readJson(path.join(options.root, '.claude/pipeline.config.json'))
  const base = options.base || (config && typeof config.baseBranch === 'string' && config.baseBranch ? config.baseBranch : 'main')
  const context = { options, target, base }
  const report = createReport()
  const runners = { installs: checkInstalls, config: checkConfig, 'template-drift': checkTemplateDrift, 'ca-bundle': checkCaBundle, disk: checkDisk, 'agents-context': checkAgentsContext }
  for (const check of CHECKS) {
    try {
      runners[check.id](report, context)
    } catch (error) {
      report.notRun(check.id, `the check threw (${error && error.message})`)
    }
  }
  const { stop, warn } = report.count
  const notRun = report.count['not-run']
  const verdict = stop > 0 ? 'stop' : notRun > 0 ? 'incomplete' : warn > 0 ? 'warn' : 'ok'
  report.out.push(`[doctor] verdict=${verdict} stop=${stop} warn=${warn} not-run=${notRun}`)
  process.stdout.write(report.out.join('\n') + '\n')
  return stop > 0 ? 1 : notRun > 0 ? 2 : 0
}

process.exitCode = main(process.argv.slice(2))
