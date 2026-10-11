#!/usr/bin/env bash
# runner-sweep.sh - remove GitHub runner scratch that is safe to remove, under
# BOX_SWEEP_RUNNER_ROOT (default /srv/gh-runner), for idle runners only.
# An idle runner has no Runner.Worker process whose command line names its
# directory. pgrep missing, or any pgrep error, is busy: nothing is removed.
# Removed, when strictly older than BOX_SWEEP_RUNNER_AGE days (default 2):
#   <runner>/_work/_temp   every regular file under it
#   <runner>/_diag/*.log   regular files in that directory only
# Never _work/<repo>, .runner, .credentials*, a symlink, or a symlink target.
# Dry run unless DRY_RUN=0. Refuses a root of /.

set -uo pipefail

dry="${DRY_RUN:-1}"
root="${BOX_SWEEP_RUNNER_ROOT:-/srv/gh-runner}"
age="${BOX_SWEEP_RUNNER_AGE:-2}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# ere_escape <text> - the text as a literal for pgrep -f
ere_escape() {
  local s="$1" i c out=""
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      '.'|'*'|'['|']'|'^'|'$'|'('|')'|'+'|'?'|'{'|'}'|'|'|'\\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# is_idle <dir> - 0 only when pgrep confirms no Runner.Worker names this dir
is_idle() {
  local dir="$1" pat prc
  command -v pgrep >/dev/null 2>&1 || return 1
  pat="Runner.Worker.*$(ere_escape "$dir")"
  pgrep -f "$pat" >/dev/null 2>&1
  prc=$?
  [[ "$prc" -eq 1 ]]
}

# older <file> - 0 when the file is strictly older than $age days
older() {
  local ts now
  ts="$(stat -c %Y "$1" 2>/dev/null)" || return 1
  now="$(date +%s)"
  (( ts < now - age * 86400 ))
}

# list_old <dir> - NUL paths this sweep may remove
list_old() {
  local dir="$1" temp_dir diag_dir file base
  temp_dir="$dir/_work/_temp"
  diag_dir="$dir/_diag"
  if [[ -d "$temp_dir" && ! -L "$temp_dir" ]]; then
    while IFS= read -r -d '' file; do
      base="${file##*/}"
      case "$base" in
        .credentials*|.runner) continue ;;
      esac
      older "$file" || continue
      printf '%s\0' "$file"
    done < <(find "$temp_dir" -type f -print0 2>/dev/null)
  fi
  if [[ -d "$diag_dir" && ! -L "$diag_dir" ]]; then
    while IFS= read -r -d '' file; do
      base="${file##*/}"
      case "$base" in
        *.log) ;;
        *) continue ;;
      esac
      case "$base" in
        .credentials*|.runner) continue ;;
      esac
      older "$file" || continue
      printf '%s\0' "$file"
    done < <(find "$diag_dir" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
  fi
}

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
[[ "$age" =~ ^[0-9]+$ ]] || { say "FAIL BOX_SWEEP_RUNNER_AGE must be a whole number of days, got '$age'"; exit 2; }
[[ -n "$root" && "$root" != / ]] || { say "FAIL BOX_SWEEP_RUNNER_ROOT must be a runner directory, got '$root'"; exit 2; }

say "START runner sweep dry_run=$dry root=$root age=${age}d"

if [[ ! -d "$root" ]]; then
  say "SKIP runner root $root not found"
  exit 0
fi

freed=0
cleaned=0
while IFS= read -r -d '' runner; do
  if ! is_idle "$runner"; then
    say "INFO runner $runner: busy, skipped"
    continue
  fi
  files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(list_old "$runner")
  count="${#files[@]}"
  if (( count == 0 )); then
    say "INFO runner $runner: nothing to clean"
    continue
  fi
  bytes=0
  for file in "${files[@]}"; do
    sz="$(stat -c %s "$file")"
    bytes=$(( bytes + sz ))
  done
  if [[ "$dry" == 1 ]]; then
    say "PLAN runner $runner: rm ${count} file(s) (${bytes}B)"
  else
    for file in "${files[@]}"; do
      rm -f -- "$file"
    done
    say "DONE runner $runner: rm ${count} file(s) (${bytes}B)"
  fi
  freed=$(( freed + bytes ))
  cleaned=$(( cleaned + 1 ))
done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

say "DONE runner sweep: $cleaned runner(s) cleaned, ${freed}B freed"
exit 0
