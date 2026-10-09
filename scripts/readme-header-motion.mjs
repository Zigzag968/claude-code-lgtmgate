// The motion half of scripts/gen-readme-header.mjs: the 18 s clock, the keyframe toolkit with its numeric twin, the two
// timelines and the per-line keyframes. Moved out unchanged to keep the generator under the line limit; `KF` collects the
// @keyframes in call order, which is the CSS order of the SVG.
// ---------------------------------------------------------------- clock
export const T = 18;
export const SHIFT = { A: 12.1, B: 0.8 };       // each line runs on its own clock: global = local + SHIFT
export const f2 = n => Math.round(n * 100) / 100;
export const modulo = (a, n) => ((a % n) + n) % n;
export const glob = (p, t) => modulo(t + SHIFT[p], T);
export const loc = (p, g) => modulo(g - SHIFT[p], T);

// ---------------------------------------------------------------- keyframes (+ a numeric model of the same curves)
export const E = {
  move: 'cubic-bezier(.77,0,.175,1)', out: 'cubic-bezier(.23,1,.32,1)', back: 'cubic-bezier(.34,1.56,.64,1)',
  slam: 'cubic-bezier(.7,0,1,.6)', io: 'cubic-bezier(.65,0,.35,1)', drop: 'cubic-bezier(.55,0,.85,.55)',
};
export const KF = [];
export const pc = t => `${Math.round((t / T) * 100000) / 1000}%`;
export const kf = (name, frames) => KF.push(`@keyframes ${name}{${frames.map(([t, css, easing]) => `${pc(t)}{${css}${easing ? `;animation-timing-function:${easing}` : ''}}`).join('')}}`);
export const tx = x => `transform:translateX(${f2(x)}px)`;
export const ty = y => `transform:translateY(${f2(y)}px)`;
export const txy = (x, y) => `transform:translate(${f2(x)}px,${f2(y)}px)`;
export const rot = a => `transform:rotate(${f2(a)}deg)`;
export const op = o => `opacity:${o}`;
export const moves = (v0, steps, fmt, ease = E.move) => {
  const fr = [[0, fmt(v0)]]; let v = v0;
  for (const [a, b, nv, easing] of steps) { fr.push([a, fmt(v), easing || ease], [b, fmt(nv)]); v = nv; }
  if (fr[fr.length - 1][0] < T) fr.push([T, fmt(v)]);
  return fr;
};
// numeric twin: frames [[t, value, easing?]]; CSS applies a frame's easing until the next frame (default `ease`)
export const bez = spec => {
  const [x1, y1, x2, y2] = spec.slice(spec.indexOf('(') + 1, spec.lastIndexOf(')')).split(',').map(Number);   // not a regex: 'cubic-bezier' has a '-'
  const cx = s => 3 * (1 - s) ** 2 * s * x1 + 3 * (1 - s) * s * s * x2 + s ** 3;
  const cy = s => 3 * (1 - s) ** 2 * s * y1 + 3 * (1 - s) * s * s * y2 + s ** 3;
  return u => { let lo = 0, hi = 1, s = u; for (let index = 0; index < 50; index++) { s = (lo + hi) / 2; if (cx(s) < u) lo = s; else hi = s; } return cy(s); };
};
export const EASE_DEFAULT = 'cubic-bezier(.25,.1,.25,1)';
export const valueAt = (fr, t) => {
  for (let index = 0; index < fr.length - 1; index++) {
    const [a, va, easing] = fr[index], [b, vb] = fr[index + 1];
    if (t >= a && t < b) return va + (vb - va) * (va === vb ? 0 : bez(easing || EASE_DEFAULT)((t - a) / (b - a)));
  }
  return fr[fr.length - 1][1];
};

// ---------------------------------------------------------------- geometry the keyframes read
export const BH = 20, PHt = 52, TOPY = BH + PHt;
export const HOIST = 150, DROP = 60;
export const LAMP = { off: '#DCD8E8', o: '#F5A524', g: '#22C55E', r: '#F04438' };

// ---------------------------------------------------------------- timelines (each line on its own local clock)
export const TB = { pop: [.40, .75], drop: [.85, 1.65], m1: [2.05, 2.60], plan: [2.60, 3.60], rows: [2.85, 3.15, 3.45], m2: [3.60, 4.15],
  work: [[4.25, 5.55]], stamp: 5.75, ci: [[5.80, 7.30]], m3: [6.15, 6.70], read: [6.70, 8.05], ticks: [7.15, 7.48, 7.81],
  m4: [8.00, 8.55], hold: [8.55, 9.35], flip: 9.35, door: [9.40, 9.80], m5: [9.85, 10.40], grip: 11.05, reset: 11.30, doorDown: [11.30, 11.70] };
export const TA = { pop: [0, .35], drop: [.45, 1.25], m1: [1.35, 1.90], plan: [1.90, 2.90], rows: [2.15, 2.45, 2.75], m2: [2.90, 3.45],
  work: [[3.55, 4.85], [8.10, 9.00]], stamp: 5.05, stamp2: 9.20, ci: [[5.10, 6.60], [9.25, 10.60]],   // the fix is a new push: CI runs again
  m3: [5.45, 6.00], read1: [6.05, 7.15], tick1: 6.45, fail: 6.85,
  back: [7.40, 8.00],                                                // the workflow runs the belt backwards: REVIEW -> DEV
  m3b: [9.55, 10.10], read2: [10.15, 11.35], ticks2: [10.70, 11.05], m4: [11.35, 11.90], hold: [11.90, 12.70], flip: 12.70,
  door: [12.75, 13.15], m5: [13.15, 13.70], grip: 14.30, reset: 14.55, doorDown: [14.55, 14.95] };
TA.red = [TA.fail + .03, TA.ticks2[1] + .02];                      // REVIEW light red until the second review passes
// the Lead and main (global clock): the arm serves the back line first, then the front line
export const ARM = { A: { down: [8.0, 8.4], swing: [8.5, 9.4], back: [9.5, 10.1] },
  B: { down: [11.45, 11.85], swing: [11.95, 12.85], back: [12.95, 13.55] } };
export const CAR = { toB: [10.2, 11.35], toA: [13.7, 14.85] };
export const MOVES = [[2.0, 2.75], [5.6, 6.35], [9.7, 10.45], [14.9, 15.65]];   // A's gap waits at z=350 (6.35-9.7), B's at z=0 (10.45-14.9)
export const MERGE = { A: 7.85, B: 11.3 };                                  // the operator's go-ahead, just before the Lead comes down

// ---------------------------------------------------------------- animations shared by both lines (each on its own clock)
const stampsOf = t => t.stamp2 ? [t.stamp, t.stamp2] : [t.stamp];

// cable and hook, the checklist scanner, the PR label and the review marks
function planKF(p, t) {
  const cable0 = f2((HOIST - TOPY - DROP) / (HOIST - TOPY));
  kf(`cable${p}`, [[0, `transform:scaleY(${cable0})`], [t.drop[0], `transform:scaleY(${cable0})`, E.drop], [t.drop[1], 'transform:scaleY(1)'], [t.drop[1] + .15, 'transform:scaleY(1)', E.out], [t.drop[1] + .7, `transform:scaleY(${cable0})`], [T, `transform:scaleY(${cable0})`]]);
  kf(`hook${p}`, [[0, ty(HOIST - TOPY - DROP)], [t.drop[0], ty(HOIST - TOPY - DROP), E.drop], [t.drop[1], ty(HOIST - TOPY)], [t.drop[1] + .15, ty(HOIST - TOPY), E.out], [t.drop[1] + .7, ty(HOIST - TOPY - DROP)], [T, ty(HOIST - TOPY - DROP)]]);
  kf(`fan${p}`, [[0, op(0)], [t.plan[0] + .05, op(0)], [t.plan[0] + .2, op(1)], [t.plan[1] - .15, op(1)], [t.plan[1], op(0)], [T, op(0)]]);
  kf(`emit${p}`, [[0, op(.25)], [t.plan[0], op(.25)], [t.plan[0] + .15, op(1)], [t.plan[1] - .1, op(1)], [t.plan[1], op(.25)], [T, op(.25)]]);
  const r = t.rows;
  kf(`scan${p}`, [[0, `${ty(0)};opacity:0`], [t.plan[0] + .18, `${ty(0)};opacity:0`], [t.plan[0] + .2, `${ty(0)};opacity:1`, E.io], [r[1] + .05, `${ty(PHt - 2)};opacity:1`, E.io], [t.plan[1] - .15, `${ty(0)};opacity:1`], [t.plan[1] - .05, `${ty(0)};opacity:0`], [T, `${ty(0)};opacity:0`]]);
  r.forEach((x, index) => kf(`row${index + 1}${p}`, [[0, 'opacity:0;transform:scaleX(0)'], [x, 'opacity:0;transform:scaleX(0)', E.out], [x + .22, 'opacity:1;transform:scaleX(1)'], [t.reset, 'opacity:1;transform:scaleX(1)'], [t.reset + .001, 'opacity:0;transform:scaleX(0)'], [T, 'opacity:0;transform:scaleX(0)']]));
  // the PR opens (grey, draft) when Nick's work is done; a later push bumps it; Morgan's LGTM turns it green
  const st = [[0, 'opacity:0;transform:scale(1.5)'], [t.stamp - .001, 'opacity:0;transform:scale(1.5)'], [t.stamp, 'opacity:1;transform:scale(1.5)', E.back], [t.stamp + .22, 'opacity:1;transform:scale(1)']];
  const bumps = [...(t.fail ? [t.fail] : []), ...(t.stamp2 ? [t.stamp2] : []), p === 'A' ? t.ticks2[1] : t.ticks[2]];
  for (const b of bumps) st.push([b, 'opacity:1;transform:scale(1)', E.out], [b + .1, 'opacity:1;transform:scale(1.25)', E.io], [b + .35, 'opacity:1;transform:scale(1)']);
  st.push([t.reset, 'opacity:1;transform:scale(1)'], [t.reset + .001, 'opacity:0;transform:scale(1.5)'], [T, 'opacity:0;transform:scale(1.5)']);
  kf(`stamp${p}`, st);
  const pass = p === 'A' ? t.ticks2[1] : t.ticks[2];                 // Morgan's review passes: the PR is ready to merge
  kf(`ready${p}`, [[0, op(0)], [pass - .001, op(0)], [pass, op(1)], [t.reset, op(1)], [t.reset + .001, op(0)], [T, op(0)]]);   // a clean switch (a cross-fade would go muddy)
  if (t.fail) {
    kf(`chg${p}`, [[0, op(0)], [t.fail - .001, op(0)], [t.fail, op(1)], [pass, op(1)], [pass + .001, op(0)], [T, op(0)]]);
    kf(`x2${p}`, [[0, 'opacity:0;transform:scale(.4)'], [t.fail - .001, 'opacity:0;transform:scale(.4)'], [t.fail, 'opacity:1;transform:scale(.4)', E.back], [t.fail + .2, 'opacity:1;transform:scale(1)'], [t.ticks2[0] - .12, 'opacity:1;transform:scale(1)'], [t.ticks2[0] - .02, 'opacity:0;transform:scale(1)'], [T, 'opacity:0;transform:scale(1)']]);
  }
}

// Nick's workshop: the head dives into a cartoon work cloud that boils while code and tools fly out; it pops, the PR opens
function workKF(p, t, syms) {
  const pr = [[0, ty(0)]], bm = [[0, 'opacity:0;transform:scale(.6)']];
  const sy = syms.map(() => [[0, 'opacity:0;transform:translate(0px,0px) scale(.3) rotate(0deg)']]);
  t.work.forEach(([w0, w1], k) => {
    const st0 = stampsOf(t)[k];
    pr.push([w0 - .2, ty(0), E.out], [w0, ty(4)]);
    for (let x = w0 + .12, index = 0; x < w1 - .06; x += .12, index++) pr.push([x, ty(index % 2 ? 4 : 2.5)]);
    pr.push([w1, ty(4), E.out], [st0 - .08, ty(-4), E.slam], [st0, ty(10)], [st0 + .15, ty(10), E.out], [st0 + .55, ty(0)]);
    sy.forEach((a, index) => {
      const [v, spin] = [syms[index][1], syms[index][2]];
      for (const off of [.18 + index * .11, .18 + index * .11 + (w1 - w0) * .5]) {
        const x = w0 + off; if (x + .62 > st0) continue;
        a.push([x, 'opacity:0;transform:translate(0px,0px) scale(.3) rotate(0deg)', E.out], [x + .14, `opacity:1;transform:translate(${f2(v[0] * .4)}px,${f2(v[1] * .4)}px) scale(1.3) rotate(${spin / 3}deg)`, E.out], [x + .45, `opacity:1;transform:translate(${f2(v[0] * .85)}px,${f2(v[1] * .85)}px) scale(1.1) rotate(${f2(spin * .8)}deg)`], [x + .62, `opacity:0;transform:translate(${v[0]}px,${v[1]}px) scale(.9) rotate(${spin}deg)`]);
      }
    });
    bm.push([st0 - .1, 'opacity:0;transform:scale(.6)', E.out], [st0 - .02, 'opacity:1;transform:scale(1)'], [st0 + .22, 'opacity:0;transform:scale(1.35)']);
  });
  pr.push([T, ty(0)]); bm.push([T, 'opacity:0;transform:scale(1.35)']);
  kf(`press${p}`, pr); kf(`boom${p}`, bm);
  sy.forEach((a, index) => kf(`sym${index}${p}`, [...a, [T, 'opacity:0;transform:translate(0px,0px) scale(.3) rotate(0deg)']]));
}

// the gate: CI light (amber while CI runs, green once it passes) and checklist light (red while held, green on LGTM)
function gateKF(p, t) {
  const ciA = [[0, op(0)]], ciG = [[0, op(0)]];
  t.ci.forEach(([a, b], k) => {
    ciA.push([a - .001, op(0)], [a, op(1)]);
    for (let x = a + .35, index = 0; x < b - .1; x += .35, index++) ciA.push([x, op(index % 2 ? 1 : .35), E.io]);
    ciA.push([b - .001, op(1)], [b, op(0)]);
    ciG.push([a - .001, op(k ? 1 : 0)], [a, op(0)], [b - .001, op(0)], [b, op(1)]);
  });
  ciG.push([t.reset, op(1)], [t.reset + .001, op(0)], [T, op(0)]); ciA.push([T, op(0)]);
  kf(`ciA${p}`, ciA); kf(`ciG${p}`, ciG);
  kf(`ciGlowA${p}`, ciA.map(([x, css, easing]) => [x, css.replace(/opacity:([\d.]+)/, (m0, v) => `opacity:${f2(v * .8)}`), easing]));
  kf(`ciGlowG${p}`, ciG.map(([x, css, easing]) => [x, css.replace(/opacity:([\d.]+)/, (m0, v) => `opacity:${f2(v * .6)}`), easing]));
  kf(`door${p}`, [[0, ty(0)], [t.door[0], ty(0), E.out], [t.door[1], ty(-74)], [t.doorDown[0], ty(-74), E.io], [t.doorDown[1], ty(0)], [T, ty(0)]]);
  kf(`lampR${p}`, [[0, op(0)], [t.hold[0], op(0)], [t.hold[0] + .03, op(1)], [t.hold[0] + .23, op(.2)], [t.hold[0] + .4, op(1)], [t.hold[0] + .57, op(.2)], [t.hold[0] + .74, op(1)], [t.flip, op(0)], [T, op(0)]]);
  kf(`lampG${p}`, [[0, op(0)], [t.flip - .01, op(0)], [t.flip + .03, op(1)], [t.reset, op(1)], [t.reset + .3, op(0)], [T, op(0)]]);
  kf(`glow${p}`, [[0, 'opacity:0;transform:scale(.5)'], [t.flip, 'opacity:0;transform:scale(.5)', E.out], [t.flip + .3, 'opacity:1;transform:scale(1.25)', E.io], [t.flip + .85, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .3, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .6, 'opacity:0;transform:scale(.8)'], [T, 'opacity:0;transform:scale(.8)']]);
}

// station lights: orange in progress, green done (on to the next step), red error, off idle; the monitor mirrors them
function lightsKF(p, t) {
  const merge = loc(p, MERGE[p]), merged = loc(p, ARM[p].swing[1]);
  const L = p === 'B'
    ? { pl: [[t.plan[0], t.plan[1], 'o'], [t.plan[1], t.m2[1], 'g']], dv: [[t.m2[1], t.stamp, 'o'], [t.stamp, t.m3[1], 'g']],
        rv: [[t.read[0], t.ticks[2], 'o'], [t.ticks[2], t.m4[1], 'g']], lg: [[t.hold[0], t.flip, 'o'], [t.flip, merged, 'g']] }
    : { pl: [[t.plan[0], t.plan[1], 'o'], [t.plan[1], t.m2[1], 'g']],
        dv: [[t.m2[1], t.stamp, 'o'], [t.stamp, t.m3[1], 'g'], [t.back[1], t.stamp2, 'o'], [t.stamp2, t.m3b[1], 'g']],
        rv: [[t.read1[0], t.fail, 'o'], [t.fail, t.read2[0], 'r'], [t.read2[0], t.ticks2[1], 'o'], [t.ticks2[1], t.m4[1], 'g']],
        lg: [[t.hold[0], t.flip, 'o'], [t.flip, merged, 'g']] };
  const fillKF = (segs, off) => {
    const transitions = [];
    segs.forEach(([a, b, c], index) => { transitions.push([a, LAMP[c]]); const nx = segs[index + 1]; if (!nx || Math.abs(nx[0] - b) > 1e-6) transitions.push([b, off]); });
    const fr = [[0, `fill:${off}`]]; let current = off;
    for (const [x, col] of transitions) { fr.push([x - .001, `fill:${current}`], [x, `fill:${col}`]); current = col; }
    fr.push([T, `fill:${current}`]); return fr;
  };
  const glowKF = (segs, c) => {
    const fr = [[0, op(0)]];
    for (const [a, b, cc] of segs) if (cc === c) {
      fr.push([a - .001, op(0)], [a + .08, op(1)]);
      if (c !== 'g') for (let x = a + .45, index = 0; x < b - .2; x += .45, index++) fr.push([x, op(index % 2 ? 1 : .45), E.io]);
      fr.push([b - .001, op(c === 'g' ? .8 : 1)], [b, op(0)]);
    }
    fr.push([T, op(0)]); return fr;
  };
  for (const k of ['pl', 'dv', 'rv']) { kf(`lm${k}${p}`, fillKF(L[k], LAMP.off)); for (const c of ['o', 'g', 'r']) kf(`l${c}${k}${p}`, glowKF(L[k], c)); }
  for (const k of ['pl', 'dv', 'rv', 'lg']) kf(`nd${k}${p}`, fillKF(L[k], '#3A3657'));
  kf(`rv${p}`, [[0, op(0)], [t.pop[0], op(0), E.out], [t.pop[0] + .3, op(1)], [merged + .6, op(1), E.out], [merged + .9, op(0)], [T, op(0)]]);
  kf(`mg${p}`, [[0, 'opacity:0;transform:scale(1)'], [merge - .001, 'opacity:0;transform:scale(1)'], [merge, 'opacity:1;transform:scale(1.35)', E.back], [merge + .25, 'opacity:1;transform:scale(1)'], [merged - .001, 'opacity:1;transform:scale(1)'], [merged, 'opacity:0;transform:scale(1)'], [T, 'opacity:0;transform:scale(1)']]);
  kf(`mgd${p}`, [[0, op(0)], [merged - .001, op(0)], [merged, op(1)], [T, op(1)]]);
}

// the kraft box exists only while the parcel is in DEV (Nick puts code in it and sticks the PR label): it pops around the
// label when the parcel reaches the station and goes when it leaves; before and after, the issue is the label alone, on its foot.
export function boxKF(p, t) {
  const s0 = 'transform:scale(0)', s1 = 'transform:scale(1)';
  const stays = t.back ? [[t.m2[1], t.m3[0]], [t.back[1], t.m3b[0]]] : [[t.m2[1], t.m3[0]]];     // [arrives, leaves] per visit
  const box = [[0, s0]], foot = [[0, op(1)]];
  for (const [a, b] of stays) {
    box.push([a - .001, s0, E.back], [a + .3, s1], [b, s1], [b + .001, s0]);
    foot.push([a - .001, op(1)], [a + .05, op(0)], [b + .001, op(1)]);                           // the foot hides under the box
  }
  box.push([T, s0]); foot.push([T, op(1)]);
  kf(`box${p}`, box); kf(`foot${p}`, foot);
}

// KF.push order is the CSS order: the four groups run in the order the original single function wrote them
export function lineKF(p, t, syms) {
  planKF(p, t); workKF(p, t, syms); gateKF(p, t); lightsKF(p, t);
}
