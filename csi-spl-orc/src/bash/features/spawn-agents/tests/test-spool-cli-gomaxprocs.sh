#!/usr/bin/env bash
# Spec 027 row 5 (perf p7-05, SPL-5448): the short `spool` CLI calls run with
# GOMAXPROCS=1 through spool_cli / spool_cli_timeout (lib/spool-env.inc.sh),
# a caller's own GOMAXPROCS wins, and the shell never exports it: a `go` child
# of the same shell still sees every core.
#
# Red controls (C2): `export GOMAXPROCS=1` in spool-env.inc.sh -> the `go`
# child sees 1, FAIL; spool_cli without the GOMAXPROCS prefix -> each spool
# call records <unset>, FAIL.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset GOMAXPROCS
CALLS="$T_TMP/calls"; : >"$CALLS"
mkdir -p "$T_TMP/bin"
# The fake spool records what each call saw; `send` answers like the real one.
cat >"$T_TMP/bin/spool" <<SH
#!/usr/bin/env bash
echo "\$1 GOMAXPROCS=\${GOMAXPROCS-<unset>}" >>"$CALLS"
[ "\$1" = send ] && echo '{"msg_id":"m-1","task_id":"t-1","delivery":"local"}'
exit 0
SH
cat >"$T_TMP/bin/go" <<SH
#!/usr/bin/env bash
echo "go GOMAXPROCS=\${GOMAXPROCS-<unset>}" >>"$CALLS"
SH
chmod +x "$T_TMP/bin/spool" "$T_TMP/bin/go"
export SPOOL_BIN="$T_TMP/bin/spool"
last() { tail -1 "$CALLS"; }

. "$T_FEAT/lib/spool-env.inc.sh"

spool_cli recv --as c-999 >/dev/null
eq "spool_cli: the spool call runs on one P" "recv GOMAXPROCS=1" "$(last)"
GOMAXPROCS=4 spool_cli recv --as c-999 >/dev/null
eq "spool_cli: a caller's GOMAXPROCS wins" "recv GOMAXPROCS=4" "$(last)"
spool_cli_timeout 5 claim --check >/dev/null
eq "spool_cli_timeout: the spool call runs on one P" "claim GOMAXPROCS=1" "$(last)"

# site 1: spool-send.sh's send
mkdir -p "$SPOOL_ROOT"/c-99{8,9}/{inbox,outbox,archive}
bash "$T_SCRIPTS/spool-send.sh" --from c-998 --to c-999 --kind note --body x --no-poke >/dev/null 2>&1
eq "spool-send.sh: its send runs on one P" "send GOMAXPROCS=1" "$(grep '^send ' "$CALLS" | tail -1)"

# site 2: asks.sh's claim (the function alone: the script runs its verb on load)
eval "$(sed -n '/^asks_claim() {/,/^}/p' "$T_SCRIPTS/asks.sh")"
unset ASKS_CLAIM_CMD
asks_claim --check >/dev/null
eq "asks.sh asks_claim: its claim runs on one P" "claim GOMAXPROCS=1" "$(last)"

# site 3: the peer poll's hub call, every tick
. "$T_REPO/csi-spl-orc/src/bash/run/spl-peer-poll.func.sh"
unset PEER_HUB_CMD
spl_peer_hub --check >/dev/null
eq "spl_peer_hub: its claim runs on one P" "claim GOMAXPROCS=1" "$(last)"

# never exported: a go child of this very shell sees every core
PATH="$T_TMP/bin:$PATH" go
eq "a go child of the same shell does not see GOMAXPROCS" "go GOMAXPROCS=<unset>" "$(last)"
t_done
