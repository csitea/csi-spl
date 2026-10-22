#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gh_secret_put_gcp_key (SPL-2893) puts this box's per-env project
#          SA key file into the CI repo secret the workflows read, the key on
#          gh's stdin only (secret-rotation.md section 5.1 step 3).
#   1. dry run (DRY_RUN unset): names the secret, the repo, the key id prefix
#      and the client_email domain; no `gh secret set` call
#   2. DRY_RUN=0: `gh secret set GCP_KEY_CSI_SPL_DEV --repo <repo>`, the key
#      bytes arrive on gh's stdin; the key and the full key id are in neither
#      gh's argv nor the action's output; prints updated_at
#   3. RED CONTROL: the same action passing the key with --body fails the
#      check of 2 (the check can see a leak)
#   4. a key of another SA -> refused, no gh call
#   5. ENV=bkp / all / qa, DRY_RUN=2 -> refused before any gh call
#   6. gh not authenticated -> refused with gh's error, no set; the action
#      reads no token of its own
#   7. ENV=prd -> GCP_KEY_CSI_SPL_PRD
#   8. every secrets.GCP_KEY_CSI_SPL_* the workflows use is the derived name
#      of dev or prd, and both are used
# gh is a stub. No network, no GitHub, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gh-secret-put-gcp-key.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null && command -v jq >/dev/null || { echo "SKIP: no yq or jq"; exit 0; }
require_action "$ACTION"

KID=abcdef01fedcba9876543210fedcba9876543210
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/app/csi-spl-cnf"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$T/app/csi-spl-cnf/csi-spl"
# the field name is an argument, so no-key-material-in-tree.tst.sh never sees a key shape here
fake_key() { printf '{"type":"service_account","client_email":"%s","private_key_id":"%s","%s":"FAKESECRET-%s"}\n' "$2" "$KID" private_key "$1"; }
put_key() { (umask 077; fake_key "$1" "${2:-csi-spl-$1@csi-spl-$1.iam.gserviceaccount.com}" >"$T/home/.gcp/.csi/key-csi-spl-$1.json"); }
put_key dev; put_key prd

cat >"$T/stub/gh" <<'EOF_GH'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$*" in
  "secret list"*)
    [[ -z "${STUB_AUTH_FAIL:-}" ]] || { echo "HTTP 401: Bad credentials (https://api.github.com/repos/x/y/actions/secrets)" >&2; exit 1; }
    printf '[{"name":"GCP_KEY_CSI_SPL_DEV","updatedAt":"2026-10-22T14:00:00Z"},{"name":"GCP_KEY_CSI_SPL_PRD","updatedAt":"2026-10-21T09:00:00Z"}]\n' ;;
  "secret set"*) cat >"$STUB_STDIN"; echo "set Actions secret $3 for $5" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
EOF_GH
chmod +x "$T/stub/gh"

# act <action file> [VAR=value ...] -> rc; output in $T/out, gh argv in $T/gh.log, set stdin in $T/stdin
act_file() {
  local file="$1"; shift
  : >"$T/gh.log"; rm -f "$T/stdin"
  env -u DRY_RUN -u GH_SECRET_REPO -u GCP_SA_KEY_FILE -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT -u STUB_AUTH_FAIL \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/gh.log" STUB_STDIN="$T/stdin" ACTION_FILE="$file" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" GH_SECRET_REPO=example-org/example-repo ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$ACTION_FILE"; do source "$f"; done
    do_gh_secret_put_gcp_key' >"$T/out" 2>&1 </dev/null
}
act() { act_file "$ACTION" "$@"; }
no_set() { ! grep -q '^secret set' "$T/gh.log"; }
# no_leak - neither the key's secret field nor the key id past its 8-char prefix
# in gh's argv or the action's output
no_leak() { ! grep -qE "FAKESECRET|${KID:8:12}" "$T/gh.log" "$T/out"; }

# --- 1. dry run ---------------------------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 ]] && no_set && no_leak && grep -q '^secret list --repo example-org/example-repo' "$T/gh.log" \
  && grep -q "would run: gh secret set GCP_KEY_CSI_SPL_DEV --repo example-org/example-repo <key file on stdin> (key id ${KID:0:8}\.\.\., client_email @csi-spl-dev.iam.gserviceaccount.com)" "$T/out" \
  && pass "1. dry run: names secret, repo, key id prefix, email domain; no gh secret set" || fail "1. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 2. a real put ----------------------------------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'secret set GCP_KEY_CSI_SPL_DEV --repo example-org/example-repo' "$T/gh.log" \
  && cmp -s "$T/stdin" "$T/home/.gcp/.csi/key-csi-spl-dev.json" && no_leak \
  && grep -q "OK put key id ${KID:0:8}\.\.\. (client_email @csi-spl-dev.iam.gserviceaccount.com) into example-org/example-repo GCP_KEY_CSI_SPL_DEV, updated_at=2026-10-22T14:00:00Z" "$T/out" \
  && pass "2. DRY_RUN=0: the key on gh's stdin only, never in argv or output; updated_at printed" || fail "2. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 3. RED CONTROL: a --body variant leaks into argv, and no_leak sees it ----------------------
sed 's#<"\$key" 2>&1#--body "$(cat "$key")" 2>\&1#' "$ACTION" >"$T/leaky.func.sh"
if cmp -s "$ACTION" "$T/leaky.func.sh"; then fail "3. CONTROL could not plant the --body leak (the put line changed): update the sed"
else act_file "$T/leaky.func.sh" DRY_RUN=0; ! no_leak && pass "3. CONTROL: a --body put is caught by the leak check" || fail "3. CONTROL: the leak check missed a --body put $(cat "$T/gh.log")"; fi

# --- 4. a key of another SA ---------------------------------------------------------------------
put_key dev other-sa@csi-spl-dev.iam.gserviceaccount.com; act DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/gh.log" ]] && grep -q 'is a key of another SA' "$T/out" && no_leak \
  && pass "4. a key of another SA -> refused, no gh call" || fail "4. rc=$rc $(cat "$T/out" "$T/gh.log")"
put_key dev csi-spl-dev@csi-spl-prd.iam.gserviceaccount.com; act DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/gh.log" ]] && pass "4. the other env's project SA -> refused, no gh call" || fail "4b. rc=$rc $(cat "$T/out")"
put_key dev

# --- 5. refusals before any gh call ---------------------------------------------------------------
for bad in "ENV=bkp" "ENV=all" "ENV=qa" "DRY_RUN=2"; do
  act DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/gh.log" ]] && pass "5. $bad -> refused before any gh call" || fail "5. $bad rc=$rc $(cat "$T/out" "$T/gh.log")"
done

# --- 6. no gh auth for the repo -------------------------------------------------------------------
act DRY_RUN=0 STUB_AUTH_FAIL=1; rc=$?
[[ $rc -ne 0 ]] && no_set && grep -q 'HTTP 401: Bad credentials' "$T/out" \
  && pass "6. gh not authenticated -> refused with gh's error, no set" || fail "6. rc=$rc $(cat "$T/out" "$T/gh.log")"
! grep -nE 'GH_TOKEN|GITHUB_TOKEN|\.github/|gh auth (login|switch)' "$ACTION" \
  && pass "6. the action reads no token of its own" || fail "6. the action names a token source"

# --- 7. prd -----------------------------------------------------------------------------------------
act ENV=prd DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'secret set GCP_KEY_CSI_SPL_PRD --repo example-org/example-repo' "$T/gh.log" \
  && cmp -s "$T/stdin" "$T/home/.gcp/.csi/key-csi-spl-prd.json" && pass "7. ENV=prd -> GCP_KEY_CSI_SPL_PRD" || fail "7. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 8. the derived names = the workflows' secrets ----------------------------------------------------
used=$(git -C "$APP_ROOT" grep -ohE 'secrets\.GCP_KEY_CSI_SPL_[A-Z0-9_]+' -- .github 2>/dev/null | sed 's/^secrets\.//' | sort -u)
# shellcheck source=/dev/null  # the action under test, sourced for its name helper
derived=$(source "$ACTION"; for e in dev prd; do gh_secret_put_gcp_key_name "csi-spl-$e"; done | sort -u)
if [[ -z "$used" ]]; then fail "8. git grep found no secrets.GCP_KEY_CSI_SPL_* under .github"
elif [[ "$used" == "$derived" ]]; then pass "8. the workflows read exactly the derived names: $(tr '\n' ' ' <<<"$used")"
else fail "8. workflows use [$(tr '\n' ' ' <<<"$used")], the action derives [$(tr '\n' ' ' <<<"$derived")]"; fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
