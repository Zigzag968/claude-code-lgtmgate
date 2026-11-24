// The README's "one run" visual: the lanes of a lgtmgate run, with a token that walks the path from issue to merge.
// Usage: node scripts/gen-readme-run.mjs .github/assets/run-workflow.svg
//        node scripts/gen-readme-run.mjs .github/assets/run-workflow-dark.svg '{"theme":"dark"}'   (GitHub's dark theme)
//        node scripts/gen-readme-run.mjs <dir>/frame.svg '{"at":21}'   (one frozen frame, second 21 of the loop)
// Node stdlib only. Output: one SVG, CSS keyframes, no JS, no web font, no external resource.
// After regenerating the SVGs, refresh .github/assets/run-workflow-static.png (the still under prefers-reduced-motion,
// one light PNG for both themes): the light frame frozen at second STILL ('{"at":21}'), rasterised at 2x.
//
// What the scene says (durations are illustrative):
// - five lanes: You, Lead, the agents (one worktree), the optional steps, the ways a run stops
// - a token walks the main path: the issue, the worktree, Theo, Sam, Nick, Morgan; each node lights up while the token is on it
//   and keeps a green outline once it is done
// - Morgan asks for changes once: the token turns red, goes back to Nick, then to Morgan, who passes it
// - after the LGTM the token waits at the Lead; the merge happens only after the user's go-ahead lights up
import { writeFileSync } from 'node:fs';

const OUT_PATH = process.argv[2];
const OPTIONS = JSON.parse(process.argv[3] || '{}');
const THEME = OPTIONS.theme === 'dark' ? 'dark' : 'light';

const WIDTH = 960, HEIGHT = 580;
const FADE_AT = 24.0, FADE_LEN = 1.2, LOOP = 26.4;
const STILL = 21;
const NOW = OPTIONS.at ?? null;   // null: the animation plays; a number freezes the frame at that second

const COLOR = {
  light: { page: '#F7F6F3', lane: '#FFFFFF', tile: '#FFFFFF', line: '#DDDBE6', ink: '#1E1B3A', mute: '#5B6472', acc: '#5B3FE0',
    ok: '#1A7F4B', bad: '#C62F3C', dash: '#8A90A0' },
  dark: { page: '#0F1319', lane: '#161B22', tile: '#1B2230', line: '#30363D', ink: '#E6EDF3', mute: '#9DA7B3', acc: '#A99BFF',
    ok: '#56D364', bad: '#FF7B72', dash: '#6B7585' },
}[THEME];

// ---------------------------------------------------------------- layout
const LANE_H = 96, LANE_X = 20, LANE_W = 920;
const LANES = [
  { id: 'you', label: 'YOU', top: 20 }, { id: 'lead', label: 'LEAD', top: 126 },
  { id: 'agents', label: 'AGENTS, ONE WORKTREE', top: 232 },
  { id: 'optional', label: 'OPTIONAL', top: 338, dashed: true }, { id: 'stops', label: 'RUN STOPS', top: 444, dashed: true },
];
const cy = (lane) => LANES.find((l) => l.id === lane).top + 52;
const NW = 110, NH = 40;
const NODES = {
  issue: { x: 150, lane: 'you', label: 'Issue + brief', sub: '/lgtmgate:deliver' },
  goahead: { x: 830, lane: 'you', label: 'Your go-ahead', sub: 'explicit order' },
  worktree: { x: 285, lane: 'lead', label: 'Worktree', sub: 'one per run' },
  merge: { x: 830, lane: 'lead', label: 'Lead merge', sub: 'lead-merge.sh' },
  theo: { x: 285, lane: 'agents', label: 'Theo', sub: 'diagnose' },
  sam: { x: 555, lane: 'agents', label: 'Sam', sub: 'plan' },
  nick: { x: 690, lane: 'agents', label: 'Nick', sub: 'dev + PR' },
  morgan: { x: 830, lane: 'agents', label: 'Morgan', sub: 'review' },
  mia: { x: 420, lane: 'optional', label: 'Mia', sub: 'PM framing', dashed: true },
  audit: { x: 600, lane: 'optional', label: 'Plan audit', sub: 'soundness', dashed: true, w: 100 },
  stop_theo: { x: 285, lane: 'stops', w: 130, label: 'Diagnosis stop', sub: 'refuted / design step', dashed: true },
  stop_dev: { x: 690, lane: 'stops', w: 130, label: 'Dev stop', sub: 'dev-died / stuck', dashed: true },
  stop_review: { x: 830, lane: 'stops', w: 130, label: 'Review stop', sub: 'escalate / human-gate', dashed: true },
};
const Y = (id) => cy(NODES[id].lane);

// static edges: [id, path points, dashed, label?]
const EDGES = [
  ['e_issue', [[150, 92], [150, 178], [230, 178]]],
  ['e_wt', [[285, 198], [285, 264]]],
  ['e_theo_sam', [[340, 284], [500, 284]]],
  ['e_sam_nick', [[610, 284], [635, 284]]],
  ['e_nick_morgan', [[745, 284], [775, 284]]],
  ['e_ret', [[800, 304], [800, 318], [710, 318], [710, 304]]],
  ['e_merge', [[830, 264], [830, 198]]],
  ['e_go', [[830, 92], [830, 158]]],
  ['d_mia', [[310, 304], [310, 390], [365, 390]], true],
  ['d_mia_sam', [[475, 390], [520, 390], [520, 304]], true],
  ['d_audit', [[565, 304], [565, 370]], true],
  ['d_audit_back', [[600, 370], [600, 304]], true],
  ['d_stop_theo', [[270, 304], [270, 476]], true],
  ['d_stop_dev', [[680, 304], [680, 476]], true],
  ['d_stop_review', [[860, 304], [860, 476]], true],
];
const PILLS = [
  { x: 420, y: 284, t: 'reproduced' }, { x: 755, y: 318, t: 'REQUIRED_CHANGES', color: 'bad' },
  { x: 848, y: 230, t: 'LGTM' }, { x: 632, y: 337, t: 'not sound' }, { x: 860, y: 420, t: 'no progress' },
];

// ---------------------------------------------------------------- timeline (seconds of the loop)
// dwell: [from, to] the token is on the node; done: from `to` on, the node keeps its green outline
const DWELL = {
  issue: [[0.3, 1.1]], worktree: [[2.0, 2.8]], theo: [[3.8, 5.0]], sam: [[6.6, 7.8]],
  nick: [[8.8, 10.0], [14.0, 15.0]], morgan: [[11.0, 12.0], [16.0, 17.2]],
  merge: [[18.2, 20.6]], goahead: [[19.2, 20.2]],
};
// the token's moves: [t0, t1, points, color]
const MOVES = [
  [1.1, 2.0, [[150, 72], [150, 178], [285, 178]]],
  [2.8, 3.8, [[285, 178], [285, 284]]],
  [5.0, 6.6, [[285, 284], [555, 284]]],
  [7.8, 8.8, [[555, 284], [690, 284]]],
  [10.0, 11.0, [[690, 284], [830, 284]]],
  [12.0, 14.0, [[830, 284], [800, 284], [800, 318], [710, 318], [710, 284], [690, 284]], 'bad'],
  [15.0, 16.0, [[690, 284], [830, 284]]],
  [17.2, 18.2, [[830, 284], [830, 178]]],
];
const EDGE_ON = { e_issue: 1.1, e_wt: 2.8, e_theo_sam: 5.0, e_sam_nick: 7.8, e_nick_morgan: 10.0, e_ret: 12.0, e_merge: 17.2, e_go: 19.2 };
const TOKEN_FIRST = 0.3, TOKEN_LAST = 20.6;

// ---------------------------------------------------------------- keyframes
const pct = (t) => +((t / LOOP) * 100).toFixed(3);
const kfs = [];
let kn = 0;
// track: list of [t, value]; the value holds until the next stop unless `ramp` is set (then it interpolates)
function track(prop, stops) {
  const name = `k${kn++}`;
  if (stops[stops.length - 1][0] < LOOP) stops = [...stops, [LOOP, stops[stops.length - 1][1]]];   // hold the last value to the end (an omitted 100% would interpolate back to the attribute)
  const body = stops.map(([t, v]) => `${pct(t)}%{${prop}:${v}}`).join('');
  kfs.push(`@keyframes ${name}{${body}}`);
  return name;
}
const EPS = 0.05;
function stepOpacity(intervals, tail = null) {
  // visible (1) during each interval, 0 elsewhere; `tail`: stays 1 from that time to the end of the scene
  const s = [[0, 0]];
  for (const [a, b] of intervals) { s.push([a - EPS, 0], [a, 1], [b, 1], [b + EPS, 0]); }
  if (tail != null) { s.push([tail - EPS, 0], [tail, 1]); }
  return s;
}
const classes = [];
function animated(prop, stops) { const n = track(prop, stops); classes.push(`.${n}{animation-name:${n}}`); return n; }

// ---------------------------------------------------------------- drawing
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const pathOf = (pts) => 'M' + pts.map(([x, y]) => `${x} ${y}`).join(' L');
function nodeRect(id, extra) {
  const n = NODES[id], w = n.w ?? NW;
  return `<rect x="${n.x - w / 2}" y="${Y(id) - NH / 2}" width="${w}" height="${NH}" rx="9" ${extra}/>`;
}
function nodeText(id) {
  const n = NODES[id];
  return `<text x="${n.x}" y="${Y(id) - 2}" text-anchor="middle" class="sans" font-size="13.5" font-weight="700" fill="${COLOR.ink}">${esc(n.label)}</text>` +
    `<text x="${n.x}" y="${Y(id) + 12}" text-anchor="middle" class="mono" font-size="9.5" fill="${COLOR.mute}">${esc(n.sub)}</text>`;
}
function pill(p) {
  const w = p.t.length * 6.4 + 14, c = p.color ? COLOR[p.color] : COLOR.mute;
  return `<rect x="${p.x - w / 2}" y="${p.y - 9}" width="${w}" height="18" rx="9" fill="${COLOR.lane}" stroke="${COLOR.line}"/>` +
    `<text x="${p.x}" y="${p.y + 3.5}" text-anchor="middle" class="mono" font-size="9.5" fill="${c}">${esc(p.t)}</text>`;
}

const out = [];
out.push(`<rect width="${WIDTH}" height="${HEIGHT}" fill="${COLOR.page}"/>`);
for (const l of LANES) {
  out.push(`<rect x="${LANE_X}" y="${l.top}" width="${LANE_W}" height="${LANE_H}" rx="12" fill="${COLOR.lane}" stroke="${l.dashed ? COLOR.dash : COLOR.line}"${l.dashed ? ' stroke-dasharray="5 4"' : ''}/>`);
  out.push(`<text x="${LANE_X + 16}" y="${l.top + 20}" class="mono" font-size="10.5" letter-spacing="1.2" fill="${COLOR.mute}">${esc(l.label)}</text>`);
}
for (const [, pts, dashed] of EDGES) {
  out.push(`<path d="${pathOf(pts)}" fill="none" stroke="${dashed ? COLOR.dash : COLOR.mute}" stroke-width="1.6"${dashed ? ' stroke-dasharray="5 4"' : ''}/>`);
  {
    const [[x0, y0], [x1, y1]] = pts.slice(-2), a = Math.atan2(y1 - y0, x1 - x0), d = 7;
    const p = (ang, r) => `${(x1 - Math.cos(ang) * r).toFixed(1)},${(y1 - Math.sin(ang) * r).toFixed(1)}`;
    out.push(`<path d="M${x1},${y1} L${p(a - 0.45, d)} L${p(a + 0.45, d)} Z" fill="${dashed ? COLOR.dash : COLOR.mute}"/>`);
  }
}
for (const id of Object.keys(NODES)) {
  const n = NODES[id];
  out.push(nodeRect(id, `fill="${COLOR.tile}" stroke="${n.dashed ? COLOR.dash : COLOR.line}" stroke-width="1.5"${n.dashed ? ' stroke-dasharray="5 4"' : ''}`));
  out.push(nodeText(id));
}

// dynamic layer (everything below fades out together at the end of the loop)
const dyn = [], tok = [];
for (const [id, pts, dashed] of EDGES) {
  if (dashed || !(id in EDGE_ON)) continue;
  const color = id === 'e_ret' ? COLOR.bad : COLOR.acc;
  const k = animated('opacity', stepOpacity([], EDGE_ON[id]));
  dyn.push(`<path class="a ${k}" d="${pathOf(pts)}" fill="none" stroke="${color}" stroke-width="2.6" opacity="0"/>`);
}
for (const id of Object.keys(DWELL)) {
  const spans = DWELL[id], lastEnd = spans[spans.length - 1][1];
  const ka = animated('opacity', stepOpacity(spans));
  dyn.push(nodeRect(id, `class="a ${ka}" fill="${COLOR.acc}" fill-opacity="0.14" stroke="${COLOR.acc}" stroke-width="2.6" opacity="0"`));
  {
    const kd = animated('opacity', stepOpacity([], lastEnd));
    dyn.push(nodeRect(id, `class="a ${kd}" fill="none" stroke="${COLOR.ok}" stroke-width="2.4" opacity="0"`));
  }
}
// the token
{
  const lenOf = (pts) => pts.slice(1).reduce((s, [x, y], i) => s + Math.hypot(x - pts[i][0], y - pts[i][1]), 0);
  const pos = [], fill = [];
  const P = (x, y) => `translate(${x}px,${y}px)`;
  pos.push([0, P(150, 72)]);
  let lastColor = 'acc';
  fill.push([0, COLOR.acc]);
  for (const [t0, t1, pts, col = 'acc'] of MOVES) {
    pos.push([t0, P(...pts[0])]);
    const total = lenOf(pts);
    let run = 0;
    for (let i = 1; i < pts.length; i++) { run += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]); pos.push([t0 + (t1 - t0) * (run / total), P(...pts[i])]); }
    if (col !== lastColor) { fill.push([t0 - EPS, COLOR[lastColor]], [t0, COLOR[col]]); lastColor = col; }
    if (col === 'bad') { fill.push([t1, COLOR.bad], [t1 + EPS, COLOR.acc]); lastColor = 'acc'; }
  }
  const kp = animated('transform', pos);
  const kf = animated('fill', fill);
  const ko = animated('opacity', stepOpacity([[TOKEN_FIRST, TOKEN_LAST]]));
  tok.push(`<g class="a ${ko}" opacity="0"><g class="a ${kp}" style="transform:${P(150, 72)}"><circle r="8" class="a ${kf}" fill="${COLOR.acc}" stroke="${COLOR.lane}" stroke-width="2.5"/></g></g>`);
}
const fadeName = track('opacity', [[0, 1], [FADE_AT, 1], [FADE_AT + FADE_LEN, 0], [LOOP - 0.3, 0], [LOOP, 1]]);
classes.push(`.fade{animation-name:${fadeName}}`);
out.push(`<g class="a fade">${dyn.join('')}</g>`);
for (const p of PILLS) out.push(pill(p));
out.push(`<g class="a fade">${tok.join('')}</g>`);   // the token rides above the labels   // above the highlights, so a lit edge never strikes a label through
out.push(`<text x="${LANE_X}" y="${HEIGHT - 12}" class="mono" font-size="10.5" fill="${COLOR.mute}">Dashed: optional steps and the ways a run stops. Times shortened for the animation.</text>`);

const frozen = NOW != null ? `animation-delay:-${NOW}s;animation-play-state:paused;` : '';
const css = `.a{animation-duration:${LOOP}s;animation-iteration-count:infinite;animation-fill-mode:both;animation-timing-function:linear;${frozen}}` +
  `.sans{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif}` +
  `.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}` +
  classes.join('') + kfs.join('');
const ARIA = 'One lgtmgate run. You launch /lgtmgate:deliver with an issue and a brief; the Lead creates one worktree for the run. Theo diagnoses, Sam plans, Nick writes the code and opens the pull request, Morgan reviews it. Here Morgan asks for changes once, the work goes back to Nick and comes back to Morgan, who passes it. Mia (product framing) and a plan audit are optional. A refuted diagnosis, a dead dev run or a review that stops making progress ends the run. After the LGTM, the Lead merges only once you give your go-ahead.';
const svg = `<?xml version="1.0" encoding="UTF-8"?>\n<!-- Generated by scripts/gen-readme-run.mjs (${THEME} theme). CSS keyframes only, no JS, no web font. -->\n` +
  `<svg viewBox="0 0 ${WIDTH} ${HEIGHT}" width="${WIDTH}" height="${HEIGHT}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${esc(ARIA)}">\n<style>${css}</style>\n${out.join('\n')}\n</svg>\n`;
if (!OUT_PATH) throw new Error('usage: node scripts/gen-readme-run.mjs <out.svg> [json options]');
writeFileSync(OUT_PATH, svg);
console.log(`wrote ${OUT_PATH} (${svg.length} bytes, loop ${LOOP}s, still frame ${STILL}s)`);
