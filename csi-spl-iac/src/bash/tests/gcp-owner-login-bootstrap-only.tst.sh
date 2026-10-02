#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: only the one-time human bootstrap gcp-000..004 may reach the owner
#          account (CLE-77937, owner order 2026-10-02: "all of the service
#          account stuff should run with the env service account ... not me
#          with my uber admin gcp auth"). Every other action and shared body
#          runs as the per-env SA from its key (do_gcp_account /
#          do_gcp_pin_account); a permission it lacks is granted SA-to-SA by
#          do_gcp_003_configure_proj_sa_permissions.
#
#          Scans every .sh under csi-spl-iac {src/bash/run,lib} and csi-spl-orc
#          {src/bash/run,lib} for the four ways to reach the owner identity:
#            - an interactive `gcloud auth login` / `auth application-default login`
#            - the bootstrap resolver do_gcp_(pin_)bootstrap_account
#            - the owner address key gcp_account_owner_email / GCP_ACCOUNT_OWNER_EMAIL
#          A comment line is not a use. Allowed: gcp-00[0-4]-*.func.sh and the
#          resolver gcp-account-pin.func.sh itself.
#
#          CONTROLS: a planted offender in a copy of the tree is caught (so the
#          scan is not blind), and do_gcp_account REFUSES with no key and no
#          ACCOUNT even when the cnf names an owner address.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

OWNER_RE='gcloud auth (application-default )?login|do_gcp_(pin_)?bootstrap_account|gcp_account_owner_email|GCP_ACCOUNT_OWNER_EMAIL'

# offenders <root> - print "<file>:<line>" for every non-comment owner reach
# outside the allow-list, one per line.
offenders() {
  local root="$1" f
  while IFS= read -r f; do
    case "$(basename "$f")" in gcp-00[0-4]-*.func.sh|gcp-account-pin.func.sh) continue ;; esac
    grep -nE "$OWNER_RE" "$f" | grep -vE '^[0-9]+:\s*#' | sed "s|^|${f#"$root"/}:|"
  done < <(find "$root"/csi-spl-iac/src/bash/run "$root"/csi-spl-iac/lib \
                "$root"/csi-spl-orc/src/bash/run "$root"/csi-spl-orc/lib -name '*.sh' -type f 2>/dev/null)
}

# --- 1. the tree: nothing outside the bootstrap reaches the owner -------------
n=$(find "$APP_ROOT"/csi-spl-iac/src/bash/run "$APP_ROOT"/csi-spl-orc/src/bash/run -name '*.func.sh' | wc -l)
[[ "$n" -ge 100 ]] && pass "scanning $n run actions" || fail "only $n run actions found: the scan is blind"
out=$(offenders "$APP_ROOT")
[[ -z "$out" ]] && pass "no action outside gcp-000..004 reaches the owner account" \
  || fail "owner-account reach outside the gcp-000..004 bootstrap (use do_gcp_account / do_gcp_pin_account):
$out"

# the bootstrap still does (else the allow-list is dead weight and this proves nothing)
grep -lE "$OWNER_RE" "$APP_ROOT"/csi-spl-iac/src/bash/run/gcp-00[0-4]-*.func.sh >/dev/null \
  && pass "the gcp-000..004 bootstrap is the place that resolves the owner" \
  || fail "no gcp-00x action reaches the owner: the allow-list is stale"

# --- 2. CONTROL: a planted offender is caught; a comment is not ----------------
mkdir -p "$T/tree/csi-spl-iac/src/bash/run" "$T/tree/csi-spl-iac/lib" "$T/tree/csi-spl-orc/src/bash/run" "$T/tree/csi-spl-orc/lib"
printf '#!/bin/bash\n# gcloud auth login is only named here\ndo_x(){ :; }\n' >"$T/tree/csi-spl-iac/src/bash/run/x-comment.func.sh"
printf '#!/bin/bash\ndo_x(){ gcloud auth login --update-adc; }\n' >"$T/tree/csi-spl-iac/src/bash/run/gcp-project-apis-x.func.sh"
printf '#!/bin/bash\ndo_y(){ do_gcp_pin_bootstrap_account; }\n' >"$T/tree/csi-spl-orc/lib/y.func.sh"
printf '#!/bin/bash\ndo_z(){ gcloud auth login; }\n' >"$T/tree/csi-spl-iac/src/bash/run/gcp-003-z.func.sh"
out=$(offenders "$T/tree")
[[ "$out" == *gcp-project-apis-x.func.sh:2:* && "$out" == *y.func.sh:2:* ]] \
  && pass "CONTROL: a planted login and a planted bootstrap resolver are caught" || fail "CONTROL: planted offenders missed: '$out'"
[[ "$out" != *x-comment* && "$out" != *gcp-003-z* ]] \
  && pass "CONTROL: a comment and the gcp-00x allow-list are not flagged" || fail "CONTROL: false positive: '$out'"

# --- 3. CONTROL: the run resolver refuses the owner even when the cnf names one --
mkdir -p "$T/cnf" "$T/home"
printf 'env:\n  gcp:\n    gcp_account_owner_email: owner@example.com\n' >"$T/cnf/all.env.yaml"
res=$(env -u ACCOUNT -u GCP_ACCOUNT -u GCP_SA_KEY_FILE -u CLOUDSDK_CONFIG HOME="$T/home" ORG=csi APP=spl ENV=dev \
  PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh" CNF="$T/cnf" \
  bash -c 'do_log(){ :; }; gcloud(){ echo CALLED; }; source "$PIN"; do_gcp_account "$CNF"; echo "rc=$?"' 2>/dev/null)
[[ "$res" == "rc=1" ]] && pass "do_gcp_account refuses (no key, no ACCOUNT) instead of falling back to the owner" \
  || fail "do_gcp_account with no key resolved: '$res'"
if command -v yq >/dev/null; then
  res=$(env -u ACCOUNT -u GCP_ACCOUNT -u GCP_SA_KEY_FILE -u GCP_ACCOUNT_OWNER_EMAIL HOME="$T/home" ORG=csi APP=spl ENV=dev \
    PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh" CNF="$T/cnf" \
    bash -c 'do_log(){ :; }; source "$PIN"; do_gcp_bootstrap_account "$CNF"' 2>/dev/null)
  [[ "$res" == owner@example.com ]] && pass "CONTROL: the bootstrap resolver does read that owner address (the refusal above is real)" \
    || fail "CONTROL: bootstrap resolver gave '$res'"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
