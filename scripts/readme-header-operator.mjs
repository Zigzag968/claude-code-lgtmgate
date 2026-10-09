// The human operator of scripts/gen-readme-header.mjs: seen from behind, headset on, centered in front of the desk's monitor
// (his silhouette may hide part of the screen). The monitor faces us. Its display is split in thirds: a minimal list on the
// left, the two workflows in progress on the right (one schematic row each, its four steps lit like the stations: orange in
// progress, green done, red error), then the MERGE go-ahead the human gives before the Lead merges.
const DESK = 130;                                                   // the desk's width: the monitor and the operator sit on its centre line
const DW = 132, DH = 58, SC = 0.85;                                 // the display is designed on 132x58 and drawn at 0.85
const MON = { w: Math.round(DW * SC), h: Math.round(DH * SC), z: 22, y: 36 };   // the monitor (world units on the desk)
MON.x = (DESK - MON.w) / 2;
const LEFT = 41;                                                    // the list takes the left third of the display
const ROWY = { A: 19, B: 37 };                                      // back line on top, as in the scene
const NODE_X = [50, 63, 76, 89];                                    // PLAN, DEV, REVIEW, LGTM
const PILL_X = 97;

export function makeOperator({ C, pts, f2, INK, KX, KY, opts }) {
  const VX = opts.opX ?? 160, VY = opts.opY ?? 334;
  const V = (x, y, z) => [VX + x + z * KX, VY - y - z * KY];
  const vbox = (x, y, z, w, h, d, m) => {
    const f = [V(x, y, z), V(x + w, y, z), V(x + w, y + h, z), V(x, y + h, z)];
    const t = [V(x, y + h, z), V(x + w, y + h, z), V(x + w, y + h, z + d), V(x, y + h, z + d)];
    const r = [V(x + w, y, z), V(x + w, y, z + d), V(x + w, y + h, z + d), V(x + w, y + h, z)];
    return `<polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/>`;
  };
  const [mx, my] = V(MON.x, MON.y + MON.h, MON.z);
  const D = { x: mx + 4 * SC, y: my + 4 * SC, w: DW - 8, h: DH - 8 };

  const display = () => {
    let s = `<g transform="translate(${f2(D.x)} ${f2(D.y)}) scale(${SC})"><rect width="${D.w}" height="${D.h}" rx="3" fill="#0B0A18"/><g>`;
    s += `<line x1="${LEFT}" y1="5" x2="${LEFT}" y2="${D.h - 5}" stroke="#2E2A4A" stroke-width=".8"/>`;
    [19, 28, 37].forEach((y, index) => {                            // the list: three short bars, each with a dot, the first one lit
      const lit = index === 0;
      s += `<circle cx="8" cy="${y}" r="2.2" fill="${lit ? '#F5A524' : '#3A3657'}"/><rect x="14" y="${y - 1.7}" width="${[22, 16, 19][index]}" height="3.4" rx="1.7" fill="${lit ? '#8E89B0' : '#2E2A4A'}"/>`;
    });
    s += `<text x="${LEFT + 6}" y="9" class="mono" font-size="5.4" font-weight="700" letter-spacing=".4" fill="#8E89B0">IN PROGRESS</text>`;
    const pill = (y, t) => `<rect x="${PILL_X}" y="${y - 5}" width="24" height="10" rx="5" fill="#1F883D"/><text x="${PILL_X + 12}" y="${y + 1.7}" text-anchor="middle" class="mono" font-size="4.8" font-weight="800" fill="#fff">${t}</text>`;
    for (const p of ['A', 'B']) {
      const y = ROWY[p];
      s += `<g class="p${p}"><g class="a rv${p}"><line x1="${NODE_X[0]}" y1="${y}" x2="${NODE_X[3]}" y2="${y}" stroke="#2E2A4A" stroke-width="2.4" stroke-linecap="round"/>`
        + ['pl', 'dv', 'rv', 'lg'].map((k, index) => `<circle class="a nd${k}${p}" cx="${NODE_X[index]}" cy="${y}" r="4.4" fill="#3A3657"/>`).join('')
        + `<rect x="${PILL_X}" y="${y - 5}" width="24" height="10" rx="5" fill="none" stroke="#4A4569" stroke-width=".9"/><text x="${PILL_X + 12}" y="${y + 1.7}" text-anchor="middle" class="mono" font-size="4.8" font-weight="800" fill="#6E6A8A">MERGE</text>`
        + `<g class="a mg${p}">${pill(y, 'MERGE')}</g><g class="a mgd${p}">${pill(y, 'MERGED')}</g></g></g>`;
    }
    return s + `</g></g>`;
  };

  // the operator seen from behind (the drawing of the original header), centered on the display
  const hy = V(0, 66, -16)[1];
  const figure = () => `<g transform="translate(${f2(mx + MON.w / 2)} ${f2(hy)}) scale(.72)">
    <rect x="-21" y="12" width="42" height="40" rx="13" fill="#6D5BD8"/><path d="M-9 12 q9 7 18 0 v4 q-9 6 -18 0 z" fill="#5B49C6"/>
    <rect x="-17" y="27" width="34" height="37" rx="7" fill="#35305B"/><rect x="-2" y="64" width="4" height="12" fill="#2B2748"/><rect x="-14" y="75" width="28" height="3.5" rx="1.75" fill="#2B2748"/>
    <circle r="11" fill="#2B2749"/><path d="M-11.5 -1 a11.5 11.5 0 0 1 23 0" fill="none" stroke="#B6AAFF" stroke-width="2.4"/>
    <rect x="-14" y="-4.5" width="5" height="10" rx="2.2" fill="#8069FF"/><rect x="9" y="-4.5" width="5" height="10" rx="2.2" fill="#8069FF"/>
    <path d="M12 4.5 q6 3 3.5 9.5" fill="none" stroke="#8069FF" stroke-width="1.8" stroke-linecap="round"/></g>`;

  return function operator() {
    let s = `<polygon fill="${INK}" opacity=".06" points="${pts([V(-24, 0, -34), V(154, 0, -34), V(164, 0, 48), V(-14, 0, 48)])}"/>`;
    for (const [x, z] of [[4, 32], [DESK - 8, 32], [4, 3], [DESK - 8, 3]]) s += vbox(x, 0, z, 4, 22, 4, 'st');
    s += vbox(0, 22, 0, DESK, 4, 40, 'st');                                               // desk top
    s += vbox(DESK / 2 - 8, 26, 18, 16, 2.5, 10, 'dk') + vbox(DESK / 2 - 3, 28.5, 22, 6, 7.5, 4, 'dk');      // monitor foot + neck
    s += vbox(MON.x, MON.y, MON.z, MON.w, MON.h, 5, 'dk');
    return s + display() + figure();
  };
}
