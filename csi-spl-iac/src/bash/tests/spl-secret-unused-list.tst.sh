#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_secret_unused_list (SPL-1945 row 2, SPL-2896) lists the
#          unused credential candidates of one env and this box, READ-ONLY,
#          with the evidence for each verdict, and never prints a value.
#   1. the verdicts: project key IN-USE, a key file no code names UNUSED, a
#      key with no file on the box CHECK, a 0-version secret EMPTY (an enabled
#      one is not listed), a token file code reads IN-USE, a credential
#      backup BACKUP, a backup with no credential field not listed
#   2. key id prefix only (8 chars); no stubbed secret value, key, token or
#      private key in the output
#   3. every gcloud call as the dev project SA on csi-spl-dev, in a private
#      CLOUDSDK_CONFIG; no `versions access`, nothing that changes anything
#   4. CONTROL: code that names the -rel key file turns its row IN-USE
#      (fails when the consumer grep is removed)
#   5. RED CONTROL: a copy of the action that echoes the gcloud dump leaks
#      the stubbed secret, and the leak check of 2 catches it (fails when
#      the leak check cannot see a value)
#   6. a list that fails -> non-zero, no table
# gcloud and gh are stubs on PATH. No network, no GCP, no GitHub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/spl-secret-unused-list.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
# the stubbed values the output must never carry; built at run time, so no
# line of this file has the shape of a key, a token or an SA key field
stub() { printf 'STUB-%s-%s' "$1" "$2"; }
PK="private""_key" TOK="ghp""_STUB""TOKEN0042" K1="1111aaaa""2222bbbb" K2="3333cccc""4444dddd"
WATCH="$(stub SECRET-VALUE 7f3a)|$(stub PRIVATE-KEY 9c1d)|$TOK|$(stub REFRESH 5e8b)|$(stub MISTRAL-KEY 2d6f)|$K1|$K2|5555eeee6666ffff"
H="$T/home"; mkdir -p "$H/.gcp/.csi" "$H/.github/.csi" "$H/.claude" "$H/.vibe" "$T/stub" "$T/app/csi-spl-cnf" "$T/app/code"
key() { jq -nc --arg e "$2" --arg i "$3" --arg f "$PK" --arg v "$(stub PRIVATE-KEY 9c1d)" \
  '{type: "service_account", client_email: $e, ($f + "_id"): $i, ($f): $v}' >"$H/.gcp/.csi/$1"; }
key key-csi-spl-dev.json "$DEV_SA" "$K1"
key key-csi-spl-dev-rel.json csi-spl-rel-dev@csi-spl-dev.iam.gserviceaccount.com "$K2"
echo "$TOK" >"$H/.github/token"
jq -nc --arg v "$(stub REFRESH 5e8b)" '{claudeAiOauth: {accessToken: "x", refreshToken: $v}}' >"$H/.claude/.credentials.json"
cp "$H/.claude/.credentials.json" "$H/.claude/.credentials.json.bak-login-20261020T000000Z"
echo '{"note":"no credential field"}' >"$H/.claude/.credentials.json.old"
echo "MISTRAL_API""_KEY=$(stub MISTRAL-KEY 2d6f)" >"$H/.vibe/.env"
cp "$H/.vibe/.env" "$H/.vibe/.env.free-api.bak"
touch -d '2026-10-01T00:00:00Z' "$H/.github/token" "$H/.claude/.credentials.json.bak-login-20261020T000000Z" "$H/.vibe/.env.free-api.bak"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$T/app/csi-spl-cnf/csi-spl"
echo 'tok=$(cat "$HOME/.github/token")' >"$T/app/code/reader.sh"
echo 'secret_id = "spl-empty-one"' >"$T/app/code/secrets.tf"
git -C "$T/app" init -q && git -C "$T/app" add -A && git -C "$T/app" -c user.name=t -c user.email=t@t commit -qm fixture

cat >"$T/stub/gcloud" <<'EOF_G'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
k() { printf '{"name":"projects/p/serviceAccounts/%s/keys/%s","validAfterTime":"%s","validBeforeTime":"9999-12-31T23:59:59Z","disabled":false,"privateKeyData":"STUB-SECRET-VALUE-7f3a"}' "$1" "$2" "$3"; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets list"*) [[ -n "${STUB_FAIL:-}" ]] && exit 1
    echo '[{"name":"projects/1/secrets/spl-empty-one","createTime":"2026-09-20T00:00:00Z","payload":"STUB-SECRET-VALUE-7f3a"},{"name":"projects/1/secrets/spl-live-one","createTime":"2026-09-20T00:00:00Z"}]' ;;
  "secrets versions list spl-empty-one"*) echo '[{"name":"projects/1/secrets/spl-empty-one/versions/1","state":"DESTROYED","createTime":"2026-09-20T00:00:00Z"}]' ;;
  "secrets versions list spl-live-one"*) echo '[{"name":"projects/1/secrets/spl-live-one/versions/1","state":"ENABLED","createTime":"2026-09-20T00:00:00Z"}]' ;;
  "iam service-accounts list"*) echo '[{"email":"csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com"},{"email":"csi-spl-rel-dev@csi-spl-dev.iam.gserviceaccount.com"}]' ;;
  "iam service-accounts keys list"*"--iam-account=csi-spl-dev@"*) echo "[$(k csi-spl-dev 1111aaaa2222bbbb 2026-09-19T00:00:00Z)]" ;;
  "iam service-accounts keys list"*"--iam-account=csi-spl-rel-dev@"*)
    echo "[$(k csi-spl-rel-dev 3333cccc4444dddd 2026-09-17T00:00:00Z),$(k csi-spl-rel-dev 5555eeee6666ffff 2026-09-01T00:00:00Z)]" ;;
esac
exit 0
EOF_G
printf '#!/usr/bin/env bash\necho "gh|$*" >>"$STUB_LOG"; echo STUB-SECRET-VALUE-7f3a\n' >"$T/stub/gh"
chmod +x "$T/stub/gcloud" "$T/stub/gh"

# act [action file] [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  local f="$ACTION"; [[ "${1:-}" == /* ]] && { f="$1"; shift; }
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u SPOOL_DESK_BOX HOME="$H" USER=tester PATH="$T/stub:$PATH" \
    STUB_LOG="$T/calls.log" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/app" ENV=dev ACTION_FILE="$f" \
    SECRET_UNUSED_BOX=testbox SECRET_UNUSED_NOW=2026-10-21T00:00:00Z "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-secret-age-report.func.sh "$ACTION_FILE"; do source "$f"; done
    do_spl_secret_unused_list' >"$T/out" 2>&1
}
row() { grep -m1 -F "$1" "$T/out"; }
leaks() { grep -oE "$WATCH" "$1" | sort -u | tr '\n' ' '; }

# --- 1. verdicts -----------------------------------------------------------------
act; rc=$?
[[ $rc -eq 0 ]] && grep -q '^| # | class | where | age d | verdict | evidence |$' "$T/out" \
  && pass "1. exit 0 and a markdown table" || fail "1. rc=$rc $(cat "$T/out")"
[[ "$(row 'key 1111aaaa')" == *"| sa-key | csi-spl-dev / csi-spl-dev / key 1111aaaa / ~/.gcp/.csi/key-csi-spl-dev.json | 32 | IN-USE | the project key file do_gcp_account reads |" ]] \
  && pass "1. the project key file -> IN-USE" || fail "1. project key: $(row 'key 1111aaaa')"
[[ "$(row 'key 3333cccc')" == *"/ ~/.gcp/.csi/key-csi-spl-dev-rel.json | 34 | UNUSED | code naming the file \`git grep -lE 'key-[^ \"']*-rel\\.json'\` (no *.md) -> 0 |" ]] \
  && pass "1. a key file no code names -> UNUSED, the grep cited" || fail "1. rel key: $(row 'key 3333cccc')"
[[ "$(row 'key 5555eeee')" == *"| 50 | CHECK | no key file on this box holds it"* ]] \
  && pass "1. a key with no file on this box -> CHECK" || fail "1. no-file key: $(row 'key 5555eeee')"
[[ "$(row 'Secret Manager spl-empty-one')" == *"| 31 | EMPTY | 0 enabled versions"*"-> 1: secrets.tf |" ]] && ! grep -q 'spl-live-one' "$T/out" \
  && pass "1. a 0-version secret -> EMPTY with its declaring code; an enabled one not listed" || fail "1. secrets: $(cat "$T/out")"
[[ "$(row 'testbox ~/.github/token')" == *"| testbox ~/.github/token | 20 | IN-USE | code reading it"*"-> 1: reader.sh;"* ]] \
  && pass "1. a token file code reads -> IN-USE, the reader named" || fail "1. token: $(row 'testbox ~/.github/token')"
[[ "$(row 'bak-login')" == *"| seat-backup | testbox ~/.claude/.credentials.json.bak-login-20261020T000000Z | 20 | BACKUP | a copy of ~/.claude/.credentials.json (live file present"* ]] \
  && [[ "$(row 'free-api')" == *"| BACKUP |"* ]] && pass "1. Claude and Mistral credential backups -> BACKUP" || fail "1. backups: $(cat "$T/out")"
! grep -q 'credentials.json.old' "$T/out" && pass "1. a backup with no credential field is not listed" || fail "1. .old listed"
grep -q '^UNUSED: 1, EMPTY: 1, BACKUP: 2, CHECK: 1, IN-USE: 2$' "$T/out" && pass "1. the counts line" || fail "1. counts: $(tail -1 "$T/out")"

# --- 2. nothing secret printed --------------------------------------------------------
l="$(leaks "$T/out")"
[[ -z "$l" ]] && pass "2. no stubbed value, key, token, private key or full key id in the output" || fail "2. leaked: $l"

# --- 3. identity, read-only -----------------------------------------------------------
n=$(grep -cE '\|(secrets|iam) ' "$T/calls.log"); m=$(grep -E '\|(secrets|iam) ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev')
[[ $n -eq 6 && $n -eq $m ]] && pass "3. all $n metadata calls as the dev project SA on csi-spl-dev" || fail "3. identity: $n vs $m $(cat "$T/calls.log")"
cfg=$(awk -F'|' '/\|secrets / {print $1; exit}' "$T/calls.log")
[[ -n "$cfg" && "$cfg" != "<unset>" && ! -e "$cfg" ]] && pass "3. a private CLOUDSDK_CONFIG, removed afterwards" || fail "3. config: '$cfg'"
! grep -qE 'versions access|delete|destroy|disable|create|add-iam|remove-iam|^gh\|' "$T/calls.log" \
  && pass "3. no value read, nothing changed, no gh call" || fail "3. calls: $(cat "$T/calls.log")"

# --- 4. CONTROL: code that names the -rel key file --------------------------------------
echo 'k="$HOME/.gcp/.csi/key-csi-spl-${ENV}-rel.json"' >"$T/app/code/rel.sh"
git -C "$T/app" add -A && git -C "$T/app" -c user.name=t -c user.email=t@t commit -qm rel
act; [[ "$(row 'key 3333cccc')" == *"| IN-USE | code naming the file"*"-> 1: rel.sh |" ]] \
  && pass "4. CONTROL: a reader of the -rel key file -> IN-USE" || fail "4. $(row 'key 3333cccc')"
git -C "$T/app" rm -q code/rel.sh && git -C "$T/app" -c user.name=t -c user.email=t@t commit -qm unrel

# --- 5. RED CONTROL: an action that echoes the dump leaks, and the check sees it ------------
sed 's|^  spl_secret_unused_table "\$d"|  cat "$d"/sa/*.json "$d"/secrets.json; spl_secret_unused_table "$d"|' "$ACTION" >"$T/leaky.func.sh"
grep -q 'cat "$d"/sa' "$T/leaky.func.sh" || fail "5. the leaky copy was not made"
act "$T/leaky.func.sh"; l="$(leaks "$T/out")"
[[ "$l" == *STUB-SECRET-VALUE-7f3a* && "$l" == *5555eeee6666ffff* ]] \
  && pass "5. RED CONTROL: an echoed dump leaks the stubbed secret and the full key id, and the check catches both" \
  || fail "5. red control not caught: '$l'"

# --- 6. a failing list -------------------------------------------------------------------
act STUB_FAIL=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'cannot list the secrets' "$T/out" && ! grep -q '^| # |' "$T/out" \
  && pass "6. a failing secrets list -> non-zero, no table" || fail "6. rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
