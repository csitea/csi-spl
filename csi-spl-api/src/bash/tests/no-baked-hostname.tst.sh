#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 007 T017 — no baked hostname in Go. The product domain
#          (env.dns.BASE_DOMAIN) is cnf; Go reads $SPOOL_HUB_URL /
#          $SPOOL_HUB_TENANT_HOST_PATTERN. Same match as domain-single-source
#          (literal, escaped, split label+".tld") scoped to *.go.
#
#          CONTROLS: a guard that finds nothing proves nothing unless it is
#          shown to find something. Control 1 plants the domain in a scratch
#          .go and requires that hit (escaped + split too); control 2 requires
#          a {tenant}.<domain> placeholder, .hub.test and .invalid to pass;
#          control 3: an empty BASE_DOMAIN is an error, not a vacuous pass.
#------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$HERE/../../../.." && pwd)"
GO="$HERE/../../go"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# domain_hits <root> <all.env.yaml> -> prints offending files; rc 2 if no domain
domain_hits() {
  local root="$1" cnf="$2" domain label label_re tld tld_re
  domain=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$cnf" 2>/dev/null)
  [[ -n "$domain" && "$domain" != null && "$domain" == *.* ]] || return 2
  label="${domain%.*}" tld="${domain##*.}"
  label_re=$(printf '%s' "$label" | sed 's/[.\\]/\\&/g')
  tld_re=$(printf '%s' "$tld" | sed 's/[.\\]/\\&/g')
  grep -rIlE --include='*.go' -- \
    "${label_re}[\"' +\\]*\.${tld_re}([^A-Za-z0-9-]|$)" "$root" 2>/dev/null |
    sed "s#^$root/##" || true
}

CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
[[ -f "$CNF" ]] || { echo "FAIL: missing $CNF"; exit 1; }
[[ -d "$GO" ]] || { echo "FAIL: missing $GO"; exit 1; }
n=$(find "$GO" -name '*.go' -type f | wc -l)
[[ "$n" -ge 1 ]] && pass "Go tree has $n .go file(s)" || fail "no .go files under $GO"

# --- the real tree ------------------------------------------------------------
hits=$(domain_hits "$GO" "$CNF"); rc=$?
if [[ $rc -ne 0 ]]; then fail "could not read env.dns.BASE_DOMAIN from $CNF (rc=$rc)"
elif [[ -z "$hits" ]]; then pass "Go source does not bake env.dns.BASE_DOMAIN"
else fail "the domain literal appears in Go:"; printf '      %s\n' $hits; fi

# --- control 1: planted literal / escaped / split are found -------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
d=$(yq -r '.env.dns.BASE_DOMAIN' "$CNF")
printf 'host := "%s"\n' "$d" >"$tmp/literal.go"
printf 'host := "%s"\n' "${d//./\\.}" >"$tmp/escaped.go"
printf 'host := "%s" + ".%s"\n' "${d%.*}" "${d##*.}" >"$tmp/split.go"
printf 'const domain = ".hub.test"\n// HubURL is https://<tenant>.<domain>\nHubURL = "http://" + tid + ".unreachable.invalid"\n' >"$tmp/ok.go"

hits=$(domain_hits "$tmp" "$CNF")
[[ "$(sort <<<"$hits" | tr '\n' ' ')" == "escaped.go literal.go split.go " ]] \
  && pass "control: planted literal + escaped + split in .go are caught; .hub.test / .invalid / <domain> placeholder are not" \
  || fail "control: expected exactly escaped.go literal.go split.go, got: ${hits:-<nothing>}"

# --- control 2: empty domain fails instead of matching nothing ----------------
printf 'env:\n  dns:\n    BASE_DOMAIN: ""\n' >"$tmp/empty.yaml"
domain_hits "$tmp" "$tmp/empty.yaml" >/dev/null; rc=$?
[[ $rc -eq 2 ]] && pass "control: an empty BASE_DOMAIN is an error, not a vacuous pass" \
  || fail "control: empty BASE_DOMAIN returned rc=$rc"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
