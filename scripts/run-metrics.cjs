#!/usr/bin/env node
'use strict';
// Anonymized pipeline performance metrics from raw REST issue/PR JSON (#44, part a).
// Usage: node scripts/run-metrics.cjs (--input <dir> | --repo <owner/name>) [--csv <file>]
//   --input <dir>   reads <dir>/issues.json and <dir>/pulls.json (raw REST arrays)
//   --repo <o/n>    loads both through `gh api --paginate --slurp` (REST only)
//   --csv <file>    also writes the per-run rows as CSV
// Output: a Markdown table (run-N labels only: no number, title, repo, user, URL or path)
// plus summary rows. A value no source records is printed `not measured`, never estimated.
// Exit: 0 ok, 1 load/parse failure, 2 usage error.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const NM = 'not measured';
const USAGE = 'usage: node scripts/run-metrics.cjs (--input <dir> | --repo <owner/name>) [--csv <file>]\n';

function usage(message) {
  process.stderr.write((message ? message + '\n' : '') + USAGE);
  process.exit(2);
}

function parseArguments(argv) {
  const o = { input: null, repo: null, csv: null };
  for (let index = 0; index < argv.length; index++) {
    const a = argv[index];
    if (a !== '--input' && a !== '--repo' && a !== '--csv') usage('unknown argument');
    const v = argv[++index];
    if (v === undefined || v.startsWith('--')) usage('missing value for ' + a);
    o[a.slice(2)] = v;
  }
  if ((o.input === null) === (o.repo === null)) usage('give exactly one of --input and --repo');
  if (o.repo !== null && !/^[\w.-]+\/[\w.-]+$/.test(o.repo)) usage('--repo must look like owner/name');
  return o;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function loadGh(repository) {
  const get = (kind) => {
    const out = execFileSync('gh', ['api', '--paginate', '--slurp', 'repos/' + repository + '/' + kind + '?state=all&per_page=100'],
      { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
    return [].concat(...JSON.parse(out));
  };
  return { issues: get('issues'), pulls: get('pulls') };
}

// Mirrors the engine's own reading of the decision-log block: last start marker, trimmed lines.
function roundsToLgtm(body) {
  const lines = String(body || '').split(/\r?\n/);
  let start = -1;
  for (let index = 0; index < lines.length; index++) if (lines[index].startsWith('<!-- decision-log:start -->')) start = index;
  if (start < 0) return null;
  for (let index = start + 1; index < lines.length; index++) {
    const l = lines[index].trim();
    if (l.startsWith('<!-- decision-log:end -->')) break;
    const m = /^- round (\d+) — LGTM\b/.exec(l);
    if (m) return Number(m[1]);
  }
  return null;
}

function hoursBetween(a, b) {
  if (!a || !b) return null;
  const ms = Date.parse(b) - Date.parse(a);
  return Number.isFinite(ms) ? Math.round(ms / 360000) / 10 : null;
}

function compute(issues, pulls) {
  const byNumber = new Map();
  for (const index of issues) if (!('pull_request' in index)) byNumber.set(index.number, index);
  const sorted = pulls.slice().sort((a, b) =>
    (Date.parse(a.created_at) - Date.parse(b.created_at)) || (a.number - b.number));
  return sorted.map((pr, index) => {
    const m = /\b(?:closes|fixes|resolves)\s+#(\d+)/i.exec(pr.body || '');
    const issue = m ? byNumber.get(Number(m[1])) : undefined;
    const outcome = pr.merged_at ? 'merged' : (pr.state === 'closed' ? 'closed-unmerged' : 'open');
    return {
      run: 'run-' + (index + 1),
      rounds: roundsToLgtm(pr.body),
      issueToPr: issue ? hoursBetween(issue.created_at, pr.created_at) : null,
      prToMerge: pr.merged_at ? hoursBetween(pr.created_at, pr.merged_at) : null,
      outcome,
    };
  });
}

const cell = (v) => (v === null ? NM : String(v));
const fmt = (n) => (Math.round(n * 10) / 10).toFixed(1);

function median(xs) {
  const s = xs.slice().sort((a, b) => a - b);
  const h = s.length >> 1;
  return s.length % 2 ? s[h] : (s[h - 1] + s[h]) / 2;
}

function render(rows) {
  const out = ['| Run | Rounds to LGTM | Issue to PR (h) | PR to merge (h) | Outcome |', '|---|---|---|---|---|'];
  for (const r of rows) out.push('| ' + [r.run, cell(r.rounds), cell(r.issueToPr), cell(r.prToMerge), r.outcome].join(' | ') + ' |');
  out.push('', 'Runs: ' + rows.length, '');
  const rounds = rows.map((r) => r.rounds).filter((x) => x !== null);
  const distribution = new Map();
  for (const n of rounds) distribution.set(n, (distribution.get(n) || 0) + 1);
  out.push('Rounds distribution:');
  for (const n of Array.from(distribution.keys()).sort((a, b) => a - b)) out.push('- ' + n + (n === 1 ? ' round: ' : ' rounds: ') + distribution.get(n));
  out.push('');
  for (const [label, key] of [['Issue to PR (h)', 'issueToPr'], ['PR to merge (h)', 'prToMerge']]) {
    const xs = rows.map((r) => r[key]).filter((x) => x !== null);
    out.push(label + ': median ' + (xs.length ? fmt(median(xs)) : NM) + ', max ' + (xs.length ? fmt(Math.max(...xs)) : NM));
  }
  out.push('');
  out.push('Rounds to LGTM: ' + (rows.length - rounds.length) + ' runs ' + NM + ' (excluded from aggregates)');
  for (const [label, key] of [['Issue to PR', 'issueToPr'], ['PR to merge', 'prToMerge']]) {
    out.push(label + ': ' + rows.filter((r) => r[key] === null).length + ' runs ' + NM + ' (excluded from aggregates)');
  }
  out.push('tokens per run and agent: ' + NM);
  out.push('merged without manual takeover: ' + NM);
  return out.join('\n') + '\n';
}

function renderCsv(rows) {
  const out = ['run,rounds_to_lgtm,issue_to_pr_hours,pr_to_merge_hours,outcome'];
  for (const r of rows) out.push([r.run, cell(r.rounds), cell(r.issueToPr), cell(r.prToMerge), r.outcome].join(','));
  return out.join('\n') + '\n';
}

function main() {
  const o = parseArguments(process.argv.slice(2));
  let data;
  try {
    data = o.input !== null
      ? { issues: readJson(path.join(o.input, 'issues.json')), pulls: readJson(path.join(o.input, 'pulls.json')) }
      : loadGh(o.repo);
  } catch {
    process.stderr.write('run-metrics: cannot load the input data\n');
    process.exit(1);
  }
  if (!Array.isArray(data.issues) || !Array.isArray(data.pulls)) {
    process.stderr.write('run-metrics: input must be two JSON arrays\n');
    process.exit(1);
  }
  const rows = compute(data.issues, data.pulls);
  if (o.csv !== null) fs.writeFileSync(o.csv, renderCsv(rows));
  process.stdout.write(render(rows));
}

main();
