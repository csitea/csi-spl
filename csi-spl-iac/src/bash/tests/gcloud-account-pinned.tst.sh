#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the gcloud identity is pinned from the yaml conf, never ambient
#          (owner rule 2026-09-19).
#   1. do_gcp_account resolves ACCOUNT > GCP_ACCOUNT > GCP_ACCOUNT_OWNER_EMAIL
#      > cnf env.gcp.gcp_account_owner_email (an env file overrides all.env.yaml).
#   2. CONTROL: no env and no conf key -> refused, naming the yaml key, and
#      WITHOUT asking gcloud (the csi-rel "active account" fallback is gone).
#   3. do_gcp_org_id: GCP_ORG_ID > cnf env.gcp.gcp_org_id.
#   4. The csi-spl-iac and csi-spl-orc copies of the lib are byte-identical.
#   5. SCAN: every `gcloud` / `gsutil` invocation under csi-spl-{iac,orc}
#      src/bash/{run,scripts,features} and lib carries --account (continuation
#      lines joined; only `gcloud auth ...` / `gcloud config ...` allow-listed).
#      An allow-list cannot prove absence, so the total the scan saw is printed
#      and must clear a floor, and a planted unpinned call must be caught.
#   6. The account / org values appear in the tree ONLY in the cnf yaml (and
#      the rendered <env>.env.json). The values are read from the yaml here,
#      so this file carries neither literal.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"
ORG_APP=$(basename "$PROJ_ROOT"); ORG_APP="${ORG_APP%-iac}"
CNF_DIR="$APP_ROOT/$ORG_APP-cnf/$ORG_APP"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

bash -n "$PIN" && pass "bash -n gcp-account-pin.func.sh" || fail "bash -n gcp-account-pin.func.sh"

want_acct=$(yq -r '.env.gcp.gcp_account_owner_email // ""' "$CNF_DIR/all.env.yaml")
want_org=$(yq -r '.env.gcp.gcp_org_id // ""' "$CNF_DIR/all.env.yaml")
[[ -n "$want_acct" && -n "$want_org" ]] && pass "all.env.yaml sets env.gcp.gcp_account_owner_email and gcp_org_id" \
  || fail "all.env.yaml lacks env.gcp.gcp_account_owner_email / gcp_org_id"

# a gcloud stub on PATH records any call: the resolution must make none
mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"%s/gcloud.log"\necho ambient@example.com\n' "$T" >"$T/stub/gcloud"
chmod +x "$T/stub/gcloud"; : >"$T/gcloud.log"

# resolve <fn> [VAR=value ...] -> stdout of <fn>; stderr to $T/err
resolve() {
  local fn="$1"; shift
  env -u ACCOUNT -u GCP_ACCOUNT -u GCP_ACCOUNT_OWNER_EMAIL -u GCP_ORG_ID \
    PIN="$PIN" FN="$fn" PATH="$T/stub:$PATH" APP_PATH="$APP_ROOT" ORG="${ORG_APP%%-*}" APP="${ORG_APP#*-}" ENV=dev "$@" \
    bash -c 'do_log(){ echo "$*"; }; source "$PIN"; "$FN"' 2>"$T/err"
}

# --- 1. precedence --------------------------------------------------------------
[[ "$(resolve do_gcp_account)" == "$want_acct" ]] && pass "no env: the account is cnf env.gcp.gcp_account_owner_email" \
  || fail "no env: got '$(resolve do_gcp_account)'"
[[ "$(resolve do_gcp_account GCP_ACCOUNT_OWNER_EMAIL=c@example.com)" == c@example.com ]] \
  && pass "an exported GCP_ACCOUNT_OWNER_EMAIL beats reading the yaml" || fail "GCP_ACCOUNT_OWNER_EMAIL ignored"
[[ "$(resolve do_gcp_account GCP_ACCOUNT=sa@example.com GCP_ACCOUNT_OWNER_EMAIL=c@example.com)" == sa@example.com ]] \
  && pass "GCP_ACCOUNT (e.g. CI's project SA) beats the conf" || fail "GCP_ACCOUNT did not win over the conf"
[[ "$(resolve do_gcp_account ACCOUNT=run@example.com GCP_ACCOUNT=sa@example.com)" == run@example.com ]] \
  && pass "ACCOUNT beats GCP_ACCOUNT" || fail "ACCOUNT did not win"

mkdir -p "$T/cnf"
printf 'env:\n  gcp:\n    gcp_account_owner_email: all@example.com\n    gcp_org_id: "111"\n' >"$T/cnf/all.env.yaml"
printf 'env:\n  gcp:\n    gcp_account_owner_email: dev@example.com\n' >"$T/cnf/dev.env.yaml"
printf 'env:\n  gcp:\n    gcp_project: x\n' >"$T/cnf/prd.env.yaml"
out_dev=$(env -u ACCOUNT -u GCP_ACCOUNT -u GCP_ACCOUNT_OWNER_EMAIL PIN="$PIN" ENV=dev bash -c 'do_log(){ :; }; source "$PIN"; do_gcp_account "$1"' _ "$T/cnf")
out_prd=$(env -u ACCOUNT -u GCP_ACCOUNT -u GCP_ACCOUNT_OWNER_EMAIL PIN="$PIN" ENV=prd bash -c 'do_log(){ :; }; source "$PIN"; do_gcp_account "$1"' _ "$T/cnf")
[[ "$out_dev" == dev@example.com && "$out_prd" == all@example.com ]] \
  && pass "an <env>.env.yaml value overrides all.env.yaml; absent, all.env.yaml applies" || fail "per-env override: dev='$out_dev' prd='$out_prd'"
yq eval-all '. as $i ireduce ({}; . * $i)' "$T/cnf/all.env.yaml" "$T/cnf/dev.env.yaml" >"$T/merged.yaml"
out_file=$(env -u ACCOUNT -u GCP_ACCOUNT -u GCP_ACCOUNT_OWNER_EMAIL PIN="$PIN" bash -c 'do_log(){ :; }; source "$PIN"; do_gcp_account "$1"' _ "$T/merged.yaml")
[[ "$out_file" == dev@example.com ]] && pass "a merged cnf FILE (orc's \$SPL_CNF) is read as is" || fail "cnf file: '$out_file'"

# --- 2. CONTROL: nothing resolves -> refused, gcloud never asked ------------------
: >"$T/gcloud.log"
out=$(resolve do_gcp_account APP_PATH="$T/nowhere"); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && grep -q 'env.gcp.gcp_account_owner_email' "$T/err" \
  && pass "CONTROL: no env and no conf key -> refused (rc=$rc), naming env.gcp.gcp_account_owner_email" \
  || fail "CONTROL: no account resolved yet rc=$rc out='$out' err='$(cat "$T/err")'"
[[ ! -s "$T/gcloud.log" ]] && pass "CONTROL: the refusal never asked gcloud for the active account" \
  || fail "the resolution called gcloud: $(cat "$T/gcloud.log")"
out=$(resolve do_gcp_pin_account APP_PATH="$T/nowhere"); rc=$?
[[ $rc -ne 0 ]] && pass "CONTROL: do_gcp_pin_account refuses too (rc=$rc)" || fail "do_gcp_pin_account did not refuse"
out=$(resolve 'do_gcp_pin_account' GCP_ACCOUNT= )
grep -q "account=$want_acct" <<<"$out" && pass "do_gcp_pin_account logs the pinned identity" || fail "no identity log line: $out"

# --- 3. org -------------------------------------------------------------------------
[[ "$(resolve do_gcp_org_id)" == "$want_org" ]] && pass "no env: the org is cnf env.gcp.gcp_org_id" || fail "org from cnf: '$(resolve do_gcp_org_id)'"
[[ "$(resolve do_gcp_org_id GCP_ORG_ID=42)" == 42 ]] && pass "GCP_ORG_ID overrides the conf" || fail "GCP_ORG_ID ignored"

# --- 4. one lib, two copies --------------------------------------------------------
ORC_PIN="$APP_ROOT/$ORG_APP-orc/lib/bash/funcs/gcp-account-pin.func.sh"
cmp -s "$PIN" "$ORC_PIN" && pass "the iac and orc gcp-account-pin.func.sh are byte-identical" || fail "$ORC_PIN differs from $PIN"

# --- 5. SCAN ----------------------------------------------------------------------
# scan_file <file> -> one line per gcloud/gsutil invocation: <verdict> <file>:<line>: <cmd>
# verdict: pinned | allowed | UNPINNED. Continuation lines are joined; comment
# lines skipped. An invocation is gcloud/gsutil as a COMMAND word (line start,
# after ; & | ( $( or a shell keyword), so `command -v gcloud` and a do_log
# message quoting a command are not calls. A file that sets
# acct="--account=..." may pass "${acct}".
scan_file() {
  awk -v F="$1" '
    FNR == 1 { buf = ""; start = 0 }
    /^[[:space:]]*#/ && buf == "" { next }
    {
      line = $0
      if (buf == "") start = FNR
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); buf = buf line " "; next }
      buf = buf line
      if (buf ~ /(^|[;&|({]|\$\(|(^|[[:space:]])(if|then|do|else|elif|while|until|!|time)[[:space:]])[[:space:]]*(command[[:space:]]+)?(gcloud|gsutil)[[:space:]]/) {
        v = "UNPINNED"
        if (buf ~ /--account/ || (acct && buf ~ /\$\{?acct\}?/)) v = "pinned"
        else if (buf ~ /gcloud[[:space:]]+(auth|config)[[:space:]]/) v = "allowed"
        c = buf; gsub(/[[:space:]]+/, " ", c)
        print v " " F ":" start ": " substr(c, 1, 160)
      }
      buf = ""
    }
  ' acct="$(grep -c 'acct="--account=' "$1")" "$1"
}
scan_tree() {
  local root="$1" d
  for d in "$root"/*-iac "$root"/*-orc; do
    find "$d/src/bash/run" "$d/src/bash/scripts" "$d/src/bash/features" "$d/lib" \
      -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null
  done | sort | while read -r f; do scan_file "$f"; done
}

scan_tree "$APP_ROOT" >"$T/scan.txt"
n_all=$(wc -l <"$T/scan.txt")
n_pin=$(grep -c '^pinned ' "$T/scan.txt")
n_allow=$(grep -c '^allowed ' "$T/scan.txt")
n_bad=$(grep -c '^UNPINNED ' "$T/scan.txt")
echo "INFO scan saw $n_all gcloud/gsutil invocation(s): $n_pin pinned, $n_allow allow-listed (auth/config), $n_bad unpinned"
[[ "$n_all" -ge 25 ]] && pass "the scan sees the calls ($n_all >= 25; 0 would prove nothing)" || fail "the scan saw only $n_all invocations: the scanner is blind"
[[ "$n_bad" -eq 0 ]] && pass "every gcloud/gsutil invocation carries --account" \
  || fail "$n_bad unpinned gcloud/gsutil invocation(s):
$(grep '^UNPINNED ' "$T/scan.txt")"

# CONTROL: the scanner flags what it should, and passes what it should
cat >"$T/planted.sh" <<'EOF'
out=$(gcloud projects describe p \
  --format=json)
gcloud storage ls gs://b
if gcloud sql users list --instance=i --account="$a"; then :; fi
command -v gcloud >/dev/null
do_log "INFO would run: gcloud projects create p"
gcloud auth print-access-token
gsutil ls gs://b
EOF
got=$(scan_file "$T/planted.sh" | awk '{print $1}' | tr '\n' ' ')
[[ "$got" == "UNPINNED UNPINNED pinned allowed UNPINNED " ]] \
  && pass "CONTROL: planted unpinned calls (joined continuation, gcloud storage, gsutil) are caught; mentions are not calls" \
  || fail "CONTROL: scanner verdicts on the planted file: '$got'"

# --- 6. no literal outside the cnf ------------------------------------------------
if git -C "$APP_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  for v in "$want_acct" "$want_org"; do
    [[ -n "$v" ]] || continue
    hits=$(git -C "$APP_ROOT" grep -lF -e "$v" -- . ":(exclude)$ORG_APP-cnf/$ORG_APP/*.env.yaml" ":(exclude)$ORG_APP-cnf/$ORG_APP/*.env.json" 2>/dev/null)
    [[ -z "$hits" ]] && pass "a cnf env.gcp value appears nowhere outside the cnf yaml/json" || fail "a cnf env.gcp value is hard-coded in: $hits"
  done
  n_cnf=$(git -C "$APP_ROOT" grep -lF -e "$want_acct" -- "$ORG_APP-cnf" | wc -l)
  [[ "$n_cnf" -ge 1 ]] && pass "CONTROL: the same grep finds the account in the cnf ($n_cnf file(s))" || fail "CONTROL: the literal grep is blind"
else
  echo "SKIP: not a git checkout, literal scan skipped"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
