// The dark theme of scripts/gen-readme-header.mjs: one palette map, applied to the finished SVG text.
// The light theme's contrast hierarchy, turned around: a near-black card (GitHub's dark range), belts and main lane only a little
// lighter than the card and cool slate (they recede), station columns mid-tone steel-blue with a hint of lavender, and the Lead arm,
// gate frame, hooks and rods near-white (the highest contrast, as the navy arm is in light). Violet stays an accent only: wordmark,
// logo tile, main sign, active stage, operator, agent tools. Kept as they are: status lights, PR labels, kraft family (more vivid),
// monitor screens. The monitor frame shares its three hexes with the hooks in the generator, so the polygons of the desk (x < 300)
// are told apart by position before the map runs. A colour not listed keeps its value.
export const DARK = {
  '#F7F6F3': '#0F1319', '#ECE9F1': '#141922', '#E9E6EF': '#181E28',                                     // card, floor
  '#EEEDF3': '#2A3345', '#DDDBE6': '#222A3A', '#C9C6D6': '#1B2230', '#C9C6D5': '#566079',                 // structure, rods
  '#EEEBFA': '#8A9BC4', '#DCD6F3': '#6E7FA8', '#C3BBE6': '#55658C',                                     // station columns
  '#E4E1EC': '#313A4D', '#CDC9DA': '#262E3E', '#B9B4CA': '#1E2533', '#CFCADD': '#3D475D',                 // belts, treads
  '#D6CFEE': '#2B3447', '#E6E2F4': '#313A4D', '#CFC8EA': '#262E3E', '#B7AEDC': '#1E2533',                 // main lane
  '#B3ADC8': '#4A5470', '#DAD6E4': '#2C3446',                                                           // rail
  '#F6DEB4': '#F4D192', '#ECC893': '#E6B76C', '#D7AD71': '#C8924A', '#E3C38F': '#E0B374',                 // kraft
  '#4A4570': '#E6EDF3', '#35305A': '#C9D1D9', '#28244A': '#8B949E', '#4A4478': '#D0D7DE',                 // Lead, gate frame
  '#2B2748': '#E6EDF3', '#3A3558': '#F0F6FC', '#211E3B': '#8B949E',                                     // arm, hooks
  '#4A4568': '#2A3141', '#DCD8E8': '#2F3748', '#4A4569': '#7C86A0',                                     // unlit lamps, screen outline
  '#1E1B3B': '#F0F6FC', '#1E1B3C': '#2E2B5C', '#1E1B3D': '#FFFFFF', '#1E1B3A': '#141923',                 // wordmark, logo, active label, ink
  '#55506F': '#C9D1D9', '#5B6472': '#9DA7B3',                                                           // stage labels, tagline
  '#5B3FE0': '#6B55E6', '#5B3FE1': '#A99BFF', '#7B63F0': '#8C79FF', '#4A31C4': '#5844D0', '#5B3DF5': '#A99BFF', '#8C93A0': '#7D8696',   // sign, wordmark, glyphs
  '#35305B': '#5D56A0', '#2B2749': '#7D75BC',                                                           // the operator's trousers and head
  '#ECEBF0': '#0D1117', '#C9C0FF': '#1E2533',   // page edge, CI label on the light housings
};
const MONITOR = { '#3A3558': '#4A5368', '#2B2748': '#3A4256', '#211E3B': '#2C3344' };
const desk = text => text.replace(/<polygon fill="(#(?:3A3558|2B2748|211E3B))" points="(\d+(?:\.\d+)?),/gi,
  (m, c, x) => +x < 300 ? `<polygon fill="${MONITOR[c.toUpperCase()]}" points="${x},` : m);
export const themed = (text, theme) => theme === 'dark' ? desk(text).replace(/#[0-9A-Fa-f]{6}\b/g, h => DARK[h.toUpperCase()] || h) : text;
