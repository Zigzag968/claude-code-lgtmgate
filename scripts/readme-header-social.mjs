// The social preview of scripts/gen-readme-header.mjs, on GitHub's "Repo Card Template": a 1280x640 white card whose content is
// centered inside the safe box x 78..1202, y 78..562 (1124x484; GitHub's guide border is 78 px from each edge, the guide lines
// themselves are not drawn). Like the template's logo + big title + subtitle, one centered group: the logo tile and the project
// name in large type, the two tagline lines under them, then the header strip (it keeps its own logo and tagline), animations
// frozen at the generator's COLD moment (the Lead is in frame). The group is 76 + 10 + 76 + 22 + 292 = 476 px high, 1088 px wide at
// most. Screenshot it at 1280x640, scale 1, to get .github/assets/social-preview.png.
export const SAFE = { x: 78, y: 78, w: 1124, h: 484 };
const STRIP = 0.85;                                                 // the strip's scale: 1088x292
const tile = `<svg width="76" height="76" viewBox="-44 -44 88 88" xmlns="http://www.w3.org/2000/svg" aria-hidden="true"><rect x="-44" y="-44" width="88" height="88" rx="22" fill="#1E1B3C"/><rect x="-32" y="-32" width="64" height="64" rx="13" fill="#0B0A18"/><path d="M-13 -5 l9 9 l17 -18" fill="none" stroke="#3DDC84" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/><text x="0" y="21" text-anchor="middle" font-family="ui-monospace,'SF Mono',SFMono-Regular,Menlo,Consolas,monospace" font-size="9.5" font-weight="700" letter-spacing="2" fill="#3DDC84">LGTM</text></svg>`;
export const socialPage = svg => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>lgtmgate social preview</title>
<style>html,body{margin:0;width:1280px;height:640px;overflow:hidden;background:#FFFFFF}
body{display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Helvetica,Arial,sans-serif}
.grp{display:flex;flex-direction:column;align-items:center}
.head{display:flex;align-items:center;gap:22px;height:76px}
.name{font-size:76px;line-height:76px;font-weight:700;letter-spacing:-2.6px;color:#1E1B3B}.name b{color:#5B3FE1;font-weight:700}
.sub{margin-top:10px;font-size:30px;line-height:38px;color:#5B6472;text-align:center}
.strip{margin-top:22px;line-height:0}
.strip svg{display:block;width:${1280 * STRIP}px;height:auto;filter:drop-shadow(0 0 1px rgba(30,27,58,.28))}
.a{animation-play-state:paused!important}</style></head>
<body><div class="grp"><div class="head">${tile}<div class="name"><b>lgtm</b>gate</div></div>
<div class="sub">An LGTM you can trust<br>Several issues at once, five agents, one mergeable PR</div>
<div class="strip">${svg}</div></div></body></html>
`;
