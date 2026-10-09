#!/usr/bin/env bash
# Invariants 16 to 18: the backlog plugin bump, pin and suite (sourced by tests/templates/test-canonical-guards.sh, never executed).
# =============================================================================
# Invariant 16 — backlog-bump-required
# =============================================================================
# #218: plugins/backlog/ is a SEPARATE plugin with its own manifest and version, excluded from
# invariant 1 by name. Same delivery rule, scoped to it: a change to its shipped surface without a
# bump of ITS version delivers nothing to an installed cache. Watched = everything under
# plugins/backlog/ except tests/ and README.md (no execution surface). A brand-new plugin (manifest
# absent on origin/main) passes with its initial version.
BL_DIR="plugins/backlog"
BL_MANIFEST="$BL_DIR/.claude-plugin/plugin.json"
if [ ! -f "$BL_MANIFEST" ]; then
  fail "backlog-bump-required" "$BL_MANIFEST does not exist"
elif ! git rev-parse --verify origin/main >/dev/null 2>&1; then
  fail "backlog-bump-required" "origin/main not resolvable in this checkout — run 'git fetch origin main' first"
else
  BL_NEW_VERSION="$(python3 -c "import json; print(json.load(open('$BL_MANIFEST')).get('version',''))" 2>/dev/null)"
  if [ -z "$BL_NEW_VERSION" ]; then
    fail "backlog-bump-required" "could not read the version of $BL_MANIFEST"
  elif ! git cat-file -e "origin/main:$BL_MANIFEST" 2>/dev/null; then
    pass "backlog-bump-required: new plugin (no $BL_MANIFEST on origin/main), initial version $BL_NEW_VERSION"
  elif git diff --quiet origin/main -- "$BL_DIR" ":(exclude)$BL_DIR/tests/" ":(exclude)$BL_DIR/README.md"; then
    pass "backlog-bump-required: no watched-surface diff under $BL_DIR against origin/main (inert on this checkout)"
  else
    BL_CHANGED="$(git diff --name-only origin/main -- "$BL_DIR" ":(exclude)$BL_DIR/tests/" ":(exclude)$BL_DIR/README.md" | head -1)"
    BL_OLD_VERSION="$(git show "origin/main:$BL_MANIFEST" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null)"
    if [ -z "$BL_OLD_VERSION" ]; then
      fail "backlog-bump-required" "could not read origin/main's $BL_MANIFEST version"
    elif [ "$BL_OLD_VERSION" = "$BL_NEW_VERSION" ]; then
      fail "backlog-bump-required" "$BL_CHANGED changed without a version bump (still $BL_NEW_VERSION)"
    else
      pass "backlog-bump-required: watched surface changed, version bumped $BL_OLD_VERSION -> $BL_NEW_VERSION"
    fi
  fi
fi

# =============================================================================
# Invariant 17 — backlog-marketplace-pin
# =============================================================================
# #218: the `backlog` catalog entry is a git-subdir source scoped to plugins/backlog with a 40-hex
# sha that resolves in this repo, and its name matches the plugin manifest. Until the human's
# publish PR moves it, the sha is the lgtmgate's current pin (a commit that has no
# plugins/backlog/), so an install FAILS CLOSED instead of tracking main unpinned.
if [ ! -f "$MARKETPLACE" ] || [ ! -f "$BL_MANIFEST" ]; then
  fail "backlog-marketplace-pin" "$MARKETPLACE or $BL_MANIFEST missing"
else
  BL_PIN="$(python3 -c "
import json
d = json.load(open('$MARKETPLACE'))
m = json.load(open('$BL_MANIFEST'))
entries = [p for p in d.get('plugins', []) if p.get('name') == 'backlog']
if not entries:
    print('ERR:no entry named backlog')
else:
    e = entries[0]
    s = e.get('source')
    if not isinstance(s, dict):
        print('ERR:source is not an object')
    elif s.get('source') != 'git-subdir':
        print('ERR:source.source is ' + repr(s.get('source')) + ', not git-subdir')
    elif s.get('path') != 'plugins/backlog':
        print('ERR:source.path is ' + repr(s.get('path')) + ', not plugins/backlog')
    elif e.get('name') != m.get('name'):
        print('ERR:entry name differs from the manifest name')
    else:
        print('SHA:' + str(s.get('sha', '')))
" 2>/dev/null)"
  case "$BL_PIN" in
    ERR:*)
      fail "backlog-marketplace-pin" "${BL_PIN#ERR:}"
      ;;
    SHA:*)
      BL_SHA="${BL_PIN#SHA:}"
      if ! echo "$BL_SHA" | grep -qE '^[0-9a-f]{40}$'; then
        fail "backlog-marketplace-pin" "source.sha '$BL_SHA' is not a 40-hex commit SHA"
      elif ! git cat-file -e "${BL_SHA}^{commit}" 2>/dev/null; then
        fail "backlog-marketplace-pin" "source.sha $BL_SHA does not resolve to a commit in this repo"
      else
        pass "backlog-marketplace-pin: backlog is a git-subdir source at plugins/backlog pinned to $BL_SHA (a 40-hex commit that resolves)"
      fi
      ;;
    *)
      fail "backlog-marketplace-pin" "could not evaluate the backlog entry of $MARKETPLACE (python3 error or empty result)"
      ;;
  esac
fi

# =============================================================================
# Invariant 18 — backlog-suite
# =============================================================================
# #218: every backlog skill ships `disable-model-invocation: true` (zero always-loaded context), the
# manifest's hooks file exists, and the plugin's own offline unittest suite (fake gh on PATH, no
# network) is green. The suite's stderr carries the unittest summary; its last line must start with OK.
BL_SKILLS="$(ls "$BL_DIR"/skills/*/SKILL.md 2>/dev/null)"
BL_BAD_SKILLS=""
for f in $BL_SKILLS; do
  if ! grep -q '^disable-model-invocation: true$' "$f"; then
    BL_BAD_SKILLS="$BL_BAD_SKILLS $f"
  fi
done
BL_HOOKS_REL="$(python3 -c "import json; print(json.load(open('$BL_MANIFEST')).get('hooks',''))" 2>/dev/null)"
if [ -z "$BL_SKILLS" ]; then
  fail "backlog-suite" "no $BL_DIR/skills/*/SKILL.md found"
elif [ -n "$BL_BAD_SKILLS" ]; then
  fail "backlog-suite" "skill(s) without 'disable-model-invocation: true':$BL_BAD_SKILLS"
elif [ -z "$BL_HOOKS_REL" ] || [ ! -f "$BL_DIR/$BL_HOOKS_REL" ]; then
  fail "backlog-suite" "manifest hooks file '$BL_HOOKS_REL' does not exist under $BL_DIR"
else
  BL_OUT="$(PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s "$BL_DIR/tests" 2>&1 >/dev/null)"
  BL_EXIT=$?
  BL_LAST="$(echo "$BL_OUT" | tail -1)"
  BL_RAN="$(echo "$BL_OUT" | grep -E '^Ran [0-9]+ tests? ' | head -1)"
  if [ "$BL_EXIT" -ne 0 ]; then
    fail "backlog-suite" "unittest exited $BL_EXIT: $(echo "$BL_OUT" | tail -5 | tr '\n' ' ')"
  elif ! echo "$BL_LAST" | grep -qE '^OK'; then
    fail "backlog-suite" "unittest output does not end with OK (last line: $BL_LAST)"
  else
    pass "backlog-suite: skills all disable-model-invocation, hooks file present, offline suite green ($BL_RAN; $BL_LAST)"
  fi
fi

