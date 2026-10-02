#!/usr/bin/env bash
# Lead merge gesture (#74): scripts/lead-merge.sh <pr> [-R owner/repo] [--tick-from-review]
# Run from a checkout of the PR head branch. Steps, each exit code checked:
#   1. acceptance checklist via scripts/lib/acceptance-check.sh (same lib as the merge hook):
#      any `- [ ]` between the acceptance markers, or missing markers, refuses.
#   1a. review freshness (#157, scripts/lib/review-check.sh, same lib as the merge hook): the latest
#      `<!-- pipeline-review-round pr=<N> sha=<40hex> -->` comment (Morgan's verdict; the squash note re-attests the
#      squashed head) must name the PR head as the API reports it before any script commit; refuses `FAIL: review-stale`.
#      A head holding only this script's own bump/merge commits after the reviewed sha (a re-run) is accepted.
#   1b. declared exceptions (#122): each `exception: <what> — <why> — #N` line between the acceptance markers
#      (optionally prefixed `- ` or `- [x] `; ` -- ` is accepted as separator too) must parse, name an OPEN issue
#      #N labelled `tech-debt` (REST), and the PR diff (`git diff origin/main...<remote head>`, added lines only) must hold a
#      `DEBT(#N)` marker. The gates 1b and 1b2 judge the remote head of the PR (fetched, checked against the head sha step 1a
#      read), never the local branch: step 2 may still fast-forward it. Any failure prints one `FAIL: declared-exception: <reason>` line and exits before any
#      fetch-merge, bump, push, checks or merge.
#      The `git fetch origin main` of this step is unconditional (the next step needs it too).
#   1b2. R2 waivers (#174): in an engine repo (`engineRepo: true` in .claude/pipeline.config.json on origin/main, never the
#      PR's copy), a PR that names (closing keyword or Refs, `#N`, `<this repo>#N` or its URL, anywhere in the PR body or in a
#      commit message of the PR) a `type:bug` issue and whose remote head changes `workflows/` (renames not detected; the
#      BUILD line the bump commit rewrites is not a change) must add or modify `fixtures/incidents/<N>-*.json` holding valid
#      JSON, unless a valid `exception:` line (1b) declares the waiver. Every issue found is checked; a gh error reading one
#      refuses. Otherwise one `FAIL: r2-waiver: <reason>` line and exit before any fetch-merge, bump, push, checks or merge.
#   2. sync: refuse unless on the PR head branch with a clean tree; fetch the head branch and
#      fast-forward when the remote is ahead (a previous partial run), refuse when diverged.
#   3. bring the base in LOCALLY: fetch origin/main, `git merge --no-edit origin/main`. On conflict:
#      abort the merge and die. Exception: when only the version files (plugin.json, BUILD line)
#      conflict (main bumped too), take main's copy; step 4 recomputes them. No `gh pr update-branch`:
#      the local merge already makes the branch current, and bumping before it always conflicted.
#   4. bump from the merged tree: next version over max(branch, origin/main) (semver 2.0.0 precedence: X.Y.Z -> patch+1,
#      X.Y.Z-beta.N -> X.Y.Z-beta.(N+1)) in .claude-plugin/plugin.json
#      + BUILD line of workflows/deliver-pipeline.js (cutFrom = origin/main short sha), commit
#      `chore: bump X (lead-merge)`. Idempotent: skipped when the branch is already above origin/main
#      via such a bump commit. Consumer repos (#145): no .claude-plugin/plugin.json in the merged tree ->
#      log `no plugin manifest, version bump skipped` and continue; BUILD line edited only when present.
#   5. push once (only when local HEAD differs from the remote head).
#   6. wait until the PR reports the pushed sha with at least one check (bounded poll, cli/cli#7401), then ask whether
#      main requires status checks (#156: classic protection, then rulesets; HTTP 403/404 = none; any other answer
#      refuses). Required (mode: required-checks): bounded wait for them to register, then
#      gh pr checks --watch --fail-fast --required. None (mode: no-required-checks): poll `gh pr checks --json` until
#      the head's checks are green, restricted to config.ciChecks when set. A timeout names the mode.
#   7. gh pr merge --merge --delete-branch (never the auto-merge flag).
#   8. read the PR back over REST (merged == true and merged_at set); only then close, with the comment
#      `Fixed by #<PR> (merged).`, each still-open issue named by a closing keyword (Closes/Fixes/Resolves #N,
#      same repo, parsed from the body read BEFORE the merge). `Refs #N` is never closed. A failed merge or a
#      PR not read back as merged exits non-zero and touches no issue (#109).
# --tick-from-review (#9): Morgan proved boxes but the auto-mode classifier refused his `gh pr edit` tick, so they stay
#   `- [ ]` (`verified-untickable`). With the flag, after step 1b and before the base merge, the script reads Morgan's
#   latest verdict comment, ticks the boxes it lists as proven, then RE-FETCHES the body and re-runs the step-1 gate,
#   which still refuses any box left open. Without the flag nothing changes (step 1 refuses first).
#   - Comment pick (REST `issues/<pr>/comments --paginate`): the LAST comment whose first line is exactly
#     `<!-- pipeline-review-round pr=<N> -->` (with or without ` sha=<40hex>`) AND that has at least 2 non-empty lines
#     after the marker (Nick's push-note reuses the marker but is one line, so it is skipped). None found: refused.
#   - Matching rule (exact, structured; Morgan's template line for a proven-untickable box):
#       `- [ ] **<box text verbatim>** — verified, tick pending (permissions): <proof with a `command` and its output>`
#     A box is ticked iff some line of that comment, after stripping the list prefix (`- `, `- [ ] `), `**` and backticks
#     and collapsing whitespace, equals the box text normalised the same way followed by an optional separator
#     (em dash, en dash, `-`, `--`, `:`) and `verified, tick pending (permissions): <proof>`, and the raw proof holds a
#     backtick-quoted command or the template form `<command> -> <output>`. Only boxes between the acceptance markers are considered; a `[human-gate]` box is never
#     ticked; an unmatched box stays open. The tick turns that line's `- [ ]` into `- [x]` and appends
#     ` — ticked by lead-merge from Morgan's review`. PATCH via REST (`pulls/<N>`).
#   - Limitation: index-style proofs ("Box 2: `cmd` -> out") and one line covering several boxes ("Boxes 1-4 verified")
#     are NOT matched (too loose to map to a box reliably): those boxes stay open and the merge is refused.
#   - Stale proofs: refused (`FAIL: tick-from-review: a push followed Morgan's verdict; re-review first`, nothing ticked)
#     when a marker comment (e.g. a Nick push-note) follows the chosen verdict, or when the PR head commit date
#     (REST `pulls/<N>` head sha -> `commits/<sha>` committer date) is later than the verdict's `created_at`.
# Afterwards prints the manual step to sync the local main. The PR itself never bumps: this script does.
# Env: LEAD_MERGE_POLL_MAX (default 30), LEAD_MERGE_POLL_SLEEP seconds (default 10).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/acceptance-check.sh
. "$SCRIPT_DIR/lib/acceptance-check.sh"
# shellcheck source=lib/review-check.sh
. "$SCRIPT_DIR/lib/review-check.sh"

MANIFEST=".claude-plugin/plugin.json"
WORKFLOW="workflows/deliver-pipeline.js"

die() { echo "lead-merge: $*" >&2; exit 1; }

PR=""; REPO=""; TICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) [ $# -ge 2 ] || die "$1 needs a value"; REPO="$2"; shift 2 ;;
    --tick-from-review) TICK=1; shift ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$PR" ] || die "unexpected argument: $1"; PR="$1"; shift ;;
  esac
done
case "$PR" in ''|*[!0-9]*) die "usage: scripts/lead-merge.sh <pr-number> [-R owner/repo] [--tick-from-review]" ;; esac

# Repo resolution: -R flag, else .claude/pipeline.config.json "repo", else gh repo view.
if [ -z "$REPO" ] && [ -f .claude/pipeline.config.json ]; then
  REPO="$(python3 -c "import json; print(json.load(open('.claude/pipeline.config.json')).get('repo',''))" 2>/dev/null || true)"
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die "cannot resolve the repo (pass -R owner/repo)"
fi
[ -n "$REPO" ] || die "cannot resolve the repo (pass -R owner/repo)"

# --- 1. acceptance checklist -------------------------------------------------
body="$(gh pr view "$PR" -R "$REPO" --json body -q .body)" || die "cannot read PR #$PR body"
# issue_refs <keyword alternation> <header|all> [<owner/repo>]: the issue numbers named by `<keyword> <ref>`. Input on stdin:
# text chunks separated by NUL (the PR body, then one chunk per commit message), each parsed on its own. Fenced code blocks
# and inline `code` spans are stripped before matching, so proofs quoting `Closes #N` never count. Case-insensitive,
# deduplicated. Scope `header` (#119): only the lines before the first `## ` line of a chunk (the PR body order puts
# `Closes #N` first); `all`: the whole chunk. Without <owner/repo> only `#N` matches (owner/repo#N never does); with it
# `#N`, `<owner/repo>#N` and `https://github.com/<owner/repo>/issues/N` match, a reference to another repo never does.
issue_refs() {
  KW="$1" SCOPE="$2" SAME_REPO="${3:-}" python3 -c '
import os, re, sys
ref = r"#(\d+)"
if os.environ["SAME_REPO"]:
    r = re.escape(os.environ["SAME_REPO"])
    ref = r"(?:#|" + r + r"#|https://github\.com/" + r + r"/issues/)(\d+)"
pat = re.compile(r"(?<![\w/])(?:" + os.environ["KW"] + r")\s*:?\s+" + ref + r"\b", re.I)
seen = []
for chunk in sys.stdin.read().split("\0"):
    kept, fenced = [], False
    for line in chunk.splitlines():
        if os.environ["SCOPE"] == "header" and not fenced and line.startswith("## "):
            break
        if re.match(r"\s*(```|~~~)", line):
            fenced = not fenced
            continue
        if not fenced:
            kept.append(re.sub(r"`[^`]*`", " ", line))
    for m in pat.finditer("\n".join(kept)):
        if m.group(1) not in seen:
            seen.append(m.group(1))
print("\n".join(seen))'
}
# header_issue_refs <keyword alternation>: `#N` references in the body's header block (the issue closing, step 8)
header_issue_refs() { printf '%s\n' "$body" | issue_refs "$1" header; }
rc=0
printf '%s\n' "$body" | acceptance_check_body || rc=$?
if [ "$rc" -ne 0 ]; then
  # --tick-from-review (#9): open boxes (rc 1) are handled by the tick step below, which re-runs this gate
  if [ "$TICK" -eq 1 ] && [ "$rc" -eq 1 ]; then
    echo "lead-merge: open boxes found, trying --tick-from-review"
  else
    die "PR #$PR acceptance gate failed (rc=$rc); nothing bumped, nothing merged"
  fi
fi

# --- 1a. review freshness (#157) -------------------------------------------------
# The latest review verdict must have been made on the PR head as it is NOW, i.e. before this script adds its own
# merge-from-base and bump commits. Runs before the exceptions, the tick, and every fetch/merge/push. The comments read
# here are the snapshot the tick step below picks its verdict from.
lm_tmp="$(mktemp -d "${TMPDIR:-/tmp}/lead-merge.XXXXXX")"
gh api "repos/$REPO/issues/$PR/comments" --paginate > "$lm_tmp/comments.json" || die "cannot read the comments of PR #$PR"
pr_head="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)" || die "cannot read the head sha of PR #$PR"
rf="$(review_fresh_state "$PR" "$pr_head" < "$lm_tmp/comments.json")" || die "cannot parse the comments of PR #$PR"
case "$rf" in
  ok*) ;;
  none) die "FAIL: review-stale: PR #$PR has no review marker carrying a head sha (first line '<!-- pipeline-review-round pr=$PR sha=<40hex> -->'); re-run the review; nothing bumped, nothing merged" ;;
  *) reviewed="${rf#stale }"
     # a re-run after a partial run: the head may hold this script's own bump/merge commits on top of the reviewed sha
     hb="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName)" || die "cannot read PR #$PR head branch"
     git fetch origin "+refs/heads/$hb:refs/remotes/origin/$hb" "+refs/heads/main:refs/remotes/origin/main" >/dev/null 2>&1 || true
     review_own_commits_only "$reviewed" "$pr_head" origin/main \
       || die "FAIL: review-stale: the latest review was made on $reviewed but the PR head is $pr_head; re-review first; nothing bumped, nothing merged"
     echo "lead-merge: head $pr_head only adds lead-merge's own commits to the reviewed $reviewed (a re-run)" ;;
esac

# --- 1b. declared exceptions (#122) -------------------------------------------
# Format: `exception: <what> — <why> — #N` (em dash; ` -- ` also accepted). Only lines inside the acceptance markers.
exc_fail() { echo "FAIL: declared-exception: $*" >&2; die "PR #$PR declared exception refused; nothing bumped, nothing merged"; }
exc_lines="$(printf '%s\n' "$body" | python3 -c '
import re, sys
inb = False
for line in sys.stdin.read().splitlines():
    if re.search(r"<!--\s*acceptance:end\s*-->", line):
        inb = False
    if inb:
        m = re.match(r"\s*(?:-\s*(?:\[[ xX]\]\s*)?)?exception:\s*(.*)$", line, re.I)
        if m:
            parts = [p.strip() for p in re.split(r"\s+(?:\u2014|--)\s+", m.group(1))]
            if len(parts) == 3 and parts[0] and parts[1] and re.fullmatch(r"#\d+", parts[2]):
                print("OK\t" + parts[2][1:])
            else:
                print("BAD\t" + line.strip())
    if re.search(r"<!--\s*acceptance:start\s*-->", line):
        inb = True')" || die "cannot parse declared exceptions"
git fetch origin "+refs/heads/main:refs/remotes/origin/main" || die "git fetch origin main failed"
# lm_sync_head: the gates below judge the PR head as the remote has it ($lm_head_ref = the fetched tip, checked against the
# head sha the review check read), never the local branch, which step 2 may still fast-forward (#174).
lm_head_ref=""
lm_sync_head() {
  [ -z "$lm_head_ref" ] || return 0
  local hb got
  hb="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName)" || die "cannot read PR #$PR head branch"
  [ -n "$hb" ] || die "empty head branch for PR #$PR"
  git fetch origin "+refs/heads/$hb:refs/remotes/origin/$hb" || die "git fetch origin $hb failed"
  got="$(git rev-parse "refs/remotes/origin/$hb")" || die "cannot resolve origin/$hb"
  [ "$got" = "$pr_head" ] || die "FAIL: review-stale: the PR head moved to $got after the review check read $pr_head; re-run"
  lm_head_ref="$got"
}
if [ -n "$exc_lines" ]; then
  lm_sync_head
  exc_diff="$(git diff "origin/main...$lm_head_ref" | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)"
  while IFS="$(printf '\t')" read -r kind val; do
    [ -n "$kind" ] || continue
    [ "$kind" = OK ] || exc_fail "malformed line (want: exception: <what> — <why> — #N): $val"
    info="$(gh api "repos/$REPO/issues/$val" --jq '.state + " " + ([.labels[].name] | join(","))')" \
      || exc_fail "cannot read follow-up issue #$val"
    case "${info%% *}" in open) ;; *) exc_fail "follow-up issue #$val is not open (${info%% *})" ;; esac
    case ",${info#* }," in *,tech-debt,*) ;; *) exc_fail "follow-up issue #$val lacks the tech-debt label" ;; esac
    printf '%s\n' "$exc_diff" | grep -qE "DEBT\(#$val\)" || exc_fail "no DEBT(#$val) marker in the PR diff"
  done <<EOX
$exc_lines
EOX
fi

# --- 1b2. R2 waivers must be declared (#174) -----------------------------------
# R2 scope = engine repo (`engineRepo: true` in .claude/pipeline.config.json ON origin/main, never the PR's own copy, so a PR
# cannot switch the rule off) + an issue named by a closing keyword or Refs (`#N`, `<this repo>#N` or its URL; anywhere in the
# PR body or in a commit message of the PR) labelled `type:bug` + a PR head touching workflows/. Such a PR must add or modify
# fixtures/incidents/<N>-*.json holding valid JSON at the PR head, or carry a valid declared exception (an `exception:` line
# already validated by 1b above). The PR is the REMOTE head against origin/main (three dots), renames are not detected (a
# file moved out of workflows/ is still a change there; a fixture moved in is still an addition). The BUILD line the bump
# commit rewrites is not a workflows/ change (a re-run after a partial run carries that bump). Local tests first: no gh call
# unless engine holds.
r2_fail() { echo "FAIL: r2-waiver: $*" >&2; die "PR #$PR R2 waiver not declared; nothing bumped, nothing merged"; }
if [ -z "$exc_lines" ]; then
  r2_engine=0
  if git show origin/main:.claude/pipeline.config.json > "$lm_tmp/base-config.json" 2>/dev/null \
     && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("engineRepo") is True else 1)' "$lm_tmp/base-config.json" 2>/dev/null; then
    r2_engine=1
  fi
  if [ "$r2_engine" -eq 1 ]; then
    lm_sync_head
    r2_range="origin/main...$lm_head_ref"
    r2_wf="$(git diff --no-renames -U0 "$r2_range" -- workflows/ | WORKFLOW="$WORKFLOW" python3 -c '
import os, re, sys
own = "diff --git a/%s b/%s" % (os.environ["WORKFLOW"], os.environ["WORKFLOW"])
build = re.compile(r"^[+-]const BUILD = \{[^}]*\}\s*;?\s*$")
blocks = []   # [header, hunk seen, changed lines, extended header lines (mode change, new or deleted file, binary...)]
for line in sys.stdin.read().split("\n"):
    if line.startswith("diff --git "):
        blocks.append([line, False, [], []])
    elif blocks:
        if line.startswith("@@"):
            blocks[-1][1] = True
        elif blocks[-1][1]:
            if line and line[0] in "+-":
                blocks[-1][2].append(line)
        elif line and not line.startswith(("index ", "--- ", "+++ ")):
            blocks[-1][3].append(line)
# a file is a real change unless it is the workflow with hunks made only of BUILD lines (no mode change, not created or deleted)
print(1 if any(h != own or not seen or not lines or ext or any(not build.match(l) for l in lines) for h, seen, lines, ext in blocks) else 0)')" \
      || die "cannot diff the PR against origin/main"
    if [ "$r2_wf" = 1 ]; then
      r2_fixtures="$(git diff --no-renames --name-status "$r2_range" | awk -F'\t' '$1 == "A" || $1 == "M" { print $2 }')" \
        || die "cannot diff the PR against origin/main"
      r2_refs="$({ printf '%s\0' "$body"; git log -z --format=%B "origin/main..$lm_head_ref"; } \
        | issue_refs 'close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?' all "$REPO")" || die "cannot parse issue references"
      for n in $r2_refs; do
        info="$(gh api "repos/$REPO/issues/$n" --jq '.state + " " + ([.labels[].name] | join(","))')" || r2_fail "cannot read issue #$n"
        case ",${info#* }," in *,type:bug,*) ;; *) continue ;; esac
        covered=0
        while IFS= read -r fx; do
          [ -n "$fx" ] || continue
          if git show "$lm_head_ref:$fx" 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then covered=1; break; fi
        done <<EOX
$(printf '%s\n' "$r2_fixtures" | grep -E "^fixtures/incidents/$n-[^/]+\.json\$" || true)
EOX
        if [ "$covered" -eq 1 ]; then continue; fi
        r2_fail "issue #$n is type:bug and the PR changes workflows/ but adds or modifies no valid (non-empty JSON) fixtures/incidents/$n-*.json; add the fixture (replayed red on base, green on the branch) or declare the waiver with 'exception: <what> — <why> — #M' in the acceptance block (#M an open tech-debt issue, DEBT(#M) marker in the diff)"
      done
    fi
  fi
fi

# --- 1c. --tick-from-review (#9) -----------------------------------------------
if [ "$TICK" -eq 1 ] && [ "$rc" -eq 1 ]; then
  tick_tmp="$lm_tmp"   # comments.json was read in step 1a: same snapshot as the freshness check
  pick_rc=0
  PR="$PR" python3 - "$tick_tmp/comments.json" "$tick_tmp/verdict_at.txt" > "$tick_tmp/review.txt" <<'PY' || pick_rc=$?
import json, os, re, sys
raw, dec, i, comments = open(sys.argv[1]).read(), json.JSONDecoder(), 0, []
while i < len(raw):
    if raw[i].isspace():
        i += 1; continue
    obj, i = dec.raw_decode(raw, i)
    comments.extend(obj if isinstance(obj, list) else [obj])
marker = re.compile(r"<!-- pipeline-review-round pr=%s( sha=[0-9a-fA-F]{40})? -->" % os.environ["PR"])
def marked(c):
    lines = (c.get("body") or "").replace("\r", "").split("\n")
    return lines, bool(lines) and bool(marker.fullmatch(lines[0].strip()))
best = None
for n, c in enumerate(comments):
    lines, is_marked = marked(c)
    if is_marked and len([l for l in lines[1:] if l.strip()]) >= 2:
        best = n
if best is None:
    sys.exit(1)
if any(marked(c)[1] for c in comments[best + 1:]):
    sys.exit(2)  # a later marker comment (e.g. a Nick push-note): the verdict is stale
open(sys.argv[2], "w").write(comments[best].get("created_at") or "")
print(comments[best]["body"])
PY
  case "$pick_rc" in
    0) ;;
    2) die "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first" ;;
    *) die "PR #$PR has no Morgan review comment (marker '<!-- pipeline-review-round pr=$PR -->' with a multi-line verdict); nothing ticked, nothing merged" ;;
  esac
  # the PR head must not be newer than the verdict (REST: pulls/<N> head sha -> commits/<sha> committer date)
  head_sha="$pr_head"
  head_date="$(gh api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date)" || die "cannot read the commit date of $head_sha"
  verdict_at="$(cat "$tick_tmp/verdict_at.txt")"
  [ -n "$head_date" ] && [ -n "$verdict_at" ] || die "tick-from-review: cannot compare the head commit date with the verdict date; nothing ticked"
  python3 -c 'import sys; sys.exit(0 if sys.argv[1] <= sys.argv[2] else 1)' "$head_date" "$verdict_at" \
    || die "FAIL: tick-from-review: a push followed Morgan's verdict; re-review first"
  printf '%s\n' "$body" > "$tick_tmp/body.txt"
  python3 - "$tick_tmp/body.txt" "$tick_tmp/review.txt" > "$tick_tmp/newbody.txt" <<'PY' || die "tick step failed"
import re, sys
body = open(sys.argv[1]).read().rstrip("\n").split("\n")
review = open(sys.argv[2]).read().replace("\r", "").split("\n")
def norm(s):
    return re.sub(r"\s+", " ", s.replace("**", "").replace("`", "")).strip()
proven = []  # (normalised box text, raw proof)
pat = re.compile(r"^\s*(?:[—–:]|--?)?\s*verified,?\s+tick pending\s*\(permissions\)\s*:\s*(\S.*)$", re.I)
for line in review:
    m = re.match(r"^\s*[-*]\s*(?:\[[ xX]\]\s*)?(.*)$", line)
    if not m:
        continue
    raw = m.group(1)
    k = raw.lower().find("(permissions):")
    proof = raw[k + len("(permissions):"):] if k >= 0 else ""
    if k < 0 or not ("`" in proof or " -> " in proof):
        continue  # the proof must show a command: backticks, or Morgan's `<command> -> <output>` template
    n = norm(raw)
    proven.append(n)
suffix = " — ticked by lead-merge from Morgan's review"
out, inblock = [], False
for line in body:
    if re.search(r"<!--\s*acceptance:end\s*-->", line):
        inblock = False
    m = re.match(r"^(\s*-\s*)\[ \](\s*)(.*)$", line) if inblock else None
    if m:
        text = m.group(3)
        if re.search(r"\[human-gate\]", text, re.I):
            print("left open (human-gate): " + norm(text), file=sys.stderr)
        else:
            bn, hit = norm(text), False
            for n in proven:
                if bn and n.lower().startswith(bn.lower()):
                    rest = n[len(bn):]
                    if pat.match(rest):
                        hit = True; break
            if hit:
                line = m.group(1) + "[x]" + m.group(2) + text + suffix
                print("ticked: " + bn, file=sys.stderr)
            else:
                print("left open (no proof in the review): " + bn, file=sys.stderr)
    out.append(line)
    if re.search(r"<!--\s*acceptance:start\s*-->", line):
        inblock = True
print("\n".join(out))
PY
  if ! cmp -s "$tick_tmp/body.txt" "$tick_tmp/newbody.txt"; then
    gh api -X PATCH "repos/$REPO/pulls/$PR" -F "body=@$tick_tmp/newbody.txt" >/dev/null || die "cannot PATCH the PR #$PR body"
  fi
  body="$(gh pr view "$PR" -R "$REPO" --json body -q .body)" || die "cannot re-read PR #$PR body"
  rc=0
  printf '%s\n' "$body" | acceptance_check_body || rc=$?
  [ "$rc" -eq 0 ] || die "PR #$PR acceptance gate still failing after --tick-from-review (rc=$rc); nothing bumped, nothing merged"
fi

# --- 2. sync with the remote head branch ---------------------------------------
head_branch="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName)" || die "cannot read PR #$PR head branch"
[ -n "$head_branch" ] || die "empty head branch for PR #$PR"
cur_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$cur_branch" = "$head_branch" ] || die "checkout is on '$cur_branch', PR #$PR head is '$head_branch': run from the PR worktree"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch origin "+refs/heads/$head_branch:refs/remotes/origin/$head_branch" || die "git fetch origin $head_branch failed"
local_sha="$(git rev-parse HEAD)"; remote_sha="$(git rev-parse "refs/remotes/origin/$head_branch")"
# the head the review check (step 1a) read must be the head this script goes on with (a push in between = re-run)
[ "$remote_sha" = "$pr_head" ] || die "FAIL: review-stale: the PR head moved to $remote_sha after the review check read $pr_head; re-run"
if [ "$local_sha" != "$remote_sha" ]; then
  if git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
    git merge --ff-only "origin/$head_branch" || die "fast-forward to origin/$head_branch failed"
  elif git merge-base --is-ancestor "$remote_sha" "$local_sha"; then
    echo "lead-merge: local branch is ahead of origin/$head_branch (will be pushed)"
  else
    die "local $head_branch and origin/$head_branch have diverged; reconcile by hand"
  fi
fi

# --- 3. bring the base in locally (merge only) -----------------------------------
git fetch origin "+refs/heads/main:refs/remotes/origin/main" || die "git fetch origin main failed"
if ! git merge --no-edit origin/main; then
  conflicts="$(git diff --name-only --diff-filter=U)"
  other="$(printf '%s\n' "$conflicts" | grep -vxF -e "$MANIFEST" -e "$WORKFLOW" | grep -v '^$' || true)"
  if [ -n "$conflicts" ] && [ -z "$other" ]; then
    # main bumped as well: take its copy (stage 3) of the version files; the bump step recomputes them
    for f in $conflicts; do git show ":3:$f" > "$f" && git add -- "$f" || { git merge --abort 2>/dev/null || true; die "cannot resolve the version-file conflict in $f"; }; done
    git commit --no-edit || { git merge --abort 2>/dev/null || true; die "merge commit failed"; }
  else
    git merge --abort 2>/dev/null || true
    die "merging origin/main conflicts (${conflicts:-unknown}); resolve in the worktree, push, re-run. Nothing pushed."
  fi
fi

ver_of() { python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))"; }
# semver valid V | semver gt A B (rc 0 iff A > B) | semver next V (prints the next version); rc 2 = not a semver.
# Semver 2.0.0 precedence (section 11): a prerelease sorts below its release, numeric identifiers compare as numbers,
# build metadata is ignored. next: X.Y.Z -> X.Y.(Z+1); X.Y.Z-id.N -> X.Y.Z-id.(N+1); X.Y.Z-id (no numeric tail) -> X.Y.Z-id.1.
semver() {
  python3 - "$@" <<'PYSEMVER'
import re, sys
def parse(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$", v)
    if not m:
        sys.exit(2)
    return [int(m.group(1)), int(m.group(2)), int(m.group(3))], m.group(4).split(".") if m.group(4) else []
def key(v):
    core, pre = parse(v)
    return (core, 0 if pre else 1, [(0, int(i), "") if i.isdigit() else (1, 0, i) for i in pre])
op = sys.argv[1]
if op == "valid":
    parse(sys.argv[2])
elif op == "gt":
    sys.exit(0 if key(sys.argv[2]) > key(sys.argv[3]) else 1)
elif op == "next":
    core, pre = parse(sys.argv[2])
    if not pre:
        print("%d.%d.%d" % (core[0], core[1], core[2] + 1))
    else:
        pre = pre[:-1] + [str(int(pre[-1]) + 1)] if pre[-1].isdigit() else pre + ["1"]
        print("%d.%d.%d-%s" % (core[0], core[1], core[2], ".".join(pre)))
PYSEMVER
}

# --- 4. bump from the merged tree (idempotent; plugin repo only, #145) ----------
if [ ! -f "$MANIFEST" ]; then
  echo "lead-merge: no plugin manifest, version bump skipped"
else
main_ver="$(git show "origin/main:$MANIFEST" | ver_of)"
branch_ver="$(ver_of < "$MANIFEST")"
[ -n "$main_ver" ] && [ -n "$branch_ver" ] || die "cannot read versions (main='$main_ver' branch='$branch_ver')"
{ semver valid "$main_ver" && semver valid "$branch_ver"; } || die "version is not semver (main='$main_ver' branch='$branch_ver')"
have_build=0
if [ -f "$WORKFLOW" ] && grep -q '^const BUILD' "$WORKFLOW"; then have_build=1; fi

if semver gt "$branch_ver" "$main_ver" && git log -n 50 --format=%s origin/main..HEAD | grep -qxF "chore: bump $branch_ver (lead-merge)"; then
  echo "lead-merge: bump commit for $branch_ver already on the branch, skipping bump"
else
  base_ver="$main_ver"
  if semver gt "$branch_ver" "$main_ver"; then base_ver="$branch_ver"; fi
  new_ver="$(semver next "$base_ver")" || die "cannot compute the next version of '$base_ver'"
  cut_from="$(git rev-parse --short origin/main)"
  NEW_VER="$new_ver" CUT_FROM="$cut_from" MANIFEST="$MANIFEST" WORKFLOW="$WORKFLOW" HAVE_BUILD="$have_build" python3 - <<'PY' || die "bump edit failed"
import os, re, sys
v, cut = os.environ["NEW_VER"], os.environ["CUT_FROM"]
def edit(path, pat, repl):
    s = open(path).read()
    out, n = re.subn(pat, repl, s, count=1)
    if n != 1:
        sys.exit("pattern not found in " + path)
    open(path, "w").write(out)
edit(os.environ["MANIFEST"], r'("version"\s*:\s*")[^"]*(")', lambda m: m.group(1) + v + m.group(2))
if os.environ["HAVE_BUILD"] == "1":
    edit(os.environ["WORKFLOW"], r"const BUILD = \{[^}]*\}",
         "const BUILD = { plugin: 'lgtmgate', version: '%s', cutFrom: '%s' }" % (v, cut))
PY
  git add "$MANIFEST"
  if [ "$have_build" = 1 ]; then git add "$WORKFLOW"; fi
  git commit -m "chore: bump $new_ver (lead-merge)" || die "bump commit failed"
  echo "lead-merge: bumped $base_ver -> $new_ver"
fi
fi

# --- 5. push once --------------------------------------------------------------
pushed_sha="$(git rev-parse HEAD)"
if [ "$pushed_sha" != "$(git rev-parse "refs/remotes/origin/$head_branch")" ]; then
  git push origin "HEAD:$head_branch" || die "push to $head_branch failed"
else
  echo "lead-merge: origin/$head_branch already at HEAD, nothing to push"
fi

# --- 6. CI on the pushed sha ---------------------------------------------------
# cli/cli#7401: right after a push `gh pr checks` can exit 1 ("no checks reported") or show the
# previous sha. Poll until the PR head is the pushed sha and at least one check is reported.
poll_max="${LEAD_MERGE_POLL_MAX:-30}"; poll_sleep="${LEAD_MERGE_POLL_SLEEP:-10}"
seen=0; n=0
while [ "$n" -lt "$poll_max" ]; do
  n=$((n + 1))
  if gh pr view "$PR" -R "$REPO" --json headRefOid,statusCheckRollup 2>/dev/null | PUSHED="$pushed_sha" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("headRefOid") == os.environ["PUSHED"] and len(d.get("statusCheckRollup") or []) > 0 else 1)' 2>/dev/null; then
    seen=1; break
  fi
  sleep "$poll_sleep"
done
[ "$seen" -eq 1 ] || die "PR #$PR never reported checks for $pushed_sha after $poll_max polls; not merging"
# #156: `--required` only reports checks the base requires, through classic branch protection or a ruleset. A base with
# neither (e.g. a private repo on GitHub Free: both APIs answer 403) never reports one, so decide the mode first.
# Steps 3-4 merge origin/main, so the probes ask about main too.
base_branch="main"
# api_probe <path>: GET repos/$REPO/<path>. rc 0 + body on stdout; rc 1 on HTTP 403/404 (feature off, nothing set);
# rc 2 on anything else, a rate-limit 403 included (message on stderr). gh ends its stderr with "... (HTTP <code>)".
api_probe() {
  local out rc=0
  out="$(gh api "repos/$REPO/$1" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
  case "$out" in *"rate limit"*) ;; *"(HTTP 403)"*|*"(HTTP 404)"*) return 1 ;; esac
  echo "lead-merge: gh api repos/$REPO/$1 failed: $out" >&2; return 2
}
# base_requires_checks: rc 0 = $base_branch requires status checks, 1 = none, 2 = probe inconclusive. Two sources, the
# two `gh pr checks --required` reads: classic protection (200 only with required status checks enabled) and rulesets
# (`rules/branches/<base>` lists the active rules, one of type required_status_checks with contexts).
base_requires_checks() {
  local body rc=0 verdict
  body="$(api_probe "branches/$base_branch/protection/required_status_checks")" || rc=$?
  case "$rc" in 0) return 0 ;; 1) ;; *) return 2 ;; esac
  rc=0
  body="$(api_probe "rules/branches/$base_branch")" || rc=$?
  case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  verdict="$(printf '%s' "$body" | python3 -c '
import json, sys
rules = json.load(sys.stdin)
print("yes" if any(r.get("type") == "required_status_checks" and (r.get("parameters") or {}).get("required_status_checks") for r in rules) else "no")' 2>/dev/null)" || verdict=""
  case "$verdict" in yes) return 0 ;; no) return 1 ;; *) return 2 ;; esac
}
# watch_head_checks (mode no-required-checks): `gh pr checks` has no name filter and rejects --watch with --json, so poll
# the JSON. Scope = config.ciChecks when set (a name not reported yet is "missing", bounded by poll_max like the
# registration race below), else every reported check. fail/cancel dies at once (--fail-fast); pending is waited out.
watch_head_checks() {
  local n=0 out state
  while :; do
    out="$(gh pr checks "$PR" -R "$REPO" --json name,bucket 2>/dev/null || true)"
    state="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    names = json.load(open(".claude/pipeline.config.json")).get("ciChecks") or []
except (OSError, ValueError):
    names = []
rows = json.load(sys.stdin)
have = [r.get("name") for r in rows]
scope = [r for r in rows if not names or r.get("name") in names]
gone = [x for x in names if x not in have] if names else ([] if rows else ["(none)"])
bad = [r.get("name") for r in scope if r.get("bucket") in ("fail", "cancel")]
if bad:
    print("fail " + ",".join(bad))
elif gone:
    print("missing " + ",".join(gone))
elif any(r.get("bucket") not in ("pass", "skipping") for r in scope):
    print("pending")
else:
    print("pass")' 2>/dev/null)" || state="missing (unreadable)"
    case "$state" in
      pass) return 0 ;;
      fail*) die "CI checks failed (${state#fail }); not merging" ;;
      pending) ;;
      *) n=$((n + 1)); [ "$n" -lt "$poll_max" ] || die "PR #$PR never reported its checks (${state#missing }) after $poll_max polls (mode: $mode); not merging" ;;
    esac
    sleep "$poll_sleep"
  done
}
req=""
if gh pr checks --help 2>&1 | grep -q -- --required; then req="--required"; fi
mode="required-checks"
if [ -n "$req" ]; then
  has_rc=0; base_requires_checks || has_rc=$?
  case "$has_rc" in
    0) ;;
    1) req=""; mode="no-required-checks"
       echo "lead-merge: $base_branch requires no status checks (mode: $mode); watching the head's checks (config.ciChecks when set)" ;;
    *) die "cannot tell whether $base_branch requires status checks; not merging" ;;
  esac
fi
if [ "$mode" = "no-required-checks" ]; then
  watch_head_checks
else
  # Required checks can register after other workflows (CodeQL): `--required` then exits 1 with
  # "no required checks reported". Keep polling (same bound) until they appear.
  if [ -n "$req" ]; then
    n=0
    # Capture first: under pipefail a `gh ... | grep -q` condition takes gh's exit 1 and never loops.
    while out="$(gh pr checks "$PR" -R "$REPO" --required 2>&1 || true)"; printf '%s' "$out" | grep -q 'no required checks reported'; do
      n=$((n + 1))
      [ "$n" -lt "$poll_max" ] || die "PR #$PR never reported its required checks after $poll_max polls (mode: $mode on $base_branch); not merging"
      sleep "$poll_sleep"
    done
  fi
  # shellcheck disable=SC2086
  gh pr checks "$PR" -R "$REPO" --watch --fail-fast $req || die "CI checks failed; not merging"
fi

# --- 7. merge ------------------------------------------------------------------
gh pr merge "$PR" -R "$REPO" --merge --delete-branch || die "gh pr merge failed"

# --- 8. verified merge -> close the referenced issues (#109) ---------------------
# Never trust the merge exit code alone: read the PR back (REST, not GraphQL) before closing anything.
merged="$(gh api "repos/$REPO/pulls/$PR" --jq .merged)" || die "cannot read PR #$PR back after merge; no issue closed"
merged_at="$(gh api "repos/$REPO/pulls/$PR" --jq .merged_at)" || die "cannot read PR #$PR merged_at; no issue closed"
{ [ "$merged" = "true" ] && [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; } \
  || die "PR #$PR is not merged (merged=$merged merged_at=$merged_at); no issue closed"
# Closing keywords in the header block ONLY (#119, see header_issue_refs); `Refs #N` never matches.
closing_issues="$(header_issue_refs 'close[sd]?|fix(?:e[sd])?|resolve[sd]?')" || die "cannot parse closing references; PR #$PR is merged, close issues by hand"
close_failed=0
for issue in $closing_issues; do
  state="$(gh api "repos/$REPO/issues/$issue" --jq .state)" || { echo "lead-merge: cannot read issue #$issue state" >&2; close_failed=1; continue; }
  [ "$state" = "open" ] || { echo "lead-merge: issue #$issue is $state, left untouched"; continue; }
  if gh api -X POST "repos/$REPO/issues/$issue/comments" -f body="Fixed by #$PR (merged)." >/dev/null \
     && gh api -X PATCH "repos/$REPO/issues/$issue" -f state=closed -f state_reason=completed >/dev/null; then
    echo "lead-merge: closed issue #$issue"
  else
    echo "lead-merge: failed to close issue #$issue" >&2; close_failed=1
  fi
done

echo "lead-merge: PR #$PR merged. Next manual step: in the main checkout run 'git fetch origin && git merge --ff-only origin/main'."
[ "$close_failed" -eq 0 ] || die "PR #$PR merged, but some referenced issues could not be closed; close them by hand"
