#!/usr/bin/env bash
# post-merge-install.sh — sourced by scripts/lead-merge.sh (#731), never executed directly.
#
# lm_post_merge_install <plugin> <merged_ver>: called once, after the merge was read back as merged and in a plugin repo only. The merged
# engine only runs once the installed plugin is updated and the session restarted (#233), so the hint alone left a stale install at every
# merge. The helper lists the installs with `scripts/plugin-versions.sh --check --target <merged_ver>` (user installs, installs of this
# repo's main checkout and installs scoped to its worktrees) and runs `claude plugin update <plugin>@<channel> --scope <scope>` for each
# stale install of scope user or of the main checkout, from the project directory. A stale install of a worktree or of another project is
# never touched: its exact command and directory are printed. Never `--yes`: a marketplace-declared command is shown to a person.
# It then prints the sessions to restart. Any failure (claude missing, listing exit 2, an update refused) prints the manual hint with
# the reason; the exit code of a merged PR never changes (always returns 0).
# Needs $SCRIPT_DIR (the directory of lead-merge.sh, which holds plugin-versions.sh); $LM_MAIN_CHECKOUT (the main checkout, read before
# a --cleanup removes the worktree this script runs from) is optional.

# lm_install_hint <plugin> <ver> <reason>: the manual form of the update (the pre-#731 hint) with the reason the automatic one did not run
lm_install_hint() {
  echo "lead-merge: plugin $1 $2 merged; update the install ($3): claude plugin update $1@<marketplace> --scope <scope>, then restart the session (scripts/plugin-versions.sh --check lists the installs)"
}

lm_post_merge_install() {
  local plugin="${1:-}" ver="${2:-}" main rc=0 out reason line scope proj chan cmd updated="" stale="" real_main real_proj
  main="${LM_MAIN_CHECKOUT:-}"
  if [ -z "$main" ] || [ ! -d "$main" ]; then
    main="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')" || main=""
  fi
  if [ -z "$main" ] || [ ! -d "$main" ]; then
    lm_install_hint "$plugin" "$ver" "cannot find the main checkout"
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    lm_install_hint "$plugin" "$ver" "the claude CLI is not on PATH"
    return 0
  fi
  out="$(cd "$main" && bash "$SCRIPT_DIR/plugin-versions.sh" --check --plugin "$plugin" --target "$ver" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    reason="$(printf '%s\n' "$out" | tail -n 1)"
    lm_install_hint "$plugin" "$ver" "plugin-versions.sh --check could not decide: $reason"
    return 0
  fi
  real_main="$(cd "$main" && pwd -P)"
  while IFS= read -r line; do
    case "$line" in *" MISMATCH:"*) ;; *) continue ;; esac
    case "$line" in user\ project=*|local\ project=*|project\ project=*) ;; *) continue ;; esac
    scope="${line%% *}"
    proj="$(printf '%s\n' "$line" | sed -n 's/^[a-z]* project=\(.*\) channel=[^ ]* enabled=.*/\1/p')"
    chan="$(printf '%s\n' "$line" | sed -n 's/^.* channel=\([^ ]*\) enabled=.*/\1/p')"
    [ -n "$scope" ] && [ -n "$chan" ] || continue
    cmd="claude plugin update $plugin@$chan --scope $scope"
    real_proj=""
    if [ "$scope" != "user" ] && [ -d "$proj" ]; then real_proj="$(cd "$proj" && pwd -P)"; fi
    if [ "$scope" = "user" ] || [ "$real_proj" = "$real_main" ]; then
      if (cd "$main" && $cmd </dev/null >/dev/null 2>&1); then
        echo "lead-merge: updated $plugin@$chan scope=$scope to $ver"
        if [ "$proj" = "-" ]; then updated="$updated (all user-scope sessions)"; else updated="$updated $proj"; fi
      else
        echo "lead-merge: update refused or failed for $plugin@$chan scope=$scope; run by hand from $main: $cmd"
        stale="$stale $main"
      fi
    else
      echo "lead-merge: still stale ($scope install of $proj, channel $chan): run from $proj: $cmd"
      stale="$stale $proj"
    fi
  done <<EOF
$out
EOF
  if [ -z "$updated" ] && [ -z "$stale" ]; then
    echo "lead-merge: plugin $plugin $ver merged; no stale install of the plugin found (scripts/plugin-versions.sh --check)"
    return 0
  fi
  echo "lead-merge: restart these sessions:$updated$stale"
  return 0
}
