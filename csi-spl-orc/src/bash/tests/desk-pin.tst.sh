#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_pin (specs/037), the box key + pin step of the
#          installer. No cloud call: `spool` is a stub that records its argv.
#   1. dry run touches nothing; bad input is refused before any spool call
#   2. check mode, not pinned: key minted, hub-sync asked, exit 3, the admin
#      line carries the pubkey; no `pinned` file
#   3. re-run while pending REUSES the key (no second keygen)
#   4. check mode once the hub knows the pin: `pinned` written, exit 0
#   5. self mode (ROOT_KEY_JSON): hub-pin with the same key, the root key
#      never reaches argv of anything but a 0600 scratch path
#   6. admin mode (BOX_PUBKEY): pins the given key, writes no local state
#   6b. PIN_REVOKE=1 revokes; with a pubkey or a bad value it is refused
#   7. SPOOL_HUB_URL that is not the cnf hub is refused
#   8. ENV=self (specs/047 W4): any hub URL, no cnf; saved and reused; a
#      different URL, a URL with a path, or none at all is refused; a bare
#      base64 root key file (the compose stack's tenant-root.key) pins
#   9. join mode (spec 108 / 073, SPOOL_JOIN_TOKEN): the box key is minted,
#      `spool join` seats it, `pinned` is written; the token is in neither
#      argv nor output; a token of another workspace, or a token next to
#      ROOT_KEY_JSON, is refused before any call. CONTROL: a hub refusal
#      writes no `pinned`
#   9b. do_spl_desk_up's first run (spl_desk_pin) takes the join token in
#      place of ROOT_KEY_JSON and prints only the pubkey. CONTROL: with
#      neither it is refused and names both
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
# keygen writes a real ed25519-shaped key (64 bytes) and prints its public half
cat >"$T/stub/spool" <<'EOF'
#!/usr/bin/env bash
echo "spool $* root=$SPOOL_ROOT box=$SPOOL_BOX_ID hub=$SPOOL_HUB_URL tenant=$SPOOL_TENANT" >>"$STUB_LOG"
case "$1" in
  keygen) python3 -c 'import base64,os,sys; k=os.urandom(64); open(sys.argv[1],"w").write(base64.b64encode(k).decode()+"\n"); print(base64.b64encode(k[32:]).decode())' \
            "$SPOOL_KEYS_DIR/box-$SPOOL_BOX_ID.key" ;;
  hub-sync) [ -e "$STUB_PINNED" ] && { echo '{"sent":0}'; exit 0; }; echo 'error: box is not pinned (401)' >&2; exit 1 ;;
  join) [ "${STUB_JOIN_FAIL:-0}" = 1 ] && { echo 'join: box_join_disabled (403)' >&2; exit 1; }
        [ -s "$SPOOL_KEYS_DIR/box-$SPOOL_BOX_ID.key" ] || exit 9
        printf '%s\n' "${SPOOL_JOIN_TOKEN:-}" >"$T_TOKSEEN"; echo "seated $SPOOL_BOX_ID on $SPOOL_TENANT" ;;
  hub-pin) prev=""; for a in "$@"; do [ "$prev" = --root-key ] && { stat -c %a "$a" >>"$STUB_LOG"; cat "$a" >>"$T_ROOTSEEN"; }; prev="$a"; done
           touch "$STUB_PINNED"; echo '{"pinned":true}' ;;
esac
EOF
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    STUB_PINNED="$T/pinned-at-hub" T_ROOTSEEN="$T/rootseen" T_TOKSEEN="$T/tokseen" PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_host_spool() { SPL_SPOOL="$(command -v spool)"; }
    do_spl_desk_pin'
}
SEAT="$T/state/dev/desk/t1/box-ext"
HUB="$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" ENV=dev bash -c '
  do_log() { :; }; for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf >/dev/null && echo "https://$(yq -r .env.dns.api_fqdn "$SPL_CNF")"')"
[[ "$HUB" =~ ^https://[a-z0-9.-]+$ ]] || { echo "FAIL: no dev hub from the merged cnf: '$HUB'"; exit 1; }

# --- 1. dry run and refusals -------------------------------------------------------
: >"$T/calls.log"
in_orc TENANT_ID=t1 DESK_BOX=box-ext >"$T/o" 2>&1
[[ $? -eq 0 && ! -s "$T/calls.log" && ! -e "$SEAT" ]] && grep -q 'OK DRY_RUN nothing was touched' "$T/o" &&
  pass "1. the dry run touches nothing" || fail "1. dry run: $(cat "$T/o" "$T/calls.log")"
for bad in "TENANT_ID=T_1" "DESK_BOX=box-wui" "BOX_PUBKEY=nope ROOT_KEY_JSON=/x" "BOX_PUBKEY=$(printf 'A%.0s' {1..43})=" "ROOT_KEY_JSON=$T/absent.json"; do
  # shellcheck disable=SC2086
  in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 $bad >"$T/o" 2>&1 && fail "1. '$bad' was accepted" || pass "1. '$bad' is refused"
done
[[ ! -s "$T/calls.log" ]] && pass "1. no refusal called spool" || fail "1. a refusal called: $(cat "$T/calls.log")"

# --- 2. check mode, pending ----------------------------------------------------------
in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1; rc=$?
PUB="$(python3 -c 'import json,sys; [print(json.loads(l)["box_pubkey"]) for l in open(sys.argv[1]) if l.startswith("{")]' "$T/o")"
[[ $rc -eq 3 ]] && pass "2. not pinned yet: exit 3" || fail "2. rc $rc: $(cat "$T/o")"
[[ -s "$SEAT/keys/box-box-ext.key" && ! -e "$SEAT/pinned" ]] && pass "2. key minted, no pinned file" || fail "2. state: $(ls -R "$SEAT")"
grep -q "BOX_PUBKEY=$PUB .*do_spl_desk_pin" "$T/o" && grep -q "spool hub-pin --box box-ext --pubkey $PUB" "$T/o" &&
  pass "2. the admin line (./run and bare spool) carries the pubkey" || fail "2. admin line: $(cat "$T/o")"
grep -q "^spool hub-sync root=$SEAT/spool box=box-ext hub=$HUB tenant=t1" "$T/calls.log" &&
  pass "2. hub-sync asked the cnf hub as box-ext in t1" || fail "2. sync argv: $(cat "$T/calls.log")"
[[ "$(stat -c %a "$SEAT")" == 700 ]] && pass "2. the seat dir is 0700" || fail "2. seat mode $(stat -c %a "$SEAT")"

# --- 3. re-run reuses the key ---------------------------------------------------------
in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1
[[ "$(grep -c '^spool keygen' "$T/calls.log")" == 1 ]] && grep -q "BOX_PUBKEY=$PUB " "$T/o" &&
  pass "3. a pending re-run reuses the one key" || fail "3. keygens: $(grep -c '^spool keygen' "$T/calls.log") $(cat "$T/o")"

# --- 4. the admin pinned it: check mode writes pinned ----------------------------------
touch "$T/pinned-at-hub"
in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && "$(cat "$SEAT/pinned")" == "$PUB" ]] && grep -q '"pinned": true' "$T/o" &&
  pass "4. once pinned at the hub: pinned file = the pubkey, exit 0" || fail "4. rc $rc: $(cat "$T/o")"
: >"$T/calls.log"
in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -q '^spool hub-sync' "$T/calls.log" && grep -q 'already pinned' "$T/o" &&
  pass "4. a pinned box is not asked again" || fail "4. idempotent: rc $rc $(cat "$T/calls.log")"

# --- 5. self mode ------------------------------------------------------------------------
rm -f "$T/pinned-at-hub"; : >"$T/calls.log"
ROOTK="root-secret-$RANDOM$RANDOM"
( umask 077; printf '{"root_private_key":"%s"}\n' "$ROOTK" >"$T/root.json" )
in_orc TENANT_ID=t1 DESK_BOX=box-own DRY_RUN=0 ROOT_KEY_JSON="$T/root.json" >"$T/o" 2>&1; rc=$?
OWN="$T/state/dev/desk/t1/box-own"
[[ $rc -eq 0 && -s "$OWN/pinned" ]] && grep -q "^spool hub-pin --box box-own --pubkey $(cat "$OWN/pinned") --root-key " "$T/calls.log" &&
  pass "5. self mode: hub-pin of the box's own key, pinned written" || fail "5. rc $rc: $(cat "$T/o" "$T/calls.log")"
grep -qx 600 "$T/calls.log" && grep -qx "$ROOTK" "$T/rootseen" && pass "5. the root key reached spool through a 0600 file" || fail "5. scratch: $(cat "$T/calls.log")"
grep -qF "$ROOTK" "$T/o" "$T/calls.log" && fail "5. the root key leaked into output / argv" || pass "5. the root key is in neither output nor argv"
chmod 644 "$T/root.json"
in_orc TENANT_ID=t1 DESK_BOX=box-own2 DRY_RUN=0 ROOT_KEY_JSON="$T/root.json" >"$T/o" 2>&1 &&
  fail "5. a 0644 root key JSON was accepted" || pass "5. a 0644 root key JSON is refused"
chmod 600 "$T/root.json"

# --- 6. admin mode ---------------------------------------------------------------------------
: >"$T/calls.log"
in_orc TENANT_ID=t1 DESK_BOX=box-peer DRY_RUN=0 ROOT_KEY_JSON="$T/root.json" BOX_PUBKEY="$PUB" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "^spool hub-pin --box box-peer --pubkey $PUB --root-key " "$T/calls.log" &&
  ! grep -q '^spool keygen' "$T/calls.log" && [[ ! -e "$T/state/dev/desk/t1/box-peer" ]] &&
  pass "6. admin mode pins the given key and writes no local seat" || fail "6. rc $rc: $(cat "$T/o" "$T/calls.log")"

# --- 6b. revoke ---------------------------------------------------------------------------------------
: >"$T/calls.log"
in_orc TENANT_ID=t1 DESK_BOX=box-peer DRY_RUN=0 ROOT_KEY_JSON="$T/root.json" PIN_REVOKE=1 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "^spool hub-pin --box box-peer --revoke --root-key " "$T/calls.log" && grep -q 'OK revoked the pin of box-peer' "$T/o" &&
  pass "6b. PIN_REVOKE=1 revokes the box's pin" || fail "6b. revoke rc $rc: $(cat "$T/o" "$T/calls.log")"
for bad in "PIN_REVOKE=1 BOX_PUBKEY=$PUB" "PIN_REVOKE=yes"; do
  : >"$T/calls.log"
  # shellcheck disable=SC2086
  in_orc TENANT_ID=t1 DESK_BOX=box-peer DRY_RUN=0 ROOT_KEY_JSON="$T/root.json" $bad >"$T/o" 2>&1 && fail "6b. '$bad' was accepted" ||
    { [[ ! -s "$T/calls.log" ]] && pass "6b. '$bad' is refused before any call" || fail "6b. '$bad' called spool"; }
done
in_orc TENANT_ID=t1 DESK_BOX=box-peer DRY_RUN=0 PIN_REVOKE=1 >"$T/o" 2>&1 && fail "6b. a revoke without a root key was accepted" || pass "6b. a revoke needs ROOT_KEY_JSON"

# --- 7. a foreign hub URL ---------------------------------------------------------------------
in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 SPOOL_HUB_URL=https://hub.example.com >"$T/o" 2>&1 &&
  fail "7. a SPOOL_HUB_URL other than the cnf hub was accepted" || pass "7. a SPOOL_HUB_URL other than the cnf hub is refused"
in_orc TENANT_ID=t1 DESK_BOX=box-ext DRY_RUN=0 SPOOL_HUB_URL="$HUB/" >"$T/o" 2>&1 &&
  pass "7. the cnf hub (trailing slash) is accepted" || fail "7. cnf hub refused: $(cat "$T/o")"

# --- 8. ENV=self: a self-hosted hub ----------------------------------------------------------
SELF="$T/state/self"; SH=http://localhost:18478
: >"$T/calls.log"
in_orc ENV=self SPL_STATE_DIR="$SELF" TENANT_ID=main DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1 &&
  fail "8. ENV=self with no SPOOL_HUB_URL was accepted" || { grep -q 'ENV=self needs SPOOL_HUB_URL' "$T/o" && pass "8. ENV=self with no hub URL is refused" || fail "8. no url: $(cat "$T/o")"; }
for bad in "http://localhost:18478/api" "ftp://x" "localhost:18478"; do
  in_orc ENV=self SPL_STATE_DIR="$SELF" SPOOL_HUB_URL="$bad" TENANT_ID=main DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1 &&
    fail "8. SPOOL_HUB_URL '$bad' was accepted" || pass "8. SPOOL_HUB_URL '$bad' is refused"
done
[[ ! -s "$T/calls.log" ]] && pass "8. no refusal called spool" || fail "8. a refusal called: $(cat "$T/calls.log")"
rm -f "$T/pinned-at-hub"
in_orc ENV=self SPL_STATE_DIR="$SELF" SPOOL_HUB_URL="$SH/" TENANT_ID=main DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 3 ]] && grep -q "^spool hub-sync root=$SELF/desk/main/box-ext/spool box=box-ext hub=$SH tenant=main" "$T/calls.log" &&
  pass "8. ENV=self asks the given hub (any host, http, trailing slash dropped); pending = exit 3" || fail "8. self check: rc $rc $(cat "$T/o" "$T/calls.log")"
grep -q "ENV=self SPOOL_HUB_URL=$SH TENANT_ID=main DESK_BOX=box-ext BOX_PUBKEY=" "$T/o" &&
  pass "8. the self admin line names the hub" || fail "8. admin line: $(cat "$T/o")"
[[ "$(cat "$SELF/hub-url")" == "$SH" ]] && pass "8. the hub URL is saved in the self state dir" || fail "8. saved: $(cat "$SELF/hub-url" 2>&1)"
: >"$T/calls.log"; touch "$T/pinned-at-hub"
in_orc ENV=self SPL_STATE_DIR="$SELF" TENANT_ID=main DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -s "$SELF/desk/main/box-ext/pinned" ]] && grep -q "hub=$SH " "$T/calls.log" &&
  pass "8. a re-run with no SPOOL_HUB_URL uses the saved hub" || fail "8. saved re-run: rc $rc $(cat "$T/o" "$T/calls.log")"
in_orc ENV=self SPL_STATE_DIR="$SELF" SPOOL_HUB_URL=https://chat.example.org TENANT_ID=main DESK_BOX=box-ext DRY_RUN=0 >"$T/o" 2>&1 &&
  fail "8. CONTROL: a second hub URL on the same self state was accepted" || { grep -q "seated at $SH" "$T/o" && pass "8. CONTROL: a different hub URL is refused (the keys are pinned at the saved one)" || fail "8. other hub: $(cat "$T/o")"; }
rm -f "$T/pinned-at-hub"; : >"$T/calls.log"; : >"$T/rootseen"
BARE="$(python3 -c 'import base64,os; print(base64.b64encode(os.urandom(64)).decode())')"
( umask 077; printf '%s\n' "$BARE" >"$T/tenant-root.key"; printf 'not a key\n' >"$T/junk.key" )
in_orc ENV=self SPL_STATE_DIR="$SELF" TENANT_ID=main DESK_BOX=box-own DRY_RUN=0 ROOT_KEY_JSON="$T/tenant-root.key" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -s "$SELF/desk/main/box-own/pinned" ]] && grep -qx "$BARE" "$T/rootseen" && grep -q "^spool hub-pin --box box-own .* --root-key " "$T/calls.log" &&
  pass "8. a bare base64 root key file pins the box (ENV=self)" || fail "8. bare key: rc $rc $(cat "$T/o" "$T/calls.log")"
grep -qF "$BARE" "$T/o" "$T/calls.log" && fail "8. the bare root key leaked into output / argv" || pass "8. the bare root key is in neither output nor argv"
in_orc ENV=self SPL_STATE_DIR="$SELF" TENANT_ID=main DESK_BOX=box-own3 DRY_RUN=0 ROOT_KEY_JSON="$T/junk.key" >"$T/o" 2>&1 &&
  fail "8. CONTROL: a file that is neither JSON nor a key was accepted" || pass "8. CONTROL: a file that is neither JSON nor a key is refused"

# --- 9. join mode ------------------------------------------------------------------------------
rm -f "$T/pinned-at-hub"
TOK="spj1.t1.sec$RANDOM$RANDOM$RANDOM"; JS="$T/state/dev/desk/t1/box-join"
for bad in "SPOOL_JOIN_TOKEN=spj1.t2.sec$RANDOM" "SPOOL_JOIN_TOKEN=nope" "SPOOL_JOIN_TOKEN=$TOK ROOT_KEY_JSON=$T/root.json"; do
  : >"$T/calls.log"
  # shellcheck disable=SC2086
  in_orc TENANT_ID=t1 DESK_BOX=box-join DRY_RUN=0 $bad >"$T/o" 2>&1 && fail "9. '${bad:0:24}...' was accepted" ||
    { [[ ! -s "$T/calls.log" ]] && ! grep -q 'sec[0-9]' "$T/o" && pass "9. '${bad:0:24}...' is refused before any call, token not echoed" || fail "9. '$bad': $(cat "$T/o" "$T/calls.log")"; }
done
in_orc TENANT_ID=t1 DESK_BOX=box-join SPOOL_JOIN_TOKEN="$TOK" >"$T/o" 2>&1
grep -q 'DRY_RUN would: mint or reuse the key of box-join .* spool join' "$T/o" && ! grep -qF "$TOK" "$T/o" &&
  pass "9. the dry run names the join and not the token" || fail "9. dry: $(cat "$T/o")"
: >"$T/calls.log"; : >"$T/tokseen"
in_orc TENANT_ID=t1 DESK_BOX=box-join DRY_RUN=0 SPOOL_JOIN_TOKEN="$TOK" STUB_JOIN_FAIL=1 >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 && ! -e "$JS/pinned" ]] && grep -q 'box_join_disabled' "$T/o" &&
  pass "9. CONTROL: a hub refusal fails the run and writes no pinned" || fail "9. refused join: rc $rc $(cat "$T/o")"
: >"$T/calls.log"
in_orc TENANT_ID=t1 DESK_BOX=box-join DRY_RUN=0 SPOOL_JOIN_TOKEN="$TOK" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -s "$JS/pinned" ]] && grep -q "^spool join --box box-join $HUB root=$JS/spool box=box-join hub=$HUB tenant=t1" "$T/calls.log" &&
  grep -q '"pinned": true' "$T/o" && pass "9. join mode: spool join seats box-join at the cnf hub, pinned written" || fail "9. join: rc $rc $(cat "$T/o" "$T/calls.log")"
[[ "$(cat "$JS/pinned")" == "$(python3 -c 'import base64,sys; print(base64.b64encode(base64.b64decode(open(sys.argv[1]).read().strip())[32:]).decode())' "$JS/keys/box-box-join.key")" ]] &&
  pass "9. pinned holds the public half of the box's own key" || fail "9. pinned: $(cat "$JS/pinned" 2>&1)"
grep -qx "$TOK" "$T/tokseen" && pass "9. spool join got the token from its environment" || fail "9. token not handed over"
grep -qF "$TOK" "$T/o" "$T/calls.log" && fail "9. the join token leaked into output / argv" || pass "9. the join token is in neither output nor argv"

# --- 9b. do_spl_desk_up's first run ------------------------------------------------------------
up_pin() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" STUB_LOG="$T/calls.log" T_TOKSEEN="$T/tokseen" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    SPL_SPOOL="$(command -v spool)"; d="$1"; mkdir -p "$d/keys" "$d/spool"
    spl_desk_pin "$d" box-up t1 https://hub.test ""' _ "$T/up"
}
: >"$T/tokseen"
up_pin SPOOL_JOIN_TOKEN="$TOK" >"$T/o" 2>"$T/e"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/o")" == "$(cat "$T/up/pinned" 2>/dev/null)" && "$(wc -l <"$T/o")" == 1 ]] && grep -qx "$TOK" "$T/tokseen" &&
  ! grep -qF "$TOK" "$T/o" "$T/e" && pass "9b. desk up's first run seats with the join token, stdout = the pubkey only" ||
  fail "9b. desk up join: rc $rc $(cat "$T/o" "$T/e")"
rm -rf "$T/up"; up_pin >"$T/o" 2>&1 && fail "9b. CONTROL: a first run with no key and no token was accepted" ||
  { grep -q 'ROOT_KEY_JSON .* or SPOOL_JOIN_TOKEN' "$T/o" && pass "9b. CONTROL: no key and no token is refused, both named" || fail "9b. control: $(cat "$T/o")"; }

[[ $fails -eq 0 ]] && echo "OK desk-pin: all passed" || { echo "FAILED desk-pin: $fails"; exit 1; }
