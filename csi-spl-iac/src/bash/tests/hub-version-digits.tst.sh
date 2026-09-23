#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every component of the hub version is a SINGLE DIGIT, 0-9.
#
#          Owner's rule, 2026-09-23: "the tags 0.1.25 should not be allowed
#          [...] after 9 follows 0 and the minor version is increased". The
#          version is an odometer, not three free integers: 0.3.9 is followed
#          by 0.4.0, and 0.9.9 by 1.0.0.
#
#          It had already drifted 16 releases before anyone looked. The carry
#          should have fired at 0.1.9; instead the patch ran 0.1.10 .. 0.1.25,
#          so the published series does not mean what the scheme says it
#          means. Those tags are in both Artifact Registries and are
#          immutable, so the correction is forward-only: 0.1.25 unwinds to
#          0.3.5 and the next release is 0.3.6.
#
#          That is exactly why this is a gate and not a paragraph in a README.
#          Nothing compared the number against the rule, and a hand-edited
#          `tag:` looks equally plausible at 0.1.9 and at 0.1.10 - the drift
#          is invisible one bump at a time and obvious only in hindsight,
#          across sixteen of them.
#
#          Checks EVERY .version in the tree (the repo root and each
#          component, e.g. csi-spl-wui), every package.json version field, and
#          hub.image.tag in every env file,
#          so a bump that edits one and forgets the other is caught by
#          whichever of the two is out of range. (hub-version-tag-parity.tst.sh
#          is the one that checks they EQUAL each other; this one checks that
#          what they say is well formed. Both are needed: two files can agree
#          perfectly on an illegal number.)
#
#          CONTROLS: a guard that finds nothing proves nothing unless it is
#          shown to find something. Control 1 plants 0.1.10 - the exact shape
#          that drifted - and requires a refusal. Control 2 plants a version
#          with a missing component. Control 3 requires an EMPTY version to
#          fail rather than pass vacuously against an empty pattern.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# digits <version> -> rc 0 when it is <0-9>.<0-9>.<0-9>; prints why when not.
digits() {
  local v="${1-}"
  if [[ -z "$v" ]]; then
    echo "empty"
    return 1
  fi
  if [[ ! "$v" =~ ^[0-9]\.[0-9]\.[0-9]$ ]]; then
    # Name the offending component, so the message says what to do rather
    # than only that something is wrong.
    local IFS=. part i=0 name
    read -ra part <<<"$v"
    if [[ ${#part[@]} -ne 3 ]]; then
      echo "\"$v\" is not major.minor.patch"
      return 1
    fi
    for i in 0 1 2; do
      name=$([[ $i -eq 0 ]] && echo major || { [[ $i -eq 1 ]] && echo minor || echo patch; })
      if [[ ! "${part[$i]}" =~ ^[0-9]$ ]]; then
        echo "$name \"${part[$i]}\" is not a single digit; after 9 comes 0 and the next component up increments"
        return 1
      fi
    done
    echo "\"$v\" is malformed"
    return 1
  fi
  return 0
}

# ---- every .version in the tree ---------------------------------------------
# The owner's rule is the APP's, not the hub's: csi-spl-wui/.version and its
# package.json carry the same number, and a component left behind is the same
# drift one directory down. Discovered, not listed, so a new component cannot
# be added without being covered.
found=0
while IFS= read -r vf; do
  [[ -f "$vf" ]] || continue
  found=$((found + 1))
  rel="${vf#"$APP_ROOT"/}"
  v=$(tr -d '[:space:]' <"$vf" 2>/dev/null)
  if why=$(digits "$v"); then
    pass "$rel $v: every component is a single digit"
  else
    fail "$rel: $why"
  fi
done < <(find "$APP_ROOT" -name .version -not -path '*/node_modules/*' -not -path '*/.git/*' \
  -not -path "$APP_ROOT/tpl-gen/*" | sort)
[[ "$found" -gt 0 ]] || fail "no .version file found at all (the check would pass vacuously)"

# package.json version fields, where a component keeps its own copy.
if command -v node >/dev/null; then
  while IFS= read -r pj; do
    rel="${pj#"$APP_ROOT"/}"
    v=$(node -e 'try{process.stdout.write(String(require(process.argv[1]).version||""))}catch(e){}' "$pj")
    [[ -n "$v" ]] || continue
    if why=$(digits "$v"); then
      pass "$rel version $v: every component is a single digit"
    else
      fail "$rel version: $why"
    fi
  done < <(find "$APP_ROOT" -name package.json -not -path '*/node_modules/*' -not -path '*/.git/*' \
    -not -path "$APP_ROOT/tpl-gen/*" | sort)
fi

# ---- every env's hub.image.tag ----------------------------------------------
if command -v yq >/dev/null; then
  for f in "$APP_ROOT"/csi-spl-cnf/csi-spl/*.env.yaml; do
    [[ -f "$f" ]] || continue
    env=$(basename "$f" .env.yaml)
    [[ "$env" != "all" ]] || continue
    tag=$(yq -r '.env.hub.image.tag // ""' "$f" 2>/dev/null)
    # An env file that pins no tag inherits all.env.yaml; nothing to check.
    [[ -n "$tag" && "$tag" != null ]] || continue
    if why=$(digits "$tag"); then
      pass "$env.env.yaml hub.image.tag $tag: every component is a single digit"
    else
      fail "$env.env.yaml hub.image.tag: $why"
    fi
  done
else
  echo "SKIP: yq not installed; only .version checked"
fi

# ---- CONTROLS ---------------------------------------------------------------
# 1: the exact shape that drifted for 16 releases.
if digits "0.1.10" >/dev/null; then
  fail "CONTROL: 0.1.10 was accepted - the gate does not implement the rule"
else
  pass "CONTROL: 0.1.10 is refused (patch 10; it should have carried to 0.2.0)"
fi
# 2: a missing component.
if digits "1.2" >/dev/null; then
  fail "CONTROL: 1.2 was accepted"
else
  pass "CONTROL: 1.2 is refused (not major.minor.patch)"
fi
# 3: empty must FAIL, not match vacuously.
if digits "" >/dev/null; then
  fail "CONTROL: an empty version was accepted"
else
  pass "CONTROL: an empty version is refused, not an empty-pattern match"
fi
# 4: and the legal shapes still pass, or the gate is red for everything.
for ok in 0.0.0 0.3.6 9.9.9; do
  if digits "$ok" >/dev/null; then
    pass "CONTROL: $ok is accepted"
  else
    fail "CONTROL: the legal version $ok was refused"
  fi
done

[[ "$fails" -eq 0 ]] && echo "PASS: all hub-version-digits.tst.sh assertions"
exit "$fails"
