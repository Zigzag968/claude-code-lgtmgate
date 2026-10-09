// The README's animated header: two assembly lines, the LGTM gate, the Lead's arm and the main lane.
// Usage: node scripts/gen-readme-header.mjs .github/assets/header.svg         (the README header)
//        node scripts/gen-readme-header.mjs .github/assets/header-dark.svg '{"theme":"dark"}'   (GitHub's dark theme)
//        node scripts/gen-readme-header.mjs /tmp/header-mockup.html           (a page to review it in a browser)
//        node scripts/gen-readme-header.mjs /tmp/social.html '{"social":true}'   (the 1280x640 page of .github/assets/social-preview.png)
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
import { T, SHIFT, f2, modulo, glob, E, KF, kf, tx, ty, txy, rot, op, moves, valueAt, BH, PHt, TOPY, HOIST, DROP, LAMP, TB, TA, ARM, CAR, MOVES, MERGE, lineKF, boxKF } from './readme-header-motion.mjs';
import { themed } from './readme-header-theme.mjs';
import { makeOperator } from './readme-header-operator.mjs';
import { socialPage } from './readme-header-social.mjs';
const OUT = process.argv[2];
const OPT = JSON.parse(process.argv[3] || '{}');
const THEME = OPT.theme === 'dark' ? 'dark' : 'light';             // '{"theme":"dark"}' writes the variant for GitHub's dark theme
// ---------------------------------------------------------------- canvas / clock
const W = 1280, H = 344;
const COLD = OPT.cold ?? 7.9;                 // opens as the operator presses MERGE and the Lead comes down for #143

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


// ---------------------------------------------------------------- geometry (world units; x along the line, y up, z depth)
const BX0 = 360, BX1 = 930, BD = 64;
const PW = 70, PD = 50, ZF = (BD - PD) / 2, ZC = ZF + PD / 2;
const SP = 100, INT = 400, TREAD = 20;
const XS = { int: INT, plan: INT + SP, dev: INT + 2 * SP, rev: INT + 3 * SP, lgtm: INT + 4 * SP, pick: INT + 4 * SP + 80 };
const DX = [0, SP, 2 * SP, 3 * SP, 4 * SP, 4 * SP + 80];           // 480 = 24 treads -> seamless
const XG = XS.lgtm + PW / 2 + 8;                                   // gate plane; its stack light (and the LGTM label) at XG + 2.5
const ZL = { A: 350, B: 0 };                                       // A = back line, B = front line



// ---------------------------------------------------------------- the parcel (drawn at x = 0, depth offset z0)
// PR label: grey while draft, red once Morgan requests changes, green once his review passes (and on main)
const PRC = { draft: '#6E7781', changes: '#CF222E', ready: '#1F883D' };  // filled, white text, like GitHub's state labels
const OKC = '#1F883D', KOC = '#CF222E';                              // Morgan's marks: green tick, red cross
const prLabel = (bg, cls) => `<g${cls ? ` class="a ${cls}"` : ''}><rect x="-13.5" y="-7.5" width="27" height="15" rx="4" fill="${bg}"/><text x="0" y="3.6" text-anchor="middle" class="mono" fill="#fff" font-size="10" font-weight="800">PR</text></g>`;
// modes: 'live' (label layers animate, class suffix p), 'final' (ticked, PR ready, on main), 'carry' (the same, in the Lead's grip, no foot), 'plain'
function parcel(prNumber, mode, z0, p = '') {
  const [fx, fy] = P(-PW / 2, TOPY, ZF + z0);
  const cx = fx + 6, cy = fy + 7;
  const tape = [P(-7, TOPY, ZF + z0), P(7, TOPY, ZF + z0), P(7, TOPY, ZF + PD + z0), P(-7, TOPY, ZF + PD + z0)];
  const live = mode === 'live';
  // the kraft box (with its tape) pops around the label when the parcel reaches DEV; before that the issue is the label alone, on a small foot
  const kraft = box(-PW / 2, BH, ZF + z0, PW, PHt, PD, 'kr') + `<polygon fill="#E3C38F" points="${pts(tape)}"/><rect fill="#E3C38F" x="${f2(fx + PW / 2 - 7)}" y="${f2(fy)}" width="14" height="5"/>`;
  const foot = `<ellipse cx="${f2(cx + 23)}" cy="${f2(cy + 46)}" rx="27" ry="3.6" fill="${INK}" opacity=".14"/><rect x="${f2(cx + 7)}" y="${f2(cy + 36)}" width="32" height="9" rx="2" fill="#C9C6D5"/>`;
  let s = live ? `<g class="a box${p}" style="transform-origin:${f2(cx + 23)}px ${f2(cy + 19)}px">${kraft}</g><g class="a foot${p}">${foot}</g>` : mode === 'carry' ? '' : foot;   // the kraft box only exists in DEV
  s += `<rect fill="#fff" x="${f2(cx)}" y="${f2(cy)}" width="46" height="38" rx="2.5"/>`;
  s += `<text class="mono" fill="${INK}" x="${f2(cx + 4)}" y="${f2(cy + 10)}" font-size="9" font-weight="700">${prNumber}</text>`;
  if (mode === 'plain') return s;
  [0, 1, 2].forEach(index => {
    const y = cy + 16 + index * 7.5, w = [24, 19, 22][index];
    s += `<g${live ? ` class="a row${index + 1}${p}" style="transform-origin:${f2(cx + 4)}px 0"` : ''}><rect x="${f2(cx + 4)}" y="${f2(y)}" width="6" height="6" rx="1.2" fill="none" stroke="${INK}" stroke-width="1.2"/><line x1="${f2(cx + 14)}" y1="${f2(y + 3)}" x2="${f2(cx + 14 + w)}" y2="${f2(y + 3)}" stroke="#C5C8D2" stroke-width="2.2" stroke-linecap="round"/></g>`;
    s += `<path${live ? ` class="a tk${index + 1}${p}"` : ''} d="M${f2(cx + 3)},${f2(y + 2.6)} l2.6,2.8 l5.4,-7" fill="none" stroke="${OKC}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="14"${live ? '' : ' stroke-dashoffset="0"'}/>`;
    if (live && p === 'A' && index === 1) s += `<g class="a x2A" style="transform-origin:${f2(cx + 7)}px ${f2(y + 3)}px"><path d="M${f2(cx + 4.3)},${f2(y + .3)} l5.4,5.4 M${f2(cx + 9.7)},${f2(y + .3)} l-5.4,5.4" stroke="${KOC}" stroke-width="1.9" stroke-linecap="round"/></g>`;
  });
  const lab = live ? `<g class="a stamp${p}">${prLabel(PRC.draft)}${p === 'A' ? prLabel(PRC.changes, 'chg' + p) : ''}${prLabel(PRC.ready, 'ready' + p)}</g>` : prLabel(PRC.ready);
  s += `<g transform="translate(${f2(fx + PW - 11)},${f2(fy + 10)}) rotate(-12)">${lab}</g>`;
  return s;
}

// ---------------------------------------------------------------- stations (v4): a column behind the belt, a violet tool arm over it
// Morgan's lens hangs from a pin bar under the REVIEW arm: its rest is centered on the station (the column's x, the belt's middle),
// and the handle is a segment whose top stays on the bar and whose bottom is the ring (lensH stretches it with the ring's lensY)
const PIN = { x: 54, y: 92, h: 4, dz: 4, base: 5, over: 2 };         // bar width / bottom / height / half depth, handle length at rest, overlap into the bar
const pinY = p => P(XS.rev, PIN.y, ZL[p] + ZC - PIN.dz)[1];
const lensRest = p => [P(XS.rev, 0, ZL[p] + ZC)[0], pinY(p) + PIN.base + 12];
const lampAt = (p, x) => P(x, 110.8, ZL[p] + 9);
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
  return column(XS.plan) + column(XS.dev) + column(XS.rev) + box(XS.rev - PIN.x / 2, PIN.y, z0 + ZC - PIN.dz, PIN.x, PIN.h, 2 * PIN.dz, 'ag') + box(XG - 2, 0, z0 + BD + 2, 9, 100, 9, 'gt');
}
function tools(p) {                                                 // the parts over the belt (drawn after the parcel)
  const z0 = ZL[p];
  let s = '';
  { // PLAN: Sam's scanner prints the acceptance checklist
    const x = XS.plan, [fx, fy] = P(x - PW / 2, TOPY, ZF + z0), hb = [P(x - 16, 84, z0 + 16), P(x + 16, 84, z0 + 16)];
    s += `<polygon class="a fan${p}" fill="#7C66FF" fill-opacity=".16" points="${pts([hb[0], hb[1], [fx + PW + 4, fy + PHt + 2], [fx - 4, fy + PHt + 2]])}"/>`;
    s += `<g class="a scan${p}"><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="2" stroke-linecap="round"/><line x1="${f2(fx - 3)}" y1="${f2(fy + 1)}" x2="${f2(fx + PW + 3)}" y2="${f2(fy + 1)}" stroke="#7C66FF" stroke-width="7" stroke-linecap="round" opacity=".25"/></g>`;
    s += box(x - 18, 84, z0 + 14, 36, 12, 30, 'ag');
    const edge = [P(x - 13, 84, z0 + 14), P(x + 13, 84, z0 + 14)];
    s += `<line class="a emit${p}" x1="${f2(edge[0][0])}" y1="${f2(edge[0][1] - 1)}" x2="${f2(edge[1][0])}" y2="${f2(edge[1][1] - 1)}" stroke="#C9C0FF" stroke-width="2.5" stroke-linecap="round"/>`;
  }
  { // DEV: Nick's workshop. The head comes down, the parcel shakes and squashes while code and tools fly out of it,
    // then a small burst: the PR opens
    const x = XS.dev, rod = P(x, 96, z0 + 32);
    s += `<clipPath id="press${p}"><rect x="0" y="${f2(rod[1])}" width="1400" height="400"/></clipPath>`;
    s += `<g clip-path="url(#press${p})"><g class="a press${p}"><line x1="${f2(rod[0])}" y1="${f2(rod[1] - 40)}" x2="${f2(rod[0])}" y2="${f2(rod[1] + 16)}" stroke="#C9C6D5" stroke-width="6"/>${box(x - 26, 82, z0 + 12, 52, 14, 38, 'ag')}</g></g>`;
    const [cx, cy] = cloudAt(p);
    SYMS.forEach(([glyph], index) => { s += `<g transform="translate(${f2(cx)} ${f2(cy)})"><g class="a sym${index}${p}">${glyph}</g></g>`; });
    s += `<g transform="translate(${f2(cx)} ${f2(cy)})"><g class="a boom${p}" stroke="#5B3DF5" stroke-width="3" stroke-linecap="round">${[...Array(10)].map((_, k) => { const t = (k * 36 + 18) * Math.PI / 180; return `<line x1="${f2(Math.cos(t) * 50)}" y1="${f2(Math.sin(t) * 38)}" x2="${f2(Math.cos(t) * 60)}" y2="${f2(Math.sin(t) * 46)}"/>`; }).join('')}</g></g>`;
  }
  { // REVIEW: Morgan's lens reads each criterion and ticks it
    const rest = lensRest(p);
    const hl = PIN.base + PIN.over;
    s += `<clipPath id="lensc${p}"><rect x="0" y="${f2(pinY(p) - PIN.h)}" width="1400" height="400"/></clipPath>`;
    s += `<g clip-path="url(#lensc${p})"><g transform="translate(${f2(rest[0])} ${f2(rest[1])})"><g class="a lensX${p}"><rect class="a lensH${p}" x="-1.3" y="${-12 - hl}" width="2.6" height="${hl}" fill="#C9C6D5" style="transform-box:fill-box;transform-origin:50% 0"/><g class="a lensY${p}"><circle r="12" fill="#fff" fill-opacity=".35" stroke="#8069FF" stroke-width="3.2"/><path d="M-6.5 -3.5 a7 7 0 0 1 3.5 -3.6" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"/></g></g></g></g>`;
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
  const z0 = ZL[p], prNumber = p === 'A' ? '#143' : '#142';
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
  s += `<g transform="translate(${INT} 0)"><g class="a vis${p}"><g class="a mx${p}"><g class="a my${p}"><g transform="translate(${f2(piv[0])} ${f2(piv[1])})"><g class="a sq${p}"><g transform="translate(${f2(-piv[0])} ${f2(-piv[1])})"><g class="a pop${p}" style="transform-origin:${f2(topc[0])}px ${f2(topc[1])}px">${parcel(prNumber, 'live', z0, p)}</g></g></g></g></g></g></g></g>`;
  s += tools(p) + gate(p);
  return `<g class="p${p}">${s}</g>`;
}
function labels() {
  const X = { int: INT, plan: XS.plan, dev: XS.dev, rev: XS.rev, lgtm: XG + 2.5 };
  return [['int', 'ISSUE'], ['plan', 'PLAN'], ['dev', 'DEV'], ['rev', 'REVIEW'], ['lgtm', 'LGTM']].map(([k, t]) => {
    const [x, y] = P(X[k], 5.6, 0);
    if (k === 'lgtm') return `<text class="lbl mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;   // the gate's lights speak for it
    return `<text class="a lbl lbl-${k} mono" x="${f2(x)}" y="${f2(y)}" text-anchor="middle">${t}</text>`;
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
for (let slot = 5; slot >= -6; slot--) {
  const m = modulo(slot, 4), who = WHO[m] || null;
  if (who && slot < LAND[who]) continue;                               // still a gap: that PR has not been merged yet
  if ((slot + 4) * PITCH < -400 || slot * PITCH > 900) continue;          // never on screen during the loop
  const lay = [];
  for (let k = 0; k < T * 200; k++) { const t = k / 200, z = (slot + valueAt(NSTRIP, t)) * PITCH; lay.push(z + ZC >= ZG ? 'far' : z < valueAt(ZCAR, t) - .5 ? 'front' : 'back'); }
  STRIP_J.push({ slot, who, lay });
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
  for (const { slot, who, lay } of STRIP_J) {
    const on = lay.map(l => l === layer);
    if (!on.some(Boolean)) continue;
    const always = on.every(Boolean), cls = `ly${{ far: 'R', back: 'B', front: 'F' }[layer]}${slot + 10}`;
    if (!always) stepKF(cls, on);
    const landing = who && slot === LAND[who];
    const [dx, dy] = slotShift(slot), piv = P(MXC, BH, ZF);
    const body = parcel(who === 'A' ? '#143' : who === 'B' ? '#142' : OTHERS[modulo(slot, 4)], 'final', 0);
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
const near = (a, reference) => a + 360 * Math.round((reference - a) / 360);
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
  const cap = (length, th) => `<rect x="${-th / 2}" y="${-th / 2}" width="${length + th}" height="${th}" rx="${th / 2}" fill="#2B2748"/>`;
  const joint = r => `<circle r="${r}" fill="#8069FF"/><circle r="${r * .34}" fill="#2B2748"/>`;
  const topC = P(0, TOPY, ZC);
  const card = ['B', 'A'].map(p => `<g class="a carry${p}"><g transform="translate(${f2(-topC[0])} ${f2(GRIP - topC[1])})">${parcel(p === 'A' ? '#143' : '#142', 'carry', 0)}</g></g>`).join('');
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
const LOGO_Y = OPT.logoY ?? 46;
function brand() {
  return `<g transform="translate(48 ${LOGO_Y})"><g transform="translate(44 44)">
    <rect class="a halo" x="-44" y="-44" width="88" height="88" rx="22" fill="none" stroke="#22C55E" stroke-width="2"/>
    <g class="a bump"><rect x="-44" y="-44" width="88" height="88" rx="22" fill="#1E1B3C"/><rect x="-32" y="-32" width="64" height="64" rx="13" fill="#0B0A18"/>
      <rect class="a sglow" x="-32" y="-32" width="64" height="64" rx="13" fill="url(#gS)"/>
      <path d="M-13 -5 l9 9 l17 -18" fill="none" stroke="#3DDC84" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
      <text x="0" y="21" text-anchor="middle" class="mono" font-size="9.5" font-weight="700" letter-spacing="2" fill="#3DDC84">LGTM</text></g></g></g>
  <text x="152" y="${LOGO_Y + 44}" class="wm"><tspan fill="#5B3FE1">lgtm</tspan><tspan fill="#1E1B3B">gate</tspan></text>
  <text x="153" y="${LOGO_Y + 70}" class="tag">An LGTM you can trust</text><text x="153" y="${LOGO_Y + 89}" class="tag">Several issues at once, five agents, one mergeable PR</text>`;
}
const operator = makeOperator({ C, pts, f2, INK, KX, KY, opts: OPT });   // the human at the desk: scripts/readme-header-operator.mjs

// ---------------------------------------------------------------- animations shared by both lines (each on its own clock)
lineKF('B', TB, SYMS); lineKF('A', TA, SYMS);
const SQ = (p, events, wobble = []) => {
  const one = 'transform:scale(1,1) rotate(0deg)', fr = [[0, one]];
  const all = [...events.map(([at, k]) => ({ at, k })), ...wobble.map(([at, b]) => ({ at, b }))].sort((x, y) => x.at - y.at);
  for (const entry of all) {
    if (entry.b === undefined) fr.push([entry.at - .02, one], [entry.at + .05, `transform:scale(${1 + .06 * entry.k},${1 - .12 * entry.k}) rotate(0deg)`, E.out], [entry.at + .2, `transform:scale(${1 - .015 * entry.k},${1 + .03 * entry.k}) rotate(0deg)`], [entry.at + .36, one]);
    else {                                                           // the parcel shakes, squashes and stretches while Nick works on it
      fr.push([entry.at, one]);
      for (let x = entry.at + .09, index = 0; x < entry.b - .05; x += .09, index++) fr.push([x, index % 2 ? 'transform:scale(.93,1.08) rotate(2.6deg)' : 'transform:scale(1.08,.9) rotate(-2.6deg)', E.io]);
      fr.push([entry.b, one]);
    }
  }
  fr.push([T, one]); kf(`sq${p}`, fr);
};
const tickKF = (name, x, reset) => kf(name, [[0, 'stroke-dashoffset:14'], [x - .12, 'stroke-dashoffset:14', E.out], [x + .02, 'stroke-dashoffset:0'], [reset, 'stroke-dashoffset:0'], [reset + .001, 'stroke-dashoffset:14'], [T, 'stroke-dashoffset:14']]);
// One frame table per read, three projections of it (x of the group, y of the ring, stretch of the handle): they cannot drift apart
const lensGeo = p => {
  const [fx, fy] = P(XS.rev - PW / 2, TOPY, ZF + ZL[p]), lr = lensRest(p), mid = fx + 6 + 23 - lr[0];   // mid: the checklist's centre
  return { r: index => fy + 7 + 16 + index * 7.5 + 3 - lr[1], x0: mid - 14, x1: mid + 14 };
};
const lensKF = (p, frames) => {                                      // frames: [t, x, y, easing]
  const hl = PIN.base + PIN.over;
  kf(`lensX${p}`, frames.map(([t, x, , easing]) => [t, tx(x), easing]));
  kf(`lensY${p}`, frames.map(([t, , y, easing]) => [t, ty(y), easing]));
  kf(`lensH${p}`, frames.map(([t, , y, easing]) => [t, `transform:scaleY(${f2((hl + y) / hl)})`, easing]));
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
  boxKF(p, t);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1]], t.work);
  t.ticks.forEach((x, index) => tickKF(`tk${index + 1}${p}`, x, t.reset));
  const { r, x0, x1 } = lensGeo(p), k = t.ticks;
  lensKF(p, [[0, 0, 0], [t.read[0], 0, 0, E.out], [t.read[0] + .2, x0, r(0), E.io], [k[0], x1, r(0), E.io], [k[0] + .1, x0, r(1), E.io], [k[1], x1, r(1), E.io],
    [k[1] + .1, x0, r(2), E.io], [k[2], x1, r(2), E.out], [t.read[1], 0, 0], [T, 0, 0]]);
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
  boxKF(p, t);
  SQ(p, [[t.drop[1], 1], [t.stamp, 1.1], [t.stamp2, 1.1]], t.work);
  [t.tick1, ...t.ticks2].forEach((x, index) => tickKF(`tk${index + 1}${p}`, x, t.reset));
  const { r, x0, x1 } = lensGeo(p), k = t.ticks2;
  lensKF(p, [[0, 0, 0], [t.read1[0], 0, 0, E.out], [t.read1[0] + .2, x0, r(0), E.io], [t.tick1, x1, r(0), E.io], [t.tick1 + .1, x0, r(1), E.io], [t.fail, x1, r(1)],
    [t.fail + .1, x1, r(1), E.io], [t.read1[1], 0, 0],
    [t.read2[0], 0, 0, E.out], [t.read2[0] + .2, x0, r(1), E.io], [k[0], x1, r(1), E.io], [k[0] + .1, x0, r(2), E.io], [k[1], x1, r(2), E.out], [t.read2[1], 0, 0], [T, 0, 0]]);
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
    const a = ARM[p], released = a.swing[1];
    kf(`carry${p}`, [[0, op(0)], [a.down[1] - .001, op(0)], [a.down[1], op(1)], [released - .001, op(1)], [released, op(0)], [T, op(0)]]);
    kf(`land${p}`, [[0, op(0)], [released - .001, op(0)], [released, op(1)], [T, op(1)]]);
    kf(`msq${p}`, [[0, 'transform:scale(1,1)'], [released, 'transform:scale(1,1)'], [released + .06, 'transform:scale(1.05,.92)', E.out], [released + .24, 'transform:scale(.99,1.02)'], [released + .4, 'transform:scale(1,1)'], [T, 'transform:scale(1,1)']]);
  }
  kf('car', ZCAR.map(([t, z, easing]) => [t, txy(z * KX, -z * KY), easing]));
  kf('mstrip', NSTRIP.map(([t, n, easing]) => [t, txy(...slotShift(n)), easing]));
}
// labels (front line clock) + logo pulses on both verdicts (global clock)
{
  const DIM = '#55506F', t = TB;
  const lbl = (k, a, b, col = '#1E1B3D') => kf(`lbl-${k}`,   // the active stage label (its own value: light in the dark theme)
   [[0, `fill:${DIM}`], [a - .1, `fill:${DIM}`], [a, `fill:${col}`], [b, `fill:${col}`], [b + .1, `fill:${DIM}`], [T, `fill:${DIM}`]]);
  lbl('int', t.pop[0], t.m1[0]);
  lbl('plan', ...t.plan); lbl('dev', t.m2[1], t.m3[0]); lbl('rev', ...t.read);
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
  ...SYMS.map((_, index) => `sym${index}`),
  'lensX', 'lensY', 'lensH', 'door', 'box', 'foot', 'lampR', 'lampG', 'glow', 'ciA', 'ciG', 'ciGlowA', 'ciGlowG', 'mx', 'belt', 'my', 'vis', 'pop', 'sq', 'tk1', 'tk2', 'tk3',
  ...['pl', 'dv', 'rv'].flatMap(k => [`lm${k}`, `lo${k}`, `lg${k}`, `lr${k}`]), ...['pl', 'dv', 'rv', 'lg'].map(k => `nd${k}`), 'rv', 'mg', 'mgd'];
const names = [...per.flatMap(n => [n + 'A', n + 'B']), 'sh', 'el', 'wr', 'carryA', 'carryB', 'landA', 'landB', 'msqA', 'msqB', 'car', 'mstrip',
  'halo', 'bump', 'sglow', ...['int', 'plan', 'dev', 'rev'].map(k => `lbl-${k}`), 'chgA', 'x2A', ...DYN];
const css = `
.a{animation-duration:${T}s;animation-iteration-count:infinite;animation-fill-mode:both;animation-delay:${f2(-modulo(COLD, T))}s}
.pA .a{animation-delay:${f2(-modulo(COLD - SHIFT.A, T))}s}.pB .a{animation-delay:${f2(-modulo(COLD - SHIFT.B, T))}s}
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
const page = OPT.social ? socialPage(card) : html;
writeFileSync(OUT, OUT.endsWith('.svg') ? `<?xml version="1.0" encoding="UTF-8"?>\n<!-- Generated by scripts/gen-readme-header.mjs (${THEME} theme). CSS keyframes only, no JS, no web font. -->\n${themed(card, THEME)}\n` : themed(page, THEME));
console.log('ok', OUT, 'bytes', html.length, 'layers', DYN.join(','));
