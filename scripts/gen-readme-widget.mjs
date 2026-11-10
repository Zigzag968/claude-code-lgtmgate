// The README's "what a run looks like" visual: a stylised desktop conversation next to the workflow progress view.
// Usage: node scripts/gen-readme-widget.mjs .github/assets/workflow-widget.svg
//        node scripts/gen-readme-widget.mjs .github/assets/workflow-widget-dark.svg '{"theme":"dark"}'   (GitHub's dark theme)
//        node scripts/gen-readme-widget.mjs <dir>/frame.svg '{"at":20}'      (one frozen frame, second 20 of the loop)
//        node scripts/gen-readme-widget.mjs <dir>/review.html                (a page to review it in a browser)
// Node stdlib only. Output: one SVG, CSS keyframes, no JS, no web font.
// After regenerating the SVGs, refresh .github/assets/workflow-widget-static.png (the still under
// prefers-reduced-motion): the light frame frozen at second STILL ('{"at":20}'), rasterised at 2x (1920x1080).
//
// What the scene says (one run of /lgtmgate:deliver, as a time-lapse):
// - the user sends the command, then the workflow card appears in the conversation and the run in the task panel
// - the panel lists the phases as they start (PHASE_TITLES in workflows/deliver-pipeline.js) and, under each, its
//   agents by label. Probe and preflight agents are left out and the Setup row stays folded
// - the first review asks for changes, so a "Review 2" phase opens with the fix and the second review
// - the run ends on a ready pull request, and the conversation says the merge waits for the user's go-ahead
// The strip under the window is a caption, not part of the interface it mocks. Durations are illustrative.
import { writeFileSync } from 'node:fs';

const OUT_PATH = process.argv[2];
const OPTIONS = JSON.parse(process.argv[3] || '{}');
const THEME = OPTIONS.theme === 'dark' ? 'dark' : 'light';   // '{"theme":"dark"}' writes the variant for GitHub's dark theme

// ---------------------------------------------------------------- canvas / clock
const WIDTH = 960, HEIGHT = 540;
const LOOP = 24;            // seconds
const STILL = 20;           // the frame a renderer without animation shows (also the static PNG)
const HOLD = LOOP - 0.2;    // dynamic elements cut here, once the scene has faded out
const NOW = OPTIONS.at ?? STILL;   // the second the plain attributes describe: STILL, or the frozen frame asked for

// ---------------------------------------------------------------- palette (light: the header's card, ink, violet, green, red)
const COLOR = {
  light: {
    page: '#F7F6F3', win: '#FFFFFF', bar: '#EEEDF3', panel: '#FAF9F7', tile: '#FFFFFF', bubble: '#ECE9F1', line: '#DDDBE6',
    ink: '#1E1B3A', soft: '#55506F', mute: '#5B6472', idle: '#C5C8D2', acc: '#5B3FE0', ok: '#1F883D', ko: '#CF222E',
  },
  dark: {
    page: '#0F1319', win: '#161B22', bar: '#1C2330', panel: '#12171E', tile: '#1B2230', bubble: '#2A3345', line: '#30363D',
    ink: '#E6EDF3', soft: '#C9D1D9', mute: '#9DA7B3', idle: '#566079', acc: '#A99BFF', ok: '#3FB950', ko: '#F85149',
  },
}[THEME];

// ---------------------------------------------------------------- the run, as a time-lapse
// One entry per agent, in run order. `at`: second of the loop it starts (it ends when the next one starts). `clock`: the
// run's elapsed time while it runs. `took`: its duration once done. Phase titles and labels are the engine's own
// (PHASE_TITLES and the `label:` of each agent call in workflows/deliver-pipeline.js); the Setup row stands for its probes.
const SETUP_AGENTS = 5;
const AGENTS = [
  { at: 3, phase: 'Setup', clock: '12s' },
  { at: 3.9, phase: 'Diagnose', label: 'diagnose-issue-142', took: '2min 41s', clock: '34s' },
  { at: 5.6, phase: 'Plan', label: 'scout-issue-142-1', took: '6min 28s', clock: '3min 15s' },
  { at: 7.4, phase: 'Plan', label: 'plan-check-142-1', took: '29s', clock: '9min 43s' },
  { at: 8.4, phase: 'Dev', label: 'nick-issue-142', took: '9min 16s', clock: '10min 12s' },
  { at: 10.6, phase: 'Review', label: 'morgan-pr-142-143-r0', took: '4min 43s', clock: '19min 28s' },
  { at: 13.4, phase: 'Review 2', label: 'nick-pr-142-143', took: '4min 45s', clock: '24min 11s' },
  { at: 15.4, phase: 'Review 2', label: 'morgan-pr-142-143-r1', took: '3min 31s', clock: '28min 56s' },
];
const MOMENT = { ask: 0.7, reply: 1.7, card: 2.3, start: AGENTS[0].at, done: 17.2, verdict: 17.8, fade: 23 };
const FINAL_CLOCK = '32min 27s';
const TOTAL_AGENTS = SETUP_AGENTS + AGENTS.length - 1;
const span = index => [AGENTS[index].at, AGENTS[index + 1]?.at ?? MOMENT.done];

// The caption under the window: the stage in a tag, then one sentence the README's own text supports.
const CAPTIONS = [
  { from: MOMENT.ask, tag: 'YOU', tone: 'acc', line: 'One command hands GitHub issue #142 to the agents.' },
  { from: AGENTS[1].at, tag: 'DIAGNOSE', tone: 'acc', line: 'An agent checks the issue is real before anyone writes a plan.' },
  { from: AGENTS[2].at, tag: 'PLAN', tone: 'acc', line: 'The plan is posted on the issue with its acceptance checklist.' },
  { from: AGENTS[4].at, tag: 'DEV', tone: 'acc', line: 'The code is written and a draft pull request is opened.' },
  { from: AGENTS[5].at, tag: 'REVIEW', tone: 'acc', line: 'A different agent checks each checklist item against evidence.' },
  { from: AGENTS[6].at, tag: 'REQUIRED_CHANGES', tone: 'ko', line: 'The dev agent fixes, then the review runs again.' },
  { from: MOMENT.done, tag: 'LGTM', tone: 'ok', line: 'The pull request is ready. The merge waits for your go-ahead.' },
];

// ---------------------------------------------------------------- keyframes
const keyframes = new Map();   // body -> name: elements on the same schedule share one rule
const percent = second => `${+(second / LOOP * 100).toFixed(2)}%`;
const animated = body => keyframes.get(body) ?? keyframes.set(body, `k${keyframes.size}`).get(body);
// Each animated group also carries, as plain attributes, what it shows at second NOW: a renderer that plays no
// animation (reduced motion, a frozen frame) draws from those alone.
const ramp = (second, from, to) => Math.min(1, Math.max(0, (second - from) / (to - from)));
const opacityNow = value => `opacity="${+value.toFixed(2)}"`;
const pulseNow = OPTIONS.at === undefined ? '' : ` ${opacityNow(0.675 + 0.325 * Math.cos(2 * Math.PI * NOW / 1.2))}`;
// A group visible during each [from, to) window; `fade` seconds to come in and the same to leave (0.02 = a cut).
function during(windows, inner, fade = 0.02) {
  const stops = windows.map(([from, to]) => `${percent(from)}{opacity:0}${percent(from + fade)}{opacity:1}${percent(to - fade)}{opacity:1}${percent(to)}{opacity:0}`);
  const name = animated(`0%{opacity:0}${stops.join('')}100%{opacity:0}`);
  const shown = Math.max(0, ...windows.map(([from, to]) => Math.min(ramp(NOW, from, from + fade), 1 - ramp(NOW, to - fade, to))));
  return `<g class="a ${name}" ${opacityNow(shown)}>${inner}</g>`;
}
// Visible from `from` to the end of the loop, coming in from 6 px below (what the conversation adds).
function rising(from, inner) {
  const low = 'opacity:0;transform:translateY(6px)', up = 'opacity:1;transform:translateY(0)';
  const name = animated(`0%{${low}}${percent(from)}{${low};animation-timing-function:ease-out}${percent(from + 0.35)}{${up}}${percent(HOLD)}{${up}}${percent(HOLD + 0.02)}{${low}}100%{${low}}`);
  const risen = NOW < HOLD ? 1 - (1 - ramp(NOW, from, from + 0.35)) ** 2 : 0;
  const lift = risen > 0 && risen < 1 ? ` transform="translate(0 ${+(6 * (1 - risen)).toFixed(1)})"` : '';
  return `<g class="a ${name}" ${opacityNow(risen)}${lift}>${inner}</g>`;
}
// Everything the run adds fades out together, then the loop restarts on the empty conversation.
function scene(inner) {
  const name = animated(`0%{opacity:1}${percent(MOMENT.fade)}{opacity:1}${percent(MOMENT.fade + 0.5)}{opacity:0}99.9%{opacity:0}100%{opacity:1}`);
  return `<g class="a ${name}" ${opacityNow(1 - ramp(NOW, MOMENT.fade, MOMENT.fade + 0.5))}>${inner}</g>`;
}

// ---------------------------------------------------------------- primitives
const escapeXml = raw => raw.replaceAll('&', '&amp;').replaceAll('<', '&lt;');
const words = (x, y, style, raw) => `<text x="${x}" y="${y}" class="${style}">${escapeXml(raw)}</text>`;
const wordsEnd = (x, y, style, raw) => `<text x="${x}" y="${y}" class="${style}" text-anchor="end">${escapeXml(raw)}</text>`;
const box = (x, y, width, height, radius, style) => `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${radius}" class="${style}"/>`;
const stroke = (x, y, path, style) => `<path transform="translate(${x} ${y})" d="${path}" class="sk ${style}"/>`;

// ---------------------------------------------------------------- the window: title bar, conversation column, task panel
function chrome() {
  const dots = [38, 54, 70].map(x => `<circle cx="${x}" cy="28" r="4.5" class="idle"/>`).join('');
  return `<clipPath id="win"><rect x="20" y="14" width="920" height="472" rx="12"/></clipPath>
<g clip-path="url(#win)">${box(20, 14, 920, 472, 0, 'win')}${box(20, 14, 920, 28, 0, 'bar')}${box(572, 42, 368, 444, 0, 'panel')}<path d="M20 42.5h920M572.5 42v444" class="line-s"/></g>
${box(20.5, 14.5, 919, 471, 12, 'line-s no')}${dots}
${box(40.5, 424.5, 511, 46, 14, 'win line-s')}${words(58, 453.5, 'z17 mute', '+')}${words(84, 452, 'z13 mute', 'Type / for commands')}
${words(592, 68, 'z13 b ink', 'Background tasks')}`;
}

// The card the conversation shows for the workflow: its title, agent count and elapsed time, one square per agent.
function workflowCard() {
  const left = 56;
  const starting = words(left, 188, 'z13 b ink', 'Starting the workflow') + box(left + 0.5, 203.5, 8, 8, 2, 'line-s no');
  const counts = AGENTS.map((agent, index) => during([span(index)], words(left, 200, 'z11 mute', `Workflow · ${SETUP_AGENTS + index} agents · ${agent.clock}`)));
  const squares = Array.from({ length: TOTAL_AGENTS }, (unused, square) => {
    const [from, to] = span(Math.max(0, square - SETUP_AGENTS + 1));
    const x = left + square * 12, early = square < SETUP_AGENTS - 1;   // the Setup probes but the last are done when the row shows
    return (early ? '' : during([[from, to]], `<g class="p"${pulseNow}>${box(x, 211, 8, 8, 2, 'acc')}</g>`)) + during([[early ? from : to, HOLD]], box(x, 211, 8, 8, 2, 'idle'));
  });
  const live = words(left, 181, 'z13 b ink', '#142 - Login page shows a stale error aft…') + stroke(391, 171, 'M0 0l5 5-5 5', 'mute-s') + counts.join('')
    + during([[MOMENT.done, HOLD]], words(left, 200, 'z11 mute', `Workflow · ${TOTAL_AGENTS} agents · ${FINAL_CLOCK}`)) + squares.join('');
  return box(40.5, 156.5, 371, 76, 10, 'tile line-s') + during([[MOMENT.card, MOMENT.start]], starting) + during([[MOMENT.start, HOLD]], live);
}

function conversation() {
  const ask = box(196, 58, 356, 54, 14, 'bubble') + words(212, 81, 'm z12 ink', '/lgtmgate:deliver 142 "Login page shows a')
    + words(212, 99, 'm z12 ink', 'stale error after a successful retry"');
  const reply = words(40, 140, 'z13 ink', 'Worktree created for issue #142. Launching the workflow.');
  const verdict = words(40, 264, 'z13 ink', 'PR #143 is ready: LGTM, acceptance checklist checked.')
    + words(40, 285, 'z13 b ink', 'Waiting for your go-ahead to merge.');
  return [rising(MOMENT.ask, ask), rising(MOMENT.reply, reply), rising(MOMENT.card, workflowCard()), rising(MOMENT.verdict, verdict)].join('\n');
}

// ---------------------------------------------------------------- the task panel: one tile for the run, a row per phase and agent
const ROW = { top: 172, phase: 24, agent: 20 };

function agentRow(agent, index, y) {
  const [from, to] = span(index);
  const live = `<circle cx="623" cy="${y + 10}" r="3.5" class="acc p"${pulseNow}/>${wordsEnd(912, y + 14, 'z11 acc', 'Running')}`;
  const done = stroke(619, y + 10, 'M0 0l3 3 5.5-6.5', 'ok-s') + wordsEnd(912, y + 14, 'z11 mute', agent.took);
  return during([[from, HOLD]], words(634, y + 14, 'm z11 soft', agent.label) + during([[from, to]], live) + during([[to, HOLD]], done), 0.3);
}

// A phase row (name, done/started counter) and its agent rows; it appears when its first agent starts.
function phaseBlock(phase, y) {
  const members = AGENTS.map((agent, index) => ({ agent, index })).filter(member => member.agent.phase === phase);
  const folded = phase === 'Setup';
  const size = folded ? SETUP_AGENTS : members.length;
  const counters = members.map((member, place) => during([span(member.index)], wordsEnd(912, y + 16, 'z11 mute', folded ? `${size - 1}/${size}` : `${place}/${place + 1}`)));
  const head = stroke(600, folded ? y + 7 : y + 9, folded ? 'M0 0l4 4.5-4 4.5' : 'M0 0l4.5 4 4.5-4', 'mute-s') + words(616, y + 16, 'z12 b ink', phase)
    + counters.join('') + during([[span(members.at(-1).index)[1], HOLD]], wordsEnd(912, y + 16, 'z11 mute', `${size}/${size}`));
  const rows = folded ? [] : members.map((member, place) => agentRow(member.agent, member.index, y + ROW.phase + place * ROW.agent));
  return { svg: during([[members[0].agent.at, HOLD]], head, 0.3) + rows.join(''), height: ROW.phase + rows.length * ROW.agent };
}

function runTile() {
  let y = ROW.top;
  const blocks = [...new Set(AGENTS.map(agent => agent.phase))].map(phase => {
    const block = phaseBlock(phase, y);
    y += block.height;
    return block.svg;
  });
  const clocks = AGENTS.map((agent, index) => during([span(index)], wordsEnd(888, 125, 'z11 mute', agent.clock)));
  const states = AGENTS.map((agent, index) => during([span(index)], words(600, 160, 'z11 mute', `1 agent running · ${SETUP_AGENTS + index - 1} done`)));
  const stop = box(896, 110, 20, 20, 5, 'bubble') + box(902, 116, 8, 8, 1.5, 'ink');
  const head = words(600, 125, 'z12 b ink', '#142 - Login page shows a…') + clocks.join('') + during([[MOMENT.start, MOMENT.done]], stop)
    + words(600, 143, 'z11 mute', 'Login page shows a stale error after a succes…') + states.join('')
    + during([[MOMENT.done, HOLD]], wordsEnd(912, 125, 'z11 mute', FINAL_CLOCK) + words(600, 160, 'z11 mute', `${TOTAL_AGENTS} agents done`))
    + '<path d="M584 168.5h344" class="line-s"/>';
  const tile = box(584.5, 100.5, 343, y + 8 - 100, 10, 'tile line-s') + head + blocks.join('\n');
  return [during([[MOMENT.start, MOMENT.done]], words(592, 90, 'z11 soft', 'Running 1')), during([[MOMENT.done, HOLD]], words(592, 90, 'z11 soft', 'Done 1')),
    during([[MOMENT.start, HOLD]], tile, 0.3)].join('\n');
}

function captions() {
  return CAPTIONS.map((caption, index) => {
    const tagWidth = caption.tag.length * 7.4;
    const pill = box(20.5, 501.5, tagWidth + 22, 24, 12, `tile ${caption.tone}-s`)
      + `<text x="31.5" y="517.5" class="m z11 b ${caption.tone}" textLength="${tagWidth.toFixed(1)}">${caption.tag}</text>`;
    return during([[caption.from, CAPTIONS[index + 1]?.from ?? HOLD]], pill + words(tagWidth + 54, 518.5, 'z14 ink', caption.line), 0.25);
  }).join('\n');
}

// ---------------------------------------------------------------- style sheet and output
function styleSheet() {
  const fills = Object.entries(COLOR).map(([name, hex]) => `.${name}{fill:${hex}}.${name}-s{stroke:${hex}}`).join('');
  const frames = [...keyframes].map(([body, name]) => `@keyframes ${name}{${body}}.${name}{animation-name:${name}}`).join('\n');
  const frozen = OPTIONS.at === undefined ? '' : '.a,.p{animation:none}\n';   // '{"at":20}': one still frame, drawn from the plain attributes
  return `text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif}
.m{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.b{font-weight:600}.z11{font-size:11.5px}.z12{font-size:12.5px}.z13{font-size:13.5px}.z14{font-size:14px}.z17{font-size:17px}
${fills}
.no,.sk{fill:none}.sk{stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
.a{animation-duration:${LOOP}s;animation-iteration-count:infinite;animation-timing-function:linear;animation-fill-mode:both}
.p{animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
${frames}
${frozen}@media (prefers-reduced-motion:reduce){.a,.p{animation:none}}`;
}

const ARIA = 'A stylised desktop conversation with the workflow progress view next to it. The user sends /lgtmgate:deliver 142 with a one-line brief. '
  + 'A workflow card appears in the conversation and the run appears in a background tasks panel, which lists the phases as they start: '
  + 'Setup, Diagnose, Plan, Dev, Review, each with its agents. The first review asks for changes, so a Review 2 phase opens with the fix and a second review. '
  + 'The run ends on a pull request that is ready, and the conversation says it waits for the go-ahead of the user to merge.';
const body = [chrome(), scene([conversation(), runTile(), captions()].join('\n'))].join('\n');
const svg = `<svg viewBox="0 0 ${WIDTH} ${HEIGHT}" width="${WIDTH}" height="${HEIGHT}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${ARIA}">
<style>
${styleSheet()}
</style>
${box(0, 0, WIDTH, HEIGHT, 20, 'page')}
${body}
</svg>`;
const banner = `<?xml version="1.0" encoding="UTF-8"?>\n<!-- Generated by scripts/gen-readme-widget.mjs (${THEME} theme). CSS keyframes only, no JS, no web font. -->\n`;
const page = `<!doctype html><meta charset="utf-8"><title>workflow widget (${THEME})</title><body style="margin:24px;background:${COLOR.page}">${svg}</body>\n`;
writeFileSync(OUT_PATH, OUT_PATH.endsWith('.svg') ? `${banner}${svg}\n` : page);
console.log('ok', OUT_PATH, 'bytes', svg.length, 'keyframes', keyframes.size);
