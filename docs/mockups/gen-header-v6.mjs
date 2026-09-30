// Usage: node docs/mockups/gen-header-v6.mjs docs/mockups/header-assembly-line-v6.html
// Optional 2nd arg: JSON overrides, e.g. '{"cold":4.4}'.
// Node stdlib only. Writes one self-contained HTML page (inline SVG + CSS keyframes, no JS in the output).
//
// v6 = v4 + review feedback:
// - stage labels carry the stage only (no agent names); LGTM sits centred under its gate light
// - stations are drones hovering over the belt: Sam's printer drone, Nick's stamping drone, Morgan's lens drone
// - a second line, behind the first (so higher on screen): its issue #143 fails one criterion at review,
//   Morgan's drone carries it back to Nick (Nick's drone lifts out of the way), Nick fixes it, it passes the
//   second review, and that line's own arm sets it on `main` too — REQUIRED_CHANGES -> Nick, as in the README
import { writeFileSync } from 'fs';
const OUT = process.argv[2];
const OPT = JSON.parse(process.argv[3] || '{}');

// ---------------------------------------------------------------- canvas / clock
const W = 1280, H = 344, T = 16;
const COLD = OPT.cold ?? 4.4;            // opens on the front line's stamp and the back line's failing review
const A_SHIFT = 15.1;                    // back line: its local time 0 (the card pops) happens at global 15.1
const f2 = n => Math.round(n * 100) / 100;
const mod = (a, n) => ((a % n) + n) % n;

// ---------------------------------------------------------------- projection (cabinet oblique, 45°, depth x0.5)
const KX = 0.3536, KY = 0.3536, FLOOR = 316;
const P = (x, y, z) => [x + z * KX, FLOOR - y - z * KY];
const pts = a => a.map(p => `${f2(p[0])},${f2(p[1])}`).join(' ');

// ---------------------------------------------------------------- palette (v4)
const BG = '#F7F6F3';
const C = {
  'st-t': '#EEEDF3', 'st-f': '#DDDBE6', 'st-r': '#C9C6D6',
  'bt-t': '#E4E1EC', 'bt-f': '#CDC9DA', 'bt-r': '#B9B4CA',
  'mn-t': '#E6E2F4', 'mn-f': '#CFC8EA', 'mn-r': '#B7AEDC',
  'kr-t': '#F6DEB4', 'kr-f': '#ECC893', 'kr-r': '#D7AD71',
  'ag-t': '#B6AAFF', 'ag-f': '#8069FF', 'ag-r': '#5E48E6',
  'dk-t': '#6D5BD8', 'dk-f': '#4F3DC4', 'dk-r': '#3B2BA3',
  'ac-t': '#4A4570', 'ac-f': '#35305A', 'ac-r': '#28244A',
  'tl-t': '#4A4570', 'tl-f': '#2E2A4F', 'tl-r': '#231F40',
};
const box = (x, y, z, w, h, d, m) => {
  const f = [P(x, y, z), P(x + w, y, z), P(x + w, y + h, z), P(x, y + h, z)];
  const t = [P(x, y + h, z), P(x + w, y + h, z), P(x + w, y + h, z + d), P(x, y + h, z + d)];
  const r = [P(x + w, y, z), P(x + w, y, z + d), P(x + w, y + h, z + d), P(x + w, y + h, z)];
  return `<polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/>`;
};

// ---------------------------------------------------------------- keyframes
const E = {
  move: 'cubic-bezier(.77,0,.175,1)', out: 'cubic-bezier(.23,1,.32,1)', back: 'cubic-bezier(.34,1.56,.64,1)',
  slam: 'cubic-bezier(.7,0,1,.6)', exit: 'cubic-bezier(.5,0,.75,0)', io: 'cubic-bezier(.65,0,.35,1)', drop: 'cubic-bezier(.55,0,.85,.55)',
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

// ---------------------------------------------------------------- geometry (world units; x along the line, y up, z depth)
const BX0 = 360, BX1 = 930, BH = 20, BD = 64;
const PW = 70, PHt = 52, PD = 50, ZF = (BD - PD) / 2, ZC = ZF + PD / 2, TOPY = BH + PHt;
const SP = 100, INT = 400, TREAD = 20;
const XS = { int: INT, plan: INT + SP, dev: INT + 2 * SP, rev: INT + 3 * SP, lgtm: INT + 4 * SP, pick: INT + 4 * SP + 80 };
const DX = [0, SP, 2 * SP, 3 * SP, 4 * SP, 4 * SP + 80];           // 480 = 24 treads -> seamless
const XG = XS.lgtm + PW / 2 + 8;                                   // gate plane; its light (and the LGTM label) at XG + 2.5
const ZL = { A: 350, B: 0 };                                       // A = back line, B = front line
const HOIST = 150, DROP = 60, HOVER = 118, LIFT = 24;

// ---------------------------------------------------------------- timelines (B on the global clock, A on its own shifted clock)
const TB = { pop: [.40, .75], drop: [.85, 1.65], m1: [2.05, 2.60], plan: [2.60, 3.60], rows: [2.85, 3.15, 3.45], m2: [3.60, 4.15], stamp: 4.55,
  m3: [5.05, 5.60], read: [5.60, 6.95], ticks: [6.00, 6.35, 6.70], m4: [6.90, 7.45], hold: [7.45, 8.25], flip: 8.25, door: [8.30, 8.70],
  m5: [8.75, 9.30], doorDown: [10.20, 10.60], grip: 9.95, reset: 10.20,
  arm: { down: [9.55, 9.95], swing: [10.05, 10.95], back: [11.05, 11.65] } };
const TA = { pop: [0, .35], drop: [.45, 1.25], m1: [1.35, 1.90], plan: [1.90, 2.90], rows: [2.15, 2.45, 2.75], m2: [2.90, 3.45], stamp: 3.85,
  m3: [4.35, 4.90], read1: [4.95, 6.15], tick1: 5.35, cross: 5.75,
  cour: { toTop: [6.15, 6.45], lift: [6.60, 6.85], fly: [6.85, 7.55], lower: [7.55, 7.85], release: 7.85, home: [7.95, 8.65] },
  devUp: [6.75, 7.15], devDown: [8.25, 8.55], stamp2: 9.25,
  m3b: [9.75, 10.30], read2: [10.35, 11.45], ticks2: [10.70, 11.05], m4: [11.45, 12.00], hold: [12.00, 12.80], flip: 12.80, door: [12.85, 13.25],
  m5: [13.25, 13.80], grip: 14.85, reset: 15.00, doorDown: [15.00, 15.40] };
const ARM_A = { down: [13.55, 13.95], swing: [14.05, 14.95], back: [15.05, 15.65] };      // global time
const MOVES = [[3.2, 4.0], [7.2, 8.0], [11.45, 12.2], [15.35, 16.0]];                    // main: B's gap waits 8.0-11.45 (front), A's 12.2-15.35 (back)
const glob = t => mod(t + A_SHIFT, T);

// ---------------------------------------------------------------- the parcel (drawn at x = 0, depth offset z0)
// modes: 'liveB' / 'liveA' (label layers animate; A also fails once), 'final' (ticked + PR stamp), 'plain'
function parcel(num, mode, z0, p = '') {
  const [fx, fy] = P(-PW / 2, TOPY, ZF + z0);
  const cx = fx + 6, cy = fy + 7;
  const tape = [P(-7, TOPY, ZF + z0), P(7, TOPY, ZF + z0), P(7, TOPY, ZF + PD + z0), P(-7, TOPY, ZF + PD + z0)];
  let s = box(-PW / 2, BH, ZF + z0, PW, PHt, PD, 'kr');
  s += `<polygon fill="#E3C38F" points="${pts(tape)}"/><rect fill="#E3C38F" x="${f2(fx + PW / 2 - 7)}" y="${f2(fy)}" width="14" height="5"/>`;
  s += `<rect fill="#fff" x="${f2(cx)}" y="${f2(cy)}" width="46" height="38" rx="2.5"/>`;
  s += `<text class="mono" fill="#1E1B3A" x="${f2(cx + 4)}" y="${f2(cy + 10)}" font-size="9" font-weight="700">${num}</text>`;
  if (mode === 'plain') return s;
  const live = mode.startsWith('live');
  [0, 1, 2].forEach(i => {
    const y = cy + 16 + i * 7.5, w = [24, 19, 22][i];
    s += `<g${live ? ` class="a row${i + 1}${p}" style="transform-origin:${f2(cx + 4)}px 0"` : ''}><rect x="${f2(cx + 4)}" y="${f2(y)}" width="6" height="6" rx="1.2" fill="none" stroke="#1E1B3A" stroke-width="1.2"/><line x1="${f2(cx + 14)}" y1="${f2(y + 3)}" x2="${f2(cx + 14 + w)}" y2="${f2(y + 3)}" stroke="#C5C8D2" stroke-width="2.2" stroke-linecap="round"/></g>`;
    s += `<path${live ? ` class="a tk${i + 1}${p}"` : ''} d="M${f2(cx + 3)},${f2(y + 2.6)} l2.6,2.8 l5.4,-7" fill="none" stroke="#1E1B3A" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="14"${live ? '' : ' stroke-dashoffset="0"'}/>`;
    if (mode === 'liveA' && i === 1) s += `<g class="a crossA" style="transform-origin:${f2(cx + 7)}px ${f2(y + 3)}px"><path d="M${f2(cx + 4.4)},${f2(y + .4)} l5.2,5.2 M${f2(cx + 9.6)},${f2(y + .4)} l-5.2,5.2" stroke="#D1242F" stroke-width="1.9" stroke-linecap="round"/></g>`;
  });
  s += `<g transform="translate(${f2(fx + PW - 11)},${f2(fy + 10)}) rotate(-12)"><g${live ? ` class="a stamp${p}"` : ''}><rect x="-13" y="-7.5" width="26" height="15" rx="3" fill="#fff" fill-opacity=".92" stroke="#5B3DF5" stroke-width="1.7"/><text x="0" y="3.6" text-anchor="middle" class="mono" fill="#5B3DF5" font-size="10" font-weight="800">PR</text></g></g>`;
  if (mode === 'liveA') s += `<g transform="translate(${f2(fx + PW - 10)} ${f2(fy + 33)})"><g class="a badgeA"><circle r="6.8" fill="#D1242F"/><path d="M0 -3.4v4" stroke="#fff" stroke-width="1.9" stroke-linecap="round"/><circle cy="3.2" r="1.1" fill="#fff"/></g></g>`;
  return s;
}

// ---------------------------------------------------------------- drones (Sam, Nick, Morgan)
let BOB = 0;
function drone(x, z, tool, act, p) {
  const s = [];
  const [l0, l1] = [P(x - 24, HOVER + 5, z), P(x + 24, HOVER + 5, z)];
  s.push(`<line x1="${f2(l0[0])}" y1="${f2(l0[1])}" x2="${f2(l1[0])}" y2="${f2(l1[1])}" stroke="#2B2748" stroke-width="2.2" stroke-linecap="round"/>`);
  for (const [rx, ry] of [l0, l1]) s.push(`<g transform="translate(${f2(rx)} ${f2(ry - 1.5)}) rotate(-12)"><ellipse class="spin" rx="11.5" ry="3.2" fill="#2B2748" opacity=".5"/></g>`);
  s.push(box(x - 17, HOVER - 4, z - 10, 34, 8, 20, 'ag'));
  const eye = P(x, HOVER, z - 10);
  s.push(`<circle cx="${f2(eye[0])}" cy="${f2(eye[1])}" r="1.7" fill="#E8E4FF"/>`);
  s.push(tool);
  return `<g class="bob" style="animation-delay:${f2(-(BOB++ * .83))}s"><g class="a ${act}${p}">${s.join('')}</g></g>`;
}
function planDrone(p) {
  const x = XS.plan, z0 = ZL[p], z = z0 + ZC;
  const [fx, fy] = P(x - PW / 2, TOPY, ZF + z0), e0 = P(x - 12, HOVER - 10, z - 7), e1 = P(x + 12, HOVER - 10, z - 7);
  let s = `<polygon class="a fan${p}" fill="#7C66FF" fill-opacity=".16" points="${pts([e0, e1, [fx + PW + 4, fy + PHt + 2], [fx - 4, fy + PHt + 2]])}"/>`;
  s += `<g class="a scan${p}"><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="2" stroke-linecap="round"/><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="7" stroke-linecap="round" opacity=".25"/></g>`;
  const tool = box(x - 13, HOVER - 10, z - 7, 26, 6, 14, 'dk') + `<line class="a emit${p}" x1="${f2(e0[0])}" y1="${f2(e0[1])}" x2="${f2(e1[0])}" y2="${f2(e1[1])}" stroke="#C9C0FF" stroke-width="2.4" stroke-linecap="round"/>`;
  return s + drone(x, z, tool, 'dPlan', p);
}
function devDrone(p) {
  const x = XS.dev, z = ZL[p] + ZC, r0 = P(x, HOVER - 4, z), r1 = P(x, HOVER - 18, z);
  const tool = `<line x1="${f2(r0[0])}" y1="${f2(r0[1])}" x2="${f2(r1[0])}" y2="${f2(r1[1])}" stroke="#2B2748" stroke-width="3"/>` + box(x - 16, HOVER - 30, z - 11, 32, 12, 22, 'dk');
  const [cx, cy] = P(x, TOPY, ZF + ZL[p]);
  const spark = d => `<g transform="translate(${f2(cx + d * 40)} ${f2(cy + 2)})"><g class="a spark${p}"><path d="M${d * 3},0 l${d * 8},-2 M${d * 2},-5 l${d * 6},-6" stroke="#5B3DF5" stroke-width="2.2" stroke-linecap="round" fill="none"/></g></g>`;
  return drone(x, z, tool, 'dDev', p) + spark(-1) + spark(1);
}
const lensRest = p => P(XS.rev - 7, HOVER - 30, ZL[p] + 3);
function revDrone(p) {
  const x = XS.rev, z = ZL[p] + ZC, st0 = P(x - 7, HOVER - 4, z - 10), lc = lensRest(p);
  const tool = `<line x1="${f2(st0[0])}" y1="${f2(st0[1])}" x2="${f2(lc[0])}" y2="${f2(lc[1] - 11)}" stroke="#2B2748" stroke-width="2.2"/>`
    + `<circle cx="${f2(lc[0])}" cy="${f2(lc[1])}" r="11" fill="#fff" fill-opacity=".35" stroke="#8069FF" stroke-width="3"/><path d="M${f2(lc[0] - 6)} ${f2(lc[1] - 3.2)} a6.5 6.5 0 0 1 3.2 -3.3" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round"/>`
    + (p === 'A' ? `<circle class="a lensRedA" cx="${f2(lc[0])}" cy="${f2(lc[1])}" r="11" fill="#D1242F" fill-opacity=".14" stroke="#D1242F" stroke-width="3"/>` : '');
  return drone(x, z, tool, 'dRev', p);
}

// ---------------------------------------------------------------- one production line
function line(p) {
  const z0 = ZL[p], num = p === 'A' ? '#143' : '#142';
  let s = '';
  s += box(INT - 36, HOIST + 10, z0 + ZC - 8, 72, 6, 16, 'st') + box(INT - 11, HOIST, z0 + ZC - 9, 22, 10, 18, 'ac');
  s += box(XG - 1, 0, z0 + BD + 1, 7, 84, 7, 'st');                                        // gate back post
  s += `<polygon fill="#1E1B3A" opacity=".07" points="${pts([P(BX0 + 6, 0, z0 - 3), P(BX1 + 8, 0, z0 - 3), P(BX1 + 24, 0, z0 + BD + 20), P(BX0 + 22, 0, z0 + BD + 20)])}"/>`;
  s += box(BX0, 0, z0, BX1 - BX0, BH, BD, 'bt');
  const topFace = [P(BX0, BH, z0), P(BX1, BH, z0), P(BX1, BH, z0 + BD), P(BX0, BH, z0 + BD)];
  let ticks = ''; for (let x = BX0 - 600 + 8; x < BX1; x += TREAD) { const a = P(x, BH, z0 + 5), b = P(x, BH, z0 + BD - 5); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="belt${p}"><polygon points="${pts(topFace)}"/></clipPath><g clip-path="url(#belt${p})"><path class="a belt${p}" d="${ticks}" stroke="#CFCADD" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  if (p === 'B') s += labels();
  const hk = P(INT, HOIST, z0 + ZC);
  s += `<g transform="translate(${f2(hk[0])} ${f2(hk[1])})"><rect class="a cable${p}" x="-.8" y="0" width="1.6" height="${HOIST - TOPY}" fill="#8C93A0" style="transform-origin:0 0"/><g class="a hook${p}"><path d="M-4.5 -2 h9 l-4.5 5 z" fill="#2B2748"/></g></g>`;
  const piv = P(0, BH, ZF + z0), topc = P(0, TOPY, ZC + z0);
  s += `<g transform="translate(${INT} 0)"><g class="a vis${p}"><g class="a mx${p}"><g class="a my${p}"><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g class="a sq${p}"><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g class="a pop${p}" style="transform-origin:${f2(topc[0])}px ${f2(topc[1])}px">${parcel(num, 'live' + p, z0, p)}</g></g></g></g></g></g></g></g>`;
  s += planDrone(p) + devDrone(p) + revDrone(p);
  // LGTM gate: door (clipped to its closed shape), front post, lintel, traffic light
  const dx = XG + 1, dw = 4;
  const cf = [P(dx, BH, z0), P(dx + dw, BH, z0), P(dx + dw, 80, z0), P(dx, 80, z0)];
  const cr = [P(dx + dw, BH, z0), P(dx + dw, BH, z0 + BD), P(dx + dw, 80, z0 + BD), P(dx + dw, 80, z0)];
  const ct = [P(dx, 80, z0), P(dx + dw, 80, z0), P(dx + dw, 80, z0 + BD), P(dx, 80, z0 + BD)];
  s += `<clipPath id="door${p}"><polygon points="${pts(cf)}"/><polygon points="${pts(cr)}"/><polygon points="${pts(ct)}"/></clipPath>`;
  s += `<g clip-path="url(#door${p})"><g class="a door${p}">${box(dx, BH, z0, dw, 60, BD, 'st')}</g></g>`;
  s += box(XG - 3, 84, z0 - 8, 11, 7, BD + 17, 'st');                                        // cantilevered from the back post: the belt face stays free for the label
  const lx = XG + 2.5, lz = z0 - 10;
  s += box(lx - 8, 91, lz, 16, 34, 10, 'tl');
  const [rx, ry] = P(lx, 116, lz), [gx, gy] = P(lx, 100, lz);
  s += `<circle class="a glow${p}" cx="${f2(gx)}" cy="${f2(gy)}" r="44" fill="url(#gG)" style="transform-box:fill-box;transform-origin:center"/><circle class="a lampR${p}" cx="${f2(rx)}" cy="${f2(ry)}" r="32" fill="url(#gR)"/>`;
  s += `<circle fill="#4A4568" cx="${f2(rx)}" cy="${f2(ry)}" r="5.8"/><circle fill="#4A4568" cx="${f2(gx)}" cy="${f2(gy)}" r="5.8"/>`;
  s += `<circle class="a lampR${p}" fill="#F04438" cx="${f2(rx)}" cy="${f2(ry)}" r="5.8"/><circle class="a lampG${p}" fill="#22C55E" cx="${f2(gx)}" cy="${f2(gy)}" r="5.8"/>`;
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
function mainLane() {
  let s = '';
  const z0 = -420, z1 = 1500;
  s += `<polygon fill="#1E1B3A" opacity=".07" points="${pts([P(MX0 + 8, 0, z0), P(MX1 + 14, 0, z0), P(MX1 + 14, 0, z1), P(MX0 + 8, 0, z1)])}"/>`;
  s += box(MX0 - 4, 0, z0, MX1 - MX0 + 8, BH, z1 - z0, 'mn');
  const top = [P(MX0 - 4, BH, z0), P(MX1 + 4, BH, z0), P(MX1 + 4, BH, z1), P(MX0 - 4, BH, z1)];
  let ticks = ''; for (let z = z0 - 4 * PITCH; z < z1; z += MTREAD) { const a = P(MX0, BH, z), b = P(MX1, BH, z); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="mainClip"><polygon points="${pts(top)}"/></clipPath><g clip-path="url(#mainClip)"><path class="a mstrip" d="${ticks}" stroke="#D6CFEE" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  const o = P(MX1 + 4, 5, -60);
  s += `<g transform="matrix(${KX * 2} ${-KY * 2} 0 1 ${f2(o[0])} ${f2(o[1])})"><g fill="none" stroke="#5B3DF5" stroke-width="1.4" stroke-linecap="round"><circle cx="3" cy="-8" r="2"/><circle cx="3" cy="0" r="2"/><circle cx="10" cy="-6" r="2"/><path d="M3 -6 v4 M10 -4 c0 3 -4 3 -6 4"/></g><text x="16" y="1" class="mono" fill="#5B3DF5" font-size="11" font-weight="700" letter-spacing=".5">main</text></g>`;
  return s;
}
function mainStrip(onlyJ, forceFinal) {
  let s = '';
  for (let j = 7; j >= -6; j--) {
    if (onlyJ !== undefined && j !== onlyJ) continue;
    const m = mod(j, 4), who = m === 2 ? 'B' : m === 3 ? 'A' : null;
    if (who === 'B' && j < -2) continue;
    if (who === 'A' && j < -1) continue;
    const landing = !forceFinal && ((who === 'B' && j === -2) || (who === 'A' && j === -1));
    const [dx, dy] = slotShift(j), piv = P(MXC, BH, ZF);
    const body = parcel(who === 'A' ? '#143' : who === 'B' ? '#142' : OTHERS[m], 'final', 0);
    s += `<g transform="translate(${f2(dx)} ${f2(dy)})"${landing ? ` class="a land${who}"` : ''}><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g${landing ? ` class="a msq${who}"` : ''}><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g transform="translate(${MXC} 0)">${body}</g></g></g></g></g>`;
  }
  return s;
}

// ---------------------------------------------------------------- the Lead's arms (one per line, both set PRs on main)
const XA = 952, L1 = 70, L2 = 64, GRIP = 19;
function ik(sh, [tx_, ty_], prefer) {
  const wx = tx_, wy = ty_ - GRIP, dx = wx - sh[0], dy = wy - sh[1], d = Math.hypot(dx, dy);
  const c = Math.max(-1, Math.min(1, (d * d - L1 * L1 - L2 * L2) / (2 * L1 * L2)));
  const t2 = prefer * Math.acos(c), t1 = Math.atan2(dy, dx) - Math.atan2(L2 * Math.sin(t2), L1 + L2 * Math.cos(t2));
  return { t1: t1 * 180 / Math.PI, t2: t2 * 180 / Math.PI };
}
const near = (a, ref) => a + 360 * Math.round((ref - a) / 360);
const ARMS = {};
for (const p of ['A', 'B']) {
  const z = ZL[p] + ZC, sh = P(XA, 46, z), pick = P(XS.pick, TOPY, z), place = P(MXC, TOPY, z), home = [sh[0] + 6, pick[1] - (p === 'B' ? 34 : 60)];
  const pose = { home: ik(sh, home, -1), pick: ik(sh, pick, -1), place: ik(sh, place, 1) };
  for (const k of ['pick', 'place']) pose[k].t1 = near(pose[k].t1, pose.home.t1);
  ARMS[p] = { sh, pose };
}
function armBase(p) {
  const z0 = ZL[p], [lx, ly] = P(XA, 12, z0 + 12);
  return `<polygon fill="#1E1B3A" opacity=".09" points="${pts([P(XA - 26, 0, z0 + 6), P(XA + 30, 0, z0 + 6), P(XA + 36, 0, z0 + 62), P(XA - 20, 0, z0 + 62)])}"/>`
    + box(XA - 22, 0, z0 + 10, 44, 12, 44, 'ac') + box(XA - 11, 12, z0 + 21, 22, 34, 22, 'ac')
    + `<text x="${f2(lx)}" y="${f2(ly + 8.5)}" text-anchor="middle" class="mono" fill="#C9C0FF" font-size="7.5" font-weight="700" letter-spacing="1">LEAD</text>`;
}
function arm(p) {
  const { sh } = ARMS[p], z0 = ZL[p];
  const cap = (len, th) => `<rect x="${-th / 2}" y="${-th / 2}" width="${len + th}" height="${th}" rx="${th / 2}" fill="#2B2748"/>`;
  const joint = r => `<circle r="${r}" fill="#8069FF"/><circle r="${r * .34}" fill="#2B2748"/>`;
  const topC = P(0, TOPY, ZC + z0);
  const card = `<g class="a carry${p}"><g transform="translate(${f2(-topC[0])} ${f2(GRIP - topC[1])})">${parcel(p === 'A' ? '#143' : '#142', 'final', z0)}</g></g>`;
  const grip = `<rect x="-3" y="0" width="6" height="${GRIP - 5}" fill="#2B2748"/><rect x="-13" y="${GRIP - 6}" width="26" height="6" rx="2" fill="#8069FF"/>${joint(6.5)}`;
  const chain = (links, hand) => `<g transform="translate(${f2(sh[0])} ${f2(sh[1])})"><g class="a sh${p}">${links ? cap(L1, 15) + `<line x1="4" y1="-5" x2="${L1 - 4}" y2="-5" stroke="#4A4478" stroke-width="2" stroke-linecap="round"/>` : ''}
      <g transform="translate(${L1} 0)"><g class="a el${p}">${links ? cap(L2, 12) + `<line x1="4" y1="-4" x2="${L2 - 4}" y2="-4" stroke="#4A4478" stroke-width="1.8" stroke-linecap="round"/>` : ''}
        <g transform="translate(${L2} 0)"><g class="a wr${p}">${hand}</g></g>${links ? joint(7.5) : ''}</g></g>${links ? joint(9) : ''}</g></g>`;
  return chain(false, card) + chain(true, grip);
}

// ---------------------------------------------------------------- floor, brand
function floor() {
  const a = P(330, 0, -120), b = P(1330, 0, -120), c = P(1330, 0, 820), d = P(330, 0, 820);
  let g = `<polygon points="${pts([a, b, c, d])}" fill="url(#floorG)"/>`;
  for (const z of [-60, 150, 300, 480]) { const l = P(340, 0, z), r = P(1330, 0, z); g += `<line x1="${f2(l[0])}" y1="${f2(l[1])}" x2="${f2(r[0])}" y2="${f2(r[1])}" stroke="#E9E6EF" stroke-width="1"/>`; }
  return g;
}
function brand() {
  return `<g transform="translate(48 112)"><g transform="translate(44 44)">
    <rect class="a halo" x="-44" y="-44" width="88" height="88" rx="22" fill="none" stroke="#22C55E" stroke-width="2"/>
    <g class="a bump"><rect x="-44" y="-44" width="88" height="88" rx="22" fill="#1E1B3A"/><rect x="-32" y="-32" width="64" height="64" rx="13" fill="#0B0A18"/>
      <rect class="a sglow" x="-32" y="-32" width="64" height="64" rx="13" fill="url(#gS)"/>
      <path d="M-13 -5 l9 9 l17 -18" fill="none" stroke="#3DDC84" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
      <text x="0" y="21" text-anchor="middle" class="mono" font-size="9.5" font-weight="700" letter-spacing="2" fill="#3DDC84">LGTM</text></g></g></g>
  <text x="152" y="156" class="wm"><tspan fill="#5B3FE0">lgtm</tspan><tspan fill="#1E1B3A">gate</tspan></text>
  <text x="153" y="182" class="tag">Merge gate for</text><text x="153" y="201" class="tag">agent-generated pull requests</text>`;
}

// ---------------------------------------------------------------- animations shared by both lines
function lineKF(p, t) {
  const cable0 = f2((HOIST - TOPY - DROP) / (HOIST - TOPY));
  kf(`cable${p}`, [[0, `transform:scaleY(${cable0})`], [t.drop[0], `transform:scaleY(${cable0})`, E.drop], [t.drop[1], 'transform:scaleY(1)'], [t.drop[1] + .15, 'transform:scaleY(1)', E.out], [t.drop[1] + .7, `transform:scaleY(${cable0})`], [T, `transform:scaleY(${cable0})`]]);
  kf(`hook${p}`, [[0, ty(HOIST - TOPY - DROP)], [t.drop[0], ty(HOIST - TOPY - DROP), E.drop], [t.drop[1], ty(HOIST - TOPY)], [t.drop[1] + .15, ty(HOIST - TOPY), E.out], [t.drop[1] + .7, ty(HOIST - TOPY - DROP)], [T, ty(HOIST - TOPY - DROP)]]);
  kf(`fan${p}`, [[0, op(0)], [t.plan[0] + .05, op(0)], [t.plan[0] + .2, op(1)], [t.plan[1] - .15, op(1)], [t.plan[1], op(0)], [T, op(0)]]);
  kf(`emit${p}`, [[0, op(.3)], [t.plan[0], op(.3)], [t.plan[0] + .15, op(1)], [t.plan[1] - .1, op(1)], [t.plan[1], op(.3)], [T, op(.3)]]);
  const r = t.rows;
  kf(`scan${p}`, [[0, `${ty(0)};opacity:0`], [t.plan[0] + .18, `${ty(0)};opacity:0`], [t.plan[0] + .2, `${ty(0)};opacity:1`, E.io], [r[1] + .05, `${ty(PHt - 2)};opacity:1`, E.io], [t.plan[1] - .15, `${ty(0)};opacity:1`], [t.plan[1] - .05, `${ty(0)};opacity:0`], [T, `${ty(0)};opacity:0`]]);
  r.forEach((x, i) => kf(`row${i + 1}${p}`, [[0, 'opacity:0;transform:scaleX(0)'], [x, 'opacity:0;transform:scaleX(0)', E.out], [x + .22, 'opacity:1;transform:scaleX(1)'], [t.reset, 'opacity:1;transform:scaleX(1)'], [t.reset + .001, 'opacity:0;transform:scaleX(0)'], [T, 'opacity:0;transform:scaleX(0)']]));
  kf(`stamp${p}`, [[0, 'opacity:0;transform:scale(1.5)'], [t.stamp - .001, 'opacity:0;transform:scale(1.5)'], [t.stamp, 'opacity:1;transform:scale(1.5)', E.back], [t.stamp + .22, 'opacity:1;transform:scale(1)'], [t.reset, 'opacity:1;transform:scale(1)'], [t.reset + .001, 'opacity:0;transform:scale(1.5)'], [T, 'opacity:0;transform:scale(1.5)']]);
  const stamps = p === 'A' ? [t.stamp, t.stamp2] : [t.stamp];
  const sp = [[0, 'opacity:0;transform:scale(.5)']]; stamps.forEach(x => sp.push([x - .01, 'opacity:0;transform:scale(.5)'], [x + .03, 'opacity:1;transform:scale(.8)', E.out], [x + .3, 'opacity:0;transform:scale(1.4)'])); sp.push([T, 'opacity:0;transform:scale(1.4)']);
  kf(`spark${p}`, sp);
  kf(`door${p}`, [[0, ty(0)], [t.door[0], ty(0), E.out], [t.door[1], ty(-62)], [t.doorDown[0], ty(-62), E.io], [t.doorDown[1], ty(0)], [T, ty(0)]]);
  kf(`lampR${p}`, [[0, op(0)], [t.hold[0], op(0)], [t.hold[0] + .03, op(1)], [t.hold[0] + .23, op(.2)], [t.hold[0] + .4, op(1)], [t.hold[0] + .57, op(.2)], [t.hold[0] + .74, op(1)], [t.flip, op(0)], [T, op(0)]]);
  kf(`lampG${p}`, [[0, op(0)], [t.flip - .01, op(0)], [t.flip + .03, op(1)], [t.m5[1] + .3, op(1)], [t.m5[1] + .6, op(0)], [T, op(0)]]);
  kf(`glow${p}`, [[0, 'opacity:0;transform:scale(.5)'], [t.flip, 'opacity:0;transform:scale(.5)', E.out], [t.flip + .3, 'opacity:1;transform:scale(1.25)', E.io], [t.flip + .85, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .3, 'opacity:.55;transform:scale(1)'], [t.m5[1] + .6, 'opacity:0;transform:scale(.8)'], [T, 'opacity:0;transform:scale(.8)']]);
  kf(`dPlan${p}`, [[0, ty(0)], [T, ty(0)]]);                        // Sam's drone just hovers: its beam does the printing
}
lineKF('B', TB); lineKF('A', TA);
const SQ = (p, events) => {
  const fr = [[0, 'transform:scale(1,1)']];
  for (const [at, k] of events) fr.push([at - .02, 'transform:scale(1,1)'], [at + .05, `transform:scale(${1 + .06 * k},${1 - .12 * k})`, E.out], [at + .2, `transform:scale(${1 - .015 * k},${1 + .03 * k})`], [at + .36, 'transform:scale(1,1)']);
  fr.push([T, 'transform:scale(1,1)']); kf(`sq${p}`, fr);
};
// front line B (global clock)
{
  const t = TB, p = 'B';
  const fwd = [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...t.m4, DX[4]], [...t.m5, DX[5]]];
  const tail = fr => [...fr.filter(f => f[0] < t.reset), [t.reset, tx(DX[5])], [t.reset + .001, tx(0)], [T, tx(0)]];
  kf(`mx${p}`, tail(moves(0, fwd, tx))); kf(`belt${p}`, tail(moves(0, fwd, tx)));
  kf(`my${p}`, [[0, ty(-DROP)], [t.drop[0], ty(-DROP), E.drop], [t.drop[1], ty(0)], [t.reset, ty(0)], [t.reset + .001, ty(-DROP)], [T, ty(-DROP)]]);
  kf(`vis${p}`, [[0, op(0)], [t.pop[0] - .001, op(0)], [t.pop[0], op(1)], [t.grip - .001, op(1)], [t.grip, op(0)], [T, op(0)]]);
  kf(`pop${p}`, [[0, 'transform:scale(0)'], [t.pop[0], 'transform:scale(0)', E.back], [t.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1]]);
  t.ticks.forEach((x, i) => kf(`tk${i + 1}${p}`, [[0, 'stroke-dashoffset:14'], [x - .12, 'stroke-dashoffset:14', E.out], [x + .02, 'stroke-dashoffset:0'], [t.reset, 'stroke-dashoffset:0'], [t.reset + .001, 'stroke-dashoffset:14'], [T, 'stroke-dashoffset:14']]));
  kf(`dDev${p}`, [[0, ty(0)], [t.stamp - .7, ty(0), E.out], [t.stamp - .48, ty(-6), E.slam], [t.stamp, ty(28)], [t.stamp + .15, ty(28), E.out], [t.stamp + .5, ty(0)], [T, ty(0)]]);
  const [fx, fy] = P(XS.rev - PW / 2, TOPY, ZF + ZL[p]), lr = lensRest(p);
  const rowY = i => fy + 7 + 16 + i * 7.5 + 3 - lr[1], x0 = fx + 6 + 7 - lr[0], x1 = fx + 6 + 36 - lr[0];
  kf(`dRev${p}`, [[0, txy(0, 0)], [t.read[0], txy(0, 0), E.out], [t.read[0] + .28, txy(x0, rowY(0)), E.io], [t.ticks[0], txy(x1, rowY(0)), E.io], [t.ticks[0] + .1, txy(x0, rowY(1)), E.io], [t.ticks[1], txy(x1, rowY(1)), E.io], [t.ticks[1] + .1, txy(x0, rowY(2)), E.io], [t.ticks[2], txy(x1, rowY(2)), E.out], [t.read[1], txy(0, 0)], [T, txy(0, 0)]]);
}
// back line A (own clock): fails once, courier back to DEV, fix, second review
{
  const t = TA, p = 'A', c = t.cour;
  const cardX = [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...c.fly, DX[2], E.io], [...t.m3b, DX[3]], [...t.m4, DX[4]], [...t.m5, DX[5]]];
  kf(`mx${p}`, [...moves(0, cardX, tx).filter(f => f[0] < t.reset), [t.reset, tx(DX[5])], [t.reset + .001, tx(0)], [T, tx(0)]]);
  kf(`belt${p}`, moves(0, [[...t.m1, DX[1]], [...t.m2, DX[2]], [...t.m3, DX[3]], [...t.m3b, DX[3] + SP], [...t.m4, DX[4] + SP], [...t.m5, DX[5] + SP]], tx));   // 580 = 29 treads
  kf(`my${p}`, [[0, ty(-DROP)], [t.drop[0], ty(-DROP), E.drop], [t.drop[1], ty(0)], [c.lift[0], ty(0), E.io], [c.lift[1], ty(-LIFT)], [c.lower[0], ty(-LIFT), E.io], [c.lower[1], ty(0)], [t.reset, ty(0)], [t.reset + .001, ty(-DROP)], [T, ty(-DROP)]]);
  kf(`vis${p}`, [[0, op(1)], [t.grip - .001, op(1)], [t.grip, op(0)], [T - .001, op(0)], [T, op(1)]]);
  kf(`pop${p}`, [[0, 'transform:scale(0)', E.back], [t.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1], [c.lower[1], .6], [t.stamp2, 1.1]]);
  [t.tick1, ...t.ticks2].forEach((x, i) => kf(`tk${i + 1}${p}`, [[0, 'stroke-dashoffset:14'], [x - .12, 'stroke-dashoffset:14', E.out], [x + .02, 'stroke-dashoffset:0'], [t.reset, 'stroke-dashoffset:0'], [t.reset + .001, 'stroke-dashoffset:14'], [T, 'stroke-dashoffset:14']]));
  kf('crossA', [[0, 'opacity:0;transform:scale(.4)'], [t.cross - .001, 'opacity:0;transform:scale(.4)'], [t.cross, 'opacity:1;transform:scale(.4)', E.back], [t.cross + .2, 'opacity:1;transform:scale(1)'], [t.stamp2, 'opacity:1;transform:scale(1)'], [t.stamp2 + .12, 'opacity:0;transform:scale(1)'], [T, 'opacity:0;transform:scale(1)']]);
  kf('badgeA', [[0, 'opacity:0;transform:scale(0)'], [t.cross + .05, 'opacity:0;transform:scale(0)'], [t.cross + .06, 'opacity:1;transform:scale(0)', E.back], [t.cross + .35, 'opacity:1;transform:scale(1)'], [t.stamp2, 'opacity:1;transform:scale(1)'], [t.stamp2 + .15, 'opacity:0;transform:scale(.6)'], [T, 'opacity:0;transform:scale(.6)']]);
  kf('lensRedA', [[0, op(0)], [t.cross - .02, op(0)], [t.cross, op(1)], [c.lift[0], op(1)], [c.lift[0] + .15, op(0)], [T, op(0)]]);
  // Nick's drone: first stamp, lifts out of the courier's way, comes back, second stamp (the fix)
  kf(`dDev${p}`, [[0, ty(0)], [t.stamp - .7, ty(0), E.out], [t.stamp - .48, ty(-6), E.slam], [t.stamp, ty(28)], [t.stamp + .15, ty(28), E.out], [t.stamp + .5, ty(0)],
    [t.devUp[0], ty(0), E.io], [t.devUp[1], ty(-32)], [t.devDown[0], ty(-32), E.io], [t.devDown[1], ty(0)],
    [t.stamp2 - .7, ty(0), E.out], [t.stamp2 - .48, ty(-6), E.slam], [t.stamp2, ty(28)], [t.stamp2 + .15, ty(28), E.out], [t.stamp2 + .5, ty(0)], [T, ty(0)]]);
  // Morgan's drone: reads (row 1 ok, row 2 fails), carries the card back to Nick, flies home; second read passes
  const [fx, fy] = P(XS.rev - PW / 2, TOPY, ZF + ZL[p]), lr = lensRest(p);
  const rowY = i => fy + 7 + 16 + i * 7.5 + 3 - lr[1], x0 = fx + 6 + 7 - lr[0], x1 = fx + 6 + 36 - lr[0];
  const onTop = HOVER - (TOPY + 4);                                  // body resting on the card's top
  kf(`dRev${p}`, [[0, txy(0, 0)], [t.read1[0], txy(0, 0), E.out], [t.read1[0] + .28, txy(x0, rowY(0)), E.io], [t.tick1, txy(x1, rowY(0)), E.io], [t.tick1 + .1, txy(x0, rowY(1)), E.io], [t.cross, txy(x1, rowY(1))],
    [c.toTop[0], txy(x1, rowY(1)), E.io], [c.toTop[1], txy(0, onTop)], [c.lift[0], txy(0, onTop), E.io], [c.lift[1], txy(0, onTop - LIFT)],
    [c.fly[0], txy(0, onTop - LIFT), E.io], [c.fly[1], txy(-SP, onTop - LIFT)], [c.lower[0], txy(-SP, onTop - LIFT), E.io], [c.lower[1], txy(-SP, onTop)],
    [c.home[0], txy(-SP, onTop), E.io], [c.home[1], txy(0, 0)],
    [t.read2[0], txy(0, 0), E.out], [t.read2[0] + .28, txy(x0, rowY(1)), E.io], [t.ticks2[0], txy(x1, rowY(1)), E.io], [t.ticks2[0] + .1, txy(x0, rowY(2)), E.io], [t.ticks2[1], txy(x1, rowY(2)), E.out], [t.read2[1], txy(0, 0)], [T, txy(0, 0)]]);
}
// the arms (global clock)
function armKF(p, a, gripAt) {
  const { pose } = ARMS[p];
  const seq = sel => [[0, rot(sel(pose.home))], [a.down[0], rot(sel(pose.home)), E.io], [a.down[1], rot(sel(pose.pick))], [a.swing[0], rot(sel(pose.pick)), E.io], [a.swing[1], rot(sel(pose.place))], [a.back[0], rot(sel(pose.place)), E.io], [a.back[1], rot(sel(pose.home))], [T, rot(sel(pose.home))]];
  kf(`sh${p}`, seq(q => q.t1)); kf(`el${p}`, seq(q => q.t2)); kf(`wr${p}`, seq(q => -(q.t1 + q.t2)));
  kf(`carry${p}`, [[0, op(0)], [gripAt - .001, op(0)], [gripAt, op(1)], [a.swing[1] - .001, op(1)], [a.swing[1], op(0)], [T, op(0)]]);
  const r = a.swing[1];
  kf(`land${p}`, [[0, op(0)], [r - .001, op(0)], [r, op(1)], [T, op(1)]]);
  kf(`msq${p}`, [[0, 'transform:scale(1,1)'], [r, 'transform:scale(1,1)'], [r + .06, 'transform:scale(1.05,.92)', E.out], [r + .24, 'transform:scale(.99,1.02)'], [r + .4, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
}
armKF('B', TB.arm, TB.grip); armKF('A', ARM_A, glob(TA.grip));
{
  const fr = [[0, txy(0, 0)]]; let n = 0;
  for (const [a, b] of MOVES) { fr.push([a, txy(...slotShift(n)), E.move]); n++; fr.push([b, txy(...slotShift(n))]); }
  if (fr[fr.length - 1][0] < T) fr.push([T, txy(...slotShift(n))]);
  kf('mstrip', fr);
  kf('occB', [[0, op(0)], [MOVES[1][1] - .001, op(0)], [MOVES[1][1], op(1)], [MOVES[2][0], op(1)], [MOVES[2][0] + .001, op(0)], [T, op(0)]]);
  kf('occA', [[0, op(0)], [MOVES[2][1] - .001, op(0)], [MOVES[2][1], op(1)], [MOVES[3][0], op(1)], [MOVES[3][0] + .001, op(0)], [T, op(0)]]);
}
// labels (front line clock) + logo pulses on both verdicts
{
  const DIM = '#55506F', INK = '#1E1B3A', t = TB;
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

// ---------------------------------------------------------------- assemble (painter's order: back line, main, back arm, front line, front arm)
const occluder = (j, o, cls) => `<g class="a ${cls}"><g transform="translate(${f2(slotShift(o)[0])} ${f2(slotShift(o)[1])})">${mainStrip(j, true)}</g></g>`;
const BODY = [floor(), `<g>${brand()}</g>`, line('A'), armBase('A'), mainLane(), `<g class="a mstrip">${mainStrip()}</g>`, arm('A'), occluder(-2, 3, 'occA'),
  line('B'), armBase('B'), arm('B'), occluder(-3, 2, 'occB'),
  `<polygon fill="url(#farFade)" points="${pts([P(MX0 - 40, 0, 430), P(MX1 + 60, 0, 430), P(MX1 + 60, 150, 1300), P(MX0 - 40, 150, 1300)])}"/>`,
  `<rect x="980" y="${H - 22}" width="${W - 980}" height="22" fill="url(#nearFade)"/>`];
const per = ['cable', 'hook', 'fan', 'emit', 'scan', 'row1', 'row2', 'row3', 'stamp', 'spark', 'door', 'lampR', 'lampG', 'glow', 'dPlan', 'dDev', 'dRev', 'mx', 'belt', 'my', 'vis', 'pop', 'sq', 'tk1', 'tk2', 'tk3', 'sh', 'el', 'wr', 'carry', 'land', 'msq'];
const names = [...per.flatMap(n => [n + 'A', n + 'B']), 'crossA', 'badgeA', 'lensRedA', 'mstrip', 'occA', 'occB', 'halo', 'bump', 'sglow',
  ...['int', 'plan', 'dev', 'rev', 'lgtm'].flatMap(k => [`lbl-${k}`, `pip-${k}`]).filter(n => n !== 'pip-lgtm')];
const css = `
.a{animation-duration:${T}s;animation-iteration-count:infinite;animation-fill-mode:both;animation-delay:${f2(-mod(COLD, T))}s}
.pA .a{animation-delay:${f2(-mod(COLD - A_SHIFT, T))}s}
.spin{animation:spin .15s linear infinite;transform-box:fill-box;transform-origin:center}
@keyframes spin{0%{transform:scaleX(1)}50%{transform:scaleX(.25)}100%{transform:scaleX(1)}}
.bob{animation:bob 2.5s cubic-bezier(.45,0,.55,1) infinite alternate}
@keyframes bob{0%{transform:translateY(-1.6px)}100%{transform:translateY(1.6px)}}
.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.wm{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:42px;font-weight:700;letter-spacing:-1.5px}
.tag{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:14.5px;fill:#5B6472}
.lbl{font-size:12px;font-weight:600;letter-spacing:1.4px;fill:#55506F}
${names.map(n => `.${n}{animation-name:${n}}`).join('')}.pip-lgtm{opacity:0}
@media (prefers-reduced-motion:reduce){.a,.spin,.bob{animation-play-state:paused}}
`;
const defs = `<defs>
  <radialGradient id="gG"><stop offset="0" stop-color="#22C55E" stop-opacity=".5"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <radialGradient id="gR"><stop offset="0" stop-color="#F04438" stop-opacity=".42"/><stop offset="1" stop-color="#F04438" stop-opacity="0"/></radialGradient>
  <radialGradient id="gS" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#22C55E" stop-opacity=".45"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <linearGradient id="floorG" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#ECE9F1"/><stop offset="1" stop-color="#ECE9F1" stop-opacity="0"/></linearGradient>
  <linearGradient id="farFade" gradientUnits="userSpaceOnUse" x1="${f2(P(MXC, 40, 430)[0])}" y1="${f2(P(MXC, 40, 430)[1])}" x2="${f2(P(MXC, 40, 640)[0])}" y2="${f2(P(MXC, 40, 640)[1])}"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
  <linearGradient id="nearFade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
</defs>`;
const svg = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="lgtmgate: two production lines, one behind the other. On each, drones do the work: one prints the acceptance checklist on the issue's label, one stamps it a pull request, one reads and ticks every criterion, then the LGTM light turns from red to green. On the back line a criterion fails; the reviewing drone carries the parcel back to be fixed, and it passes the second time. Each line's arm then sets its pull request onto the main lane, among pull requests from other pipelines.">
<style>${css}${KF.join('\n')}</style>
${defs}
<rect width="${W}" height="${H}" fill="${BG}"/>
${BODY.join('\n')}
</svg>`;
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>lgtmgate header v6</title>
<style>html,body{margin:0;background:#ECEBF0}main{max-width:1280px;margin:0 auto;padding:40px 16px 56px}
.frame{border-radius:20px;overflow:hidden;box-shadow:0 1px 0 rgba(17,19,24,.04),0 12px 40px -12px rgba(17,19,24,.18)}
.frame svg{display:block;width:100%;height:auto}
p{font:13px -apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif;color:#5B6472;margin:14px 4px 0}</style></head>
<body><main><div class="frame">
<!-- Generated by gen-header-v6.mjs. One self-contained <svg>: CSS keyframes only, no JS, no web font. -->
${svg}
</div><p>Mockup v6 · 1280×344 · 16 s loop · SVG + CSS keyframes · respects prefers-reduced-motion on this page.</p></main></body></html>`;
writeFileSync(OUT, html);
console.log('ok', OUT, 'bytes', html.length, 'arms', JSON.stringify(Object.fromEntries(Object.entries(ARMS).map(([k, v]) => [k, Object.fromEntries(Object.entries(v.pose).map(([n, q]) => [n, [f2(q.t1), f2(q.t2)]]))]))));
