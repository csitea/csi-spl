#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the gcloud identity is the per-env project SA from its key, never
#          ambient and never the owner account outside the bootstrap (owner
#          rule 2026-09-19: "once the service account keys are provisioned,
#          then you should be using only the service accounts per environment
#          for everything. You should not be using the owner account.").
#   1. do_gcp_account resolves ACCOUNT > GCP_ACCOUNT > the per-env SA key
#      ($HOME/.gcp/.<org>/key-<project>.json, activated in a PRIVATE
#      CLOUDSDK_CONFIG); do_gcp_pin_account makes that private config itself.
#   2. CONTROL: no key in a non-bootstrap action -> refused, and the owner
#      account is never printed (not from the yaml, not from
#      GCP_ACCOUNT_OWNER_EMAIL); a key with the SHARED config -> refused.
#   2b. bootstrap (do_gcp_bootstrap_account, gcp-000..004): no key -> the cnf
#      owner account (an env file overrides all.env.yaml); key -> the SA.
#   2c. STATIC: only gcp-000..004 reach the bootstrap resolver, and no action
#      reads gcp_account_owner_email; every file that calls gcloud resolves
#      its identity (resolver, key activation, or a caller-pinned
#      $GCP_ACCOUNT) -- the count is printed and must not be 0.
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

# a gcloud stub: logs "<CLOUDSDK_CONFIG>|<argv>"; activate-service-account
# records the key's client_email as the active account OF THAT CONFIG
mkdir -p "$T/stub" "$T/home/.gcp/.csi" "$T/nokey" "$T/cfg"
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
case "$*" in
  "auth activate-service-account --key-file="*)
    for a in "$@"; do [[ "$a" == --key-file=* ]] && k="${a#--key-file=}"; done
    jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "${CLOUDSDK_CONFIG:-/nonexistent}/active" 2>/dev/null ;;
  *) echo ambient@example.com ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"; : >"$T/gcloud.log"
SA="csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com"
printf '{"type":"service_account","client_email":"%s"}\n' "$SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# resolve <fn> [VAR=value ...] -> stdout of <fn>; stderr to $T/err. Default: the
# key is on disk and CLOUDSDK_CONFIG is a private dir.
resolve() {
  local fn="$1"; shift
  env -u ACCOUNT -u GCP_ACCOUNT -u GCP_ACCOUNT_OWNER_EMAIL -u GCP_ORG_ID -u GCP_SA_KEY_FILE \
    -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT \
    PIN="$PIN" FN="$fn" PATH="$T/stub:$PATH" STUB_LOG="$T/gcloud.log" HOME="$T/home" CLOUDSDK_CONFIG="$T/cfg" \
    APP_PATH="$APP_ROOT" ORG="${ORG_APP%%-*}" APP="${ORG_APP#*-}" ENV=dev "$@" \
    bash -c 'do_log(){ echo "$*"; }; source "$PIN"; "$FN"' 2>"$T/err"
}

# --- 1. precedence --------------------------------------------------------------
: >"$T/gcloud.log"; rm -f "$T/cfg/active"
[[ "$(resolve do_gcp_account)" == "$SA" ]] && pass "no override: the account is the per-env SA from key-csi-spl-dev.json" \
  || fail "key present: got '$(resolve do_gcp_account)' err=$(cat "$T/err")"
grep -q "^$T/cfg|auth activate-service-account --key-file=$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/gcloud.log" \
  && pass "the key is activated in the PRIVATE config" || fail "activation: $(cat "$T/gcloud.log")"
[[ "$(resolve do_gcp_account GCP_ACCOUNT=sa@example.com)" == sa@example.com ]] \
  && pass "GCP_ACCOUNT (e.g. CI's deploy SA) beats the key" || fail "GCP_ACCOUNT did not win over the key"
[[ "$(resolve do_gcp_account ACCOUNT=run@example.com GCP_ACCOUNT=sa@example.com)" == run@example.com ]] \
  && pass "ACCOUNT beats GCP_ACCOUNT" || fail "ACCOUNT did not win"
cp "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/other-key.json"
[[ "$(resolve do_gcp_account HOME="$T/nokey" GCP_SA_KEY_FILE="$T/other-key.json")" == "$SA" ]] \
  && pass "GCP_SA_KEY_FILE names the key explicitly" || fail "GCP_SA_KEY_FILE ignored"
printf 'env:\n  gcp:\n    gcp_project: csi-spl-dev\n' >"$T/spl-cnf.yaml"
out=$(env -u ACCOUNT -u GCP_ACCOUNT -u ENV -u ORG -u APP -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT PIN="$PIN" PATH="$T/stub:$PATH" \
  STUB_LOG="$T/gcloud.log" HOME="$T/home" CLOUDSDK_CONFIG="$T/cfg" \
  bash -c 'do_log(){ :; }; source "$PIN"; do_gcp_account "$1"' _ "$T/spl-cnf.yaml")
[[ "$out" == "$SA" ]] && pass "the project comes from a cnf FILE's env.gcp.gcp_project (orc's \$SPL_CNF)" || fail "cnf-file project: '$out'"

# do_gcp_pin_account from a caller on the SHARED config: moves the run to a
# private config, activates there, exports GCP_ACCOUNT, and cleans up on EXIT
: >"$T/gcloud.log"
out=$(env -u ACCOUNT -u GCP_ACCOUNT -u CLOUDSDK_CONFIG -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT PIN="$PIN" PATH="$T/stub:$PATH" \
  STUB_LOG="$T/gcloud.log" HOME="$T/home" APP_PATH="$APP_ROOT" ORG="${ORG_APP%%-*}" APP="${ORG_APP#*-}" ENV=dev \
  bash -c 'do_log(){ :; }; source "$PIN"; trap "echo caller-trap-ran" EXIT; do_gcp_pin_account >/dev/null || exit 9
           echo "acct=$GCP_ACCOUNT cfg=$CLOUDSDK_CONFIG"')
cfg=$(sed -n 's/^acct=.* cfg=//p' <<<"$out")
[[ "$out" == "acct=$SA cfg="* && -n "$cfg" && "$cfg" != "$T/home/.config/gcloud" ]] \
  && pass "do_gcp_pin_account pins the SA and exports a private CLOUDSDK_CONFIG" || fail "pin from the shared config: '$out'"
[[ -n "$cfg" && ! -e "$cfg" ]] && pass "the private config (it holds the SA credential) is removed on EXIT" || fail "private config $cfg left behind"
grep -q '^caller-trap-ran$' <<<"$out" && pass "a caller's EXIT trap still runs (chained, not replaced)" || fail "caller EXIT trap lost: '$out'"
if cut -d'|' -f1 "$T/gcloud.log" | grep -qx -e '<unset>' -e "$T/home/.config/gcloud"; then
  fail "a gcloud call ran against the shared config: $(cat "$T/gcloud.log")"
else pass "no gcloud call touched the shared config"; fi

# --- 2. CONTROL: no key -> refused, the owner account is NEVER resolved ------------
: >"$T/gcloud.log"
want_owner_leak="$want_acct"
out=$(resolve do_gcp_account HOME="$T/nokey"); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && grep -q 'owner account is used only by the gcp-000..004 bootstrap' "$T/err" \
  && pass "CONTROL: key absent in a non-bootstrap action -> refused (rc=$rc)" \
  || fail "CONTROL: key absent rc=$rc out='$out' err='$(cat "$T/err")'"
out=$(resolve do_gcp_account HOME="$T/nokey" GCP_ACCOUNT_OWNER_EMAIL=c@example.com); rc=$?
[[ $rc -ne 0 && "$out" != *c@example.com* && "$out" != *"$want_owner_leak"* ]] \
  && pass "CONTROL: GCP_ACCOUNT_OWNER_EMAIL is no fallback outside the bootstrap" || fail "owner leaked: rc=$rc out='$out'"
[[ ! -s "$T/gcloud.log" ]] && pass "CONTROL: the refusal never asked gcloud for the active account" \
  || fail "the resolution called gcloud: $(cat "$T/gcloud.log")"
out=$(resolve do_gcp_pin_account HOME="$T/nokey"); rc=$?
[[ $rc -ne 0 ]] && pass "CONTROL: do_gcp_pin_account refuses too (rc=$rc)" || fail "do_gcp_pin_account did not refuse: $out"
: >"$T/gcloud.log"
out=$(resolve do_gcp_account -u CLOUDSDK_CONFIG); rc=$?
[[ $rc -ne 0 && -z "$out" && ! -s "$T/gcloud.log" ]] \
  && pass "CONTROL: a key with the SHARED config (inside \$( )) is refused, nothing activated" \
  || fail "shared-config activation: rc=$rc out='$out' calls=$(cat "$T/gcloud.log")"
out=$(resolve do_gcp_pin_account GCP_ACCOUNT=sa@example.com)
grep -q "account=sa@example.com" <<<"$out" && pass "do_gcp_pin_account logs the pinned identity" || fail "no identity log line: $out"

# --- 2b. bootstrap: the owner only while no key exists -----------------------------
[[ "$(resolve do_gcp_bootstrap_account HOME="$T/nokey")" == "$want_acct" ]] \
  && pass "bootstrap, no key: the cnf env.gcp.gcp_account_owner_email" || fail "bootstrap no key: '$(resolve do_gcp_bootstrap_account HOME="$T/nokey")'"
[[ "$(resolve do_gcp_bootstrap_account)" == "$SA" ]] \
  && pass "bootstrap, key present: the SA, not the owner" || fail "bootstrap with key: '$(resolve do_gcp_bootstrap_account)'"
[[ "$(resolve do_gcp_bootstrap_account HOME="$T/nokey" GCP_ACCOUNT_OWNER_EMAIL=c@example.com)" == c@example.com ]] \
  && pass "bootstrap: an exported GCP_ACCOUNT_OWNER_EMAIL beats reading the yaml" || fail "GCP_ACCOUNT_OWNER_EMAIL ignored"
mkdir -p "$T/cnf"
printf 'env:\n  gcp:\n    gcp_account_owner_email: all@example.com\n    gcp_org_id: "111"\n' >"$T/cnf/all.env.yaml"
printf 'env:\n  gcp:\n    gcp_account_owner_email: dev@example.com\n' >"$T/cnf/dev.env.yaml"
printf 'env:\n  gcp:\n    gcp_region: x\n' >"$T/cnf/prd.env.yaml"
boot() { env -u ACCOUNT -u GCP_ACCOUNT -u GCP_ACCOUNT_OWNER_EMAIL -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT -u ORG -u APP \
  PIN="$PIN" HOME="$T/nokey" ENV="$1" bash -c 'do_log(){ :; }; source "$PIN"; do_gcp_bootstrap_account "$1"' _ "$2"; }
out_dev=$(boot dev "$T/cnf"); out_prd=$(boot prd "$T/cnf")
[[ "$out_dev" == dev@example.com && "$out_prd" == all@example.com ]] \
  && pass "bootstrap: an <env>.env.yaml value overrides all.env.yaml; absent, all.env.yaml applies" || fail "per-env override: dev='$out_dev' prd='$out_prd'"
yq eval-all '. as $i ireduce ({}; . * $i)' "$T/cnf/all.env.yaml" "$T/cnf/dev.env.yaml" >"$T/merged.yaml"
[[ "$(boot "" "$T/merged.yaml")" == dev@example.com ]] && pass "bootstrap: a merged cnf FILE is read as is" || fail "cnf file: '$(boot "" "$T/merged.yaml")'"
out=$(boot dev "$T/nowhere"); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && pass "CONTROL: bootstrap with no key and no cnf owner -> refused" || fail "bootstrap refuse: rc=$rc '$out'"

# --- 2c. STATIC: who may reach the owner, and who resolves -------------------------
code_files() {
  local d
  for d in "$APP_ROOT"/*-iac "$APP_ROOT"/*-orc; do
    find "$d/src/bash/run" "$d/src/bash/scripts" "$d/src/bash/features" "$d/lib" \
      -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null
  done | grep -v '/gcp-account-pin.func.sh$' | sort
}
owner_hits=$(code_files | while read -r f; do
  grep -vE '^[[:space:]]*#' "$f" | grep -qE 'do_gcp_(pin_)?bootstrap_account|gcp_account_owner_email|GCP_ACCOUNT_OWNER_EMAIL' || continue
  [[ "$(basename "$f")" =~ ^gcp-00[0-4]- ]] || echo "$f"
done)
[[ -z "$owner_hits" ]] && pass "STATIC: only gcp-000..004 can reach the owner account" || fail "owner reachable outside the bootstrap: $owner_hits"
n_boot=$(code_files | xargs grep -lE '^[[:space:]]*do_gcp_pin_bootstrap_account' | wc -l)
[[ "$n_boot" -eq 4 ]] && pass "STATIC: gcp-001..004 pin through the bootstrap resolver ($n_boot)" || fail "bootstrap resolver used by $n_boot files, want 4"
n_gc=0; unresolved=""
while read -r f; do
  grep -vE '^[[:space:]]*#' "$f" \
    | grep -qE '(^|[;&|({]|\$\(|(^|[[:space:]])(if|then|do|else|elif|while|until|!|time)[[:space:]])[[:space:]]*(command[[:space:]]+)?(gcloud|\$\{?GCLOUD\}?)[[:space:]]' || continue
  n_gc=$((n_gc + 1))
  grep -qE 'do_gcp_(pin_)?(bootstrap_)?account|do_gcp_isolated_active_account|auth activate-service-account --key-file|--account="?\$\{?(GCP_ACCOUNT|account)\b|--account="?\$\{?1' "$f" \
    || unresolved="$unresolved $(basename "$f")"
done < <(code_files)
echo "INFO resolver scan: $n_gc file(s) call gcloud"
[[ "$n_gc" -ge 25 ]] && pass "STATIC: the resolver scan sees $n_gc gcloud-calling files (0 would prove nothing)" || fail "resolver scan saw only $n_gc files"
[[ -z "$unresolved" ]] && pass "STATIC: every gcloud-calling file resolves its identity (resolver, the key directly, or a pinned \$GCP_ACCOUNT)" \
  || fail "gcloud without a resolved identity in:$unresolved"

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
  n_cnf=$(git -C "$APP_ROOT" grep -lF -e "$want_org" -- "$ORG_APP-cnf" | wc -l)
  [[ "$n_cnf" -ge 1 ]] && pass "CONTROL: the same grep finds the org in the cnf ($n_cnf file(s))" || fail "CONTROL: the literal grep is blind"
else
  echo "SKIP: not a git checkout, literal scan skipped"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
