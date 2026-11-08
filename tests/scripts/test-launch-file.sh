#!/usr/bin/env bash
# Self-test of scripts/lib/launch-file.cjs and scripts/runtime/clean-launch-files.cjs (#605): the launch file of a run
# (`.pipeline/launch/<sha12>/#<N> - <title>.js`), the sanitiser that makes the file name, the flag the generator alone turns on, the
# engine that refuses to run without it, the path parser and the clean script. Throw-away trees under $TMPDIR, nothing committed.
# bash 3.2 compatible. Prints `ok: <name>` per case and a last line `[test-launch-file] status=<ok|fail> passed=<n> failed=<m>`.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
CLEAN="$ROOT/scripts/runtime/clean-launch-files.cjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/launch-file-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# cases <js body>: a node program that prints `ok: ...` / `FAIL: ...` lines (the helpers `lib`, `source`, `check` are in scope)
cases() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "ok: "*) PASS=$((PASS+1)); echo "$line" ;;
      *) FAIL=$((FAIL+1)); echo "FAIL: ${line#FAIL: }" ;;
    esac
  done < <(node -e '
const fs = require("fs")
const root = process.argv[1]
const lib = require(root + "/scripts/lib/launch-file.cjs")
const source = fs.readFileSync(root + "/workflows/deliver-pipeline.js", "utf8")
const tmp = process.argv[2]
const check = (name, condition) => console.log((condition ? "ok: " : "FAIL: ") + name)
'"$1" "$ROOT" "$TMP" 2>&1)
}

# ---- shape of the file ---------------------------------------------------------------------------------
cases '
const project = tmp + "/shape"
const bytes = lib.retitle(source, 605, { title: "One launch form" })
const written = lib.ensureLaunchFile(project, bytes)
const sha = require("crypto").createHash("sha256").update(fs.readFileSync(written.path)).digest("hex")
const parts = written.path.slice(project.length + 1).split("/")
check("path: .pipeline/launch/<sha12>/#<N> - <title>.js with <sha12> the first 12 hex of the sha256 of the bytes", parts.length === 4 && parts[0] === ".pipeline" && parts[1] === "launch" && parts[2] === sha.slice(0, 12) && parts[3] === "#605 - One launch form.js")
check("path: no file of the previous issue-<N>- shape is written", !parts[3].startsWith("issue-") && fs.readdirSync(project + "/.pipeline/launch").every((n) => /^[0-9a-f]{12}$/.test(n)))
check("name: the file name is the meta name of the copy for a plain title", lib.metaName(bytes) === "#605 - One launch form" && parts[3] === lib.metaName(bytes) + ".js")
check("path: a second write returns the same path and keeps the file", lib.ensureLaunchFile(project, bytes).path === written.path)
fs.appendFileSync(written.path, "\n")
check("path: a file edited after it was written is denied by name", lib.ensureLaunchFile(project, bytes).denied === parts[3])
check("path: a bare #<N> label when there is no title", lib.labelFileName(lib.retitle(source, 7)) === "#7.js")
const parsed = lib.parseLaunchPath(written.path)
check("parse: the written path parses to its digest and issue", parsed !== null && parsed.digest === sha.slice(0, 12) && parsed.issue === 605)
'

# ---- the sanitiser -------------------------------------------------------------------------------------
cases '
const PRINTABLE = /^[^\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}\p{Zl}\p{Zp}\ufe00-\ufe0f]+$/u
const nameOf = (title) => lib.labelFileName(lib.retitle(source, 12, { title }))
const hostile = { "/": "slash", "\\": "backslash", ":": "colon", "*": "asterisk", "?": "question mark", "\"": "double quote", "<": "less-than", ">": "greater-than", "|": "vertical bar" }
for (const [character, label] of Object.entries(hostile)) {
  const name = nameOf("a" + character + "b")
  check("sanitiser: " + label + " becomes a dash, printable-only name", name === "#12 - a-b.js" && PRINTABLE.test(name))
}
const invisible = { "U+061C": "\u061c", "U+00AD": "\u00ad", "U+E0041": "\u{e0041}", "U+FE0F": "\ufe0f", "U+180E": "\u180e", "U+2061": "\u2061", "U+FFF9": "\ufff9", "a lone surrogate": "\ud800" }
for (const [label, character] of Object.entries(invisible)) {
  const name = nameOf("a" + character + "b")
  check("sanitiser: " + label + " is removed, printable-only name", name === "#12 - ab.js" && PRINTABLE.test(name))
}
check("sanitiser: line and paragraph separators become one space", nameOf("a\u2028b\u2029c") === "#12 - a b c.js")
check("sanitiser: a title with a control character gives no launch copy (the REST path cleans it before)", lib.retitle(source, 12, { title: "a\u0007b" }) === null && nameOf(lib.cutTitle("a\u0007b", 80)) === "#12 - a b.js")
check("sanitiser: accented letters and emoji stay", nameOf("caf\u00e9 \u{1F680}") === "#12 - caf\u00e9 \u{1F680}.js")
check("sanitiser: trailing dots and spaces are stripped", nameOf("end...  ") === "#12 - end.js")
const wide = nameOf("\u00e9".repeat(100))
const title81 = nameOf("x".repeat(81))
check("sanitiser: the name is cut at 80 bytes (an 81-byte title, a multi-byte title)", Buffer.byteLength(wide.slice(0, -3), "utf8") <= 80 && Buffer.byteLength(title81.slice(0, -3), "utf8") <= 80 && wide.endsWith(".js"))
check("sanitiser: a cut never splits a code point", !wide.includes("\ufffd") && PRINTABLE.test(wide))
check("sanitiser: a quote and a backslash in the title stay valid JS in the meta and safe in the name", (() => {
  const quote = String.fromCharCode(39)
  const bytes = lib.retitle(source, 12, { title: "it" + quote + "s a \\ title" })
  fs.writeFileSync(tmp + "/q.js", bytes)
  return lib.labelFileName(bytes) === "#12 - it" + quote + "s a - title.js"
})())
'
if node --check "$TMP/q.js" 2>/dev/null; then ok "sanitiser: the copy with a quote and a backslash is valid JS"; else bad "sanitiser: the copy with a quote and a backslash is not valid JS"; fi

# ---- the flag ------------------------------------------------------------------------------------------
if [ "$(grep -c '^const LAUNCH_FILE_GENERATED = false$' "$ROOT/workflows/deliver-pipeline.js")" = 1 ] && [ "$(grep -c 'const LAUNCH_FILE_GENERATED = ' "$ROOT/workflows/deliver-pipeline.js")" = 1 ]; then ok "flag: the shipped engine holds exactly one flag line, off"; else bad "flag: the shipped engine flag line"; fi
cases '
const on = "const LAUNCH_FILE_GENERATED = true"
const off = "const LAUNCH_FILE_GENERATED = false"
const generated = lib.retitle(source, 12, { title: "T" })
check("flag: retitle (the generator) turns the flag on and changes nothing else of the flag line", generated.includes("\n" + on + "\n") && !generated.includes(off))
check("flag: markGenerated flips the flag and only that line", lib.markGenerated(source) === source.replace(off, on))
check("flag: markGenerated is idempotent", lib.markGenerated(lib.markGenerated(source)) === lib.markGenerated(source))
check("flag: retitle is idempotent on a generated copy", lib.retitle(generated, 12, { title: "T" }) === generated)
const noFlag = source.replace(off + "\n", "")
check("flag: a source with no flag line (an old engine copy) passes through unchanged", lib.markGenerated(noFlag) === noFlag && lib.retitle(noFlag, 12, { title: "T" }) !== null && !lib.retitle(noFlag, 12, { title: "T" }).includes(on))
const two = source.replace(off + "\n", off + "\n" + off + "\n")
check("flag: two flag lines give null from both functions", lib.markGenerated(two) === null && lib.retitle(two, 12, { title: "T" }) === null)
const idented = source.replace(off, "  " + off)
check("flag: an indented or suffixed flag line is not the flag", lib.markGenerated(idented) === idented && lib.markGenerated(source.replace(off, off + " // x")) === source.replace(off, off + " // x"))
'
if [ "$(grep -rlF LAUNCH_FILE_GENERATED "$ROOT/workflows" "$ROOT/scripts" | sed "s#^$ROOT/##" | sort | tr '\n' ' ')" = "scripts/lib/launch-file.cjs workflows/deliver-pipeline.js " ]; then ok "flag: single writer (only the engine and scripts/lib/launch-file.cjs name the flag)"; else bad "flag: single writer"; fi

# ---- the engine refuses to run without the flag ------------------------------------------------------
cases '
const strip = (text) => text.replace(/^export\s+/mg, "")
const runner = (text) => {
  const calls = []
  const fn = new Function("args", "agent", "log", "phase", "return (async () => {\n" + strip(text) + "\n})()")
  return { calls, run: (a) => fn(a, async () => { calls.push(1); throw new Error("agent called") }, () => {}, () => {}) }
}
const args = { issue: 12, brief: "x", worktreePath: "/wt", pluginRoot: "/p", config: { branchPrefix: "f/" }, mode: "auto", dryRun: true }
const raw = runner(source)
raw.run(args).then(() => check("self-refusal: the raw engine is refused with engine-launch-form before any agent call", false), (error) => {
  check("self-refusal: the raw engine is refused with engine-launch-form before any agent call", /^engine-launch-form: /.test(error.message) && error.message.includes("(engine-launch-form).") && raw.calls.length === 0)
}).then(() => raw.run(undefined)).then(() => check("self-refusal: a malformed args still gives the form error first", false), (error) => {
  check("self-refusal: a malformed args still gives the form error first", /^engine-launch-form: /.test(error.message))
}).then(() => {
  const generated = runner(lib.retitle(source, 12, { title: "T" }))
  return generated.run(args).then((result) => check("dryrun-generated-copy-ok (the generated copy evaluated with dryRun returns dry-run-ok)", result && result.status === "dry-run-ok" && generated.calls.length === 0), (error) => check("dryrun-generated-copy-ok (threw " + error.message + ")", false))
}).then(() => {
  const marked = runner(lib.markGenerated(source))
  return marked.run(args).then((result) => check("self-refusal: a copy whose flag is set through markGenerated runs", result && result.status === "dry-run-ok"), () => check("self-refusal: a copy whose flag is set through markGenerated runs", false))
})
'

# ---- path parser and git state -----------------------------------------------------------------------
cases '
const good = "/p/.pipeline/launch/0123456789ab/#5 - a title.js"
const parsed = lib.parseLaunchPath(good)
check("parse: a path of the generated shape gives its digest and issue", parsed && parsed.digest === "0123456789ab" && parsed.issue === 5)
check("parse: a bare #<N>.js parses", lib.parseLaunchPath("/p/.pipeline/launch/0123456789ab/#5.js").issue === 5)
const negatives = {
  "a digest of 11 hex": "/p/.pipeline/launch/0123456789a/#5 - a.js",
  "a digest of 13 hex": "/p/.pipeline/launch/0123456789abc/#5 - a.js",
  "an upper-case digest": "/p/.pipeline/launch/0123456789AB/#5 - a.js",
  "no launch directory": "/p/.pipeline/other/0123456789ab/#5 - a.js",
  "no .pipeline directory": "/p/pipeline/launch/0123456789ab/#5 - a.js",
  "a legacy issue-<N>- name": "/p/.pipeline/launch/issue-5-0123456789ab.js",
  "a poc basename": "/p/x/#999 - poc c basename.js",
  "issue 0": "/p/.pipeline/launch/0123456789ab/#0 - a.js",
  "an unsafe issue number": "/p/.pipeline/launch/0123456789ab/#99999999999999999999 - a.js",
  "no .js extension": "/p/.pipeline/launch/0123456789ab/#5 - a.txt",
  "no space-dash-space": "/p/.pipeline/launch/0123456789ab/#5 a.js",
  "a directory only": "/p/.pipeline/launch/0123456789ab",
  "an empty string": "",
}
for (const [label, path] of Object.entries(negatives)) check("parse: " + label + " is not the generated shape", lib.parseLaunchPath(path) === null)
check("parse: a non-string is not the generated shape", lib.parseLaunchPath(undefined) === null && lib.parseLaunchPath(5) === null)
check("marker: the engine marker matches the engine and nothing like a foreign script", lib.ENGINE_MARKER_RE.test(source) && !lib.ENGINE_MARKER_RE.test("const PHASE_TITLES = 1\nconsole.log(1)"))
'
mkdir -p "$TMP/g-ignored" "$TMP/g-open" "$TMP/g-none"
git init -q "$TMP/g-ignored"; printf '.pipeline/\n' > "$TMP/g-ignored/.gitignore"; git init -q "$TMP/g-open"
GIT_CEILING_DIRECTORIES="$TMP" cases '
check("git: an ignored .pipeline/ is ignored", lib.ignoredState(tmp + "/g-ignored", ".pipeline/launch/0123456789ab/x.js") === "ignored")
check("git: a repository without the ignore line is not-ignored", lib.ignoredState(tmp + "/g-open", ".pipeline/launch/0123456789ab/x.js") === "not-ignored")
check("git: a directory outside any repository is git-failed (128 included)", lib.ignoredState(tmp + "/g-none", ".pipeline/launch/0123456789ab/x.js") === "git-failed")
'

# ---- the clean script on the new layout --------------------------------------------------------------
C="$TMP/clean"; mkdir -p "$C/.pipeline/launch/aaaaaaaaaaaa" "$C/.pipeline/launch/bbbbbbbbbbbb" "$C/.pipeline/launch/cccccccccccc" "$TMP/elsewhere/dddddddddddd"
printf 'a' > "$C/.pipeline/launch/aaaaaaaaaaaa/#5 - five.js"
printf 'b' > "$C/.pipeline/launch/bbbbbbbbbbbb/#55 - fifty-five.js"
printf 'k' > "$C/.pipeline/launch/cccccccccccc/notes.txt"
printf 'l' > "$C/.pipeline/launch/issue-5-eeeeeeeeeeee.js"; printf 'm' > "$C/.pipeline/launch/issue-66-ffffffffffff.js"
printf 'k' > "$C/.pipeline/launch/keep.txt"; printf 'o' > "$C/.pipeline/other.txt"
printf 'x' > "$TMP/elsewhere/dddddddddddd/#9 - nine.js"
ln -s "$TMP/elsewhere/dddddddddddd" "$C/.pipeline/launch/dddddddddddd"
OUTC="$(node "$CLEAN" --root "$C" --issue 5)"
if [ "$OUTC" = "removed 2" ] && [ ! -e "$C/.pipeline/launch/aaaaaaaaaaaa" ] && [ ! -e "$C/.pipeline/launch/issue-5-eeeeeeeeeeee.js" ] && [ -e "$C/.pipeline/launch/bbbbbbbbbbbb/#55 - fifty-five.js" ] && [ -e "$C/.pipeline/launch/issue-66-ffffffffffff.js" ]; then ok "clean: one issue on the new layout (and the legacy file of that issue); #5 is not #55"; else bad "clean: one issue ($OUTC)"; fi
OUTC="$(node "$CLEAN" --root "$C")"
if [ "$OUTC" = "removed 2" ] && [ ! -e "$C/.pipeline/launch/bbbbbbbbbbbb" ] && [ -e "$C/.pipeline/launch/cccccccccccc/notes.txt" ]; then ok "clean: all issues; an emptied digest directory is removed, a directory with another file stays"; else bad "clean: all issues ($OUTC)"; fi
if [ -e "$C/.pipeline/launch/keep.txt" ] && [ -e "$C/.pipeline/other.txt" ] && [ -e "$TMP/elsewhere/dddddddddddd/#9 - nine.js" ]; then ok "clean: other files, other .pipeline content and a symlinked digest directory are left alone"; else bad "clean: kept files"; fi
rm "$C/.pipeline/launch/keep.txt" "$C/.pipeline/launch/cccccccccccc/notes.txt"; rmdir "$C/.pipeline/launch/cccccccccccc"; rm "$C/.pipeline/launch/dddddddddddd"
node "$CLEAN" --root "$C" >/dev/null
if [ ! -d "$C/.pipeline/launch" ] && [ -e "$C/.pipeline/other.txt" ]; then ok "clean: the launch directory is removed when empty, the rest of .pipeline/ stays"; else bad "clean: empty launch directory"; fi
L="$TMP/linked"; mkdir -p "$L/.pipeline" "$TMP/real-launch/aaaaaaaaaaaa"; printf 'x' > "$TMP/real-launch/aaaaaaaaaaaa/#1 - x.js"
ln -s "$TMP/real-launch" "$L/.pipeline/launch"
OUTC="$(node "$CLEAN" --root "$L")"
if [ "$OUTC" = "removed 0" ] && [ -e "$TMP/real-launch/aaaaaaaaaaaa/#1 - x.js" ]; then ok "clean: a symlinked launch directory is never followed"; else bad "clean: symlinked launch directory ($OUTC)"; fi
node "$CLEAN" --bogus >/dev/null 2>&1; if [ $? -eq 2 ]; then ok "clean: a bad flag exits 2"; else bad "clean: a bad flag exits 2"; fi
node "$CLEAN" --issue x >/dev/null 2>&1; if [ $? -eq 2 ]; then ok "clean: a non-numeric --issue exits 2"; else bad "clean: a non-numeric --issue exits 2"; fi

STATUS=ok; [ "$FAIL" -eq 0 ] || STATUS=fail
echo "[test-launch-file] status=${STATUS} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
