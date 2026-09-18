#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the spool domain has ONE source, env.dns.BASE_DOMAIN in
#          csi-spl-cnf/csi-spl/all.env.yaml. Outside csi-spl-cnf/ (config and
#          its generated renders) and csi-spl-doc/ (docs explaining the config)
#          no tracked file may contain it.
#
#          The domain is READ from the config, never written here, and the
#          search is for its label without the TLD, so an escaped regex form
#          (label\.tld) or a split string is caught as well.
#
#          CONTROLS: a guard that finds nothing proves nothing unless it is
#          shown to find something. Control 1 plants the literal in a
#          disallowed path of a scratch tree and requires exactly that hit;
#          control 2 requires an empty BASE_DOMAIN to FAIL rather than pass
#          with an empty pattern.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# domain_violations <root> <all.env.yaml> -> prints offending files; rc 2 if no domain
domain_violations() {
  local root="$1" cnf="$2" domain label label_re
  domain=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$cnf" 2>/dev/null)
  [[ -n "$domain" && "$domain" != null && "$domain" == *.* ]] || return 2
  label="${domain%.*}"
  # Match the label only at a real domain boundary: the label followed by a
  # non-[A-Za-z0-9-] char (a dot, an escaped dot, a quote) or end-of-line. This
  # still catches the BASE_DOMAIN literal and its escaped/split forms, but a
  # legitimate identifier that merely STARTS with the label (e.g. a
  # "<label>-api" module directory) is no longer a false positive. (-E, not -F.)
  label_re=$(printf '%s' "$label" | sed 's/[.\\]/\\&/g')
  grep -rIlE --exclude-dir=.git --exclude-dir=tpl-gen --exclude-dir=bin --exclude-dir=log \
    -- "${label_re}([^A-Za-z0-9-]|$)" "$root" 2>/dev/null |
    sed "s#^$root/##" |
    grep -vE '^(csi-spl-cnf|csi-spl-doc)/' || true
}

CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"

# --- the real tree ------------------------------------------------------------
[[ -f "$CNF" ]] || { echo "FAIL: missing $CNF"; exit 1; }
hits=$(domain_violations "$APP_ROOT" "$CNF"); rc=$?
if [[ $rc -ne 0 ]]; then fail "could not read env.dns.BASE_DOMAIN from $CNF (rc=$rc)"
elif [[ -z "$hits" ]]; then pass "the domain appears only under csi-spl-cnf/ and csi-spl-doc/"
else fail "the domain literal appears outside csi-spl-cnf/ and csi-spl-doc/:"; printf '      %s\n' $hits; fi

# --- control 1: a planted literal in a disallowed path is found ---------------
tmp=$(mktemp -d)
mkdir -p "$tmp/csi-spl-cnf/csi-spl" "$tmp/csi-spl-doc" "$tmp/csi-spl-iac/src" "$tmp/tpl-gen"
cp "$CNF" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml"
d=$(yq -r '.env.dns.BASE_DOMAIN' "$CNF")
printf 'allowed %s\n' "$d" >"$tmp/csi-spl-doc/ok.md"
printf 'ignored %s\n' "$d" >"$tmp/tpl-gen/ignored.txt"
printf 'host="%s"\n' "${d//./\\.}" >"$tmp/csi-spl-iac/src/planted.sh"
hits=$(domain_violations "$tmp" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml")
[[ "$hits" == "csi-spl-iac/src/planted.sh" ]] && pass "control: a planted (escaped) literal in csi-spl-iac is caught, allowed dirs are not" \
  || fail "control: expected exactly csi-spl-iac/src/planted.sh, got: ${hits:-<nothing>}"

# --- control 2: an empty domain fails instead of matching nothing -------------
printf 'env:\n  dns:\n    BASE_DOMAIN: ""\n' >"$tmp/csi-spl-cnf/csi-spl/all.env.yaml"
domain_violations "$tmp" "$tmp/csi-spl-cnf/csi-spl/all.env.yaml" >/dev/null; rc=$?
[[ $rc -eq 2 ]] && pass "control: an empty BASE_DOMAIN is an error, not a vacuous pass" || fail "control: empty BASE_DOMAIN returned rc=$rc"
rm -rf "$tmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
