#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_log and the action dispatcher in iac and orc run.sh do not fork
#          once per log line or once per action name (perf edition E18, C1's
#          practice). A log line used to be 3x echo|cut, 2x date and a mkdir.
#   Checks, for each run.sh:
#   1. full log lines at RUN_LOG_EPOCH are the same bytes as the old
#      echo|cut|date formatter (the date comes from that epoch)
#   2. compact stdout is still LEVEL msg, with DEBUG and framework banners
#      dropped
#   3. eight do_log calls fork cut 0, date 0, mkdir 1
#   4. ./run -a do_no_such_action forks cut 0, tr 0, sed 0, awk 0, date 1
#      (the one date is main's run stamp, not a log line)
#   5. action names still split and normalise, a missing action still exits 1,
#      and @arg flags still map to env vars with no awk
#   Control: planted once, the pre-change run.sh is red. 8 do_log calls
#   were cut=24 date=16 mkdir=8; ./run was cut=18 date=13 tr=1 sed=1;
#   three @arg lines were awk=6. Behaviour checks stayed green.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
EPOCH=1600000000

extract() {
  local src="$1" name="$2" dest="$3"
  awk -v fn="$name" '
    $0 ~ "^" fn "\\(\\) \\{" { p=1 }
    p { print }
    p && $0 ~ "^}" { exit }
  ' "$src" >"$dest"
  grep -q "^${name}() {" "$dest"
}

count_of() {
  local calls="$1" tool="$2" n
  n=$(grep -c "^${tool}$" "$calls" || true)
  printf '%s' "$n"
}

# Run argv under a PATH that records each date/cut/mkdir/dirname/tr/sed/awk.
# The caller's stdout/stderr are unchanged. Prints nothing. The count file
# is the first argument.
with_shim() {
  local calls="$1"
  shift
  local d c real
  d=$(mktemp -d)
  : >"$calls"
  for c in date cut mkdir dirname tr sed awk; do
    real=$(PATH=/usr/bin:/bin command -v "$c") || continue
    cat >"$d/$c" <<EOF
#!/bin/sh
printf '%s\n' '$c' >>'$calls'
exec '$real' "\$@"
EOF
    chmod +x "$d/$c"
  done
  PATH="$d:/usr/bin:/bin" "$@"
  local rc=$?
  rm -rf "$d"
  return "$rc"
}

for mod in orc iac; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  [[ -f "$src" ]] || { fail "$mod run.sh exists" "$src"; continue; }
  lib="$T/$mod-log.inc.sh"
  extract "$src" do_log "$lib" || { fail "$mod: extract do_log" "$src"; continue; }

  # 1. Byte-compare the visible line against the old formatter.
  bash -c '
    set -u
    source "$1"
    epoch="$2"
    dir="$3"
    export RUN_LOG_EPOCH="$epoch" RUN_LOG_COMPACT=0 PROJ=p HOST_NAME=h
    export LOG_DIR="$dir/full"
    mkdir -p "$LOG_DIR"
    unset _do_log_dir_ready
    fail=0
    while IFS= read -r m || [[ -n "$m" ]]; do
      [[ -z "$m" ]] && continue
      do_log "$m" >"$dir/one.out"
      # shellcheck disable=SC2086,SC2048 # the old formatter, kept as the oracle
      type_of_msg=$(echo $m | cut -d" " -f1)
      # shellcheck disable=SC2086,SC2048
      action=$(echo $m | cut -d" " -f2)
      # shellcheck disable=SC2086,SC2048
      rest_of_msg=$(echo $m | cut -d" " -f3-)
      display_type="${type_of_msg/WARNING/WARN}"
      type_padded=$(printf "%-7s" "[$display_type]")
      ts=$(date -d "@$epoch" "+%Y-%m-%d %H:%M:%S %Z")
      if [[ "$action" == "START" || "$action" == "STOP" ]]; then
        formatted_action=$(printf "%-5s" "$action")
        exp=" $type_padded $ts [p][@h] [$$] $formatted_action $rest_of_msg"
      else
        exp=" $type_padded $ts [p][@h] [$$] $action $rest_of_msg"
      fi
      grep -F -q "$exp" "$dir/one.out" || { echo "DIFF [$m]"; echo "EXP $exp"; echo "GOT $(cat "$dir/one.out")"; fail=1; }
    done <<'"'"'MSGS'"'"'
DEBUG
INFO OK
INFO OK run.sh'"'"'s run completed
INFO STOP  ::: running function  :: do_x
INFO START ::: running action    :: do_x
FATAL the run failed !
WARNING a warning
ERROR Action failed with status 1
FATAL action(s) requested: "do_no_such_action" NOT found !!!
OK Resource imported successfully: a -> b
MSGS
    day=$(date -d "@$epoch" "+%Y%m%d")
    [[ -f "$LOG_DIR/p.$day.log" ]] || { echo "DAYFILE missing p.$day.log"; fail=1; }
    exit "$fail"
  ' _ "$lib" "$EPOCH" "$T/$mod" && pass "$mod: full lines match the old formatter at a fixed epoch" \
    || fail "$mod: full lines" "see DIFF above"

  # 2. Compact bodies.
  out=$(env RUN_LOG_COMPACT=1 RUN_LOG_EPOCH="$EPOCH" LOG_DIR="$T/$mod/compact" PROJ=p HOST_NAME=h \
    bash -c '
      source "$1"
      unset _do_log_dir_ready
      do_log "OK Resource imported successfully: a -> b"
      do_log "DEBUG a debug line"
      do_log "INFO START ::: running action :: do_x"
      do_log "INFO OK run.sh'"'"'s run completed"
      do_log "FATAL it broke"
    ' _ "$lib")
  want=$'OK Resource imported successfully: a -> b\nFATAL it broke'
  [[ "$out" == "$want" ]] && pass "$mod: compact LEVEL msg, DEBUG and banners dropped" \
    || fail "$mod: compact" "$(cat -v <<<"$out")"

  # 3. Fork budget on the function itself.
  calls="$T/$mod-log.calls"
  with_shim "$calls" env RUN_LOG_COMPACT=1 RUN_LOG_EPOCH="$EPOCH" LOG_DIR="$T/$mod/shim" PROJ=p \
    bash -c '
      source "$1"
      unset _do_log_dir_ready
      i=0
      while [[ "$i" -lt 8 ]]; do
        do_log "INFO line $i of the budget"
        i=$((i + 1))
      done
    ' _ "$lib" >/dev/null
  c_cut=$(count_of "$calls" cut)
  c_date=$(count_of "$calls" date)
  c_mkdir=$(count_of "$calls" mkdir)
  [[ "$c_cut" == 0 && "$c_date" == 0 && "$c_mkdir" == 1 ]] \
    && pass "$mod: 8 do_log calls fork cut 0, date 0, mkdir 1" \
    || fail "$mod: do_log forks" "cut=$c_cut date=$c_date mkdir=$c_mkdir"

  # 4. The whole ./run, not-found path. date 1 is main'\''s stamp.
  calls="$T/$mod-run.calls"
  with_shim "$calls" "$REPO_ROOT/csi-spl-$mod/run" -a do_no_such_action >/dev/null 2>&1
  rc=$?
  c_cut=$(count_of "$calls" cut)
  c_date=$(count_of "$calls" date)
  c_tr=$(count_of "$calls" tr)
  c_sed=$(count_of "$calls" sed)
  c_awk=$(count_of "$calls" awk)
  [[ "$rc" -eq 1 && "$c_cut" == 0 && "$c_date" == 1 && "$c_tr" == 0 && "$c_sed" == 0 && "$c_awk" == 0 ]] \
    && pass "$mod: ./run -a do_no_such_action cut 0, tr 0, sed 0, awk 0, date 1, rc 1" \
    || fail "$mod: ./run forks" "rc=$rc cut=$c_cut date=$c_date tr=$c_tr sed=$c_sed awk=$c_awk"

  # 5. Dispatcher and @arg, no awk/sed/tr.
  disp="$T/$mod-disp.inc.sh"
  argsrc="$T/$mod-args.inc.sh"
  extract "$src" do_run_actions "$disp" || { fail "$mod: extract do_run_actions"; continue; }
  extract "$src" execute_step "$argsrc" || { fail "$mod: extract execute_step"; continue; }

  out=$(bash -c '
    set -u
    source "$1"
    do_log() { :; }
    execute_step() { printf "%s\n" "$1"; return 0; }
    declare -gA _func_to_file
    _func_to_file[do_alpha_beta]=x
    _func_to_file[do_beta_gamma]=y
    PROJ_PATH="$2"
    do_run_actions " alpha-beta   do_beta_gamma "
  ' _ "$disp" "$T")
  want=$'do_alpha_beta\ndo_beta_gamma'
  [[ "$out" == "$want" ]] && pass "$mod: action names split and normalise, empty fields dropped" \
    || fail "$mod: dispatch" "$(cat -v <<<"$out")"

  nf=$(bash -c '
    set -u
    source "$1"
    do_log() { printf "%s\n" "$*"; }
    declare -gA _func_to_file
    PROJ_PATH="$2"
    do_run_actions "nope"
  ' _ "$disp" "$T")
  nfrc=$?
  [[ "$nfrc" -eq 1 && "$nf" == *'NOT found'* ]] && pass "$mod: a missing action exits 1" \
    || fail "$mod: missing action" "rc=$nfrc out=$nf"

  calls="$T/$mod-arg.calls"
  out=$(with_shim "$calls" bash -c '
    set -u
    source "$1"
    do_log() { :; }
    do_parse_metadata() { printf "%s\n" "arg=--name NAME_VAR" "arg=--flag FLAG_VAR" "arg=--with   WITH_VAR extra"; }
    do_alpha() { printf "NAME=[%s] FLAG=[%s] WITH=[%s]\n" "${NAME_VAR:-}" "${FLAG_VAR:-}" "${WITH_VAR:-}"; }
    declare -gA _func_to_file
    _func_to_file[do_alpha]=x
    execute_step do_alpha --name zee --flag --with yy
  ' _ "$argsrc")
  c_awk=$(count_of "$calls" awk)
  [[ "$out" == "NAME=[zee] FLAG=[true] WITH=[yy]" && "$c_awk" == 0 ]] \
    && pass "$mod: @arg flags map with no awk" \
    || fail "$mod: @arg" "awk=$c_awk out=$out"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"
exit 1
