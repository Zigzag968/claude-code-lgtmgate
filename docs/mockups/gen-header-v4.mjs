// Usage: node docs/mockups/gen-header-v4.mjs docs/mockups/header-assembly-line-v4.html
// Optional 2nd arg: JSON overrides, e.g. '{"cold":6.2}'.
// Node stdlib only. Writes one self-contained HTML page (inline SVG + CSS keyframes, no JS in the output).
//
// v4: one production line in 3D (cabinet oblique, 45°, depth x0.5), read left to right:
// the issue is lowered onto the belt, Sam prints the acceptance checklist, Nick's press stamps
// "PR", Morgan's lens reads and ticks each criterion, the LGTM light goes red then green, then
// the Lead's articulated arm lifts the parcel over its head and sets it into the gap waiting on
// the `main` lane — where PRs from other pipelines are already flowing.
import { writeFileSync } from 'fs';
const OUT = process.argv[2];
const OPT = JSON.parse(process.argv[3] || '{}');

// ---------------------------------------------------------------- canvas / clock
const W = 1280, H = 344, T = 12;
const COLD = OPT.cold ?? 6.2;                 // global time shown at load: mid-review, verdict ~2.3 s later
const f2 = n => Math.round(n * 100) / 100;
const mod = (a, n) => ((a % n) + n) % n;

// ---------------------------------------------------------------- projection
const KX = 0.3536, KY = 0.3536, FLOOR = 300;
const P = (x, y, z) => [x + z * KX, FLOOR - y - z * KY];
const pts = a => a.map(p => `${f2(p[0])},${f2(p[1])}`).join(' ');

// ---------------------------------------------------------------- palette
const BG = '#F7F6F3';
const C = {
  'st-t': '#EEEDF3', 'st-f': '#DDDBE6', 'st-r': '#C9C6D6',          // structure
  'hs-t': '#EEEBFA', 'hs-f': '#DCD6F3', 'hs-r': '#C3BBE6',          // station columns
  'bt-t': '#E4E1EC', 'bt-f': '#CDC9DA', 'bt-r': '#B9B4CA',          // belts
  'mn-t': '#E6E2F4', 'mn-f': '#CFC8EA', 'mn-r': '#B7AEDC',          // main lane (slightly violet)
  'kr-t': '#F6DEB4', 'kr-f': '#ECC893', 'kr-r': '#D7AD71',          // kraft parcel
  'ag-t': '#B6AAFF', 'ag-f': '#8069FF', 'ag-r': '#5E48E6',          // agent tools
  'ac-t': '#4A4570', 'ac-f': '#35305A', 'ac-r': '#28244A',          // the Lead (dark)
  'tl-t': '#4A4570', 'tl-f': '#2E2A4F', 'tl-r': '#231F40',          // traffic light housing
};
const box = (x, y, z, w, h, d, m, extra = '') => {
  const f = [P(x, y, z), P(x + w, y, z), P(x + w, y + h, z), P(x, y + h, z)];
  const t = [P(x, y + h, z), P(x + w, y + h, z), P(x + w, y + h, z + d), P(x, y + h, z + d)];
  const r = [P(x + w, y, z), P(x + w, y, z + d), P(x + w, y + h, z + d), P(x + w, y + h, z)];
  return `<g${extra}><polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/></g>`;
};

// ---------------------------------------------------------------- keyframes
const E = {
  move: 'cubic-bezier(.77,0,.175,1)', out: 'cubic-bezier(.23,1,.32,1)', back: 'cubic-bezier(.34,1.56,.64,1)',
  slam: 'cubic-bezier(.7,0,1,.6)', exit: 'cubic-bezier(.5,0,.75,0)', io: 'cubic-bezier(.65,0,.35,1)',
  drop: 'cubic-bezier(.55,0,.85,.55)',
};
const KF = [];
const kf = (name, frames) => KF.push(`@keyframes ${name}{${frames.map(([t, css, e]) =>
  `${Math.round((t / T) * 100000) / 1000}%{${css}${e ? `;animation-timing-function:${e}` : ''}}`).join('')}}`);
const tx = x => `transform:translateX(${f2(x)}px)`;
const ty = y => `transform:translateY(${f2(y)}px)`;
const txy = (x, y) => `transform:translate(${f2(x)}px,${f2(y)}px)`;
const rot = a => `transform:rotate(${f2(a)}deg)`;
const op = o => `opacity:${o}`;
const step = (name, on, off, a = 1, b = 0) => kf(name, [[0, op(b)], [on - .001, op(b)], [on, op(a)], [off, op(a)], [off + .001, op(b)], [T, op(b)]]);

// ---------------------------------------------------------------- geometry
const BX0 = 380, BX1 = 1020, BH = 20, BD = 64;
const PW = 70, PHt = 52, PD = 50, ZF = (BD - PD) / 2, ZC = ZF + PD / 2;   // parcel; ZC = 32, the arm's plane
const TOPY = BH + PHt;                                                      // 72
const INT = 420, SP = 115, TREAD = 23;
const XS = { plan: INT + SP, dev: INT + 2 * SP, rev: INT + 3 * SP, lgtm: INT + 4 * SP, pick: INT + 4 * SP + 92 };
const DX = [0, SP, 2 * SP, 3 * SP, 4 * SP, 4 * SP + 92];                    // 552 = 24 treads -> seamless
const XG = XS.lgtm + PW / 2 + 8;
const HOIST = 110;                                                          // drop height

// timeline (global seconds; one parcel per loop)
const TL = {
  drop: [.10, 1.00], cableUp: [1.25, 1.80], m1: [1.45, 2.05], plan: [2.05, 3.25], m2: [3.25, 3.85],
  dev: [3.85, 4.85], m3: [4.85, 5.45], rev: [5.45, 7.05], m4: [7.05, 7.65], hold: [7.65, 8.45], flip: 8.45,
  door: [8.50, 8.90], m5: [8.95, 9.55], doorDown: [10.20, 10.60], pickDown: [9.55, 9.95], grip: 9.95,
  swing: [10.05, 10.95], release: 10.95, back: [11.05, 11.65], reset: 11.00, pop: [11.60, 11.95],
};

// ---------------------------------------------------------------- the parcel
// mode: 'live' (label layers animate), 'final' (checklist ticked + PR stamp), 'plain' (number only)
function parcel(num, mode) {
  const [fx, fy] = P(-PW / 2, TOPY, ZF);
  const cx = fx + 6, cy = fy + 7;
  const tape = [P(-7, TOPY, ZF), P(7, TOPY, ZF), P(7, TOPY, ZF + PD), P(-7, TOPY, ZF + PD)];
  let s = box(-PW / 2, BH, ZF, PW, PHt, PD, 'kr');
  s += `<polygon fill="#E3C38F" points="${pts(tape)}"/><rect fill="#E3C38F" x="${f2(fx + PW / 2 - 7)}" y="${f2(fy)}" width="14" height="5"/>`;
  s += `<rect fill="#fff" x="${f2(cx)}" y="${f2(cy)}" width="46" height="38" rx="2.5"/>`;
  s += `<text class="mono" fill="#1E1B3A" x="${f2(cx + 4)}" y="${f2(cy + 10)}" font-size="9" font-weight="700">${num}</text>`;
  if (mode === 'plain') return s;
  const live = mode === 'live';
  [0, 1, 2].forEach(i => {
    const y = cy + 16 + i * 7.5, w = [24, 19, 22][i];
    s += `<g${live ? ` class="a row${i + 1}" style="transform-origin:${f2(cx + 4)}px 0"` : ''}><rect x="${f2(cx + 4)}" y="${f2(y)}" width="6" height="6" rx="1.2" fill="none" stroke="#1E1B3A" stroke-width="1.2"/><line x1="${f2(cx + 14)}" y1="${f2(y + 3)}" x2="${f2(cx + 14 + w)}" y2="${f2(y + 3)}" stroke="#C5C8D2" stroke-width="2.2" stroke-linecap="round"/></g>`;
    s += `<path${live ? ` class="a tick${i + 1}"` : ''} d="M${f2(cx + 3)},${f2(y + 2.6)} l2.6,2.8 l5.4,-7" fill="none" stroke="#1E1B3A" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="14"${live ? '' : ' stroke-dashoffset="0"'}/>`;
  });
  s += `<g transform="translate(${f2(fx + PW - 11)},${f2(fy + 10)}) rotate(-12)"><g${live ? ' class="a stamp"' : ''}><rect x="-13" y="-7.5" width="26" height="15" rx="3" fill="#fff" fill-opacity=".92" stroke="#5B3DF5" stroke-width="1.7"/><text x="0" y="3.6" text-anchor="middle" class="mono" fill="#5B3DF5" font-size="10" font-weight="800">PR</text></g></g>`;
  return s;
}

// ---------------------------------------------------------------- the production line
function line() {
  let s = '';
  // station columns behind the belt, each with a violet tool arm over it
  const column = x => box(x - 14, 0, BD + 2, 28, 104, 20, 'hs') + box(x - 10, 96, 4, 20, 8, BD + 2, 'ag');
  s += column(XS.plan) + column(XS.dev) + column(XS.rev);
  s += box(XG - 1, 0, BD + 1, 7, 84, 7, 'st');                                  // gate back post
  // hoist over the intake
  s += box(INT - 40, 246, ZC - 8, 80, 6, 16, 'st') + box(INT - 12, 236, ZC - 9, 24, 10, 18, 'ac');
  // belt
  s += `<polygon fill="#1E1B3A" opacity=".07" points="${pts([P(BX0 + 6, 0, -3), P(BX1 + 8, 0, -3), P(BX1 + 24, 0, BD + 20), P(BX0 + 22, 0, BD + 20)])}"/>`;
  s += box(BX0, 0, 0, BX1 - BX0, BH, BD, 'bt');
  const topFace = [P(BX0, BH, 0), P(BX1, BH, 0), P(BX1, BH, BD), P(BX0, BH, BD)];
  let ticks = '';
  for (let x = BX0 - 552 + 8; x < BX1; x += TREAD) { const a = P(x, BH, 5), b = P(x, BH, BD - 5); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="beltClip"><polygon points="${pts(topFace)}"/></clipPath><g clip-path="url(#beltClip)"><path class="a pmove" d="${ticks}" stroke="#CFCADD" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  s += labels();
  // cable + hook (the parcel hangs from it until it lands)
  const hk = P(INT, 236, ZC);
  s += `<g transform="translate(${f2(hk[0])} ${f2(hk[1])})"><rect class="a cable" x="-.8" y="0" width="1.6" height="${236 - TOPY}" fill="#8C93A0" style="transform-origin:0 0"/><g class="a hook"><path d="M-4.5 -2 h9 l-4.5 5 z" fill="#2B2748"/></g></g>`;
  // the parcel
  const piv = P(0, BH, ZF);
  s += `<g transform="translate(${INT} 0)"><g class="a pvis"><g class="a pmove"><g class="a pdrop"><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g class="a psquash"><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g class="a ppop" style="transform-origin:${f2(P(0, TOPY, ZC)[0])}px ${f2(P(0, TOPY, ZC)[1])}px">${parcel('#142', 'live')}</g></g></g></g></g></g></g></g>`;
  // PLAN — Sam's scanner prints the acceptance criteria
  {
    const x = XS.plan, [fx, fy] = P(x - PW / 2, TOPY, ZF), hb = [P(x - 16, 84, 16), P(x + 16, 84, 16)];
    s += `<polygon class="a fan" fill="#7C66FF" fill-opacity=".16" points="${pts([hb[0], hb[1], [fx + PW + 4, fy + PHt + 2], [fx - 4, fy + PHt + 2]])}"/>`;
    s += `<g class="a scan"><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="2" stroke-linecap="round"/><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="7" stroke-linecap="round" opacity=".25"/></g>`;
    s += box(x - 18, 84, 14, 36, 12, 30, 'ag');
    const e = [P(x - 13, 84, 14), P(x + 13, 84, 14)];
    s += `<line class="a emit" x1="${f2(e[0][0])}" y1="${f2(e[0][1] - 1)}" x2="${f2(e[1][0])}" y2="${f2(e[1][1] - 1)}" stroke="#C9C0FF" stroke-width="2.5" stroke-linecap="round"/>`;
  }
  // DEV — Nick's press stamps the PR label
  {
    const x = XS.dev, rod = P(x, 96, 32);
    s += `<clipPath id="pressClip"><rect x="0" y="${f2(rod[1])}" width="1400" height="200"/></clipPath>`;
    s += `<g clip-path="url(#pressClip)"><g class="a press"><line x1="${f2(rod[0])}" y1="${f2(rod[1] - 40)}" x2="${f2(rod[0])}" y2="${f2(rod[1] + 16)}" stroke="#C9C6D6" stroke-width="6"/>${box(x - 26, 82, 12, 52, 14, 38, 'ag')}</g></g>`;
    const [cx, cy] = P(x, TOPY, ZF);
    const spark = d => `<g transform="translate(${f2(cx + d * 40)} ${f2(cy + 2)})"><g class="a spark"><path d="M${d * 3},0 l${d * 8},-2 M${d * 2},-5 l${d * 6},-6" stroke="#5B3DF5" stroke-width="2.2" stroke-linecap="round" fill="none"/></g></g>`;
    s += spark(-1) + spark(1);
  }
  // REVIEW — Morgan's lens reads each criterion, then ticks it
  {
    const x = XS.rev, rest = LENS_REST;
    s += `<clipPath id="lensClip"><rect x="0" y="${f2(P(0, 96, 4)[1])}" width="1400" height="200"/></clipPath>`;
    s += `<g clip-path="url(#lensClip)"><g transform="translate(${f2(rest[0])} ${f2(rest[1])})"><g class="a lens"><line x1="0" y1="-12" x2="0" y2="-160" stroke="#C9C6D6" stroke-width="2.6"/><circle r="12" fill="#fff" fill-opacity=".35" stroke="#8069FF" stroke-width="3.2"/><path d="M-6.5 -3.5 a7 7 0 0 1 3.5 -3.6" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/></g></g></g>`;
  }
  // LGTM gate: door (clipped to its closed shape), front post, lintel, traffic light
  {
    const dx = XG + 1, dw = 4;
    const cf = [P(dx, BH, 0), P(dx + dw, BH, 0), P(dx + dw, 80, 0), P(dx, 80, 0)];
    const cr = [P(dx + dw, BH, 0), P(dx + dw, BH, BD), P(dx + dw, 80, BD), P(dx + dw, 80, 0)];
    const ct = [P(dx, 80, 0), P(dx + dw, 80, 0), P(dx + dw, 80, BD), P(dx, 80, BD)];
    s += `<clipPath id="doorClip"><polygon points="${pts(cf)}"/><polygon points="${pts(cr)}"/><polygon points="${pts(ct)}"/></clipPath>`;
    s += `<g clip-path="url(#doorClip)"><g class="a door">${box(dx, BH, 0, dw, 60, BD, 'st')}</g></g>`;
    s += box(XG - 1, 0, -8, 7, 84, 7, 'st') + box(XG - 3, 84, -8, 11, 7, BD + 17, 'st');
    const lx = XG + 2.5, lz = -10;
    s += box(lx - 8, 91, lz, 16, 34, 10, 'tl');
    const [rx, ry] = P(lx, 116, lz), [gx, gy] = P(lx, 100, lz);
    s += `<circle class="a glowg" cx="${f2(gx)}" cy="${f2(gy)}" r="44" fill="url(#gG)" style="transform-box:fill-box;transform-origin:center"/>`;
    s += `<circle class="a lampr" cx="${f2(rx)}" cy="${f2(ry)}" r="32" fill="url(#gR)"/>`;
    s += `<circle fill="#4A4568" cx="${f2(rx)}" cy="${f2(ry)}" r="5.8"/><circle fill="#4A4568" cx="${f2(gx)}" cy="${f2(gy)}" r="5.8"/>`;
    s += `<circle class="a lampr" fill="#F04438" cx="${f2(rx)}" cy="${f2(ry)}" r="5.8"/><circle class="a lampg" fill="#22C55E" cx="${f2(gx)}" cy="${f2(gy)}" r="5.8"/>`;
  }
  return s;
}
const LENS_REST = [XS.rev - 7 + ZF * KX, P(0, 84, 3)[1]];

// station names stencilled on the belt's front face
function labels() {
  const items = [['int', 'ISSUE'], ['plan', 'PLAN · Sam'], ['dev', 'DEV · Nick'], ['rev', 'REVIEW · Morgan'], ['lgtm', 'LGTM']];
  const X = { int: INT, ...XS };
  return items.map(([k, t]) => {
    const [x, y] = P(X[k], 5.4, 0);
    return `<circle class="a pip-${k}" cx="${f2(x - t.length * 3.75 - 7)}" cy="${f2(y - 3.8)}" r="2.5" fill="#5B3DF5"/><text class="a lbl lbl-${k} mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;
  }).join('');
}

// ---------------------------------------------------------------- main lane (runs away from us along z)
const MX0 = 1130, MX1 = 1200, MXC = (MX0 + MX1) / 2 + 0;            // belt x span; parcels centred on MXC
const PITCH = 180, MTREAD = 20;                                     // 3 slots per loop = 540 = 27 treads
const zSlot = q => ZF + q * PITCH;                                  // parcel front z for slot q (q=0: drop point)
const slotShift = n => [n * PITCH * KX, -n * PITCH * KY];
function mainLane() {
  let s = '';
  const z0 = -260, z1 = 820;
  s += `<polygon fill="#1E1B3A" opacity=".07" points="${pts([P(MX0 + 8, 0, z0), P(MX1 + 14, 0, z0), P(MX1 + 14, 0, z1), P(MX0 + 8, 0, z1)])}"/>`;
  s += box(MX0 - 4, 0, z0, MX1 - MX0 + 8, BH, z1 - z0, 'mn');
  const topFace = [P(MX0 - 4, BH, z0), P(MX1 + 4, BH, z0), P(MX1 + 4, BH, z1), P(MX0 - 4, BH, z1)];
  let ticks = '';
  for (let z = z0 - 3 * PITCH; z < z1; z += MTREAD) { const a = P(MX0, BH, z), b = P(MX1, BH, z); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="mainClip"><polygon points="${pts(topFace)}"/></clipPath><g clip-path="url(#mainClip)"><path class="a mstrip" d="${ticks}" stroke="#D6CFEE" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  // "main", stencilled on the lane's right side face (branch glyph + word)
  const o = P(MX1 + 4, 5, -40);
  s += `<g transform="matrix(${KX * 2} ${-KY * 2} 0 1 ${f2(o[0])} ${f2(o[1])})"><g fill="none" stroke="#5B3DF5" stroke-width="1.4" stroke-linecap="round"><circle cx="3" cy="-8" r="2"/><circle cx="3" cy="0" r="2"/><circle cx="10" cy="-6" r="2"/><path d="M3 -6 v4 M10 -4 c0 3 -4 3 -6 4"/></g><text x="16" y="1" class="mono" fill="#5B3DF5" font-size="11" font-weight="700" letter-spacing=".5">main</text></g>`;
  return s;
}
// the moving row of parcels on main: j = slot index in the strip's own frame (q = j + offset)
// gaps (j ≡ 1 mod 3) are the slots waiting for this pipeline's PRs; the others come from other pipelines
const OTHER = { 0: '#139', 2: '#141' };
function mainStrip(onlyJ) {
  let s = '';
  for (let j = 5; j >= -6; j--) {
    if (onlyJ !== undefined && j !== onlyJ) continue;
    const kind = mod(j, 3) === 1 ? 'ours' : 'other';
    const [dx, dy] = slotShift(j);
    const body = kind === 'ours' ? parcel('#142', 'final') : parcel(OTHER[mod(j, 3)], 'final');
    const vis = kind === 'ours' ? (j >= 1 ? '' : j === -2 ? ' class="a landed"' : ' opacity="0"') : '';
    const piv = P(MXC, BH, ZF);
    s += `<g transform="translate(${f2(dx)} ${f2(dy)})"${vis}><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g${j === -2 ? ' class="a msquash"' : ''}><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g transform="translate(${MXC} 0)">${body}</g></g></g></g></g>`;
  }
  return s;
}

// ---------------------------------------------------------------- the Lead: articulated arm between the line and main
const SH = P(1056, 46, ZC), L1 = 80, L2 = 74, GRIP = 19;
const TOOL = { pick: P(XS.pick, TOPY, ZC), place: P(MXC, TOPY, ZC) };
TOOL.home = [SH[0], TOOL.pick[1] - 70];
function ik([tx_, ty_], prefer) {
  const wx = tx_, wy = ty_ - GRIP, dx = wx - SH[0], dy = wy - SH[1], d = Math.hypot(dx, dy);
  const c = Math.max(-1, Math.min(1, (d * d - L1 * L1 - L2 * L2) / (2 * L1 * L2)));
  const sols = [Math.acos(c), -Math.acos(c)].map(t2 => {
    const t1 = Math.atan2(dy, dx) - Math.atan2(L2 * Math.sin(t2), L1 + L2 * Math.cos(t2));
    return { t1: t1 * 180 / Math.PI, t2: t2 * 180 / Math.PI };
  });
  return prefer > 0 ? sols[0] : sols[1];
}
// elbow-up on both sides: the arm reaches down from above at pick and at place, and the swing
// between them passes through the upright pose, lifting the parcel over the Lead's head
const POSE = { home: ik(TOOL.home, -1), pick: ik(TOOL.pick, -1), place: ik(TOOL.place, 1) };
function arm() {
  const cap = (len, th) => `<rect x="${-th / 2}" y="${-th / 2}" width="${len + th}" height="${th}" rx="${th / 2}"/>`;
  const topC = P(0, TOPY, ZC);
  const carried = `<g class="a carry"><g transform="translate(${f2(-topC[0])} ${f2(GRIP - topC[1])})">${parcel('#142', 'final')}</g></g>`;
  return `<g transform="translate(${f2(SH[0])} ${f2(SH[1])})"><g class="a sh">
      <g fill="#2B2748">${cap(L1, 16)}</g><line x1="4" y1="-5.5" x2="${L1 - 4}" y2="-5.5" stroke="#4A4478" stroke-width="2" stroke-linecap="round"/>
      <g transform="translate(${L1} 0)"><g class="a el">
        <g fill="#2B2748">${cap(L2, 13)}</g><line x1="4" y1="-4.5" x2="${L2 - 4}" y2="-4.5" stroke="#4A4478" stroke-width="1.8" stroke-linecap="round"/>
        <g transform="translate(${L2} 0)"><g class="a wr">
          ${carried}
          <rect x="-3" y="0" width="6" height="${GRIP - 5}" fill="#2B2748"/><rect x="-13" y="${GRIP - 6}" width="26" height="6" rx="2" fill="#8069FF"/>
          <circle r="7" fill="#8069FF"/><circle r="2.4" fill="#2B2748"/>
        </g></g>
        <circle r="8" fill="#8069FF"/><circle r="2.8" fill="#2B2748"/>
      </g></g>
      <circle r="9.5" fill="#8069FF"/><circle r="3.2" fill="#2B2748"/>
    </g></g>`;
}
function armBase() {
  const [lx, ly] = P(1056, 12, 12);
  return `<polygon fill="#1E1B3A" opacity=".09" points="${pts([P(1030, 0, 6), P(1086, 0, 6), P(1092, 0, 62), P(1036, 0, 62)])}"/>`
    + box(1034, 0, 10, 44, 12, 44, 'ac') + box(1045, 12, 21, 22, 34, 22, 'ac')
    + `<text x="${f2(lx)}" y="${f2(ly + 8.5)}" text-anchor="middle" class="mono" fill="#C9C0FF" font-size="7.5" font-weight="700" letter-spacing="1">LEAD</text>`;
}

// ---------------------------------------------------------------- floor, brand
function floor() {
  const a = P(350, 0, -120), b = P(1300, 0, -120), c = P(1300, 0, 520), d = P(350, 0, 520);
  let g = `<polygon points="${pts([a, b, c, d])}" fill="url(#floorG)"/>`;
  for (const z of [-60, 140, 300]) { const l = P(360, 0, z), r = P(1300, 0, z); g += `<line x1="${f2(l[0])}" y1="${f2(l[1])}" x2="${f2(r[0])}" y2="${f2(r[1])}" stroke="#E9E6EF" stroke-width="1"/>`; }
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

// ---------------------------------------------------------------- animations (all on one 12 s clock)
const X = DX;
kf('pmove', [[0, tx(0)], [TL.m1[0], tx(0), E.move], [TL.m1[1], tx(X[1])], [TL.m2[0], tx(X[1]), E.move], [TL.m2[1], tx(X[2])],
  [TL.m3[0], tx(X[2]), E.move], [TL.m3[1], tx(X[3])], [TL.m4[0], tx(X[3]), E.move], [TL.m4[1], tx(X[4])],
  [TL.m5[0], tx(X[4]), E.move], [TL.m5[1], tx(X[5])], [TL.reset, tx(X[5])], [TL.reset + .001, tx(0)], [T, tx(0)]]);
kf('pdrop', [[0, ty(-HOIST)], [TL.drop[0], ty(-HOIST), E.drop], [TL.drop[1], ty(0)], [TL.reset, ty(0)], [TL.reset + .001, ty(-HOIST)], [T, ty(-HOIST)]]);
kf('pvis', [[0, op(1)], [TL.grip - .001, op(1)], [TL.grip, op(0)], [TL.pop[0] - .001, op(0)], [TL.pop[0], op(1)], [T, op(1)]]);
kf('ppop', [[0, 'transform:scale(1)'], [TL.pop[0] - .001, 'transform:scale(1)'], [TL.pop[0], 'transform:scale(0)', E.back], [TL.pop[1], 'transform:scale(1)'], [T, 'transform:scale(1)']]);
kf('psquash', [[0, 'transform:scale(1,1)'], [TL.drop[1] - .02, 'transform:scale(1,1)'], [TL.drop[1] + .06, 'transform:scale(1.06,.9)', E.out], [TL.drop[1] + .22, 'transform:scale(.98,1.03)'], [TL.drop[1] + .38, 'transform:scale(1,1)'],
  [4.24, 'transform:scale(1,1)'], [4.29, 'transform:scale(1.07,.86)', E.out], [4.45, 'transform:scale(.98,1.03)'], [4.62, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
kf('cable', [[0, `transform:scaleY(${f2((236 - TOPY - HOIST) / (236 - TOPY))})`], [TL.drop[0], `transform:scaleY(${f2((236 - TOPY - HOIST) / (236 - TOPY))})`, E.drop], [TL.drop[1], 'transform:scaleY(1)'],
  [TL.cableUp[0], 'transform:scaleY(1)', E.out], [TL.cableUp[1], `transform:scaleY(${f2((236 - TOPY - HOIST) / (236 - TOPY))})`], [T, `transform:scaleY(${f2((236 - TOPY - HOIST) / (236 - TOPY))})`]]);
kf('hook', [[0, ty(236 - TOPY - HOIST)], [TL.drop[0], ty(236 - TOPY - HOIST), E.drop], [TL.drop[1], ty(236 - TOPY)], [TL.cableUp[0], ty(236 - TOPY), E.out], [TL.cableUp[1], ty(236 - TOPY - HOIST)], [T, ty(236 - TOPY - HOIST)]]);
[2.30, 2.60, 2.90].forEach((t, i) => kf(`row${i + 1}`, [[0, 'opacity:0;transform:scaleX(0)'], [t, 'opacity:0;transform:scaleX(0)', E.out], [t + .22, 'opacity:1;transform:scaleX(1)'], [TL.reset, 'opacity:1;transform:scaleX(1)'], [TL.reset + .001, 'opacity:0;transform:scaleX(0)'], [T, 'opacity:0;transform:scaleX(0)']]));
[6.00, 6.40, 6.80].forEach((t, i) => kf(`tick${i + 1}`, [[0, 'stroke-dashoffset:14'], [t - .12, 'stroke-dashoffset:14', E.out], [t + .02, 'stroke-dashoffset:0'], [TL.reset, 'stroke-dashoffset:0'], [TL.reset + .001, 'stroke-dashoffset:14'], [T, 'stroke-dashoffset:14']]));
kf('stamp', [[0, 'opacity:0;transform:scale(1.5)'], [4.24, 'opacity:0;transform:scale(1.5)'], [4.25, 'opacity:1;transform:scale(1.5)', E.back], [4.47, 'opacity:1;transform:scale(1)'], [TL.reset, 'opacity:1;transform:scale(1)'], [TL.reset + .001, 'opacity:0;transform:scale(1.5)'], [T, 'opacity:0;transform:scale(1.5)']]);
kf('fan', [[0, op(0)], [2.10, op(0)], [2.27, op(1)], [3.07, op(1)], [3.23, op(0)], [T, op(0)]]);
kf('emit', [[0, op(.25)], [2.10, op(.25)], [2.25, op(1)], [3.10, op(1)], [3.25, op(.25)], [T, op(.25)]]);
kf('scan', [[0, `${ty(0)};opacity:0`], [2.25, `${ty(0)};opacity:0`], [2.27, `${ty(0)};opacity:1`, E.io], [2.67, `${ty(PHt - 2)};opacity:1`, E.io], [3.07, `${ty(0)};opacity:1`], [3.15, `${ty(0)};opacity:0`], [T, `${ty(0)};opacity:0`]]);
kf('press', [[0, ty(0)], [3.85, ty(0), E.out], [4.07, ty(-6), E.slam], [4.25, ty(10)], [4.40, ty(10), E.out], [4.85, ty(0)], [T, ty(0)]]);
kf('spark', [[0, 'opacity:0;transform:scale(.5)'], [4.24, 'opacity:0;transform:scale(.5)'], [4.28, 'opacity:1;transform:scale(.8)', E.out], [4.55, 'opacity:0;transform:scale(1.4)'], [T, 'opacity:0;transform:scale(1.4)']]);
{
  const [fx, fy] = P(XS.rev - PW / 2, TOPY, ZF);
  const rowY = i => fy + 7 + 16 + i * 7.5 + 3 - LENS_REST[1];
  const x0 = fx + 6 + 7 - LENS_REST[0], x1 = fx + 6 + 36 - LENS_REST[0];
  kf('lens', [[0, txy(0, 0)], [5.45, txy(0, 0), E.out], [5.72, txy(x0, rowY(0)), E.io], [6.00, txy(x1, rowY(0)), E.io],
    [6.12, txy(x0, rowY(1)), E.io], [6.40, txy(x1, rowY(1)), E.io], [6.52, txy(x0, rowY(2)), E.io], [6.80, txy(x1, rowY(2)), E.out],
    [7.05, txy(0, 0)], [T, txy(0, 0)]]);
}
kf('door', [[0, ty(0)], [TL.door[0], ty(0), E.out], [TL.door[1], ty(-62)], [TL.doorDown[0], ty(-62), E.io], [TL.doorDown[1], ty(0)], [T, ty(0)]]);
kf('lampr', [[0, op(0)], [TL.hold[0], op(0)], [TL.hold[0] + .03, op(1)], [7.88, op(.2)], [8.05, op(1)], [8.22, op(.2)], [8.39, op(1)], [TL.flip, op(0)], [T, op(0)]]);
kf('lampg', [[0, op(0)], [TL.flip - .01, op(0)], [TL.flip + .03, op(1)], [TL.doorDown[0], op(1)], [TL.doorDown[1], op(0)], [T, op(0)]]);
kf('glowg', [[0, 'opacity:0;transform:scale(.5)'], [TL.flip, 'opacity:0;transform:scale(.5)', E.out], [TL.flip + .3, 'opacity:1;transform:scale(1.25)', E.io], [TL.flip + .85, 'opacity:.55;transform:scale(1)'], [TL.doorDown[0], 'opacity:.55;transform:scale(1)'], [TL.doorDown[1], 'opacity:0;transform:scale(.8)'], [T, 'opacity:0;transform:scale(.8)']]);
// labels
const DIM = '#55506F', INK = '#1E1B3A';
const lbl = (name, a, b, col = INK) => kf(name, [[0, `fill:${DIM}`], [a - .1, `fill:${DIM}`], [a, `fill:${col}`], [b, `fill:${col}`], [b + .1, `fill:${DIM}`], [T, `fill:${DIM}`]]);
const pip = (name, a, b) => kf(name, [[0, op(0)], [a - .1, op(0)], [a, op(1)], [b, op(1)], [b + .1, op(0)], [T, op(0)]]);
kf('lbl-int', [[0, `fill:${INK}`], [TL.m1[0], `fill:${INK}`], [TL.m1[0] + .1, `fill:${DIM}`], [TL.pop[0] - .1, `fill:${DIM}`], [TL.pop[0], `fill:${INK}`], [T, `fill:${INK}`]]);
kf('pip-int', [[0, op(1)], [TL.m1[0], op(1)], [TL.m1[0] + .1, op(0)], [TL.pop[0] - .1, op(0)], [TL.pop[0], op(1)], [T, op(1)]]);
lbl('lbl-plan', ...TL.plan); lbl('lbl-dev', ...TL.dev); lbl('lbl-rev', ...TL.rev);
pip('pip-plan', ...TL.plan); pip('pip-dev', ...TL.dev); pip('pip-rev', ...TL.rev);
kf('lbl-lgtm', [[0, `fill:${DIM}`], [TL.hold[0] - .1, `fill:${DIM}`], [TL.hold[0], 'fill:#C53030'], [TL.flip - .05, 'fill:#C53030'], [TL.flip + .05, 'fill:#15803D'], [TL.m5[1], 'fill:#15803D'], [TL.m5[1] + .2, `fill:${DIM}`], [T, `fill:${DIM}`]]);
// the Lead
const armKF = (name, sel) => kf(name, [[0, rot(sel(POSE.home))], [TL.pickDown[0], rot(sel(POSE.home)), E.io], [TL.pickDown[1], rot(sel(POSE.pick))],
  [TL.swing[0], rot(sel(POSE.pick)), E.io], [TL.swing[1], rot(sel(POSE.place))], [TL.back[0], rot(sel(POSE.place)), E.io], [TL.back[1], rot(sel(POSE.home))], [T, rot(sel(POSE.home))]]);
armKF('sh', p => p.t1); armKF('el', p => p.t2); armKF('wr', p => -(p.t1 + p.t2));
step('carry', TL.grip, TL.release - .001);
// main lane: three index moves per loop, the gap reaches the drop point at 8.0 and waits for our PR
const MOVES = [[3.2, 4.0], [7.2, 8.0], [11.2, 12.0]];
{
  const fr = [[0, txy(0, 0)]]; let n = 0;
  for (const [a, b] of MOVES) { fr.push([a, txy(...slotShift(n)), E.move]); n++; fr.push([b, txy(...slotShift(n))]); }
  if (fr[fr.length - 1][0] < T) fr.push([T, txy(...slotShift(n))]);
  kf('mstrip', fr);
}
kf('landed', [[0, op(0)], [TL.release - .001, op(0)], [TL.release, op(1)], [T, op(1)]]);   // hands over to its twin exactly at the seam
kf('msquash', [[0, 'transform:scale(1,1)'], [TL.release, 'transform:scale(1,1)'], [TL.release + .06, 'transform:scale(1.05,.92)', E.out], [TL.release + .24, 'transform:scale(.99,1.02)'], [TL.release + .4, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
step('occl', 8.0, 11.2 - .001);
// logo pulse on the verdict
kf('halo', [[0, 'opacity:0;transform:scale(1.45)'], [TL.flip, 'opacity:0;transform:scale(1)'], [TL.flip + .01, 'opacity:.8;transform:scale(1)', E.out], [TL.flip + 1.1, 'opacity:0;transform:scale(1.45)'], [T, 'opacity:0;transform:scale(1.45)']]);
kf('bump', [[0, 'transform:scale(1)'], [TL.flip, 'transform:scale(1)', E.out], [TL.flip + .12, 'transform:scale(1.06)', E.back], [TL.flip + .6, 'transform:scale(1)'], [T, 'transform:scale(1)']]);
kf('sglow', [[0, op(.35)], [TL.flip, op(.35)], [TL.flip + .1, op(1)], [TL.flip + 1.4, op(.35)], [T, op(.35)]]);

// ---------------------------------------------------------------- assemble
const css = `
.a{animation-duration:${T}s;animation-iteration-count:infinite;animation-fill-mode:both;animation-delay:${f2(-mod(COLD, T))}s}
.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.wm{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:42px;font-weight:700;letter-spacing:-1.5px}
.tag{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:14.5px;fill:#5B6472}
.lbl{font-size:12px;font-weight:600;letter-spacing:.8px;fill:${DIM}}
.pmove{animation-name:pmove}.pdrop{animation-name:pdrop}.pvis{animation-name:pvis}.ppop{animation-name:ppop}.psquash{animation-name:psquash}
.cable{animation-name:cable}.hook{animation-name:hook}
.row1{animation-name:row1}.row2{animation-name:row2}.row3{animation-name:row3}.tick1{animation-name:tick1}.tick2{animation-name:tick2}.tick3{animation-name:tick3}
.stamp{animation-name:stamp}.fan{animation-name:fan}.emit{animation-name:emit}.scan{animation-name:scan}.press{animation-name:press}.spark{animation-name:spark}
.lens{animation-name:lens}.door{animation-name:door}.lampr{animation-name:lampr}.lampg{animation-name:lampg}.glowg{animation-name:glowg}
.lbl-int{animation-name:lbl-int}.lbl-plan{animation-name:lbl-plan}.lbl-dev{animation-name:lbl-dev}.lbl-rev{animation-name:lbl-rev}.lbl-lgtm{animation-name:lbl-lgtm}
.pip-int{animation-name:pip-int}.pip-plan{animation-name:pip-plan}.pip-dev{animation-name:pip-dev}.pip-rev{animation-name:pip-rev}.pip-lgtm{opacity:0}
.sh{animation-name:sh}.el{animation-name:el}.wr{animation-name:wr}.carry{animation-name:carry}
.mstrip{animation-name:mstrip}.landed{animation-name:landed}.msquash{animation-name:msquash}.occl{animation-name:occl}
.halo{animation-name:halo}.bump{animation-name:bump}.sglow{animation-name:sglow}
@media (prefers-reduced-motion:reduce){.a{animation-play-state:paused}}
`;
const defs = `<defs>
  <radialGradient id="gG"><stop offset="0" stop-color="#22C55E" stop-opacity=".5"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <radialGradient id="gR"><stop offset="0" stop-color="#F04438" stop-opacity=".42"/><stop offset="1" stop-color="#F04438" stop-opacity="0"/></radialGradient>
  <radialGradient id="gS" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#22C55E" stop-opacity=".45"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <linearGradient id="floorG" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#ECE9F1"/><stop offset="1" stop-color="#ECE9F1" stop-opacity="0"/></linearGradient>
  <linearGradient id="farFade" gradientUnits="userSpaceOnUse" x1="${f2(P(MXC, 40, 190)[0])}" y1="${f2(P(MXC, 40, 190)[1])}" x2="${f2(P(MXC, 40, 360)[0])}" y2="${f2(P(MXC, 40, 360)[1])}"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
  <linearGradient id="nearFade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
</defs>`;
const occluder = `<g class="a occl"><g transform="translate(${f2(slotShift(2)[0])} ${f2(slotShift(2)[1])})">${mainStrip(-3)}</g></g>`;
const svg = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="lgtmgate: a GitHub issue is lowered onto an assembly line; Sam prints its acceptance checklist, Nick stamps it a pull request, Morgan ticks every criterion, the LGTM light turns from red to green, and the Lead's arm sets the approved PR onto the main lane among PRs from other pipelines.">
<style>${css}${KF.join('\n')}</style>
${defs}
<rect width="${W}" height="${H}" fill="${BG}"/>
${floor()}
<g>${brand()}</g>
${line()}
${armBase()}
${mainLane()}
<g class="a mstrip">${mainStrip()}</g>
${arm()}
${occluder}
<polygon fill="url(#farFade)" points="${pts([P(MX0 - 40, 0, 170), P(MX1 + 60, 0, 170), P(MX1 + 60, 130, 900), P(MX0 - 40, 130, 900)])}"/>
<rect x="1040" y="${H - 26}" width="${W - 1040}" height="26" fill="url(#nearFade)"/>
</svg>`;
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>lgtmgate header v4</title>
<style>html,body{margin:0;background:#ECEBF0}main{max-width:1280px;margin:0 auto;padding:40px 16px 56px}
.frame{border-radius:20px;overflow:hidden;box-shadow:0 1px 0 rgba(17,19,24,.04),0 12px 40px -12px rgba(17,19,24,.18)}
.frame svg{display:block;width:100%;height:auto}
p{font:13px -apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif;color:#5B6472;margin:14px 4px 0}</style></head>
<body><main><div class="frame">
<!-- Generated by gen-header-v4.mjs. One self-contained <svg>: CSS keyframes only, no JS, no web font. -->
${svg}
</div><p>Mockup v4 · 1280×344 · 12 s loop · SVG + CSS keyframes · respects prefers-reduced-motion on this page.</p></main></body></html>`;
writeFileSync(OUT, html);
console.log('ok', OUT, 'bytes', html.length, 'poses', JSON.stringify(Object.fromEntries(Object.entries(POSE).map(([k, v]) => [k, [f2(v.t1), f2(v.t2)]]))));
