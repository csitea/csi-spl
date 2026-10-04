#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the ported csi-rel gcp-* actions never touch the SHARED gcloud config
#          (ORC OK 2026-09-19), and still reach GCP as a credential they hold.
#   1. Driving a real action (do_gcp_sync_s3_to_local) against a stub gcloud:
#      a. every gcloud call runs under a private CLOUDSDK_CONFIG, never the
#         caller's, and that private dir is gone afterwards
#      b. the CALLER's config dir survives (a planted credentials file is still
#         there), CLOUDSDK_CONFIG is restored to it, and no RETURN trap is left
#      c. a caller with CLOUDSDK_CONFIG unset gets it unset back
#      d. after the key is activated in the private config, --account names
#         THAT key's identity, not the cnf owner account (which the private
#         config holds no credential for)
#   2. CONTROL: do_gcp_isolated_active_account refuses to read the shared
#      config (CLOUDSDK_CONFIG unset, or the default dir) and asks gcloud nothing.
#   3. Static: in every src/bash/run/gcp-*.func.sh that runs `gcloud auth
#      activate-service-account` / `gcloud auth login`, each such statement is
#      followed by a re-pin, and the function isolates its config.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"
ACTION="$RUN/gcp-sync-s3-to-local.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; activate-service-account records
# the key's client_email as the active account OF THAT CONFIG; auth list prints it
mkdir -p "$T/stub" "$T/home/.gcp/.csi"
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
case "$*" in
  "auth activate-service-account --key-file="*)
    for a in "$@"; do [[ "$a" == --key-file=* ]] && k="${a#--key-file=}"; done
    mkdir -p "$CLOUDSDK_CONFIG" && jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "${CLOUDSDK_CONFIG:-/nonexistent}/active" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"
SA="csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com"
printf '{"type":"service_account","client_email":"%s"}\n' "$SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# drive <caller CLOUDSDK_CONFIG or "-" for unset> -> prints "after=<value|<unset>> trap=<n>"
drive() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
      PIN="$PIN" ACTION="$ACTION" CALLER_CFG="$1" TGT_DIR="$T/tgt" BASE_PATH="$T/none" \
      APP_PATH="$T" ORG=csi APP=spl ENV=dev GCP_ACCOUNT=owner@example.com \
  bash -c '
    do_log() { :; }; quit_on() { rv=$?; [ $rv -ne 0 ] && { echo "FATAL $1"; exit $rv; }; }
    do_require_var() { :; }
    source "$PIN"; source "$ACTION"
    [[ "$CALLER_CFG" == - ]] || export CLOUDSDK_CONFIG="$CALLER_CFG"
    caller() { do_gcp_sync_s3_to_local >/dev/null 2>&1; }
    caller
    echo "after=${CLOUDSDK_CONFIG-<unset>} trap=$(trap -p RETURN | wc -l)"
  ' 2>/dev/null
}

# --- 1. a real action ----------------------------------------------------------
mkdir -p "$T/mine"; echo secret >"$T/mine/credentials.db"
out=$(drive "$T/mine")
n=$(wc -l <"$T/calls.log")
[[ $n -ge 3 ]] && pass "control: the stub recorded $n gcloud calls" || fail "control: the stub recorded only $n calls"
if cut -d'|' -f1 "$T/calls.log" | grep -xF -e "$T/mine" -e '<unset>' >/dev/null; then
  fail "a gcloud call ran under the caller's / the shared config: $(grep -F "$T/mine|" "$T/calls.log" | sed -n 1p)"
else pass "a. every gcloud call ran under a private CLOUDSDK_CONFIG"; fi
priv=$(head -1 "$T/calls.log" | cut -d'|' -f1)
[[ -n "$priv" && ! -e "$priv" ]] && pass "a. the private config dir is removed afterwards" || fail "a. private config $priv left behind"
[[ -f "$T/mine/credentials.db" ]] && pass "b. the caller's gcloud config survives the action (planted credentials.db still there)" \
  || fail "b. the caller's gcloud config was DELETED"
[[ "$out" == "after=$T/mine trap=0" ]] && pass "b. CLOUDSDK_CONFIG restored to the caller's dir, no RETURN trap left" \
  || fail "b. after the action: '$out'"
grep -q "storage rsync .*--account=$SA" "$T/calls.log" && ! grep -q -- '--account=owner@example.com' "$T/calls.log" \
  && pass "d. after activation --account names the activated key ($SA), not the owner account" \
  || fail "d. --account after activation: $(grep 'storage rsync' "$T/calls.log")"

out=$(drive -)
[[ "$out" == "after=<unset> trap=0" ]] && pass "c. a caller with CLOUDSDK_CONFIG unset gets it unset back" || fail "c. unset caller: '$out'"

# --- 2. CONTROL: never read the shared active account ------------------------------
for cfg in - "$T/home/.config/gcloud"; do
  mkdir -p "$T/home/.config/gcloud"; : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" PIN="$PIN" CFG="$cfg" \
    bash -c 'do_log(){ :; }; source "$PIN"; [[ "$CFG" == - ]] || export CLOUDSDK_CONFIG="$CFG"; do_gcp_isolated_active_account' >/dev/null 2>&1
  rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "CONTROL: do_gcp_isolated_active_account refuses the shared config ($cfg) without asking gcloud" \
    || fail "CONTROL: shared config ($cfg) read: rc=$rc calls=$(cat "$T/calls.log")"
done

# --- 3. static: every activation / login is re-pinned, every such file isolates ----
# The lib helpers that activate for their callers (CLE-77915: the 7 gcp-list-*
# actions run on gcp-each-env-sa, the 4 apis actions on gcp-project-apis) are
# scanned too; gcp-account-pin is the resolver itself, checked above.
n_files=0; n_sites=0
for f in "$RUN"/gcp-*.func.sh "$PROJ_ROOT"/lib/bash/funcs/gcp-each-env-sa.func.sh "$PROJ_ROOT"/lib/bash/funcs/gcp-project-apis.func.sh; do
  acts=$(grep -cE '^\s*(if\s+!\s+)?gcloud auth (activate-service-account|login)\b' "$f")
  (( acts )) || continue
  n_files=$((n_files + 1)); n_sites=$((n_sites + acts))
  pins=$(grep -c 'do_gcp_isolated_active_account' "$f")
  [[ "$pins" -eq "$acts" ]] || fail "$(basename "$f"): $acts activation/login statement(s), $pins re-pin(s)"
  grep -q 'export CLOUDSDK_CONFIG="\$_spl_sdk_dir"' "$f" || fail "$(basename "$f") activates without isolating its gcloud config"
done
# 16 files since CLE-77915 folded 11 actions onto the 2 helpers (was 25).
[[ $n_files -ge 12 ]] && pass "static: $n_sites activation/login statement(s) in $n_files action(s), each re-pinned in an isolated config" \
  || fail "static: saw only $n_files action(s) -- the scan is blind"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
