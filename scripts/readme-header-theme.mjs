// The dark theme of scripts/gen-readme-header.mjs: one palette map, applied to the finished SVG text.
// Same family as the light theme, turned around: a dark slate card (GitHub's dark range, lightly tinted) and violet structure in
// the mid-light range, lavender and periwinkle (station columns, gate and Lead frames, rails, belts), so the scene stays violet but
// light and airy. Kept as they are: the status lights (orange, green, red), the PR labels, the kraft family (lightly warmed), the
// logo's green, the violet tool arms and the monitor screens (dark in both themes). A few uses share a hue in light but not in dark,
// so they carry their own value in the generator (rods #C9C6D5, the wordmark's "lgtm" #5B3FE1 and "gate" #1E1B3B, the logo tile
// #1E1B3C, the active stage label #1E1B3D, the sign face #5B3FE0, the screen outline #4A4569). A colour not listed keeps its value.
export const DARK = {
  '#F7F6F3': '#161A24', '#ECE9F1': '#1C2130', '#E9E6EF': '#2A2F44',                                     // card, floor
  '#EEEDF3': '#8A83C6', '#DDDBE6': '#756EB2', '#C9C6D6': '#5E579A', '#C9C6D5': '#8179BE',                 // structure, rods
  '#EEEBFA': '#B9B2E6', '#DCD6F3': '#9D95DA', '#C3BBE6': '#8179C2',                                     // station columns
  '#E4E1EC': '#9890D2', '#CDC9DA': '#8179C0', '#B9B4CA': '#6A62A8', '#CFCADD': '#756DB5',                 // belts, treads
  '#D6CFEE': '#7A72BA', '#E6E2F4': '#A39CDA', '#CFC8EA': '#8C84C8', '#B7AEDC': '#746CB2',                                     // main lane
  '#B3ADC8': '#B0A9E2', '#DAD6E4': '#7E77BC',                                                           // rail
  '#F6DEB4': '#E9CC98', '#ECC893': '#DDB77C', '#D7AD71': '#C39A5E', '#E3C38F': '#D5B27A',                 // kraft
  '#4A4570': '#BDB6EA', '#35305A': '#A59DDC', '#28244A': '#8B83C8', '#4A4478': '#B3ABE4',                 // Lead, gate frame
  '#2B2748': '#A59DDC', '#3A3558': '#9088CC', '#211E3B': '#7971B6',                                     // arm, hooks, monitor
  '#4A4568': '#323859', '#DCD8E8': '#4C477E', '#4A4569': '#8179BE',                                     // unlit lamps, screen outline
  '#1E1B3B': '#ECEAFA', '#1E1B3C': '#2E2B5C', '#1E1B3D': '#ECEAFA', '#1E1B3A': '#1B1D2B',                 // wordmark, logo, labels, ink
  '#55506F': '#2B2756', '#5B6472': '#9AA2BA',                                                           // stage labels, tagline
  '#5B3FE0': '#6B55E6', '#5B3FE1': '#A99BFF', '#7B63F0': '#8C79FF', '#4A31C4': '#5844D0', '#5B3DF5': '#A99BFF', '#8C93A0': '#7078A0',   // sign, wordmark, glyphs
  '#35305B': '#5D56A0', '#2B2749': '#7D75BC',                                                           // the operator's trousers and head
  '#ECEBF0': '#0D1117',
};
export const themed = (text, theme) => theme === 'dark' ? text.replace(/#[0-9A-Fa-f]{6}\b/g, h => DARK[h.toUpperCase()] || h) : text;
