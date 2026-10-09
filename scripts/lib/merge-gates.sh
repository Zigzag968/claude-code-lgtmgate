#!/usr/bin/env bash
# Merge gates 1b (declared exceptions, #122) and 1b2 (R2 waivers, #174) of scripts/lead-merge.sh. Sourced by it.
# bash 3.2 safe. Defines functions only; no side effect on source.
#   lm_gate_declared_exceptions   validates the `exception:` lines of the acceptance block; sets the global $exc_lines
#   lm_gate_r2_waivers            needs $exc_lines (empty: no exception declared); refuses an undeclared R2 waiver
# Both take (body, pr_head[, tmp dir]), read the globals PR, REPO, WORKFLOW and use die(), issue_refs() of the main script;
# lm_gate_declared_exceptions runs first and resets $lm_tips.

exc_fail() { echo "FAIL: declared-exception: $*" >&2; die "PR #$PR declared exception refused; nothing bumped, nothing merged"; }
# lm_sync_head: the gates below judge the tip(s) that WILL be merged, in $lm_tips: the PR head as the remote has it (fetched,
# checked against the head sha the review check read) and, when the local branch holds commits the remote lacks, the local
# head, since step 2 pushes those commits (#174). Local behind the remote (step 2 fast-forwards): the remote head. Local ahead
# (it contains the remote head): the local head alone, it carries everything the remote head has. Diverged (step 2 refuses
# it later): both heads, each must pass. A checkout on another branch than the PR head is judged on the remote head only
# (step 2 refuses it).
lm_sync_head() {
  [ -z "$lm_tips" ] || return 0
  local pr_head="$1" hb got cur loc
  hb="$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName)" || die "cannot read PR #$PR head branch"
  [ -n "$hb" ] || die "empty head branch for PR #$PR"
  git fetch origin "+refs/heads/$hb:refs/remotes/origin/$hb" || die "git fetch origin $hb failed"
  got="$(git rev-parse "refs/remotes/origin/$hb")" || die "cannot resolve origin/$hb"
  [ "$got" = "$pr_head" ] || die "FAIL: review-stale: the PR head moved to $got after the review check read $pr_head; re-run"
  lm_tips="$got"
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$cur" = "$hb" ]; then
    loc="$(git rev-parse HEAD)" || die "cannot resolve the local head"
    if [ "$loc" != "$got" ] && ! git merge-base --is-ancestor "$loc" "$got"; then
      if git merge-base --is-ancestor "$got" "$loc"; then lm_tips="$loc"; else lm_tips="$got $loc"; fi
    fi
  fi
}
# exc_marker_in_every_tip <n>: a `DEBT(#n)` marker among the added lines of the diff against origin/main, on every tip judged
exc_marker_in_every_tip() {
  local t added
  for t in $lm_tips; do
    added="$(git diff "origin/main...$t" | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)"
    grep -qE "DEBT\(#$1\)" <<<"$added" || return 1
  done
}

lm_gate_declared_exceptions() {
  local body="$1" pr_head="$2" info kind val
  lm_tips=""
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
  if [ -n "$exc_lines" ]; then
    lm_sync_head "$pr_head"
    while IFS="$(printf '\t')" read -r kind val; do
      [ -n "$kind" ] || continue
      [ "$kind" = OK ] || exc_fail "malformed line (want: exception: <what> — <why> — #N): $val"
      info="$(gh api "repos/$REPO/issues/$val" --jq '.state + " " + ([.labels[].name] | join(","))')" \
        || exc_fail "cannot read follow-up issue #$val"
      case "${info%% *}" in open) ;; *) exc_fail "follow-up issue #$val is not open (${info%% *})" ;; esac
      case ",${info#* }," in *,tech-debt,*) ;; *) exc_fail "follow-up issue #$val lacks the tech-debt label" ;; esac
      exc_marker_in_every_tip "$val" || exc_fail "no DEBT(#$val) marker in the PR diff"
    done <<EOX
$exc_lines
EOX
  fi
}

# R2 scope = engine repo (`engineRepo: true` in .claude/pipeline.config.json ON origin/main, never the PR's own copy, so a PR
# cannot switch the rule off) + an issue named by a closing keyword or Refs (`#N`, `<this repo>#N` or its URL; anywhere in the
# PR body or in a commit message of the PR) labelled `type:bug` + a PR head touching workflows/. Such a PR must add or modify
# fixtures/incidents/<N>-*.json holding valid JSON at the PR head, or carry a valid declared exception (an `exception:` line
# already validated by 1b above). The PR is each tip judged (lm_sync_head: the remote head, the local head when it holds
# unpushed commits) against origin/main (three dots) and every tip that changes workflows/ needs its own fixture. Renames are
# not detected (a file moved out of workflows/ is still a change there; a fixture moved in is still an addition). Only the
# exact line the bump writes (`const BUILD = { plugin: 'lgtmgate', version: '<semver>', cutFrom: '<literal>' }`) is not a
# workflows/ change (a re-run after a partial run carries that bump). Issue numbers are normalised (#030 = 30). Local tests first: no gh call
# unless engine holds.
r2_fail() { echo "FAIL: r2-waiver: $*" >&2; die "PR #$PR R2 waiver not declared; nothing bumped, nothing merged"; }
# r2_fixtures_of <tip> <n>: the files fixtures/incidents/<n>-<name>.json (that exact path, no subfolder) the PR added or modified
# between origin/main and <tip>, NUL-separated. `-z` keeps non-ASCII names unquoted; renames are split into their parts.
r2_fixtures_of() {
  git diff -z --no-renames --name-status "origin/main...$1" | N="$2" python3 -c '
import os, re, sys
parts = sys.stdin.buffer.read().split(b"\0")
pat = re.compile(rb"fixtures/incidents/" + re.escape(os.environ["N"].encode()) + rb"-[^/]+\.json")
for status, path in zip(parts[0::2], parts[1::2]):
    if status in (b"A", b"M") and pat.fullmatch(path):
        sys.stdout.buffer.write(path + b"\0")'
}
# r2_changes_workflows <tip>: prints 1 when the PR (origin/main...<tip>) really changes workflows/, 0 when it only rewrites the BUILD
# line of the workflow (the bump). Renames are not detected: a file moved out of workflows/ is still a change there.
r2_changes_workflows() {
  git diff --no-renames -U0 "origin/main...$1" -- workflows/ | WORKFLOW="$WORKFLOW" python3 -c '
import os, re, sys
own = "diff --git a/%s b/%s" % (os.environ["WORKFLOW"], os.environ["WORKFLOW"])
# the one line the bump writes (see step 4): known keys in order, quoted literals only (\x27 = the single quote), no code fits in it
build = re.compile(r"[+-]const BUILD = \{\s*plugin:\s*\x27lgtmgate\x27\s*,\s*version:\s*\x27[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\x27\s*,\s*cutFrom:\s*\x27[0-9A-Za-z._-]{1,40}\x27\s*\}\s*;?\s*")
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
print(1 if any(h != own or not seen or not lines or ext or any(not build.fullmatch(l) for l in lines) for h, seen, lines, ext in blocks) else 0)'
}

lm_gate_r2_waivers() {
  local body="$1" pr_head="$2" lm_tmp="$3"
  local r2_engine r2_wf_tips r2_wf r2_refs r2_seen n info t covered fx
  if [ -z "$exc_lines" ]; then
    r2_engine=0
    if git show origin/main:.claude/pipeline.config.json > "$lm_tmp/base-config.json" 2>/dev/null \
       && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("engineRepo") is True else 1)' "$lm_tmp/base-config.json" 2>/dev/null; then
      r2_engine=1
    fi
    if [ "$r2_engine" -eq 1 ]; then
      lm_sync_head "$pr_head"
      r2_wf_tips=""
      for t in $lm_tips; do
        r2_wf="$(r2_changes_workflows "$t")" || die "cannot diff the PR against origin/main"
        if [ "$r2_wf" = 1 ]; then r2_wf_tips="$r2_wf_tips $t"; fi
      done
      if [ -n "$r2_wf_tips" ]; then
        r2_refs="$({ printf '%s\0' "$body"; git log -z --format=%B $lm_tips ^origin/main; } \
          | issue_refs 'close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?' all "$REPO")" || die "cannot parse issue references"
        r2_seen=" "
        for n in $r2_refs; do
          n="$(printf '%s' "$n" | sed -E 's/^0+([0-9])/\1/')"   # #030 is issue 30 for the API and for the fixture name
          case "$r2_seen" in *" $n "*) continue ;; esac
          r2_seen="$r2_seen$n "
          info="$(gh api "repos/$REPO/issues/$n" --jq '.state + " " + ([.labels[].name] | join(","))')" || r2_fail "cannot read issue #$n"
          case ",${info#* }," in *,type:bug,*) ;; *) continue ;; esac
          for t in $r2_wf_tips; do   # every tip that changes workflows/ carries its own valid fixture
            covered=0
            r2_fixtures_of "$t" "$n" > "$lm_tmp/fixtures.list" || die "cannot diff the PR against origin/main"
            while IFS= read -r -d '' fx; do
              if git show "$t:$fx" 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then covered=1; break; fi
            done < "$lm_tmp/fixtures.list"
            if [ "$covered" -eq 1 ]; then continue; fi
            r2_fail "issue #$n is type:bug and the PR changes workflows/ but adds or modifies no valid (non-empty JSON) fixtures/incidents/$n-*.json; add the fixture (replayed red on base, green on the branch) or declare the waiver with 'exception: <what> — <why> — #M' in the acceptance block (#M an open tech-debt issue, DEBT(#M) marker in the diff)"
          done
        done
      fi
    fi
  fi
}
