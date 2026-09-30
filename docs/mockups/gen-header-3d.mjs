// Usage: node docs/mockups/gen-header-3d.mjs docs/mockups/header-assembly-line-3d.html
// Optional 2nd arg: JSON overrides, e.g. '{"cold":7.15,"vp":[1150,-231]}'.
// Node stdlib only. Writes one self-contained HTML page (inline SVG + CSS keyframes, no JS in the output).

// Generator for the 3D assembly-line header (v3).
// Output: one self-contained HTML page with an inline SVG animated by CSS keyframes only.
import { writeFileSync } from 'fs';
const OUT = process.argv[2];
const OPT = JSON.parse(process.argv[3] || '{}');

// ---------------------------------------------------------------- canvas / clock
const W = 1280, H = 344;
const T = 12;                               // one loop = 12 s, one new issue every 4 s
const COLD = OPT.cold ?? 7.15;              // global time shown at load (cold open)
const f2 = n => Math.round(n * 100) / 100;
const pct = t => `${f2((t / T) * 100 * 10) / 10}%`.replace(/(\.\d)\d+%/, '$1%');

// ---------------------------------------------------------------- projection
// Objects: cabinet oblique (45°, depth x0.5). Between lines: true perspective
// (each line is a uniform scale about the vanishing point VP).
const KX = 0.3536, KY = 0.3536;
const FLOOR = 334;
const P = (x, y, z) => [x + z * KX, FLOOR - y - z * KY];
const pts = a => a.map(p => `${f2(p[0])},${f2(p[1])}`).join(' ');
const VP = OPT.vp ?? [1150, -231];
const LINES = [
  { s: 1,    haze: 0,   num: '#142' },
  { s: .8,   haze: .24, num: '#143' },
  { s: .64,  haze: .44, num: '#144' },
];
const persp = s => `translate(${VP[0]}px,${VP[1]}px) scale(${s}) translate(${-VP[0]}px,${-VP[1]}px)`;
const perspAttr = s => `translate(${VP[0]} ${VP[1]}) scale(${s}) translate(${-VP[0]} ${-VP[1]})`;

// ---------------------------------------------------------------- materials
const BG = '#F7F6F3';
const MAT = {
  'st-t': '#EEEDF3', 'st-f': '#DDDBE6', 'st-r': '#C9C6D6',        // structure
  'bt-t': '#E4E1EC', 'bt-f': '#CDC9DA', 'bt-r': '#B9B4CA', 'tr': '#CFCADD', // belt
  'kr-t': '#F6DEB4', 'kr-f': '#ECC893', 'kr-r': '#D7AD71', 'tp': '#E3C38F', // kraft parcel
  'ag-t': '#B6AAFF', 'ag-f': '#8069FF', 'ag-r': '#5E48E6', 'ag-l': '#C9C0FF', // agent tools
  'lb': '#FFFFFF', 'lbs': '#E2D6BE', 'ink': '#1E1B3A', 'rule': '#C5C8D2', 'pr': '#5B3DF5',
  'hs-t': '#EEEBFA', 'hs-f': '#DCD6F3', 'hs-r': '#C3BBE6', 'hg': '#8069FF',
  'tl-t': '#4A4570', 'tl-f': '#2E2A4F', 'tl-r': '#231F40', 'tlo': '#4A4568',
  'lo': '#DDDAE6', 'lr': '#F04438', 'lg': '#22C55E', 'fan': '#7C66FF', 'sh': '#1E1B3A',
};
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const mix = (a, b, t) => '#' + hex(a).map((c, i) => Math.round(c + (hex(b)[i] - c) * t).toString(16).padStart(2, '0')).join('');

// ---------------------------------------------------------------- easing + keyframes
const E = {
  move: 'cubic-bezier(.77,0,.175,1)', out: 'cubic-bezier(.23,1,.32,1)', back: 'cubic-bezier(.34,1.56,.64,1)',
  slam: 'cubic-bezier(.7,0,1,.6)', exit: 'cubic-bezier(.5,0,.75,0)', io: 'cubic-bezier(.65,0,.35,1)',
};
const KF = [];
function kf(name, frames, period = T) {
  const p = t => `${Math.round((t / period) * 100000) / 1000}%`;
  KF.push(`@keyframes ${name}{${frames.map(([t, css, e]) => `${p(t)}{${css}${e ? `;animation-timing-function:${e}` : ''}}`).join('')}}`);
}
const tx = x => `transform:translateX(${f2(x)}px)`;
const ty = y => `transform:translateY(${f2(y)}px)`;
const txy = (x, y) => `transform:translate(${f2(x)}px,${f2(y)}px)`;
const rot = a => `transform:rotate(${f2(a)}deg)`;
const op = o => `opacity:${o}`;

// ---------------------------------------------------------------- line geometry (line-1 coordinates)
const BX0 = 470, BX1 = 1250, BH = 18, BD = 56;
const PW = 62, PHt = 44, PD = 44, ZF = (BD - PD) / 2;       // parcel
const INT = 510;
const XS = { plan: INT + 130, dev: INT + 260, rev: INT + 390, lgtm: INT + 520, exit: INT + 702 };
const TREAD = 26;                                            // 702 = 27 treads -> seamless
const XG = XS.lgtm + PW / 2 + 8;                             // gate plane

// line-local timeline (s after the arm lets go of the parcel)
const L = {
  m1: [.40, 1.10], plan: [1.10, 2.30], m2: [2.30, 2.90], dev: [2.90, 3.90], m3: [3.90, 4.50],
  rev: [4.50, 6.10], m4: [6.10, 6.70], hold: [6.70, 7.50], flip: 7.50, exit: [8.00, 9.00], reset: 10,
};
const RELEASE = 1.75;                                          // within an arm slot
const TP = [0, 1, 2].map(k => 4 * k + RELEASE);               // global release time per line

function box(x, y, z, w, h, d, m, extra = '') {
  const f = [P(x, y, z), P(x + w, y, z), P(x + w, y + h, z), P(x, y + h, z)];
  const t = [P(x, y + h, z), P(x + w, y + h, z), P(x + w, y + h, z + d), P(x, y + h, z + d)];
  const r = [P(x + w, y, z), P(x + w, y, z + d), P(x + w, y + h, z + d), P(x + w, y + h, z)];
  return `<g${extra}><polygon class="f-${m}-r" points="${pts(r)}"/><polygon class="f-${m}-t" points="${pts(t)}"/><polygon class="f-${m}-f" points="${pts(f)}"/></g>`;
}

// ---------------------------------------------------------------- parcel (drawn at x=0, moved by transforms)
// Returns the parcel in line-1 coords centred on x=0. `live` adds the animated label layers.
function parcel(num, live) {
  const [fx, fy] = P(-PW / 2, BH + PHt, ZF);               // front-face top-left (screen)
  const cardX = fx + 5, cardY = fy + 6;
  const tapeTop = [P(-6, BH + PHt, ZF), P(6, BH + PHt, ZF), P(6, BH + PHt, ZF + PD), P(-6, BH + PHt, ZF + PD)];
  let s = box(-PW / 2, BH, ZF, PW, PHt, PD, 'kr');
  s += `<polygon class="f-tp" points="${pts(tapeTop)}"/><rect class="f-tp" x="${f2(fx + PW / 2 - 6)}" y="${f2(fy)}" width="12" height="5"/>`;
  s += `<rect class="f-lb" x="${f2(cardX)}" y="${f2(cardY)}" width="42" height="33" rx="2.5"/>`;
  s += `<text class="f-ink mono" x="${f2(cardX + 4)}" y="${f2(cardY + 9)}" font-size="8" font-weight="700">${num}</text>`;
  if (!live) return s;
  // PLAN prints three acceptance criteria
  [0, 1, 2].forEach(i => {
    const y = cardY + 14 + i * 6.5, w = [22, 17, 20][i];
    s += `<g class="a row${i + 1}" style="transform-origin:${f2(cardX + 4)}px 0"><rect class="s-ink" x="${f2(cardX + 4)}" y="${f2(y)}" width="5" height="5" rx="1" fill="none" stroke-width="1.1"/><line class="s-rule" x1="${f2(cardX + 13)}" y1="${f2(y + 2.5)}" x2="${f2(cardX + 13 + w)}" y2="${f2(y + 2.5)}" stroke-width="2" stroke-linecap="round"/></g>`;
    // REVIEW ticks it
    s += `<path class="a tick${i + 1} s-ink" d="M${f2(cardX + 3.2)},${f2(y + 2.2)} l2.2,2.4 l4.6,-6" fill="none" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="12"/>`;
  });
  // DEV stamps "PR" on the corner
  s += `<g transform="translate(${f2(fx + PW - 9)},${f2(fy + 9)}) rotate(-12)"><g class="a stamp"><rect x="-12" y="-7" width="24" height="14" rx="3" fill="#fff" fill-opacity=".9" class="s-pr" stroke-width="1.6"/><text x="0" y="3.4" text-anchor="middle" class="f-pr mono" font-size="9" font-weight="800">PR</text></g></g>`;
  return s;
}

// ---------------------------------------------------------------- one production line (line-1 coordinates)
function line(k) {
  const id = `L${k + 1}`;
  let s = '';
  // soft floor shadow under the belt

  // each station = one compact column behind the belt + an overhang reaching over the parcel
  const column = (x, glyph) => {
    let p = box(x - 13, 0, BD + 2, 26, 92, 18, 'hs');
    p += box(x - 9, 84, 4, 18, 8, BD + 2, 'ag');
    const [gx, gy] = P(x - 13, 92, BD + 2);
    return p;
  };
  s += column(XS.plan, '<path d="M-6 -4 h12 M-6 0 h9 M-6 4 h11"/>');
  s += column(XS.dev, '<path d="M-3 -4 l-4 4 l4 4 M3 -4 l4 4 l-4 4"/>');
  s += column(XS.rev, '<path d="M-6 0 l4 4 l8 -9"/>');
  // gate: back post (front post, lintel and stack light come after the parcel)
  s += box(XG - 1, 0, BD + 2, 7, 78, 7, 'st');
  // soft contact shadow of the belt on the floor
  s += `<polygon class="f-sh" opacity=".07" points="${pts([P(BX0 + 6, 0, -3), P(BX1 + 8, 0, -3), P(BX1 + 22, 0, BD + 18), P(BX0 + 20, 0, BD + 18)])}"/>`;

  // belt body + moving treads on its top face
  s += box(BX0, 0, 0, BX1 - BX0, BH, BD, 'bt');
  const topFace = [P(BX0, BH, 0), P(BX1, BH, 0), P(BX1, BH, BD), P(BX0, BH, BD)];
  let ticks = '';
  for (let x = BX0 - 702 + 8; x < BX1; x += TREAD) { const a = P(x, BH, 5), b = P(x, BH, BD - 5); ticks += `M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}`; }
  s += `<clipPath id="bc${id}"><polygon points="${pts(topFace)}"/></clipPath>`;
  s += `<g clip-path="url(#bc${id})"><path class="a pmove s-tr" d="${ticks}" stroke-width="3" stroke-linecap="round" fill="none"/></g>`;
  // drums
  s += `<circle class="f-bt-r" cx="${f2(P(BX0 + 9, 9, 0)[0])}" cy="${f2(P(BX0 + 9, 9, 0)[1])}" r="4"/><circle class="f-bt-r" cx="${f2(P(BX1 - 9, 9, 0)[0])}" cy="${f2(P(BX1 - 9, 9, 0)[1])}" r="4"/>`;

  // PLAN light fan (behind the parcel's front face? no: light falls on it -> drawn after the parcel below)
  // the parcel
  const piv = P(0, BH, ZF);
  s += `<g transform="translate(${INT} 0)"><g class="a pfade"><g class="a pmove"><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g class="a psquash"><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})">${parcel(LINES[k].num, true)}</g></g></g></g></g></g>`;

  // PLAN: scanner head, fan of light, scan line
  {
    const x = XS.plan;
    const [fx, fy] = P(x - PW / 2, BH + PHt, ZF);
    const hb = [P(x - 14, 74, 14), P(x + 14, 74, 14)];
    s += `<polygon class="a fan f-fan" points="${pts([hb[0], hb[1], [fx + PW + 4, fy + PHt + 2], [fx - 4, fy + PHt + 2]])}"/>`;
    s += `<g class="a scan"><line class="s-fan" x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke-width="2" stroke-linecap="round"/><line class="s-fan" x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke-width="7" stroke-linecap="round" opacity=".25"/></g>`;
    s += box(x - 16, 74, 12, 32, 10, 26, 'ag');
    const e = [P(x - 12, 74, 12), P(x + 12, 74, 12)];
    s += `<line class="a emit s-ag-l" x1="${f2(e[0][0])}" y1="${f2(e[0][1] - 1)}" x2="${f2(e[1][0])}" y2="${f2(e[1][1] - 1)}" stroke-width="2.5" stroke-linecap="round"/>`;
  }
  // DEV: press
  {
    const x = XS.dev;
    const rod = [P(x, 120, 28), P(x, 84, 28)];
    s += `<clipPath id="pc${id}"><rect x="0" y="${f2(P(0, 84, 28)[1])}" width="1400" height="200"/></clipPath>`;
    s += `<g clip-path="url(#pc${id})"><g class="a press"><line class="s-st" x1="${f2(rod[0][0])}" y1="${f2(rod[0][1] - 40)}" x2="${f2(rod[1][0])}" y2="${f2(rod[1][1] + 14)}" stroke-width="5"/>${box(x - 22, 72, 10, 44, 12, 34, 'ag')}</g></g>`;
    const [cx, cy] = P(x, BH + PHt, ZF);
    const spark = dir => `<g transform="translate(${f2(cx + dir * 36)} ${f2(cy + 2)})"><g class="a spark"><path class="s-pr" d="M${dir * 3},0 l${dir * 7},-2 M${dir * 2},-4 l${dir * 5},-5" stroke-width="2" stroke-linecap="round" fill="none"/></g></g>`;
    s += spark(-1) + spark(1);
  }
  // REVIEW: the reading lens (in front of the label)
  {
    const x = XS.rev;
    const rest = [x - 6 + ZF * KX, P(0, 72, 2)[1]];
    s += `<clipPath id="lc${id}"><rect x="0" y="${f2(P(0, 84, 4)[1])}" width="1400" height="200"/></clipPath>`;
    s += `<g clip-path="url(#lc${id})"><g transform="translate(${f2(rest[0])} ${f2(rest[1])})"><g class="a lens">
      <line class="s-st" x1="0" y1="-10" x2="0" y2="-140" stroke-width="2.5"/>
      <circle r="10" fill="#fff" fill-opacity=".35" class="s-ag-f" stroke-width="3"/>
      <path d="M-5.5 -3 a6 6 0 0 1 3 -3.2" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/></g></g></g>`;
  }
  // GATE: door (clipped to its closed silhouette), front post, lintel, stack light
  {
    const dx = XG + 1, dw = 4;
    const closedF = [P(dx, BH, 0), P(dx + dw, BH, 0), P(dx + dw, 70, 0), P(dx, 70, 0)];
    const closedR = [P(dx + dw, BH, 0), P(dx + dw, BH, BD), P(dx + dw, 70, BD), P(dx + dw, 70, 0)];
    const closedT = [P(dx, 70, 0), P(dx + dw, 70, 0), P(dx + dw, 70, BD), P(dx, 70, BD)];
    s += `<clipPath id="gc${id}"><polygon points="${pts(closedF)}"/><polygon points="${pts(closedR)}"/><polygon points="${pts(closedT)}"/></clipPath>`;
    s += `<g clip-path="url(#gc${id})"><g class="a door">${box(dx, BH, 0, dw, 52, BD, 'dr')}</g></g>`;
    s += box(XG - 1, 0, -7, 7, 72, 7, 'st');
    s += box(XG - 3, 72, -7, 11, 6, BD + 16, 'st');
    const lx = XG + 2.5, lz = -9;
    s += box(lx - 7, 78, lz, 14, 30, 9, 'tl');
    const [rx, ry] = P(lx, 100, lz), [gx, gy] = P(lx, 86, lz);
    s += `<circle class="a glowg" cx="${f2(gx)}" cy="${f2(gy)}" r="40" fill="url(#gG)" style="transform-box:fill-box;transform-origin:center"/>`;
    s += `<circle class="a lampr" cx="${f2(rx)}" cy="${f2(ry)}" r="30" fill="url(#gR)"/>`;
    s += `<circle class="f-tlo" cx="${f2(rx)}" cy="${f2(ry)}" r="5"/><circle class="f-tlo" cx="${f2(gx)}" cy="${f2(gy)}" r="5"/>`;
    s += `<circle class="a lampr f-lr" cx="${f2(rx)}" cy="${f2(ry)}" r="5"/><circle class="a lampg f-lg" cx="${f2(gx)}" cy="${f2(gy)}" r="5"/>`;
  }
  return `<g class="${id}" transform="${perspAttr(LINES[k].s)}">${s}</g>`;
}

// ---------------------------------------------------------------- station labels (front line only, stencilled on the belt)
function labels() {
  const items = [['plan', 'PLAN · Sam'], ['dev', 'DEV · Nick'], ['rev', 'REVIEW · Morgan'], ['lgtm', 'LGTM']];
  return items.map(([k, t]) => {
    const [x, y] = P(XS[k], 4.8, 0);
    return `<circle class="a pip-${k}" cx="${f2(x - t.length * 3.75 - 7)}" cy="${f2(y - 3.6)}" r="2.4" fill="#5B3DF5"/><text class="a lbl lbl-${k} mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;
  }).join('');
}

// ---------------------------------------------------------------- the Lead: articulated arm on a depth rail
const SH = P(441, 34, 28), L1 = 74, L2 = 70, GRIP = 19;
const TOOL_PLACE = P(INT, BH + PHt, ZF + PD / 2);
const TOOL_HOME = OPT.home ?? [TOOL_PLACE[0] - 40, TOOL_PLACE[1] - 84];
function ik([tx_, ty_]) {
  const wx = tx_, wy = ty_ - GRIP;
  const dx = wx - SH[0], dy = wy - SH[1], d = Math.hypot(dx, dy);
  const c = Math.max(-1, Math.min(1, (d * d - L1 * L1 - L2 * L2) / (2 * L1 * L2)));
  const sols = [Math.acos(c), -Math.acos(c)].map(t2 => {
    const t1 = Math.atan2(dy, dx) - Math.atan2(L2 * Math.sin(t2), L1 + L2 * Math.cos(t2));
    const ey = SH[1] + L1 * Math.sin(t1);
    return { t1: t1 * 180 / Math.PI, t2: t2 * 180 / Math.PI, ey };
  });
  const best = sols.sort((a, b) => a.ey - b.ey)[0];           // elbow up
  return [best.t1, best.t2];
}
const A_HOME = ik(TOOL_HOME), A_PLACE = ik(TOOL_PLACE);

function arm() {
  const capsule = (len, th) => `<rect x="${-th / 2}" y="${-th / 2}" width="${len + th}" height="${th}" rx="${th / 2}"/>`;
  const topC = P(0, BH + PHt, ZF + PD / 2);                  // parcel top-centre when drawn at x=0
  const sil = [P(-PW / 2, BH, ZF), P(PW / 2, BH, ZF), P(PW / 2, BH, ZF + PD), P(PW / 2, BH + PHt, ZF + PD), P(-PW / 2, BH + PHt, ZF + PD), P(-PW / 2, BH + PHt, ZF)];
  const carried = LINES.map((ln, k) => `<g class="a carry${k + 1}" style="transform-origin:0 ${GRIP}px"><g transform="translate(${f2(-topC[0])} ${f2(GRIP - topC[1])})">${parcel(ln.num, false)}${k ? `<polygon class="a hz${k + 1}" fill="${BG}" points="${pts(sil)}"/>` : ''}</g></g>`).join('');
  // rail along the depth axis, drawn in perspective
  const railPts = (x, z) => [P(x, 0, z), ...[.64].map(() => null)];
  const tp = (pt, s) => [VP[0] + (pt[0] - VP[0]) * s, VP[1] + (pt[1] - VP[1]) * s];
  const r0 = P(424, 0, 16), r1 = P(458, 0, 16), r2 = P(458, 0, 40), r3 = P(424, 0, 40);
  const rail = `<line class="s-railk" x1="${f2(tp(P(430, 0, 28), 1.03)[0])}" y1="${f2(tp(P(430, 0, 28), 1.03)[1])}" x2="${f2(tp(P(430, 0, 28), .6)[0])}" y2="${f2(tp(P(430, 0, 28), .6)[1])}" stroke-width="2"/>
    <line class="s-railk" x1="${f2(tp(P(452, 0, 28), 1.03)[0])}" y1="${f2(tp(P(452, 0, 28), 1.03)[1])}" x2="${f2(tp(P(452, 0, 28), .6)[0])}" y2="${f2(tp(P(452, 0, 28), .6)[1])}" stroke-width="2"/>`;
  const sparks = `<g class="a pop"><path d="M-40 -14 l-7 -4 M-36 -30 l-5 -7 M40 -14 l7 -4 M36 -30 l5 -7 M0 -40 l0 -8" class="s-ag-f" stroke-width="2.2" stroke-linecap="round" fill="none"/></g>`;
  return `${rail}<g class="a carriage">
    <polygon class="f-sh" opacity=".08" points="${pts([P(414, 0, 8), P(470, 0, 8), P(474, 0, 52), P(418, 0, 52)])}"/>
    ${box(419, 0, 6, 44, 10, 44, 'ac')}
    ${box(431, 10, 18, 20, 20, 20, 'ac')}
    <g transform="translate(${f2(SH[0])} ${f2(SH[1])})"><g class="a sh">
      <g class="f-ar">${capsule(L1, 15)}</g><line x1="4" y1="-5" x2="${L1 - 4}" y2="-5" class="s-arl" stroke-width="2" stroke-linecap="round"/>
      <g transform="translate(${L1} 0)"><g class="a el">
        <g class="f-ar">${capsule(L2, 12)}</g><line x1="4" y1="-4" x2="${L2 - 4}" y2="-4" class="s-arl" stroke-width="1.8" stroke-linecap="round"/>
        <g transform="translate(${L2} 0)"><g class="a wr">
          ${carried}
          <rect x="-3" y="0" width="6" height="${GRIP - 5}" class="f-ar"/>
          <rect x="-12" y="${GRIP - 6}" width="24" height="6" rx="2" class="f-ag-f"/>
          <g transform="translate(0 ${GRIP + 22})">${sparks}</g>
          <circle r="6.5" class="f-aj"/><circle r="2.2" class="f-ar"/>
        </g></g>
        <circle r="7.5" class="f-aj"/><circle r="2.6" class="f-ar"/>
      </g></g>
      <circle r="9" class="f-aj"/><circle r="3" class="f-ar"/>
    </g></g>
  </g>`;
}

// ---------------------------------------------------------------- floor
function floor() {
  const tp = (pt, s) => [VP[0] + (pt[0] - VP[0]) * s, VP[1] + (pt[1] - VP[1]) * s];
  const a = tp(P(380, 0, -10), 1.02), b = tp(P(1320, 0, -10), 1.02), c = tp(P(1320, 0, BD + 40), .58), d = tp(P(380, 0, BD + 40), .58);
  let g = `<polygon points="${pts([a, b, c, d])}" fill="url(#floorG)"/>`;
  for (const s of [1, .9, .8, .72, .64]) { const l = tp(P(390, 0, BD + 20), s), r = tp(P(1320, 0, BD + 20), s); g += `<line x1="${f2(l[0])}" y1="${f2(l[1])}" x2="${f2(r[0])}" y2="${f2(r[1])}" stroke="#E7E4EE" stroke-width="1"/>`; }
  return g;
}

// ---------------------------------------------------------------- brand
function brand() {
  return `<g transform="translate(48 116)">
    <g transform="translate(44 44)"><rect class="a halo" x="-44" y="-44" width="88" height="88" rx="22" fill="none" stroke="#22C55E" stroke-width="2"/>
    <g class="a bump"><rect x="-44" y="-44" width="88" height="88" rx="22" fill="#1E1B3A"/><rect x="-32" y="-32" width="64" height="64" rx="13" fill="#0B0A18"/>
      <rect class="a sglow" x="-32" y="-32" width="64" height="64" rx="13" fill="url(#gS)"/>
      <path d="M-13 -5 l9 9 l17 -18" fill="none" stroke="#3DDC84" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
      <text x="0" y="21" text-anchor="middle" class="mono" font-size="9.5" font-weight="700" letter-spacing="2" fill="#3DDC84">LGTM</text></g></g>
  </g>
  <text x="152" y="160" class="wm"><tspan fill="#5B3FE0">lgtm</tspan><tspan fill="#1E1B3A">gate</tspan></text>
  <text x="153" y="186" class="tag">Merge gate for</text><text x="153" y="205" class="tag">agent-generated pull requests</text>`;
}

// ---------------------------------------------------------------- animations
// line-local
const X = [0, 130, 260, 390, 520, 702];
kf('pmove', [[0, tx(0)], [L.m1[0], tx(0), E.move], [L.m1[1], tx(X[1])], [L.m2[0], tx(X[1]), E.move], [L.m2[1], tx(X[2])],
  [L.m3[0], tx(X[2]), E.move], [L.m3[1], tx(X[3])], [L.m4[0], tx(X[3]), E.move], [L.m4[1], tx(X[4])],
  [7.90, tx(X[4]), E.out], [L.exit[0], tx(X[4] - 6), E.exit], [L.exit[1], tx(X[5])], [T, tx(X[5])]]);
kf('pfade', [[0, op(1)], [8.6, op(1)], [9.0, op(0)], [T, op(0)]]);
kf('psquash', [[0, 'transform:scale(1,1)'], [.06, 'transform:scale(1.045,.92)', E.out], [.3, 'transform:scale(1,1)'],
  [3.29, 'transform:scale(1,1)'], [3.34, 'transform:scale(1.07,.86)', E.out], [3.5, 'transform:scale(.98,1.03)'], [3.66, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
[1.35, 1.65, 1.95].forEach((t, i) => kf(`row${i + 1}`, [[0, 'opacity:0;transform:scaleX(0)'], [t, 'opacity:0;transform:scaleX(0)', E.out], [t + .22, 'opacity:1;transform:scaleX(1)'], [L.reset, 'opacity:1;transform:scaleX(1)'], [L.reset + .01, 'opacity:0;transform:scaleX(0)'], [T, 'opacity:0;transform:scaleX(0)']]));
[5.05, 5.45, 5.85].forEach((t, i) => kf(`tick${i + 1}`, [[0, 'stroke-dashoffset:12'], [t - .12, 'stroke-dashoffset:12', E.out], [t + .02, 'stroke-dashoffset:0'], [L.reset, 'stroke-dashoffset:0'], [L.reset + .01, 'stroke-dashoffset:12'], [T, 'stroke-dashoffset:12']]));
kf('stamp', [[0, 'opacity:0;transform:scale(1.5)'], [3.29, 'opacity:0;transform:scale(1.5)'], [3.30, 'opacity:1;transform:scale(1.5)', E.back], [3.52, 'opacity:1;transform:scale(1)'], [L.reset, 'opacity:1;transform:scale(1)'], [L.reset + .01, 'opacity:0;transform:scale(1.5)'], [T, 'opacity:0;transform:scale(1.5)']]);
kf('fan', [[0, op(0)], [1.15, op(0)], [1.32, op(1)], [2.12, op(1)], [2.28, op(0)], [T, op(0)]]);
kf('emit', [[0, op(.25)], [1.15, op(.25)], [1.3, op(1)], [2.15, op(1)], [2.3, op(.25)], [T, op(.25)]]);
kf('scan', [[0, `${ty(0)};opacity:0`], [1.3, `${ty(0)};opacity:0`], [1.32, `${ty(0)};opacity:1`, E.io], [1.72, `${ty(PHt - 2)};opacity:1`, E.io], [2.12, `${ty(0)};opacity:1`], [2.2, `${ty(0)};opacity:0`], [T, `${ty(0)};opacity:0`]]);
kf('press', [[0, ty(0)], [2.90, ty(0), E.out], [3.12, ty(-5), E.slam], [3.30, ty(10)], [3.45, ty(10), E.out], [3.90, ty(0)], [T, ty(0)]]);
kf('spark', [[0, 'opacity:0;transform:scale(.5)'], [3.29, 'opacity:0;transform:scale(.5)'], [3.33, 'opacity:1;transform:scale(.8)', E.out], [3.6, 'opacity:0;transform:scale(1.4)'], [T, 'opacity:0;transform:scale(1.4)']]);
{
  // lens path relative to its rest point: reads each criterion left -> right
  const [fx, fy] = P(XS.rev - PW / 2, BH + PHt, ZF);
  const rest = [XS.rev - 6 + ZF * KX, P(0, 72, 2)[1]];
  const rowY = i => fy + 6 + 14 + i * 6.5 + 2.5 - rest[1];
  const x0 = fx + 5 + 5 - rest[0], x1 = fx + 5 + 32 - rest[0];
  kf('lens', [[0, txy(0, 0)], [4.50, txy(0, 0), E.out], [4.78, txy(x0, rowY(0)), E.io], [5.05, txy(x1, rowY(0)), E.io],
    [5.17, txy(x0, rowY(1)), E.io], [5.45, txy(x1, rowY(1)), E.io], [5.57, txy(x0, rowY(2)), E.io], [5.85, txy(x1, rowY(2)), E.out],
    [6.10, txy(0, 0)], [T, txy(0, 0)]]);
}
kf('door', [[0, ty(0)], [7.55, ty(0), E.out], [7.95, ty(-54)], [9.1, ty(-54), E.io], [9.5, ty(0)], [T, ty(0)]]);
kf('lampr', [[0, op(0)], [6.70, op(0)], [6.73, op(1)], [6.93, op(.2)], [7.1, op(1)], [7.27, op(.2)], [7.44, op(1)], [7.5, op(0)], [T, op(0)]]);
kf('lampg', [[0, op(0)], [7.49, op(0)], [7.53, op(1)], [9.1, op(1)], [9.4, op(0)], [T, op(0)]]);
kf('glowg', [[0, 'opacity:0;transform:scale(.5)'], [7.5, 'opacity:0;transform:scale(.5)', E.out], [7.78, 'opacity:1;transform:scale(1.25)', E.io], [8.3, 'opacity:.55;transform:scale(1)'], [9.1, 'opacity:.55;transform:scale(1)'], [9.4, 'opacity:0;transform:scale(.8)'], [T, 'opacity:0;transform:scale(.8)']]);
// station labels (front line clock)
const lblK = (name, a, b, col = '#1E1B3A') => kf(name, [[0, 'fill:#55506F'], [a - .1, 'fill:#55506F'], [a, `fill:${col}`], [b, `fill:${col}`], [b + .1, 'fill:#55506F'], [T, 'fill:#55506F']]);
const pipK = (name, a, b) => kf(name, [[0, op(0)], [a - .1, op(0)], [a, op(1)], [b, op(1)], [b + .1, op(0)], [T, op(0)]]);
lblK('lbl-plan', ...L.plan); lblK('lbl-dev', ...L.dev); lblK('lbl-rev', ...L.rev);
pipK('pip-plan', ...L.plan); pipK('pip-dev', ...L.dev); pipK('pip-rev', ...L.rev);
kf('lbl-lgtm', [[0, 'fill:#55506F'], [6.6, 'fill:#55506F'], [6.7, 'fill:#C53030'], [7.45, 'fill:#C53030'], [7.55, 'fill:#15803D'], [8.6, 'fill:#15803D'], [8.8, 'fill:#55506F'], [T, 'fill:#55506F']]);

// global: the arm (slot k = one new issue for line k, every 4 s)
{
  const car = [[0, `transform:${persp(1)}`]];
  [[1, .8], [2, .64]].forEach(([k, s]) => {
    const b = 4 * k;
    car.push([b + .45, `transform:${persp(1)}`, E.move], [b + 1.25, `transform:${persp(s)}`], [b + 2.35, `transform:${persp(s)}`, E.move], [b + 3.15, `transform:${persp(1)}`]);
  });
  car.push([T, `transform:${persp(1)}`]);
  kf('carriage', car);
  const joint = (name, i, sign = 1) => {
    const fr = [[0, rot(A_HOME[i] * sign)]];
    [0, 1, 2].forEach(k => {
      const b = 4 * k;
      fr.push([b + 1.25, rot(A_HOME[i] * sign), E.io], [b + RELEASE, rot(A_PLACE[i] * sign)], [b + RELEASE + .1, rot(A_PLACE[i] * sign), E.io], [b + 2.35, rot(A_HOME[i] * sign)]);
    });
    fr.push([T, rot(A_HOME[i] * sign)]);
    kf(name, fr);
  };
  joint('sh', 0); joint('el', 1);
  const wr = [[0, rot(-(A_HOME[0] + A_HOME[1]))]];
  [0, 1, 2].forEach(k => { const b = 4 * k; wr.push([b + 1.25, rot(-(A_HOME[0] + A_HOME[1])), E.io], [b + RELEASE, rot(-(A_PLACE[0] + A_PLACE[1]))], [b + RELEASE + .1, rot(-(A_PLACE[0] + A_PLACE[1])), E.io], [b + 2.35, rot(-(A_HOME[0] + A_HOME[1]))]); });
  wr.push([T, rot(-(A_HOME[0] + A_HOME[1]))]);
  kf('wr', wr);
  [0, 1, 2].forEach(k => {
    const b = 4 * k, fr = [];
    if (b > 0) fr.push([0, 'opacity:0;transform:scale(0)'], [b - .01, 'opacity:0;transform:scale(0)']);
    fr.push([b, 'opacity:1;transform:scale(0)', E.back], [b + .38, 'opacity:1;transform:scale(1)'], [b + RELEASE - .005, 'opacity:1;transform:scale(1)'], [b + RELEASE, 'opacity:0;transform:scale(1)'], [T, 'opacity:0;transform:scale(0)']);
    kf(`carry${k + 1}`, fr);
  });
  [[1, .8], [2, .64]].forEach(([k, s]) => { const b = 4 * k, h = LINES[k].haze; kf(`hz${k + 1}`, [[0, op(0)], [b + .45, op(0), E.move], [b + 1.25, op(h)], [T, op(h)]]); });
  kf('pop', [[0, 'opacity:0;transform:scale(.6)'], [.02, 'opacity:1;transform:scale(.6)', E.out], [.45, 'opacity:0;transform:scale(1.25)'], [4, 'opacity:0;transform:scale(1.25)']], 4);
  kf('halo', [[0, 'opacity:.8;transform:scale(1)', E.out], [1.1, 'opacity:0;transform:scale(1.45)'], [4, 'opacity:0;transform:scale(1.45)']], 4);
  kf('bump', [[0, 'transform:scale(1)', E.out], [.12, 'transform:scale(1.06)', E.back], [.6, 'transform:scale(1)'], [4, 'transform:scale(1)']], 4);
  kf('sglow', [[0, op(.35)], [.1, op(1)], [1.2, op(.35)], [4, op(.35)]], 4);
}

// ---------------------------------------------------------------- CSS
const mod = (a, n) => ((a % n) + n) % n;
const dLine = k => -mod(COLD - TP[k], T);
const dGlobal = -mod(COLD, T);
const dPulse = -mod(COLD - (TP[0] + L.flip), 4);             // verdicts land every 4 s
const matCSS = LINES.map((ln, k) => {
  const c = m => mix(MAT[m], BG, ln.haze);
  const rules = [];
  for (const m of ['st', 'bt', 'kr', 'ag', 'hs', 'tl']) for (const f of ['t', 'f', 'r']) rules.push(`.L${k + 1} .f-${m}-${f}{fill:${c(`${m}-${f}`)}}`);
  rules.push(`.L${k + 1} .f-dr-t{fill:${c('st-t')}}.L${k + 1} .f-dr-f{fill:${c('st-f')}}.L${k + 1} .f-dr-r{fill:${c('st-r')}}`);
  for (const [cls, m] of [['lg0', 'lo'], ['lr0', 'lo']]) rules.push(`.L${k + 1} .f-${cls}-t,.L${k + 1} .f-${cls}-f,.L${k + 1} .f-${cls}-r{fill:${c(m)}}`);
  rules.push(`.L${k + 1} .f-lg1-t{fill:${c('lg')}}.L${k + 1} .f-lg1-f{fill:${mix(c('lg'), '#000000', .08)}}.L${k + 1} .f-lg1-r{fill:${mix(c('lg'), '#000000', .22)}}`);
  rules.push(`.L${k + 1} .f-lr1-t{fill:${c('lr')}}.L${k + 1} .f-lr1-f{fill:${mix(c('lr'), '#000000', .08)}}.L${k + 1} .f-lr1-r{fill:${mix(c('lr'), '#000000', .22)}}`);
  rules.push(`.L${k + 1} .f-tp{fill:${c('tp')}}.L${k + 1} .f-lb{fill:${c('lb')}}.L${k + 1} .f-ink{fill:${c('ink')}}.L${k + 1} .s-ink{stroke:${c('ink')}}.L${k + 1} .s-rule{stroke:${c('rule')}}`);
  rules.push(`.L${k + 1} .f-pr{fill:${c('pr')}}.L${k + 1} .s-pr{stroke:${c('pr')}}.L${k + 1} .f-fan{fill:${c('fan')}}.L${k + 1} .s-fan{stroke:${c('fan')}}.L${k + 1} .s-tr{stroke:${c('tr')}}.L${k + 1} .f-sh{fill:${c('sh')}}`);
  rules.push(`.L${k + 1} .s-st{stroke:${c('st-r')}}.L${k + 1} .s-ag-f{stroke:${c('ag-f')}}.L${k + 1} .s-ag-l{stroke:${c('ag-l')}}.L${k + 1} .f-bt-r{fill:${c('bt-r')}}.L${k + 1} .s-hg{stroke:${c('hg')}}.L${k + 1} .f-tlo{fill:${c('tlo')}}.L${k + 1} .f-lr{fill:${c('lr')}}.L${k + 1} .f-lg{fill:${c('lg')}}`);
  rules.push(`.L${k + 1} .a{animation-delay:${f2(dLine(k))}s}`);
  return rules.join('');
}).join('\n');

const css = `
.a{animation-duration:${T}s;animation-iteration-count:infinite;animation-fill-mode:both}
.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace}
.wm{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:42px;font-weight:700;letter-spacing:-1.5px}
.tag{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif;font-size:14.5px;fill:#5B6472}
.lbl{font-size:12px;font-weight:600;letter-spacing:.8px;fill:#55506F}
.pmove{animation-name:pmove}.pfade{animation-name:pfade}.psquash{animation-name:psquash}
.row1{animation-name:row1}.row2{animation-name:row2}.row3{animation-name:row3}
.tick1{animation-name:tick1}.tick2{animation-name:tick2}.tick3{animation-name:tick3}
.stamp{animation-name:stamp}.fan{animation-name:fan;opacity:0}.emit{animation-name:emit}.scan{animation-name:scan}
.press{animation-name:press}.spark{animation-name:spark}.lens{animation-name:lens}.door{animation-name:door}
.lampr{animation-name:lampr}.lampg{animation-name:lampg}.glowg{animation-name:glowg}
.f-fan{fill-opacity:.16}
.lbl-plan{animation-name:lbl-plan}.lbl-dev{animation-name:lbl-dev}.lbl-rev{animation-name:lbl-rev}.lbl-lgtm{animation-name:lbl-lgtm}
.pip-plan{animation-name:pip-plan}.pip-dev{animation-name:pip-dev}.pip-rev{animation-name:pip-rev}.pip-lgtm{opacity:0}
.labels .a{animation-delay:${f2(dLine(0))}s}
.carriage{animation-name:carriage}.sh{animation-name:sh}.el{animation-name:el}.wr{animation-name:wr}
.carry1{animation-name:carry1}.carry2{animation-name:carry2}.carry3{animation-name:carry3}.hz2{animation-name:hz2}.hz3{animation-name:hz3}
.lead .a{animation-delay:${f2(dGlobal)}s}
.pop{animation-name:pop;animation-duration:4s}
.lead .pop{animation-delay:${f2(-mod(COLD, 4))}s}
.halo{animation-name:halo;animation-duration:4s}.bump{animation-name:bump;animation-duration:4s}.sglow{animation-name:sglow;animation-duration:4s}
.brand .a{animation-delay:${f2(dPulse)}s}
.f-ar{fill:#2B2748}.s-arl{stroke:#4A4478}.f-aj{fill:#8069FF}.f-ag-f{fill:#8069FF}.s-ag-f{stroke:#8069FF}
.f-ac-t{fill:#4A4570}.f-ac-f{fill:#35305A}.f-ac-r{fill:#28244A}
.s-railk{stroke:#D4D0E0}.f-sh{fill:#1E1B3A}
.f-kr-t{fill:${MAT['kr-t']}}.f-kr-f{fill:${MAT['kr-f']}}.f-kr-r{fill:${MAT['kr-r']}}.f-tp{fill:${MAT.tp}}.f-lb{fill:#fff}.f-ink{fill:${MAT.ink}}
${matCSS}
@media (prefers-reduced-motion:reduce){.a{animation-play-state:paused}}
`;

const defs = `<defs>
  <radialGradient id="gG"><stop offset="0" stop-color="#22C55E" stop-opacity=".5"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <radialGradient id="gR"><stop offset="0" stop-color="#F04438" stop-opacity=".42"/><stop offset="1" stop-color="#F04438" stop-opacity="0"/></radialGradient>
  <radialGradient id="gS" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#22C55E" stop-opacity=".45"/><stop offset="1" stop-color="#22C55E" stop-opacity="0"/></radialGradient>
  <linearGradient id="fadeR" x1="0" x2="1"><stop offset="0" stop-color="${BG}" stop-opacity="0"/><stop offset="1" stop-color="${BG}"/></linearGradient>
  <radialGradient id="floor" cx="62%" cy="78%" r="60%"><stop offset="0" stop-color="#EFEDF4"/><stop offset="1" stop-color="${BG}" stop-opacity="0"/></radialGradient>
  <linearGradient id="floorG" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#ECE9F1"/><stop offset="1" stop-color="#ECE9F1" stop-opacity="0"/></linearGradient>
</defs>`;

const svg = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="lgtmgate: an orchestrating arm dispatches GitHub issues onto three parallel assembly lines; on each, Sam prints the acceptance checklist, Nick stamps it a pull request, Morgan ticks every criterion, and the LGTM gate turns from red to green.">
<style>${css}${KF.join('\n')}</style>
${defs}
<rect width="${W}" height="${H}" fill="${BG}"/>
<rect width="${W}" height="${H}" fill="url(#floor)"/>
${floor()}
<g class="brand">${brand()}</g>
${line(2)}
${line(1)}
${line(0)}
<g class="labels">${labels()}</g>
<g class="lead">${arm()}</g>
<rect x="${W - 70}" y="0" width="70" height="${H}" fill="url(#fadeR)"/>
</svg>`;

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>lgtmgate header 3D</title>
<style>html,body{margin:0;background:#ECEBF0}main{max-width:1280px;margin:0 auto;padding:40px 16px 56px}
.frame{border-radius:20px;overflow:hidden;box-shadow:0 1px 0 rgba(17,19,24,.04),0 12px 40px -12px rgba(17,19,24,.18)}
.frame svg{display:block;width:100%;height:auto}
p{font:13px -apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif;color:#5B6472;margin:14px 4px 0}</style></head>
<body><main><div class="frame">
<!-- Generated. One self-contained <svg>: CSS keyframes only, no JS, no web font; extractable as-is to a README image. -->
${svg}
</div><p>Mockup v3 · 1280×344 · 12 s loop (a new issue every 4 s, three runs in parallel) · SVG + CSS keyframes · respects prefers-reduced-motion on this page.</p></main></body></html>`;
writeFileSync(OUT, html);
console.log('ok', OUT, 'bytes', html.length, 'home', A_HOME.map(f2), 'place', A_PLACE.map(f2));
