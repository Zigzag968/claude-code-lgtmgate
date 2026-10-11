#!/usr/bin/env bash
# Self-test of scripts/consumer-defects.sh (#431). Offline: a fake `gh` on PATH prints a canned listing and logs its argv.
# The listing is the output of the script's own `--jq` filter, one `number<TAB>state<TAB>created_at` line per issue, as
# observed on the real repository ("426<TAB>open<TAB>2026-10-11T09:54:20Z", "412<TAB>closed<TAB>2026-10-11T08:22:17Z").
# Tags come from a throwaway git repository under $TMPDIR with controlled commit dates. Nothing touches the real tree.
# bash 3.2 compatible. Trailer: [test-consumer-defects] status=<ok|fail> passed=<n> failed=<n>
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
SCRIPT="$ROOT/scripts/consumer-defects.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/consumer-defects-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
[ -z "${FAKE_RC:-}" ] || { echo "fake gh: HTTP 502" >&2; exit "$FAKE_RC"; }
cat "$FAKE_ISSUES"
FAKE
chmod +x "$TMP/bin/gh"
FAKE_LOG="$TMP/gh.log"; : > "$FAKE_LOG"; export FAKE_LOG

# repo <dir> [tag date]...: a git repository with one commit per "tag date" pair, tagged (lightweight) at that date
mkrepo() {
  local dir="$1"; shift
  git init -q "$dir"
  ( cd "$dir" && git config user.email t@t && git config user.name t )
  while [ $# -ge 2 ]; do
    ( cd "$dir" && echo "$1" > f && git add f && GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git commit -qm "$1" && git tag "$1" )
    shift 2
  done
}
# issues <file> <number state created_at>...: the canned listing, tab separated
issues() {
  local f="$1"; shift
  : > "$f"
  while [ $# -ge 3 ]; do printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$f"; shift 3; done
}
OUT=""; RC=0
# run <repo dir> <issues file> [args...]: OUT = stdout+stderr, RC = exit code
run() {
  local dir="$1" f="$2"; shift 2
  OUT="$(cd "$dir" && PATH="$TMP/bin:$PATH" FAKE_ISSUES="$f" bash "$SCRIPT" "$@" 2>&1)"; RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
last_line() { printf '%s\n' "$OUT" | tail -n 1; }

mkrepo "$TMP/r" v1.0.0 2026-10-05T12:00:00Z v1.2.0 2026-10-09T12:00:00Z
issues "$TMP/l1" \
  5 closed 2026-09-29T08:00:00Z \
  12 closed 2026-09-29T20:00:00Z \
  249 closed 2026-10-05T11:59:59Z \
  252 closed 2026-10-06T09:00:00Z \
  338 closed 2026-10-08T09:00:00Z \
  405 closed 2026-10-10T09:00:00Z \
  421 open 2026-10-11T09:36:01Z \
  426 open 2026-10-11T09:54:20Z

# T1 windows by release: one line per window, counts, open, last date, and the total line
run "$TMP/r" "$TMP/l1"
if [ "$RC" -eq 0 ] \
  && has '[consumer-defects] window=v1.0.0 from=- to=2026-10-05 created=3 open=0 last=2026-10-05' \
  && has '[consumer-defects] window=v1.2.0 from=2026-10-05 to=2026-10-09 created=2 open=0 last=2026-10-08' \
  && has '[consumer-defects] window=unreleased from=2026-10-09 to=- created=3 open=2 last=2026-10-11' \
  && [ "$(last_line)" = '[consumer-defects] total=8 open=2 last=2026-10-11' ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 4 ]; then
  ok "T1 one line per release window with created, open and last, then the total line"
else bad "T1 rc=$RC $OUT"; fi

# T2 an issue created before the first tag belongs to the first window; the tag instant itself belongs to its window
if has 'window=v1.0.0 from=- to=2026-10-05 created=3'; then ok "T2 issues before the first tag, or at its instant, fall in the first window"; else bad "T2 $OUT"; fi

# T3 no matching issue: every window at zero, total=0
: > "$TMP/l3"
run "$TMP/r" "$TMP/l3"
if [ "$RC" -eq 0 ] && has 'window=v1.0.0 from=- to=2026-10-05 created=0 open=0 last=-' && [ "$(last_line)" = '[consumer-defects] total=0 open=0 last=-' ]; then ok "T3 no matching issue prints total=0 and exits 0"; else bad "T3 rc=$RC $OUT"; fi

# T4 the listing cannot be read: exit 2, no total line
FAKE_RC=1 run "$TMP/r" "$TMP/l1"
if [ "$RC" -eq 2 ] && has 'cannot read the issues listing' && ! has 'total='; then ok "T4 a listing that cannot be read exits 2 without a total line"; else bad "T4 rc=$RC $OUT"; fi

# T5 a listing line that is not number/state/date: exit 2
printf 'not a listing\n' > "$TMP/l5"
run "$TMP/r" "$TMP/l5"
if [ "$RC" -eq 2 ] && has 'unexpected line'; then ok "T5 an unreadable listing line exits 2"; else bad "T5 rc=$RC $OUT"; fi

# T6 no tag at all: one unreleased window holds everything
mkrepo "$TMP/notags"
( cd "$TMP/notags" && echo x > f && git add f && git commit -qm x )
run "$TMP/notags" "$TMP/l1"
if [ "$RC" -eq 0 ] && has 'window=unreleased from=- to=- created=8 open=2 last=2026-10-11' && [ "$(last_line)" = '[consumer-defects] total=8 open=2 last=2026-10-11' ]; then ok "T6 a repository without tags has one unreleased window"; else bad "T6 rc=$RC $OUT"; fi

# T7 not a git repository: the tags cannot be read, exit 2
mkdir -p "$TMP/nogit"
run "$TMP/nogit" "$TMP/l1"
if [ "$RC" -eq 2 ] && has 'cannot read the tags'; then ok "T7 a directory that is not a repository exits 2"; else bad "T7 rc=$RC $OUT"; fi

# T8 options: --label and --repo reach the request, an unknown option exits 2
: > "$FAKE_LOG"
run "$TMP/r" "$TMP/l1" --label x-label --repo o/n
if [ "$RC" -eq 0 ] && grep -qF 'repos/o/n/issues?labels=x-label&state=all' "$FAKE_LOG"; then ok "T8 --label and --repo build the request"; else bad "T8 rc=$RC $(cat "$FAKE_LOG")"; fi
run "$TMP/r" "$TMP/l1" --bogus
if [ "$RC" -eq 2 ]; then ok "T8b an unknown option exits 2"; else bad "T8b rc=$RC $OUT"; fi

# T9 read-only: every gh call of every case is one paginated GET on the issues listing, never GraphQL or a write
if [ -s "$FAKE_LOG" ] && ! grep -vE '^api --paginate repos/[^ ]+/issues\?labels=[^ ]+&state=all&per_page=100 --jq ' "$FAKE_LOG" | grep -q . \
  && ! grep -qE 'graphql|-X|--method|--field|-f |issue |pr ' "$FAKE_LOG"; then
  ok "T9 read-only: every gh call is a paginated GET on the issues listing"
else bad "T9 gh saw: $(sort -u "$FAKE_LOG" | tr '\n' ';')"; fi
if ! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE 'graphql|gh (issue|pr|project)|-X (POST|PATCH|PUT|DELETE)|git (fetch|push|tag -)'; then
  ok "T9b the script holds no GraphQL call, no gh issue/pr/project and no write"
else bad "T9b the script mentions a GraphQL call or a write"; fi

RESULT=ok; [ "$FAIL" -eq 0 ] || RESULT=fail
echo "[test-consumer-defects] status=${RESULT} passed=${PASS} failed=${FAIL}"
[ "$FAIL" -eq 0 ]
