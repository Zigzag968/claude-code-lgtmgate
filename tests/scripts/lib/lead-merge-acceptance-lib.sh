#!/usr/bin/env bash
# lib-level cases of the acceptance check (#202), before any lead-merge run (sourced by tests/scripts/test-lead-merge.sh, never executed).
BASE="$(mktemp -d "${TMPDIR:-/tmp}/lead-merge-test.XXXXXX")"
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
acc "B3 start marker followed by text is a prose mention, read by the lax union: the open box before it refuses (rc 1)" 1 "unchecked" "$(accb "$REAL_OPEN0" "$S0 x" "$E0")"
acc "B3 start marker followed by a form feed is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" "$S0$FF" "$E0")"
acc "B3 start marker followed by a vertical tab is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" "$S0$VT" "$E0")"
acc "B3 end marker followed by two carriage returns is refused" 3 "$AMB" "$(accb "$S0" '- [ ] open' "$E0"$'\r\r')"
acc "B3 start marker with a no-break space inside is refused" 3 "$AMB" "$(accb "$REAL_OPEN0" '<!--'"$NB"'acceptance:start -->' "$E0")"
acc "B3 the refusal quotes no body content" 3 "$AMB" "$(accb "$REAL_OPEN0" "$NB"'``` ZZTOKENZZ' "$E0")"
err="$(printf '%s\n' "$(accb "$REAL_OPEN0" "$NB"'``` ZZTOKENZZ' "$E0")" | acceptance_check_body 2>&1 >/dev/null)"
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

# F1: a marker pair whose start marker is only indented or preceded by text is still read, as the lib did before #202 (lax pattern
# `<!--[[:space:]]*acceptance:start[[:space:]]*-->` anywhere in a line outside a fence): an open box in it refuses even when a later exact pair is empty or ticked
SPACED_S=" $S0"; TEXT_S="x $S0"
acc "F1 an indented start marker holds an open box, a later exact pair is empty -> rc 1" 1 "unchecked" "$(accb "$SPACED_S" '- [ ] open' "$E0" "$S0" "$E0")"
acc "F1 an indented start marker holds an open box, a later exact pair is ticked -> rc 1" 1 "unchecked" "$(accb "$SPACED_S" '- [ ] open' "$E0" "$REAL_OK0")"
acc "F1 a start marker preceded by text holds an open box, a later exact pair is ticked -> rc 1" 1 "unchecked" "$(accb "$TEXT_S" '- [ ] open' "$E0" "$REAL_OK0")"
acc "F1 a start marker followed by text holds an open box, a later exact pair is ticked -> rc 1" 1 "unchecked" "$(accb "$S0 x" '- [ ] open' "$E0" "$REAL_OK0")"
acc "F1 a tab-indented start marker holds an open box -> rc 1" 1 "unchecked" "$(accb $'\t'"$S0" '- [ ] open' "$E0" "$REAL_OK0")"
acc "F1 an indented start marker, everything ticked -> rc 0" 0 "" "$(accb "$SPACED_S" '- [x] a' "$E0" "$REAL_OK0")"
acc "F1 a start marker preceded by text, everything ticked -> rc 0" 0 "" "$(accb "$TEXT_S" '- [x] a' "$E0" "$REAL_OK0")"
acc "F1 an open box after a lax end marker is outside the pair -> rc 0" 0 "" "$(accb "$SPACED_S" '- [x] a' "x $E0" '- [ ] outside' "$REAL_OK0")"
acc "F1 an inline mention of the start marker opens a pair like before #202: the open box after it refuses" 1 "unchecked" "$(accb 'see `'"$S0"'` here' '- [ ] open' "$E0" "$REAL_OK0")"
acc "F1 an inline mention with nothing open after it is accepted" 0 "" "$(accb 'see `'"$S0"'` here' 'prose' "$REAL_OK0")"
acc "F1 a lax pair inside a fence is ignored, an open box in it too -> rc 0" 0 "" "$(accb '```' "$SPACED_S" '- [ ] example' "$E0" '```' "$REAL_OK0")"
acc "F1 a lax pair inside a ~~~ fence after a ticked pair -> rc 0" 0 "" "$(accb "$REAL_OK0" '~~~' "$TEXT_S" '- [ ] example' "$E0" '~~~')"
# F2: a NUL byte makes the shell (which drops it) and the engine (which keeps it) read the fences differently: refused before any capture
accn() { # name want-rc stderr-substring printf-format
  local name="$1" want="$2" sub="$3" err rc tmpd="$BASE/nul-tmp"
  mkdir -p "$tmpd"
  err="$(printf "$4" | TMPDIR="$tmpd" acceptance_check_body 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$sub" ] || case "$err" in *"$sub"*) true ;; *) false ;; esac; } && [ -z "$(ls -A "$tmpd")" ]; then
    ok "fenced-example lib: $name"
  else
    bad "fenced-example lib: $name (rc=$rc want $want, stderr: $err, tmp left: $(ls -A "$tmpd" | tr '\n' ' '))"
  fi
}
NUL_HEAD='<!-- acceptance:start -->\n- [x] a\n<!-- acceptance:end -->\n'
NUL_OPEN='<!-- acceptance:start -->\n- [ ] open\n<!-- acceptance:end -->\n'
accn "F2 a NUL byte hides a second, open pair behind a backtick run -> rc 3, ambiguous (NUL byte)" 3 "NUL byte" "$NUL_HEAD"'`\0``\n'"$NUL_OPEN"
accn "F2 a NUL byte in an ordinary line -> rc 3" 3 "NUL byte" "$NUL_HEAD"'a\0b\n'
accn "F2 a NUL byte as the last byte -> rc 3" 3 "NUL byte" "$NUL_HEAD"'\0'
accn "F2 a NUL byte before the block -> rc 3" 3 "NUL byte" '\0\n'"$NUL_HEAD"
accn "F2 no NUL byte, ticked block -> rc 0, temporary file removed" 0 "" "$NUL_HEAD"
accn "F2 no NUL byte, open box -> rc 1, temporary file removed" 1 "unchecked" "$NUL_OPEN"
accn "F2 no block, no NUL byte -> rc 3, temporary file removed" 3 "markers missing" 'nothing here\n'
err="$(printf '%s\n' "$REAL_OK0" | TMPDIR="$BASE/no-such-dir" acceptance_check_body 2>&1 >/dev/null)"; rc=$?
if [ "$rc" = 3 ] && case "$err" in *"temporary file"*) true ;; *) false ;; esac; then ok "fenced-example lib: F2 no usable temporary directory -> rc 3 (fail-closed)"; else bad "fenced-example lib: F2 no usable temporary directory (rc=$rc, stderr: $err)"; fi
# F3: only a character the engine trims, or a control byte, makes a fence/marker line ambiguous; accents, emoji, dashes and arrows do not;
# a prose line that merely mentions the markers is not a marker line
ARROW=$'\xe2\x86\x92'; EMD=$'\xe2\x80\x94'; ACC=$'\xc3\xa9'
acc "F3 a backticked acceptance:start next to an em dash, outside the block -> rc 0" 0 "" "$(accb "- the gate reads \`acceptance:start\` $EMD as the engine" "$REAL_OK0")"
acc "F3 the same line inside the block -> rc 0" 0 "" "$(accb "$S0" "- the gate reads \`acceptance:start\` $EMD as the engine" '- [x] a' "$E0")"
acc "F3 a proof line with an arrow inside the block -> rc 0" 0 "" "$(accb "$S0" "- [x] <!-- ac:1 --> \`grep -c \"acceptance:\" f\` $ARROW 3" "$E0")"
acc "F3 the same proof line, box open -> rc 1" 1 "unchecked" "$(accb "$S0" "- [ ] <!-- ac:1 --> \`grep -c \"acceptance:\" f\` $ARROW 3" "$E0")"
acc "F3 a fence whose info string carries an accent opens a fence, hides the open pair after a ticked one -> rc 0" 0 "" "$(accb "$REAL_OK0" "\`\`\`swift $ACC" "$S0" '- [ ] example' "$E0" '```')"
acc "F3 a prose line in column 0 that mentions both markers -> rc 0" 0 "" "$(accb "$S0 and $E0 delimit it" "$REAL_OK0")"
acc "F3 the same prose line after a ticked block -> rc 0" 0 "" "$(accb "$REAL_OK0" "$S0 and $E0 delimit it")"
acc "F3 an ordinary body with accents, emoji, dashes and arrows around fences -> rc 0" 0 "" "$(accb "R${ACC}sum${ACC} $ARROW ${EMD} \`\`\`not a fence\`\`\`" '```text '"$ACC" "a $ARROW b" '```' "$REAL_OK0" "fin $EMD ${ACC}")"
acc "F3 a closing fence followed by a carriage return after the CRLF one stays ambiguous -> rc 3" 3 "$AMB" "$(accb "$S0" '- [x] a' "$E0" '```' x $'```\r\r' "$S0" '- [ ] open' "$E0")"
acc "F3 a fence indented by U+0085 stays ambiguous -> rc 3" 3 "$AMB" "$(accb "$REAL_OK0" $'\xc2\x85''```' "$S0" "$E0" '```')"
acc "F3 a fence line holding U+202F stays ambiguous -> rc 3" 3 "$AMB" "$(accb "$REAL_OK0" $'```\xe2\x80\xaf' "$S0" '- [ ] open' "$E0")"
acc "F3 a marker line holding U+2009 stays ambiguous -> rc 3" 3 "$AMB" "$(accb "$S0" '- [ ] open' "$E0"$'\xe2\x80\x89')"
acc "F3 a marker line holding a control byte stays ambiguous -> rc 3" 3 "$AMB" "$(accb "$S0" '- [ ] open' "$E0"$'\x1b')"
acc "F3 a lone marker with unusual spacing stays ambiguous -> rc 3" 3 "$AMB" "$(accb "$REAL_OK0" '<!--   acceptance:end   -->')"

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
const filler = () => pick(["", "text", "## What this ships", "    ```", "\f```", "```\f", "``` x", "````", "~~~~", "<!--acceptance:start-->", "<!--  acceptance:end -->", "  <!-- acceptance:start -->", "<!-- acceptance:start --> x", "<!-- acceptance:end -->\f", "<!-- acceptance:start -->\v",
  " <!-- acceptance:start -->", "x <!-- acceptance:start -->", "see `<!-- acceptance:start -->` here", "<!-- acceptance:end --> x", "<!-- acceptance:start --> and <!-- acceptance:end --> delimit it", "R\u00e9sum\u00e9 \u2014 \u2192 \u2705",
  "```swift \u00e9", "- the gate reads `acceptance:start` \u2014 as the engine", "```\r\r", "`\0``", "\u00a0```", "```\u2003", "~~~\u202f", "\u3000<!-- acceptance:start -->"])
const pair = () => { const out = [marker("start")]; for (let k = Math.floor(rnd() * 3); k > 0; k--) out.push(rnd() < 0.5 ? "- [x] <!-- ac:" + k + " --> a" : box()); out.push(marker("end")); return out }
const laxPair = () => [pick([" ", "x ", "\t", "  ", "- "]) + "<!-- acceptance:start -->", box(), pick(["<!-- acceptance:end -->", "y <!-- acceptance:end -->", " <!-- acceptance:end -->"])]
const segment = () => {
  const r = rnd()
  if (r < 0.34) return pair()
  if (r < 0.62) return [fenceLine(), ...(rnd() < 0.7 ? pair() : [box()]), ...(rnd() < 0.8 ? [fenceLine()] : [])]
  if (r < 0.72) return [marker(pick(["start", "end"]))]
  if (r < 0.80) return [box()]
  if (r < 0.88) return laxPair()
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
const { acceptanceSpan, fenceAfter } = new Function(m + ";return { acceptanceSpan, fenceAfter }")()
const openRe = /^[ \t\n\v\f\r]*-[ \t\n\v\f\r]*\[ \]/
// the reading the lib had before #202, outside fences: a pair opens on any line holding the lax start marker, closes on the lax end marker
const laxOpen = (body) => {
  let fence = "", oin = false
  for (const raw of body.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw
    const next = fenceAfter(line, fence)
    if (fence === "" && next === "") {
      if (/<!--[ \t\n\v\f\r]*acceptance:end[ \t\n\v\f\r]*-->/.test(line)) oin = false
      else if (oin && openRe.test(line)) return true
      if (/<!--[ \t\n\v\f\r]*acceptance:start[ \t\n\v\f\r]*-->/.test(line)) oin = true
    }
    fence = next
  }
  return false
}
let permissive = 0, closedOk = 0, openRefused = 0, noBlockRefused = 0, refusedAmbiguous = 0, badRc = 0, laxRefused = 0
const first = []
for (const l of fs.readFileSync(rcs, "utf8").trim().split("\n")) {
  const [f, rcs0] = l.split(" ")
  const rc = Number(rcs0)
  const body = fs.readFileSync(dir + "/" + f, "utf8").replace(/\n+$/, "") + "\n"
  const sp = acceptanceSpan(body)
  let verdict = "none"
  if (sp) { const t = body.slice(sp.from, sp.to).split("\n"); t.shift(); t.pop(); verdict = t.some((x) => openRe.test(x)) ? "open" : "closed" }
  if (rc !== 0 && rc !== 1 && rc !== 3) badRc++
  const lax = laxOpen(body)
  if (rc === 0 && (verdict !== "closed" || lax)) { permissive++; if (first.length < 3) first.push(f + " engine=" + verdict + " lax=" + lax) }
  else if (rc === 0) closedOk++
  else if (rc === 1 && lax && verdict !== "open") laxRefused++
  else if (verdict === "open" && rc === 1) openRefused++
  else if (verdict === "none" && rc === 3) noBlockRefused++
  else refusedAmbiguous++
}
console.log("permissive=" + permissive + " badrc=" + badRc + " closed_ok=" + closedOk + " open_refused=" + openRefused + " noblock_refused=" + noBlockRefused + " stricter=" + refusedAmbiguous + " lax_refused=" + laxRefused + " " + first.join(","))
JS
  res="$(node "$BASE/cmp.cjs" "$ROOT" "$GEN" "$BASE/gen.rcs" 2>&1)"
  n_gen="$(ls "$GEN" | wc -l | tr -d ' ')"
  case "$res" in
    *"permissive=0 badrc=0 "*)
      co="${res#*closed_ok=}"; co="${co%% *}"; orf="${res#*open_refused=}"; orf="${orf%% *}"
      lr="${res#*lax_refused=}"; lr="${lr%% *}"
      if [ "$n_gen" -ge 300 ] && [ "$co" -ge 20 ] && [ "$orf" -ge 20 ] && [ "$lr" -ge 5 ]; then
        ok "fenced-example generated parity: $n_gen bodies, the shell is never more permissive than the engine or the pre-#202 lax reading ($res)"
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

