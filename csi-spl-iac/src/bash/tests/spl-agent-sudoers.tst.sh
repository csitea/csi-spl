#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_agent_sudoers (SPL-2187), on a temp sudoers dir, no sudo:
#   1. no agent user (no SPL_AGENT_SUDO_USER, no box env) -> FATAL rc 1,
#      nothing written; a bad name, root, or the owner as agent -> FATAL
#   2. the box env file names the agent: DRY_RUN (default) prints the wanted
#      file and the diff, "would write", writes nothing
#   3. the restricted file parses (visudo -cf), runs anything as any user BUT
#      root, and as root only read-only commands, NOEXEC; no package /
#      service / shell / write command is on its root list
#   4. DRY_RUN=0 writes it 0440 with a backup of the old file; a second run
#      is a no-op ("already holds")
#   5. SPL_AGENT_SUDO_MODE=all writes NOPASSWD:ALL back (the revert)
#   6. CONTROL: a visudo that rejects the config -> rc 1 and the old file is
#      restored, byte for byte
# The live check (real sudo, an agent refused apt-get / systemctl / tee
# /etc, still allowed sudo -u <owner>): spl-agent-sudoers-live.tst.sh.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$RUN/spl-agent-sudoers.func.sh"
VISUDO=""
for v in "$(command -v visudo)" /usr/sbin/visudo /sbin/visudo; do [[ -n "$v" && -x "$v" ]] && { VISUDO="$v"; break; }; done
[[ -n "$VISUDO" ]] || { echo "SKIP: no visudo (apt package sudo)"; exit 0; }

mkdir -p "$T/d" "$T/bin"
printf 'OWNER_USER=box-owner\nAGENT_USER=box-agent\n' >"$T/box.env"
OLD='box-agent ALL=(ALL) NOPASSWD:ALL'
F="$T/d/90-box-agent-nopasswd"

# act [VAR=value ...] -> rc; output in $T/out
act() {
  env -u DRY_RUN -u SPL_AGENT_SUDO_USER -u SPL_AGENT_SUDO_OWNER -u SPL_AGENT_SUDO_MODE \
    PROJ_PATH="$PROJ_ROOT" SPL_AGENT_SUDOERS_DIR="$T/d" SPL_AGENT_SUDO_BACKUP_DIR="$T/bak" \
    SPL_AGENT_SUDO_BOX_ENV="$T/box.env" SPL_AGENT_SUDO_AS_SELF=1 SPL_AGENT_SUDO_PROBE=0 \
    SPL_AGENT_SUDO_CHECK_FILE=1 SPL_AGENT_SUDO_VISUDO="$VISUDO" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-agent-sudoers.func.sh"
    do_spl_agent_sudoers' >"$T/out" 2>&1
}
reset() { rm -rf "$T/d" "$T/bak"; mkdir -p "$T/d"; printf '%s\n' "$OLD" >"$F"; chmod 0440 "$F"; }

# 1. no agent user, bad names
reset
act SPL_AGENT_SUDO_BOX_ENV="$T/none.env"; rc=$?
[[ $rc == 1 ]] && grep -q 'FATAL no agent user' "$T/out" && [[ "$(cat "$F")" == "$OLD" ]] &&
  pass "1. no agent user: FATAL rc 1, nothing written" || fail "1. no agent user: rc=$rc $(cat "$T/out")"
act SPL_AGENT_SUDO_USER='x;y'; [[ $? == 1 ]] && pass "1. a bad user name: FATAL" || fail "1. bad name: $(cat "$T/out")"
act SPL_AGENT_SUDO_USER=root; [[ $? == 1 ]] && pass "1. root as the agent: FATAL" || fail "1. root: $(cat "$T/out")"
act SPL_AGENT_SUDO_USER=box-owner; [[ $? == 1 ]] && pass "1. the owner as the agent: FATAL" || fail "1. owner: $(cat "$T/out")"

# 2. DRY_RUN default: prints, writes nothing
reset
act; rc=$?
[[ $rc == 0 ]] && grep -q 'OK DRY_RUN would write' "$T/out" && grep -q '^< box-agent ALL=(ALL) NOPASSWD:ALL' "$T/out" &&
  [[ "$(cat "$F")" == "$OLD" ]] && [[ ! -d "$T/bak" ]] &&
  pass "2. DRY_RUN: wanted file + diff printed, nothing written" || fail "2. DRY_RUN: rc=$rc $(cat "$T/out")"

# 3. the restricted file
act DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && "$VISUDO" -cf "$F" >/dev/null 2>&1 && pass "3. the written file parses (visudo -cf)" || fail "3. parse: rc=$rc $(cat "$T/out")"
grep -qx 'box-agent ALL=(ALL,!root) NOPASSWD: ALL' "$F" && pass "3. any user but root: (ALL,!root)" || fail "3. no (ALL,!root) line: $(cat "$F")"
grep -qx 'box-agent ALL=(root) NOPASSWD:NOEXEC: SPL_AGENT_ROOT_RO, !SPL_AGENT_ROOT_WRITE' "$F" &&
  pass "3. root: the read-only alias only, NOEXEC" || fail "3. root line: $(cat "$F")"
grep -q 'NOPASSWD: *ALL$' <(grep -v '(ALL,!root)' "$F") && fail "3. a NOPASSWD:ALL for root is left: $(cat "$F")" ||
  pass "3. no NOPASSWD:ALL as root"
ro="$(sed -n '/^Cmnd_Alias SPL_AGENT_ROOT_RO/,/^[^ ]/p' "$F" | grep -oE '/[a-z/._-]+' | sort -u)"
bad="$(grep -xE '.*/(apt|apt-get|aptitude|dpkg|snap|systemctl|service|tee|cp|mv|install|ln|rm|chmod|chown|setfacl|sed|perl|dd|bash|sh|dash|python3|su|sudoedit|env|crontab|docker|vi|vim|nano|less|more|mount)$' <<<"$ro")"
[[ -n "$ro" && -z "$bad" ]] && pass "3. the root list has no package, service, write, shell or editor command ($(wc -l <<<"$ro") commands)" ||
  fail "3. the root list carries: ${bad:-nothing parsed}"

# 4. backup, mode, idempotent
b=("$T"/bak/90-box-agent-nopasswd.*)
[[ -f "${b[0]}" && "$(cat "${b[0]}")" == "$OLD" ]] && pass "4. the old file is backed up" || fail "4. no backup: ${b[*]}"
[[ "$(stat -c %a "$F")" == 440 ]] && pass "4. written 0440" || fail "4. mode $(stat -c %a "$F")"
act DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && grep -q 'already holds mode restricted' "$T/out" && pass "4. a second run is a no-op" || fail "4. rerun: rc=$rc $(cat "$T/out")"

# 5. the revert
act DRY_RUN=0 SPL_AGENT_SUDO_MODE=all; rc=$?
[[ $rc == 0 ]] && grep -qx 'box-agent ALL=(ALL) NOPASSWD:ALL' "$F" && ! grep -q 'NOEXEC' "$F" &&
  pass "5. mode all writes NOPASSWD:ALL back" || fail "5. revert: rc=$rc $(cat "$F")"

# 6. CONTROL: the config check fails -> restored
reset
printf '#!/bin/sh\ncase "$*" in *-cf*) exec %s "$@";; esac\necho "parse error" >&2; exit 1\n' "$VISUDO" >"$T/bin/visudo-bad"
chmod +x "$T/bin/visudo-bad"
act DRY_RUN=0 SPL_AGENT_SUDO_VISUDO="$T/bin/visudo-bad" SPL_AGENT_SUDO_CHECK_FILE=; rc=$?
[[ $rc == 1 ]] && grep -q 'restored the previous' "$T/out" && [[ "$(cat "$F")" == "$OLD" ]] &&
  pass "6. control: a config that does not parse is rolled back (rc 1, old file byte for byte)" ||
  fail "6. control: rc=$rc file=$(cat "$F") $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
