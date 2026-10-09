// The social preview of scripts/gen-readme-header.mjs: a 1280x640 page holding the header (it carries the wordmark) at
// 1200 wide, centered, a 40-point margin left and right, animations frozen at the generator's COLD moment (the Lead is
// in frame). Screenshot it at 1280x640, scale 1, to get .github/assets/social-preview.png.
export const socialPage = svg => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>lgtmgate social preview</title>
<style>html,body{margin:0;width:1280px;height:640px;overflow:hidden;background:#F7F6F3}
body{display:flex;align-items:center;justify-content:center}
svg{display:block;width:1200px;height:auto;filter:drop-shadow(0 0 1px rgba(30,27,58,.28)) drop-shadow(0 10px 24px rgba(30,27,58,.10))}
.a{animation-play-state:paused!important}</style></head>
<body>${svg}</body></html>
`;
