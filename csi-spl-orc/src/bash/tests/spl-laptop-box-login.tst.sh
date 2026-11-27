#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the laptop box's read-only login pull (SPL-6680, spec 037 "Laptop
#          box"; owner Q1 = PUL): laptop-login-serve.sh (the key's forced
#          command on the move box), laptop-login-peer.sh (the laptop's ssh),
#          do_spl_laptop_box_login_grant (the authorized_keys line) and
#          do_spl_laptop_box_login_pull (the sync's wiring). Stubs only.
#   1. serve: a read op on a served file reaches the helper; a write op
#      (fput, put, facctput), an unserved file, a bad jq path, extra words
#      and an empty command are refused (exit 2) and the helper never runs
#   2. peer: plain words go to ssh with the laptop key, batch mode and
#      accept-new; a word with a shell character is refused before ssh
#   3. grant: the dry run writes nothing and prints no key; a bad key is
#      refused; grant writes one restrict,command= line serving the cnf
#      files, keeps other lines, installs both scripts root-owned; a second
#      grant replaces it; grant-move adds a plain line for the move key;
#      revoke removes both, only those
#      W2: a key with a newline or a CR, a bad LAPTOP_SERVE_LIB -> exit 2
#   4. pull: no laptop-box.env -> exit 3; a bad LAPTOP_MOVE_SSH -> exit 3;
#      else the sync runs claude, move box -> this box, through the peer
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export IN_ORC_RUN="spl-laptop-box-login-grant spl-laptop-box-login-pull"
FB="$PROJ_ROOT/src/bash/features/laptop-box"
mkdir -p "$T/stub"
printf '#!/usr/bin/env bash\necho "helper $*" >>"%s/helper.log"\n' "$T" >"$T/helper"; chmod +x "$T/helper"
FILES=".cli/login.json .cli.json"
serve() { : >"$T/helper.log"; SSH_ORIGINAL_COMMAND="$1" LAPTOP_SERVE_FILES="$FILES" LAPTOP_SERVE_HELPER="$T/helper" bash "$FB/laptop-login-serve.sh" >/dev/null 2>&1; }

# 1
serve "fstat .cli/login.json .oauth.expiresAt"; r1=$?; l1="$(cat "$T/helper.log")"
serve "fget .cli/login.json"; r2=$?; l2="$(cat "$T/helper.log")"
[[ $r1 -eq 0 && "$l1" == "helper fstat .cli/login.json .oauth.expiresAt" && $r2 -eq 0 && "$l2" == "helper fget .cli/login.json" ]] \
  && pass "1 serve: read ops on served files" || fail "1 serve read: $r1 '$l1' $r2 '$l2'"
bad=0
for c in "fput .cli/login.json 20261127" "fput .cli/login.json" "facctput .cli.json" "put" "facctput .cli.json 1" "fget .ssh/id_ed25519" "fget ../x" \
  "fstat .cli/login.json \$(id)" "fget .cli.json extra words" "" "fget"; do
  serve "$c"; rc=$?; { [[ $rc -eq 2 && ! -s "$T/helper.log" ]]; } || { bad=1; echo "  not refused: '$c' rc=$rc"; }
done
(( bad == 0 )) && pass "1 serve: writes, other files, bad args refused, helper never run" || fail "1 serve refusals"

# 2
printf '#!/usr/bin/env bash\necho "ssh $*" >>"%s/ssh.log"\n' "$T" >"$T/stub/ssh"; chmod +x "$T/stub/ssh"
LAPTOP_SSH="$T/stub/ssh" LAPTOP_SSH_KEY=/k bash "$FB/laptop-login-peer.sh" u@h fstat .cli.json .x; r1=$?
LAPTOP_SSH="$T/stub/ssh" bash "$FB/laptop-login-peer.sh" u@h fget '.cli.json;id' 2>/dev/null; r2=$?
grep -qx "ssh -i /k -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 u@h fstat .cli.json .x" "$T/ssh.log" \
  && [[ $r1 -eq 0 && $r2 -eq 2 && "$(wc -l <"$T/ssh.log")" -eq 1 ]] && pass "2 peer: plain words to ssh, shell words refused" || { fail "2 peer r=$r1/$r2"; cat "$T/ssh.log"; }

# 3
CNF="$T/all.env.yaml"
printf 'env:\n  box:\n    agent_cred_sync:\n      claude:\n        main:\n          files: [.cli/login.json]\n          account: .cli.json\n' >"$CNF"
AK="$T/ak"; printf 'ssh-ed25519 AAAAother other@x\n' >"$AK"
cat >"$T/rootrun" <<'R'
#!/usr/bin/env bash
for c in "$@"; do echo "$c" >>"$ROOTLOG"; done
R
chmod +x "$T/rootrun"
KEY="ssh-ed25519 AAAAC3NzaLaptopKey1 spl-laptop-box:lap-a"
grant() { SNIPPET=do_spl_laptop_box_login_grant in_orc LAPTOP_SERVE_CNF="$CNF" LAPTOP_AUTH_KEYS="$AK" LAPTOP_ROOT_RUN="$T/rootrun" ROOTLOG="$T/root.log" BOX_TAG=lap-a "$@" >"$T/o" 2>&1; }
grant LAPTOP_PUBKEY="$KEY"; rc=$?
[[ $rc -eq 0 && "$(cat "$AK")" == "ssh-ed25519 AAAAother other@x" && ! -e "$T/root.log" ]] && ! grep -q AAAAC3Nza "$T/o" && pass "3 grant dry run: nothing written, no key printed" || { fail "3 dry rc=$rc"; cat "$T/o"; }
grant LAPTOP_PUBKEY="ssh-rsa AAAAB3 x" DRY_RUN=0; [[ $? -eq 2 ]] && pass "3 a non-ed25519 key is refused" || fail "3 bad key"
grant LAPTOP_PUBKEY="$KEY" DRY_RUN=0; rc=$?
want="restrict,command=\"LAPTOP_SERVE_FILES='.cli/login.json .cli.json' bash /usr/local/lib/spl-laptop-box/laptop-login-serve.sh\" ssh-ed25519 AAAAC3NzaLaptopKey1 spl-laptop-box:lap-a"
if [[ $rc -eq 0 ]] && grep -qxF "$want" "$AK" && grep -qx "ssh-ed25519 AAAAother other@x" "$AK" && [[ "$(stat -c %a "$AK")" == 600 ]] \
  && grep -q "laptop-login-serve.sh' '/usr/local/lib/spl-laptop-box/laptop-login-serve.sh'" "$T/root.log" && grep -q "agent-login-cred.sh' '/usr/local/lib/spl-laptop-box/agent-login-cred.sh'" "$T/root.log"; then
  pass "3 grant: one restricted line, other lines kept, scripts root-owned"
else fail "3 grant rc=$rc"; cat "$T/o" "$AK"; fi
grant LAPTOP_PUBKEY="${KEY/Key1/Key2}" DRY_RUN=0
[[ "$(grep -c 'spl-laptop-box:lap-a$' "$AK")" == 1 ]] && grep -q LaptopKey2 "$AK" && pass "3 a second grant replaces the line" || fail "3 regrant"
MKEY="ssh-ed25519 AAAAC3NzaMoveKey1 spl-laptop-box-move:lap-a"
grant LAPTOP_GRANT_CMD=grant-move LAPTOP_PUBKEY="$MKEY" DRY_RUN=0
grep -qx "ssh-ed25519 AAAAC3NzaMoveKey1 spl-laptop-box-move:lap-a" "$AK" && grep -q "LaptopKey2 spl-laptop-box:lap-a$" "$AK" && pass "3 grant-move: a plain line, the read line kept" || { fail "3 grant-move"; cat "$AK"; }
grant LAPTOP_GRANT_CMD=revoke DRY_RUN=0
[[ "$(cat "$AK")" == "ssh-ed25519 AAAAother other@x" ]] && pass "3 revoke removes both of its lines, only those" || { fail "3 revoke"; cat "$AK"; }
# W2 (R7 a-736): a key value with a newline or a CR (bash's '.' takes a
# newline) is refused for grant and grant-move, nothing written; so is a
# serve lib that is not an absolute plain path
cp "$AK" "$T/ak.w2"; w2=""
for k in "$KEY"$'\n'"ssh-ed25519 AAAAInjected x" "$KEY"$'\r'; do
  for c in grant grant-move; do grant LAPTOP_GRANT_CMD=$c LAPTOP_PUBKEY="$k" DRY_RUN=0; w2+="$? "; done
done
for l in rel/lib "/x' ; id ; '" /a/../b; do grant LAPTOP_PUBKEY="$KEY" LAPTOP_SERVE_LIB="$l" DRY_RUN=0; w2+="$? "; done
[[ "$w2" == "2 2 2 2 2 2 2 " ]] && cmp -s "$AK" "$T/ak.w2" && ! grep -q Injected "$AK" \
  && pass "3 W2 a 2-line or CR key, a bad serve lib: refused, nothing written" || { fail "3 W2: $w2"; cat "$AK"; }

# 4
SR="$T/spool"; mkdir -p "$SR/dispatch"; export LAPTOP_ENV_FILE="$SR/dispatch/laptop-box.env"
printf '#!/usr/bin/env bash\nenv | grep -E "^(CRED_|SPOOL_BOX_TAG=)" | sort >"%s/sync.env"\n' "$T" >"$T/sync"; chmod +x "$T/sync"
pull() { SNIPPET=do_spl_laptop_box_login_pull in_orc SPOOL_ROOT="$SR" LAPTOP_SYNC_CMD="$T/sync" >"$T/o" 2>&1; }
pull; r1=$?
printf '%s\n' LAPTOP_BOX_TAG=lap-a LAPTOP_MOVE_BOX=home "LAPTOP_MOVE_SSH=u@h;id" >"$SR/dispatch/laptop-box.env"; pull; r2=$?
sed -i 's/^LAPTOP_MOVE_SSH=.*/LAPTOP_MOVE_SSH=agt@home.example.com/' "$SR/dispatch/laptop-box.env"; pull; r3=$?
if [[ $r1 -eq 3 && $r2 -eq 3 && $r3 -eq 0 ]] && grep -qx CRED_VENDOR=claude "$T/sync.env" && grep -qx CRED_SRC_BOX=home "$T/sync.env" \
  && grep -qx CRED_DST_BOX=lap-a "$T/sync.env" && grep -qx CRED_PEERS=home=agt@home.example.com "$T/sync.env" \
  && grep -q "^CRED_PEER_CMD=bash .*/features/laptop-box/laptop-login-peer.sh$" "$T/sync.env"; then pass "4 pull: refusals, then the sync wired move box -> this box"
else fail "4 pull r=$r1/$r2/$r3"; cat "$T/o" "$T/sync.env" 2>/dev/null; fi

echo "=== spl-laptop-box-login: $fails failure(s) ==="
(( fails == 0 ))
