#!/usr/bin/env bash
# Offline test of eval-results freshness by content (#454): scripts/eval-digest.cjs and the committed-summary
# path of scripts/gate-check.sh. Real git merges in throwaway repos. No claude call, no network. bash 3.2 safe.
# Usage: test-eval-freshness.sh [merge|agents|gate-check]   (none = all)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_BASE="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK="$(mktemp -d "$TMP_BASE/eval-freshness-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
DIGEST="$ROOT/scripts/eval-digest.cjs"
GC="$ROOT/scripts/gate-check.sh"
WANT="${1:-all}"

pass_count=0
fail_count=0
check() {
  local name="$1" ok="$2"
  if [ "$ok" -eq 1 ]; then echo "PASS - $name"; pass_count=$((pass_count + 1))
  else echo "FAIL - $name"; fail_count=$((fail_count + 1)); fi
}
want() { [ "$WANT" = "all" ] || [ "$WANT" = "$1" ]; }
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

# chk <file> [root]: sets COUT and CRC
chk() { COUT="$(node "$DIGEST" --root "${2:-$REPO}" --check "$1" 2>&1)"; CRC=$?; }

mkrepo() {
  REPO="$1"
  mkdir -p "$REPO"
  git init -q -b main "$REPO" >/dev/null 2>&1 || { git init -q "$REPO"; g checkout -q -b main; }
  local d
  for d in evals templates hooks agents scripts docs; do mkdir -p "$REPO/$d"; echo "$d v1" > "$REPO/$d/x.md"; done
  echo root > "$REPO/README.md"
  g add -A; g commit -q -m base
  g checkout -q -b feature
}

if want merge; then
  mkrepo "$WORK/m"
  node "$DIGEST" --root "$REPO" --write "$WORK/m-summary.json" --gate PASS --line 'gate: ok' || true
  g checkout -q main
  echo "docs v2" > "$REPO/docs/x.md"; echo changed > "$REPO/README.md"
  g add -A; g commit -q -m "base moves"
  g checkout -q feature
  echo "feature note" > "$REPO/docs/feature.md"; g add -A; g commit -q -m "feature"
  head_before="$(git -C "$REPO" rev-parse HEAD)"
  g merge -q --no-ff -m "merge main" main
  head_after="$(git -C "$REPO" rev-parse HEAD)"
  chk "$WORK/m-summary.json"
  ok=0; [ "$head_before" != "$head_after" ] && [ "$CRC" -eq 0 ] && case "$COUT" in fresh:*) true ;; *) false ;; esac && ok=1
  check "merge: a merge of a base that changes none of the digest paths (new head) keeps the summary fresh" "$ok"
  # the results subtree is not part of the digest
  mkdir -p "$REPO/evals/results/c"; echo run1 > "$REPO/evals/results/c/aggregate-result.json"
  chk "$WORK/m-summary.json"
  ok=0; [ "$CRC" -eq 0 ] && ok=1
  check "merge: content under evals/results does not change the digest" "$ok"
fi

if want agents; then
  mkrepo "$WORK/a"
  node "$DIGEST" --root "$REPO" --write "$WORK/a-summary.json" --gate PASS --line 'gate: ok' || true
  echo "agents v2" > "$REPO/agents/x.md"; g add -A; g commit -q -m "edit agent"
  chk "$WORK/a-summary.json"
  ok=0; [ "$CRC" -eq 1 ] && case "$COUT" in stale:*) true ;; *) false ;; esac && ok=1
  check "agents: a changed file under agents/ after the summary -> stale, exit 1" "$ok"

  mkrepo "$WORK/s"
  node "$DIGEST" --root "$REPO" --write "$WORK/s-summary.json" --gate PASS --line 'gate: ok' || true
  echo "scripts v2" > "$REPO/scripts/x.md"
  chk "$WORK/s-summary.json"
  ok=0; [ "$CRC" -eq 1 ] && ok=1
  check "agents: a changed file under scripts/ -> stale" "$ok"

  mkrepo "$WORK/d"
  node "$DIGEST" --root "$REPO" --write "$WORK/d-summary.json" --gate PASS --line 'gate: ok' || true
  rm -f "$REPO/hooks/x.md"
  chk "$WORK/d-summary.json"
  ok=0; [ "$CRC" -eq 1 ] && ok=1
  check "agents: a deleted file under hooks/ -> stale" "$ok"

  chk "$WORK/absent.json"
  ok=0; [ "$CRC" -eq 2 ] && case "$COUT" in unreadable:*) true ;; *) false ;; esac && ok=1
  check "agents: an absent summary -> unreadable, exit 2" "$ok"
  echo 'not json' > "$WORK/bad.json"
  chk "$WORK/bad.json"
  ok=0; [ "$CRC" -eq 2 ] && ok=1
  check "agents: a non-JSON summary -> unreadable, exit 2" "$ok"
  echo '{"digest":"abc"}' > "$WORK/nodigest.json"
  chk "$WORK/nodigest.json"
  ok=0; [ "$CRC" -eq 2 ] && ok=1
  check "agents: a summary without a 64-hex digest -> unreadable, exit 2" "$ok"
fi

if want gate-check; then
  mkdir -p "$WORK/g/evals" "$WORK/g/docs/gate"
  cp -R "$ROOT"/evals/probe-* "$WORK/g/evals/"
  cp -R "$ROOT/fixtures" "$WORK/g/fixtures"
  node "$DIGEST" --root "$WORK/g" --write "$WORK/g/docs/gate/e2-eval.json" --gate PASS \
    --line 'gate: 30/30 fully passed runs (need >= 29/30) -> PASS'
  rm -rf "$WORK/other"
  cp -R "$WORK/g" "$WORK/other"
  gce() { # <root> [args]: sets GOUT
    local d="$1"; shift
    GOUT="$(env -u PROBE_EVALS_RESULTS_DIR GATE_ROOT="$d" bash "$GC" e2 "$@" 2>&1)"
  }
  eline() { printf '%s\n' "$GOUT" | grep -E '^(PASS|FAIL|SKIP) eval: '; }
  gce "$WORK/other"
  l="$(eline)"
  ok=0; case "$l" in "PASS eval: "*"recorded summary"*) case "$l" in *"no results dir"*) ;; *) ok=1 ;; esac ;; esac
  check "gate-check: a copy of the repo reads the committed docs/gate/e2-eval.json (PASS eval, no 'no results dir')" "$ok"

  echo "agents v2" >> "$WORK/other/evals/probe-provision/graders/extra-note.md"
  gce "$WORK/other"
  l="$(eline)"
  ok=0; case "$l" in "FAIL eval: "*stale*) ok=1 ;; esac
  check "gate-check: a changed digest path -> FAIL eval, stale" "$ok"
  gce "$WORK/other" --ci
  l="$(eline)"
  ok=0; case "$l" in "SKIP eval: "*stale*) ok=1 ;; esac
  check "gate-check: the same with --ci -> SKIP eval" "$ok"

  rm -rf "$WORK/other"; cp -R "$WORK/g" "$WORK/other"
  node "$DIGEST" --root "$WORK/other" --write "$WORK/other/docs/gate/e2-eval.json" --gate FAIL --line 'gate: 20/30 -> FAIL'
  gce "$WORK/other"
  l="$(eline)"
  ok=0; case "$l" in "FAIL eval: "*) ok=1 ;; esac
  check "gate-check: a record with gate FAIL -> FAIL eval" "$ok"

  rm -rf "$WORK/other"; cp -R "$WORK/g" "$WORK/other"
  echo 'not json' > "$WORK/other/docs/gate/e2-eval.json"
  gce "$WORK/other" --ci
  l="$(eline)"
  ok=0; case "$l" in "FAIL eval: "*malformed*) ok=1 ;; esac
  check "gate-check: a non-JSON record -> FAIL eval even with --ci" "$ok"
fi

echo "status=$([ "$fail_count" -eq 0 ] && echo pass || echo fail) pass=$pass_count fail=$fail_count"
[ "$fail_count" -eq 0 ]
