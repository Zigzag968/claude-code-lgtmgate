// The social preview of scripts/gen-readme-header.mjs, on GitHub's "Repo Card Template": a 1280x640 white card whose content is
// centered inside the safe box x 78..1202, y 78..562 (1124x484; GitHub's guide border is 78 px from each edge, the guide lines
// themselves are not drawn). The header (it carries the wordmark) is scaled to 1120 wide (the 1 px outline stays inside the box), centered both ways, animations
// frozen at the generator's COLD moment (the Lead is in frame). Screenshot it at 1280x640, scale 1, to get .github/assets/social-preview.png.
export const SAFE = { x: 78, y: 78, w: 1124, h: 484 };
export const socialPage = svg => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>lgtmgate social preview</title>
<style>html,body{margin:0;width:1280px;height:640px;overflow:hidden;background:#FFFFFF}
body{display:flex;align-items:center;justify-content:center}
svg{display:block;width:${SAFE.w - 4}px;height:auto;filter:drop-shadow(0 0 1px rgba(30,27,58,.28))}
.a{animation-play-state:paused!important}</style></head>
<body>${svg}</body></html>
`;
