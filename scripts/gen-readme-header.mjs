// The README's animated header: two assembly lines, the LGTM gate, the Lead's arm and the main lane.
// Usage: node scripts/gen-readme-header.mjs .github/assets/header.svg         (the README header)
//        node scripts/gen-readme-header.mjs /tmp/header-mockup.html           (a page to review it in a browser)
// Optional 2nd arg: JSON overrides, e.g. '{"cold":7.9}'. Node stdlib only. Output: one SVG, CSS keyframes, no JS, no web font.
// After regenerating the SVG, refresh .github/assets/header-static.png (the still under prefers-reduced-motion):
// a 2x screenshot of the SVG with reduced motion on. The design history (v1-v10 mockups) lives on the
// design/readme-header-mockups branch.
//
// What the scene says:
// - every station has a status light (orange in progress, green done, red error, off idle), mirrored on the
//   operator's monitor, one schematic row per workflow in progress, then the human's MERGE go-ahead
// - DEV: the parcel shakes while code flies out of it, then the PR opens (grey draft label)
// - REVIEW: Morgan ticks each criterion green; on the back line one gets a red cross, the label turns red and the
//   workflow runs the belt back to DEV; after the fix CI runs again and the review passes (label green)
// - the LGTM gate opens only when its CI light and checklist light are both green
// - one Lead arm on an endless rail sets each approved PR on main, under a hanging "main" sign
import { writeFileSync } from 'fs';
const OUT = process.argv[2];
const OPT = JSON.parse(process.argv[3] || '{}');

// ---------------------------------------------------------------- canvas / clock
const W = 1280, H = 344, T = 18;
const COLD = OPT.cold ?? 7.9;                 // opens as the operator presses MERGE and the Lead comes down for #143
const SHIFT = { A: 12.1, B: 0.8 };       // each line runs on its own clock: global = local + SHIFT
const f2 = n => Math.round(n * 100) / 100;
const mod = (a, n) => ((a % n) + n) % n;
const glob = (p, t) => mod(t + SHIFT[p], T);
const loc = (p, g) => mod(g - SHIFT[p], T);

// ---------------------------------------------------------------- projection (cabinet oblique, 45°, depth x0.5)
const KX = 0.3536, KY = 0.3536, FLOOR = 316;
const P = (x, y, z) => [x + z * KX, FLOOR - y - z * KY];
const pts = a => a.map(p => `${f2(p[0])},${f2(p[1])}`).join(' ');

// ---------------------------------------------------------------- palette
const BG = '#F7F6F3';
const C = {
  'st-t': '#EEEDF3', 'st-f': '#DDDBE6', 'st-r': '#C9C6D6',          // structure
  'hs-t': '#EEEBFA', 'hs-f': '#DCD6F3', 'hs-r': '#C3BBE6',          // station columns
  'bt-t': '#E4E1EC', 'bt-f': '#CDC9DA', 'bt-r': '#B9B4CA',          // belts
  'mn-t': '#E6E2F4', 'mn-f': '#CFC8EA', 'mn-r': '#B7AEDC',          // main lane
  'kr-t': '#F6DEB4', 'kr-f': '#ECC893', 'kr-r': '#D7AD71',          // kraft parcel
  'ag-t': '#B6AAFF', 'ag-f': '#8069FF', 'ag-r': '#5E48E6',          // agent tools
  'ac-t': '#4A4570', 'ac-f': '#35305A', 'ac-r': '#28244A',          // the Lead / dark hardware
  'gt-t': '#4A4570', 'gt-f': '#35305A', 'gt-r': '#28244A',          // gate frame
  'sg-t': '#7B63F0', 'sg-f': '#5B3FE0', 'sg-r': '#4A31C4',          // the main sign
  'dk-t': '#3A3558', 'dk-f': '#2B2748', 'dk-r': '#211E3B',          // monitor
};
const HZ_Y = '#FFC53D', INK = '#1E1B3A';
const box = (x, y, z, w, h, d, m) => {
  const f = [P(x, y, z), P(x + w, y, z), P(x + w, y + h, z), P(x, y + h, z)];
  const t = [P(x, y + h, z), P(x + w, y + h, z), P(x + w, y + h, z + d), P(x, y + h, z + d)];
  const r = [P(x + w, y, z), P(x + w, y, z + d), P(x + w, y + h, z + d), P(x + w, y + h, z)];
  return `<polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/>`;
};

// ---------------------------------------------------------------- keyframes (+ a numeric model of the same curves)
const E = {
  move: 'cubic-bezier(.77,0,.175,1)', out: 'cubic-bezier(.23,1,.32,1)', back: 'cubic-bezier(.34,1.56,.64,1)',
  slam: 'cubic-bezier(.7,0,1,.6)', io: 'cubic-bezier(.65,0,.35,1)', drop: 'cubic-bezier(.55,0,.85,.55)',
};
const KF = [];
const pc = t => `${Math.round((t / T) * 100000) / 1000}%`;
const kf = (name, frames) => KF.push(`@keyframes ${name}{${frames.map(([t, css, e]) => `${pc(t)}{${css}${e ? `;animation-timing-function:${e}` : ''}}`).join('')}}`);
const tx = x => `transform:translateX(${f2(x)}px)`;
const ty = y => `transform:translateY(${f2(y)}px)`;
const txy = (x, y) => `transform:translate(${f2(x)}px,${f2(y)}px)`;
const rot = a => `transform:rotate(${f2(a)}deg)`;
const op = o => `opacity:${o}`;
const moves = (v0, steps, fmt, ease = E.move) => {
  const fr = [[0, fmt(v0)]]; let v = v0;
  for (const [a, b, nv, e] of steps) { fr.push([a, fmt(v), e || ease], [b, fmt(nv)]); v = nv; }
  if (fr[fr.length - 1][0] < T) fr.push([T, fmt(v)]);
  return fr;
};
// numeric twin: frames [[t, value, easing?]]; CSS applies a frame's easing until the next frame (default `ease`)
const bez = spec => {
  const [x1, y1, x2, y2] = spec.slice(spec.indexOf('(') + 1, spec.lastIndexOf(')')).split(',').map(Number);   // not a regex: 'cubic-bezier' has a '-'
  const cx = s => 3 * (1 - s) ** 2 * s * x1 + 3 * (1 - s) * s * s * x2 + s ** 3;
  const cy = s => 3 * (1 - s) ** 2 * s * y1 + 3 * (1 - s) * s * s * y2 + s ** 3;
  return u => { let lo = 0, hi = 1, s = u; for (let i = 0; i < 50; i++) { s = (lo + hi) / 2; if (cx(s) < u) lo = s; else hi = s; } return cy(s); };
};
const EASE_DEFAULT = 'cubic-bezier(.25,.1,.25,1)';
const valueAt = (fr, t) => {
  for (let i = 0; i < fr.length - 1; i++) {
    const [a, va, e] = fr[i], [b, vb] = fr[i + 1];
    if (t >= a && t < b) return va + (vb - va) * (va === vb ? 0 : bez(e || EASE_DEFAULT)((t - a) / (b - a)));
  }
  return fr[fr.length - 1][1];
};

// ---------------------------------------------------------------- geometry (world units; x along the line, y up, z depth)
const BX0 = 360, BX1 = 930, BH = 20, BD = 64;
const PW = 70, PHt = 52, PD = 50, ZF = (BD - PD) / 2, ZC = ZF + PD / 2, TOPY = BH + PHt;
const SP = 100, INT = 400, TREAD = 20;
const XS = { int: INT, plan: INT + SP, dev: INT + 2 * SP, rev: INT + 3 * SP, lgtm: INT + 4 * SP, pick: INT + 4 * SP + 80 };
const DX = [0, SP, 2 * SP, 3 * SP, 4 * SP, 4 * SP + 80];           // 480 = 24 treads -> seamless
const XG = XS.lgtm + PW / 2 + 8;                                   // gate plane; its stack light (and the LGTM label) at XG + 2.5
const ZL = { A: 350, B: 0 };                                       // A = back line, B = front line
const HOIST = 150, DROP = 60;


// ---------------------------------------------------------------- timelines (each line on its own local clock)
const TB = { pop: [.40, .75], drop: [.85, 1.65], m1: [2.05, 2.60], plan: [2.60, 3.60], rows: [2.85, 3.15, 3.45], m2: [3.60, 4.15],
  work: [[4.25, 5.55]], stamp: 5.75, ci: [[5.80, 7.30]], m3: [6.15, 6.70], read: [6.70, 8.05], ticks: [7.15, 7.48, 7.81],
  m4: [8.00, 8.55], hold: [8.55, 9.35], flip: 9.35, door: [9.40, 9.80], m5: [9.85, 10.40], grip: 11.05, reset: 11.30, doorDown: [11.30, 11.70] };
const TA = { pop: [0, .35], drop: [.45, 1.25], m1: [1.35, 1.90], plan: [1.90, 2.90], rows: [2.15, 2.45, 2.75], m2: [2.90, 3.45],
  work: [[3.55, 4.85], [8.10, 9.00]], stamp: 5.05, stamp2: 9.20, ci: [[5.10, 6.60], [9.25, 10.60]],   // the fix is a new push: CI runs again
  m3: [5.45, 6.00], read1: [6.05, 7.15], tick1: 6.45, fail: 6.85,
  back: [7.40, 8.00],                                                // the workflow runs the belt backwards: REVIEW -> DEV
  m3b: [9.55, 10.10], read2: [10.15, 11.35], ticks2: [10.70, 11.05], m4: [11.35, 11.90], hold: [11.90, 12.70], flip: 12.70,
  door: [12.75, 13.15], m5: [13.15, 13.70], grip: 14.30, reset: 14.55, doorDown: [14.55, 14.95] };
TA.red = [TA.fail + .03, TA.ticks2[1] + .02];                      // REVIEW light red until the second review passes
// the Lead and main (global clock): the arm serves the back line first, then the front line
const ARM = { A: { down: [8.0, 8.4], swing: [8.5, 9.4], back: [9.5, 10.1] },
  B: { down: [11.45, 11.85], swing: [11.95, 12.85], back: [12.95, 13.55] } };
const CAR = { toB: [10.2, 11.35], toA: [13.7, 14.85] };
const MOVES = [[2.0, 2.75], [5.6, 6.35], [9.7, 10.45], [14.9, 15.65]];   // A's gap waits at z=350 (6.35-9.7), B's at z=0 (10.45-14.9)
const MERGE = { A: 7.85, B: 11.3 };                                  // the operator's go-ahead, just before the Lead comes down

// ---------------------------------------------------------------- the parcel (drawn at x = 0, depth offset z0)
// PR label: grey while draft, red once Morgan requests changes, green once his review passes (and on main)
const PRC = { draft: '#6E7781', changes: '#CF222E', ready: '#1F883D' };  // filled, white text, like GitHub's state labels
const OKC = '#1F883D', KOC = '#CF222E';                              // Morgan's marks: green tick, red cross
const prLabel = (bg, cls) => `<g${cls ? ` class="a ${cls}"` : ''}><rect x="-13.5" y="-7.5" width="27" height="15" rx="4" fill="${bg}"/><text x="0" y="3.6" text-anchor="middle" class="mono" fill="#fff" font-size="10" font-weight="800">PR</text></g>`;
// modes: 'live' (label layers animate, class suffix p), 'final' (ticked, PR ready: carried or on main), 'plain'
function parcel(num, mode, z0, p = '') {
  const [fx, fy] = P(-PW / 2, TOPY, ZF + z0);
  const cx = fx + 6, cy = fy + 7;
  const tape = [P(-7, TOPY, ZF + z0), P(7, TOPY, ZF + z0), P(7, TOPY, ZF + PD + z0), P(-7, TOPY, ZF + PD + z0)];
  let s = box(-PW / 2, BH, ZF + z0, PW, PHt, PD, 'kr');
  s += `<polygon fill="#E3C38F" points="${pts(tape)}"/><rect fill="#E3C38F" x="${f2(fx + PW / 2 - 7)}" y="${f2(fy)}" width="14" height="5"/>`;
  s += `<rect fill="#fff" x="${f2(cx)}" y="${f2(cy)}" width="46" height="38" rx="2.5"/>`;
  s += `<text class="mono" fill="${INK}" x="${f2(cx + 4)}" y="${f2(cy + 10)}" font-size="9" font-weight="700">${num}</text>`;
  if (mode === 'plain') return s;
  const live = mode === 'live';
  [0, 1, 2].forEach(i => {
    const y = cy + 16 + i * 7.5, w = [24, 19, 22][i];
    s += `<g${live ? ` class="a row${i + 1}${p}" style="transform-origin:${f2(cx + 4)}px 0"` : ''}><rect x="${f2(cx + 4)}" y="${f2(y)}" width="6" height="6" rx="1.2" fill="none" stroke="${INK}" stroke-width="1.2"/><line x1="${f2(cx + 14)}" y1="${f2(y + 3)}" x2="${f2(cx + 14 + w)}" y2="${f2(y + 3)}" stroke="#C5C8D2" stroke-width="2.2" stroke-linecap="round"/></g>`;
    s += `<path${live ? ` class="a tk${i + 1}${p}"` : ''} d="M${f2(cx + 3)},${f2(y + 2.6)} l2.6,2.8 l5.4,-7" fill="none" stroke="${OKC}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="14"${live ? '' : ' stroke-dashoffset="0"'}/>`;
    if (live && p === 'A' && i === 1) s += `<g class="a x2A" style="transform-origin:${f2(cx + 7)}px ${f2(y + 3)}px"><path d="M${f2(cx + 4.3)},${f2(y + .3)} l5.4,5.4 M${f2(cx + 9.7)},${f2(y + .3)} l-5.4,5.4" stroke="${KOC}" stroke-width="1.9" stroke-linecap="round"/></g>`;
  });
  const lab = live ? `<g class="a stamp${p}">${prLabel(PRC.draft)}${p === 'A' ? prLabel(PRC.changes, 'chg' + p) : ''}${prLabel(PRC.ready, 'ready' + p)}</g>` : prLabel(PRC.ready);
  s += `<g transform="translate(${f2(fx + PW - 11)},${f2(fy + 10)}) rotate(-12)">${lab}</g>`;
  return s;
}

// ---------------------------------------------------------------- stations (v4): a column behind the belt, a violet tool arm over it
const lensRest = p => P(XS.rev - 7, 84, ZL[p] + 3);
const lampAt = (p, x) => P(x, 110.8, ZL[p] + 9);
const LAMP = { off: '#DCD8E8', o: '#F5A524', g: '#22C55E', r: '#F04438' };
const cloudAt = p => { const [fx, fy] = P(XS.dev - PW / 2, TOPY, ZF + ZL[p]); return [fx + PW / 2 + 9, fy + 9]; };
const GEAR = `<circle r="5.6" fill="none" stroke="#8069FF" stroke-width="3.4" stroke-dasharray="2.3 2.1"/><circle r="3.4" fill="#8069FF"/><circle r="1.4" fill="#fff"/>`;
const SYMS = [                                                      // [glyph, flight vector, spin]
  [`<text x="0" y="4.5" text-anchor="middle" class="mono" font-size="13" font-weight="800" fill="#5B3DF5">&lt;/&gt;</text>`, [-64, -30], -25],
  [`<text x="0" y="4.5" text-anchor="middle" class="mono" font-size="13" font-weight="800" fill="#5B3DF5">{ }</text>`, [62, -38], 20],
  [`<path d="M0 -5.5C.7 -1.2 1.2 -.7 5.5 0C1.2 .7 .7 1.2 0 5.5C-.7 1.2 -1.2 .7 -5.5 0C-1.2 -.7 -.7 -1.2 0 -5.5Z" fill="#F5A524" transform="scale(1.6)"/>`, [-24, -62], 70],
  [`<g transform="scale(1.3)">${GEAR}</g>`, [30, -64], 120],
  [`<text x="0" y="4" text-anchor="middle" class="mono" font-size="11" font-weight="800" fill="#8069FF">01</text>`, [70, 12], -15],
];
function stations(p) {                                              // the parts behind the belt
  const z0 = ZL[p];
  const column = x => box(x - 14, 0, z0 + BD + 2, 28, 104, 20, 'hs') + box(x - 10, 96, z0 + 4, 20, 8, BD + 2, 'ag');
  return column(XS.plan) + column(XS.dev) + column(XS.rev) + box(XG - 2, 0, z0 + BD + 2, 9, 100, 9, 'gt');
}
function tools(p) {                                                 // the parts over the belt (drawn after the parcel)
  const z0 = ZL[p];
  let s = '';
  { // PLAN: Sam's scanner prints the acceptance checklist
    const x = XS.plan, [fx, fy] = P(x - PW / 2, TOPY, ZF + z0), hb = [P(x - 16, 84, z0 + 16), P(x + 16, 84, z0 + 16)];
    s += `<polygon class="a fan${p}" fill="#7C66FF" fill-opacity=".16" points="${pts([hb[0], hb[1], [fx + PW + 4, fy + PHt + 2], [fx - 4, fy + PHt + 2]])}"/>`;
    s += `<g class="a scan${p}"><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="2" stroke-linecap="round"/><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="7" stroke-linecap="round" opacity=".25"/></g>`;
    s += box(x - 18, 84, z0 + 14, 36, 12, 30, 'ag');
    const e = [P(x - 13, 84, z0 + 14), P(x + 13, 84, z0 + 14)];
    s += `<line class="a emit${p}" x1="${f2(e[0][0])}" y1="${f2(e[0][1] - 1)}" x2="${f2(e[1][0])}" y2="${f2(e[1][1] - 1)}" stroke="#C9C0FF" stroke-width="2.5" stroke-linecap="round"/>`;
  }
  { // DEV: Nick's workshop. The head comes down, the parcel shakes and squashes while code and tools fly out of it,
    // then a small burst: the PR opens
    const x = XS.dev, rod = P(x, 96, z0 + 32);
    s += `<clipPath id="press${p}"><rect x="0" y="${f2(rod[1])}" width="1400" height="400"/></clipPath>`;
    s += `<g clip-path="url(#press${p})"><g class="a press${p}"><line x1="${f2(rod[0])}" y1="${f2(rod[1] - 40)}" x2="${f2(rod[0])}" y2="${f2(rod[1] + 16)}" stroke="#C9C6D6" stroke-width="6"/>${box(x - 26, 82, z0 + 12, 52, 14, 38, 'ag')}</g></g>`;
    const [cx, cy] = cloudAt(p);
    SYMS.forEach(([glyph], i) => { s += `<g transform="translate(${f2(cx)} ${f2(cy)})"><g class="a sym${i}${p}">${glyph}</g></g>`; });
    s += `<g transform="translate(${f2(cx)} ${f2(cy)})"><g class="a boom${p}" stroke="#5B3DF5" stroke-width="3" stroke-linecap="round">${[...Array(10)].map((_, k) => { const t = (k * 36 + 18) * Math.PI / 180; return `<line x1="${f2(Math.cos(t) * 50)}" y1="${f2(Math.sin(t) * 38)}" x2="${f2(Math.cos(t) * 60)}" y2="${f2(Math.sin(t) * 46)}"/>`; }).join('')}</g></g>`;
  }
  { // REVIEW: Morgan's lens reads each criterion and ticks it
    const rest = lensRest(p);
    s += `<clipPath id="lensc${p}"><rect x="0" y="${f2(P(0, 96, z0 + 4)[1])}" width="1400" height="400"/></clipPath>`;
    s += `<g clip-path="url(#lensc${p})"><g transform="translate(${f2(rest[0])} ${f2(rest[1])})"><g class="a lens${p}"><line x1="0" y1="-12" x2="0" y2="-160" stroke="#C9C6D6" stroke-width="2.6"/><circle r="12" fill="#fff" fill-opacity=".35" stroke="#8069FF" stroke-width="3.2"/><path d="M-6.5 -3.5 a7 7 0 0 1 3.5 -3.6" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/></g></g></g>`;
  }
  // every station's status light: orange in progress, green done, red error, off idle
  for (const [k, x] of [['pl', XS.plan], ['dv', XS.dev], ['rv', XS.rev]]) {
    const [lx, ly] = lampAt(p, x);
    s += box(x - 6, 104, z0 + 5, 12, 3, 9, 'gt');
    s += ['o', 'g', 'r'].map(c => `<circle class="a l${c}${k}${p}" cx="${f2(lx)}" cy="${f2(ly)}" r="36" fill="url(#g${{ o: 'A', g: 'G', r: 'R' }[c]})"/>`).join('');
    s += `<circle class="a lm${k}${p}" cx="${f2(lx)}" cy="${f2(ly)}" r="6.2" fill="${LAMP.off}"/>`;
    s += `<path d="M${f2(lx - 2.8)} ${f2(ly - 1.5)} a3.2 3.2 0 0 1 2.2 -2.2" fill="none" stroke="#fff" stroke-width="1.3" stroke-linecap="round" opacity=".85"/>`;
  }
  return s;
}

// ---------------------------------------------------------------- LGTM gate: a two-key safety gate (CI + checklist) with a hazard-striped shutter
function gate(p) {
  const z0 = ZL[p], dx = XG + 1, dw = 5, top = 92;
  let s = '';
  const cf = [P(dx, BH, z0), P(dx + dw, BH, z0), P(dx + dw, top, z0), P(dx, top, z0)];
  const cr = [P(dx + dw, BH, z0), P(dx + dw, BH, z0 + BD), P(dx + dw, top, z0 + BD), P(dx + dw, top, z0)];
  s += `<clipPath id="door${p}"><polygon points="${pts(cf)}"/><polygon points="${pts(cr)}"/></clipPath>`;
  s += `<g clip-path="url(#door${p})"><g class="a door${p}"><polygon points="${pts(cr)}" fill="url(#hz)"/><polygon points="${pts(cr)}" fill="none" stroke="${INK}" stroke-width="1.2" stroke-linejoin="round"/><polygon points="${pts(cf)}" fill="#2B2748"/></g></g>`;
  s += box(XG - 3, top, z0 - 8, 11, 8, BD + 19, 'gt');                              // beam, cantilevered from the pillar
  const lx = XG + 2.5, lz = z0 - 6;
  s += box(lx - 2, top + 8, lz + 3, 4, 2.5, 4, 'gt') + box(lx - 23, top + 10.5, lz, 46, 27, 8, 'gt');   // post + signal plate
  const [ax, ay] = P(lx - 11, top + 19, lz), [bx, by] = P(lx + 11, top + 19, lz);
  s += `<circle class="a ciGlowA${p}" cx="${f2(ax)}" cy="${f2(ay)}" r="34" fill="url(#gA)"/><circle class="a ciGlowG${p}" cx="${f2(ax)}" cy="${f2(ay)}" r="34" fill="url(#gG)"/>`;
  s += `<circle class="a glow${p}" cx="${f2(bx)}" cy="${f2(by)}" r="52" fill="url(#gG)" style="transform-box:fill-box;transform-origin:center"/><circle class="a lampR${p}" cx="${f2(bx)}" cy="${f2(by)}" r="40" fill="url(#gR)"/>`;
  const lamp = (x, y, cls, fill) => `<circle${cls ? ` class="a ${cls}"` : ''} cx="${f2(x)}" cy="${f2(y)}" r="6.8" fill="${fill}"/>`;
  s += lamp(ax, ay, '', '#4A4568') + lamp(bx, by, '', '#4A4568');
  s += lamp(ax, ay, `ciA${p}`, '#F5A524') + lamp(ax, ay, `ciG${p}`, '#22C55E') + lamp(bx, by, `lampR${p}`, '#F04438') + lamp(bx, by, `lampG${p}`, '#22C55E');
  for (const [x, y] of [[ax, ay], [bx, by]]) s += `<path d="M${f2(x - 3.4)} ${f2(y - 1.8)} a3.6 3.6 0 0 1 2.5 -2.5" fill="none" stroke="#fff" stroke-width="1.4" stroke-linecap="round" opacity=".7"/>`;
  const [t1x, t1y] = P(lx - 11, top + 30.5, lz), [t2x, t2y] = P(lx + 11, top + 33, lz);
  s += `<text x="${f2(t1x)}" y="${f2(t1y)}" text-anchor="middle" class="mono" font-size="8.5" font-weight="800" letter-spacing=".4" fill="#C9C0FF">CI</text>`;
  s += `<path d="M${f2(t2x - 4.2)} ${f2(t2y)} l2.8 2.8 l5.6 -6.2" fill="none" stroke="#C9C0FF" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>`;
  return s;
}
// ---------------------------------------------------------------- one production line
function line(p) {
  const z0 = ZL[p], num = p === 'A' ? '#143' : '#142';
  let s = '';
  s += box(INT - 36, HOIST + 10, z0 + ZC - 8, 72, 6, 16, 'st') + box(INT - 11, HOIST, z0 + ZC - 9, 22, 10, 18, 'ac');
  s += stations(p);
  s += `<polygon fill="${INK}" opacity=".07" points="${pts([P(BX0 + 6, 0, z0 - 3), P(BX1 + 8, 0, z0 - 3), P(BX1 + 24, 0, z0 + BD + 20), P(BX0 + 22, 0, z0 + BD + 20)])}"/>`;
  s += box(BX0, 0, z0, BX1 - BX0, BH, BD, 'bt');
  const topFace = [P(BX0, BH, z0), P(BX1, BH, z0), P(BX1, BH, z0 + BD), P(BX0, BH, z0 + BD)];
  let ticks = ''; for (let x = BX0 - 600 + 8; x < BX1 + 120; x += TREAD) { const a = P(x, BH, z0 + 5), b = P(x, BH, z0 + BD - 5); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="belt${p}"><polygon points="${pts(topFace)}"/></clipPath><g clip-path="url(#belt${p})"><path class="a belt${p}" d="${ticks}" stroke="#CFCADD" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  if (p === 'B') s += labels();
  const hk = P(INT, HOIST, z0 + ZC);
  s += `<g transform="translate(${f2(hk[0])} ${f2(hk[1])})"><rect class="a cable${p}" x="-.8" y="0" width="1.6" height="${HOIST - TOPY}" fill="#8C93A0" style="transform-origin:0 0"/><g class="a hook${p}"><path d="M-4.5 -2 h9 l-4.5 5 z" fill="#2B2748"/></g></g>`;
  const piv = P(0, BH, ZF + z0), topc = P(0, TOPY, ZC + z0);
  s += `<g transform="translate(${INT} 0)"><g class="a vis${p}"><g class="a mx${p}"><g class="a my${p}"><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g class="a sq${p}"><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g class="a pop${p}" style="transform-origin:${f2(topc[0])}px ${f2(topc[1])}px">${parcel(num, 'live', z0, p)}</g></g></g></g></g></g></g></g>`;
  s += tools(p) + gate(p);
  return `<g class="p${p}">${s}</g>`;
}
function labels() {
  const X = { int: INT, plan: XS.plan, dev: XS.dev, rev: XS.rev, lgtm: XG + 2.5 };
  return [['int', 'ISSUE'], ['plan', 'PLAN'], ['dev', 'DEV'], ['rev', 'REVIEW'], ['lgtm', 'LGTM']].map(([k, t]) => {
    const [x, y] = P(X[k], 5.6, 0);
    if (k === 'lgtm') return `<text class="lbl mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;   // the gate's lights speak for it
    return `<circle class="a pip-${k}" cx="${f2(x - t.length * 4.1 - 8)}" cy="${f2(y - 4)}" r="2.5" fill="#5B3DF5"/><text class="a lbl lbl-${k} mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;
  }).join('');
}

// ---------------------------------------------------------------- main lane (along z, away from us)
const MX0 = 1027, MX1 = 1097, MXC = (MX0 + MX1) / 2, PITCH = 175, MTREAD = 25;
const slotShift = n => [n * PITCH * KX, -n * PITCH * KY];
const WHO = { 0: 'A', 1: 'B' }, OTHERS = { 2: '#139', 3: '#141' };  // j mod 4: 0 = back line (#143), 1 = front line (#142), 2-3 other pipelines
const LAND = { A: 0, B: -3 };                                       // the slot index each line fills this loop
const NSTRIP = [[0, 0]];                                            // slots travelled (numeric twin of the mstrip keyframes)
{ let n = 0; for (const [a, b] of MOVES) { NSTRIP.push([a, n, E.move]); n++; NSTRIP.push([b, n]); } if (NSTRIP[NSTRIP.length - 1][0] < T) NSTRIP.push([T, n]); }
const ZCAR = [[0, ZL.A], [CAR.toB[0], ZL.A, E.io], [CAR.toB[1], ZL.B], [CAR.toA[0], ZL.B, E.io], [CAR.toA[1], ZL.A], [T, ZL.A]];
function mainLane() {
  let s = '';
  const z0 = -420, z1 = 1500;
  s += `<polygon fill="${INK}" opacity=".07" points="${pts([P(MX0 + 8, 0, z0), P(MX1 + 14, 0, z0), P(MX1 + 14, 0, z1), P(MX0 + 8, 0, z1)])}"/>`;
  s += box(MX0 - 4, 0, z0, MX1 - MX0 + 8, BH, z1 - z0, 'mn');
  const top = [P(MX0 - 4, BH, z0), P(MX1 + 4, BH, z0), P(MX1 + 4, BH, z1), P(MX0 - 4, BH, z1)];
  let ticks = ''; for (let z = z0 - 4 * PITCH; z < z1; z += MTREAD) { const a = P(MX0, BH, z), b = P(MX1, BH, z); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="mainClip"><polygon points="${pts(top)}"/></clipPath><g clip-path="url(#mainClip)"><path class="a mstrip" d="${ticks}" stroke="#D6CFEE" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  const o = P(MX1 + 4, 5, -60);
  s += `<g transform="matrix(${KX * 2} ${-KY * 2} 0 1 ${f2(o[0])} ${f2(o[1])})"><g fill="none" stroke="#5B3DF5" stroke-width="1.4" stroke-linecap="round"><circle cx="3" cy="-8" r="2"/><circle cx="3" cy="0" r="2"/><circle cx="10" cy="-6" r="2"/><path d="M3 -6 v4 M10 -4 c0 3 -4 3 -6 4"/></g><text x="16" y="1" class="mono" fill="#5B3DF5" font-size="11" font-weight="700" letter-spacing=".5">main</text></g>`;
  return s;
}
// Depth sort against the moving Lead and the gantry: a parcel on main is drawn beyond the gantry while it is past it,
// in front of the arm only while it is nearer to us (smaller z) than the carriage. A parcel that changes layer gets a copy
// in each layer it visits, switched on/off in step.
const ZG = 420;                                                     // the main sign's depth: behind both landing points and the carriage
const STRIP_J = [];
for (let j = 5; j >= -6; j--) {
  const m = mod(j, 4), who = WHO[m] || null;
  if (who && j < LAND[who]) continue;                               // still a gap: that PR has not been merged yet
  if ((j + 4) * PITCH < -400 || j * PITCH > 900) continue;          // never on screen during the loop
  const lay = [];
  for (let k = 0; k < T * 200; k++) { const t = k / 200, z = (j + valueAt(NSTRIP, t)) * PITCH; lay.push(z + ZC >= ZG ? 'far' : z < valueAt(ZCAR, t) - .5 ? 'front' : 'back'); }
  STRIP_J.push({ j, who, lay });
}
const DYN = [];                                                     // animation names created on the fly
function stepKF(name, states) {                                     // boolean samples (every 5 ms) -> opacity steps
  DYN.push(name);
  const fr = [[0, op(states[0] ? 1 : 0)]];
  for (let k = 1; k < states.length; k++) if (states[k] !== states[k - 1]) { const t = k / 200; fr.push([t - .001, op(states[k - 1] ? 1 : 0)], [t, op(states[k] ? 1 : 0)]); }
  fr.push([T, op(states[states.length - 1] ? 1 : 0)]);
  kf(name, fr);
}
function mainStrip(layer) {
  let s = '';
  for (const { j, who, lay } of STRIP_J) {
    const on = lay.map(l => l === layer);
    if (!on.some(Boolean)) continue;
    const always = on.every(Boolean), cls = `ly${{ far: 'R', back: 'B', front: 'F' }[layer]}${j + 10}`;
    if (!always) stepKF(cls, on);
    const landing = who && j === LAND[who];
    const [dx, dy] = slotShift(j), piv = P(MXC, BH, ZF);
    const body = parcel(who === 'A' ? '#143' : who === 'B' ? '#142' : OTHERS[mod(j, 4)], 'final', 0);
    s += `<g transform="translate(${f2(dx)} ${f2(dy)})"${always ? '' : ` class="a ${cls}"`}><g${landing ? ` class="a land${who}"` : ''}><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g${landing ? ` class="a msq${who}"` : ''}><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g transform="translate(${MXC} 0)">${body}</g></g></g></g></g></g>`;
  }
  return `<g class="a mstrip">${s}</g>`;
}
// the main sign: a panel hung from the ceiling by two cables over the lane (no posts: it must not read as a gate)
function gantry() {
  const sx0 = MX0 - 12, sx1 = MX1 + 10, sy0 = 96, sy1 = 124, h = sy1 - sy0;
  const [a, b] = P(sx0, sy1, ZG - 3), [c] = P(sx1, sy1, ZG - 3);
  let s = `<path d="M${f2(a + 8)} 0V${f2(b)}M${f2(c - 8)} 0V${f2(b)}" stroke="#8C93A0" stroke-width="1.6"/>`;
  s += box(sx0, sy0, ZG - 3, sx1 - sx0, h, 3, 'sg');
  s += `<g transform="translate(${f2(a)} ${f2(b)})"><g fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="${h / 2 - 6}" r="2.7"/><circle cx="11" cy="${h / 2 + 6}" r="2.7"/><circle cx="20" cy="${h / 2 - 3}" r="2.7"/><path d="M11 ${h / 2 - 3.3} v6.6 M20 ${h / 2 - .3} c0 4 -5 4 -8 5"/></g>`
    + `<text x="28" y="${h / 2 + 6.3}" class="mono" font-size="18" font-weight="800" fill="#fff">main</text>`
    + `<path d="M${sx1 - sx0 - 10} ${h / 2 - 8} v15 M${sx1 - sx0 - 15.5} ${h / 2 + 2} l5.5 6 l5.5 -6" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/></g>`;
  return s;
}

// ---------------------------------------------------------------- the Lead: one arm on a carriage riding an endless depth rail
const XA = 952, L1 = 70, L2 = 64, GRIP = 19;
function ik(sh, [tx_, ty_], prefer) {
  const wx = tx_, wy = ty_ - GRIP, dx = wx - sh[0], dy = wy - sh[1], d = Math.hypot(dx, dy);
  const c = Math.max(-1, Math.min(1, (d * d - L1 * L1 - L2 * L2) / (2 * L1 * L2)));
  const t2 = prefer * Math.acos(c), t1 = Math.atan2(dy, dx) - Math.atan2(L2 * Math.sin(t2), L1 + L2 * Math.cos(t2));
  return { t1: t1 * 180 / Math.PI, t2: t2 * 180 / Math.PI };
}
const near = (a, ref) => a + 360 * Math.round((ref - a) / 360);
const SH = P(XA, 46, ZC);                                           // drawn in the front line's plane; the carriage moves it
const POSE = (() => {
  const pick = P(XS.pick, TOPY, ZC), place = P(MXC, TOPY, ZC), home = [SH[0] + 6, pick[1] - 14];
  const pose = { home: ik(SH, home, -1), pick: ik(SH, pick, -1), place: ik(SH, place, 1) };
  for (const k of ['pick', 'place']) pose[k].t1 = near(pose[k].t1, pose.home.t1);
  return pose;
})();
const RZ = [-420, 1500];                                            // the rail runs the whole depth, like main
function rail() {
  const a = P(XA - 12, 2.5, RZ[0]), b = P(XA - 12, 2.5, RZ[1]), c = P(XA + 12, 2.5, RZ[0]), d = P(XA + 12, 2.5, RZ[1]);
  let sl = ''; for (let z = RZ[0]; z < RZ[1]; z += 44) { const u = P(XA - 16, 2.5, z), v = P(XA + 16, 2.5, z); sl += `M${f2(u[0])} ${f2(u[1])}L${f2(v[0])} ${f2(v[1])}`; }
  return box(XA - 17, 0, RZ[0], 34, 2.5, RZ[1] - RZ[0], 'st')
    + `<path d="${sl}" stroke="#DAD6E4" stroke-width="2"/>`
    + `<path d="M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}M${f2(c[0])} ${f2(c[1])}L${f2(d[0])} ${f2(d[1])}" stroke="#B3ADC8" stroke-width="2" stroke-linecap="round"/>`;
}
function lead() {
  const cap = (len, th) => `<rect x="${-th / 2}" y="${-th / 2}" width="${len + th}" height="${th}" rx="${th / 2}" fill="#2B2748"/>`;
  const joint = r => `<circle r="${r}" fill="#8069FF"/><circle r="${r * .34}" fill="#2B2748"/>`;
  const topC = P(0, TOPY, ZC);
  const card = ['B', 'A'].map(p => `<g class="a carry${p}"><g transform="translate(${f2(-topC[0])} ${f2(GRIP - topC[1])})">${parcel(p === 'A' ? '#143' : '#142', 'final', 0)}</g></g>`).join('');
  const grip = `<rect x="-3" y="0" width="6" height="${GRIP - 5}" fill="#2B2748"/><rect x="-13" y="${GRIP - 6}" width="26" height="6" rx="2" fill="#8069FF"/>${joint(6.5)}`;
  const chain = (links, hand) => `<g transform="translate(${f2(SH[0])} ${f2(SH[1])})"><g class="a sh">${links ? cap(L1, 15) + `<line x1="4" y1="-5" x2="${L1 - 4}" y2="-5" stroke="#4A4478" stroke-width="2" stroke-linecap="round"/>` : ''}
      <g transform="translate(${L1} 0)"><g class="a el">${links ? cap(L2, 12) + `<line x1="4" y1="-4" x2="${L2 - 4}" y2="-4" stroke="#4A4478" stroke-width="1.8" stroke-linecap="round"/>` : ''}
        <g transform="translate(${L2} 0)"><g class="a wr">${hand}</g></g>${links ? joint(7.5) : ''}</g></g>${links ? joint(9) : ''}</g></g>`;
  const [lx, ly] = P(XA, 5, 10);
  const base = `<polygon fill="${INK}" opacity=".1" points="${pts([P(XA - 26, 2.5, 6), P(XA + 30, 2.5, 6), P(XA + 36, 2.5, 62), P(XA - 20, 2.5, 62)])}"/>`
    + box(XA - 22, 2.5, 10, 44, 12, 44, 'ac') + box(XA - 11, 14.5, 21, 22, 31.5, 22, 'ac')
    + `<text x="${f2(lx)}" y="${f2(ly + 1.5)}" text-anchor="middle" class="mono" fill="#C9C0FF" font-size="7.5" font-weight="700" letter-spacing="1">LEAD</text>`;
  return `<g class="a car">${base}${chain(true, '')}${chain(false, card)}${chain(false, grip)}</g>`;   // links, then the parcel, then the gripper
}

// ---------------------------------------------------------------- floor, brand, the human operator
function floor() {
  const a = P(330, 0, -120), b = P(1330, 0, -120), c = P(1330, 0, 820), d = P(330, 0, 820);
  let g = `<polygon points="${pts([a, b, c, d])}" fill="url(#floorG)"/>`;
  for (const z of [-60, 150, 300, 480]) { const l = P(340, 0, z), r = P(1330, 0, z); g += `<line x1="${f2(l[0])}" y1="${f2(l[1])}" x2="${f2(r[0])}" y2="${f2(r[1])}" stroke="#E9E6EF" stroke-width="1"/>`; }
  return g;
}
const LOGO_Y = OPT.logoY ?? 92;
function brand() {
  return `<g transform="translate(48 ${LOGO_Y})"><g transform="translate(44 44)">
    <rect class="a halo" x="-44" y="-44" width="88" height="88" rx="22" fill="none" stroke="#22C55E" stroke-width="2"/>
    <g class="a bump"><rect x="-44" y="-44" width="88" height="88" rx="22" fill="${INK}"/><rect x="-32" y="-32" width="64" height="64" rx="13" fill="#0B0A18"/>
      <rect class="a sglow" x="-32" y="-32" width="64" height="64" rx="13" fill="url(#gS)"/>
      <path d="M-13 -5 l9 9 l17 -18" fill="none" stroke="#3DDC84" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
      <text x="0" y="21" text-anchor="middle" class="mono" font-size="9.5" font-weight="700" letter-spacing="2" fill="#3DDC84">LGTM</text></g></g></g>
  <text x="152" y="${LOGO_Y + 44}" class="wm"><tspan fill="#5B3FE0">lgtm</tspan><tspan fill="${INK}">gate</tspan></text>
  <text x="153" y="${LOGO_Y + 70}" class="tag">Merge gate for</text><text x="153" y="${LOGO_Y + 89}" class="tag">agent-generated pull requests</text>`;
}
// the operator, next to the belts: one schematic row per workflow in progress, its four steps lit like the stations
// (orange in progress, green done, red error), then the MERGE go-ahead the human gives before the Lead merges
const VX = OPT.opX ?? 196, VY = OPT.opY ?? 334;
const V = (x, y, z) => [VX + x + z * KX, VY - y - z * KY];
const vbox = (x, y, z, w, h, d, m) => {
  const f = [V(x, y, z), V(x + w, y, z), V(x + w, y + h, z), V(x, y + h, z)];
  const t = [V(x, y + h, z), V(x + w, y + h, z), V(x + w, y + h, z + d), V(x, y + h, z + d)];
  const r = [V(x + w, y, z), V(x + w, y, z + d), V(x + w, y + h, z + d), V(x + w, y + h, z)];
  return `<polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/>`;
};
const MON = { x: 18, y: 36, z: 22, w: 112, h: 58 };
const DISP = (() => { const [x, y] = V(MON.x, MON.y + MON.h, MON.z); return { x: x + 4, y: y + 4, w: MON.w - 8, h: MON.h - 8 }; })();
const ROWY = { A: 19, B: 37 };                                      // back line on top, as in the scene
const NODE_X = [12, 30, 48, 66];                                    // PLAN, DEV, REVIEW, LGTM
function operator() {
  let s = `<polygon fill="${INK}" opacity=".06" points="${pts([V(-8, 0, -34), V(140, 0, -34), V(150, 0, 48), V(2, 0, 48)])}"/>`;
  for (const [x, z] of [[4, 32], [124, 32], [4, 3], [124, 3]]) s += vbox(x, 0, z, 4, 22, 4, 'st');
  s += vbox(0, 22, 0, 132, 4, 40, 'st');                                               // desk top
  s += vbox(66, 26, 28, 16, 2.5, 10, 'dk') + vbox(71, 28.5, 32, 6, 7.5, 4, 'dk');      // monitor foot + neck
  s += vbox(MON.x, MON.y, MON.z, MON.w, MON.h, 5, 'dk');
  const d = DISP;
  s += `<rect x="${f2(d.x)}" y="${f2(d.y)}" width="${d.w}" height="${d.h}" rx="3" fill="#0B0A18"/>`;
  s += `<g transform="translate(${f2(d.x)} ${f2(d.y)})"><text x="6" y="9" class="mono" font-size="5.4" font-weight="700" letter-spacing=".4" fill="#8E89B0">IN PROGRESS</text>`;
  const pill = (y, fill, t) => `<rect x="76" y="${y - 5}" width="24" height="10" rx="5" fill="${fill}"/><text x="88" y="${y + 1.7}" text-anchor="middle" class="mono" font-size="4.8" font-weight="800" fill="#fff">${t}</text>`;
  for (const p of ['A', 'B']) {
    const y = ROWY[p];
    s += `<g class="p${p}"><g class="a rv${p}"><line x1="${NODE_X[0]}" y1="${y}" x2="${NODE_X[3]}" y2="${y}" stroke="#2E2A4A" stroke-width="2.4" stroke-linecap="round"/>`
      + ['pl', 'dv', 'rv', 'lg'].map((k, i) => `<circle class="a nd${k}${p}" cx="${NODE_X[i]}" cy="${y}" r="4.4" fill="#3A3657"/>`).join('')
      + `<rect x="76" y="${y - 5}" width="24" height="10" rx="5" fill="none" stroke="#4A4568" stroke-width=".9"/><text x="88" y="${y + 1.7}" text-anchor="middle" class="mono" font-size="4.8" font-weight="800" fill="#6E6A8A">MERGE</text>`
      + `<g class="a mg${p}">${pill(y, '#1F883D', 'MERGE')}</g><g class="a mgd${p}">${pill(y, '#1F883D', 'MERGED')}</g></g></g>`;
  }
  s += `</g>`;
  // the operator, seen from behind, headset on
  const [hx, hy] = V(2, 66, -16);
  s += `<g transform="translate(${f2(hx)} ${f2(hy)}) scale(.72)">
    <rect x="-21" y="12" width="42" height="40" rx="13" fill="#6D5BD8"/><path d="M-9 12 q9 7 18 0 v4 q-9 6 -18 0 z" fill="#5B49C6"/>
    <rect x="-17" y="27" width="34" height="37" rx="7" fill="#35305A"/><rect x="-2" y="64" width="4" height="12" fill="#2B2748"/><rect x="-14" y="75" width="28" height="3.5" rx="1.75" fill="#2B2748"/>
    <circle r="11" fill="#2B2748"/><path d="M-11.5 -1 a11.5 11.5 0 0 1 23 0" fill="none" stroke="#B6AAFF" stroke-width="2.4"/>
    <rect x="-14" y="-4.5" width="5" height="10" rx="2.2" fill="#8069FF"/><rect x="9" y="-4.5" width="5" height="10" rx="2.2" fill="#8069FF"/>
    <path d="M12 4.5 q6 3 3.5 9.5" fill="none" stroke="#8069FF" stroke-width="1.8" stroke-linecap="round"/></g>`;
  return s;
}

// ---------------------------------------------------------------- animations shared by both lines (each on its own clock)
const stampsOf = t => t.stamp2 ? [t.stamp, t.stamp2] : [t.stamp];
function lineKF(p, t) {
  const cable0 = f2((HOIST - TOPY - DROP) / (HOIST - TOPY));
  kf(`cable${p}`, [[0, `transform:scaleY(${cable0})`], [t.drop[0], `transform:scaleY(${cable0})`, E.drop], [t.drop[1], 'transform:scaleY(1)'], [t.drop[1] + .15, 'transform:scaleY(1)', E.out], [t.drop[1] + .7, `transform:scaleY(${cable0})`], [T, `transform:scaleY(${cable0})`]]);
  kf(`hook${p}`, [[0, ty(HOIST - TOPY - DROP)], [t.drop[0], ty(HOIST - TOPY - DROP), E.drop], [t.drop[1], ty(HOIST - TOPY)], [t.drop[1] + .15, ty(HOIST - TOPY), E.out], [t.drop[1] + .7, ty(HOIST - TOPY - DROP)], [T, ty(HOIST - TOPY - DROP)]]);
  kf(`fan${p}`, [[0, op(0)], [t.plan[0] + .05, op(0)], [t.plan[0] + .2, op(1)], [t.plan[1] - .15, op(1)], [t.plan[1], op(0)], [T, op(0)]]);
  kf(`emit${p}`, [[0, op(.25)], [t.plan[0], op(.25)], [t.plan[0] + .15, op(1)], [t.plan[1] - .1, op(1)], [t.plan[1], op(.25)], [T, op(.25)]]);
  const r = t.rows;
  kf(`scan${p}`, [[0, `${ty(0)};opacity:0`], [t.plan[0] + .18, `${ty(0)};opacity:0`], [t.plan[0] + .2, `${ty(0)};opacity:1`, E.io], [r[1] + .05, `${ty(PHt - 2)};opacity:1`, E.io], [t.plan[1] - .15, `${ty(0)};opacity:1`], [t.plan[1] - .05, `${ty(0)};opacity:0`], [T, `${ty(0)};opacity:0`]]);
  r.forEach((x, i) => kf(`row${i + 1}${p}`, [[0, 'opacity:0;transform:scaleX(0)'], [x, 'opacity:0;transform:scaleX(0)', E.out], [x + .22, 'opacity:1;transform:scaleX(1)'], [t.reset, 'opacity:1;transform:scaleX(1)'], [t.reset + .001, 'opacity:0;transform:scaleX(0)'], [T, 'opacity:0;transform:scaleX(0)']]));
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
  // Nick's workshop: the head dives into a cartoon work cloud that boils while code and tools fly out; it pops, the PR opens
  const pr = [[0, ty(0)]], bm = [[0, 'opacity:0;transform:scale(.6)']];
  const sy = SYMS.map(() => [[0, 'opacity:0;transform:translate(0px,0px) scale(.3) rotate(0deg)']]);
  t.work.forEach(([w0, w1], k) => {
    const st0 = stampsOf(t)[k];
    pr.push([w0 - .2, ty(0), E.out], [w0, ty(4)]);
    for (let x = w0 + .12, i = 0; x < w1 - .06; x += .12, i++) pr.push([x, ty(i % 2 ? 4 : 2.5)]);
    pr.push([w1, ty(4), E.out], [st0 - .08, ty(-4), E.slam], [st0, ty(10)], [st0 + .15, ty(10), E.out], [st0 + .55, ty(0)]);
    sy.forEach((a, i) => {
      const [v, spin] = [SYMS[i][1], SYMS[i][2]];
      for (const off of [.18 + i * .11, .18 + i * .11 + (w1 - w0) * .5]) {
        const x = w0 + off; if (x + .62 > st0) continue;
        a.push([x, 'opacity:0;transform:translate(0px,0px) scale(.3) rotate(0deg)', E.out], [x + .14, `opacity:1;transform:translate(${f2(v[0] * .4)}px,${f2(v[1] * .4)}px) scale(1.3) rotate(${spin / 3}deg)`, E.out], [x + .45, `opacity:1;transform:translate(${f2(v[0] * .85)}px,${f2(v[1] * .85)}px) scale(1.1) rotate(${f2(spin * .8)}deg)`], [x + .62, `opacity:0;transform:translate(${v[0]}px,${v[1]}px) scale(.9) rotate(${spin}deg)`]);
      }
    });
    bm.push([st0 - .1, 'opacity:0;transform:scale(.6)', E.out], [st0 - .02, 'opacity:1;transform:scale(1)'], [st0 + .22, 'opacity:0;transform:scale(1.35)']);
  });
  pr.push([T, ty(0)]); bm.push([T, 'opacity:0;transform:scale(1.35)']);
  kf(`press${p}`, pr); kf(`boom${p}`, bm);
  sy.forEach((a, i) => kf(`sym${i}${p}`, [...a, [T, 'opacity:0;transform:translate(0px,0px) scale(.3) rotate(0deg)']]));
  // the gate: CI light (amber while CI runs, green once it passes) and checklist light (red while held, green on LGTM)
  const ciA = [[0, op(0)]], ciG = [[0, op(0)]];
  t.ci.forEach(([a, b], k) => {
    ciA.push([a - .001, op(0)], [a, op(1)]);
    for (let x = a + .35, i = 0; x < b - .1; x += .35, i++) ciA.push([x, op(i % 2 ? 1 : .35), E.io]);
    ciA.push([b - .001, op(1)], [b, op(0)]);
    ciG.push([a - .001, op(k ? 1 : 0)], [a, op(0)], [b - .001, op(0)], [b, op(1)]);
  });
  ciG.push([t.reset, op(1)], [t.reset + .001, op(0)], [T, op(0)]); ciA.push([T, op(0)]);
  kf(`ciA${p}`, ciA); kf(`ciG${p}`, ciG);
  kf(`ciGlowA${p}`, ciA.map(([x, css, e]) => [x, css.replace(/opacity:([\d.]+)/, (m0, v) => `opacity:${f2(v * .8)}`), e]));
  kf(`ciGlowG${p}`, ciG.map(([x, css, e]) => [x, css.replace(/opacity:([\d.]+)/, (m0, v) => `opacity:${f2(v * .6)}`), e]));
  kf(`door${p}`, [[0, ty(0)], [t.door[0], ty(0), E.out], [t.door[1], ty(-74)], [t.doorDown[0], ty(-74), E.io], [t.doorDown[1], ty(0)], [T, ty(0)]]);
  kf(`lampR${p}`, [[0, op(0)], [t.hold[0], op(0)], [t.hold[0] + .03, op(1)], [t.hold[0] + .23, op(.2)], [t.hold[0] + .4, op(1)], [t.hold[0] + .57, op(.2)], [t.hold[0] + .74, op(1)], [t.flip, op(0)], [T, op(0)]]);
  kf(`lampG${p}`, [[0, op(0)], [t.flip - .01, op(0)], [t.flip + .03, op(1)], [t.reset, op(1)], [t.reset + .3, op(0)], [T, op(0)]]);
  kf(`glow${p}`, [[0, 'opacity:0;transform:scale(.5)'], [t.flip, 'opacity:0;transform:scale(.5)', E.out], [t.flip + .3, 'opacity:1;transform:scale(1.25)', E.io], [t.flip + .85, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .3, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .6, 'opacity:0;transform:scale(.8)'], [T, 'opacity:0;transform:scale(.8)']]);
  // station lights: orange in progress, green done (on to the next step), red error, off idle; the monitor mirrors them
  const merge = loc(p, MERGE[p]), merged = loc(p, ARM[p].swing[1]);
  const L = p === 'B'
    ? { pl: [[t.plan[0], t.plan[1], 'o'], [t.plan[1], t.m2[1], 'g']], dv: [[t.m2[1], t.stamp, 'o'], [t.stamp, t.m3[1], 'g']],
        rv: [[t.read[0], t.ticks[2], 'o'], [t.ticks[2], t.m4[1], 'g']], lg: [[t.hold[0], t.flip, 'o'], [t.flip, merged, 'g']] }
    : { pl: [[t.plan[0], t.plan[1], 'o'], [t.plan[1], t.m2[1], 'g']],
        dv: [[t.m2[1], t.stamp, 'o'], [t.stamp, t.m3[1], 'g'], [t.back[1], t.stamp2, 'o'], [t.stamp2, t.m3b[1], 'g']],
        rv: [[t.read1[0], t.fail, 'o'], [t.fail, t.read2[0], 'r'], [t.read2[0], t.ticks2[1], 'o'], [t.ticks2[1], t.m4[1], 'g']],
        lg: [[t.hold[0], t.flip, 'o'], [t.flip, merged, 'g']] };
  const fillKF = (segs, off) => {
    const ev = [];
    segs.forEach(([a, b, c], i) => { ev.push([a, LAMP[c]]); const nx = segs[i + 1]; if (!nx || Math.abs(nx[0] - b) > 1e-6) ev.push([b, off]); });
    const fr = [[0, `fill:${off}`]]; let cur = off;
    for (const [x, col] of ev) { fr.push([x - .001, `fill:${cur}`], [x, `fill:${col}`]); cur = col; }
    fr.push([T, `fill:${cur}`]); return fr;
  };
  const glowKF = (segs, c) => {
    const fr = [[0, op(0)]];
    for (const [a, b, cc] of segs) if (cc === c) {
      fr.push([a - .001, op(0)], [a + .08, op(1)]);
      if (c !== 'g') for (let x = a + .45, i = 0; x < b - .2; x += .45, i++) fr.push([x, op(i % 2 ? 1 : .45), E.io]);
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
lineKF('B', TB); lineKF('A', TA);
const SQ = (p, events, wobble = []) => {
  const one = 'transform:scale(1,1) rotate(0deg)', fr = [[0, one]];
  const all = [...events.map(([at, k]) => ({ at, k })), ...wobble.map(([at, b]) => ({ at, b }))].sort((x, y) => x.at - y.at);
  for (const e of all) {
    if (e.b === undefined) fr.push([e.at - .02, one], [e.at + .05, `transform:scale(${1 + .06 * e.k},${1 - .12 * e.k}) rotate(0deg)`, E.out], [e.at + .2, `transform:scale(${1 - .015 * e.k},${1 + .03 * e.k}) rotate(0deg)`], [e.at + .36, one]);
    else {                                                           // the parcel shakes, squashes and stretches while Nick works on it
      fr.push([e.at, one]);
      for (let x = e.at + .09, i = 0; x < e.b - .05; x += .09, i++) fr.push([x, i % 2 ? 'transform:scale(.93,1.08) rotate(2.6deg)' : 'transform:scale(1.08,.9) rotate(-2.6deg)', E.io]);
      fr.push([e.b, one]);
    }
  }
  fr.push([T, one]); kf(`sq${p}`, fr);
};
const tickKF = (name, x, reset) => kf(name, [[0, 'stroke-dashoffset:14'], [x - .12, 'stroke-dashoffset:14', E.out], [x + .02, 'stroke-dashoffset:0'], [reset, 'stroke-dashoffset:0'], [reset + .001, 'stroke-dashoffset:14'], [T, 'stroke-dashoffset:14']]);
const lensGeo = p => {
  const [fx, fy] = P(XS.rev - PW / 2, TOPY, ZF + ZL[p]), lr = lensRest(p);
  return { r: i => fy + 7 + 16 + i * 7.5 + 3 - lr[1], x0: fx + 6 + 7 - lr[0], x1: fx + 6 + 36 - lr[0] };
};
// front line B: the happy path
{
  const t = TB, p = 'B';
  const fwd = [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...t.m4, DX[4]], [...t.m5, DX[5]]];
  const tail = fr => [...fr.filter(f => f[0] < t.reset), [t.reset, tx(DX[5])], [t.reset + .001, tx(0)], [T, tx(0)]];
  kf(`mx${p}`, tail(moves(0, fwd, tx))); kf(`belt${p}`, tail(moves(0, fwd, tx)));
  kf(`my${p}`, [[0, ty(-DROP)], [t.drop[0], ty(-DROP), E.drop], [t.drop[1], ty(0)], [t.reset, ty(0)], [t.reset + .001, ty(-DROP)], [T, ty(-DROP)]]);
  kf(`vis${p}`, [[0, op(0)], [t.pop[0] - .001, op(0)], [t.pop[0], op(1)], [t.grip - .001, op(1)], [t.grip, op(0)], [T, op(0)]]);
  kf(`pop${p}`, [[0, 'transform:scale(0)'], [t.pop[0], 'transform:scale(0)', E.back], [t.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1]], t.work);
  t.ticks.forEach((x, i) => tickKF(`tk${i + 1}${p}`, x, t.reset));
  const { r, x0, x1 } = lensGeo(p), k = t.ticks;
  kf(`lens${p}`, [[0, txy(0, 0)], [t.read[0], txy(0, 0), E.out], [t.read[0] + .2, txy(x0, r(0)), E.io], [k[0], txy(x1, r(0)), E.io], [k[0] + .1, txy(x0, r(1)), E.io], [k[1], txy(x1, r(1)), E.io],
    [k[1] + .1, txy(x0, r(2)), E.io], [k[2], txy(x1, r(2)), E.out], [t.read[1], txy(0, 0)], [T, txy(0, 0)]]);
}
// back line A: the review fails once, the workflow runs the belt back to DEV, Nick fixes and pushes, it passes
{
  const t = TA, p = 'A';
  const cardX = [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...t.back, DX[2]], [...t.m3b, DX[3]], [...t.m4, DX[4]], [...t.m5, DX[5]]];
  kf(`mx${p}`, [...moves(0, cardX, tx).filter(f => f[0] < t.reset), [t.reset, tx(DX[5])], [t.reset + .001, tx(0)], [T, tx(0)]]);
  kf(`belt${p}`, moves(0, cardX, tx));                                                  // net 480 = 24 treads per loop
  kf(`my${p}`, [[0, ty(-DROP)], [t.drop[0], ty(-DROP), E.drop], [t.drop[1], ty(0)], [t.reset, ty(0)], [t.reset + .001, ty(-DROP)], [T, ty(-DROP)]]);
  kf(`vis${p}`, [[0, op(1)], [t.grip - .001, op(1)], [t.grip, op(0)], [T, op(0)]]);        // back on at the loop boundary, while pop is at scale 0
  kf(`pop${p}`, [[0, 'transform:scale(0)', E.back], [t.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1], [t.stamp2, 1.1]], t.work);
  [t.tick1, ...t.ticks2].forEach((x, i) => tickKF(`tk${i + 1}${p}`, x, t.reset));
  const { r, x0, x1 } = lensGeo(p), k = t.ticks2;
  kf(`lens${p}`, [[0, txy(0, 0)], [t.read1[0], txy(0, 0), E.out], [t.read1[0] + .2, txy(x0, r(0)), E.io], [t.tick1, txy(x1, r(0)), E.io], [t.tick1 + .1, txy(x0, r(1)), E.io], [t.fail, txy(x1, r(1))],
    [t.fail + .1, txy(x1, r(1)), E.io], [t.read1[1], txy(0, 0)],
    [t.read2[0], txy(0, 0), E.out], [t.read2[0] + .2, txy(x0, r(1)), E.io], [k[0], txy(x1, r(1)), E.io], [k[0] + .1, txy(x0, r(2)), E.io], [k[1], txy(x1, r(2)), E.out], [t.read2[1], txy(0, 0)], [T, txy(0, 0)]]);
}
// the Lead (global clock): one arm, one carriage; it serves the back line, then the front line
{
  const seq = sel => {
    const fr = [[0, rot(sel(POSE.home))]];
    for (const p of ['A', 'B']) { const a = ARM[p]; fr.push([a.down[0], rot(sel(POSE.home)), E.io], [a.down[1], rot(sel(POSE.pick))], [a.swing[0], rot(sel(POSE.pick)), E.io], [a.swing[1], rot(sel(POSE.place))], [a.back[0], rot(sel(POSE.place)), E.io], [a.back[1], rot(sel(POSE.home))]); }
    fr.push([T, rot(sel(POSE.home))]); return fr;
  };
  kf('sh', seq(q => q.t1)); kf('el', seq(q => q.t2)); kf('wr', seq(q => -(q.t1 + q.t2)));
  for (const p of ['A', 'B']) {
    const a = ARM[p], rel = a.swing[1];
    kf(`carry${p}`, [[0, op(0)], [a.down[1] - .001, op(0)], [a.down[1], op(1)], [rel - .001, op(1)], [rel, op(0)], [T, op(0)]]);
    kf(`land${p}`, [[0, op(0)], [rel - .001, op(0)], [rel, op(1)], [T, op(1)]]);
    kf(`msq${p}`, [[0, 'transform:scale(1,1)'], [rel, 'transform:scale(1,1)'], [rel + .06, 'transform:scale(1.05,.92)', E.out], [rel + .24, 'transform:scale(.99,1.02)'], [rel + .4, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
  }
  kf('car', ZCAR.map(([t, z, e]) => [t, txy(z * KX, -z * KY), e]));
  kf('mstrip', NSTRIP.map(([t, n, e]) => [t, txy(...slotShift(n)), e]));
}
// labels (front line clock) + logo pulses on both verdicts (global clock)
{
  const DIM = '#55506F', t = TB;
  const lbl = (k, a, b, col = INK) => kf(`lbl-${k}`, [[0, `fill:${DIM}`], [a - .1, `fill:${DIM}`], [a, `fill:${col}`], [b, `fill:${col}`], [b + .1, `fill:${DIM}`], [T, `fill:${DIM}`]]);
  const pip = (k, a, b) => kf(`pip-${k}`, [[0, op(0)], [a - .1, op(0)], [a, op(1)], [b, op(1)], [b + .1, op(0)], [T, op(0)]]);
  lbl('int', t.pop[0], t.m1[0]); pip('int', t.pop[0], t.m1[0]);
  lbl('plan', ...t.plan); pip('plan', ...t.plan); lbl('dev', t.m2[1], t.m3[0]); pip('dev', t.m2[1], t.m3[0]); lbl('rev', ...t.read); pip('rev', ...t.read);
  const flips = [glob('B', TB.flip), glob('A', TA.flip)].sort((x, y) => x - y);
  const halo = [[0, 'opacity:0;transform:scale(1.45)']], bump = [[0, 'transform:scale(1)']], glow = [[0, op(.35)]];
  flips.forEach(f => { halo.push([f, 'opacity:0;transform:scale(1)'], [f + .01, 'opacity:.8;transform:scale(1)', E.out], [f + 1.1, 'opacity:0;transform:scale(1.45)']); bump.push([f, 'transform:scale(1)', E.out], [f + .12, 'transform:scale(1.06)', E.back], [f + .6, 'transform:scale(1)']); glow.push([f, op(.35)], [f + .1, op(1)], [f + 1.4, op(.35)]); });
  halo.push([T, 'opacity:0;transform:scale(1.45)']); bump.push([T, 'transform:scale(1)']); glow.push([T, op(.35)]);
  kf('halo', halo); kf('bump', bump); kf('sglow', glow);
}

// ---------------------------------------------------------------- assemble
// painter's order: brand + operator, rail, back line, main (parcels behind the Lead), front line, the Lead, main (parcels in front)
const BODY = [floor(), `<g>${brand()}</g>`, operator(), `<g mask="url(#railMask)">${rail()}</g>`, line('A'),
  `<g mask="url(#mainMask)">${mainLane()}${mainStrip('far')}</g>`, gantry(), mainStrip('back'), line('B'), lead(), mainStrip('front'),
  `<rect x="980" y="${H - 22}" width="${W - 980}" height="22" fill="url(#nearFade)"/>`];
const per = ['cable', 'hook', 'fan', 'emit', 'scan', 'row1', 'row2', 'row3', 'stamp', 'ready', 'press', 'boom',
  ...SYMS.map((_, i) => `sym${i}`),
  'lens', 'door', 'lampR', 'lampG', 'glow', 'ciA', 'ciG', 'ciGlowA', 'ciGlowG', 'mx', 'belt', 'my', 'vis', 'pop', 'sq', 'tk1', 'tk2', 'tk3',
  ...['pl', 'dv', 'rv'].flatMap(k => [`lm${k}`, `lo${k}`, `lg${k}`, `lr${k}`]), ...['pl', 'dv', 'rv', 'lg'].map(k => `nd${k}`), 'rv', 'mg', 'mgd'];
const names = [...per.flatMap(n => [n + 'A', n + 'B']), 'sh', 'el', 'wr', 'carryA', 'carryB', 'landA', 'landB', 'msqA', 'msqB', 'car', 'mstrip',
  'halo', 'bump', 'sglow', ...['int', 'plan', 'dev', 'rev'].flatMap(k => [`lbl-${k}`, `pip-${k}`]), 'chgA', 'x2A', ...DYN];
const css = `
.a{animation-duration:${T}s;animation-iteration-count:infinite;animation-fill-mode:both;animation-delay:${f2(-mod(COLD, T))}s}
.pA .a{animation-delay:${f2(-mod(COLD - SHIFT.A, T))}s}.pB .a{animation-delay:${f2(-mod(COLD - SHIFT.B, T))}s}
.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.wm{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:42px;font-weight:700;letter-spacing:-1.5px}
.tag{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:14.5px;fill:#5B6472}
.lbl{font-size:12px;font-weight:600;letter-spacing:1.4px;fill:#55506F}
.mgA,.mgB{transform-box:fill-box;transform-origin:center}
${names.map(n => `.${n}{animation-name:${n}}`).join('')}
@media (prefers-reduced-motion:reduce){.a{animation-play-state:paused}}
`;
const [rm0, rm1] = [P(XA, 0, 470), P(XA, 0, 700)];
const defs = `<defs>
  <radialGradient id="gG"><stop offset="0" stop-color="#22C55E" stop-opacity=".5"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <radialGradient id="gR"><stop offset="0" stop-color="#F04438" stop-opacity=".42"/><stop offset="1" stop-color="#F04438" stop-opacity="0"/></radialGradient>
  <radialGradient id="gV"><stop offset="0" stop-color="#8069FF" stop-opacity=".38"/><stop offset="1" stop-color="#8069FF" stop-opacity="0"/></radialGradient>
  <radialGradient id="gA"><stop offset="0" stop-color="#F5A524" stop-opacity=".45"/><stop offset="1" stop-color="#F5A524" stop-opacity="0"/></radialGradient>
  <radialGradient id="gS" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#22C55E" stop-opacity=".45"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <linearGradient id="floorG" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#ECE9F1"/><stop offset="1" stop-color="#ECE9F1" stop-opacity="0"/></linearGradient>
  <linearGradient id="nearFade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
  <linearGradient id="railMaskG" gradientUnits="userSpaceOnUse" x1="${f2(rm0[0])}" y1="${f2(rm0[1])}" x2="${f2(rm1[0])}" y2="${f2(rm1[1])}"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>
  <mask id="railMask" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="url(#railMaskG)"/></mask>
  <linearGradient id="mainMaskG" gradientUnits="userSpaceOnUse" x1="${f2(P(MXC, 40, 470)[0])}" y1="${f2(P(MXC, 40, 470)[1])}" x2="${f2(P(MXC, 40, 680)[0])}" y2="${f2(P(MXC, 40, 680)[1])}"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>
  <mask id="mainMask" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="url(#mainMaskG)"/></mask>
  <pattern id="hz" patternUnits="userSpaceOnUse" width="8" height="8" patternTransform="rotate(45)"><rect width="8" height="8" fill="${HZ_Y}"/><rect width="4" height="8" fill="${INK}"/></pattern>
</defs>`;
const svg = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="lgtmgate: two production lines, one behind the other. Each station has a status light: orange while it works, green when done, red on an error. One station prints the acceptance checklist; at the development station the parcel shakes while code flies out of it, then a grey draft PR label appears; the review station ticks each criterion in green. On the back line one criterion gets a red cross, the station light and the PR label turn red, the belt carries the parcel back to be fixed, CI runs again and the second review passes: the label turns green. The LGTM gate opens only when its CI and checklist lights are both green. A human operator next to the belts watches one row per workflow and presses MERGE; a single Lead arm on an endless rail then sets each pull request on the main lane, under a gantry sign reading main, among pull requests from other pipelines.">
<style>${css}${KF.join('\n')}</style>
${defs}
<rect width="${W}" height="${H}" fill="${BG}"/>
${BODY.join('\n')}
</svg>`;
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>lgtmgate header v8</title>
<style>html,body{margin:0;background:#ECEBF0}main{max-width:1280px;margin:0 auto;padding:40px 16px 56px}
.frame{border-radius:20px;overflow:hidden;box-shadow:0 1px 0 rgba(17,19,24,.04),0 12px 40px -12px rgba(17,19,24,.18)}
.frame svg{display:block;width:100%;height:auto}
p{font:13px -apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif;color:#5B6472;margin:14px 4px 0}</style></head>
<body><main><div class="frame">
<!-- Generated by gen-header-v8.mjs. One self-contained <svg>: CSS keyframes only, no JS, no web font. -->
${svg}
</div><p>Mockup v8 · 1280×344 · 18 s loop · SVG + CSS keyframes · respects prefers-reduced-motion on this page.</p></main></body></html>`;
// `.svg` output: the bare SVG for the README (a card with rounded corners), otherwise the mockup page
const card = svg.replace('</defs>', `  <clipPath id="card"><rect width="${W}" height="${H}" rx="20"/></clipPath>\n</defs>`)
  .replace(`<rect width="${W}" height="${H}" fill="${BG}"/>`, `<g clip-path="url(#card)"><rect width="${W}" height="${H}" fill="${BG}"/>`)
  .replace(/<\/svg>$/, '</g>\n</svg>');
writeFileSync(OUT, OUT.endsWith('.svg') ? `<?xml version="1.0" encoding="UTF-8"?>\n<!-- Generated by scripts/gen-readme-header.mjs. CSS keyframes only, no JS, no web font. -->\n${card}\n` : html);
console.log('ok', OUT, 'bytes', html.length, 'layers', DYN.join(','));
