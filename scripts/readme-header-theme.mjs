// The dark theme of scripts/gen-readme-header.mjs: one palette map, applied to the finished SVG text.
// Neutral greys only (no violet cast): the brand violets become light or mid greys, the structure becomes dark greys.
// Kept as they are: the status lights (orange, green, red), the PR labels, the kraft family (lightly warmed) and the
// logo's green. A few uses share a hue in light but not in dark, so they carry their own value in the generator
// (rods #C9C6D5, the wordmark's "lgtm" #5B3FE1 and "gate" #1E1B3B, the logo tile #1E1B3C, the active stage label #1E1B3D,
// the sign face #5B3FE0, the operator's outline #4A4569). Any violet that is not listed is flattened to the grey of the
// same lightness, so a colour added later cannot bring the cast back.
export const DARK = {
  '#F7F6F3': '#161616', '#ECE9F1': '#1D1D1D', '#E9E6EF': '#2A2A2A',                                     // card, floor
  '#EEEDF3': '#3A3A3A', '#DDDBE6': '#2F2F2F', '#C9C6D6': '#262626', '#C9C6D5': '#4E4E4E',                 // structure, rods
  '#EEEBFA': '#454545', '#DCD6F3': '#393939', '#C3BBE6': '#2D2D2D',                                     // station columns
  '#E4E1EC': '#303030', '#CDC9DA': '#272727', '#B9B4CA': '#1F1F1F', '#CFCADD': '#3E3E3E',                 // belts, treads
  '#E6E2F4': '#353535', '#CFC8EA': '#2B2B2B', '#B7AEDC': '#232323', '#D6CFEE': '#424242',                 // main, treads
  '#B3ADC8': '#505050', '#DAD6E4': '#303030',                                                           // rail
  '#F6DEB4': '#E9CC98', '#ECC893': '#DDB77C', '#D7AD71': '#C39A5E', '#E3C38F': '#D5B27A',                 // kraft
  '#4A4570': '#8C8C8C', '#35305A': '#707070', '#28244A': '#5A5A5A', '#4A4478': '#9C9C9C',                 // Lead, gate frame
  '#2B2748': '#7C7C7C', '#3A3558': '#686868', '#211E3B': '#525252',                                     // arm, hooks, monitor
  '#4A4568': '#2C2C2C', '#DCD8E8': '#4A4A4A', '#4A4569': '#5A5A5A',                                     // unlit lamps, screen outline
  '#1E1B3B': '#EDEDED', '#1E1B3C': '#2C2C2C', '#1E1B3D': '#EDEDED', '#1E1B3A': '#1A1A1A',                 // wordmark, logo, labels, ink
  '#55506F': '#8F8F8F', '#5B6472': '#8F8F8F',
  '#5B3FE0': '#6A6A6A', '#5B3FE1': '#A6A6A6', '#7B63F0': '#8A8A8A', '#4A31C4': '#555555', '#5B3DF5': '#C8C8C8', '#8C93A0': '#6C6C6C',   // sign, wordmark, glyphs
  '#B6AAFF': '#D6D6D6', '#8069FF': '#ADADAD', '#5E48E6': '#838383', '#7C66FF': '#C4C4C4', '#C9C0FF': '#E2E2E2',                 // tool arms, scanner
  '#6D5BD8': '#9A9A9A', '#5B49C6': '#7E7E7E', '#35305B': '#4A4A4A', '#2B2749': '#8A8A8A',                                       // the operator
  '#F3E2D0': '#D2D2D2', '#E8CDB3': '#BEBEBE',
  '#8E89B0': '#9A9A9A', '#2E2A4A': '#454545', '#3A3657': '#383838', '#6E6A8A': '#8A8A8A', '#0B0A18': '#0A0A0A',                 // the screen
  '#ECEBF0': '#0D0D0D',
};
function flatten(hex) {                                              // a violet (hue 230-300, saturation above .15) -> the grey of the same lightness
  const [r, g, b] = [1, 3, 5].map(index => parseInt(hex.slice(index, index + 2), 16) / 255);
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
  if (!d) return hex;
  const s = d / (1 - Math.abs(2 * l - 1));
  const h = (mx === r ? ((g - b) / d + 6) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4) * 60;
  if (s <= .15 || h < 230 || h > 300) return hex;
  const v = Math.round(l * 255).toString(16).toUpperCase().padStart(2, '0');
  return `#${v}${v}${v}`;
}
export const themed = (text, theme) => theme === 'dark' ? text.replace(/#[0-9A-Fa-f]{6}\b/g, h => DARK[h.toUpperCase()] || flatten(h.toUpperCase())) : text;
