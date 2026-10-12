#!/usr/bin/env bash
# Self-test of scripts/runtime/agent-context.cjs (#264): per-role specifics assembled from the base ref of a
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
AC="$ROOT/scripts/runtime/agent-context.cjs"
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
run() { local d=$1; shift; LASTD=$d; (cd "$d" && node "$AC" --root "$d" "$@") >"$OUT" 2>"$ERR"; rc=$?; }
# jx <expr>: evaluates a JS expression over the parsed stdout (j)
jx() {
  node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(new Function("j","return ("+process.argv[2]+")")(j)))' "$OUT" "$1"
}
# jtrue <label> <expr>: ok when the expression is true
jtrue() { if [ "$(jx "$2")" = "true" ]; then ok "$1"; else bad "$1: [$2] -> $(jx "$2" 2>&1 | head -c 200)"; fi; }
# atrue <label> <expr>: ok when the expression is true over a, the in-process assemble() result of the last run repo
# (the per-file list stays in the process, so it is read here and never on stdout); process.argv[4] is the stdout file
atrue() {
  local v
  v=$(node -e 'const ac=require(process.argv[1]);const a=ac.assemble({root:process.argv[2],ref:"origin/main",local:require("path").join(process.argv[2],".claude","pipeline.config.local.json")});process.stdout.write(String(new Function("a",   "return ("+process.argv[3]+")")(a)))' "$AC" "$LASTD" "$2" "$OUT" 2>&1)
  if [ "$v" = "true" ]; then ok "$1"; else bad "$1: [$2] -> $(printf '%s' "$v" | head -c 200)"; fi
}
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
atrue "US-C4: subject-not-lane: nick.testing.md (no frontmatter) is a subject, never a lane" 'a.roles.Nick.text.includes("NICK-TESTING-MARK")&&a.roles.Nick.lanes.length===0&&a.files.some(f=>f.path.endsWith("nick.testing.md")&&f.roles.includes("Nick"))'
jtrue "role-without-source-absent: Theo has no block" '!("Theo" in j.roles)'
jtrue "frontmatter-strip: Morgan keeps its base body, the lane (frontmatter stripped) is kept apart" '(()=>{const m=j.roles.Morgan;const l=m.lanes[0];return m.text.includes("MORGAN-MARK")&&!m.text.includes("MORGAN-REVIEW-MARK")&&!m.text.includes("lane:")&&m.lanes.length===1&&l.name==="review"&&l.persona==="reviewer"&&l.hint==="review lane"&&l.text.includes("MORGAN-REVIEW-MARK")&&!l.text.includes("persona")&&l.files.length===1&&l.files[0].endsWith("morgan.review.md")})()'
atrue "empty-stub-ignored: comment-only mia.md warns, exit 0, no Mia block" '!("Mia" in a.roles)&&a.warnings.some(w=>w.kind==="empty-ignored"&&w.path.endsWith("mia.md"))&&a.files.some(f=>f.path.endsWith("mia.md")&&f.empty===true)'

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

# ---- --sha (#520) -----------------------------------------------------------------------------
R="$TMP/sha"; new_repo "$R"; seal "$R"
SHA="$(git -C "$R" rev-parse HEAD)"
run "$R" --ref origin/main; cp "$OUT" "$TMP/by-ref"
run "$R" --sha "$SHA"
exit_is "sha-valid: exit 0" 0
jtrue "sha-valid: ref is the sha and refSha is the sha" "j.ref===\"$SHA\"&&j.refSha===\"$SHA\""
if node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const b=JSON.parse(require("fs").readFileSync(process.argv[2],"utf8"));delete a.ref;delete b.ref;process.exit(JSON.stringify(a)===JSON.stringify(b)?0:1)' "$OUT" "$TMP/by-ref"; then ok "sha-valid: same specifics and digests as --ref at that commit"; else bad "sha-valid: payload differs from --ref"; fi
run "$R" --sha 0000000000000000000000000000000000000001
exit_is "sha-unknown: refused, exit 2" 2
run "$R" --sha "$(printf '%s' "$SHA" | tr 'a-f' 'A-F')"
exit_is "sha-uppercase: refused, exit 2" 2
run "$R" --sha "$SHA" --ref origin/main
exit_is "sha-with-ref: exclusive, exit 2" 2
run "$R" --sha 'HEAD'
exit_is "sha-name: a name is not a sha, exit 2" 2

# ---- switch off -------------------------------------------------------------------------------
R="$TMP/off"; new_repo "$R"; setcfg "$R" '{"baseBranch":"main"}'; seal "$R"
run "$R"
exit_is "no-switch-empty-payload: exit 0" 0
jtrue "no-switch-empty-payload: empty payload" 'j.shared===null&&Object.keys(j.roles).length===0&&!("files" in j)&&j.warnings.length===0'

# ---- agentContext lists, dedup ----------------------------------------------------------------
R="$TMP/star"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"],"Nick":["docs/extra-nick.md"]}}'; seal "$R"
run "$R"
jtrue "agentcontext-star-and-role: * goes once in shared, the role list only its role" 'j.shared.text.split("ALL-EXTRA-MARK").length===2&&Object.values(j.roles).every(r=>!r.text.includes("ALL-EXTRA-MARK"))&&j.roles.Nick.text.includes("NICK-EXTRA-MARK")&&!j.roles.Sam.text.includes("NICK-EXTRA-MARK")&&!("Mia" in j.roles)&&!("Theo" in j.roles)'
R="$TMP/dedup"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-nick.md"],"Nick":["docs/extra-nick.md",".claude/lgtmgate/shared.md",".claude/lgtmgate/nick.md"]}}'; seal "$R"
run "$R"
jtrue "dedup-first-wins: a path never repeats, shared.md then the star file in shared, nothing of them in Nick" '(()=>{const t=j.roles.Nick.text,sh=j.shared.text;return t.split("NICK-MARK").length===2&&!t.includes("NICK-EXTRA-MARK")&&!t.includes("SHARED-MARK")&&sh.split("SHARED-MARK").length===2&&sh.split("NICK-EXTRA-MARK").length===2&&sh.indexOf("SHARED-MARK")<sh.indexOf("NICK-EXTRA-MARK")})()'

# ---- #447: agentContext["*"] files travel once, inside shared (after shared.md) ---------------------
# star_repo <dir> <json config>: a repo whose docs/extra-all.md is the mark line padded to 5000 bytes
star_repo() {
  new_repo "$1"
  node -e 'let s="ALL-EXTRA-MARK extra file for every role.\n";while(s.length<5000)s+="x".repeat(59)+"\n";process.stdout.write(s.slice(0,5000))' > "$1/docs/extra-all.md"
  setcfg "$1" "$2"; seal "$1"
}
STARCFG='{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"],"Nick":["docs/extra-nick.md"]}}'
R="$TMP/star-pay"; star_repo "$R" "$STARCFG"
run "$R"
SB=$(wc -c < "$OUT" | tr -d ' ')
if [ "$rc" = 0 ] && [ "$(wc -c < "$R/docs/extra-all.md" | tr -d ' ')" = 5000 ] && [ "$(grep -o 'ALL-EXTRA-MARK' "$OUT" | wc -l | tr -d ' ')" = 1 ] && [ "$SB" -lt 8000 ]; then ok "star-payload-once: stdout $SB bytes (27126 before), ALL-EXTRA-MARK once"; else bad "star-payload-once: exit $rc, stdout $SB bytes"; fi
STAR_OUT="$TMP/star-payload.json"; cp "$OUT" "$STAR_OUT"
jtrue "star-shared-after-shared-md: shared.md first, then the star file, no role text holds it" '(()=>{const t=j.shared.text;return t.indexOf("SHARED-MARK")>=0&&t.indexOf("SHARED-MARK")<t.indexOf("ALL-EXTRA-MARK")&&!("Mia" in j.roles)&&!("Theo" in j.roles)&&Object.values(j.roles).every(r=>!r.text.includes("ALL-EXTRA-MARK"))})()'
# independent recomputation of every digest present
DIGS=$(node -e '
  const c=require("crypto"),j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))
  const cj=(v)=>Array.isArray(v)?"["+v.map(cj).join(",")+"]":v&&typeof v==="object"?"{"+Object.keys(v).filter(k=>v[k]!==undefined).sort().map(k=>JSON.stringify(k)+":"+cj(v[k])).join(",")+"}":JSON.stringify(v)
  const h=(k,b)=>c.createHash("sha256").update(cj({lanes:b.lanes,refSha:j.refSha,role:k,text:b.text})).digest("hex")
  const bad=[["shared",j.shared],...Object.entries(j.roles)].filter(([k,b])=>h(k,b)!==b.digest).map(([k])=>k)
  process.stdout.write(bad.join(",")+"|"+Object.keys(j.roles).length)
' "$STAR_OUT")
if [ "${DIGS%%|*}" = "" ] && [ -n "$(jx 'j.shared.digest')" ]; then ok "star-digest-shared: sha256 of {lanes,refSha,role,text} matches for shared"; else bad "star-digest-shared: mismatch [$DIGS]"; fi
if [ "${DIGS%%|*}" = "" ] && [ "${DIGS##*|}" -ge 1 ]; then ok "star-digest-roles: every role block present recomputes (${DIGS##*|} roles)"; else bad "star-digest-roles: mismatch [$DIGS]"; fi
# engine check: one byte changed in shared.text is refused
node -e '
  const fs=require("fs")
  const f=new Function(process.argv[1]+"\n"+process.argv[2]+"\nreturn { sha256Hex, specificsDigest, specificsProblem }")()
  const ps=JSON.parse(fs.readFileSync(process.argv[3],"utf8"))
  const untouched=f.specificsProblem(true,ps,f.sha256Hex)===null
  const bad=JSON.parse(JSON.stringify(ps)); bad.shared.text=bad.shared.text.slice(0,-1)+"X"
  const refused=String(f.specificsProblem(true,bad,f.sha256Hex)).startsWith("digest mismatch for shared")
  bad.shared.digest=f.specificsDigest(f.sha256Hex,bad.refSha,"shared",bad.shared.text,[])
  const rolesStill=f.specificsProblem(true,bad,f.sha256Hex)===null
  process.exit(untouched&&refused&&rolesStill?0:1)
' "$SHA_BLK" "$PS_BLK" "$STAR_OUT" 2>"$TMP/st.err" && ok "star-tamper: one byte in shared.text is refused (digest mismatch for shared), the untouched payload passes" || bad "star-tamper: $(head -c 300 "$TMP/st.err")"
# content screen on the moved files
SWA='@Environment(\.horizontalSizeClass) private var horizontalSizeClass'
R="$TMP/star-at"; new_repo "$R"; printf 'intro\n%s\n' "$SWA" > "$R/docs/extra-all.md"
setcfg "$R" "$STARCFG"; seal "$R"; run "$R"
exit_is "star-screen-at-line: exit 3" 3
err_has "star-screen-at-line: located" "at-line at line 2"
STOK="gh""p_$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"
R="$TMP/star-secret"; new_repo "$R"; printf 'a token: %s\n' "$STOK" > "$R/docs/extra-all.md"
setcfg "$R" "$STARCFG"; seal "$R"; run "$R"
exit_is "star-screen-secret: exit 3" 3
if grep -qF -- "$STOK" "$ERR"; then bad "star-screen-secret-not-printed: the value is printed"; else ok "star-screen-secret-not-printed: the value is never printed"; fi
R="$TMP/star-fm"; new_repo "$R"; printf -- '---\npaths: ["**/*.swift"]\n---\nSwift rules.\n' > "$R/docs/extra-all.md"
setcfg "$R" "$STARCFG"; seal "$R"; run "$R"
exit_is "star-screen-frontmatter: exit 2" 2
err_has "star-screen-frontmatter: names the rule" "frontmatter-on-context-file"
# size warning on the moved files
R="$TMP/star-over"; star_repo "$R" "$STARCFG"; run "$R"
exit_is "star-oversize-exit0" 0
jtrue "star-oversize-warning: shared-oversize, recommended 2048, bytes equal shared.bytes" 'j.warnings.some(w=>w.kind==="shared-oversize"&&w.recommended===2048&&w.bytes===j.shared.bytes)&&j.shared.bytes>2048'
# edges
R="$TMP/star-only"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","agentContext":{"*":["docs/extra-all.md"]}}'; seal "$R"; run "$R"
jtrue "star-edge-only-star: no projectSpecifics, the star file is in shared, no role block" 'j.shared!==null&&j.shared.text.includes("ALL-EXTRA-MARK")&&Object.keys(j.roles).length===0'
R="$TMP/star-dup"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"],"Nick":["docs/extra-all.md"]}}'; seal "$R"; run "$R"
jtrue "star-edge-role-list-dup: a path in * and in a role list appears once, in shared" 'j.shared.text.split("ALL-EXTRA-MARK").length===2&&Object.values(j.roles).every(r=>!r.text.includes("ALL-EXTRA-MARK"))'
R="$TMP/star-owned"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":[".claude/lgtmgate/nick.md"]}}'; seal "$R"; run "$R"
jtrue "star-edge-owned-file: a folder file listed in * stays with its role" 'j.roles.Nick.text.includes("NICK-MARK")&&!j.shared.text.includes("NICK-MARK")&&!j.roles.Sam.text.includes("NICK-MARK")'
R="$TMP/star-comment"; new_repo "$R"; printf '<!-- nothing yet -->\n' > "$R/docs/extra-all.md"
setcfg "$R" "$STARCFG"; seal "$R"; run "$R"
jtrue "star-edge-comment-only: a comment-only star file leaves shared and warns once" 'j.shared!==null&&!j.shared.text.includes("ALL-EXTRA-MARK")&&j.warnings.filter(w=>w.kind==="empty-ignored"&&w.path==="docs/extra-all.md").length===1'

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
# the accept leaves no untracked file (the local file is kept out of git through info/exclude)
UNTRACKED=$(git -C "$R" status --porcelain | wc -l | tr -d ' ')
if [ "$UNTRACKED" = 0 ]; then ok "accept-oversize-untracked: the consumer worktree is clean after an accept"; else bad "accept-oversize-untracked: $(git -C "$R" status --porcelain | head -c 200)"; fi
R5="$TMP/acc5"; new_repo "$R5"; padfile "$R5/docs/extra-nick.md" 7000; seal "$R5"
git -C "$R5" worktree add -q "$TMP/acc5-wt" -b side
run "$TMP/acc5-wt" --accept-oversize Nick
WTS=$(git -C "$TMP/acc5-wt" status --porcelain | wc -l | tr -d ' ')
if [ "$rc" = 0 ] && [ "$WTS" = 0 ]; then ok "accept-oversize-untracked-worktree: a linked worktree is clean after an accept"; else bad "accept-oversize-untracked-worktree: exit $rc $(git -C "$TMP/acc5-wt" status --porcelain | head -c 200)"; fi
# a second accept does not duplicate the exclude line
run "$R" --accept-oversize Nick
EXCL="$(git -C "$R" rev-parse --path-format=absolute --git-path info/exclude)"
if [ "$rc" = 0 ] && [ "$(grep -cxF '/.claude/pipeline.config.local.json' "$EXCL")" = 1 ]; then ok "accept-oversize-exclude-once: no duplicate exclude line"; else bad "accept-oversize-exclude-once: rc=$rc count=$(grep -cxF '/.claude/pipeline.config.local.json' "$EXCL")"; fi
# a repo that already ignores the file gets no exclude line
R6="$TMP/acc6"; new_repo "$R6"; padfile "$R6/docs/extra-nick.md" 7000; printf '.claude/pipeline.config.local.json\n' > "$R6/.gitignore"; seal "$R6"
run "$R6" --accept-oversize Nick
EXCL6="$(git -C "$R6" rev-parse --path-format=absolute --git-path info/exclude)"
if [ "$rc" = 0 ] && ! grep -qF 'pipeline.config.local.json' "$EXCL6" && [ "$(git -C "$R6" status --porcelain | wc -l | tr -d ' ')" = 0 ]; then ok "accept-oversize-already-ignored: no exclude line added"; else bad "accept-oversize-already-ignored: rc=$rc excl=$(tr '\n' '~' < "$EXCL6") status=$(git -C "$R6" status --porcelain | tr '\n' '~')"; fi
# the total warning is informational and never asks
R7="$TMP/tot"; new_repo "$R7"; padfile "$R7/docs/extra-nick.md" 8300; seal "$R7"
run "$R7"
jtrue "total-oversize-informational: informational true, ask false" 'j.warnings.some(w=>w.kind==="total-oversize"&&w.informational===true&&w.ask===false)'

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
jtrue "wire-shape: stdout holds ref, refSha, shared, roles and warnings only: no per-file list, no display list of lanes" 'Object.keys(j).sort().join()==="ref,refSha,roles,shared,warnings"'
atrue "wire-equals-assembler: stdout is the in-process result minus the per-file list" '(()=>{const w=JSON.parse(require("fs").readFileSync(process.argv[4],"utf8"));const {files,...rest}=a;return JSON.stringify(w)===JSON.stringify(rest)})()'
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
const one = JSON.parse(JSON.stringify(ps)); one.roles.Nick.text = one.roles.Nick.text.slice(0, -1) + 'X'
out.rejectsOneByte = String(f.specificsProblem(true, one, f.sha256Hex)).startsWith('digest mismatch for Nick')
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
for k in accepts rejectsTamper rejectsOneByte found blockIos blockNone blockSkipsMissing resolve roundTrip pathHits sentence theoSection; do
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
FA_ENG="$(sed -n '/^function fenceAfter/,/^}/p' "$ROOT/scripts/runtime/pr-body-splice.cjs")"
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

# ---- #415: a file the roles never receive warns on stderr, once, with its remedy; exit code and payload stay ------
LG=.claude/lgtmgate
# has_warn <path> <rule>: exit 0, exactly one stderr line `agent-context: warning: <path>: <rule>. <remedy>`, and the same entry in the JSON warnings
has_warn() {
  [ "$rc" = 0 ] && [ "$(grep -c "^agent-context: warning: $1: $2\. " "$ERR")" = 1 ] && [ "$(jx "j.warnings.filter(w=>w.kind===\"$2\"&&w.path===\"$1\").length")" = 1 ]
}
R="$TMP/w1"; new_repo "$R"; seal "$R"; printf 'THEO-LOCAL-MARK\n' > "$R/$LG/theo.md"
run "$R"
if has_warn "$LG/theo.md" not-on-base-ref; then ok "warn-not-on-base-ref-untracked: an untracked theo.md warns"; else bad "warn-not-on-base-ref-untracked: exit $rc $(head -c 300 "$ERR")"; fi
R="$TMP/w2"; new_repo "$R"; seal "$R"; printf 'THEO-LOCAL-MARK\n' > "$R/$LG/theo.md"; git_add_all "$R"; git -C "$R" commit -q -m local
run "$R"
if has_warn "$LG/theo.md" not-on-base-ref; then ok "warn-not-on-base-ref-unpushed: a theo.md committed but not on the base ref warns"; else bad "warn-not-on-base-ref-unpushed: exit $rc $(head -c 300 "$ERR")"; fi
R="$TMP/w3"; new_repo "$R"; for f in reviewer.md Theo.md sam.txt README.md; do printf 'IGNORED\n' > "$R/$LG/$f"; done; seal "$R"
run "$R"
if has_warn "$LG/reviewer.md" no-role-match && has_warn "$LG/Theo.md" no-role-match && has_warn "$LG/sam.txt" no-role-match && has_warn "$LG/README.md" no-role-match; then ok "warn-no-role-match: reviewer.md, Theo.md, sam.txt and README.md warn"; else bad "warn-no-role-match: exit $rc $(head -c 400 "$ERR")"; fi
R="$TMP/w4"; new_repo "$R"; printf -- '---\npaths: ["a/**"]\n---\nSHARED-MARK with frontmatter.\n' > "$R/$LG/shared.md"; seal "$R"
run "$R"
if has_warn "$LG/shared.md" frontmatter-on-shared-file; then ok "warn-frontmatter-on-shared-file: the keys are discarded and the file warns"; else bad "warn-frontmatter-on-shared-file: exit $rc $(head -c 300 "$ERR")"; fi
R="$TMP/w5"; lane_repo "$R"; printf 'NICK-IOS-MARK without frontmatter.\n' > "$R/$LG/nick.ios.md"; seal "$R"
run "$R"
if has_warn "$LG/nick.ios.md" lane-captured-from-other-role && ! grep -qF "sam.ios.md" "$ERR"; then ok "warn-lane-captured-from-other-role: nick.ios.md warns, the file that declares the lane does not"; else bad "warn-lane-captured-from-other-role: exit $rc $(head -c 300 "$ERR")"; fi
R="$TMP/w6"; new_repo "$R"; seal "$R"
run "$R"
if has_warn "$LG/mia.md" empty-ignored; then ok "warn-empty-ignored: the comment-only mia.md warns on stderr, not only in the JSON"; else bad "warn-empty-ignored: exit $rc $(head -c 300 "$ERR")"; fi
R="$TMP/w7"; new_repo "$R"; printf '<!-- to be completed -->\n' > "$R/docs/extra-all.md"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["docs/extra-all.md"]}}'; seal "$R"
run "$R"
if has_warn "docs/extra-all.md" empty-ignored; then ok "warn-once-per-file: a comment-only file read by five roles warns once"; else bad "warn-once-per-file: exit $rc $(head -c 300 "$ERR")"; fi
R="$TMP/w8"; new_repo "$R"; rm "$R/$LG/mia.md"; seal "$R"
run "$R"
if [ "$rc" = 0 ] && [ ! -s "$ERR" ]; then ok "warn-clean-folder-silent: a folder of committed, named, non-empty files prints nothing on stderr"; else bad "warn-clean-folder-silent: exit $rc $(head -c 300 "$ERR")"; fi
jx 'JSON.stringify([j.shared,j.roles])' > "$TMP/w8.before"
printf 'LOCAL\n' > "$R/$LG/theo.md"; printf 'IGNORED\n' > "$R/$LG/reviewer.md"
run "$R"
jx 'JSON.stringify([j.shared,j.roles])' > "$TMP/w8.after"
if [ "$rc" = 0 ] && [ -s "$ERR" ] && [ -s "$TMP/w8.before" ] && cmp -s "$TMP/w8.before" "$TMP/w8.after"; then ok "warn-payload-unchanged: warnings leave the exit code and every role digest as they were"; else bad "warn-payload-unchanged: exit $rc"; fi

# ---- #416: every refusal names its remedy on one hint line, once per run, after the refusal lines ----------------------
# hint_is <label> <rule>: exactly one stderr line `agent-context: hint: <rule>: <remedy>; see docs/consumer-reference.md#<rule>`
hint_is() {
  if [ "$(grep -cF -- "agent-context: hint: $2: " "$ERR")" = 1 ] && grep -F -- "agent-context: hint: $2: " "$ERR" | grep -qF -- "; see docs/consumer-reference.md#$2"; then ok "$1"; else bad "$1: $(head -c 400 "$ERR")"; fi
}
R="$TMP/h1"; new_repo "$R"; printf 'plain\n' > "$R/docs/data.txt"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/data.txt"]}}'; seal "$R"
run "$R"; exit_is "hint-path-rule: exit 3 as before" 3
err_has "hint-path-rule: the refusal line is unchanged" "agent-context: docs/data.txt: not-md at line 0"
hint_is "hint-path-rule: not-md names a remedy and its reference row" not-md
R="$TMP/h2"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"*":["a.md","b.md","c.md","d.md","e.md","f.md","g.md","h.md","i.md"]}}'; seal "$R"
run "$R"; exit_is "hint-cap-rule: exit 3 as before" 3
err_has "hint-cap-rule: the refusal line is unchanged" "agent-context: agentContext.*: too-many-files at line 0"
hint_is "hint-cap-rule: too-many-files names the limit of 8 and its reference row" too-many-files
R="$TMP/h3"; new_repo "$R"; printf 'text\n</project_specifics>\n' > "$R/docs/extra-nick.md"; seal "$R"
run "$R"; exit_is "hint-screen-rule: exit 3 as before" 3
err_has "hint-screen-rule: the refusal line is unchanged" "agent-context: docs/extra-nick.md: machine-literal at line 2"
hint_is "hint-screen-rule: machine-literal names a remedy and its reference row" machine-literal
R="$TMP/h4"; new_repo "$R"; printf -- '---\nbogus: x\n---\nbody\n' > "$R/.claude/lgtmgate/nick.md"; seal "$R"
run "$R"; exit_is "hint-frontmatter-rule: exit 2 as before" 2
err_has "hint-frontmatter-rule: the refusal line is unchanged" "agent-context: .claude/lgtmgate/nick.md: frontmatter-unknown-key at line 2"
hint_is "hint-frontmatter-rule: frontmatter-unknown-key names the allowed keys and its reference row" frontmatter-unknown-key
R="$TMP/h5"; new_repo "$R"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Bob":["docs/extra-all.md"]}}'; seal "$R"
run "$R"; exit_is "hint-config-rule: exit 2 as before" 2
err_has "hint-config-rule: the refusal line is unchanged" 'agent-context: agentContext: unknown role "Bob"'
hint_is "hint-config-rule: unknown role names the valid roles and its reference row" "unknown role"
R="$TMP/h6"; new_repo "$R"; printf 'one\n' > "$R/docs/a.txt"; printf 'two\n' > "$R/docs/b.txt"
setcfg "$R" '{"baseBranch":"main","projectSpecifics":".claude/lgtmgate","agentContext":{"Nick":["docs/a.txt","docs/b.txt"]}}'; seal "$R"
run "$R"; exit_is "hint-once: two refusals of one rule, exit 3" 3
if [ "$(grep -c 'not-md at line 0' "$ERR")" = 2 ]; then hint_is "hint-once: two refusal lines, one hint line" not-md; else bad "hint-once: $(head -c 400 "$ERR")"; fi
R="$TMP/h7"; new_repo "$R"; printf 'a token: %s\n' "$TOK" > "$R/docs/extra-nick.md"; seal "$R"
run "$R"
if grep -qF -- "$TOK" "$ERR"; then bad "hint-secret-star: the value is printed"; else hint_is "hint-secret-star: the hint names secret-* and never the value" "secret-*"; fi
R="$TMP/h8"; new_repo "$R"; seal "$R"
run "$R"
if [ "$rc" = 0 ] && grep -qF 'warning:' "$ERR" && ! grep -qF 'agent-context: hint:' "$ERR"; then ok "hint-clean-folder-silent: a run that only warns prints no hint line"; else bad "hint-clean-folder-silent: exit $rc $(head -c 300 "$ERR")"; fi
MISSING_ROWS=$(node -e 'const {HINTED_RULES}=require(process.argv[1]);const t=require("fs").readFileSync(process.argv[2],"utf8");process.stdout.write(HINTED_RULES.filter((r)=>!t.includes("\n| `"+r+"` |")).join(" "))' "$ROOT/scripts/lib/agent-context-hints.cjs" "$ROOT/docs/consumer-reference.md")
if [ -z "$MISSING_ROWS" ]; then ok "hint-rows: every hinted rule has a row in docs/consumer-reference.md"; else bad "hint-rows: no row for [$MISSING_ROWS]"; fi

rm -rf "$TMP"
RESULT=ok; [ "$FAIL" -gt 0 ] && RESULT=fail
echo "[test-agent-context] status=$RESULT passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
