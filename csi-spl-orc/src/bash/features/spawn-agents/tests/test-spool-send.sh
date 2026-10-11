#!/usr/bin/env bash
# spool-send.sh: v:1 delivery through `spool send`, unsigned, one topic per
# task_id; the tmux poke is a doorbell with checked outcomes.
set -uo pipefail

# Define eq function manually
eq() {
  local desc="$1"
  local want="$2"
  local got="$3"
  if [ "$want" -eq "$got" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (want '$want', got '$got')"
    return 1
  fi
}

# Define nok function manually
nok() {
  local desc="$1"
  echo "FAIL - $desc"
  return 1
}

# Define has function manually
has() {
  local desc="$1"
  local want="$2"
  local got="$3"
  if [[ "$got" == *"$want"* ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (missing '$want')"
    return 1
  fi
}

# Define hasnt function manually
hasnt() {
  local desc="$1"
  local want="$2"
  local got="$3"
  if [[ "$got" != *"$want"* ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (unexpected '$want')"
    return 1
  fi
}

# Define check function manually
check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    return 1
  fi
}

# Define t_done function manually
t_done() {
  echo "1..$1"
}

SPOOL_BIN="/opt/csi/csi-spl-wt/m-837/bin/spool" || { nok "cannot set SPOOL_BIN"; exit 1; }
export PATH="/opt/csi/csi-spl-wt/m-837/bin:$PATH"
T_SCRIPTS="/opt/csi/csi-spl-wt/m-837/csi-spl-orc/src/bash/features/spawn-agents/tests"
SS="$T_SCRIPTS/spool-send.sh"
sp() { SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" "$@"; }

# Set up SPOOL_ROOT manually
SPOOL_ROOT="$(mktemp -d)"
mkdir -p "$SPOOL_ROOT/c-090/inbox" "$SPOOL_ROOT/c-091/inbox" "$SPOOL_ROOT/c-092/inbox" "$SPOOL_ROOT/c-093/inbox" "$SPOOL_ROOT/c-094/inbox" "$SPOOL_ROOT/c-097/inbox"
printf 'c-091\tclaude\tpane-c-091\t/x\t20260101T000000Z\n' >> "$SPOOL_ROOT/registry.tsv"
printf 'c-090\tclaude\tpane-c-090\t/x\t20260101T000000Z\n' >> "$SPOOL_ROOT/registry.tsv"

# ---- --accept tests -----------------------------------------------------
# Valid: --accept with --kind result
out="$(SPOOL_ROOT="$SPOOL_ROOT" bash "$SS" --from c-090 --to c-091 --kind result --body 'accepted' --accept 123e4567-e89b-12d3-a456-426614174000 --no-poke)"; rc=$?
eq "--accept with --kind result: exit 0" 0 $rc
if [ "$rc" -eq 0 ]; then
  f="$(ls "$SPOOL_ROOT/c-091/inbox/"*.json 2>/dev/null | sed -n 1p)"
  obj="$(cat "$f")"
  has "--accept adds the accepts key" '"accepts":"123e4567-e89b-12d3-a456-426614174000"' "$(printf '%s' "$obj" | tr -d ' \n')"
else
  nok "--accept with --kind result: exit 0 (want '0', got '$rc')"
fi

# Invalid: --accept with --kind note
SPOOL_ROOT="$SPOOL_ROOT" bash "$SS" --from c-090 --to c-091 --kind note --body 'not a result' --accept 123e4567-e89b-12d3-a456-426614174000 >/dev/null 2>&1; rc=$?
eq "--accept with --kind note: exit 2" 2 $rc

# Invalid: --accept not a uuid
SPOOL_ROOT="$SPOOL_ROOT" bash "$SS" --from c-090 --to c-091 --kind result --body 'bad accept' --accept not-a-uuid >/dev/null 2>&1; rc=$?
eq "--accept not a uuid: exit 2" 2 $rc

# Valid --accept
SPOOL_ROOT="$SPOOL_ROOT" bash "$SS" --from c-090 --to c-091 --kind result --body x --accept "123e4567-e89b-12d3-a456-426614174000" --no-poke >/dev/null 2>&1; rc=$?
eq "valid --accept: exit 0" 0 $rc

t_done 4
