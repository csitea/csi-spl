#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_list_secrets really lists (it used to only echo), as each
#          env's OWN project SA, and never reads a secret value.
#   1. ENV=dev: one `gcloud secrets list`, --project and --account from the
#      dev key, the key passed as CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE, under
#      a private CLOUDSDK_CONFIG that is gone afterwards; ~/.config/gcloud is
#      never created
#   2. ENV unset: every env in GCP_LIST_ENVS with a key, each as its own SA;
#      an env without a key is skipped
#   3. no call is `versions access` (or any other value read)
#   4. CONTROL: no key at all -> non-zero, and gcloud is never called
#   5. a Ctrl-C while gcloud runs still removes the private CLOUDSDK_CONFIG
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-list-secrets.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

mkdir -p "$T/bin" "$T/home/.gcp/.o"
cat >"$T/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG:-<unset>}|${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-<unset>}|$*" >>"$GC_CALLS"
[[ -d "${CLOUDSDK_CONFIG:-/nonexistent}" ]] && echo seen >>"$GC_CALLS.cfg"
echo "NAME  CREATED"
[[ -z "${GC_INTERRUPT:-}" ]] || kill -INT 0
EOF
chmod +x "$T/bin/gcloud"
for e in dev prd; do
  printf '{"client_email":"sa-%s@p-%s.iam.gserviceaccount.com","project_id":"o-a-%s"}\n' "$e" "$e" "$e" >"$T/home/.gcp/.o/key-o-a-$e.json"
done

# run_action <env assignments...> -> rc; calls in $T/calls.log
run_action() {
  : >"$T/calls.log"; rm -f "$T/calls.log.cfg"
  env -u ENV -u CLOUDSDK_CONFIG PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" ACTION="$ACTION" \
    PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh" HOME="$T/home" ORG=o APP=a "$@" \
    bash -c 'source "$PIN"; do_log(){ echo "$*"; }; do_require_var(){ [[ -n "$2" ]] || exit 1; }
      do_gcp_log_identity(){ echo "identity $1 $2"; }
      source "$ACTION"; do_gcp_list_secrets' >"$T/out.log" 2>&1
}

# --- 1. one env ---------------------------------------------------------------------
run_action ENV=dev; rc=$?
IFS='|' read -r cfg ovr args <"$T/calls.log"
[[ $rc -eq 0 && "$(wc -l <"$T/calls.log")" -eq 1 && "$args" == "secrets list --project=o-a-dev --account=sa-dev@p-dev.iam.gserviceaccount.com "* ]] \
  && pass "ENV=dev: one secrets list, as the dev SA on the dev project" || fail "ENV=dev: rc=$rc calls=$(cat "$T/calls.log") $(cat "$T/out.log")"
[[ "$ovr" == "$T/home/.gcp/.o/key-o-a-dev.json" ]] && pass "ENV=dev: the dev key is the credential (override, nothing activated)" || fail "override='$ovr'"
[[ "$cfg" != "<unset>" && "$cfg" != "$T/home/.config/gcloud" && -s "$T/calls.log.cfg" && ! -e "$cfg" ]] \
  && pass "ENV=dev: a private CLOUDSDK_CONFIG, removed afterwards" || fail "config dir: '$cfg'"
[[ ! -e "$T/home/.config/gcloud" ]] && pass "the shared ~/.config/gcloud is never created" || fail "~/.config/gcloud was written"

# --- 2. every env with a key --------------------------------------------------------
run_action GCP_LIST_ENVS="dev tst prd"; rc=$?
got=$(cut -d'|' -f3 "$T/calls.log" | awk '{print $3, $4}' | tr '\n' ' ')
[[ $rc -eq 0 && "$got" == "--project=o-a-dev --account=sa-dev@p-dev.iam.gserviceaccount.com --project=o-a-prd --account=sa-prd@p-prd.iam.gserviceaccount.com " ]] \
  && pass "ENV unset: dev and prd, each as its own SA; tst (no key) skipped" || fail "all envs: rc=$rc got='$got'"
dirs=$(cut -d'|' -f1 "$T/calls.log" | sort -u | wc -l)
[[ "$dirs" -eq 2 ]] && pass "ENV unset: a fresh private config per env" || fail "config dirs: $dirs"

# --- 3. never a value ---------------------------------------------------------------
run_action GCP_LIST_ENVS="dev prd" FILTER="name~auth"
! grep -qE 'access|versions' "$T/calls.log" && grep -q -- '--filter=name~auth' "$T/calls.log" \
  && pass "no value is read (no versions access); FILTER reaches --filter" || fail "calls: $(cat "$T/calls.log")"

# --- 4. CONTROL: no key -------------------------------------------------------------
run_action ENV=stg; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "CONTROL: no key -> refused, gcloud never called" || fail "CONTROL: rc=$rc calls=$(cat "$T/calls.log")"

# --- 5. Ctrl-C mid gcloud ------------------------------------------------------------
# CTRL_C <cmd...>: a Ctrl-C. It runs <cmd> in its own process group with SIGINT
# at its default (a runner may start tests with it ignored), so the stub's
# `kill -INT 0` reaches the whole action and nothing else.
CTRL_C=(python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])')
mkdir -p "$T/tmp"; before=$(ls -A "$T/tmp")
run_action ENV=dev GC_INTERRUPT=1 TMPDIR="$T/tmp" "${CTRL_C[@]}"; rc=$?
after=$(ls -A "$T/tmp")
[[ $rc -ne 0 && -s "$T/calls.log.cfg" && -z "$before" && -z "$after" ]] \
  && pass "Ctrl-C mid gcloud: the private config is removed (temp root empty before and after)" \
  || fail "Ctrl-C: rc=$rc temp root before='$before' after='$after'"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
