// Usage: node docs/mockups/gen-header-v7.mjs docs/mockups/header-assembly-line-v7.html
// Optional 2nd arg: JSON overrides, e.g. '{"cold":8.4}'.
// Node stdlib only. Writes one self-contained HTML page (inline SVG + CSS keyframes, no JS in the output).
//
// v7 = v4 stations + review feedback on v6:
// - back to v4's stations (column + tool arm over the belt); no drones
// - one Lead only: a single arm on a depth rail (v3's idea) serves both lines and sets every PR on `main`
// - back line: the REVIEW station's own light turns red (no tag on the parcel); the workflow, not Morgan,
//   sends the parcel back: the belt runs backwards to DEV, Nick's press fixes it, the second review passes
// - LGTM gate reads as a safety gate: hazard-striped shutter, dark frame, andon stack light
// - a human operator under the logo watches a small board: backlog, in progress, done, with red/green lights
import { writeFileSync } from 'fs';
const OUT = process.argv[2];
const OPT = JSON.parse(process.argv[3] || '{}');

// ---------------------------------------------------------------- canvas / clock
const W = 1280, H = 344, T = 16;
const COLD = OPT.cold ?? 8.4;            // opens on the front gate turning green while the back line's review light is red
const A_SHIFT = 1.2;                     // back line: its local time 0 (the card pops) happens at global 1.2
const f2 = n => Math.round(n * 100) / 100;
const mod = (a, n) => ((a % n) + n) % n;
const glob = t => mod(t + A_SHIFT, T);

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
  const [x1, y1, x2, y2] = spec.match(/[-\d.]+/g).map(Number);
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

// ---------------------------------------------------------------- timelines
// front line B runs on the global clock; back line A on its own clock (global = local + A_SHIFT)
const TB = { pop: [.40, .75], drop: [.85, 1.65], m1: [2.05, 2.60], plan: [2.60, 3.60], rows: [2.85, 3.15, 3.45], m2: [3.60, 4.15], stamp: 4.55,
  m3: [5.05, 5.60], read: [5.60, 6.95], ticks: [6.05, 6.38, 6.71], m4: [6.90, 7.45], hold: [7.45, 8.25], flip: 8.25,
  door: [8.30, 8.70], m5: [8.75, 9.30], grip: 9.95, reset: 10.20, doorDown: [10.20, 10.60] };
const TA = { pop: [0, .35], drop: [.45, 1.25], m1: [1.35, 1.90], plan: [1.90, 2.90], rows: [2.15, 2.45, 2.75], m2: [2.90, 3.45], stamp: 3.85,
  m3: [4.30, 4.85], read1: [4.90, 6.00], tick1: 5.30, fail: 5.70,
  back: [6.25, 6.85],                                                // the workflow runs the belt backwards: REVIEW -> DEV
  stamp2: 7.45,                                                      // Nick's press, the fix
  m3b: [8.05, 8.60], read2: [8.65, 9.85], ticks2: [9.20, 9.55], m4: [9.85, 10.40], hold: [10.40, 11.20], flip: 11.20,
  door: [11.25, 11.65], m5: [11.65, 12.20], grip: 12.75, reset: 13.00, doorDown: [13.00, 13.40] };
TA.red = [TA.fail + .03, TA.ticks2[1] + .02];                      // REVIEW light red until the second review passes
// the Lead (global clock): one arm, one carriage on the depth rail
const ARM = { B: { down: [9.55, 9.95], swing: [10.05, 10.95], back: [11.05, 11.65] },
  A: { down: [13.55, 13.95], swing: [14.05, 14.95], back: [15.05, 15.65] } };
const CAR = { toB: [.25, 1.40], toA: [12.25, 13.40] };             // carriage travel (main never moves meanwhile)
const MOVES = [[3.2, 4.0], [7.2, 8.0], [11.45, 12.2], [15.35, 16.0]];  // main: B's gap waits at z=0 (8.0-11.45), A's at z=350 (12.2-15.35)

// ---------------------------------------------------------------- the parcel (drawn at x = 0, depth offset z0)
// modes: 'live' (label layers animate, class suffix p), 'final' (ticked + PR stamp), 'plain'
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
    s += `<path${live ? ` class="a tk${i + 1}${p}"` : ''} d="M${f2(cx + 3)},${f2(y + 2.6)} l2.6,2.8 l5.4,-7" fill="none" stroke="${INK}" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="14"${live ? '' : ' stroke-dashoffset="0"'}/>`;
  });
  s += `<g transform="translate(${f2(fx + PW - 11)},${f2(fy + 10)}) rotate(-12)"><g${live ? ` class="a stamp${p}"` : ''}><rect x="-13" y="-7.5" width="26" height="15" rx="3" fill="#fff" fill-opacity=".92" stroke="#5B3DF5" stroke-width="1.7"/><text x="0" y="3.6" text-anchor="middle" class="mono" fill="#5B3DF5" font-size="10" font-weight="800">PR</text></g></g>`;
  return s;
}

// ---------------------------------------------------------------- stations (v4): a column behind the belt, a violet tool arm over it
Object.assign(C, {
  'rO-t': '#E9B9BD', 'rO-f': '#D69BA1', 'rO-r': '#BF848A', 'rL-t': '#FF8A80', 'rL-f': '#F04438', 'rL-r': '#C9302A',
  'aO-t': '#F1DEB2', 'aO-f': '#E3CA91', 'aO-r': '#CDB277',
  'gO-t': '#BCE0C9', 'gO-f': '#9FCDB0', 'gO-r': '#87B99A', 'gL-t': '#6EE7A0', 'gL-f': '#22C55E', 'gL-r': '#16A34A',
});
const lensRest = p => P(XS.rev - 7, 84, ZL[p] + 3);
const lampAt = p => P(XS.rev, 110.5, ZL[p] + 9);
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
  { // DEV: Nick's press stamps the PR label (and presses again for the fix)
    const x = XS.dev, rod = P(x, 96, z0 + 32);
    s += `<clipPath id="press${p}"><rect x="0" y="${f2(rod[1])}" width="1400" height="400"/></clipPath>`;
    s += `<g clip-path="url(#press${p})"><g class="a press${p}"><line x1="${f2(rod[0])}" y1="${f2(rod[1] - 40)}" x2="${f2(rod[0])}" y2="${f2(rod[1] + 16)}" stroke="#C9C6D6" stroke-width="6"/>${box(x - 26, 82, z0 + 12, 52, 14, 38, 'ag')}</g></g>`;
    const [cx, cy] = P(x, TOPY, ZF + z0);
    const spark = d => `<g transform="translate(${f2(cx + d * 40)} ${f2(cy + 2)})"><g class="a spark${p}"><path d="M${d * 3},0 l${d * 8},-2 M${d * 2},-5 l${d * 6},-6" stroke="#5B3DF5" stroke-width="2.2" stroke-linecap="round" fill="none"/></g></g>`;
    s += spark(-1) + spark(1);
  }
  { // REVIEW: Morgan's lens reads each criterion and ticks it; the station's own light gives the verdict
    const rest = lensRest(p);
    s += `<clipPath id="lensc${p}"><rect x="0" y="${f2(P(0, 96, z0 + 4)[1])}" width="1400" height="400"/></clipPath>`;
    s += `<g clip-path="url(#lensc${p})"><g transform="translate(${f2(rest[0])} ${f2(rest[1])})"><g class="a lens${p}"><line x1="0" y1="-12" x2="0" y2="-160" stroke="#C9C6D6" stroke-width="2.6"/><circle r="12" fill="#fff" fill-opacity=".35" stroke="#8069FF" stroke-width="3.2"/><path d="M-6.5 -3.5 a7 7 0 0 1 3.5 -3.6" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/></g></g></g>`;
    const [lx, ly] = lampAt(p);
    s += box(XS.rev - 6, 104, z0 + 5, 12, 3, 9, 'gt');
    s += `<circle class="a rvGlowR${p}" cx="${f2(lx)}" cy="${f2(ly)}" r="36" fill="url(#gR)"/>`;
    s += `<circle cx="${f2(lx)}" cy="${f2(ly)}" r="5.8" fill="#DCD8E8"/><circle class="a rvR${p}" cx="${f2(lx)}" cy="${f2(ly)}" r="5.8" fill="#F04438"/>`;
    s += `<path d="M${f2(lx - 2.6)} ${f2(ly - 1.4)} a3 3 0 0 1 2 -2" fill="none" stroke="#fff" stroke-width="1.3" stroke-linecap="round" opacity=".85"/>`;
  }
  return s;
}

// ---------------------------------------------------------------- LGTM gate: dark frame, hazard-striped shutter, andon stack light
function gate(p) {
  const z0 = ZL[p], dx = XG + 1, dw = 5, top = 92;
  let s = '';
  const cf = [P(dx, BH, z0), P(dx + dw, BH, z0), P(dx + dw, top, z0), P(dx, top, z0)];
  const cr = [P(dx + dw, BH, z0), P(dx + dw, BH, z0 + BD), P(dx + dw, top, z0 + BD), P(dx + dw, top, z0)];
  s += `<clipPath id="door${p}"><polygon points="${pts(cf)}"/><polygon points="${pts(cr)}"/></clipPath>`;
  s += `<g clip-path="url(#door${p})"><g class="a door${p}"><polygon points="${pts(cr)}" fill="url(#hz)"/><polygon points="${pts(cr)}" fill="none" stroke="${INK}" stroke-width="1.2" stroke-linejoin="round"/><polygon points="${pts(cf)}" fill="#2B2748"/></g></g>`;
  s += box(XG - 3, top, z0 - 8, 11, 8, BD + 19, 'gt');                              // beam, cantilevered from the pillar
  const lx = XG + 2.5, lz = z0 - 5.5, y0 = top + 16;
  s += box(lx - 1.5, top + 8, lz + 2.5, 3, 6, 3, 'gt') + box(lx - 4.8, top + 14, lz - .8, 9.6, 2, 9.6, 'gt');
  const seg = (y, off, lit, cls) => box(lx - 4, y, lz, 8, 9, 8, off) + (lit ? `<g class="a ${cls}">${box(lx - 4, y, lz, 8, 9, 8, lit)}</g>` : '');
  const ring = y => box(lx - 4.5, y, lz - .5, 9, 1.3, 9, 'gt');
  s += seg(y0, 'gO', 'gL', `lampG${p}`) + ring(y0 + 9) + seg(y0 + 10.3, 'aO') + ring(y0 + 19.3) + seg(y0 + 20.6, 'rO', 'rL', `lampR${p}`);
  s += box(lx - 4.8, y0 + 29.6, lz - .8, 9.6, 3, 9.6, 'gt');
  const [gx, gy] = P(lx, y0 + 4.5, lz), [rx, ry] = P(lx, y0 + 25.1, lz);
  s += `<circle class="a glow${p}" cx="${f2(gx)}" cy="${f2(gy)}" r="44" fill="url(#gG)" style="transform-box:fill-box;transform-origin:center"/><circle class="a lampR${p}" cx="${f2(rx)}" cy="${f2(ry)}" r="32" fill="url(#gR)"/>`;
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
    return `<circle class="a pip-${k}" cx="${f2(x - t.length * 4.1 - 8)}" cy="${f2(y - 4)}" r="2.5" fill="#5B3DF5"/><text class="a lbl lbl-${k} mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;
  }).join('');
}

// ---------------------------------------------------------------- main lane (along z, away from us)
const MX0 = 1027, MX1 = 1097, MXC = (MX0 + MX1) / 2, PITCH = 175, MTREAD = 25;
const slotShift = n => [n * PITCH * KX, -n * PITCH * KY];
const OTHERS = { 0: '#139', 1: '#141' };                            // j mod 4: 0, 1 other pipelines; 2 = front line (#142); 3 = back line (#143)
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
// Depth sort against the moving Lead: a parcel on main is drawn in front of the arm only while it is nearer
// to us (smaller z) than the carriage. Each parcel gets a copy in both layers when it changes sides.
const STRIP_J = [];
for (let j = 3; j >= -5; j--) {
  const m = mod(j, 4), who = m === 2 ? 'B' : m === 3 ? 'A' : null;
  if ((who === 'B' && j < -2) || (who === 'A' && j < -1)) continue;          // still a gap: that PR has not been placed yet
  const front = [];
  for (let k = 0; k < T * 200; k++) { const t = k / 200; front.push((j + valueAt(NSTRIP, t)) * PITCH < valueAt(ZCAR, t) - .5); }
  STRIP_J.push({ j, who, front });
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
  for (const { j, who, front } of STRIP_J) {
    const anyF = front.some(Boolean), anyB = front.some(f => !f);
    if (layer === 'front' ? !anyF : !anyB) continue;
    const both = anyF && anyB, cls = `ly${layer === 'front' ? 'F' : 'B'}${j + 10}`;
    if (both) stepKF(cls, layer === 'front' ? front : front.map(f => !f));
    const landing = (who === 'B' && j === -2) || (who === 'A' && j === -1);
    const [dx, dy] = slotShift(j), piv = P(MXC, BH, ZF);
    const body = parcel(who === 'A' ? '#143' : who === 'B' ? '#142' : OTHERS[mod(j, 4)], 'final', 0);
    s += `<g transform="translate(${f2(dx)} ${f2(dy)})"${both ? ` class="a ${cls}"` : ''}><g${landing ? ` class="a land${who}"` : ''}><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g${landing ? ` class="a msq${who}"` : ''}><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g transform="translate(${MXC} 0)">${body}</g></g></g></g></g></g>`;
  }
  return `<g class="a mstrip">${s}</g>`;
}

// ---------------------------------------------------------------- the Lead: one arm on a carriage that rides a depth rail
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
function rail() {
  const a = P(XA - 12, 2.5, -24), b = P(XA - 12, 2.5, 444), c = P(XA + 12, 2.5, -24), d = P(XA + 12, 2.5, 444);
  return box(XA - 17, 0, -24, 34, 2.5, 468, 'st')
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
  return `<g class="a car">${base}${chain(false, card)}${chain(true, grip)}</g>`;
}

// ---------------------------------------------------------------- floor, brand, the human operator
function floor() {
  const a = P(330, 0, -120), b = P(1330, 0, -120), c = P(1330, 0, 820), d = P(330, 0, 820);
  let g = `<polygon points="${pts([a, b, c, d])}" fill="url(#floorG)"/>`;
  for (const z of [-60, 150, 300, 480]) { const l = P(340, 0, z), r = P(1330, 0, z); g += `<line x1="${f2(l[0])}" y1="${f2(l[1])}" x2="${f2(r[0])}" y2="${f2(r[1])}" stroke="#E9E6EF" stroke-width="1"/>`; }
  return g;
}
const LOGO_Y = 78;
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
// the operator's board: three columns, cards with a status light each; it follows both lines.
// Cards swap identities at the loop boundary, so odd and even cards share one bar width each (seamless).
const VX = 46, VY = 336;
const V = (x, y, z) => [VX + x + z * KX, VY - y - z * KY];
const vbox = (x, y, z, w, h, d, m) => {
  const q = (a, b, c) => V(a, b, c);
  const f = [q(x, y, z), q(x + w, y, z), q(x + w, y + h, z), q(x, y + h, z)];
  const t = [q(x, y + h, z), q(x + w, y + h, z), q(x + w, y + h, z + d), q(x, y + h, z + d)];
  const r = [q(x + w, y, z), q(x + w, y, z + d), q(x + w, y + h, z + d), q(x + w, y + h, z)];
  return `<polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/>`;
};
const SCR = { x: 30, y: 42, z: 34, w: 150, h: 74 };                 // monitor housing (front face faces us)
const DISP = (() => { const [x, y] = V(SCR.x, SCR.y + SCR.h, SCR.z); return { x: x + 5, y: y + 5, w: SCR.w - 10, h: SCR.h - 10 }; })();
const CELL = (col, row) => [3 + col * 46, 13 + row * 12];
const LED = { off: '#5E5A7A', ok: '#22C55E', ko: '#F04438' };
function operator() {
  let s = `<polygon fill="${INK}" opacity=".06" points="${pts([V(-8, 0, -40), V(188, 0, -40), V(200, 0, 60), V(4, 0, 60)])}"/>`;
  for (const [x, z] of [[6, 44], [168, 44], [6, 4], [168, 4]]) s += vbox(x, 0, z, 5, 26, 5, 'st');
  s += vbox(0, 26, 0, 180, 5, 54, 'st');                                               // desk top
  s += vbox(92, 31, 38, 18, 2.5, 12, 'dk') + vbox(98, 33.5, 42, 6, 9, 4, 'dk');        // monitor foot + neck
  s += vbox(SCR.x, SCR.y, SCR.z, SCR.w, SCR.h, 6, 'dk');
  const d = DISP;
  s += `<rect x="${f2(d.x)}" y="${f2(d.y)}" width="${d.w}" height="${d.h}" rx="3" fill="#0B0A18"/>`;
  ['BACKLOG', 'IN PROGRESS', 'DONE'].forEach((t, i) => { s += `<text x="${f2(d.x + CELL(i, 0)[0] + 1)}" y="${f2(d.y + 8.5)}" class="mono" font-size="5.4" font-weight="700" letter-spacing=".3" fill="#8E89B0">${t}</text>`; });
  for (const i of [1, 2]) s += `<line x1="${f2(d.x + CELL(i, 0)[0] - 2)}" y1="${f2(d.y + 4)}" x2="${f2(d.x + CELL(i, 0)[0] - 2)}" y2="${f2(d.y + d.h - 4)}" stroke="#221F3A" stroke-width="1"/>`;
  s += `<g transform="translate(${f2(d.x)} ${f2(d.y)})">`;
  for (let k = 1; k <= 8; k++) s += `<g class="a oc${k}"><g class="a oo${k}"><rect width="42" height="9.5" rx="2" fill="#1C1933"/><circle class="a ol${k}" cx="5.5" cy="4.75" r="2.2" fill="${LED.off}"/><rect x="11" y="3.75" width="${k % 2 ? 20 : 15}" height="2" rx="1" fill="#3A3657"/></g></g>`;
  s += `</g>`;
  // the operator, seen from behind, headset on, watching the board
  const [hx, hy] = V(40, 92, -22);
  s += `<g transform="translate(${f2(hx)} ${f2(hy)})">
    <rect x="-21" y="12" width="42" height="40" rx="13" fill="#6D5BD8"/><path d="M-9 12 q9 7 18 0 v4 q-9 6 -18 0 z" fill="#5B49C6"/>
    <rect x="-17" y="27" width="34" height="37" rx="7" fill="#35305A"/><rect x="-2" y="64" width="4" height="12" fill="#2B2748"/><rect x="-14" y="75" width="28" height="3.5" rx="1.75" fill="#2B2748"/>
    <circle r="11" fill="#2B2748"/><path d="M-11.5 -1 a11.5 11.5 0 0 1 23 0" fill="none" stroke="#B6AAFF" stroke-width="2.4"/>
    <rect x="-14" y="-4.5" width="5" height="10" rx="2.2" fill="#8069FF"/><rect x="9" y="-4.5" width="5" height="10" rx="2.2" fill="#8069FF"/>
    <path d="M12 4.5 q6 3 3.5 9.5" fill="none" stroke="#8069FF" stroke-width="1.8" stroke-linecap="round"/></g>`;
  return s;
}

// ---------------------------------------------------------------- animations shared by both lines (each on its own clock)
function lineKF(p, t) {
  const cable0 = f2((HOIST - TOPY - DROP) / (HOIST - TOPY));
  kf(`cable${p}`, [[0, `transform:scaleY(${cable0})`], [t.drop[0], `transform:scaleY(${cable0})`, E.drop], [t.drop[1], 'transform:scaleY(1)'], [t.drop[1] + .15, 'transform:scaleY(1)', E.out], [t.drop[1] + .7, `transform:scaleY(${cable0})`], [T, `transform:scaleY(${cable0})`]]);
  kf(`hook${p}`, [[0, ty(HOIST - TOPY - DROP)], [t.drop[0], ty(HOIST - TOPY - DROP), E.drop], [t.drop[1], ty(HOIST - TOPY)], [t.drop[1] + .15, ty(HOIST - TOPY), E.out], [t.drop[1] + .7, ty(HOIST - TOPY - DROP)], [T, ty(HOIST - TOPY - DROP)]]);
  kf(`fan${p}`, [[0, op(0)], [t.plan[0] + .05, op(0)], [t.plan[0] + .2, op(1)], [t.plan[1] - .15, op(1)], [t.plan[1], op(0)], [T, op(0)]]);
  kf(`emit${p}`, [[0, op(.25)], [t.plan[0], op(.25)], [t.plan[0] + .15, op(1)], [t.plan[1] - .1, op(1)], [t.plan[1], op(.25)], [T, op(.25)]]);
  const r = t.rows;
  kf(`scan${p}`, [[0, `${ty(0)};opacity:0`], [t.plan[0] + .18, `${ty(0)};opacity:0`], [t.plan[0] + .2, `${ty(0)};opacity:1`, E.io], [r[1] + .05, `${ty(PHt - 2)};opacity:1`, E.io], [t.plan[1] - .15, `${ty(0)};opacity:1`], [t.plan[1] - .05, `${ty(0)};opacity:0`], [T, `${ty(0)};opacity:0`]]);
  r.forEach((x, i) => kf(`row${i + 1}${p}`, [[0, 'opacity:0;transform:scaleX(0)'], [x, 'opacity:0;transform:scaleX(0)', E.out], [x + .22, 'opacity:1;transform:scaleX(1)'], [t.reset, 'opacity:1;transform:scaleX(1)'], [t.reset + .001, 'opacity:0;transform:scaleX(0)'], [T, 'opacity:0;transform:scaleX(0)']]));
  const stamps = t.stamp2 ? [t.stamp, t.stamp2] : [t.stamp];
  const st = [[0, 'opacity:0;transform:scale(1.5)'], [t.stamp - .001, 'opacity:0;transform:scale(1.5)'], [t.stamp, 'opacity:1;transform:scale(1.5)', E.back], [t.stamp + .22, 'opacity:1;transform:scale(1)']];
  if (t.stamp2) st.push([t.stamp2, 'opacity:1;transform:scale(1)', E.out], [t.stamp2 + .1, 'opacity:1;transform:scale(1.22)', E.io], [t.stamp2 + .35, 'opacity:1;transform:scale(1)']);
  st.push([t.reset, 'opacity:1;transform:scale(1)'], [t.reset + .001, 'opacity:0;transform:scale(1.5)'], [T, 'opacity:0;transform:scale(1.5)']);
  kf(`stamp${p}`, st);
  const sp = [[0, 'opacity:0;transform:scale(.5)']]; stamps.forEach(x => sp.push([x - .01, 'opacity:0;transform:scale(.5)'], [x + .03, 'opacity:1;transform:scale(.8)', E.out], [x + .3, 'opacity:0;transform:scale(1.4)'])); sp.push([T, 'opacity:0;transform:scale(1.4)']);
  kf(`spark${p}`, sp);
  const pr = [[0, ty(0)]]; stamps.forEach(x => pr.push([x - .7, ty(0), E.out], [x - .48, ty(-6), E.slam], [x, ty(10)], [x + .15, ty(10), E.out], [x + .6, ty(0)])); pr.push([T, ty(0)]);
  kf(`press${p}`, pr);
  kf(`door${p}`, [[0, ty(0)], [t.door[0], ty(0), E.out], [t.door[1], ty(-74)], [t.doorDown[0], ty(-74), E.io], [t.doorDown[1], ty(0)], [T, ty(0)]]);
  kf(`lampR${p}`, [[0, op(0)], [t.hold[0], op(0)], [t.hold[0] + .03, op(1)], [t.hold[0] + .23, op(.2)], [t.hold[0] + .4, op(1)], [t.hold[0] + .57, op(.2)], [t.hold[0] + .74, op(1)], [t.flip, op(0)], [T, op(0)]]);
  kf(`lampG${p}`, [[0, op(0)], [t.flip - .01, op(0)], [t.flip + .03, op(1)], [t.m5[1] + .3, op(1)], [t.m5[1] + .6, op(0)], [T, op(0)]]);
  kf(`glow${p}`, [[0, 'opacity:0;transform:scale(.5)'], [t.flip, 'opacity:0;transform:scale(.5)', E.out], [t.flip + .3, 'opacity:1;transform:scale(1.25)', E.io], [t.flip + .85, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .3, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .6, 'opacity:0;transform:scale(.8)'], [T, 'opacity:0;transform:scale(.8)']]);
  // the REVIEW station's light: red while changes are required (green belongs to the gate)
  if (t.red) {
    const [a, b] = t.red;
    kf(`rvR${p}`, [[0, op(0)], [a - .001, op(0)], [a, op(1)], [b, op(1)], [b + .001, op(0)], [T, op(0)]]);
    const g = [[0, op(0)], [a - .001, op(0)], [a + .06, op(1)]];
    for (let x = a + .5; x < b - .25; x += .5) g.push([x, op(g.length % 2 ? .45 : 1), E.io]);
    g.push([b, op(.8)], [b + .001, op(0)], [T, op(0)]);
    kf(`rvGlowR${p}`, g);
  } else { kf(`rvR${p}`, [[0, op(0)], [T, op(0)]]); kf(`rvGlowR${p}`, [[0, op(0)], [T, op(0)]]); }
}
lineKF('B', TB); lineKF('A', TA);
const SQ = (p, events) => {
  const fr = [[0, 'transform:scale(1,1)']];
  for (const [at, k] of events) fr.push([at - .02, 'transform:scale(1,1)'], [at + .05, `transform:scale(${1 + .06 * k},${1 - .12 * k})`, E.out], [at + .2, `transform:scale(${1 - .015 * k},${1 + .03 * k})`], [at + .36, 'transform:scale(1,1)']);
  fr.push([T, 'transform:scale(1,1)']); kf(`sq${p}`, fr);
};
const tickKF = (name, x, reset) => kf(name, [[0, 'stroke-dashoffset:14'], [x - .12, 'stroke-dashoffset:14', E.out], [x + .02, 'stroke-dashoffset:0'], [reset, 'stroke-dashoffset:0'], [reset + .001, 'stroke-dashoffset:14'], [T, 'stroke-dashoffset:14']]);
const lensGeo = p => {
  const [fx, fy] = P(XS.rev - PW / 2, TOPY, ZF + ZL[p]), lr = lensRest(p);
  return { r: i => fy + 7 + 16 + i * 7.5 + 3 - lr[1], x0: fx + 6 + 7 - lr[0], x1: fx + 6 + 36 - lr[0] };
};
// front line B (global clock): the happy path
{
  const t = TB, p = 'B';
  const fwd = [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...t.m4, DX[4]], [...t.m5, DX[5]]];
  const tail = fr => [...fr.filter(f => f[0] < t.reset), [t.reset, tx(DX[5])], [t.reset + .001, tx(0)], [T, tx(0)]];
  kf(`mx${p}`, tail(moves(0, fwd, tx))); kf(`belt${p}`, tail(moves(0, fwd, tx)));
  kf(`my${p}`, [[0, ty(-DROP)], [t.drop[0], ty(-DROP), E.drop], [t.drop[1], ty(0)], [t.reset, ty(0)], [t.reset + .001, ty(-DROP)], [T, ty(-DROP)]]);
  kf(`vis${p}`, [[0, op(0)], [t.pop[0] - .001, op(0)], [t.pop[0], op(1)], [t.grip - .001, op(1)], [t.grip, op(0)], [T, op(0)]]);
  kf(`pop${p}`, [[0, 'transform:scale(0)'], [t.pop[0], 'transform:scale(0)', E.back], [t.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1]]);
  t.ticks.forEach((x, i) => tickKF(`tk${i + 1}${p}`, x, t.reset));
  const { r, x0, x1 } = lensGeo(p), k = t.ticks;
  kf(`lens${p}`, [[0, txy(0, 0)], [t.read[0], txy(0, 0), E.out], [t.read[0] + .2, txy(x0, r(0)), E.io], [k[0], txy(x1, r(0)), E.io], [k[0] + .1, txy(x0, r(1)), E.io], [k[1], txy(x1, r(1)), E.io],
    [k[1] + .1, txy(x0, r(2)), E.io], [k[2], txy(x1, r(2)), E.out], [t.read[1], txy(0, 0)], [T, txy(0, 0)]]);
}
// back line A (own clock): the review fails once, the workflow runs the belt back to DEV, Nick fixes, it passes
{
  const t = TA, p = 'A';
  const cardX = [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...t.back, DX[2]], [...t.m3b, DX[3]], [...t.m4, DX[4]], [...t.m5, DX[5]]];
  kf(`mx${p}`, [...moves(0, cardX, tx).filter(f => f[0] < t.reset), [t.reset, tx(DX[5])], [t.reset + .001, tx(0)], [T, tx(0)]]);
  kf(`belt${p}`, moves(0, cardX, tx));                                                  // net 480 = 24 treads per loop
  kf(`my${p}`, [[0, ty(-DROP)], [t.drop[0], ty(-DROP), E.drop], [t.drop[1], ty(0)], [t.reset, ty(0)], [t.reset + .001, ty(-DROP)], [T, ty(-DROP)]]);
  kf(`vis${p}`, [[0, op(1)], [t.grip - .001, op(1)], [t.grip, op(0)], [T, op(0)]]);        // back on at the loop boundary, while pop is at scale 0
  kf(`pop${p}`, [[0, 'transform:scale(0)', E.back], [t.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1], [t.stamp2, 1.1]]);
  [t.tick1, ...t.ticks2].forEach((x, i) => tickKF(`tk${i + 1}${p}`, x, t.reset));
  const { r, x0, x1 } = lensGeo(p), k = t.ticks2;
  kf(`lens${p}`, [[0, txy(0, 0)], [t.read1[0], txy(0, 0), E.out], [t.read1[0] + .2, txy(x0, r(0)), E.io], [t.tick1, txy(x1, r(0)), E.io], [t.tick1 + .1, txy(x0, r(1)), E.io], [t.fail, txy(x1, r(1))],
    [t.fail + .1, txy(x1, r(1)), E.io], [t.read1[1], txy(0, 0)],
    [t.read2[0], txy(0, 0), E.out], [t.read2[0] + .2, txy(x0, r(1)), E.io], [k[0], txy(x1, r(1)), E.io], [k[0] + .1, txy(x0, r(2)), E.io], [k[1], txy(x1, r(2)), E.out], [t.read2[1], txy(0, 0)], [T, txy(0, 0)]]);
}
// the Lead (global clock): one arm, one carriage
{
  const seq = sel => {
    const fr = [[0, rot(sel(POSE.home))]];
    for (const p of ['B', 'A']) { const a = ARM[p]; fr.push([a.down[0], rot(sel(POSE.home)), E.io], [a.down[1], rot(sel(POSE.pick))], [a.swing[0], rot(sel(POSE.pick)), E.io], [a.swing[1], rot(sel(POSE.place))], [a.back[0], rot(sel(POSE.place)), E.io], [a.back[1], rot(sel(POSE.home))]); }
    fr.push([T, rot(sel(POSE.home))]); return fr;
  };
  kf('sh', seq(q => q.t1)); kf('el', seq(q => q.t2)); kf('wr', seq(q => -(q.t1 + q.t2)));
  for (const p of ['B', 'A']) {
    const a = ARM[p], rel = a.swing[1];
    kf(`carry${p}`, [[0, op(0)], [a.down[1] - .001, op(0)], [a.down[1], op(1)], [rel - .001, op(1)], [rel, op(0)], [T, op(0)]]);
    kf(`land${p}`, [[0, op(0)], [rel - .001, op(0)], [rel, op(1)], [T, op(1)]]);
    kf(`msq${p}`, [[0, 'transform:scale(1,1)'], [rel, 'transform:scale(1,1)'], [rel + .06, 'transform:scale(1.05,.92)', E.out], [rel + .24, 'transform:scale(.99,1.02)'], [rel + .4, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
  }
  kf('car', ZCAR.map(([t, z, e]) => [t, txy(z * KX, -z * KY), e]));
  kf('mstrip', NSTRIP.map(([t, n, e]) => [t, txy(...slotShift(n)), e]));
}
// labels (front line clock) + logo pulses on both verdicts
{
  const DIM = '#55506F', t = TB;
  const lbl = (k, a, b, col = INK) => kf(`lbl-${k}`, [[0, `fill:${DIM}`], [a - .1, `fill:${DIM}`], [a, `fill:${col}`], [b, `fill:${col}`], [b + .1, `fill:${DIM}`], [T, `fill:${DIM}`]]);
  const pip = (k, a, b) => kf(`pip-${k}`, [[0, op(0)], [a - .1, op(0)], [a, op(1)], [b, op(1)], [b + .1, op(0)], [T, op(0)]]);
  lbl('int', t.pop[0], t.m1[0]); pip('int', t.pop[0], t.m1[0]);
  lbl('plan', ...t.plan); pip('plan', ...t.plan); lbl('dev', t.m2[1], t.m3[0]); pip('dev', t.m2[1], t.m3[0]); lbl('rev', ...t.read); pip('rev', ...t.read);
  kf('lbl-lgtm', [[0, `fill:${DIM}`], [t.hold[0] - .1, `fill:${DIM}`], [t.hold[0], 'fill:#C53030'], [t.flip - .05, 'fill:#C53030'], [t.flip + .05, 'fill:#15803D'], [t.m5[1], 'fill:#15803D'], [t.m5[1] + .2, `fill:${DIM}`], [T, `fill:${DIM}`]]);
  const flips = [TB.flip, glob(TA.flip)].sort((x, y) => x - y);
  const halo = [[0, 'opacity:0;transform:scale(1.45)']], bump = [[0, 'transform:scale(1)']], glow = [[0, op(.35)]];
  flips.forEach(f => { halo.push([f, 'opacity:0;transform:scale(1)'], [f + .01, 'opacity:.8;transform:scale(1)', E.out], [f + 1.1, 'opacity:0;transform:scale(1.45)']); bump.push([f, 'transform:scale(1)', E.out], [f + .12, 'transform:scale(1.06)', E.back], [f + .6, 'transform:scale(1)']); glow.push([f, op(.35)], [f + .1, op(1)], [f + 1.4, op(.35)]); });
  halo.push([T, 'opacity:0;transform:scale(1.45)']); bump.push([T, 'transform:scale(1)']); glow.push([T, op(.35)]);
  kf('halo', halo); kf('bump', bump); kf('sglow', glow);
}
// the operator's board: cards flow backlog -> in progress -> done, in step with the lines
{
  const card = (k, start, events) => {
    const tr = [[0, txy(...CELL(...start.cell))]], oo = [[0, op(start.o)]], ll = [[0, `fill:${LED[start.led]}`]];
    let cur = start.cell, o = start.o, led = start.led;
    for (const ev of events) {
      if (ev.cell) { tr.push([ev.t, txy(...CELL(...cur)), E.io], [ev.t + ev.d, txy(...CELL(...ev.cell))]); cur = ev.cell; }
      if (ev.o !== undefined) { oo.push([ev.t, op(o), E.out], [ev.t + ev.d, op(ev.o)]); o = ev.o; }
      if (ev.led) { ll.push([ev.t - .001, `fill:${LED[led]}`], [ev.t, `fill:${LED[ev.led]}`]); led = ev.led; }
    }
    tr.push([T, txy(...CELL(...cur))]); oo.push([T, op(o)]); ll.push([T, `fill:${LED[led]}`]);
    kf(`oc${k}`, tr); kf(`oo${k}`, oo); kf(`ol${k}`, ll);
  };
  const inB = TB.pop[0], inA = glob(TA.pop[0]), outB = ARM.B.swing[1], outA = ARM.A.swing[1];
  card(1, { cell: [0, 0], led: 'off', o: 1 }, [{ t: inB, cell: [1, 0], d: .45 }, { t: inB + .45, led: 'ok' }, { t: outB, cell: [2, 0], d: .45 }, { t: outA, cell: [2, 1], d: .3 }]);
  card(2, { cell: [0, 1], led: 'off', o: 1 }, [{ t: inB + .15, cell: [0, 0], d: .3 }, { t: inA, cell: [1, 1], d: .45 }, { t: inA + .45, led: 'ok' }, { t: glob(TA.red[0]), led: 'ko' }, { t: glob(TA.red[1]), led: 'ok' }, { t: outA, cell: [2, 0], d: .45 }]);
  card(3, { cell: [0, 2], led: 'off', o: 1 }, [{ t: inB + .15, cell: [0, 1], d: .3 }, { t: inA + .15, cell: [0, 0], d: .3 }]);
  card(4, { cell: [0, 3], led: 'off', o: 0 }, [{ t: inB + .15, cell: [0, 2], d: .3, o: 1 }, { t: inA + .15, cell: [0, 1], d: .3 }]);
  card(5, { cell: [0, 3], led: 'off', o: 0 }, [{ t: inA + .15, cell: [0, 2], d: .3, o: 1 }]);
  card(6, { cell: [2, 0], led: 'ok', o: 1 }, [{ t: outB, cell: [2, 1], d: .3 }, { t: outA, cell: [2, 2], d: .3 }]);
  card(7, { cell: [2, 1], led: 'ok', o: 1 }, [{ t: outB, cell: [2, 2], d: .3 }, { t: outA, cell: [2, 3], d: .3, o: 0 }]);
  card(8, { cell: [2, 2], led: 'ok', o: 1 }, [{ t: outB, cell: [2, 3], d: .3, o: 0 }]);
}

// ---------------------------------------------------------------- assemble
// painter's order: brand + operator, rail, back line, main (parcels behind the Lead), front line, the Lead, main (parcels in front)
const BODY = [floor(), `<g>${brand()}</g>`, operator(), rail(), line('A'), mainLane(), mainStrip('back'), line('B'), lead(), mainStrip('front'),
  `<polygon fill="url(#farFade)" points="${pts([P(MX0 - 40, 0, 470), P(MX1 + 60, 0, 470), P(MX1 + 60, 150, 1300), P(MX0 - 40, 150, 1300)])}"/>`,
  `<rect x="980" y="${H - 22}" width="${W - 980}" height="22" fill="url(#nearFade)"/>`];
const per = ['cable', 'hook', 'fan', 'emit', 'scan', 'row1', 'row2', 'row3', 'stamp', 'spark', 'press', 'lens', 'door', 'lampR', 'lampG', 'glow',
  'rvR', 'rvGlowR', 'mx', 'belt', 'my', 'vis', 'pop', 'sq', 'tk1', 'tk2', 'tk3'];
const names = [...per.flatMap(n => [n + 'A', n + 'B']), 'sh', 'el', 'wr', 'carryA', 'carryB', 'landA', 'landB', 'msqA', 'msqB', 'car', 'mstrip',
  'halo', 'bump', 'sglow', ...['int', 'plan', 'dev', 'rev', 'lgtm'].flatMap(k => [`lbl-${k}`, `pip-${k}`]).filter(n => n !== 'pip-lgtm'),
  ...[1, 2, 3, 4, 5, 6, 7, 8].flatMap(k => [`oc${k}`, `oo${k}`, `ol${k}`]), ...DYN];
const css = `
.a{animation-duration:${T}s;animation-iteration-count:infinite;animation-fill-mode:both;animation-delay:${f2(-mod(COLD, T))}s}
.pA .a{animation-delay:${f2(-mod(COLD - A_SHIFT, T))}s}
.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.wm{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:42px;font-weight:700;letter-spacing:-1.5px}
.tag{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:14.5px;fill:#5B6472}
.lbl{font-size:12px;font-weight:600;letter-spacing:1.4px;fill:#55506F}
${names.map(n => `.${n}{animation-name:${n}}`).join('')}.pip-lgtm{opacity:0}
@media (prefers-reduced-motion:reduce){.a{animation-play-state:paused}}
`;
const defs = `<defs>
  <radialGradient id="gG"><stop offset="0" stop-color="#22C55E" stop-opacity=".5"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <radialGradient id="gR"><stop offset="0" stop-color="#F04438" stop-opacity=".42"/><stop offset="1" stop-color="#F04438" stop-opacity="0"/></radialGradient>
  <radialGradient id="gS" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#22C55E" stop-opacity=".45"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <linearGradient id="floorG" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#ECE9F1"/><stop offset="1" stop-color="#ECE9F1" stop-opacity="0"/></linearGradient>
  <linearGradient id="farFade" gradientUnits="userSpaceOnUse" x1="${f2(P(MXC, 40, 470)[0])}" y1="${f2(P(MXC, 40, 470)[1])}" x2="${f2(P(MXC, 40, 680)[0])}" y2="${f2(P(MXC, 40, 680)[1])}"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
  <linearGradient id="nearFade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
  <pattern id="hz" patternUnits="userSpaceOnUse" width="8" height="8" patternTransform="rotate(45)"><rect width="8" height="8" fill="${HZ_Y}"/><rect width="4" height="8" fill="${INK}"/></pattern>
</defs>`;
const svg = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="lgtmgate: two production lines, one behind the other. On each, stations do the work: one prints the acceptance checklist on the issue's label, one stamps it a pull request, one reads and ticks every criterion, then the LGTM safety gate turns from red to green and opens. On the back line the review station's light turns red; the belt carries the parcel back to be fixed, and it passes the second time. A single Lead arm rides a rail between the two lines and sets each approved pull request onto the main lane, among pull requests from other pipelines, while a human operator watches the backlog, in-progress and done board.">
<style>${css}${KF.join('\n')}</style>
${defs}
<rect width="${W}" height="${H}" fill="${BG}"/>
${BODY.join('\n')}
</svg>`;
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>lgtmgate header v7</title>
<style>html,body{margin:0;background:#ECEBF0}main{max-width:1280px;margin:0 auto;padding:40px 16px 56px}
.frame{border-radius:20px;overflow:hidden;box-shadow:0 1px 0 rgba(17,19,24,.04),0 12px 40px -12px rgba(17,19,24,.18)}
.frame svg{display:block;width:100%;height:auto}
p{font:13px -apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif;color:#5B6472;margin:14px 4px 0}</style></head>
<body><main><div class="frame">
<!-- Generated by gen-header-v7.mjs. One self-contained <svg>: CSS keyframes only, no JS, no web font. -->
${svg}
</div><p>Mockup v7 · 1280×344 · 16 s loop · SVG + CSS keyframes · respects prefers-reduced-motion on this page.</p></main></body></html>`;
writeFileSync(OUT, html);
console.log('ok', OUT, 'bytes', html.length, 'layers', DYN.join(','), 'pose', JSON.stringify(Object.fromEntries(Object.entries(POSE).map(([n, q]) => [n, [f2(q.t1), f2(q.t2)]]))));
