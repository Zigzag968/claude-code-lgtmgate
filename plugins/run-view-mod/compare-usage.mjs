// Usage: node plugins/run-view-mod/compare-usage.mjs <dump.json> <transcriptDir>
// Compares the mod's per-agent token totals with the transcript sums (deduped by message.id). Limit 2 percent.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const FIELDS = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"];
const [dumpPath, dir] = process.argv.slice(2);
if (!dumpPath || !dir) {
  console.error("FAIL usage: compare-usage.mjs <dump.json> <transcriptDir>");
  process.exit(1);
}

const dump = JSON.parse(readFileSync(dumpPath, "utf8"));
const modTotals = {};
for (const [id, a] of Object.entries(dump.agents ?? {})) modTotals[id] = FIELDS.reduce((s, f) => s + (a[f] ?? 0), 0);

const trTotals = {};
for (const file of readdirSync(dir)) {
  const m = /^agent-(.+)\.jsonl$/.exec(file);
  if (!m) continue;
  const seen = new Set();
  let sum = 0;
  for (const line of readFileSync(join(dir, file), "utf8").split("\n")) {
    if (!line.trim()) continue;
    let row;
    try { row = JSON.parse(line); } catch { continue; }
    const msg = row.message;
    if (!msg?.usage || !msg.id || seen.has(msg.id)) continue;
    seen.add(msg.id);
    sum += FIELDS.reduce((s, f) => s + (msg.usage[f] ?? 0), 0);
  }
  trTotals[m[1]] = sum;
}

let max = 0;
let bad = false;
for (const id of new Set([...Object.keys(modTotals), ...Object.keys(trTotals)])) {
  const a = modTotals[id];
  const b = trTotals[id];
  if (a === undefined || b === undefined) {
    console.log(`agent ${id} mod=${a ?? "missing"} transcript=${b ?? "missing"} diff=n/a`);
    bad = true;
    continue;
  }
  const diff = b === 0 ? (a === 0 ? 0 : 100) : (Math.abs(a - b) / b) * 100;
  max = Math.max(max, diff);
  console.log(`agent ${id} mod=${a} transcript=${b} diff=${diff.toFixed(2)}%`);
}
const ok = !bad && max <= 2;
console.log(`${ok ? "PASS" : "FAIL"} max-diff=${max.toFixed(2)}% (limit 2%)`);
process.exit(ok ? 0 : 1);
