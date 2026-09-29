#!/usr/bin/env bash
# provision_worktree.sh — deterministic worktree provisioning: symlink unversioned
# dependencies (.env, venvs, caches) from MAIN into a linked worktree, before any
# agent runs so build/test commands work from the first tick (ported
# from an internal reference implementation).
#
# Replaces the old best-effort hand-rolled-symlink prompt handed to a haiku
# agent, whose result was never checked and which ran too late (after Plan/Dev
# already started). This script is deterministic, runs before any stage, and fails
# loudly (named path, non-zero exit) when a configured (hard) source is
# missing — see workflows/deliver-pipeline.js for the caller.
#
# HARDENING (claude-agent-pipeline#51, beyond the reference implementation this file is
# otherwise byte-aligned with): the JS-side caller validates provision.extraLinks
# lexically (segment + metacharacter allowlist) before composing the shell invocation,
# but that guard cannot assert PHYSICAL containment (workflow scripts have no module
# imports, so no path.resolve/realpath there) and does not protect a DIRECT invocation
# of this script bypassing the JS caller entirely. This script closes both gaps:
#   1. Segment rejection on every <src>/<dst> pair (same rule as the JS guard, so the
#      two cannot disagree) — belt-and-suspenders against a direct invocation.
#   2. Physical containment (`pwd -P`, no realpath dependency — BSD realpath on macOS
#      lacks the GNU flags and fails on a not-yet-existing path) of the DESTINATION
#      directory inside the worktree and the SOURCE directory inside MAIN.
#   3. Final-component resolution: if the source path itself is a symlink, its target
#      is resolved and re-checked against MAIN containment too — steps 1-2 alone would
#      let a symlink already committed in MAIN (e.g. "devkey" -> ~/.ssh/id_ed25519) link
#      a real secret into the worktree, since they only ever inspect the DIRECTORY.
#
# Usage: provision_worktree.sh <worktree-path> [<src> <dst>]...
#   <src>/<dst> are positional PAIRS (no separator char, so a path containing
#   ':' or '=' can never be misparsed), relative to MAIN and to the worktree
#   respectively. Every argv pair is HARD (missing source fails the run).
#   The implicit ".env" -> ".env" link is always considered too, as SOFT
#   (missing source only warns) — unless the caller already passes an
#   explicit pair with dst=".env", in which case the caller's (hard) pair wins.
#
# Env var: PROVISION_ENV_SYMLINK=required|forbidden|ignore (default: required,
#   claude-agent-pipeline#72). Only 'forbidden' has an effect: it skips the IMPLICIT
#   ".env" link above so provisioning doesn't fight preflight.envSymlink=forbidden
#   (workflows/deliver-pipeline.js), which asserts NO ".env" symlink is present. An
#   explicit argv dst=".env" pair is unaffected — it always wins.
#
# Exit codes:
#   0 — every HARD link created (or none configured); SOFT misses only warn.
#   1 — usage error: bad/missing worktree path, not a git worktree, odd arg
#       count, or worktree resolves to MAIN itself (never self-link).
#   2 — at least one HARD source was missing, rejected, or failed to link — see stderr.
#
# stdout (one line per successfully created link):
#   LINKED <dst> -> <src-abs-path>
# stderr:
#   WARN optional src missing: <abs path>   — soft miss, never fails the run
#   MISSING-SRC <abs path>                  — hard miss (source or link failure)
#   MISSING-SRC <abs path> (path segment rejected)   — traversal/metacharacter reject
#   MISSING-SRC <abs path> (destination escapes WT)  — dst containment reject
#   MISSING-SRC <abs path> (source escapes MAIN)     — src dir containment reject
#   MISSING-SRC <abs path> (link escapes MAIN)       — src is itself a symlink whose
#                                                       target escapes MAIN
#   PROVISION-FAILED: <n> link(s)           — summary, only printed on exit 2
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "[provision] usage: provision_worktree.sh <worktree-path> [<src> <dst>]..." >&2
  exit 1
fi

WT="$1"
shift

if [ ! -d "$WT" ]; then
  echo "[provision] worktree path does not exist or is not a directory: $WT" >&2
  exit 1
fi

GIT_COMMON="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -z "${GIT_COMMON:-}" ]; then
  echo "[provision] not a git worktree (git-common-dir resolution failed): $WT" >&2
  exit 1
fi
MAIN="$(dirname "$GIT_COMMON")"

WT_REAL="$(realpath "$WT" 2>/dev/null || echo "$WT")"
MAIN_REAL="$(realpath "$MAIN" 2>/dev/null || echo "$MAIN")"
if [ "$WT_REAL" = "$MAIN_REAL" ]; then
  echo "[provision] refusing to provision: worktree resolves to MAIN itself ($MAIN_REAL) — never self-link" >&2
  exit 1
fi

# Physical containment roots (claude-agent-pipeline#51 hardening) — `pwd -P` rather than
# `realpath`, which portably resolves symlinks in the path without depending on GNU-only
# flags. Both WT and MAIN already passed the -d/git-worktree checks above, so both exist.
WT_PHYS="$(cd "$WT" && pwd -P)"
MAIN_PHYS="$(cd "$MAIN" && pwd -P)"

if [ $(( $# % 2 )) -ne 0 ]; then
  echo "[provision] usage error: <src> <dst> arguments must come in pairs (got $# trailing arg(s))" >&2
  exit 1
fi

# src_exists PATH — presence check that survives a sandbox denying direct
# stat/lstat on specific filenames (observed live for a MAIN/.env: `ls -la
# <MAIN>/.env` -> "Operation not permitted", while listing the PARENT
# directory still shows the `.env` entry fine). Direct -e/-L is tried first
# (cheap, works everywhere else); only on that failure does it fall back to a
# parent-directory listing match (readdir + name compare, never stats the
# target path itself), so a sandboxed agent still detects a real source
# instead of silently treating it as missing.
src_exists() {
  local path="$1" dir base
  if [ -e "$path" ] || [ -L "$path" ]; then
    return 0
  fi
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [ -d "$dir" ] || return 1
  find "$dir" -maxdepth 1 -name "$base" 2>/dev/null | grep -qx "$dir/$base"
}

# reject_path REL — true (reject) if REL contains a `..` or `.` path segment, or is
# absolute. Same rule as the JS-side safeLinkPath validator, so the two guards can
# never disagree about what is safe.
reject_path() {
  local rel="$1" seg
  case "$rel" in
    /*) return 0 ;;
  esac
  local IFS=/
  for seg in $rel; do
    if [ -z "$seg" ] || [ "$seg" = "." ] || [ "$seg" = ".." ]; then
      return 0
    fi
  done
  return 1
}

# phys_contained VALUE ROOT_PHYS — true if the already-resolved absolute path VALUE
# equals ROOT_PHYS or is a physical descendant of it. Pure string comparison — VALUE
# must already be pwd-P-resolved by the caller.
phys_contained() {
  local value="$1" root="$2"
  [ "$value" = "$root" ] && return 0
  case "$value" in
    "$root"/*) return 0 ;;
  esac
  return 1
}

# dir_contained CHILD_DIR ROOT_PHYS — true if CHILD_DIR resolves (pwd -P) to exactly
# ROOT_PHYS or a physical descendant of it. CHILD_DIR need not exist yet (caller passes
# it only after mkdir -p for the dst case).
dir_contained() {
  local dir="$1" root="$2" phys
  phys="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  phys_contained "$phys" "$root"
}

# existing_ancestor PATH — walks up PATH until it finds a directory that actually
# exists, and prints it. Used to containment-check a not-yet-created destination
# directory (claude-agent-pipeline#53): dir_contained needs a real directory to `cd`
# into, so before any `mkdir -p` runs, the check must walk up to the nearest existing
# ancestor instead.
existing_ancestor() {
  local d="$1"
  while [ ! -d "$d" ]; do
    d="$(dirname "$d")"
  done
  printf '%s\n' "$d"
}

# Parse argv pairs into indexed arrays (index-based access throughout — no
# `"${arr[@]}"` foreach — so an empty array never trips `set -u` on older bash).
argv_srcs=()
argv_dsts=()
while [ "$#" -gt 0 ]; do
  argv_srcs+=("$1")
  argv_dsts+=("$2")
  shift 2
done
argv_n=${#argv_dsts[@]}

# PROVISION_ENV_SYMLINK (claude-agent-pipeline#72) — env var seam, not an argv flag (keeps
# the positional <src> <dst> pair contract untouched). Mirrors workflows/deliver-pipeline.js's
# preflight.envSymlink enum ('required' default here matches that config default). Only
# 'forbidden' has an effect: it skips the IMPLICIT .env link below. An EXPLICIT argv pair
# targeting dst=".env" is caller-authored and always wins regardless of this var — see
# has_explicit_env below, unchanged.
PROVISION_ENV_SYMLINK="${PROVISION_ENV_SYMLINK:-required}"

has_explicit_env=0
ai=0
while [ "$ai" -lt "$argv_n" ]; do
  if [ "${argv_dsts[$ai]}" = ".env" ]; then
    has_explicit_env=1
  fi
  ai=$((ai + 1))
done

# Build the full (pre-dedupe) list: implicit soft .env first (unless overridden
# above by an explicit argv pair), then every argv pair as HARD.
all_srcs=()
all_dsts=()
all_hard=()

if [ "$has_explicit_env" -eq 0 ] && [ "$PROVISION_ENV_SYMLINK" != "forbidden" ]; then
  all_srcs+=(".env")
  all_dsts+=(".env")
  all_hard+=(0)
fi

ai=0
while [ "$ai" -lt "$argv_n" ]; do
  all_srcs+=("${argv_srcs[$ai]}")
  all_dsts+=("${argv_dsts[$ai]}")
  all_hard+=(1)
  ai=$((ai + 1))
done

# Dedupe by dst — LAST occurrence wins (lets a later argv pair override an
# earlier one targeting the same dst).
final_srcs=()
final_dsts=()
final_hard=()
all_n=${#all_dsts[@]}
i=0
while [ "$i" -lt "$all_n" ]; do
  d="${all_dsts[$i]}"
  is_last=1
  j=$((i + 1))
  while [ "$j" -lt "$all_n" ]; do
    if [ "${all_dsts[$j]}" = "$d" ]; then
      is_last=0
      break
    fi
    j=$((j + 1))
  done
  if [ "$is_last" -eq 1 ]; then
    final_srcs+=("${all_srcs[$i]}")
    final_dsts+=("${all_dsts[$i]}")
    final_hard+=("${all_hard[$i]}")
  fi
  i=$((i + 1))
done

missing=()
final_n=${#final_dsts[@]}
k=0
while [ "$k" -lt "$final_n" ]; do
  src="${final_srcs[$k]}"
  dst="${final_dsts[$k]}"
  hard="${final_hard[$k]}"
  abs_src="$MAIN/$src"
  abs_dst="$WT/$dst"

  # Step 1 (claude-agent-pipeline#51): segment rejection — belt-and-suspenders in front
  # of the JS-side safeLinkPath validator, so a direct invocation of this script
  # bypassing the caller is refused too. Always a HARD failure, regardless of `hard`:
  # a traversal attempt is a security violation, never a benign missing optional file.
  if reject_path "$src" || reject_path "$dst"; then
    echo "MISSING-SRC $abs_src (path segment rejected)" >&2
    missing+=("$abs_src")
    k=$((k + 1))
    continue
  fi

  if ! src_exists "$abs_src"; then
    if [ "$hard" -eq 1 ]; then
      echo "MISSING-SRC $abs_src" >&2
      missing+=("$abs_src")
    else
      echo "WARN optional src missing: $abs_src" >&2
    fi
    k=$((k + 1))
    continue
  fi

  # Step 3 (claude-agent-pipeline#51, advisory note 1): final-component resolution — if
  # src itself is a symlink, its target must ALSO resolve inside MAIN. Steps 1-2 alone
  # inspect only the DIRECTORY, so a symlink already committed in MAIN (e.g. a "devkey"
  # entry pointing at ~/.ssh/id_ed25519) would otherwise pass both and get linked
  # straight into the worktree, where every agent reads freely. dst is deliberately NOT
  # re-resolved here: any pre-existing dst symlink is atomically replaced by `ln -sfn`
  # below, never followed, so only the src side can leak a foreign target.
  if [ -L "$abs_src" ]; then
    src_dir_phys="$(cd "$(dirname "$abs_src")" && pwd -P)"
    tgt="$(readlink "$abs_src")"
    case "$tgt" in
      /*) resolved="$tgt" ;;
      *) resolved="$src_dir_phys/$tgt" ;;
    esac
    resolved_dir="$(cd "$(dirname "$resolved")" 2>/dev/null && pwd -P)" || resolved_dir=""
    if [ -z "$resolved_dir" ] || ! phys_contained "$resolved_dir" "$MAIN_PHYS"; then
      echo "MISSING-SRC $abs_src (link escapes MAIN)" >&2
      missing+=("$abs_src")
      k=$((k + 1))
      continue
    fi
  fi

  # dst already a REAL (non-symlink) path — never touch it. Without this
  # guard, `ln -sfn` on an existing real directory does not replace it (unlink
  # on a non-empty directory fails); instead it silently nests a new symlink
  # INSIDE it (named after src's basename), reproducing the exact
  # `.venv/.venv` self-loop pollution observed live in production
  # (a real incident). A pre-existing SYMLINK dst is fine
  # — it falls through and gets atomically replaced below.
  if [ ! -L "$abs_dst" ] && src_exists "$abs_dst"; then
    echo "SKIPPED-REAL-PATH $abs_dst (already a real path, not a symlink — left untouched)"
    k=$((k + 1))
    continue
  fi

  # Step 2 (claude-agent-pipeline#51/#53): physical containment — the JS-side guard
  # cannot assert this (no module imports, so no path.resolve/realpath there); this is
  # the half only the shell can do, and it also catches a hostile SYMLINKED
  # INTERMEDIATE DIRECTORY already present in the worktree/MAIN (a plain lexical check
  # on src/dst strings would miss that). This MUST run BEFORE any `mkdir -p` — a hostile
  # dst (e.g. a segment escaping WT via a pre-existing symlinked ancestor) must never
  # get a directory created on its behalf first (claude-agent-pipeline#53: mkdir ran
  # before this check, so a rejected path could still leave a created directory behind).
  # existing_ancestor() lets the check run against a not-yet-created dst by walking up
  # to the nearest real ancestor.
  dst_parent="$(dirname "$abs_dst")"
  if ! dir_contained "$(existing_ancestor "$dst_parent")" "$WT_PHYS"; then
    echo "MISSING-SRC $abs_src (destination escapes WT)" >&2
    missing+=("$abs_src"); k=$((k + 1)); continue
  fi
  if ! dir_contained "$(dirname "$abs_src")" "$MAIN_PHYS"; then
    echo "MISSING-SRC $abs_src (source escapes MAIN)" >&2
    missing+=("$abs_src"); k=$((k + 1)); continue
  fi

  mkdir -p "$dst_parent"

  # -n is load-bearing: without it, `ln` (given -s -f but no -n) treats an
  # EXISTING symlink-to-directory dst as the directory itself and writes the
  # new link INSIDE it (reproduced live) — `-sfn` replaces the
  # link atomically instead.
  # Verify via src_exists too — the destination path can match the same
  # sandbox-denied filenames as the source (e.g. "<worktree>/.env").
  if ln -sfn "$abs_src" "$abs_dst" 2>/dev/null && src_exists "$abs_dst"; then
    echo "LINKED $dst -> $abs_src"
  else
    echo "MISSING-SRC $abs_src (link creation/verification failed)" >&2
    if [ "$hard" -eq 1 ]; then
      missing+=("$abs_src")
    fi
  fi
  k=$((k + 1))
done

missing_n=${#missing[@]}
if [ "$missing_n" -gt 0 ]; then
  echo "PROVISION-FAILED: ${missing_n} link(s)" >&2
  mi=0
  while [ "$mi" -lt "$missing_n" ]; do
    echo "${missing[$mi]}" >&2
    mi=$((mi + 1))
  done
  exit 2
fi

exit 0
