#!/usr/bin/env bash
# Self-test of scripts/agent-context.cjs (#264): per-role specifics assembled from the base ref of a
# synthetic git repo built in $TMPDIR from fixtures/agent-context/base. Covers the source order, the
# `*`/role lists, dedup, the file-level refusals (exit 3), the frontmatter schema (exit 2), the caps
# (warning at the recommended size, exit 4 at the hard ceiling), the digest (recomputed independently),
# the base-ref-only config read and --accept-oversize.
# Planted bad values (secret form, invisible character) are assembled below from fragments at run time:
# no token-shaped or invisible literal in this source or in the fixtures.
# bash 3.2 compatible. Trailer: [test-agent-context] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
AC="$ROOT/scripts/agent-context.cjs"
BASE="$ROOT/fixtures/agent-context/base"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="${TMPDIR:-/tmp}/agent-context-selftest.$$"; mkdir -p "$TMP"
OUT="$TMP/out"; ERR="$TMP/err"
rc=0

# new_repo <dir>: a fresh repo holding a copy of the base fixture tree (not committed yet)
new_repo() {
  git init -q "$1"
  git -C "$1" config user.name t
  git -C "$1" config user.email t@example.com
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
  cp -R "$BASE/." "$1/"
  # the config fixture is stored as .json.in so the recursive *.json replay collector ignores it
  mv "$1/.claude/pipeline.config.json.in" "$1/.claude/pipeline.config.json"
}
git_add_all() { git -C "$1" add -A; }
commit_ref() {
  git -C "$1" commit -q -m fixture
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
seal() { git_add_all "$1"; commit_ref "$1"; }
# setcfg <dir> <json>
setcfg() { printf '%s\n' "$2" > "$1/.claude/pipeline.config.json"; }
# run <dir> <args...>: stdout in $OUT, stderr in $ERR, exit code in $rc
run() { local d=$1; shift; (cd "$d" && node "$AC" --root "$d" "$@") >"$OUT" 2>"$ERR"; rc=$?; }
# jx <expr>: evaluates a JS expression over the parsed stdout (j)
jx() {
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(new Function("j","return ("+process.argv[2]+")")(j)))' "$OUT" "$1"
}
# jtrue <label> <expr>: ok when the expression is true
jtrue() { if [ "$(jx "$2")" = "true" ]; then ok "$1"; else bad "$1: [$2] -> $(jx "$2" 2>&1 | head -c 200)"; fi; }
# exit_is <label> <code>: the exit code, and nothing on stdout when it is not 0
exit_is() {
  if [ "$rc" != "$2" ]; then bad "$1: exit $rc (wanted $2): $(head -c 300 "$ERR")"; return; fi
  if [ "$2" != 0 ] && [ -s "$OUT" ]; then bad "$1: stdout is not empty on a refusal"; return; fi
  ok "$1"
}
err_has() { if grep -qF -- "$2" "$ERR"; then ok "$1"; else bad "$1: stderr lacks [$2]: $(head -c 300 "$ERR")"; fi; }
# padfile <file> <bytes>: plain lines up to about <bytes>
padfile() { node -e 'let s="";while(s.length<+process.argv[1])s+="padding line for the size tests\n";process.stdout.write(s)' "$2" > "$1"; }

# ---- base repo ------------------------------------------------------------------------------
R="$TMP/base"; new_repo "$R"; seal "$R"
run "$R"
exit_is "ok-base" 0
jtrue "ok-base: roles Nick Sam Morgan, shared set" 'j.shared!==null&&Object.keys(j.roles).sort().join()==="Morgan,Nick,Sam"&&/^[0-9a-f]{40}$/.test(j.refSha)'
jtrue "order-shared-role-subjects-extra" '(()=>{const t=j.roles.Nick.text;const a=["NICK-MARK","NICK-ALPHA-MARK","NICK-TESTING-MARK","NICK-EXTRA-MARK"].map(m=>t.indexOf(m));return a.every((x,i)=>x>=0&&(i===0||x>a[i-1]))&&!t.includes("SHARED-MARK")&&j.shared.text.includes("SHARED-MARK")})()'
jtrue "US-C4: subject-not-lane: nick.testing.md (no frontmatter) is a subject, never a lane" 'j.roles.Nick.text.includes("NICK-TESTING-MARK")&&j.roles.Nick.lanes.length===0&&j.files.some(f=>f.path.endsWith("nick.testing.md")&&f.roles.includes("Nick"))'
jtrue "role-without-source-absent: Theo has no block" '!("Theo" in j.roles)'
jtrue "frontmatter-strip: Morgan keeps its base body, the lane (frontmatter stripped) is kept apart" '(()=>{const m=j.roles.Morgan;const l=m.lanes[0];return m.text.includes("MORGAN-MARK")&&!m.text.includes("MORGAN-REVIEW-MARK")&&!m.text.includes("lane:")&&m.lanes.length===1&&l.name==="review"&&l.persona==="reviewer"&&l.hint==="review lane"&&l.text.includes("MORGAN-REVIEW-MARK")&&!l.text.includes("persona")&&l.files.length===1&&l.files[0].endsWith("morgan.review.md")})()'
jtrue "empty-stub-ignored: comment-only mia.md warns, exit 0, no Mia block" '!("Mia" in j.roles)&&j.warnings.some(w=>w.kind==="empty-ignored"&&w.path.endsWith("mia.md"))&&j.files.some(f=>f.path.endsWith("mia.md")&&f.empty===true)'

# ---- digest, recomputed independently ---------------------------------------------------------
SHA=$(jx 'j.refSha'); DIG=$(jx 'j.roles.Sam.digest'); TXT=$(jx 'JSON.stringify(j.roles.Sam.text)')
WANT=$(printf '{"lanes":[],"refSha":"%s","role":"Sam","text":%s}' "$SHA" "$TXT" | shasum -a 256 | cut -d' ' -f1)
if [ -n "$DIG" ] && [ "$DIG" = "$WANT" ]; then ok "digest-independent: sha256 of {lanes,refSha,role,text} matches"; else bad "digest-independent: got [$DIG] wanted [$WANT]"; fi

# ---- digest parity with the workflow engine (#265) ----------------------------------------------
SHA_BLK="$(sed -n '/^\/\/ --- sha256Hex:start ---/,/^\/\/ --- sha256Hex:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
PS_BLK="$(sed -n '/^\/\/ --- projectSpecifics:start ---/,/^\/\/ --- projectSpecifics:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
PAR=0
if [ -n "$SHA_BLK" ] && [ -n "$PS_BLK" ]; then
  node -e '
    const f = new Function(process.argv[1] + "\n" + process.argv[2] + "\nreturn { sha256Hex, specificsDigest }")()
    const { digestOf } = require(process.argv[3])
    const ref = "0123456789abcdef0123456789abcdef01234567"
    const lanes = [{ file: "d/sam.api.md", lane: "api", persona: "p", hint: "h", paths: ["a/**", "b"] }]
    const cases = [["Nick", "Use tabs.", []], ["Sam", "caf\u00e9 \u00e9", []], ["Morgan", "astral \ud83d\ude80 char", lanes], ["Theo", "", []], ["shared", "S\nT", []], ["Sam", "x", lanes]]
    for (const [k, t, l] of cases) if (f.specificsDigest(f.sha256Hex, ref, k, t, l) !== digestOf(ref, k, t, l)) process.exit(1)
  ' "$SHA_BLK" "$PS_BLK" "$AC" 2>/dev/null && PAR=1
fi
if [ "$PAR" = 1 ]; then ok "digest-parity-workflow: the engine digest equals agent-context.cjs digestOf"; else bad "digest-parity-workflow: the engine digest differs from digestOf"; fi

# ---- print ------------------------------------------------------------------------------------
run "$R" --print Nick
if [ "$rc" = 0 ] && grep -q '^== Nick (' "$OUT" && grep -q 'NICK-MARK' "$OUT" && ! grep -q 'SAM-MARK' "$OUT"; then ok "print: --print Nick renders one role"; else bad "print: exit $rc: $(head -c 200 "$OUT")"; fi

# ---- config read from the ref, never the worktree --------------------------------------------
run "$R"; cp "$OUT" "$TMP/before"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":""}'
run "$R"
if [ "$rc" = 0 ] && cmp -s "$OUT" "$TMP/before"; then ok "config-from-ref-not-worktree: an edited worktree config changes nothing"; else bad "config-from-ref-not-worktree: exit $rc"; fi
git -C "$R" checkout -q -- .claude/pipeline.config.json

# ---- bad ref ----------------------------------------------------------------------------------
run "$R" --ref 'origin/main;touch pwned'
if [ "$rc" = 2 ] && [ ! -e "$R/pwned" ] && [ ! -e "$ROOT/pwned" ]; then ok "bad-ref-exit2: injection refused, no file created"; else bad "bad-ref-exit2: exit $rc"; fi

# ---- switch off -------------------------------------------------------------------------------
R="$TMP/off"; new_repo "$R"; setcfg "$R" '{"baseBranch":"main"}'; seal "$R"
run "$R"
exit_is "no-switch-empty-payload: exit 0" 0
jtrue "no-switch-empty-payload: empty payload" 'j.shared===null&&Object.keys(j.roles).length===0&&j.files.length===0&&j.warnings.length===0'

# ---- agentContext lists, dedup ----------------------------------------------------------------
R="$TMP/star"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"],"Nick":["docs/extra-nick.md"]}}'; seal "$R"
run "$R"
jtrue "agentcontext-star-and-role: * reaches every role, the role list only its role" 'j.roles.Sam.text.includes("ALL-EXTRA-MARK")&&j.roles.Mia.text.includes("ALL-EXTRA-MARK")&&j.roles.Theo.text.includes("ALL-EXTRA-MARK")&&j.roles.Nick.text.includes("ALL-EXTRA-MARK")&&j.roles.Nick.text.includes("NICK-EXTRA-MARK")&&!j.roles.Sam.text.includes("NICK-EXTRA-MARK")'
R="$TMP/dedup"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-nick.md"],"Nick":["docs/extra-nick.md",".claude/lgtmgate/shared.md",".claude/lgtmgate/nick.md"]}}'; seal "$R"
run "$R"
jtrue "dedup-first-wins: a path never repeats, shared.md stays in shared" '(()=>{const t=j.roles.Nick.text;return t.split("NICK-EXTRA-MARK").length===2&&t.split("NICK-MARK").length===2&&!t.includes("SHARED-MARK")})()'

# ---- file-level refusals (exit 3) --------------------------------------------------------------
R="$TMP/missing"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/nope.md"]}}'; seal "$R"
run "$R"; exit_is "missing-exit3" 3
R="$TMP/nodir"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/nodir"}'; seal "$R"
run "$R"; exit_is "folder-absent-exit3" 3
R="$TMP/symlink"; new_repo "$R"
rm "$R/docs/extra-nick.md"; git_add_all "$R"
LNK=$(printf 'extra-all.md' | git -C "$R" hash-object -w --stdin)
git -C "$R" update-index --add --cacheinfo "120000,$LNK,docs/extra-nick.md"
commit_ref "$R"
run "$R"; exit_is "symlink-blob-exit3 (committed mode 120000)" 3
err_has "symlink-blob-exit3: the rule is named" "symlink"
R="$TMP/symdisc"; new_repo "$R"
rm "$R/.claude/lgtmgate/nick.alpha.md"; git_add_all "$R"
LNK=$(printf 'nick.md' | git -C "$R" hash-object -w --stdin)
git -C "$R" update-index --add --cacheinfo "120000,$LNK,.claude/lgtmgate/nick.alpha.md"
commit_ref "$R"
run "$R"; exit_is "symlink-discovered-exit3 (a symlink named like a subject)" 3
R="$TMP/dotdot"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/../docs/extra-nick.md"]}}'; seal "$R"
run "$R"; exit_is "dotdot-exit3" 3
R="$TMP/nonmd"; new_repo "$R"; printf 'plain\n' > "$R/docs/data.txt"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/data.txt"]}}'; seal "$R"
run "$R"; exit_is "non-md-exit3" 3
R="$TMP/atline"; new_repo "$R"; printf 'intro\n@include other.md\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "at-line-exit3" 3
err_has "at-line-exit3: names the rule and the line" "at-line at line 2"
R="$TMP/machine"; new_repo "$R"; printf 'text\n</project_specifics>\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "machine-literal-exit3" 3
R="$TMP/owd"; new_repo "$R"; printf 'one-way-door: none\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "one-way-door-line-exit3" 3
R="$TMP/invis"; new_repo "$R"; { printf 'zero'; printf '\342\200\213'; printf 'width\n'; } > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "invisible-char-exit3" 3
R="$TMP/secret"; new_repo "$R"
TOK="gh""p_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"
printf 'a token: %s\n' "$TOK" > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "secret-form-exit3" 3
if grep -qF -- "$TOK" "$ERR"; then bad "secret-form-exit3: the value is printed"; else ok "secret-form-exit3: the value is never printed"; fi

# ---- schema and encoding ------------------------------------------------------------------------
R="$TMP/fmbad"; new_repo "$R"; printf -- '---\nbogus: x\n---\nbody\n' > "$R/.claude/lgtmgate/nick.md"; seal "$R"
run "$R"; exit_is "frontmatter-schema-exit2" 2
R="$TMP/unkrole"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Bob":["docs/extra-all.md"]}}'; seal "$R"
run "$R"; exit_is "unknown-role-exit2" 2
R="$TMP/crlf"; new_repo "$R"; { printf '\357\273\277'; printf '# Nick\r\n\r\nNICK-MARK crlf file.\r\n'; } > "$R/.claude/lgtmgate/nick.md"; seal "$R"
run "$R"
jtrue "crlf-bom-normalised: no CR, no BOM" '!j.roles.Nick.text.includes("\r")&&j.roles.Nick.text.charCodeAt(0)!==0xFEFF&&j.roles.Nick.text.startsWith("# Nick\n\nNICK-MARK crlf file.")'

# ---- caps ---------------------------------------------------------------------------------------
R="$TMP/big"; new_repo "$R"; padfile "$R/docs/extra-nick.md" 7000; seal "$R"
run "$R"
exit_is "recommended-cap-warns-exit0: exit 0" 0
jtrue "recommended-cap-warns-exit0: oversize warning asks" 'j.warnings.some(w=>w.kind==="oversize"&&w.role==="Nick"&&w.recommended===6144&&w.ask===true&&w.accepted===null)'
R="$TMP/ceil"; new_repo "$R"; padfile "$R/docs/extra-nick.md" 70000; seal "$R"
run "$R"; exit_is "hard-ceiling-exit4" 4

# ---- --accept-oversize --------------------------------------------------------------------------
R="$TMP/acc"; new_repo "$R"; padfile "$R/docs/extra-nick.md" 7000; seal "$R"
printf '{"keep":1}\n' > "$R/.claude/pipeline.config.local.json"
run "$R" --accept-oversize Nick
NB=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j.accepted.Nick))' "$OUT" 2>/dev/null)
LOCALV=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(j.keep+":"+j.specifics.acceptOversize.Nick)' "$R/.claude/pipeline.config.local.json" 2>/dev/null)
LEFT=$(find "$R/.claude" -name '*.tmp-*' | wc -l | tr -d ' ')
TRACKED=$(git -C "$R" status --porcelain --untracked-files=no | wc -l | tr -d ' ')
if [ "$rc" = 0 ] && [ -n "$NB" ] && [ "$LOCALV" = "1:$NB" ] && [ "$LEFT" = 0 ] && [ "$TRACKED" = 0 ]; then ok "accept-oversize-patch: only the local file changes, other keys kept, no temp file left"; else bad "accept-oversize-patch: exit $rc nb=[$NB] local=[$LOCALV] left=$LEFT tracked-changes=$TRACKED"; fi
run "$R"
jtrue "accept-oversize-patch: the accepted size silences the warning" '!j.warnings.some(w=>w.kind==="oversize")'
# 25 % rule: within it no warning, above it the question comes back with the accepted size
R2="$TMP/acc2"; new_repo "$R2"; padfile "$R2/docs/extra-nick.md" 7600; seal "$R2"
printf '{"specifics":{"acceptOversize":{"Nick":%s}}}\n' "$NB" > "$R2/.claude/pipeline.config.local.json"
run "$R2"
jtrue "accept-oversize-asks-again: within +25 % no warning" '!j.warnings.some(w=>w.kind==="oversize")'
R3="$TMP/acc3"; new_repo "$R3"; padfile "$R3/docs/extra-nick.md" 11000; seal "$R3"
printf '{"specifics":{"acceptOversize":{"Nick":%s}}}\n' "$NB" > "$R3/.claude/pipeline.config.local.json"
run "$R3"
jtrue "accept-oversize-asks-again: above +25 % it asks again" 'j.warnings.some(w=>w.kind==="oversize"&&w.role==="Nick"&&w.ask===true&&w.accepted===+"'"$NB"'")'
R4="$TMP/acc4"; new_repo "$R4"; seal "$R4"
run "$R4" --accept-oversize Nick; exit_is "accept-oversize-nothing-exit2: a role within the cap has nothing to accept" 2

# ---- lanes (#271) -------------------------------------------------------------------------------------
# lane_repo <dir>: the base fixture plus sam.ios.md (lane ios, persona Ivy, paths) and sam.web.md; nothing sealed yet
lane_repo() {
  new_repo "$1"
  printf -- '---\nlane: ios\npersona: Ivy\nhint: a senior iOS planner\npaths: ["ios/**", "!ios/Generated/**"]\n---\nIOS-SAM-MARK plans screens.\n' > "$1/.claude/lgtmgate/sam.ios.md"
  printf -- '---\nlane: web\n---\nWEB-SAM-MARK plans routes.\n' > "$1/.claude/lgtmgate/sam.web.md"
}
R="$TMP/lane1"; lane_repo "$R"; seal "$R"
run "$R"
exit_is "lane-valid-frontmatter: exit 0" 0
jtrue "lane-output-shape: base text kept apart, lanes array sorted with metadata, files and a digest each" '(()=>{const s=j.roles.Sam;const [a,b]=s.lanes;return s.text.includes("SAM-MARK")&&!s.text.includes("IOS-SAM-MARK")&&!s.text.includes("WEB-SAM-MARK")&&s.lanes.length===2&&a.name==="ios"&&b.name==="web"&&a.persona==="Ivy"&&a.hint==="a senior iOS planner"&&a.paths.length===2&&b.persona===undefined&&a.files.length===1&&a.text==="IOS-SAM-MARK plans screens."&&/^[0-9a-f]{64}$/.test(a.digest)&&a.bytes===a.text.length&&s.bytes===s.text.length+Math.max(a.bytes,b.bytes)})()'
jtrue "lane-display-list: top-level lanes lists each lane once with its roles" '(()=>{const a=j.lanes.find(l=>l.name==="ios");return j.lanes.length===3&&j.lanes.map(l=>l.name).join()==="ios,review,web"&&a.roles.join()==="Sam"&&a.persona==="Ivy"})()'
SHA=$(jx 'j.refSha'); LDIG=$(jx 'j.roles.Sam.lanes[0].digest'); RDIG=$(jx 'j.roles.Sam.digest')
WANT=$(printf '{"lanes":[],"refSha":"%s","role":"Sam:ios","text":"IOS-SAM-MARK plans screens."}' "$SHA" | shasum -a 256 | cut -d' ' -f1)
if [ -n "$LDIG" ] && [ "$LDIG" = "$WANT" ]; then ok "lane-digest-independent: sha256 of {lanes,refSha,role Sam:ios,text} matches"; else bad "lane-digest-independent: got [$LDIG] wanted [$WANT]"; fi
WANTR=$(node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const c=require("crypto");const {canonicalJson}=require(process.argv[2]);process.stdout.write(c.createHash("sha256").update(canonicalJson({refSha:j.refSha,role:"Sam",text:j.roles.Sam.text,lanes:j.roles.Sam.lanes}),"utf8").digest("hex"))' "$OUT" "$AC")
if [ "$RDIG" = "$WANTR" ]; then ok "lane-digest-role-covers-lanes: the role digest hashes the lane entries"; else bad "lane-digest-role-covers-lanes: got [$RDIG] wanted [$WANTR]"; fi
cp "$OUT" "$TMP/lane1.json"

R="$TMP/lane2"; lane_repo "$R"; printf -- '---\nlane: web\n---\nbody\n' > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-name-differs-from-file-name-exit2" 2
err_has "lane-name-differs-from-file-name-exit2: names the rule" "frontmatter-lane-mismatch"
R="$TMP/lane3"; lane_repo "$R"; printf -- '---\nlane: ios\n---\nbody\n' > "$R/.claude/lgtmgate/sam.md"; seal "$R"
run "$R"; exit_is "lane-frontmatter-on-role-file-exit2" 2
R="$TMP/lane4"; lane_repo "$R"; printf -- '---\nlane: ios\ncolor: red\n---\nbody\n' > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-unknown-field-exit2" 2
R="$TMP/lane5"; lane_repo "$R"; printf -- '---\nlane: iOS_App\n---\nbody\n' > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-name-regex-exit2" 2
LONG80=$(node -e 'process.stdout.write("p".repeat(81))'); LONG120=$(node -e 'process.stdout.write("h".repeat(121))')
R="$TMP/lane6"; lane_repo "$R"; printf -- '---\nlane: ios\npersona: %s\n---\nbody\n' "$LONG80" > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-persona-over-80-exit2" 2
R="$TMP/lane6b"; lane_repo "$R"; printf -- '---\nlane: ios\npersona: Two Words\n---\nbody\n' > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-persona-two-tokens-exit2" 2
R="$TMP/lane7"; lane_repo "$R"; printf -- '---\nlane: ios\nhint: %s\n---\nbody\n' "$LONG120" > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-hint-over-120-exit2" 2
R="$TMP/lane8"; lane_repo "$R"; printf -- '---\nlane: ios\npaths: ["a","b","c","d","e","f","g","h","i"]\n---\nbody\n' > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-paths-over-8-entries-exit2" 2
R="$TMP/lane9"; lane_repo "$R"; printf -- '---\nlane: ios\npaths: ["%s"]\n---\nbody\n' "$LONG80" > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-path-entry-over-80-exit2" 2
R="$TMP/lane10"; lane_repo "$R"; printf -- '---\nlane: ios\npersona: ivy\n---\nIOS-NICK-MARK\n' > "$R/.claude/lgtmgate/nick.ios.md"; seal "$R"
run "$R"; exit_is "lane-persona-duplicated-exit2 (case-insensitive, across roles)" 2
err_has "lane-persona-duplicated-exit2: names the rule" "frontmatter-persona-duplicate"
R="$TMP/lane11"; lane_repo "$R"; printf -- '---\nlane: ios\npersona: sam\n---\nbody\n' > "$R/.claude/lgtmgate/sam.ios.md"; seal "$R"
run "$R"; exit_is "lane-persona-equal-to-role-name-exit2" 2
R="$TMP/lane12"; lane_repo "$R"; printf -- '---\npersona: Other\n---\nIOS-SAM-MORE-MARK\n' > "$R/.claude/lgtmgate/sam.ios.testing.md"; seal "$R"
run "$R"; exit_is "lane-metadata-contradiction-in-a-pair-exit2" 2
R="$TMP/lane13"; lane_repo "$R"; printf 'IOS-SAM-EXTRA-MARK from a file without frontmatter.\n' > "$R/.claude/lgtmgate/sam.ios.testing.md"; seal "$R"
run "$R"
jtrue "lane-deduced-from-file-name: a sibling without frontmatter joins the declared lane" '(()=>{const s=j.roles.Sam;const a=s.lanes.find(l=>l.name==="ios");return a.files.length===2&&a.text.includes("IOS-SAM-EXTRA-MARK")&&a.persona==="Ivy"&&!s.text.includes("IOS-SAM-EXTRA-MARK")})()'
R="$TMP/lane14"; lane_repo "$R"; printf 'SAM-SUBJECT-MARK no lane declares this segment.\n' > "$R/.claude/lgtmgate/sam.extra.md"; seal "$R"
run "$R"
jtrue "lane-subject-when-undeclared: a segment no file declares stays a subject of the base" '(()=>{const s=j.roles.Sam;return s.text.includes("SAM-SUBJECT-MARK")&&s.lanes.length===2&&!s.lanes.some(l=>l.name==="extra")})()'
R="$TMP/lane15"; lane_repo "$R"; printf -- '---\nlane: ios\n---\nbody\n' > "$R/docs/extra-all.md"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"]}}'; seal "$R"
run "$R"; exit_is "lane-frontmatter-on-agentcontext-file-exit2" 2
R="$TMP/lane16"; lane_repo "$R"; printf -- '---\nlane: ios\npersona: Nora\n---\n<!-- to be completed -->\n' > "$R/.claude/lgtmgate/nick.ios.md"; seal "$R"
run "$R"
exit_is "lane-empty-file-is-ignored: a comment-only lane file warns, exit 0" 0
jtrue "lane-empty-file-is-ignored: no Nick lane block, empty-ignored warning" '!("Nick" in j.roles&&j.roles.Nick.lanes.some(l=>l.name==="ios"))&&j.warnings.some(w=>w.kind==="empty-ignored"&&w.path.endsWith("nick.ios.md"))'
R="$TMP/lane17"; new_repo "$R"; rm "$R/.claude/lgtmgate/nick.md" "$R/.claude/lgtmgate/nick.alpha.md" "$R/.claude/lgtmgate/nick.testing.md"
printf -- '---\nlane: ios\n---\nIOS-NICK-ONLY-MARK\n' > "$R/.claude/lgtmgate/nick.ios.md"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate"}'; seal "$R"
run "$R"
jtrue "lane-role-with-lanes-but-no-base: text is empty, the lane carries the content" 'j.roles.Nick.text===""&&j.roles.Nick.lanes.length===1&&j.roles.Nick.bytes===j.roles.Nick.lanes[0].bytes'

# ---- paths block list (#407) --------------------------------------------------------------------------
# paths_repo <dir> <frontmatter-body>: the base fixture plus sam.ios.md with `lane: ios` and the given extra frontmatter lines (printf %b), sealed
paths_repo() {
  new_repo "$1"
  printf -- '---\nlane: ios\n%b---\nIOS-SAM-MARK plans screens.\n' "$2" > "$1/.claude/lgtmgate/sam.ios.md"
  seal "$1"
}
R="$TMP/pb1"; paths_repo "$R" 'paths:\n  - "**/*.swift"\n  - "Sources/**"\n'
run "$R"
exit_is "paths-block-list-accepted: exit 0" 0
jtrue "paths-block-list-same-array: the lane carries the inline form's array" 'JSON.stringify(j.roles.Sam.lanes[0].paths)===JSON.stringify(["**/*.swift","Sources/**"])'
PB_DIGESTS=$(node -e 'const {parseFrontmatter,digestOf}=require(process.argv[1]);const d=(p)=>{const f=parseFrontmatter("---\nlane: ios\n"+p+"---\nbody\n");return digestOf("0".repeat(40),"Sam",f.body,[f.meta])};process.stdout.write(String(d("paths:\n  - \"**/*.swift\"\n  - \"Sources/**\"\n")===d("paths: [\"**/*.swift\", \"Sources/**\"]\n")))' "$AC")
if [ "$PB_DIGESTS" = "true" ]; then ok "paths-block-list-same-digest: parseFrontmatter and digestOf give the inline form's value"; else bad "paths-block-list-same-digest: got [$PB_DIGESTS]"; fi
R="$TMP/pb4"; paths_repo "$R" "paths:\n  - 'a/b'\n  - c/d\n  - \"e\"\n"
run "$R"
jtrue "paths-block-list-quote-styles: single-quoted and plain items give the same array" 'JSON.stringify(j.roles.Sam.lanes[0].paths)===JSON.stringify(["a/b","c/d","e"])'
R="$TMP/pb5"; paths_repo "$R" 'paths:\n  - "e1"\n  - "e2"\n  - "e3"\n  - "e4"\n  - "e5"\n  - "e6"\n  - "e7"\n  - "e8"\n  - "e9"\n'
run "$R"; exit_is "paths-block-list-nine-entries: exit 2" 2
err_has "paths-block-list-nine-entries: names the rule" "frontmatter-paths-too-many at line 3"
R="$TMP/pb7"; paths_repo "$R" "paths:\n  - \"$LONG80\"\n"
run "$R"; exit_is "paths-block-list-long-entry: exit 2" 2
err_has "paths-block-list-long-entry: names the rule" "frontmatter-paths-entry-too-long at line 3"
R="$TMP/pb9"; paths_repo "$R" 'paths:\n  - - a\n'
run "$R"; exit_is "paths-block-list-nested-list: exit 2" 2
err_has "paths-block-list-nested-list: names the rule" "frontmatter-paths at line 3"
R="$TMP/pb11"; paths_repo "$R" 'paths:\n  - &a x\n'
run "$R"; exit_is "paths-block-list-anchor-item: exit 2" 2
err_has "paths-block-list-anchor-item: names the rule" "frontmatter-paths at line 3"
R="$TMP/pb13"; paths_repo "$R" 'paths: ["a"]\n  - b\n'
run "$R"; exit_is "paths-block-list-after-inline-value: exit 2" 2
err_has "paths-block-list-after-inline-value: names the rule" "frontmatter-syntax at line 4"
R="$TMP/pb15"; paths_repo "$R" 'hint: x\n  - a\n'
run "$R"; exit_is "paths-block-list-outside-paths: exit 2" 2
err_has "paths-block-list-outside-paths: names the rule" "frontmatter-syntax at line 4"
R="$TMP/pb17"; paths_repo "$R" 'paths:\n  - a:b\n'
run "$R"; exit_is "paths-block-list-colon-item: exit 2" 2
err_has "paths-block-list-colon-item: names the rule" "frontmatter-paths at line 3"
R="$TMP/pb19"; paths_repo "$R" 'paths: src/**/*.swift\n'
run "$R"
if grep -F 'paths: [' "$ERR" | grep -qF 'block list'; then ok "paths-hint-names-both-forms: one line holds both"; else bad "paths-hint-names-both-forms: $(head -c 300 "$ERR")"; fi
R="$TMP/pb20"; paths_repo "$R" 'paths: ["a"]\n  - b\n  - c\nbogus: x\n'
run "$R"
if [ "$(grep -cF 'block list' "$ERR")" = "1" ]; then ok "paths-hint-once: three refusals, one hint line"; else bad "paths-hint-once: $(head -c 400 "$ERR")"; fi
R="$TMP/pb21"; paths_repo "$R" 'bogus: x\n'
run "$R"
if grep -qF 'frontmatter-unknown-key' "$ERR" && ! grep -qF 'block list' "$ERR"; then ok "paths-hint-absent-on-unrelated-refusal: no hint line"; else bad "paths-hint-absent-on-unrelated-refusal: $(head -c 300 "$ERR")"; fi

# ---- engine helpers, extracted from the workflow like the digest parity block ------------------------------------
SAFE_BLK="$(sed -n '/^\/\/ --- safePlanTargets:start ---/,/^\/\/ --- safePlanTargets:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
OWD_BLK="$(sed -n '/^\/\/ --- oneWayDoor:start ---/,/^\/\/ --- oneWayDoor:end ---/p' "$ROOT/workflows/deliver-pipeline.js")"
cat > "$TMP/eng.cjs" <<'JS'
const fs = require('fs')
const [shaB, psB, safeB, owdB, payloadFile, acPath] = process.argv.slice(2)
const f = new Function(shaB + '\n' + psB + '\n' + safeB + '\n' + owdB + '\nreturn { sha256Hex, specificsDigest, specificsProblem, specificsBlockFor, specificsLanesFound, resolveTheoLanes, lanesFromPlanText, appendLanesLine, lanePathHits, laneSentence, theoLanesSection }')()
const ps = JSON.parse(fs.readFileSync(payloadFile, 'utf8'))
const ac = require(acPath)
const out = {}
out.problem = String(f.specificsProblem(true, ps, f.sha256Hex))
out.accepts = f.specificsProblem(true, ps, f.sha256Hex) === null
const bad = JSON.parse(JSON.stringify(ps)); bad.roles.Sam.lanes[0].text += ' tampered'
const roleOnly = String(f.specificsProblem(true, bad, f.sha256Hex)).startsWith('digest mismatch for Sam')
bad.roles.Sam.digest = f.specificsDigest(f.sha256Hex, bad.refSha, 'Sam', bad.roles.Sam.text, bad.roles.Sam.lanes)
out.rejectsTamper = roleOnly && String(f.specificsProblem(true, bad, f.sha256Hex)).startsWith('digest mismatch for Sam:ios')
const found = f.specificsLanesFound(ps)
out.found = found.map((l) => l.name).join() === 'ios,review,web' && found[0].persona === 'Ivy'
const blk = f.specificsBlockFor(ps, 'sam', ['ios'])
out.blockIos = blk.indexOf('In this lane you act as Ivy, a senior iOS planner.') > blk.indexOf('<project_specifics>') && blk.indexOf('In this lane you act as Ivy') < blk.indexOf('SAM-MARK') && blk.includes('IOS-SAM-MARK') && !blk.includes('WEB-SAM-MARK')
out.blockNone = !f.specificsBlockFor(ps, 'sam', []).includes('IOS-SAM-MARK') && f.specificsBlockFor(ps, 'sam') === f.specificsBlockFor(ps, 'sam', [])
out.blockSkipsMissing = !f.specificsBlockFor(ps, 'morgan', ['ios']).includes('IOS-SAM-MARK')
const r = (a) => JSON.stringify(f.resolveTheoLanes(found, a))
out.resolve = r(['ios']) === '{"lanes":["ios"],"unresolved":false,"unknown":[]}' && JSON.parse(r([])).unresolved === true && JSON.parse(r(undefined)).unresolved === true && JSON.parse(r('ios')).unresolved === true && JSON.parse(r(['ios', 3])).unresolved === true && JSON.parse(r(['ios', 'mars'])).unknown.join() === 'mars'
const plan = f.appendLanesLine('plan body\n\n', ['ios', 'web'])
out.roundTrip = plan === 'plan body\nlanes: ios,web' && f.lanesFromPlanText(plan).join() === 'ios,web' && f.lanesFromPlanText('no line').length === 0 && f.lanesFromPlanText('lanes: IOS').length === 0 && f.lanesFromPlanText('lanes: ios,').length === 0 && f.appendLanesLine('p', []) === 'p'
out.pathHits = f.lanePathHits(found, ['ios/App.swift']).join() === 'ios' && f.lanePathHits(found, ['ios/Generated/X.swift']).length === 0 && f.lanePathHits(found, ['docs/a.md']).length === 0 && f.lanePathHits(found, ['ios/App.swift', 'web/a.js']).join() === 'ios'
out.sentence = [['Ivy', 'a senior iOS planner'], ['Ivy', undefined], [undefined, 'x'], ['', 'x']].every(([p, h]) => f.laneSentence(p, h) === ac.laneSentence(p, h))
out.theoSection = f.theoLanesSection([]) === '' && f.theoLanesSection(found).startsWith('LANES:') && f.theoLanesSection(found).includes('ios (persona Ivy')
process.stdout.write(JSON.stringify(out))
JS
node "$TMP/eng.cjs" "$SHA_BLK" "$PS_BLK" "$SAFE_BLK" "$OWD_BLK" "$TMP/lane1.json" "$AC" > "$TMP/eng.out" 2> "$TMP/eng.err"
eng() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j[process.argv[2]]))' "$TMP/eng.out" "$1" 2>/dev/null; }
for k in accepts rejectsTamper found blockIos blockNone blockSkipsMissing resolve roundTrip pathHits sentence theoSection; do
  if [ "$(eng $k)" = "true" ]; then ok "lane-engine-$k"; else bad "lane-engine-$k: $(head -c 300 "$TMP/eng.err") $(eng problem)"; fi
done

# ---- #408: a line starting with @ is accepted only inside a closed fenced code block ---------------------------------
SW='@Environment(\.horizontalSizeClass) private var horizontalSizeClass'
# atcase <name> <printf format with one %s for the @ line or the planted value> [value]: a repo whose rule file holds the text, run
atcase() { R="$TMP/$1"; new_repo "$R"; printf "$2" "${3:-$SW}" > "$R/docs/extra-nick.md"; seal "$R"; run "$R"; }
atcase at-fence-backtick 'intro\n```swift\n%s\n```\n'; exit_is "at-fenced-backtick: an @ line in a closed backtick fence passes" 0
atcase at-fence-tilde 'intro\n~~~swift\n%s\n~~~\n'; exit_is "at-fenced-tilde: an @ line in a closed tilde fence passes" 0
atcase at-fence-indented 'intro\n   ```swift\n%s\n   ```\n'; exit_is "at-fenced-indented: a fence indented by three spaces holds" 0
atcase at-unfenced 'intro\n%s\n'; exit_is "at-unfenced-exit3" 3
err_has "at-unfenced-exit3: names the rule and the line" "at-line at line 2"
atcase at-indented 'intro\n  %s\n'; exit_is "at-unfenced-indented-exit3" 3
err_has "at-unfenced-indented-exit3: names the rule and the line" "at-line at line 2"
atcase at-unclosed 'intro\n```swift\n%s\n'; exit_is "at-unclosed-fence-exit3" 3
err_has "at-unclosed-fence-exit3: names the rule and the line" "at-line at line 3"
atcase at-short-close 'intro\n````swift\n```\n%s\n'; exit_is "at-fence-closed-by-a-shorter-run-exit3" 3
err_has "at-fence-closed-by-a-shorter-run-exit3: names the rule and the line" "at-line at line 4"
atcase at-after-fence 'intro\n```\ncode\n```\n%s\n'; exit_is "at-after-a-closed-fence-exit3" 3
err_has "at-after-a-closed-fence-exit3: names the rule and the line" "at-line at line 5"
atcase at-fence-ctrl 'a\n```\nx%sy\n```\n' "$(printf '\001')"; exit_is "fenced-control-char-exit3" 3
err_has "fenced-control-char-exit3: names the rule and the line" "control-char at line 3"
atcase at-fence-invis 'a\n```\nx%sy\n```\n' "$(printf '\342\200\213')"; exit_is "fenced-invisible-char-exit3" 3
err_has "fenced-invisible-char-exit3: names the rule and the line" "invisible-char at line 3"
atcase at-fence-secret 'a\n```\n%s\n```\n' "$TOK"; exit_is "fenced-secret-exit3" 3
if grep -q '^.*secret-.* at line 3' "$ERR"; then ok "fenced-secret-exit3: names a secret rule and the line"; else bad "fenced-secret-exit3: stderr: $(head -c 300 "$ERR")"; fi
FA_ENG="$(sed -n '/^function fenceAfter/,/^}/p' "$ROOT/templates/pr-body-splice.cjs")"
FA_TXT="$(sed -n '/^function fenceAfter/,/^}/p' "$ROOT/scripts/lib/agent-context-text.cjs")"
if [ -n "$FA_ENG" ] && [ "$FA_ENG" = "$FA_TXT" ]; then ok "fence-rule-parity: fenceAfter of the screen is the engine's, byte for byte"; else bad "fence-rule-parity: the two fenceAfter differ"; fi

# ---- #412: frontmatter on a listed file is refused once, with a hint; a lane file stays accepted ----------
R="$TMP/ctxfm"; new_repo "$R"; mkdir -p "$R/docs"
printf -- '---\npaths: ["**/*.swift"]\n---\nSwift rules.\n' > "$R/docs/swift.md"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/swift.md"]}}'; seal "$R"
run "$R"; exit_is "ctx-frontmatter-exit2" 2
if [ "$(grep -c 'frontmatter-on-context-file' "$ERR")" = 1 ]; then ok "ctx-frontmatter-once"; else bad "ctx-frontmatter-once: $(head -c 400 "$ERR")"; fi
if grep -F 'lane' "$ERR" | grep -qF 'remove the frontmatter'; then ok "ctx-frontmatter-hint"; else bad "ctx-frontmatter-hint: $(head -c 400 "$ERR")"; fi
R="$TMP/ctxlane"; new_repo "$R"
printf -- '---\nlane: ios\npaths: ["**/*.swift"]\n---\nSwift rules.\n' > "$R/.claude/lgtmgate/sam.ios.md"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate"}'; seal "$R"
run "$R"; exit_is "ctx-lane-file-still-accepted" 0
jtrue "ctx-lane-file-in-payload" 'j.roles.Sam.lanes[0].name==="ios"'

rm -rf "$TMP"
RESULT=ok; [ "$FAIL" -gt 0 ] && RESULT=fail
echo "[test-agent-context] status=$RESULT passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
