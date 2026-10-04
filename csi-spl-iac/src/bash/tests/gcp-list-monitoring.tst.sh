#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_list_monitoring (the 070-gcp-monitoring measure) lists the
#          uptime checks, alert policies and notification channels as each
#          env's OWN project SA, read-only, never printing a channel's labels.
#   1. ENV=dev: three list calls, each with --project and --account from the
#      dev key, the key passed as CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE, under
#      a private CLOUDSDK_CONFIG that is gone afterwards; ~/.config/gcloud is
#      never created
#   2. ENV unset: dev and prd, each as its own SA; an env without a key is skipped
#   3. read-only: no create/update/delete call, and the channels format never
#      prints labels (a channel's address)
#   4. CONTROL: no key at all -> non-zero, and gcloud is never called
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-list-monitoring.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

mkdir -p "$T/bin" "$T/home/.gcp/.o"
cat >"$T/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG:-<unset>}|${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-<unset>}|$*" >>"$GC_CALLS"
[[ -d "${CLOUDSDK_CONFIG:-/nonexistent}" ]] && echo seen >>"$GC_CALLS.cfg"
echo "NAME"
STUB
chmod +x "$T/bin/gcloud"
for e in dev prd; do
  printf '{"client_email":"sa-%s@p-%s.iam.gserviceaccount.com","project_id":"o-a-%s"}\n' "$e" "$e" "$e" >"$T/home/.gcp/.o/key-o-a-$e.json"
done

# run_action <env assignments...> -> rc; calls in $T/calls.log
run_action() {
  : >"$T/calls.log"; rm -f "$T/calls.log.cfg"
  env -u ENV -u CLOUDSDK_CONFIG PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" ACTION="$ACTION" \
    HOME="$T/home" ORG=o APP=a "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_require_var(){ [[ -n "$2" ]] || exit 1; }
      do_gcp_log_identity(){ echo "identity $1 $2"; }
      source "$ACTION"; do_gcp_list_monitoring' >"$T/out.log" 2>&1
}

# --- 1. one env ---------------------------------------------------------------------
run_action ENV=dev; rc=$?
n_ok=$(cut -d'|' -f3 "$T/calls.log" | grep -c -- '--project=o-a-dev --account=sa-dev@p-dev.iam.gserviceaccount.com')
[[ $rc -eq 0 && "$(wc -l <"$T/calls.log")" -eq 3 && "$n_ok" -eq 3 ]] \
  && pass "ENV=dev: three list calls, all as the dev SA on the dev project" || fail "ENV=dev: rc=$rc calls=$(cat "$T/calls.log") $(cat "$T/out.log")"
for want in 'monitoring uptime list-configs' 'alpha monitoring policies list' 'beta monitoring channels list'; do
  grep -q "|${want} " "$T/calls.log" && pass "ENV=dev: runs '${want}'" || fail "no '${want}' call"
done
ovr=$(cut -d'|' -f2 "$T/calls.log" | sort -u)
[[ "$ovr" == "$T/home/.gcp/.o/key-o-a-dev.json" ]] && pass "ENV=dev: the dev key is the credential (override, nothing activated)" || fail "override='$ovr'"
cfg=$(cut -d'|' -f1 "$T/calls.log" | sort -u)
[[ "$cfg" != "<unset>" && "$cfg" != "$T/home/.config/gcloud" && -s "$T/calls.log.cfg" && ! -e "$cfg" ]] \
  && pass "ENV=dev: a private CLOUDSDK_CONFIG, removed afterwards" || fail "config dir: '$cfg'"
[[ ! -e "$T/home/.config/gcloud" ]] && pass "the shared ~/.config/gcloud is never created" || fail "the shared HOME/.config/gcloud was written"

# --- 2. every env with a key --------------------------------------------------------
run_action GCP_LIST_ENVS="dev tst prd"; rc=$?
got=$(cut -d'|' -f3 "$T/calls.log" | grep -oE -- '--project=[^ ]+ --account=[^ ]+' | sort -u | tr '\n' ' ')
[[ $rc -eq 0 && "$got" == "--project=o-a-dev --account=sa-dev@p-dev.iam.gserviceaccount.com --project=o-a-prd --account=sa-prd@p-prd.iam.gserviceaccount.com " ]] \
  && pass "ENV unset: dev and prd, each as its own SA; tst (no key) skipped" || fail "all envs: rc=$rc got='$got'"
dirs=$(cut -d'|' -f1 "$T/calls.log" | sort -u | wc -l)
[[ "$dirs" -eq 2 ]] && pass "ENV unset: a fresh private config per env" || fail "config dirs: $dirs"

# --- 3. read-only, no address -------------------------------------------------------
! grep -qE '\b(create|update|delete)\b' "$T/calls.log" && pass "read-only: no create/update/delete" || fail "calls: $(cat "$T/calls.log")"
ch=$(grep 'monitoring channels list' "$T/calls.log")
[[ -n "$ch" ]] && ! grep -qiE 'labels' <<<"$ch" && pass "no channel label (its address) is printed" || fail "the channels format prints labels: $ch"

# --- 4. CONTROL: no key -------------------------------------------------------------
run_action ENV=stg; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "CONTROL: no key -> refused, gcloud never called" || fail "CONTROL: rc=$rc calls=$(cat "$T/calls.log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
