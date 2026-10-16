#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_wine_box_tester_tf, offline (do_spl_db_query and make
#   stubbed, a throwaway key from ssh-keygen):
#   1. plan: the key and user:<address> reach make only as the two TF_VAR
#      lists, for 061 in dev; the output carries the fingerprint and masks
#      the key body, its comment and the address (the make stub echoes all).
#   2. TF_VERB=provision runs do-provision; another verb is refused.
#   3. no row, two rows, a non-key body or a bad msg id stop it before make.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-wine-box-tester-tf.func.sh"
fails=0
ok() { echo "PASS: $1"; }
ko() { echo "FAIL: $1"; fails=$((fails + 1)); }

bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ssh-keygen -q -t ed25519 -N '' -C 'name@laptop' -f "$T/k" || { echo "FAIL: ssh-keygen"; exit 1; }
KEY=$(cat "$T/k.pub")
BODY=$(awk '{print $2}' "$T/k.pub")
FP=$(ssh-keygen -lf "$T/k.pub" | awk '{print $2}')
MAIL=tester@example.test
MSG=00000000-0000-4000-8000-000000000001
export PROJ_PATH="$T/orc"
unset TF_VERB KEY_ENV TF_VAR_iap_members TF_VAR_desktop_user_ssh_public_keys

do_log() { echo "$*"; }
do_require_bin() { :; }
# psql aligned output: header, the marked rows, a row count. STUB_ROWS picks it.
do_spl_db_query() {
  printf '%s\n' "$ENV $SQL" >"$T/query.log"
  echo "INFO proxy up"
  echo "  r"
  echo "-----"
  case "${STUB_ROWS:-ok}" in
    ok) echo " KEY $KEY"; echo " MAIL $MAIL                   " ;;
    two) echo " KEY $KEY"; echo " KEY $KEY"; echo " MAIL $MAIL" ;;
    nokey) echo " KEY hello there"; echo " MAIL $MAIL" ;;
    none) : ;;
  esac
  echo "(2 rows)"
}
mkdir -p "$T/bin"
cat >"$T/bin/make" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$T/make.log"
printf '%s\n%s\n' "\${TF_VAR_desktop_user_ssh_public_keys:-}" "\${TF_VAR_iap_members:-}" >"$T/make.env"
echo "metadata ssh-keys = wine:\${TF_VAR_desktop_user_ssh_public_keys:-}"
echo "member = \${TF_VAR_iap_members:-}"
STUB
chmod +x "$T/bin/make"
export PATH="$T/bin:$PATH"
# shellcheck disable=SC1090
source "$FUNC"

# --- 1. plan ------------------------------------------------------------------
out=$(KEY_MSG_ID=$MSG do_spl_wine_box_tester_tf 2>&1); rc=$?
(( rc == 0 )) || ko "plan rc=$rc: $out"
grep -q "^prd .*msg_id = '$MSG'" "$T/query.log" && ok "the message is read from prd by its id" || ko "query: $(cat "$T/query.log")"
grep -qx -- "-C $T/orc do-tf-plan ENV=dev STEP=061-gcp-vm-wine-box" "$T/make.log" && ok "plan runs make do-tf-plan for 061 in dev" || ko "make: $(cat "$T/make.log")"
[[ "$(sed -n 1p "$T/make.env")" == "$(jq -cn --arg k "$KEY" '[$k]')" ]] && ok "make gets the key as a one-item list" || ko "key var: $(sed -n 1p "$T/make.env")"
[[ "$(sed -n 2p "$T/make.env")" == "[\"user:$MAIL\"]" ]] && ok "make gets user:<address> as the IAP member" || ko "member var: $(sed -n 2p "$T/make.env")"
grep -qF "$FP" <<<"$out" && ok "the output names the fingerprint" || ko "no fingerprint: $out"
for s in "$BODY" "$MAIL" name@laptop; do
  grep -qF "$s" <<<"$out" && ko "the output carries '$s'" || ok "the output never carries '${s:0:12}...'"
done
grep -q '<KEY> <KEY-COMMENT>' <<<"$out" && grep -q 'user:<TESTER>' <<<"$out" && ok "echoed values are masked" || ko "no masked line: $out"

# --- 2. verbs -----------------------------------------------------------------
: >"$T/make.log"
TF_VERB=provision KEY_MSG_ID=$MSG do_spl_wine_box_tester_tf >/dev/null 2>&1
grep -q ' do-provision ENV=dev STEP=061-gcp-vm-wine-box' "$T/make.log" && ok "TF_VERB=provision applies" || ko "provision: $(cat "$T/make.log")"
TF_VERB=destroy KEY_MSG_ID=$MSG do_spl_wine_box_tester_tf >/dev/null 2>&1 && ko "TF_VERB=destroy accepted" || ok "an unknown TF_VERB is refused"

# --- 3. refusals before make --------------------------------------------------
for r in none two nokey; do
  : >"$T/make.log"
  STUB_ROWS=$r KEY_MSG_ID=$MSG do_spl_wine_box_tester_tf >/dev/null 2>&1 && ko "rows '$r' accepted" || ok "rows '$r' are refused"
  [[ -s "$T/make.log" ]] && ko "make ran on rows '$r'" || ok "make does not run on rows '$r'"
done
: >"$T/query.log"
KEY_MSG_ID="x'; drop" do_spl_wine_box_tester_tf >/dev/null 2>&1 && ko "a bad msg id accepted" || ok "a bad msg id is refused"
[[ -s "$T/query.log" ]] && ko "a bad msg id reached the query" || ok "a bad msg id never reaches the query"

(( fails == 0 )) && echo "PASS: all" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
