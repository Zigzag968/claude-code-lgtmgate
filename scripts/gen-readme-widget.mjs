// The README's "what a run looks like" visual: a stylised desktop session where the Lead runs three issues in parallel.
// Usage: node scripts/gen-readme-widget.mjs .github/assets/workflow-widget.svg
//        node scripts/gen-readme-widget.mjs .github/assets/workflow-widget-dark.svg '{"theme":"dark"}'   (GitHub's dark theme)
//        node scripts/gen-readme-widget.mjs <dir>/frame.svg '{"at":12}'      (one frozen frame, second 12 of the loop)
//        node scripts/gen-readme-widget.mjs <dir>/review.html                (a page to review it in a browser)
// Node stdlib only. Output: one SVG, CSS keyframes, no JS, no web font, no external resource.
// After regenerating the SVGs, refresh .github/assets/workflow-widget-static.png (the still under prefers-reduced-motion,
// one light PNG for both themes): the light frame frozen at second STILL ('{"at":30.3}'), rasterised at 2x (1920x1080).
//
// What the scene says (a time-lapse; durations and agent counts are illustrative):
// - the window, edge to edge: a sidebar of generic sessions, the conversation with the Lead, the background tasks panel
// - the conversation plays like a live one, at reading pace: a message stays still MOTION.read characters per second, from
//   the moment it is fully shown, before the stack moves up. One exception, named in the data (`announced` on a card): the
//   message that announces that card. The card comes MOTION.respond after it; the message rises once with the stack and
//   stays whole in the view for its reading time. The user's follow-ups are typed in the composer, then sent; a
//   turn of the Lead opens on a working mark and rises once for all its lines, which stream in; a tool line shimmers
// - each run gets a workflow card in the conversation and a container in the panel; the newest card stays in view until the
//   next one arrives. A finished run folds to its header and stays until the merge; a stopped one leaves; an empty panel says so
// - the run the conversation follows shows its phases in run order (PHASE_TITLES in workflows/deliver-pipeline.js; the
//   meta block declares no phases, so nothing says what comes next): a finished phase is one line (its counter, its agents'
//   total duration), the running one is open (its squares, its agents by `label:`). Setup is one step and stays folded.
//   The other runs show their header alone, which does not change while they run
// - one simulated clock (SCALE minutes per second of the loop) gives every duration, in whole minutes, from the seconds of the
//   loop alone: an agent's, a phase's (its agents' sum), a run's (its phases' sum); each shows once final, never a running one
// - #142: the review asks for one fix, so a "Review 2" phase holds the fix, its preflight and the second review
// - #203 (the UNBLOCK block): the run stops and leaves the panel, the Lead unblocks it alone and relaunches it
// - the three end ready, the Lead asks before merging, then merges: the three containers leave, the panel says it is empty.
//   A renderer without animation shows the finished session, just before that.
// - a footnote, "Times shortened for the animation.", as the fine print under Apple's ads ("Sequence shortened"): the loop plays minutes in seconds.
//   It sits outside the scene's fade, so it shows all loop long and in the still, under the composer, on the model line's baseline
// One thing moves at a time. A text that changes state is replaced at once, at the second of its event (no slide, no fade); a
// phase event is one rigid movement (the container's back is one rect whose height changes, what is under it glides the same
// distance, the open phase's body slides up under its line) and what comes in waits for what leaves. checkSlots() throws if two
// texts share a slot.
// The panel is scripts/readme-widget-panel.mjs; this file hands it its tokens, its scenario and its drawing primitives.
import { writeFileSync } from 'node:fs';
import { panelOf } from './readme-widget-panel.mjs';

const OUT_PATH = process.argv[2];
const OPTIONS = JSON.parse(process.argv[3] || '{}');
const THEME = OPTIONS.theme === 'dark' ? 'dark' : 'light';   // '{"theme":"dark"}' writes the variant for GitHub's dark theme

// ---------------------------------------------------------------- canvas / clock
const WIDTH = 960, HEIGHT = 540;
const FADE_OUT = 30.7;      // everything the session added fades out from here: after the last message's reading time (checked), the finished session holds
const LOOP = +(FADE_OUT + 0.7).toFixed(1);   // seconds: the fade, then the empty window
const STILL = +(FADE_OUT - 0.4).toFixed(1);  // the frame a renderer without animation shows (also the static PNG): the finished session
const HOLD = LOOP - 0.2;    // dynamic elements cut here, once the scene has faded out
const NOW = OPTIONS.at ?? STILL;   // the second the plain attributes describe: STILL, or the frozen frame asked for

// ---------------------------------------------------------------- tokens
// Palette: the current one per theme (the header's ink and violet accent). Secondary text and done squares all use `mute` (>= 4.5:1).
// `field` is the composer's ground (the window's white in light, a step above the window in dark), `edge` the ink of the hairlines
// drawn at a share of it (EDGE below: the window's rim, the composer's border).
const COLOR = {
  light: { page: '#F7F6F3', win: '#FFFFFF', bar: '#EEEDF3', panel: '#FAF9F7', tile: '#FFFFFF', bubble: '#ECE9F1', line: '#DDDBE6',
    ink: '#1E1B3A', mute: '#5B6472', idle: '#C5C8D2', acc: '#5B3FE0', field: '#FFFFFF', edge: '#1E1B3A' },
  dark: { page: '#0F1319', win: '#161B22', bar: '#1C2330', panel: '#12171E', tile: '#1B2230', bubble: '#2A3345', line: '#30363D',
    ink: '#E6EDF3', mute: '#9DA7B3', idle: '#566079', acc: '#A99BFF', field: '#202838', edge: '#FFFFFF' },
}[THEME];
// `from` blended into `into` at `share`, as one opaque colour (the accent over a card at the pulse's opacity; the selected row).
const mix = (from, into, share) => `#${[1, 3, 5].map(at => Math.round(parseInt(into.slice(at, at + 2), 16) * (1 - share)
  + parseInt(from.slice(at, at + 2), 16) * share).toString(16).padStart(2, '0')).join('').toUpperCase()}`;
// The selected sidebar row (HIG color, "Selected content background color"): the accent over the sidebar, 15 % in light and 26 % in
// dark (the dark ground needs more to show); `selbar`, its placeholder: the ink at half over it (the idle grey no longer reads on it).
COLOR.sel = mix(COLOR.acc, COLOR.bar, THEME === 'dark' ? 0.26 : 0.15);
COLOR.selbar = mix(COLOR.ink, COLOR.sel, 0.5);
const EDGE = { rim: 0.16, field: THEME === 'dark' ? 0.14 : 0.16 };   // the share of `edge` the window's rim and the composer's border take
// The window's lights (HIG windows: the key window uses colour for closing, minimising and zooming): fill and 0.5 px rim, the same
// in both themes, as on macOS.
const LIGHTS = [['#FF5F57', '#E0443E'], ['#FEBC2E', '#DEA123'], ['#28C840', '#1AAB29']];
const STROKE = 1.3;   // the icons' line, in px: an icon's weight follows its text's (ehmo-ios 7.10, SF Symbols)
const LINE = 20;   // one line of the conversation: about 27 lines per height
const SIZE = { f12: 12, f13: 13, f14: 14 };   // the type scale, in px (.f12 .f13 .f14): 14 for the conversation and the titles, 13 elsewhere, 12 the footnote
const EM = { text: 0.53, mono: 0.62 };   // average advance per em, above the system face so a wider fallback still fits
// The system face's own advances (SF, GitHub's face on a Mac), in hundredths of an em, GLYPHS order: what sizes a bubble to
// its text and fits a name to its room. Any other character counts EM.text.
const GLYPHS = ' !"#,-./0123456789:?ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz…·';
const ADVANCE = '2831486330473030634660636462645764643051676672736057757427546657877477647765646374679768666655615661573661592525542587585961613852365854775254548030';
// The window fills the image, its corners rounded (the README adds its own margin); top: the row of lights and titles.
const WINDOW = { x: 0, y: 0, width: WIDTH, height: HEIGHT, radius: 12, top: 40 };
const COLUMN = { side: 173, tasks: 672 };   // the sidebar keeps 18 % of the window width, the panel 30 %
const CONV = { left: 197, right: 648, first: 64, anchor: 444, gap: 12, card: 248, soft: 24 };   // soft: the fade it scrolls under
const COMPOSER = { x: 185, y: 458, width: 475, height: 40, text: 219, base: 483 };
// One card token (a workflow card in the conversation, a run's container in the panel): 12 px inside each side, 10 above
// the title; the baselines of its title and meta line, the top of its squares, its height; `head` a container's header,
// closed by the one rule that opens the run's phases; `gap` between two containers.
const CARD = { pad: 12, title: 21, meta: 39.5, dots: 50, height: 68, head: 53, radius: 10, gap: 12 };
const BUBBLE = { pad: CARD.pad, height: 34, radius: 14 };   // a user's message: the card's padding on each side of its text
// The panel's cards sit 12 px inside it, under the header's rule and above the window's edge (top, view); their text, 12 px
// inside them (left, right). A phase line every `pitch` px from `first` (a baseline 10 px under the rule); an open phase:
// its squares `dots` px under its name's baseline, its agents from `agents` px, one every `row` px, `indent` px right of its
// name (itself `label` px right of the chevron); `foot`: the descent and the padding under the last line.
const PANEL = { top: 53, view: 474, x: 685, width: 262, left: 697, right: 935, first: 73.2, pitch: 28, dots: 8.5, agents: 33.5, row: 20, indent: 12, label: 14, foot: 13 };
const SQUARE = { size: 7, step: 10, radius: 2 };   // the agent squares, in a workflow card and in an open phase
// Motion, in seconds: `rise` every glide of the conversation (eased out), `enter` what comes in (fades, the squares' paint), `exit`
// what leaves, `out` the line the panel says when it is empty (it leaves first, then the rest comes in), `move` a phase event's
// one movement, `lag` the wait before the next line comes in, `fill` a title going mute. `stream`, `type` and `read` are
// rates (px streamed, characters typed, characters read per second), `edge` the soft edge in px, `floor` the pulse's lowest
// opacity (the accent keeps 3:1 on its ground there). `respond`: the wait between a message and the card it announces, 0.1 s,
// the limit under which a result reads as the instant effect of its cause (Nielsen, "Response Times: The 3 Important Limits",
// https://www.nngroup.com/articles/response-times-3-important-limits/: 0.1 s "reacting instantaneously", 1 s the flow of thought).
const MOTION = { rise: 0.35, enter: 0.2, exit: 0.2, out: 0.1, move: 0.3, lag: 0.15, fill: 0.2, cut: 0.02, fade: 0.5, pulse: 1.2, floor: 0.66, shimmer: 2.4, sweep: 0.15, think: 0.4, tool: 0.4, respond: 0.1, stream: 726, edge: 28, type: 60, read: 17 };
const LONGEST = 60;   // characters in one message, at most
// How wide a text runs, rounded up (`code` spans in monospace): the length a cover has to travel to reveal it.
const widthOf = (raw, size) => raw.split('`').reduce((sum, part, index) => sum + part.length * (index % 2 ? (size - 1) * EM.mono : size * EM.text), 0);
// How wide a text runs in the system face itself (GLYPHS, ADVANCE): what a bubble is sized to.
const faceWidth = (raw, size) => [...raw].reduce((sum, char) => sum + (GLYPHS.includes(char) ? +ADVANCE.substr(2 * GLYPHS.indexOf(char), 2) / 100 : EM.text), 0) * size;
// A text cut with an ellipsis until it fits its room in the system face and in a wider fallback.
const fit = (raw, room, size = SIZE.f13) => (Math.max(faceWidth(raw, size), widthOf(raw, size)) <= room ? raw : fit(`${raw.replace(/…$/, '').slice(0, -1).trimEnd()}…`, room, size));
// The one clock: a second of the loop is SCALE minutes of the runs' time (the longest run shown lasts 10 to 15 min, checked below).
// Every duration shown is the difference of two stamps, a second of the loop scaled and rounded to a whole minute, so a phase is
// the sum of its agents and a run the sum of its phases, to the minute. Under a minute it reads "<1 min": no seconds shown.
const SCALE = 2;
const minutes = second => Math.round(second * SCALE);
const lasted = (from, to) => (minutes(to) > minutes(from) ? `${minutes(to) - minutes(from)} min` : '<1 min');

// ---------------------------------------------------------------- the three runs, as a time-lapse
// One entry per agent, in run order: `at` is the second of the loop it starts (it ends when the next one starts, the last
// at the run's `end`); its duration is read off the clock. Setup is one step (its probes are not listed). Labels are the engine's.
// `open`: the run the conversation follows, open in the panel. A run's duration is the sum of its agents' (they run in turn).
// `listed`: the second its container comes into the panel, by default its `launch`: the three first runs come in as one event.
const agent = (phase, label, at, shown) => ({ phase, label, at, shown: shown ?? label });
const setup = at => agent('Setup', 'setup', at);
// The conversation's entries, at the second each appears. A card arrives when its run starts. `think`: a turn of the Lead
// opens on the working mark that long before its first line. `typed`: the second the user starts typing it. `announced`: the
// message just before this card says the run is coming; the card comes MOTION.respond after it (keepAnnouncementInView).
const card = (id, announced = false) => ({ kind: 'card', id, announced });
const lead = (at, text, opensTurn) => ({ at, kind: 'say', text, think: opensTurn ? MOTION.think : 0 });
const tool = (at, text) => ({ at, kind: 'tool', text });
const ask = (typed, at, text) => ({ at, kind: 'ask', text, typed });

// ---------------------------------------------------------------- the #203 story, one block (swap it for another case)
// #203 passes its review, then stops at the end of Review: main changed the same lines (escalate, reason
// mergeable-conflicting) and leaves the panel. The Lead merges main into the PR, keeping both changes, and relaunches it at
// entryStage review, which runs only Setup and Review. A swap that breaks the reading pace, a card's view or the panel's
// height fails loudly (checks below). The stop comes 0.75 s before the Lead's message that says it; the relaunch card comes
// MOTION.respond after its message.
const UNBLOCK = {
  runs: [
    { id: 'r203', launch: 4, listed: 3.4, end: 10.4, stopped: true, title: '#203 - Rate-limit the password reset endpoint',
      agents: [setup(4), agent('Diagnose', 'diagnose-issue-203', 4.3), agent('Plan', 'scout-issue-203-1', 4.9),
        agent('Plan', 'plan-check-203-1', 5.8), agent('Dev', 'nick-issue-203', 6.1),
        agent('Review', 'preflight-203-215-0', 7.5), agent('Review', 'morgan-pr-203-215-r0', 8.2)] },
    { id: 'r203b', launch: 16.2, end: 18, open: true, title: '#203 - Rate-limit the password reset endpoint',
      agents: [setup(16.2), agent('Review', 'preflight-203-215-0', 16.5), agent('Review', 'morgan-pr-203-215-r0', 16.85)] },
  ],
  turns: [lead(11.15, '#203 stopped: its PR conflicts with main.', true), tool(11.7, 'Ran 2 commands ›'),
    lead(12.1, 'Main fixed the same lines. Keeping both.'),
    lead(15.6, 'Merged main, tests pass. Relaunching review.', true), card('r203b', true)],
  summary: '#203 passes its review, then stops: a fix on main changed the same lines. The Lead keeps both changes, merges main into '
    + 'the pull request, re-runs the tests and relaunches the review alone.',
};

const RUNS = [
  { id: 'r142', launch: 3.4, end: 9.9, open: true, title: '#142 - Login page shows a stale error after a successful retry',
    agents: [setup(3.4), agent('Diagnose', 'diagnose-issue-142', 3.7), agent('Plan', 'scout-issue-142-1', 4.4),
      agent('Plan', 'plan-check-142-1', 4.9), agent('Dev', 'nick-issue-142', 5.4),
      agent('Review', 'preflight-142-209-0', 6.4), agent('Review', 'morgan-pr-142-209-r0', 6.9),
      agent('Review 2', 'nick-pr-142-209', 7.4), agent('Review 2', 'preflight-142-209-1', 8.8),
      agent('Review 2', 'morgan-pr-142-209-r1', 9.3)] },
  { id: 'r187', launch: 3.7, listed: 3.4, end: 8.3, title: '#187 - Add CSV export to the reports page',
    agents: [setup(3.7), agent('Diagnose', 'diagnose-issue-187', 4), agent('Plan', 'scout-issue-187-1', 4.6),
      agent('Plan', 'plan-check-187-1', 5.4), agent('Dev', 'nick-issue-187', 5.7),
      agent('Review', 'preflight-187-212-0', 7), agent('Review', 'morgan-pr-187-212-r0', 7.3)] },
  ...UNBLOCK.runs,
];
for (const run of RUNS) {
  run.listed ??= run.launch;
  run.agents.forEach((member, index) => { member.end = run.agents[index + 1]?.at ?? run.end; member.took = lasted(member.at, member.end); });
  run.phases = [...new Set(run.agents.map(member => member.phase))].map(title => {
    const members = run.agents.filter(member => member.phase === title);
    return { name: title, members, start: members[0].at, end: members.at(-1).end, took: lasted(members[0].at, members.at(-1).end) };
  });
  run.final = lasted(run.agents[0].at, run.end);
  run.card = fit(run.title, CONV.card - 2 * CARD.pad - 20);   // room for the chevron and 16 px before it
  run.head = fit(run.title, PANEL.right - PANEL.left - 30);   // room for the stop button and 16 px before it
}
const RUN = Object.fromEntries(RUNS.map(run => [run.id, run]));
// The clock's checks: a run's phases add up to its duration, to the minute, and the longest run shown lasts 10 to 15 min.
const span = (from, to) => minutes(to) - minutes(from);
for (const run of RUNS) if (run.phases.reduce((sum, phase) => sum + span(phase.start, phase.end), 0) !== span(run.agents[0].at, run.end)) throw new Error(`the phases of ${run.id} do not add up to its duration`);
const LONGEST_RUN = Math.max(...RUNS.map(run => span(run.agents[0].at, run.end)));
if (LONGEST_RUN < 10 || LONGEST_RUN > 15) throw new Error(`the longest run lasts ${LONGEST_RUN} min on the clock, not 10 to 15`);
const ROWS = Math.max(...RUNS.flatMap(run => run.phases.map(phase => phase.members.length)));   // an open phase keeps the room of the busiest one

// The conversation in order; the #203 turns come from UNBLOCK.
const MESSAGES = [
  { at: 0.3, kind: 'command', text: '/lgtmgate:deliver 142 "Fix stale login error"' },
  ask(1.2, 2, 'Also run #187 and #203 in parallel.'),
  lead(2.8, 'Three runs launched, each in its own worktree.', true),
  card('r142'), card('r187'), card('r203'),
  lead(7.4, '#142: review wants one fix. Dev agent on it.', true),
  ...UNBLOCK.turns,
  lead(19.09, 'All three PRs are ready.', true),
  lead(19.76, 'Merge all three PRs?'),
  ask(20.65, 21.2, 'Yes, merge them.'),
  lead(22.9, 'Every box is checked. Merging all three PRs.', true),
].map(item => (item.kind === 'card' ? { ...item, at: RUN[item.id].launch, run: RUN[item.id] } : item));
const HEIGHT_OF = { command: BUBBLE.height, ask: BUBBLE.height, tool: LINE, say: LINE, card: CARD.height };

// ---------------------------------------------------------------- windows: [from, to) pairs, in seconds
function merge(windows) {
  const merged = [];
  for (const pair of windows.filter(([from, to]) => to > from).sort((first, second) => first[0] - second[0])) {
    if (merged.length && pair[0] <= merged.at(-1)[1]) merged.at(-1)[1] = Math.max(merged.at(-1)[1], pair[1]);
    else merged.push([...pair]);
  }
  return merged;
}

// ---------------------------------------------------------------- keyframes
const keyframes = new Map();   // body -> name: elements on the same schedule share one rule
const percent = second => `${+(second / LOOP * 100).toFixed(2)}%`;
const animated = body => keyframes.get(body) ?? keyframes.set(body, `k${keyframes.size}`).get(body);
// A slot is a place that shows one text at a time; each text registers the [from, to) seconds it is visible there, checkSlots() compares.
const SLOTS = new Map();
const occupy = (slot, windows) => SLOTS.set(slot, [...(SLOTS.get(slot) ?? []), ...windows]);
// Each animated group also carries, as plain attributes, what it shows at second NOW (for a renderer that plays no animation).
const ramp = (second, from, to) => Math.min(1, Math.max(0, (second - from) / (to - from)));
const easeOut = value => 1 - (1 - value) ** 2;
const opacityNow = value => `opacity="${+value.toFixed(2)}"`;
const glow = second => (1 + MOTION.floor) / 2 + (1 - MOTION.floor) / 2 * Math.cos(2 * Math.PI * second / MOTION.pulse);   // the pulse's opacity at that second
const pulseNow = OPTIONS.at === undefined ? '' : ` ${opacityNow(glow(NOW))}`;
// A group visible during each [from, to) window, in and out at one keyframe (step timing), or faded: `enter` seconds in from
// `from`, `leave` seconds out from `to`, linear. A window from 0 or to the end of the loop wraps; one that ends at HOLD or later
// is cut there (the scene has faded out).
function during(windows, inner, { enter = 0, leave = 0, slot } = {}) {
  const open = merge(windows), linear = ';animation-timing-function:linear';
  if (open.length === 0) return '';
  const softIn = from => enter > 0 && from > 0, softOut = to => leave > 0 && to + leave <= HOLD;
  const stops = open.map(([from, to]) => (from <= 0 ? '' : softIn(from) ? `${percent(from)}{opacity:0${linear}}${percent(from + enter)}{opacity:1}` : `${percent(from)}{opacity:1}`)
    + (to >= LOOP ? '' : softOut(to) ? `${percent(to)}{opacity:1${linear}}${percent(to + leave)}{opacity:0}` : `${percent(to)}{opacity:0}`));
  const name = animated(`0%{opacity:${+(open[0][0] <= 0)}}${stops.join('')}100%{opacity:${+(open.at(-1)[1] >= LOOP)}}`);
  if (slot) occupy(slot, open.map(([from, to]) => [from, softOut(to) ? to + leave : to]));
  const shown = Math.max(0, ...open.map(([from, to]) => Math.min(NOW < from ? 0 : softIn(from) ? ramp(NOW, from, from + enter) : 1,
    NOW < to ? 1 : softOut(to) ? 1 - ramp(NOW, to, to + leave) : 0)));
  return `<g class="a ${name}" ${opacityNow(shown)}>${inner}</g>`;
}
// The reverse: a group shown all loop long except during each [from, to) window (the composer's placeholder).
function except(windows, inner) {
  const name = animated(`0%{opacity:1}${merge(windows).map(([from, to]) => `${percent(from)}{opacity:0}${percent(to)}{opacity:1}`).join('')}100%{opacity:1}`);
  return `<g class="a ${name}" ${opacityNow(windows.some(([from, to]) => NOW >= from && NOW < to) ? 0 : 1)}>${inner}</g>`;
}
// Visible from `from` to the end of the loop, coming in from 6 px below (what the conversation adds).
function rising(from, inner) {
  const low = 'opacity:0;transform:translateY(6px)', up = 'opacity:1;transform:translateY(0)';
  const name = animated(`0%{${low}}${percent(from)}{${low};animation-timing-function:ease-out}${percent(from + MOTION.rise)}{${up}}${percent(HOLD)}{${up}}${percent(HOLD + 0.02)}{${low}}100%{${low}}`);
  const risen = NOW < HOLD ? easeOut(ramp(NOW, from, from + MOTION.rise)) : 0;
  const lift = risen > 0 && risen < 1 ? ` transform="translate(0 ${+(6 * (1 - risen)).toFixed(1)})"` : '';
  return `<g class="a ${name}" ${opacityNow(risen)}${lift}>${inner}</g>`;
}
// The standard easing, cubic-bezier(0.2, 0, 0, 1): its progress `value` of the way along, by bisection on its x curve.
const standard = value => {
  let low = 0, high = 1;
  for (let round = 0; round < 24; round++) { const mid = (low + high) / 2; if (0.6 * mid * (1 - mid) ** 2 + mid ** 3 < value) low = mid; else high = mid; }
  return 3 * low ** 2 - 2 * low ** 3;
};
// How a value gets from one step to the next: seconds, the CSS easing, and the same easing for the plain attributes (second NOW).
const EASE_OUT = { dur: MOTION.rise, css: 'ease-out', at: easeOut }, MOVE = { dur: MOTION.move, css: 'cubic-bezier(0.2,0,0,1)', at: standard };
const EXIT = { ...MOVE, dur: MOTION.exit }, FILL = { ...MOVE, dur: MOTION.fill };
// A value that changes by steps: `changes` = [{ at, y }] (the first is the value from the start), each new y reached in
// `feel.dur` seconds along `feel.css`; `style` writes a value as CSS. Gives the animation's classes and the value at second NOW.
function steps(changes, style, feel) {
  const moves = changes.filter((change, index) => index > 0 && change.y !== changes[index - 1].y);
  let last = changes[0].y, here = last, body = `0%{${style(last)}}`;
  moves.forEach((move, index) => {
    const end = Math.min(move.at + feel.dur, moves[index + 1]?.at ?? HOLD);
    body += `${percent(move.at)}{${style(last)};animation-timing-function:${feel.css}}${percent(end)}{${style(move.y)}}`;
    if (NOW >= move.at && typeof last === 'number') here = last + (move.y - last) * feel.at(ramp(NOW, move.at, end));
    last = move.y;
  });
  return { name: moves.length ? `a ${animated(`${body}100%{${style(last)}}`)}` : '', here: typeof here === 'number' ? +here.toFixed(1) : here };
}
// A group moved vertically (the conversation's scroll, a container gliding to its place).
function track(changes, inner, feel = EASE_OUT) {
  const { name, here } = steps(changes, value => `transform:translateY(${value}px)`, feel);
  return `<g ${name ? `class="${name}" ` : ''}transform="translate(0 ${here})">${inner}</g>`;
}
// What shows through a window of the given size in the same coordinates (a hard clip, no opacity): a nested svg.
const clip = (x, y, width, height, inner) => `<svg x="${x}" y="${y}" width="${width}" height="${height}" viewBox="${x} ${y} ${width} ${height}">${inner}</svg>`;
// A text that changes state is replaced at once: one group per state, `rows` = [{ at, mark }], each shown from its `at` to the next
// one's (a hard cut, no fade, no movement); a row with no `mark` shows nothing. `slot` makes checkSlots() throw if two ever overlap.
const cut = (rows, slot) => rows.map((row, index) => (row.mark ? during([[row.at, rows[index + 1]?.at ?? HOLD]], row.mark, { slot }) : '')).join('');
// A cover that slides `travel` px to the right from `from` to `to`, revealing what it hides, then goes. `jumps`: in that many
// jumps (typing), else smoothly (streaming). The plain attributes put it where it is at second NOW.
function uncover(from, to, travel, inner, jumps = 0) {
  const pose = (x, shown) => `{opacity:${shown};transform:translateX(${+x.toFixed(1)}px)}`;
  const timing = jumps ? `steps(${jumps},end)` : 'linear';
  const name = animated(`0%${pose(0, 1)}${percent(from)}{opacity:1;transform:translateX(0);animation-timing-function:${timing}}${percent(to)}${pose(travel, 1)}${percent(to + MOTION.cut)}${pose(travel, 0)}100%${pose(travel, 0)}`);
  const progress = ramp(NOW, from, to), done = jumps ? Math.floor(progress * jumps) / jumps : progress;
  return `<g class="a ${name}" transform="translate(${+(travel * done).toFixed(1)} 0)" ${opacityNow(NOW >= to ? 0 : 1)}>${inner}</g>`;
}
// Everything the session adds fades out together, then the loop restarts on the empty window.
function scene(inner) {
  const name = animated(`0%{opacity:1}${percent(FADE_OUT)}{opacity:1;animation-timing-function:linear}${percent(FADE_OUT + MOTION.fade)}{opacity:0}99.9%{opacity:0}100%{opacity:1}`);
  return `<g class="a ${name}" ${opacityNow(1 - ramp(NOW, FADE_OUT, FADE_OUT + MOTION.fade))}>${inner}</g>`;
}
// Two texts visible in one slot at once (a swap that overlaps instead of waiting) fails loudly; gives the slots compared.
function checkSlots() {
  for (const [slot, windows] of SLOTS) {
    let until = 0;
    for (const [from, to] of [...windows].sort((first, second) => first[0] - second[0])) {
      if (from < until - 1e-9) throw new Error(`${slot} shows two texts at once at ${from.toFixed(2)}s`);
      until = Math.max(until, to);
    }
  }
  return SLOTS.size;
}

// ---------------------------------------------------------------- primitives
const escapeXml = raw => raw.replaceAll('&', '&amp;').replaceAll('<', '&lt;');
const words = (x, y, style, raw) => `<text x="${x}" y="${y}" class="${style}">${escapeXml(raw)}</text>`;
const wordsEnd = (x, y, style, raw) => `<text x="${x}" y="${y}" class="${style}" text-anchor="end">${escapeXml(raw)}</text>`;
const box = (x, y, width, height, radius, style) => `<rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${radius}" class="${style}"/>`;
const stroke = (x, y, path, style) => `<path transform="translate(${x} ${y})" d="${path}" class="sk ${style}"/>`;
const hairline = path => `<path d="${path}" class="line-s"/>`;
const ring = (cx, cy, radius, style) => `<circle cx="${cx}" cy="${cy}" r="${radius}" class="${style}"/>`;
// Texts on one line, each 12 px after the one before it whatever the face: `parts` = [class, text] pairs.
const inline = (x, y, style, parts, anchor = 'start') => `<text x="${x}" y="${y}" class="${style}" text-anchor="${anchor}">${parts
  .map(([look, raw], index) => `<tspan${index ? ' dx="12"' : ''}${look ? ` class="${look}"` : ''}>${escapeXml(raw)}</tspan>`).join('')}</text>`;
const CHEVRON = { right: 'M0 0l4 4-4 4' };
// A text whose words light up in turn while it is live (a running card title or tool line); a frozen frame lights the word
// the sweep is on at second NOW.
const litNow = index => OPTIONS.at !== undefined && Math.abs((((NOW - index * MOTION.sweep) % MOTION.shimmer) + MOTION.shimmer) % MOTION.shimmer / MOTION.shimmer - 0.08) < 0.04;
const shimmer = (x, y, size, raw) => `<text x="${x}" y="${y}" class="${size} mute">${raw.split(/(?<= )/)
  .map((part, index) => `<tspan class="sh d${index % 8}${litNow(index % 8) ? ' ink' : ''}">${escapeXml(part)}</tspan>`).join('')}</text>`;
// One line of the Lead: `code` spans in monospace.
const said = (x, y, raw) => `<text x="${x}" y="${y}" class="f14 ink">${raw.split('`').map((part, index) => `<tspan${index % 2 ? ' class="m f13"' : ''}>${escapeXml(part)}</tspan>`).join('')}</text>`;
// One square per started agent (of a run in its card, of a phase in the panel), a single element whose paint fades from state
// to state over MOTION.enter: outlined while the agent before it runs (closing the row), accent while it runs (the pulse folded
// into its colour over its `ground`), mute once done. One more square, outlined, closes the row while the last agent runs.
function squares(list, end, x, y, ground) {
  const paint = (shown, filled, colour) => `opacity:${shown};fill-opacity:${filled};fill:${colour};stroke:${colour}`;
  const hidden = paint(0, 0, COLOR.mute), outline = paint(1, 0, COLOR.mute), done = paint(1, 1, COLOR.mute);
  const lit = second => paint(1, 1, mix(COLOR.acc, ground, glow(second)));
  const half = MOTION.pulse / 2, linear = ';animation-timing-function:linear', fade = (from, to) => from + Math.min(MOTION.enter, (to - from) / 2);
  return [...list, undefined].map((member, index) => {
    const before = list[index - 1], from = before?.at ?? member.at, until = member?.end ?? end;
    let body = `0%{${hidden}}${before ? `${percent(before.at)}{${hidden}${linear}}${percent(fade(before.at, before.end))}{${outline}}` : ''}`;
    if (member) {
      const lift = fade(member.at, member.end), crests = [];
      for (let step = Math.ceil((lift + 0.02) / half); step * half < member.end - 0.02; step++) crests.push(`${percent(step * half)}{${lit(step * half)};animation-timing-function:ease-in-out}`);
      body += `${percent(member.at)}{${before ? outline : hidden}${linear}}${percent(lift)}{${lit(lift)};animation-timing-function:ease-in-out}${crests.join('')}`
        + `${percent(member.end)}{${lit(member.end)}${linear}}${percent(member.end + MOTION.enter)}{${done}}`;
    } else body += `${percent(end)}{${outline}${linear}}${percent(end + MOTION.enter)}{${hidden}}`;
    const name = animated(`${body}${percent(HOLD)}{${hidden}}100%{${hidden}}`);
    const state = NOW < from || NOW >= HOLD || (!member && NOW >= until) ? ' opacity="0"' : !member || NOW < member.at ? ' fill-opacity="0"' : NOW < member.end ? 'lit' : '';
    const look = state === 'lit' ? `acc acc-s"${pulseNow}` : `mute mute-s"${state}`;
    return `<rect x="${x + index * SQUARE.step + 0.5}" y="${y + 0.5}" width="${SQUARE.size - 1}" height="${SQUARE.size - 1}" rx="${SQUARE.radius - 0.5}" class="a ${name} ${look}/>`;
  }).join('');
}

// ---------------------------------------------------------------- the window: sidebar, headers, composer
function surfaces() {
  const { x, y, width, height } = WINDOW;
  return box(x, y, width, height, 0, 'win') + box(x, y, COLUMN.side - x, height, 0, 'bar') + box(COLUMN.tasks, y, x + width - COLUMN.tasks, height, 0, 'panel');
}

// One content edge, 12 px inside the window (the lights, the icons, "Recents", the recent rows); the selected row's pill
// spreads 8 px past it on each side.
function sidebar() {
  const edge = WINDOW.x + 12, lights = LIGHTS.map((unused, index) => ring(edge + 4.5 + 16 * index, WINDOW.y + 20, 4.25, `light${index}`)).join('');
  const icons = [
    stroke(edge + 5.75, 60.5, 'M0 -5v10M-5 0h10', 'acc-s'),
    ring(edge + 4.75, 85.5, 4, 'sk acc-s') + stroke(edge + 7.75, 88.5, 'M0 0l3 3', 'acc-s'),
    box(edge + 0.75, 108.5, 8, 9, 1.5, 'sk acc-s') + stroke(edge + 3.75, 106.5, 'M0 0h6.5v8', 'acc-s'),
    ring(edge + 6.25, 138.5, 5.5, 'sk acc-s') + stroke(edge + 6.25, 135.5, 'M0 0v3h2.5', 'acc-s'),
    box(edge + 0.75, 161.5, 11, 8, 2, 'sk acc-s') + stroke(edge + 4.25, 159.5, 'M0 2v-2h4v2', 'acc-s'),
  ];
  const items = ['New session', 'Search', 'Artifacts', 'Scheduled tasks', 'Customize'].map((label, index) => icons[index] + words(edge + 20, 65 + 26 * index, 'f13 ink', label)).join('');
  const recents = words(edge, 203, 'f13 w6 mute', 'Recents') + stroke(edge + Math.ceil(faceWidth('Recents', SIZE.f13)) + 6, 197, 'M0 0l3 3 3-3', 'mute-s')
    + box(edge - 8, 213, COLUMN.side - edge + 4, 20, 6, 'sel') + [104, 86, 118, 72, 96, 110, 64, 90, 80].map((width, index) => box(edge, 220 + 24 * index, width, 6, 3, index ? 'idle' : 'selbar')).join('');
  return lights + items + recents;
}

// The session's title on the conversation's edge, its menu on the other; the panel's title and close button on its cards' text.
function headers() {
  const middle = WINDOW.y + 20, base = middle + 5;
  const title = words(CONV.left, base, 'f14 w6 ink', 'Deliver issues') + stroke(CONV.left + Math.ceil(faceWidth('Deliver issues', SIZE.f14)) + 8, middle - 1.5, 'M0 0l3.5 3.5 3.5-3.5', 'mute-s')
    + [-10, -5, 0].map(dx => ring(CONV.right - 1.2 + dx, middle + 0.5, 1.2, 'mute')).join('');
  const tasks = words(PANEL.left, base, 'f14 w6 ink', 'Background tasks') + hairline(`M${COLUMN.tasks} ${WINDOW.y + WINDOW.top + 0.5}h${WINDOW.x + WINDOW.width - COLUMN.tasks}`)
    + stroke(PANEL.right - 9.5, middle - 4, 'M0 0l8 8M8 0l-8 8', 'mute-s');
  return title + tasks;
}

// The user's follow-ups, typed in the composer one character at a time behind a caret, then sent: the bubble rises in the
// conversation and the placeholder comes back.
function drafts() {
  const asks = MESSAGES.filter(item => item.typed !== undefined);
  const placeholder = except(asks.map(item => [item.typed, item.at]), words(COMPOSER.text, COMPOSER.base, 'f14 mute', 'Type / for commands'));
  return placeholder + asks.map(item => {
    const travel = Math.ceil(widthOf(item.text, SIZE.f14)) + 3, typedBy = item.typed + item.text.length / MOTION.type;
    const cover = box(COMPOSER.text - 1, COMPOSER.y + 9, travel + 4, 23, 0, 'field') + box(COMPOSER.text - 1, COMPOSER.y + 13, 1.5, 15, 0.75, 'ink');
    return during([[item.typed, item.at]], words(COMPOSER.text, COMPOSER.base, 'f14 ink', item.text) + uncover(item.typed, typedBy, travel, cover, item.text.length), { slot: 'composer' });
  }).join('');
}

// The composer, and under it the model, the effort and the mode, then the context ring; on the same baseline at the conversation's
// left edge, the footnote (the palette's secondary ink, 5.98:1 light and 7.09:1 dark on the window, one step under the 13 px scale).
function composer() {
  const { x, y, width, height } = COMPOSER, right = x + width, base = WINDOW.y + WINDOW.height - 16;
  const arc = Array.from({ length: 9 }, (unused, step) => {
    const angle = -Math.PI / 2 + step * Math.PI / 24;
    return `${step ? 'L' : 'M'}${+(right - 10 + 5.5 * Math.cos(angle)).toFixed(2)} ${+(base - 4 + 5.5 * Math.sin(angle)).toFixed(2)}`;
  }).join('');
  return box(x + 0.5, y + 0.5, width - 1, height - 1, 11.5, 'field edge-s border') + stroke(x + 16, y + 20, 'M0 -5v10M-5 0h10', 'mute-s') + `<g clip-path="url(#pad)">${drafts()}</g>`
    + box(right - 20.5, y + 10.5, 6, 10, 3, 'sk mute-s') + stroke(right - 21.5, y + 17, 'M0 0v1.5l4 3.5 4-3.5v-1.5M4 5v3', 'mute-s')
    + inline(right - 22, base, 'f13 ink', [['', 'Sonnet 5.5'], ['mute', 'High'], ['', 'Auto']], 'end') + words(CONV.left, base, 'f12 mute', 'Times shortened for the animation.')
    + ring(right - 10, base - 4, 5.5, 'sk mute-s') + `<path d="${arc}" class="sk acc-s"/>`;
}

// ---------------------------------------------------------------- the conversation
// A workflow card: its title shimmers while the run is live; the meta line counts the agents started, then adds the run's duration,
// each replacing the one before at once. What stays (Workflow) is drawn once; the copies that change lay it out unseen (.no).
function workflowCard(run, top) {
  const x = CONV.left, inner = x + CARD.pad, slot = `card ${run.id}`, meta = parts => inline(inner, top + CARD.meta, 'f13 mute', [['no', 'Workflow'], ...parts]);
  const count = index => `${index + 1} agent${index ? 's' : ''}`;
  const counts = cut(run.agents.map((member, index) => ({ at: member.at, mark: meta([['', count(index)]]) })), `${slot} count`);
  const total = cut([{ at: run.end, mark: meta([['no', `${run.agents.length} agents`], ['', run.final]]) }], `${slot} total`);
  const title = during([[run.launch, run.end]], shimmer(inner, top + CARD.title, 'f13', run.card), { slot: `${slot} title` })
    + during([[run.end, HOLD]], words(inner, top + CARD.title, 'f13 mute', run.card), { slot: `${slot} title` });
  return box(x + 0.5, top + 0.5, CONV.card - 1, CARD.height - 1, CARD.radius, 'win line-s') + title + stroke(x + CONV.card - CARD.pad - 4.75, top + 12, CHEVRON.right, 'mute-s')
    + words(inner, top + CARD.meta, 'f13 mute', 'Workflow') + counts + total + squares(run.agents, run.end, inner, top + CARD.dots, COLOR.win);
}

// What a message shows once it is in. A user's bubble fits its text in the system face, BUBBLE.pad on each side, the text
// centred so a face of another width spreads the difference evenly. A tool line shimmers while its commands run, then settles.
function message(item, top) {
  if (item.kind === 'command' || item.kind === 'ask') {
    const width = Math.ceil(faceWidth(item.text, SIZE.f14)) + 2 * BUBBLE.pad;
    return box(CONV.right - width, top, width, BUBBLE.height, BUBBLE.radius, 'bubble') + `<text x="${CONV.right - width / 2}" y="${top + 22}" class="f14 ink" text-anchor="middle">${escapeXml(item.text)}</text>`;
  }
  if (item.kind === 'tool') {
    const slot = `tool ${item.at}`;
    return during([[item.at, item.at + MOTION.tool]], shimmer(CONV.left, top + 15, 'f14', item.text), { slot })
      + during([[item.at + MOTION.tool, HOLD]], words(CONV.left, top + 15, 'f14 mute', item.text), { slot });
  }
  return workflowCard(item.run, top);
}

// The working mark that opens a turn of the Lead, where its first line will be: an accent spark that pulses.
const thinking = top => `<g class="p"${pulseNow}>${stroke(CONV.left + 6, top + 10, 'M0 -5v10M-5 0h10M-3.5 -3.5l7 7M3.5 -3.5l-7 7', 'acc-s')}</g>`;

// A line of the Lead streams in: a cover in the conversation's colour, with a soft left edge, slides off the text. It is
// fully shown once the cover has travelled; anything else, once it has risen.
const travelOf = text => Math.ceil(widthOf(text, SIZE.f14)) + 8 + MOTION.edge;
const shownAt = item => item.at + (item.kind === 'say' ? travelOf(item.text) / MOTION.stream : MOTION.rise);
function streamed(item) {
  const travel = travelOf(item.text);
  const cover = `<rect x="${CONV.left - 4 - MOTION.edge}" y="${item.top - 1}" width="${travel}" height="${LINE + 2}" fill="url(#fade)"/>`;
  return during([[item.at, HOLD]], said(CONV.left, item.top + 15, item.text) + uncover(item.at, item.at + travel / MOTION.stream, travel, cover));
}

// The newest card stays in view until the next card arrives: checked here, so a longer scenario fails loudly.
function keepCardsInView(placed, offsets) {
  placed.forEach((item, index) => {
    if (item.kind !== 'card') return;
    const next = placed.findIndex((other, later) => later > index && other.kind === 'card');
    for (let shown = index; shown < (next < 0 ? placed.length : next); shown++) {
      if (offsets[shown] + item.top < WINDOW.y + WINDOW.top + CONV.soft || offsets[shown] + item.bottom > CONV.anchor) throw new Error(`the card of ${item.run.id} leaves the view when message ${shown} arrives`);
    }
  });
}

// A message holds at most LONGEST characters and, from the moment it is fully shown, stays still MOTION.read characters per
// second before the stack moves up (the last one, before the scene fades out): checked here, so a retimed scenario fails loudly.
// The one exception is named in the data: the message just before a card flagged `announced` lets that card's rise through
// (keepAnnouncementInView holds it to something else); the next rise is the one it must outlast, so it moves once at most.
function keepMessagesReadable(placed, offsets) {
  placed.forEach((item, index) => {
    const text = item.kind === 'card' ? item.run.card : item.text, announced = placed[index + 1]?.announced ? placed[index + 1] : undefined;
    const push = placed.find((other, later) => later > index && other !== announced && offsets[later] < offsets[later - 1]);
    const still = (push?.open ?? FADE_OUT) - shownAt(item);
    if (text.length > LONGEST || still < text.length / MOTION.read) throw new Error(`"${text}" (${text.length} characters) stays still ${still.toFixed(2)}s once fully shown before the stack moves`);
  });
}

// What the exception asks instead of stillness: its card comes MOTION.respond after the message is fully shown, the card never
// covers the message, and for the message's whole reading time the message stays whole in the conversation, under its soft top
// edge and above its anchor, at each place the stack puts it.
function keepAnnouncementInView(placed, changes) {
  placed.forEach((arrival, index) => {
    if (!arrival.announced) return;
    const item = placed[index - 1], shown = shownAt(item), until = shown + item.text.length / MOTION.read, wait = arrival.at - shown;
    if (Math.abs(wait - MOTION.respond) > 0.005) throw new Error(`the card of ${arrival.run.id} comes ${wait.toFixed(2)}s after its message, not ${MOTION.respond}s`);
    if (arrival.top < item.bottom) throw new Error(`the card of ${arrival.run.id} covers "${item.text}"`);
    const places = [changes.findLast(change => change.at <= shown), ...changes.filter(change => change.at > shown && change.at < until)];
    for (const { y } of places) {
      if (item.top + y < WINDOW.y + WINDOW.top + CONV.soft || item.bottom + y > CONV.anchor) throw new Error(`"${item.text}" leaves the view while it is read (its top ${item.top + y}px, its bottom ${item.bottom + y}px)`);
    }
  });
}

// The messages stack from the top; once they fill the column, the stack rises so the newest sits above the composer. A
// message takes its place when it opens: a turn of the Lead at its working mark, all its lines (text and tool lines) at
// once; anything else when it appears.
function conversation() {
  let bottom = 0;
  const placed = [], lines = new Set(['say', 'tool']);
  for (const item of MESSAGES) {
    const before = placed.at(-1), joins = !item.think && lines.has(item.kind) && lines.has(before?.kind);
    placed.push({ ...item, open: joins ? before.open : item.at - (item.think ?? 0), top: bottom, bottom: bottom + HEIGHT_OF[item.kind] });
    bottom += HEIGHT_OF[item.kind] + CONV.gap;
  }
  const rises = new Map();
  for (const item of placed) rises.set(item.open, Math.min(rises.get(item.open) ?? CONV.first, CONV.anchor - item.bottom));
  const offsets = placed.map(item => rises.get(item.open));
  const changes = [{ at: 0, y: CONV.first }, ...[...rises].map(([at, y]) => ({ at, y }))];
  keepCardsInView(placed, offsets);
  keepMessagesReadable(placed, offsets);
  keepAnnouncementInView(placed, changes);
  const entries = placed.map(item => (item.think ? during([[item.open, item.at]], thinking(item.top)) : '')
    + (item.kind === 'say' ? streamed(item) : rising(item.at, message(item, item.top))));
  return track(changes, entries.join('\n'));
}

// ---------------------------------------------------------------- style sheet and output
function styleSheet() {
  const fills = Object.entries(COLOR).map(([key, hex]) => `.${key}{fill:${hex}}.${key}-s{stroke:${hex}}`).join('');
  const lamps = LIGHTS.map(([fill, rim], index) => `.light${index}{fill:${fill};stroke:${rim};stroke-width:0.5}`).join('');
  const sizes = Object.entries(SIZE).map(([key, px]) => `.${key}{font-size:${px}px}`).join('');
  const frames = [...keyframes].map(([body, key]) => `@keyframes ${key}{${body}}.${key}{animation-name:${key}}`).join('\n');
  const sweep = Array.from({ length: 8 }, (unused, index) => `.d${index}{animation-delay:${+(index * MOTION.sweep).toFixed(2)}s}`).join('');
  const frozen = OPTIONS.at === undefined ? '' : '.a,.p,.sh{animation:none}\n';   // '{"at":12}': one still frame, drawn from the plain attributes
  return `text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif}
.m{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}.w5{font-weight:500}.w6{font-weight:600}
${sizes}
${fills}
${lamps}
.rim{stroke-opacity:${EDGE.rim}}.border{stroke-opacity:${EDGE.field}}
.no,.sk{fill:none}.sk{stroke-width:${STROKE};stroke-linecap:round;stroke-linejoin:round}
.a{animation-duration:${LOOP}s;animation-iteration-count:infinite;animation-timing-function:step-end;animation-fill-mode:both}
.p{animation:pulse ${MOTION.pulse}s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:${MOTION.floor}}}
.sh{animation:shimmer ${MOTION.shimmer}s linear infinite}${sweep}
@keyframes shimmer{0%,16%,100%{fill:${COLOR.mute}}8%{fill:${COLOR.ink}}}
${frames}
${frozen}@media (prefers-reduced-motion:reduce){.a,.p,.sh{animation:none}}`;
}

const ARIA = 'Time-lapse of a desktop conversation in which the Lead drives three lgtmgate runs in parallel, next to a background tasks '
  + 'panel that groups the agents of the run being discussed under its phases. The user sends /lgtmgate:deliver 142 and asks for '
  + `#187 and #203 in parallel. On #142 the review asks for one fix, the dev agent makes it and the second review passes. ${UNBLOCK.summary} `
  + 'All three pull requests end ready and the Lead asks before merging. Once the user says yes, the Lead replies that every box is '
  + 'checked and merges them. Durations and agent counts are illustrative.';
const { x: wx, y: wy, width: ww, height: wh, radius: wr } = WINDOW;
// What the panel's module is handed: its tokens, its scenario and the drawing and keyframe primitives it shares with this file.
const panel = panelOf({ COLOR, CARD, PANEL, WINDOW, SIZE, MOTION, RUNS, ROWS, CHEVRON, LOOP, HOLD, FADE_OUT, NOW, MOVE, EXIT, FILL,
  words, wordsEnd, box, hairline, stroke, inline, fit, faceWidth, widthOf, merge, during, occupy, steps, track, cut, clip, squares });
const scenery = [
  `<clipPath id="win"><rect x="${wx}" y="${wy}" width="${ww}" height="${wh}" rx="${wr}"/></clipPath>`,
  `<clipPath id="conv"><rect x="${COLUMN.side + 1}" y="${wy + WINDOW.top}" width="${COLUMN.tasks - COLUMN.side - 1}" height="${CONV.anchor + 10 - wy - WINDOW.top}"/></clipPath>`,
  `<clipPath id="tasks"><rect x="${COLUMN.tasks + 1}" y="${wy + WINDOW.top + 1}" width="${wx + ww - COLUMN.tasks - 1}" height="${wh - WINDOW.top - 1}"/></clipPath>`,
  `<clipPath id="pad"><rect x="${COMPOSER.x}" y="${COMPOSER.y}" width="${COMPOSER.width}" height="${COMPOSER.height}" rx="12"/></clipPath>`,
  `<linearGradient id="fade" gradientUnits="userSpaceOnUse" x1="${CONV.left - 4 - MOTION.edge}" y1="0" x2="${CONV.left - 4}" y2="0">`
    + `<stop offset="0" stop-color="${COLOR.win}" stop-opacity="0"/><stop offset="1" stop-color="${COLOR.win}"/></linearGradient>`,
  `<linearGradient id="soft" gradientUnits="userSpaceOnUse" x1="0" y1="${wy + WINDOW.top}" x2="0" y2="${wy + WINDOW.top + CONV.soft}">`
    + `<stop offset="0" stop-color="${COLOR.win}"/><stop offset="1" stop-color="${COLOR.win}" stop-opacity="0"/></linearGradient>`,
  `<g clip-path="url(#win)">${surfaces()}`,
  `<g clip-path="url(#conv)">${scene(conversation())}<rect x="${COLUMN.side + 1}" y="${wy + WINDOW.top}" width="${COLUMN.tasks - COLUMN.side - 1}" height="${CONV.soft}" fill="url(#soft)"/></g>`,
  `<g clip-path="url(#tasks)">${panel}</g>`,
  headers(), composer(), sidebar(), hairline(`M${COLUMN.side + 0.5} ${wy}v${wh}M${COLUMN.tasks + 0.5} ${wy}v${wh}`), '</g>',
  box(wx + 0.5, wy + 0.5, ww - 1, wh - 1, wr, 'edge-s rim no'),
].join('\n');
const edges = checkSlots();
const svg = `<svg viewBox="0 0 ${WIDTH} ${HEIGHT}" width="${WIDTH}" height="${HEIGHT}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${ARIA}">
<style>
${styleSheet()}
</style>
${scenery}
</svg>`;
const banner = `<?xml version="1.0" encoding="UTF-8"?>\n<!-- Generated by scripts/gen-readme-widget.mjs (${THEME} theme). CSS keyframes only, no JS, no web font. -->\n`;
const page = `<!doctype html><meta charset="utf-8"><title>workflow widget (${THEME})</title><body style="margin:24px;background:${COLOR.page}">${svg}</body>\n`;
writeFileSync(OUT_PATH, OUT_PATH.endsWith('.svg') ? `${banner}${svg}\n` : page);
console.log('ok', OUT_PATH, 'bytes', svg.length, 'keyframes', keyframes.size, 'slots checked', edges);
