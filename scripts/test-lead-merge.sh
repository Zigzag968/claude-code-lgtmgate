#!/usr/bin/env bash
# Regression test for scripts/lead-merge.sh (#74). Offline: a fake `gh` on PATH logs every call
# to a file; the git side is a throwaway repo + bare origin under $TMPDIR (the real worktree is
# never touched). Cases: open box, missing markers, happy path order, no auto-merge flag,
# --merge used, CI failure, idempotent re-run, main moved (own bump + unrelated commit) after the
# branch was cut, conflicting main, remote head ahead of local, stale/no-checks polling, base without
# required checks (#156), review freshness (#157: review on the head, commit after the review, no marker, bare marker,
# own commits on a re-run, head moved between the check and the sync, --tick-from-review on a stale review),
# prerelease versions (1.0.0-beta.N: next merge bumps the counter, a hand bump above main is kept, non-semver refused).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/lead-merge.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/lead-merge-test.XXXXXX")"
PASS=0; FAIL=0; RUN_FLAGS=""
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 0. lib-level cases (#202), before any lead-merge run ---------------------------------------------------------
# The gate reads fences and markers byte-wise (LC_ALL=C awk) while the engine (templates/pr-body-splice.cjs) trims Unicode
# whitespace. It does not copy every Unicode subtlety: it REFUSES (rc 3, "ambiguous acceptance block", no body content quoted) any
# body where a line of interest is ambiguous, and it is never more permissive than the engine. ACC_LIB_UNDER_TEST runs these
# cases against another copy of the lib (mutation checks), ACC_LIB_ONLY=1 stops after this section.
ACC_LIB="${ACC_LIB_UNDER_TEST:-$ROOT/scripts/lib/acceptance-check.sh}"
# shellcheck source=lib/acceptance-check.sh
. "$ACC_LIB"
S0='<!-- acceptance:start -->'; E0='<!-- acceptance:end -->'
NB=$'\xc2\xa0'; BOM=$'\xef\xbb\xbf'; U2003=$'\xe2\x80\x83'; U2028=$'\xe2\x80\xa8'; U3000=$'\xe3\x80\x80'; FF=$'\f'; VT=$'\v'
AMB='ambiguous acceptance block'
accb() { local IFS=$'\n'; printf '%s' "$*"; } # the arguments as lines
acc() { # name want-rc stderr-substring (may be empty) body
  local name="$1" want="$2" sub="$3" body="$4" err rc
  err="$(printf '%s\n' "$body" | acceptance_check_body 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$sub" ] || case "$err" in *"$sub"*) true ;; *) false ;; esac; }; then
    ok "fenced-example lib: $name"
  else
    bad "fenced-example lib: $name (rc=$rc want $want, stderr: $err)"
  fi
}
REAL_OK0="$(accb "$S0" '- [x] <!-- ac:1 --> a' "$E0")"
REAL_OPEN0="$(accb "$S0" '- [x] <!-- ac:1 --> a' '- [ ] <!-- ac:2 --> open' "$E0")"
# B1: a closing fence followed by a blank the engine trims (trim()) but the shell does not
for w in "$FF" "$VT" "$NB" "$BOM" "$U2003" "$U2028" "$U3000"; do
  case "$w" in "$FF") wn="form feed" ;; "$VT") wn="vertical tab" ;; "$NB") wn="U+00A0" ;; "$BOM") wn="U+FEFF" ;; "$U2003") wn="U+2003" ;; "$U2028") wn="U+2028" ;; *) wn="U+3000" ;; esac
  acc "B1 closing backtick fence followed by $wn is refused, not read as unclosed" 3 "$AMB" "$(accb "$S0" '- [x] a' "$E0" '```' x '```'"$w" "$S0" '- [x] a' '- [ ] open' "$E0")"
done
acc "B1 closing tilde fence followed by U+00A0 is refused" 3 "$AMB" "$(accb "$S0" '- [x] a' "$E0" '~~~' x '~~~'"$NB" "$S0" '- [x] a' '- [ ] open' "$E0")"
# B2: an opening fence indented by a blank the engine counts (trimStart()) but awk does not
acc "B2 opening fence indented by U+00A0, empty fenced pair after an open block: refused" 3 "$AMB" "$(accb "$S0" '- [x] a' '- [ ] open' "$E0" "$NB"'```' "$S0" "$E0" '```')"
acc "B2 opening fence indented by U+3000: refused" 3 "$AMB" "$(accb "$S0" '- [x] a' '- [ ] open' "$E0" "$U3000"'```' "$S0" "$E0" '```')"
acc "B2 opening fence preceded by a BOM: refused" 3 "$AMB" "$(accb "$BOM"'```' "$S0" '- [x] a' "$E0" '```')"
acc "a tab-indented fence is plain ASCII: it hides the open pair after the ticked one (allowed)" 0 "" "$(accb "$REAL_OK0" $'\t''```' "$S0" '- [ ] example' "$E0" '```')"
# B3: marker look-alikes outside a fence
acc "B3 <!--acceptance:start--> after an open block is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" '<!--acceptance:start-->' "$E0")"
acc "B3 two spaces inside the start marker is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" '<!--  acceptance:start -->' "$E0")"
acc "B3 end marker without the space before --> is refused" 3 "$AMB" "$(accb "$S0" '- [ ] open' '<!-- acceptance:end-->')"
acc "B3 a tab inside the start marker is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" '<!--'$'\t''acceptance:start -->' "$E0")"
acc "B3 start marker followed by text is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" "$S0 x" "$E0")"
acc "B3 start marker followed by a form feed is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" "$S0$FF" "$E0")"
acc "B3 start marker followed by a vertical tab is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" "$S0$VT" "$E0")"
acc "B3 end marker followed by two carriage returns is refused" 3 "$AMB" "$(accb "$S0" '- [ ] open' "$E0"$'\r\r')"
acc "B3 start marker with a no-break space inside is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" '<!--'"$NB"'acceptance:start -->' "$E0")"
acc "B3 the refusal quotes no body content" 3 "$AMB" "$(accb "$REAL_OPEN0" '<!--acceptance:start--> ZZTOKENZZ' "$E0")"
err="$(printf '%s\n' "$(accb "$REAL_OPEN0" '<!--acceptance:start--> ZZTOKENZZ' "$E0")" | acceptance_check_body 2>&1 >/dev/null)"
case "$err" in *ZZTOKENZZ*) bad "fenced-example lib: the refusal quotes body content: $err" ;; *) ok "fenced-example lib: the refusal message quotes no body content" ;; esac
# what stays accepted
acc "an indented marker is plain text, not a look-alike: the real block is read" 1 "unchecked" "$(accb "$REAL_OPEN0" '  <!-- acceptance:start -->')"
acc "exact markers with trailing spaces and tabs are read (open box -> rc 1)" 1 "unchecked" "$(accb "$S0 "$'\t' '- [ ] open' "$E0"$'\t ')"
acc "exact markers with CRLF line ends are read (ticked -> rc 0)" 0 "" "$(printf '%s\r\n' "$S0" '- [x] a' "$E0")"
acc "CRLF body with an open box -> rc 1" 1 "unchecked" "$(printf '%s\r\n' "$S0" '- [ ] a' "$E0")"
acc "accents and emoji in an ordinary body are not refused (ticked -> rc 0)" 0 "" "$(accb 'Résumé : le correctif est livré ✅ 🚀' "$S0" '- [x] <!-- ac:1 --> vérifié, ça marche — ✅' "$E0" 'fin, à demain')"
acc "accents and emoji in an ordinary body, open box -> rc 1" 1 "unchecked" "$(accb 'Résumé ✅' "$S0" '- [ ] <!-- ac:1 --> vérifié 🚀' "$E0")"
acc "look-alikes inside a fence are not refused" 0 "" "$(accb '```' '<!--acceptance:start-->' '<!--  acceptance:end -->' '```' "$REAL_OK0")"
acc "an exact pair and a look-alike pair inside a fence, then a ticked block: allowed" 0 "" "$(accb '~~~' "$S0" '<!--acceptance:start-->' '- [ ] example' "$E0" '~~~' "$REAL_OK0")"
# R6 / I2: several exact pairs outside fences: any open box in any of them refuses (union), fenced pairs are ignored
acc "R6 two exact pairs, first open, last empty -> rc 1" 1 "unchecked" "$(accb "$S0" '- [ ] open' "$E0" "$S0" "$E0")"
acc "R6 two exact pairs, first open, last ticked -> rc 1" 1 "unchecked" "$(accb "$S0" '- [ ] open' "$E0" "$REAL_OK0")"
acc "three exact pairs, the middle one open -> rc 1" 1 "unchecked" "$(accb "$REAL_OK0" "$S0" '- [ ] open' "$E0" "$REAL_OK0")"
acc "three exact pairs, the last one open -> rc 1" 1 "unchecked" "$(accb "$REAL_OK0" "$REAL_OK0" "$REAL_OPEN0")"
acc "three exact pairs, all ticked -> rc 0" 0 "" "$(accb "$REAL_OK0" "$REAL_OK0" "$REAL_OK0")"
acc "an open pair inside a fence is ignored next to two ticked pairs -> rc 0" 0 "" "$(accb "$REAL_OK0" '```' "$S0" '- [ ] example' "$E0" '```' "$REAL_OK0")"
acc "two ends after one start: a box between the two ends is still read -> rc 1" 1 "unchecked" "$(accb "$S0" '- [x] a' "$E0" '- [ ] b' "$E0")"
# I1 / I4: behaviour of the base, kept
acc "I1 an empty block (no line between the markers) is accepted, as before #202" 0 "" "$(accb "$S0" "$E0")"
acc "I4 an unticked box inside a fence inside the block still refuses (fail-closed)" 1 "unchecked" "$(accb "$S0" '- [x] a' '```' '- [ ] an example box' '```' "$E0")"
# mutants of the fence rule (the cases below are the ones that kill them; see the mutation run in the PR notes)
acc "m2 a 4-backtick line closes a 3-backtick fence (closing at least as long)" 0 "" "$(accb '```' "$S0" '- [ ] ex' "$E0" '````' "$REAL_OK0")"
acc "m3 a tilde line does not close a backtick fence" 3 "" "$(accb '```' '~~~' "$REAL_OK0")"
acc "m6 a fence indented by 4 spaces is not a fence" 1 "unchecked" "$(accb '    ```' "$S0" '- [ ] open' "$E0")"
acc "m6 a fence indented by 3 spaces is a fence" 3 "" "$(accb '   ```' "$S0" '- [x] a' "$E0")"
acc "m7 a backtick in the info string of a backtick fence: not a fence" 1 "unchecked" "$(accb '```a`b' "$S0" '- [ ] open' "$E0")"
acc "m8 a closing fence followed by text does not close" 3 "" "$(accb '```' '``` trailing' "$REAL_OK0")"
acc "m12 the last end marker counts, not the first (box after the first end)" 1 "unchecked" "$(accb "$S0" '- [x] a' "$E0" '- [ ] b' "$E0")"
acc "m14 two backticks do not open a fence" 1 "unchecked" "$(accb '``' "$S0" '- [ ] open' "$E0")"
acc "m15 a backtick in the info string of a tilde fence still opens it" 3 "" "$(accb '~~~a`b' "$REAL_OK0")"

# generated parity (#202): a few hundred deterministic ASCII bodies (fixed seed; fences of varied length and indent, markers and look-alikes,
# open and ticked boxes, CRLF) read by the shell and by the engine. The shell may refuse more than the engine, never less: it must not
# return rc 0 when the engine finds no block or a block with an open box.
if command -v node >/dev/null 2>&1; then
  GEN="$BASE/gen"; mkdir -p "$GEN"
  cat > "$BASE/gen.cjs" <<'JS'
const fs = require("fs")
const dir = process.argv[2]
let a = 20261003
const rnd = () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296 }
const pick = (xs) => xs[Math.floor(rnd() * xs.length)]
const ws = () => pick(["", "", "", " ", "\t", "  "])
const fenceLine = () => " ".repeat(Math.floor(rnd() * 6)) + pick(["`", "`", "~"]).repeat(1 + Math.floor(rnd() * 5)) + pick(["", "", "", "js", "a`b", " x", " ", "\t"])
const marker = (s) => "<!-- acceptance:" + s + " -->" + ws()
const box = () => pick(["- [x] <!-- ac:1 --> a", "- [x] <!-- ac:2 --> b", "- [ ] <!-- ac:3 --> c"])
const filler = () => pick(["", "text", "## What this ships", "    ```", "\f```", "```\f", "``` x", "````", "~~~~", "<!--acceptance:start-->", "<!--  acceptance:end -->", "  <!-- acceptance:start -->", "<!-- acceptance:start --> x", "<!-- acceptance:end -->\f", "<!-- acceptance:start -->\v"])
const pair = () => { const out = [marker("start")]; for (let k = Math.floor(rnd() * 3); k > 0; k--) out.push(rnd() < 0.5 ? "- [x] <!-- ac:" + k + " --> a" : box()); out.push(marker("end")); return out }
const segment = () => {
  const r = rnd()
  if (r < 0.34) return pair()
  if (r < 0.62) return [fenceLine(), ...(rnd() < 0.7 ? pair() : [box()]), ...(rnd() < 0.8 ? [fenceLine()] : [])]
  if (r < 0.72) return [marker(pick(["start", "end"]))]
  if (r < 0.82) return [box()]
  return [filler(), ...(rnd() < 0.3 ? [fenceLine()] : [])]
}
for (let i = 0; i < 400; i++) {
  const lines = []
  for (let k = 1 + Math.floor(rnd() * 4); k > 0; k--) lines.push(...segment())
  fs.writeFileSync(dir + "/" + String(i).padStart(3, "0") + ".md", lines.join(rnd() < 0.1 ? "\r\n" : "\n") + "\n")
}
JS
  node "$BASE/gen.cjs" "$GEN"
  : > "$BASE/gen.rcs"
  for f in "$GEN"/*.md; do
    acceptance_check_body < "$f" > /dev/null 2>&1; grc=$?
    echo "$(basename "$f") $grc" >> "$BASE/gen.rcs"
  done
  cat > "$BASE/cmp.cjs" <<'JS'
const fs = require("fs")
const [root, dir, rcs] = process.argv.slice(2)
const src = fs.readFileSync(root + "/templates/pr-body-splice.cjs", "utf8")
const m = src.split("// --- prBodySplice:start ---")[1].split("\n").slice(1).join("\n").split("// --- prBodySplice:end ---")[0]
const { acceptanceSpan } = new Function(m + ";return { acceptanceSpan }")()
const openRe = /^[ \t\n\v\f\r]*-[ \t\n\v\f\r]*\[ \]/
let permissive = 0, closedOk = 0, openRefused = 0, noBlockRefused = 0, refusedAmbiguous = 0, badRc = 0
const first = []
for (const l of fs.readFileSync(rcs, "utf8").trim().split("\n")) {
  const [f, rcs0] = l.split(" ")
  const rc = Number(rcs0)
  const body = fs.readFileSync(dir + "/" + f, "utf8").replace(/\n+$/, "") + "\n"
  const sp = acceptanceSpan(body)
  let verdict = "none"
  if (sp) { const t = body.slice(sp.from, sp.to).split("\n"); t.shift(); t.pop(); verdict = t.some((x) => openRe.test(x)) ? "open" : "closed" }
  if (rc !== 0 && rc !== 1 && rc !== 3) badRc++
  if (rc === 0 && verdict !== "closed") { permissive++; if (first.length < 3) first.push(f + " engine=" + verdict) }
  else if (rc === 0) closedOk++
  else if (verdict === "open" && rc === 1) openRefused++
  else if (verdict === "none" && rc === 3) noBlockRefused++
  else refusedAmbiguous++
}
console.log("permissive=" + permissive + " badrc=" + badRc + " closed_ok=" + closedOk + " open_refused=" + openRefused + " noblock_refused=" + noBlockRefused + " stricter=" + refusedAmbiguous + " " + first.join(","))
JS
  res="$(node "$BASE/cmp.cjs" "$ROOT" "$GEN" "$BASE/gen.rcs" 2>&1)"
  n_gen="$(ls "$GEN" | wc -l | tr -d ' ')"
  case "$res" in
    *"permissive=0 badrc=0 "*)
      co="${res#*closed_ok=}"; co="${co%% *}"; orf="${res#*open_refused=}"; orf="${orf%% *}"
      if [ "$n_gen" -ge 300 ] && [ "$co" -ge 20 ] && [ "$orf" -ge 20 ]; then
        ok "fenced-example generated parity: $n_gen bodies, the shell is never more permissive than the engine ($res)"
      else
        bad "fenced-example generated parity is vacuous: $n_gen bodies ($res)"
      fi ;;
    *) bad "fenced-example generated parity: the shell is more permissive than the engine ($res)" ;;
  esac
else
  bad "fenced-example generated parity: node missing"
fi
if [ -n "${ACC_LIB_ONLY:-}" ]; then
  echo "[lead-merge test] lib cases only: passed=$PASS failed=$FAIL"
  [ "$FAIL" -eq 0 ]; exit
fi

mkdir -p "$BASE/bin"
cat > "$BASE/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr checks --help" ]; then
  [ "${FAKE_HAS_REQUIRED:-1}" -eq 1 ] && echo "      --required   Only show checks that are required"
  exit 0
fi
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefOid*)
        stale="$(cat "$FAKE_LOG.stale" 2>/dev/null || echo "${FAKE_STALE:-0}")"
        if [ "$stale" -gt 0 ]; then
          echo $((stale - 1)) > "$FAKE_LOG.stale"
          echo '{"headRefOid":"0000000","statusCheckRollup":[]}'
        else
          echo "{\"headRefOid\":\"$(git --git-dir="$FAKE_REMOTE" rev-parse "$FAKE_BRANCH")\",\"statusCheckRollup\":[{\"name\":\"ci\"}]}"
        fi ;;
      *headRefName*) echo "$FAKE_BRANCH" ;;
      *) cat "$FAKE_BODY" ;;
    esac ;;
  "pr update-branch") echo "fake gh: update-branch must not be called" >&2; exit 98 ;;
  "pr checks")
    case "$*" in
      *--json*) # no-required-checks mode (#156): the head's checks as JSON; FAKE_PENDING polls report a pending check first
        pend="$(cat "$FAKE_LOG.pending" 2>/dev/null || echo "${FAKE_PENDING:-0}")"
        if [ "$pend" -gt 0 ]; then
          echo $((pend - 1)) > "$FAKE_LOG.pending"
          echo '[{"name":"ci","bucket":"pending"}]'
        else
          json="${FAKE_CHECKS_JSON:-}"; [ -n "$json" ] || json='[{"name":"ci","bucket":"pass"}]' # a `}` inside ${..:-..} ends it early
          echo "$json"
        fi
        exit 0 ;;
    esac
    case "$* ${FAKE_PROTECTION:-classic}" in
      *--required*none404|*--required*none403) # a base without required checks never reports one (#156)
        echo "no required checks reported on the 'feat/x' branch"; exit 1 ;;
    esac
    noreq="$(cat "$FAKE_LOG.noreq" 2>/dev/null || echo "${FAKE_NOREQ:-0}")"
    if [ "$noreq" -gt 0 ]; then
      echo $((noreq - 1)) > "$FAKE_LOG.noreq"
      echo "no required checks reported on the 'feat/x' branch"; exit 1
    fi
    [ "${FAKE_CHECKS_RC:-0}" -eq 0 ] || exit "$FAKE_CHECKS_RC" ;;
  "pr merge") [ "${FAKE_MERGE_RC:-0}" -eq 0 ] || exit "$FAKE_MERGE_RC" ;;
  "api repos/o/r/branches/"*) # protection probe (#156); FAKE_PROTECTION = classic (default) | none404 | ruleset | none403 | error | ratelimit
    case "${FAKE_PROTECTION:-classic}" in
      classic) echo '{"strict":true,"contexts":["ci"],"checks":[{"context":"ci","app_id":null}]}' ;;
      none403) echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'
               echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1 ;;
      error) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
      ratelimit) echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1 ;;
      *) echo '{"message":"Branch not protected","status":"404"}'; echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  "api repos/o/r/rules/"*) # ruleset probe (#156): payload shape observed on a ruleset-protected branch
    case "${FAKE_PROTECTION:-classic}" in
      ruleset) echo '[{"type":"deletion","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":1},{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"do_not_enforce_on_create":false,"required_status_checks":[{"context":"ci"}]},"ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":1}]' ;;
      none403) echo "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)" >&2; exit 1 ;;
      *) echo '[]' ;;
    esac ;;
  "api repos/o/r/commits/"*) echo "${FAKE_HEAD_DATE:-2025-12-31T00:00:00Z}" ;; # --tick-from-review head date (#9)
  "api repos/o/r/pulls/7")
    case "$*" in
      *head.sha*) echo "${FAKE_HEAD_SHA:-$(git --git-dir="$FAKE_REMOTE" rev-parse "$FAKE_BRANCH")}" ;; # the real remote head; FAKE_HEAD_SHA = a lagging REST read (#157)
      *merged_at*) [ "${FAKE_MERGED:-true}" = true ] && echo "2026-10-01T00:00:00Z" || echo null ;;
      *) echo "${FAKE_MERGED:-true}" ;;
    esac ;;
  "api repos/o/r/issues/"*)
    case "$*" in
      *comments*) cat "$FAKE_COMMENTS" 2>/dev/null || echo '[]' ;; # --tick-from-review (#9)
      *labels*) n="${2##*/}"; cat "$FAKE_ISSUES/$n.labels" 2>/dev/null || echo "closed" ;; # declared-exception lookup (#122)
      *) n="${2##*/}"; cat "$FAKE_ISSUES/$n" 2>/dev/null || echo open ;;
    esac ;;
  "api -X") case "$*" in
      *"PATCH repos/o/r/pulls/7"*) # --tick-from-review (#9): record the PATCH, update the served body
        all="$*"; f="${all##*body=@}"; cp "$f" "$FAKE_BODY" && cp "$f" "$FAKE_LOG.patch" ;;
      *"issues/"*) ;; *) echo "fake gh: unexpected: $*" >&2; exit 99 ;; esac ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 99 ;;
esac
exit 0
FAKE
chmod +x "$BASE/bin/gh"

# fixture: bare origin + working clone on feat/x one commit ahead of main
setup() {
  local d="$BASE/$1"
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  ( cd "$d/work" && git config user.email t@t && git config user.name t \
    && mkdir -p .claude-plugin workflows \
    && printf '{\n  "name": "lgtmgate",\n  "version": "0.8.80",\n  "x": 1\n}\n' > .claude-plugin/plugin.json \
    && printf "const BUILD = { plugin: 'lgtmgate', version: '0.8.80', cutFrom: 'abc1234' }\n" > workflows/deliver-pipeline.js \
    && git add -A && git commit -qm init && git push -q origin HEAD:main \
    && git checkout -q -b feat/x && echo change > f.txt && git add -A && git commit -qm feat \
    && git push -q origin feat/x ) >/dev/null 2>&1
  echo "$d"
}

review_at() { # <dir> <sha>: $d/comments.json = one multi-line verdict whose marker carries <sha> (pages concatenated like gh --paginate)
  printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- pipeline-review-round pr=7 sha=%s -->\\nLGTM\\nevery box proven"}]\n' "$2" > "$1/comments.json"
}
head_of() { git --git-dir="$1/origin.git" rev-parse feat/x; }
run() { # <dir> <body-file> [checks-rc]; serves a review on the CURRENT head unless $d/comments.keep pins the fixture (#157)
  local d="$1"
  [ -e "$d/comments.keep" ] || review_at "$d" "$(head_of "$d")"
  : > "$d/log"; : > "$d/pushes"; rm -f "$d/log.stale" "$d/log.patch" "$d/log.noreq" "$d/log.pending"; mkdir -p "$d/issues"
  [ -n "${FAKE_STALE:-}" ] && echo "$FAKE_STALE" > "$d/log.stale"
  printf '#!/bin/sh\necho "$1" >> "%s/pushes"\n' "$d" > "$d/origin.git/hooks/update"; chmod +x "$d/origin.git/hooks/update"
  ( cd "$d/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$d/log" FAKE_BODY="$2" FAKE_BRANCH=feat/x \
      FAKE_REMOTE="$d/origin.git" FAKE_CHECKS_RC="${3:-0}" FAKE_ISSUES="$d/issues" FAKE_COMMENTS="$d/comments.json" LEAD_MERGE_POLL_SLEEP=0 bash "$SCRIPT" 7 -R o/r $RUN_FLAGS ) > "$d/out" 2>&1
}
# push a commit to origin/main from a second clone: main_commit <dir> <bump 0|1> <file> <content>
main_commit() {
  local d="$1" bump="$2"
  [ -d "$d/other" ] || git clone -q "$d/origin.git" "$d/other" 2>/dev/null
  ( cd "$d/other" && git config user.email t@t && git config user.name t && git checkout -q main \
    && if [ "$bump" = 1 ]; then
         sed -i.bak 's/"version": "0.8.80"/"version": "0.8.81"/' .claude-plugin/plugin.json
         sed -i.bak "s/version: '0.8.80'/version: '0.8.81'/" workflows/deliver-pipeline.js; rm -f ./*.bak .claude-plugin/*.bak workflows/*.bak
       fi \
    && printf '%s\n' "$4" > "$3" && git add -A && git commit -qm "main: $3" && git push -q origin main ) >/dev/null 2>&1
}

printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n' > "$BASE/open.md"
printf 'Closes #1\n- [x] a\n' > "$BASE/nomark.md"
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n- [x] b\n<!-- acceptance:end -->\n- [ ] outside\n' > "$BASE/good.md"

# 1. unchecked box
D="$(setup open)"; run "$D" "$BASE/open.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" = feat ] \
  && ok "unchecked box: refused, no bump, no update-branch/checks/merge" || bad "unchecked box (rc=$rc)"

# 2. missing markers
D="$(setup nomark)"; run "$D" "$BASE/nomark.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'update-branch|pr merge' "$D/log" && ok "missing markers: refused" || bad "missing markers (rc=$rc)"

# 3. happy path
D="$(setup happy)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ok "happy path rc=0" || bad "happy path rc=$rc: $(tail -3 "$D/out")"
seq="$(grep -oE 'pr (update-branch|checks|merge)|pr view 7 -R o/r --json headRefOid' "$D/log" | tr '\n' ',')"
[ "$seq" = "pr view 7 -R o/r --json headRefOid,pr checks,pr checks,pr merge," ] && ok "order: base merge+bump+push (one push) < poll < required-checks probe < checks < merge" || bad "order: $seq"
[ "$(wc -l < "$D/pushes" | tr -d ' ')" = 1 ] && ok "exactly one push" || bad "push count: $(cat "$D/pushes")"
! grep -q 'update-branch' "$D/log" && ok "no gh pr update-branch" || bad "update-branch called"
git -C "$D/origin.git" log -1 --format=%s feat/x | grep -qx 'chore: bump 0.8.81 (lead-merge)' && ok "bump commit is the pushed head" || bad "remote head not the bump"
grep -q -- '--required' "$D/log" && ok "checks use --required when supported" || bad "--required missing"
grep -q -- '--watch --fail-fast' "$D/log" && ok "checks use --watch --fail-fast" || bad "checks flags"
grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "merge uses --merge" || bad "merge flag"
! grep -q -e '--auto' -e '--squash' "$D/log" && ok "no auto/squash flag in any gh call" || bad "forbidden flag in log"
grep -q '"version": "0.8.81"' "$D/work/.claude-plugin/plugin.json" \
  && grep -q "version: '0.8.81', cutFrom: '$(git -C "$D/work" rev-parse --short origin/main)'" "$D/work/workflows/deliver-pipeline.js" \
  && ok "plugin.json + BUILD bumped (cutFrom = origin/main short sha)" || bad "bump content"

# 3b. id-format bodies (#183): boxes carry an <!-- ac:N --> id after their checkbox; the gate counts them like any box
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> a\n- [ ] <!-- ac:2 --> b\n<!-- acceptance:end -->\n' > "$BASE/open-id.md"
printf 'Closes #1\n<!-- acceptance:start -->\n- [x] <!-- ac:1 --> a\n- [x] <!-- ac:2 --> b\n<!-- acceptance:end -->\n- [ ] outside\n' > "$BASE/good-id.md"
D="$(setup open-id)"; run "$D" "$BASE/open-id.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" = feat ] \
  && ok "id-format: an open id box is refused, no bump, no update-branch/checks/merge" || bad "id-format open box (rc=$rc)"
D="$(setup happy-id)"; run "$D" "$BASE/good-id.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ! grep -q -e '--auto' -e '--squash' "$D/log" \
  && ok "id-format: an all-checked id body merges (rc=0, --merge)" || bad "id-format happy path rc=$rc: $(tail -3 "$D/out")"
D_AFTER_3B="$D"

# 3c. fenced examples (#202): a marker pair inside a fenced code block is not the acceptance block (the engine's rule,
# templates/pr-body-splice.cjs), so the gate reads the same block the engine ticked
fx='```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n'
fx4='````\n```\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n```\n````\n'
fxt='~~~\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n~~~\n'
fxu='```\nan example, never closed\n<!-- acceptance:start -->\n- [ ] an example box\n<!-- acceptance:end -->\n'
real_ok='<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n'
real_open='<!-- acceptance:start -->\n- [x] a\n- [ ] b\n<!-- acceptance:end -->\n'
printf 'Closes #1\n%b%b' "$fx" "$real_ok" > "$BASE/fx-before-ok.md"
printf 'Closes #1\n%b%b' "$real_ok" "$fx" > "$BASE/fx-after-ok.md"
printf 'Closes #1\n%b%b' "$fx" "$real_open" > "$BASE/fx-before-open.md"
printf 'Closes #1\n%b%b' "$real_open" "$fx" > "$BASE/fx-after-open.md"
printf 'Closes #1\n%b%b%b' "$fx4" "$real_ok" "$fxt" > "$BASE/fx-long-tilde-ok.md"
printf 'Closes #1\n%b%b' "$fxu" "$real_ok" > "$BASE/fx-unclosed-before.md"
printf 'Closes #1\n%b%b' "$real_ok" "$fxu" > "$BASE/fx-unclosed-after.md"
printf 'Closes #1\n%b' "$fx" > "$BASE/fx-only.md"
for c in before after; do
  D="$(setup "fx-$c-ok")"; run "$D" "$BASE/fx-$c-ok.md"; rc=$?
  [ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
    && ok "fenced-example $c a ticked real block: merges (rc=0, --merge)" || bad "fenced-example $c ticked (rc=$rc): $(tail -3 "$D/out")"
  D="$(setup "fx-$c-open")"; run "$D" "$BASE/fx-$c-open.md"; rc=$?
  [ "$rc" -ne 0 ] && grep -qF -- '- [ ] b' "$D/out" && ! grep -qF 'an example box' "$D/out" && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" \
    && [ "$(git -C "$D/work" log --format=%s | head -1)" = feat ] \
    && ok "fenced-example $c an open real block: refused naming only the real box, no bump/checks/merge" || bad "fenced-example $c open (rc=$rc): $(tail -3 "$D/out")"
done
D="$(setup fx-long-tilde)"; run "$D" "$BASE/fx-long-tilde-ok.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "fenced-example ~~~ and a 4-backtick fence around a 3-backtick one: merges" || bad "fenced-example long/tilde (rc=$rc): $(tail -3 "$D/out")"
D="$(setup fx-unclosed-after)"; run "$D" "$BASE/fx-unclosed-after.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" \
  && ok "fenced-example fence never closed after the real block: merges (the real pair comes first)" || bad "fenced-example unclosed after (rc=$rc): $(tail -3 "$D/out")"
D="$(setup fx-unclosed-before)"; run "$D" "$BASE/fx-unclosed-before.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'acceptance markers missing' "$D/out" && grep -qF 'fence' "$D/out" && ! grep -qE 'update-branch|pr merge|pr checks' "$D/log" \
  && ok "fenced-example fence never closed before the real block: refused with the readable reason, nothing bumped" || bad "fenced-example unclosed before (rc=$rc): $(tail -3 "$D/out")"
# engine parity: the block the lib finds is the one pr-body-splice.cjs replaces (the splice of a sentinel, put back as the lib's block, gives the body again)
if command -v node >/dev/null 2>&1; then
  . "$ACC_LIB"
  printf 'SENT' > "$BASE/sent.txt"
  for f in fx-before-ok fx-after-ok fx-before-open fx-after-open fx-long-tilde-ok fx-unclosed-before fx-unclosed-after fx-only good open; do
    node "$ROOT/templates/pr-body-splice.cjs" splice acceptance "$BASE/$f.md" "$BASE/sent.txt" "$BASE/sent.out" >/dev/null 2>&1; erc=$?
    acceptance_extract_block < "$BASE/$f.md" > "$BASE/blk.txt"; lrc=$?
    if [ "$erc" -eq 3 ]; then
      [ "$lrc" -eq 3 ] && ok "fenced-example parity $f: no block, as in the engine" || bad "fenced-example parity $f: engine finds no block, lib rc=$lrc"
    else
      awk -v blk="$BASE/blk.txt" '$0 == "SENT" { while ((getline l < blk) > 0) print l; next } { print }' "$BASE/sent.out" > "$BASE/rebuilt.md"
      [ "$erc" -eq 0 ] && [ "$lrc" -eq 0 ] && cmp -s "$BASE/rebuilt.md" "$BASE/$f.md" \
        && ok "fenced-example parity $f: same block as the engine" || bad "fenced-example parity $f: engine rc=$erc lib rc=$lrc"
    fi
  done
else
  bad "fenced-example parity: node missing"
fi
D="$D_AFTER_3B"

# 4. idempotent re-run: no second bump
: > "$D/log"
( cd "$D/work" && PATH="$BASE/bin:$PATH" FAKE_LOG="$D/log" FAKE_BODY="$BASE/good.md" FAKE_BRANCH=feat/x FAKE_REMOTE="$D/origin.git" FAKE_COMMENTS="$D/comments.json" bash "$SCRIPT" 7 -R o/r ) > "$D/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ] && ok "re-run does not bump twice" || bad "second bump created (rc=$rc)"

# 5. CI failure -> no merge
D="$(setup ci)"; run "$D" "$BASE/good.md" 1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'pr checks' "$D/log" && ! grep -q 'pr merge' "$D/log" && ok "checks failure: no merge" || bad "checks failure (rc=$rc)"

# 6. main moved after the branch was cut: own bump + unrelated commit
D="$(setup moved)"; main_commit "$D" 1 g.txt other; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ok "moved main: rc=0" || bad "moved main rc=$rc: $(tail -3 "$D/out")"
head_sha="$(git -C "$D/origin.git" rev-parse feat/x)"
git -C "$D/origin.git" show "$head_sha:.claude-plugin/plugin.json" | grep -q '"version": "0.8.82"' \
  && git -C "$D/origin.git" show "$head_sha:workflows/deliver-pipeline.js" | grep -q "version: '0.8.82'" \
  && ok "version = max(branch, main)+1 = 0.8.82" || bad "moved main version"
git -C "$D/origin.git" merge-base --is-ancestor "$(git -C "$D/origin.git" rev-parse main)" "$head_sha" \
  && ok "pushed branch contains origin/main" || bad "main not merged into branch"
git -C "$D/origin.git" show "$head_sha:g.txt" >/dev/null 2>&1 && ok "unrelated main commit present" || bad "g.txt missing"
[ "$(wc -l < "$D/pushes" | tr -d ' ')" = 1 ] && grep -q 'pr merge' "$D/log" && ok "moved main: one push, merged" || bad "moved main push/merge: $(cat "$D/pushes")"

# 7. main conflicts in a non-version file: dies before any push, no merge call
D="$(setup conflict)"; main_commit "$D" 0 f.txt other; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && [ -z "$(git -C "$D/work" status --porcelain)" ] && ok "conflict: died, no push, merge aborted, no merge call" || bad "conflict case (rc=$rc)"

# 8. main bumped after our bump was pushed (version-only conflict): main's copy taken, re-bumped
D="$(setup vconf)"; run "$D" "$BASE/good.md"; main_commit "$D" 1 g.txt other; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q '"version": "0.8.82"' "$D/work/.claude-plugin/plugin.json" \
  && ok "version-only conflict resolved, re-bumped to 0.8.82" || bad "vconf rc=$rc: $(tail -3 "$D/out")"

# 9. remote head ahead of local (previous run pushed): fast-forward, no second bump
D="$(setup ahead)"; run "$D" "$BASE/good.md"
git -C "$D/work" checkout -q -B feat/x HEAD~1 >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && [ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" -eq 1 ] && [ ! -s "$D/pushes" ] \
  && ok "remote ahead: fast-forwarded, no second bump, no push" || bad "ahead case (rc=$rc): $(tail -3 "$D/out")"

# 9b. diverged local vs remote: refused before any push
D="$(setup diverged)"; ( cd "$D/work" && echo more > h.txt && git add -A && git commit -qm local-only ) >/dev/null 2>&1
main_commit "$D" 0 k.txt k >/dev/null 2>&1
( cd "$D/other" && git checkout -q feat/x && echo r > r.txt && git add -A && git commit -qm remote-only && git push -q origin feat/x ) >/dev/null 2>&1
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$D/pushes" ] && grep -q diverged "$D/out" && ok "diverged: refused" || bad "diverged (rc=$rc)"

# 10. checks race: first polls report the old sha / no checks
D="$(setup race)"; FAKE_STALE=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c 'json headRefOid' "$D/log")" -eq 4 ] && ok "polls until pushed sha + checks reported (4 polls)" || bad "race (rc=$rc): $(cat "$D/log")"
D="$(setup never)"; FAKE_STALE=99 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && ok "never reports checks: bounded, no merge" || bad "never (rc=$rc)"
D="$(setup reqlate)"; FAKE_NOREQ=2 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ok "required checks registered late: keeps polling, then merges" || bad "reqlate (rc=$rc): $(tail -3 "$D/out")"
D="$(setup reqnever)"; FAKE_NOREQ=99 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && ok "required checks never registered: bounded, no merge" || bad "reqnever (rc=$rc)"

# 11. gh without --required: watch without it
D="$(setup noreq)"; FAKE_HAS_REQUIRED=0 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q -- '--required' "$D/log" && ok "no --required when unsupported" || bad "noreq (rc=$rc)"

# 11b. base without required checks (#156): protection probe 404/403 and no ruleset rule -> watch the head's checks, never --required
cfg_ci() { # <dir> <json-list>: commit .claude/pipeline.config.json with ciChecks on the head branch (the script wants a clean tree)
  ( cd "$1/work" && mkdir -p .claude && printf '{"ciChecks": %s}\n' "$2" > .claude/pipeline.config.json \
    && git add -A && git commit -qm cfg && git push -q origin feat/x ) >/dev/null 2>&1
}
nrc_merged() { # <label>: merged without --required/--watch, mode named, head checks polled as JSON
  [ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ! grep -qE -- '--required|--watch' "$D/log" \
    && grep -q 'pr checks 7 -R o/r --json name,bucket' "$D/log" && grep -qF '(mode: no-required-checks)' "$D/out" \
    && ok "$1" || bad "$1 (rc=$rc): $(tail -3 "$D/out")"
}
D="$(setup nrc-404)"; FAKE_PROTECTION=none404 run "$D" "$BASE/good.md"; rc=$?
nrc_merged "no required checks (protection 404, no ruleset): merges without --required"
D="$(setup nrc-403)"; FAKE_PROTECTION=none403 run "$D" "$BASE/good.md"; rc=$?
nrc_merged "no required checks (protection and rulesets 403, private Free): merges without --required"
D="$(setup nrc-ruleset)"; FAKE_PROTECTION=ruleset run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr checks 7 -R o/r --required' "$D/log" && ! grep -q -- '--json name,bucket' "$D/log" && ! grep -qF 'no-required-checks' "$D/out" \
  && ok "ruleset-only required checks (protection 404): keeps --required" || bad "ruleset-only (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-error)"; FAKE_PROTECTION=error run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -qF 'cannot tell whether main requires status checks' "$D/out" \
  && ok "protection probe inconclusive (HTTP 500): refused, no checks, no merge" || bad "probe error (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-ratelimit)"; FAKE_PROTECTION=ratelimit run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -qF 'cannot tell whether main requires status checks' "$D/out" \
  && ok "protection probe rate-limited (HTTP 403): inconclusive, not read as none: refused" || bad "rate-limit probe (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-scoped)"; cfg_ci "$D" '["ci"]'
FAKE_PROTECTION=none404 FAKE_CHECKS_JSON='[{"name":"ci","bucket":"pass"},{"name":"codeql","bucket":"fail"}]' run "$D" "$BASE/good.md"; rc=$?
nrc_merged "no required checks, ciChecks set: a failing check outside ciChecks does not gate the merge"
D="$(setup nrc-named-fail)"; cfg_ci "$D" '["ci"]'
FAKE_PROTECTION=none404 FAKE_CHECKS_JSON='[{"name":"ci","bucket":"fail"}]' run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && grep -qF 'CI checks failed (ci)' "$D/out" \
  && ok "no required checks, named check failing: no merge" || bad "named fail (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-all-fail)"
FAKE_PROTECTION=none404 FAKE_CHECKS_JSON='[{"name":"ci","bucket":"pass"},{"name":"codeql","bucket":"cancel"}]' run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && grep -qF 'CI checks failed (codeql)' "$D/out" \
  && ok "no required checks, ciChecks unset: every reported check gates (cancel refuses)" || bad "all-fail (rc=$rc): $(tail -3 "$D/out")"
D="$(setup nrc-pending)"; FAKE_PROTECTION=none404 FAKE_PENDING=2 run "$D" "$BASE/good.md"; rc=$?
[ "$(grep -c 'pr checks 7 -R o/r --json' "$D/log")" -eq 3 ] && nrc_merged "no required checks, pending then green: waits (3 polls), then merges" || bad "pending polls: $(grep -c 'pr checks' "$D/log")"
D="$(setup nrc-never)"; cfg_ci "$D" '["ci","lint"]'
FAKE_PROTECTION=none404 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'pr merge' "$D/log" && grep -qF '(mode: no-required-checks)' "$D/out" && grep -qF 'lint' "$D/out" && grep -q 'never reported its checks' "$D/out" \
  && ok "no required checks, named check never reported: bounded die names the mode and the check" || bad "never reported (rc=$rc): $(tail -3 "$D/out")"
D="$(setup req-mode-msg)"; FAKE_NOREQ=99 LEAD_MERGE_POLL_MAX=3 run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF '(mode: required-checks on main)' "$D/out" && ok "required checks never registered: timeout message names the mode" || bad "required-mode message (rc=$rc): $(tail -3 "$D/out")"

# 12. issue closing after a verified merge (#109)
printf 'Closes #5\nfixes: #6, Resolved #8 and closes #5 again; Refs #9; Fixes o/other#77\n<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n' > "$BASE/close.md"
mut() { grep -cE 'gh api -X (POST|PATCH) repos/o/r/issues/' "$1/log" | tr -d ' '; }
D="$(setup cl-fail)"; FAKE_MERGE_RC=1 run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(mut "$D")" = 0 ] && ! grep -qE 'repos/o/r/issues/[0-9]+( |$)' "$D/log" && ok "merge failure: non-zero, no issue call" || bad "merge failure (rc=$rc)"
D="$(setup cl-unmerged)"; FAKE_MERGED=false run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -ne 0 ] && [ "$(mut "$D")" = 0 ] && ! grep -qE 'repos/o/r/issues/[0-9]+( |$)' "$D/log" && ok "not read back as merged: non-zero, no issue call" || bad "unmerged (rc=$rc)"
D="$(setup cl-ok)"; mkdir -p "$D/issues"; echo closed > "$D/issues/8"; run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && ok "merged with closing refs: rc=0" || bad "closing rc=$rc: $(tail -3 "$D/out")"
for n in 5 6; do
  [ "$(grep -c "gh api -X POST repos/o/r/issues/$n/comments -f body=Fixed by #7 (merged)\." "$D/log")" = 1 ] \
    && [ "$(grep -c "gh api -X PATCH repos/o/r/issues/$n -f state=closed -f state_reason=completed" "$D/log")" = 1 ] \
    && ok "open Closes #$n: one comment + one close" || bad "issue #$n calls: $(grep "issues/$n" "$D/log")"
done
! grep -qE 'X (POST|PATCH) repos/o/r/issues/8' "$D/log" && ok "already-closed #8: no call" || bad "closed issue touched"
! grep -qE 'repos/o/r/issues/(9|77)' "$D/log" && ok "Refs #9 and other-repo ref: no call" || bad "Refs/other-repo touched"
[ "$(mut "$D")" = 4 ] && ok "dedup: 4 mutating calls total" || bad "mutating calls: $(mut "$D")"

# 13. closing keywords parsed in the header block only (#119)
printf 'Closes #5\n\nAlso `Fixes #7` inline\n```\nResolves #12\n```\n## What this ships\n- Fixes #10\n## Acceptance checklist\n<!-- acceptance:start -->\n- [x] fixture body `Closes #5`, Fixes #6, Closes #11\n<!-- acceptance:end -->\n' > "$BASE/hdr.md"
D="$(setup hdr)"; run "$D" "$BASE/hdr.md"; rc=$?
[ "$rc" -eq 0 ] && ok "header-only body: rc=0" || bad "header rc=$rc: $(tail -3 "$D/out")"
[ "$(grep -c "gh api -X PATCH repos/o/r/issues/5 -f state=closed" "$D/log")" = 1 ] && ok "Closes #5 on first line: closed once" || bad "issue #5: $(grep 'issues/5' "$D/log")"
for n in 6 7 10 11 12; do
  ! grep -qE "X (POST|PATCH) repos/o/r/issues/$n( |/)" "$D/log" && ok "keyword outside header or in code ($n): no close call" || bad "issue #$n touched"
done
[ "$(mut "$D")" = 2 ] && ok "header-only: 2 mutating calls total" || bad "mutating calls: $(mut "$D")"

# 14. declared exceptions (#122): exception: <what> — <why> — #N
exc_body() { printf 'Closes #1\n<!-- acceptance:start -->\n- [x] a\n%s\n<!-- acceptance:end -->\n' "$1" > "$2"; }
exc_run() { # <name> <exception-line> <issue-file-content|""> <debt-marker|""> -> sets D, rc
  D="$(setup "$1")"; exc_body "$2" "$BASE/$1.md"; mkdir -p "$D/issues"
  [ -n "$3" ] && printf '%s\n' "$3" > "$D/issues/9.labels"
  if [ -n "$4" ]; then ( cd "$D/work" && echo "// DEBT(#$4): skipped" >> f.txt && git add -A && git commit -qm debt && git push -q origin feat/x ) >/dev/null 2>&1; fi
  run "$D" "$BASE/$1.md"; rc=$?
}
exc_refused() { # <label> <reason-substring>
  [ "$rc" -ne 0 ] && grep -q 'FAIL: declared-exception:' "$D/out" && grep -q -- "$2" "$D/out" \
    && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" && [ "$(git -C "$D/work" log --format=%s | head -1)" != "chore: bump 0.8.81 (lead-merge)" ] \
    && ok "$1: refused, FAIL line, no push/checks/merge" || bad "$1 (rc=$rc): $(tail -3 "$D/out")"
}
EXC='- [x] exception: skip the lint pass \xe2\x80\x94 needs a config migration \xe2\x80\x94 #9'
EXC="$(printf -- "$EXC")"
exc_run exc-ok "$EXC" "open tech-debt,other" 9
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ok "valid exception: merge proceeds" || bad "valid exception (rc=$rc): $(tail -3 "$D/out")"
exc_run exc-ascii "exception: skip lint -- migration pending -- #9" "open tech-debt" 9
[ "$rc" -eq 0 ] && ok "valid exception with ' -- ' separator and no box prefix" || bad "ascii separator (rc=$rc)"
exc_run exc-bad "- [x] exception: skip the lint pass, no reason" "open tech-debt" 9; exc_refused "malformed line" "malformed"
exc_run exc-closed "$EXC" "closed tech-debt" 9; exc_refused "follow-up issue closed" "not open"
exc_run exc-nolabel "$EXC" "open bug,other" 9; exc_refused "issue without tech-debt" "tech-debt label"
exc_run exc-nomarker "$EXC" "open tech-debt" ""; exc_refused "no DEBT(#N) in the diff" "DEBT(#9)"
exc_run exc-wrongn "$EXC" "open tech-debt" 5; exc_refused "DEBT marker with another N" "DEBT(#9)"

# 15. --tick-from-review (#9)
MK='<!-- pipeline-review-round pr=7 sha=@HEAD@ -->' # @HEAD@ = the head sha at fixture time (mkc)
mkc() { # <dir> <review-file> [push-note] -> $D/comments.json (review, then optional Nick push-note); pinned: run() keeps it
  : > "$1/comments.keep"
  python3 - "$1/comments.json" "$2" "${3:-}" "$(head_of "$1")" <<'PY'
import json, sys
c = [{"id": 1, "created_at": "2026-01-01T00:00:00Z", "body": open(sys.argv[2]).read().replace("@HEAD@", sys.argv[4])}]
if sys.argv[3]:
    c.append({"id": 2, "created_at": "2026-01-02T00:00:00Z", "body": "<!-- pipeline-review-round pr=7 -->\n" + sys.argv[3]})
with open(sys.argv[1], "w") as f:  # concatenated pages, like gh --paginate
    json.dump(c[:1], f)
    if c[1:]:
        json.dump(c[1:], f)
PY
}
tick_body() { printf 'Closes #1\n## Acceptance checklist\n<!-- acceptance:start -->\n%s\n<!-- acceptance:end -->\n' "$1" > "$2"; }
tick_run() { cp "$2" "$1/body.md"; RUN_FLAGS="${RUN_FLAGS_OVERRIDE---tick-from-review}" run "$1" "$1/body.md"; } # per-run copy: the fake PATCH rewrites it
B1='- [ ] `bash t.sh` exits 0'; B2='- [ ] grep -c foo f.txt prints 1'
printf '%s\n%s\n%s\n' "$MK" 'Verified, tick pending (permissions).' \
  '- [ ] **`bash t.sh` exits 0** — verified, tick pending (permissions): `bash t.sh` -> exit 0, `PASS 5/5`' > "$BASE/rv1.md"

# 15a. proven box ticked, then the normal merge sequence
D="$(setup tk-ok)"; tick_body "$B1" "$BASE/tk1.md"; mkc "$D" "$BASE/rv1.md"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "tick-from-review: proven box ticked, merge proceeds" || bad "tick ok (rc=$rc): $(tail -3 "$D/out")"
grep -qF -- '- [x] `bash t.sh` exits 0 — ticked by lead-merge from Morgan'"'"'s review' "$D/log.patch" 2>/dev/null \
  && [ "$(grep -c 'pulls/7 -F body' "$D/log")" = 1 ] && ok "tick: REST PATCH pulls/7, line ticked with suffix" || bad "tick patch: $(cat "$D/log.patch" 2>/dev/null)"
[ "$(grep -n 'PATCH repos/o/r/pulls/7' "$D/log" | cut -d: -f1)" -lt "$(grep -n 'pr merge' "$D/log" | cut -d: -f1)" ] && ok "tick happens before the merge" || bad "tick order"

# 15a2. Morgan's template proof without backticks (`<command> -> <output>`) is accepted
printf '%s\n%s\n%s\n' "$MK" 'Tick pending.' \
  '- [ ] **`bash t.sh` exits 0** — verified, tick pending (permissions): bash t.sh -> exit 0, PASS 5/5' > "$BASE/rv1b.md"
D="$(setup tk-arrow)"; tick_body "$B1" "$BASE/tk1b.md"; mkc "$D" "$BASE/rv1b.md"; tick_run "$D" "$BASE/tk1b.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && ok "tick-from-review: arrow-form proof accepted" || bad "tick arrow (rc=$rc): $(tail -3 "$D/out")"

# 15b. box without proof stays open, merge refused; proven one is ticked
tick_body "$B1
$B2" "$BASE/tk2.md"; D="$(setup tk-noproof)"; mkc "$D" "$BASE/rv1.md"; tick_run "$D" "$BASE/tk2.md"; rc=$?
[ "$rc" -ne 0 ] && ! grep -qE 'pr merge|pr checks' "$D/log" && [ ! -s "$D/pushes" ] && grep -qF -- '- [ ] grep -c foo f.txt prints 1' "$D/log.patch" \
  && grep -qF -- '- [x] `bash t.sh` exits 0' "$D/log.patch" && ok "box without proof stays open: refused, no push/merge" || bad "noproof (rc=$rc): $(tail -3 "$D/out")"

# 15c. [human-gate] is never ticked even if Morgan lists it as proven
HG='- [ ] [human-gate] Alex confirms the UI'
tick_body "$HG" "$BASE/tk3.md"; printf '%s\n%s\n%s\n' "$MK" 'Verified.' '- [ ] **[human-gate] Alex confirms the UI** — verified, tick pending (permissions): `look` -> ok' > "$BASE/rv3.md"
D="$(setup tk-hg)"; mkc "$D" "$BASE/rv3.md"; tick_run "$D" "$BASE/tk3.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -q 'pr merge' "$D/log" && ok "human-gate box never ticked: no PATCH, refused" || bad "human-gate (rc=$rc)"

# 15d. no review comment -> refused (also when only a one-line push-note exists)
D="$(setup tk-none)"; echo '[]' > "$D/comments.json"; : > "$D/comments.keep"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" && grep -q 'FAIL: review-stale' "$D/out" && ok "no review comment: refused" || bad "no review (rc=$rc): $(tail -3 "$D/out")"
D="$(setup tk-note)"; printf '%s\n%s\n' "$MK" 'only a push-note' > "$BASE/note.md"; mkc "$D" "$BASE/note.md"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ok "one-line marker comment is not a verdict: refused" || bad "push-note only (rc=$rc)"

# 15e. without the flag nothing is ticked
D="$(setup tk-noflag)"; mkc "$D" "$BASE/rv1.md"; RUN_FLAGS_OVERRIDE="" tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -q 'comments' "$D/log" && ! grep -qE 'pr merge|pr checks' "$D/log" && ok "no flag: nothing ticked, refused as before" || bad "noflag (rc=$rc)"

# 15f. stale proofs (#9): a marker comment after the verdict, or a head commit newer than the verdict
D="$(setup tk-stale-note)"; mkc "$D" "$BASE/rv1.md" "push-note: nothing new"; tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && grep -qF "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first" "$D/out" && ok "push-note after the verdict: refused, nothing ticked" || bad "stale note (rc=$rc): $(tail -3 "$D/out")"
D="$(setup tk-stale-date)"; mkc "$D" "$BASE/rv1.md"; FAKE_HEAD_DATE="2026-01-03T00:00:00Z" tick_run "$D" "$BASE/tk1.md"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$D/log.patch" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && grep -qF "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first" "$D/out" && ok "head commit newer than the verdict: refused, nothing ticked" || bad "stale date (rc=$rc): $(tail -3 "$D/out")"

# 16. consumer repo (#145): no plugin manifest in the merged tree -> bump skipped, the rest of the gesture runs
rm_files() { # <dir> <clone> <branch> <files...>: remove tracked files in a clone and push the branch
  local d="$1" clone="$2" br="$3"; shift 3
  [ -d "$d/$clone" ] || git clone -q "$d/origin.git" "$d/$clone" 2>/dev/null
  ( cd "$d/$clone" && git config user.email t@t && git config user.name t && git checkout -q "$br" \
    && git rm -q -- "$@" && git commit -qm "drop plugin files" && git push -q origin "$br" ) >/dev/null 2>&1
}
D="$(setup consumer)"
rm_files "$D" work feat/x .claude-plugin/plugin.json workflows/deliver-pipeline.js
rm_files "$D" other main .claude-plugin/plugin.json workflows/deliver-pipeline.js
run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && ok "consumer repo without manifest: rc=0" || bad "consumer repo rc=$rc: $(tail -3 "$D/out")"
grep -qF 'lead-merge: no plugin manifest, version bump skipped' "$D/out" && ok "consumer repo: skip line logged" || bad "consumer repo: no skip line"
[ "$(git -C "$D/work" log --format=%s | grep -c 'chore: bump')" = 0 ] && ok "consumer repo: no bump commit" || bad "consumer repo: bump commit created"
grep -q 'pr merge 7 -R o/r --merge' "$D/log" && grep -qE 'gh api -X PATCH repos/o/r/issues/5 -f state=closed' "$D/log" \
  && ok "consumer repo: merged and issue closed" || bad "consumer repo: merge/close missing: $(cat "$D/log")"
D="$(setup consumer-nobuild)"
rm_files "$D" work feat/x workflows/deliver-pipeline.js
rm_files "$D" other main workflows/deliver-pipeline.js
run "$D" "$BASE/close.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q '"version": "0.8.81"' "$D/work/.claude-plugin/plugin.json" \
  && ok "consumer with manifest but no BUILD line: plugin.json bumped, rc=0" || bad "consumer nobuild (rc=$rc): $(tail -3 "$D/out")"

# 17. review freshness (#157): the latest sha-bearing review marker must name the PR head as read BEFORE the script's own commits
pin_review() { review_at "$1" "$2"; : > "$1/comments.keep"; } # <dir> <sha>: pin the fixture (run() would regenerate it on the head)
late_commit() { # <dir> [subject] [file]: push a commit to feat/x after the review
  ( cd "$1/work" && echo late > "${3:-late.txt}" && git add -A && git commit -qm "${2:-late}" && git push -q origin feat/x ) >/dev/null 2>&1
}
stale_refused() { # <reviewed-sha> <head-sha>: refused with the review-stale line naming both, before any push/checks/merge
  [ "$rc" -ne 0 ] && grep -qF 'FAIL: review-stale' "$D/out" && grep -qF "$1" "$D/out" && grep -qF "$2" "$D/out" \
    && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log"
}
D="$(setup rs-head)"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge 7 -R o/r --merge' "$D/log" && grep -q 'issues/7/comments' "$D/log" \
  && ok "review-stale: review on the head sha: merge proceeds" || bad "review-stale: review on the head sha (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-late)"; R="$(head_of "$D")"; pin_review "$D" "$R"; late_commit "$D"; H="$(head_of "$D")"; run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && [ "$(git -C "$D/work" log --format=%s | head -1)" = late ] \
  && ok "review-stale: commit after the review: refused naming both shas, no bump" || bad "review-stale: commit after the review (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-none)"; echo '[]' > "$D/comments.json"; : > "$D/comments.keep"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'FAIL: review-stale' "$D/out" && grep -qF 'no review marker' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "review-stale: no review marker: refused" || bad "review-stale: no review marker (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-bare)"; printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- pipeline-review-round pr=7 -->\\nLGTM\\nno sha in the marker"}]\n' > "$D/comments.json"; : > "$D/comments.keep"
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'no review marker' "$D/out" && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "review-stale: a bare marker (no sha) is not a review: refused" || bad "review-stale: bare marker (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-latest)"; H="$(head_of "$D")"
printf '[{"id":1,"created_at":"2026-01-01T00:00:00Z","body":"<!-- pipeline-review-round pr=7 sha=%s -->\\nold\\nverdict"}][{"id":2,"created_at":"2026-01-02T00:00:00Z","body":"<!-- pipeline-review-round pr=7 sha=%s -->\\nnew\\nverdict"},{"id":3,"created_at":"2026-01-03T00:00:00Z","body":"<!-- pipeline-review-round pr=7 -->\\nNick push-note"}]\n' \
  "1111111111111111111111111111111111111111" "$H" > "$D/comments.json"; : > "$D/comments.keep"
run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && ok "review-stale: the latest verdict wins over an older one; a bare push-note after it is ignored" || bad "review-stale: latest verdict (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-own)"; main_commit "$D" 1 g.txt other; run "$D" "$BASE/good.md" 1; : > "$D/comments.keep"; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'pr merge' "$D/log" && grep -qF "only adds lead-merge's own commits" "$D/out" && [ ! -s "$D/pushes" ] \
  && ok "review-stale: re-run after a partial run (own merge + bump commits after the review): tolerated" || bad "review-stale: own commits (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-foreign)"; R="$(head_of "$D")"; run "$D" "$BASE/good.md" 1; : > "$D/comments.keep"; late_commit "$D"; H="$(head_of "$D")"; run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && ok "review-stale: a foreign commit on top of the script's own commits: refused naming both shas" || bad "review-stale: foreign commit (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-forged)"; R="$(head_of "$D")"; pin_review "$D" "$R"; late_commit "$D" "chore: bump 9.9.9 (lead-merge)" evil.txt; H="$(head_of "$D")"; run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && ok "review-stale: a bump-looking commit touching another file: refused" || bad "review-stale: forged bump (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-moved)"; R="$(head_of "$D")"; late_commit "$D"; H="$(head_of "$D")"; pin_review "$D" "$R"; FAKE_HEAD_SHA="$R" run "$D" "$BASE/good.md"; rc=$?
stale_refused "$R" "$H" && grep -qF 'head moved' "$D/out" && ok "review-stale: head moved after the check read it: refused" || bad "review-stale: head moved (rc=$rc): $(tail -3 "$D/out")"
D="$(setup rs-tick)"; tick_body "$B1" "$BASE/tk1.md"; R="$(head_of "$D")"; mkc "$D" "$BASE/rv1.md"; late_commit "$D"; H="$(head_of "$D")"; tick_run "$D" "$BASE/tk1.md"; rc=$?
stale_refused "$R" "$H" && [ ! -e "$D/log.patch" ] && ok "review-stale: --tick-from-review on a stale review: refused before anything is ticked" || bad "review-stale: tick on stale (rc=$rc): $(tail -3 "$D/out")"

# 18. prerelease versions (the 1.0.0-beta.N channel): the bump follows semver 2.0.0 precedence, never a broken string or a patch
set_version() { # <dir> <clone> <branch> <ver> [subject]: set the version in plugin.json + BUILD of a clone, commit and push <branch>
  local d="$1" clone="$2" br="$3" v="$4"
  [ -d "$d/$clone" ] || git clone -q "$d/origin.git" "$d/$clone" 2>/dev/null
  ( cd "$d/$clone" && git config user.email t@t && git config user.name t && git checkout -q "$br" \
    && sed -i.bak -E "s/\"version\": \"[^\"]*\"/\"version\": \"$v\"/" .claude-plugin/plugin.json \
    && sed -i.bak -E "s/version: '[^']*'/version: '$v'/" workflows/deliver-pipeline.js && rm -f .claude-plugin/*.bak workflows/*.bak \
    && git add -A && git commit -qm "${5:-main: version $v}" && git push -q origin "$br" ) >/dev/null 2>&1
}
bumped_to() { # <dir> <ver>: plugin.json + BUILD read <ver>, the pushed head is `chore: bump <ver> (lead-merge)`, one bump commit, merged
  grep -q "\"version\": \"$2\"" "$1/work/.claude-plugin/plugin.json" && grep -q "version: '$2', cutFrom: " "$1/work/workflows/deliver-pipeline.js" \
    && [ "$(git -C "$1/origin.git" log -1 --format=%s feat/x)" = "chore: bump $2 (lead-merge)" ] \
    && [ "$(git -C "$1/work" log --format=%s | grep -c 'chore: bump')" = 1 ] && grep -q 'pr merge 7 -R o/r --merge' "$1/log"
}
D="$(setup pre-next)"; set_version "$D" other main 1.0.0-beta.1; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-beta.2 && ok "prerelease: main at 1.0.0-beta.1 -> the next merge bumps to 1.0.0-beta.2" || bad "prerelease next (rc=$rc): $(tail -3 "$D/out")"
D="$(setup pre-num)"; set_version "$D" other main 1.0.0-beta.9; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-beta.10 && ok "prerelease: the counter is numeric (beta.9 -> beta.10)" || bad "prerelease numeric (rc=$rc): $(tail -3 "$D/out")"
D="$(setup pre-bare)"; set_version "$D" other main 1.0.0-rc; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-rc.1 && ok "prerelease without a numeric tail: 1.0.0-rc -> 1.0.0-rc.1 (a greater version)" || bad "prerelease bare (rc=$rc): $(tail -3 "$D/out")"
# the release gesture: the Lead bumps by hand with lead-merge's own subject; the merge gesture must recognise a prerelease above main and not bump again
D="$(setup pre-hand)"; set_version "$D" work feat/x 1.0.0-beta.1 'chore: bump 1.0.0-beta.1 (lead-merge)'; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -eq 0 ] && bumped_to "$D" 1.0.0-beta.1 && grep -qF 'bump commit for 1.0.0-beta.1 already on the branch, skipping bump' "$D/out" && [ ! -s "$D/pushes" ] \
  && ok "hand bump 0.8.80 -> 1.0.0-beta.1 on the branch: recognised as above main, merged as is, no second bump" || bad "prerelease hand bump (rc=$rc): $(tail -3 "$D/out")"
D="$(setup pre-junk)"; set_version "$D" other main banana; run "$D" "$BASE/good.md"; rc=$?
[ "$rc" -ne 0 ] && grep -qF 'not semver' "$D/out" && [ ! -s "$D/pushes" ] && ! grep -qE 'pr merge|pr checks' "$D/log" \
  && ok "non-semver version on main: refused before any bump, push or merge" || bad "non-semver version (rc=$rc): $(tail -3 "$D/out")"

echo "[lead-merge test] passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
