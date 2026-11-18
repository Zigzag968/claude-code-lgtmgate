// The background tasks panel of the README widget, in the family of scripts/gen-readme-header.mjs and its readme-header-*.mjs.
// scripts/gen-readme-widget.mjs hands over its tokens, its scenario and the drawing and keyframe primitives it shares with the
// conversation (the kit), and writes what panelOf() returns. Node stdlib only.
//
// One container per run, stacked under the panel's title; the run the conversation follows lists its phases in run order.
// - A phase event is one rigid movement of MOTION.move, standard easing: the container's back is ONE rect whose height changes,
//   what is under it glides the same distance (the same keyframes), the chevron turns, and the open phase's body slides up
//   under its line in MOTION.exit (a clip, no opacity). The next line and its body come in MOTION.lag after the start, fading
//   in over MOTION.enter. Bodies keep the room of the busiest phase (ROWS agents): a phase adds one line, an agent adds none.
// - A text that changes state is replaced at once, at the second of its event (a counter, "Running" then a duration, a meta line,
//   an icon): no slide, no fade, never two texts in one place.
// - The panel never shows two things in one place: its own line ("No tasks running") leaves, the containers come in (their
//   shell first, the run's lines after it); at the merge the three containers slide up together, under the panel's rule (the
//   gesture a finished run's phases make under its header), then the line comes back. A stopped run fades out in its place.
let K;   // the kit: tokens, scenario, primitives

const shows = (run, at) => at >= run.listed && (at < run.end || !run.stopped);   // a finished run stays, a stopped one leaves
const leavesAt = run => (run.stopped ? run.end : K.FADE_OUT);   // the second a container starts to go: a stopped run when it stops, the others at the merge
const goneAt = run => leavesAt(run) + (run.stopped ? K.MOTION.exit : K.MOTION.move);

// The phases of a run with the second each is drawn: Setup (one folded line) and the step after it with the run's container,
// the others when their first agent starts. The step after Setup begins with the container, whatever its agent's `at`.
const linesOf = run => run.phases.map((phase, index) => {
  const opens = index < 2 ? run.listed : phase.start;
  return { ...phase, run: run.id, opens, members: phase.members.map((member, order) => (order || index !== 1 ? member : { ...member, at: opens })) };
});

// A container's height at a second: its header alone, or with the phases, every body keeping the room of ROWS agents.
function heightOf(run, at) {
  const { PANEL, CARD } = K;
  if (!shows(run, at)) return 0;
  if (!run.open || at >= run.end) return CARD.head;
  const started = run.lines.filter(phase => phase.opens <= at).length - 1;
  return Math.round(PANEL.first + started * PANEL.pitch + PANEL.agents + (K.ROWS - 1) * PANEL.row + PANEL.foot);
}

// The stack at each second something changes; it never scrolls: a stack taller than the panel fails loudly.
function layout() {
  const times = [...new Set(K.RUNS.flatMap(run => [run.listed, run.end, ...(run.open ? run.lines.map(phase => phase.opens) : [])]))].sort((first, second) => first - second);
  return times.map(at => {
    const tops = {}, heights = {};
    let y = 0;
    for (const run of K.RUNS) {
      heights[run.id] = heightOf(run, at);
      if (shows(run, at)) { tops[run.id] = y; y += heights[run.id] + K.CARD.gap; }
    }
    if (y - K.CARD.gap > K.PANEL.view) throw new Error(`the panel's stack runs ${y - K.CARD.gap}px at ${at}s, past its ${K.PANEL.view}px`);
    return { at, tops, heights };
  });
}

// The run's title and stop button; under them one line that does not change while it runs. Once finished: the title goes mute
// (its fill changes, no second text), the meta line and the stop button are replaced by the card's finished look (the agents and
// the total, the card's chevron).
function header(run) {
  const { PANEL, CARD, COLOR, CHEVRON } = K, { left, right } = PANEL, end = run.end;
  const meta = parts => K.inline(left, CARD.meta, 'f13 mute', parts), live = meta([['', '1 agent running']]);
  const stop = K.box(right - 13.25, 9.45, 13.5, 13.5, 4, 'sk mute-s') + K.box(right - 8.5, 14.2, 4, 4, 1, 'mute');
  if (run.stopped) return K.words(left, CARD.title, 'f13 w5 ink', run.head) + live + stop;
  const fill = K.steps([{ at: 0, y: COLOR.ink }, { at: end, y: COLOR.mute }], colour => `fill:${colour}`, K.FILL);
  return K.words(left, CARD.title, `${fill.name} f13 w5 ${K.NOW >= end ? 'mute' : 'ink'}`, run.head)
    + K.cut([{ at: 0, mark: live }, { at: end, mark: meta([['', `${run.agents.length} agents`], ['', run.final]]) }], `${run.id} meta`)
    + K.cut([{ at: 0, mark: stop }, { at: end, mark: K.stroke(right - 4.75, 12, CHEVRON.right, 'mute-s') }], `${run.id} icon`);
}

// A phase's line: a chevron (turning from down to right as the phase folds), its name and its counter (the agents done of the
// agents started, each count replacing the one before), and its agents' total duration, which comes in as it folds. Setup is one
// step: no counter, its duration shown from the start. The name is drawn once; the counter's copies lay it out unseen (.no).
function line(phase, index, fold) {
  const { PANEL } = K, { left, right, label } = PANEL, y = PANEL.first + index * PANEL.pitch, x = left + label, count = phase.members.length;
  const name = counter => K.inline(x, y, 'f13 mute', [[counter ? 'w5 no' : 'w5 ink', phase.name], ...(counter ? [['', counter]] : [])]);
  const turn = K.steps(fold ? [{ at: 0, y: 90 }, { at: fold, y: 0 }] : [{ at: 0, y: index ? 90 : 0 }], angle => `transform:rotate(${angle}deg)`, K.MOVE);
  const chevron = `<g transform="translate(${left + 4} ${y - 4})"><path class="${turn.name} sk mute-s" transform="rotate(${turn.here})" d="M-2 -4l4 4-4 4"/></g>`;
  const took = K.wordsEnd(right, y, 'f13 mute', phase.took);
  if (index === 0) return chevron + name('') + took;
  const counters = [...phase.members.map((member, order) => ({ at: member.at, mark: name(`${order}/${order + 1}`) })), ...(fold ? [{ at: fold, mark: name(`${count}/${count}`) }] : [])];
  return chevron + name('') + K.cut(counters, `${phase.run} ${phase.name} count`) + (fold ? K.cut([{ at: fold, mark: took }], `${phase.run} ${phase.name} took`) : '');
}

// An open phase's body: its squares and its agents, one row each, in a window as tall as ROWS rows. A row comes in as its agent
// starts (in an empty place); its "Running" is replaced by its duration as the next agent starts. At the fold the body slides up
// under its line.
function body(phase, index, fold) {
  const { PANEL, COLOR, SIZE, MOTION } = K, y = PANEL.first + index * PANEL.pitch, x = PANEL.left + PANEL.label + PANEL.indent, last = phase.members.length - 1;
  const rows = phase.members.map((member, order) => {
    const base = y + PANEL.agents + order * PANEL.row, state = raw => K.wordsEnd(PANEL.right, base, 'f13 mute', raw);
    const widest = Math.max(...['Running', member.took].map(raw => Math.max(K.faceWidth(raw, SIZE.f13), K.widthOf(raw, SIZE.f13))));
    const right = order < last ? K.cut([{ at: 0, mark: state('Running') }, { at: member.end, mark: state(member.took) }], `${phase.run} ${member.label} state`) : state('Running');
    const drawn = K.words(x, base, 'f13 mute', K.fit(member.shown, PANEL.right - x - 16 - widest)) + right;
    return order ? K.during([[member.at, K.HOLD]], drawn, { enter: MOTION.enter }) : drawn;
  }).join('');
  const inner = K.squares(phase.members, phase.end, x, y + PANEL.dots, COLOR.tile) + rows, tall = Math.ceil(PANEL.agents + (K.ROWS - 1) * PANEL.row - 2);
  return K.clip(PANEL.x, y + 6, PANEL.width, tall, fold ? K.track([{ at: 0, y: 0 }, { at: fold, y: -tall }], inner, K.EXIT) : inner);
}

// The run's phases and the rule above them, in a window whose top edge is that rule: at the run's end they slide up under it, as
// far as the container's back shrinks (the card's own edge takes the rule's place). A phase's line stays until then; its body
// leaves as the next phase starts.
function block(run, mine, began) {
  const { PANEL, CARD, MOTION } = K, end = Math.min(K.HOLD, run.end + MOTION.move), rule = K.hairline(`M${PANEL.x} ${CARD.head - 0.5}h${PANEL.width}`);
  const markup = run.lines.map((phase, index) => {
    const fold = run.lines[index + 1]?.opens, enters = index < 2 ? began + MOTION.enter : phase.opens + MOTION.lag;
    return K.during([[enters, end]], (index ? '' : rule) + line(phase, index, fold), { enter: MOTION.enter })
      + (index ? K.during([[enters, fold ? fold + MOTION.exit : end]], body(phase, index, fold), { enter: MOTION.enter }) : '');
  }).join('');
  const before = mine.filter(step => step.at < run.end).at(-1).heights[run.id], reach = Math.max(...mine.map(step => step.heights[run.id]));
  return K.clip(PANEL.x, CARD.head - 1, PANEL.width, reach - CARD.head + 1, K.track([{ at: 0, y: 0 }, { at: run.end, y: CARD.head - before }], markup, K.MOVE));
}

// A container comes in as its run is listed (after the panel's own line has left, if the panel was empty); its back and header
// first, the run's lines after them. It glides as the ones above it grow or fold. At its end a stopped run leaves; the others
// stay folded until the merge.
function container(run, stack, drop) {
  const { PANEL, CARD, MOTION } = K, mine = stack.filter(step => shows(run, step.at));
  const began = run.listed + (K.RUNS.some(other => other !== run && shows(other, run.listed - 1e-6)) ? 0 : MOTION.out);
  const back = K.steps(mine.map(step => ({ at: step.at, y: step.heights[run.id] - 1 })), tall => `height:${tall}px`, K.MOVE);
  const rect = `<rect x="${PANEL.x + 0.5}" y="0.5" width="${PANEL.width - 1}" height="${back.here}" rx="${CARD.radius}" class="${back.name} tile line-s"/>`;
  const shell = K.during([[began, run.stopped ? run.end : goneAt(run)]], rect + header(run), { enter: MOTION.enter, leave: run.stopped ? MOTION.exit : 0 });
  const glide = mine.map(step => ({ at: step.at, y: PANEL.top + step.tops[run.id] }));
  if (!run.stopped) glide.push({ at: K.FADE_OUT, y: glide.at(-1).y - drop });
  return K.track(glide, shell + (run.open ? block(run, mine, began) : ''), K.MOVE);
}

// The panel with no run in it says so where a container's title would be. It leaves first as a run comes in, and comes back
// once the containers are gone (it registers with them in one slot: checkSlots() fails if the two overlap).
function idle() {
  const { PANEL, CARD, MOTION } = K, gone = K.merge(K.RUNS.map(run => [run.listed, goneAt(run)]));
  K.occupy('panel', gone.map(([from, to]) => [from + MOTION.out, to]));
  const edges = [0, ...gone.flat(), K.LOOP], gaps = edges.flatMap((at, index) => (index % 2 ? [] : [[at, edges[index + 1]]]));
  return K.during(gaps, K.words(PANEL.left, PANEL.top + CARD.title, 'f13 mute', 'No tasks running'), { enter: MOTION.enter, leave: MOTION.out, slot: 'panel' });
}

// What the stack ends as: how far the containers slide up at the merge, until the lowest one's bottom is at the panel's rule.
function dropOf(stack) {
  const { PANEL, WINDOW } = K, rest = stack.at(-1);
  return PANEL.top + Math.max(...K.RUNS.filter(run => shows(run, rest.at)).map(run => rest.tops[run.id] + rest.heights[run.id])) - (WINDOW.y + WINDOW.top);
}

export function panelOf(kit) {
  K = kit;
  for (const run of K.RUNS) run.lines = linesOf(run);
  const stack = layout(), drop = dropOf(stack);
  return idle() + K.RUNS.map(run => container(run, stack, drop)).join('\n');
}
