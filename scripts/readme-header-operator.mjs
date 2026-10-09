// The human operator of scripts/gen-readme-header.mjs, at the left end of a desk next to the belts: seen in profile,
// headset on, head turned to the monitor, one hand on the keyboard. The monitor faces us. Its display is split in
// thirds: a minimal list on the left, the two workflows in progress on the right (one schematic row each, its four steps lit
// like the stations: orange in progress, green done, red error), then the MERGE go-ahead the human gives before the Lead merges.
const SKIN = '#F3E2D0', SKIN_SHADE = '#E8CDB3', HAIR = '#2B2749', SHIRT = '#6D5BD8', SHIRT_BACK = '#5B49C6', TROUSERS = '#35305B', CHAIR = '#2B2748';
const MON = { x: 52, y: 36, z: 22, w: 132, h: 58 };                 // the monitor (world units on the desk)
const LEFT = 41;                                                    // the list takes the left third of the display
const ROWY = { A: 19, B: 37 };                                      // back line on top, as in the scene
const NODE_X = [50, 63, 76, 89];                                    // PLAN, DEV, REVIEW, LGTM
const PILL_X = 97;

export function makeOperator({ C, pts, f2, INK, KX, KY, opts }) {
  const VX = opts.opX ?? 148, VY = opts.opY ?? 334;
  const V = (x, y, z) => [VX + x + z * KX, VY - y - z * KY];
  const vbox = (x, y, z, w, h, d, m) => {
    const f = [V(x, y, z), V(x + w, y, z), V(x + w, y + h, z), V(x, y + h, z)];
    const t = [V(x, y + h, z), V(x + w, y + h, z), V(x + w, y + h, z + d), V(x, y + h, z + d)];
    const r = [V(x + w, y, z), V(x + w, y, z + d), V(x + w, y + h, z + d), V(x + w, y + h, z)];
    return `<polygon fill="${C[m + '-r']}" points="${pts(r)}"/><polygon fill="${C[m + '-t']}" points="${pts(t)}"/><polygon fill="${C[m + '-f']}" points="${pts(f)}"/>`;
  };
  const [mx, my] = V(MON.x, MON.y + MON.h, MON.z);
  const D = { x: mx + 4, y: my + 4, w: MON.w - 8, h: MON.h - 8 };

  const display = () => {
    let s = `<rect x="${f2(D.x)}" y="${f2(D.y)}" width="${D.w}" height="${D.h}" rx="3" fill="#0B0A18"/><g transform="translate(${f2(D.x)} ${f2(D.y)})">`;
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
    return s + `</g>`;
  };

  // the seated operator in profile (local units: u to the right, v up is negative, floor at v = 0), facing the monitor
  const [ox, oy] = V(-20, 0, 12);
  const figure = () => `<g transform="translate(${f2(ox)} ${f2(oy)})">
    <rect x="-25" y="-52" width="5" height="40" rx="2.5" fill="${CHAIR}"/><rect x="-23" y="-14" width="31" height="4" rx="2" fill="${CHAIR}"/>
    <rect x="-9" y="-10" width="3" height="8" fill="${CHAIR}"/><rect x="-17" y="-3" width="21" height="3" rx="1.5" fill="${CHAIR}"/>
    <rect x="14" y="-22" width="8" height="22" rx="3" fill="${TROUSERS}"/><rect x="14" y="-4.5" width="17" height="4.5" rx="2" fill="${CHAIR}"/>
    <rect x="-14" y="-22" width="34" height="9" rx="4.5" fill="${TROUSERS}"/>
    <rect x="-14" y="-52" width="21" height="38" rx="9" fill="${SHIRT}"/><path d="M-14 -44 v26 a9 9 0 0 0 6 8.5 v-34 z" fill="${SHIRT_BACK}"/>
    <rect x="-3" y="-54" width="7" height="9" fill="${SKIN_SHADE}"/>
    <circle cx="2" cy="-63" r="10" fill="${SKIN}"/><path d="M-8 -60 A10 10 0 0 1 11 -67 L4 -64.5 Q-1 -68 -5.5 -59 Z" fill="${HAIR}"/>
    <path d="M12 -64 l4.2 4.2 l-4.2 1.3 z" fill="${SKIN_SHADE}"/><circle cx="7.4" cy="-64.4" r="1.3" fill="${INK}"/><path d="M8 -57 q2 1.2 4.2 0" fill="none" stroke="${SKIN_SHADE}" stroke-width="1.2" stroke-linecap="round"/>
    <path d="M-8 -64 A10.6 10.6 0 0 1 10.5 -69" fill="none" stroke="#B6AAFF" stroke-width="2.4" stroke-linecap="round"/>
    <rect x="-3.6" y="-67" width="6.4" height="9.5" rx="3.2" fill="#8069FF"/><path d="M0 -58 q7 7 13.5 2.5" fill="none" stroke="#8069FF" stroke-width="1.7" stroke-linecap="round"/><circle cx="13.5" cy="-55.5" r="2" fill="#8069FF"/></g>`;
  // the arm reaches over the keyboard and is drawn last, in front of the desk
  const arm = () => `<g transform="translate(${f2(ox)} ${f2(oy)})"><path d="M-3 -45 L9 -30 L27 -27" fill="none" stroke="${SHIRT}" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round"/><circle cx="29" cy="-27" r="3.3" fill="${SKIN}"/></g>`;

  return function operator() {
    let s = `<polygon fill="${INK}" opacity=".06" points="${pts([V(-60, 0, -34), V(190, 0, -34), V(200, 0, 48), V(-50, 0, 48)])}"/>`;
    s += figure();
    for (const [x, z] of [[4, 32], [172, 32], [4, 3], [172, 3]]) s += vbox(x, 0, z, 4, 22, 4, 'st');
    s += vbox(0, 22, 0, 180, 4, 40, 'st');                                               // desk top
    s += vbox(8, 26, 4, 40, 2, 11, 'dk');                                                // keyboard
    s += vbox(110, 26, 28, 16, 2.5, 10, 'dk') + vbox(115, 28.5, 32, 6, 7.5, 4, 'dk');      // monitor foot + neck
    s += vbox(MON.x, MON.y, MON.z, MON.w, MON.h, 5, 'dk');
    return s + display() + arm();
  };
}
