#!/usr/bin/env bash
# runner-sweep.sh - remove GitHub runner scratch that is safe to remove, under
# BOX_SWEEP_RUNNER_ROOT (default /srv/gh-runner), for idle runners only.
# An idle runner has no Runner.Worker process whose command line names its
# directory. pgrep missing, or any pgrep error, is busy: nothing is removed.
# Removed, when strictly older than BOX_SWEEP_RUNNER_AGE days (default 2):
#   <runner>/_work/_temp   every regular file under it
#   <runner>/_diag/*.log   regular files in that directory only
# Never _work/<repo>, .runner, .credentials*, a symlink, or a symlink target.
# A live run removes as the directory owner: sudo -n -u <owner> rm -f.
# If that sudo fails, the runner is skipped with a WARN and nothing is claimed.
# Only a file that is gone afterwards counts. One that remains is a WARN, and
# the step exits non-zero. Dry run unless DRY_RUN=0. Refuses a root of /.

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

# sudo_ok <user> - 0 when sudo -n can run a command as that user
sudo_ok() {
  sudo -n -u "$1" true
}

# rm_as <user> <file>... - best effort, in batches. The caller counts survivors.
rm_as() {
  local user="$1" f
  local -a batch=()
  shift
  for f in "$@"; do
    batch+=("$f")
    if (( ${#batch[@]} < 100 )); then
      continue
    fi
    sudo -n -u "$user" rm -f -- "${batch[@]}" || true
    batch=()
  done
  if (( ${#batch[@]} > 0 )); then
    sudo -n -u "$user" rm -f -- "${batch[@]}" || true
  fi
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
not_removed=0
sweep_fail=0
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
  sizes=()
  for file in "${files[@]}"; do
    sz="$(stat -c %s "$file" 2>/dev/null || printf '0')"
    sizes+=("$sz")
    bytes=$(( bytes + sz ))
  done
  if [[ "$dry" == 1 ]]; then
    say "PLAN runner $runner: rm ${count} file(s) (${bytes}B)"
    freed=$(( freed + bytes ))
    cleaned=$(( cleaned + 1 ))
    continue
  fi
  owner="$(stat -c %U "$runner" 2>/dev/null || true)"
  if [[ -z "$owner" ]] || ! sudo_ok "$owner"; then
    say "WARN runner $runner: sudo -n -u ${owner:-unknown} failed, skipped"
    not_removed=$(( not_removed + count ))
    sweep_fail=1
    continue
  fi
  rm_as "$owner" "${files[@]}"
  gone=0
  gone_bytes=0
  missed=0
  i=0
  for file in "${files[@]}"; do
    if [[ -e "$file" || -L "$file" ]]; then
      missed=$(( missed + 1 ))
    else
      gone=$(( gone + 1 ))
      gone_bytes=$(( gone_bytes + sizes[i] ))
    fi
    i=$(( i + 1 ))
  done
  if (( gone > 0 )); then
    say "DONE runner $runner: rm ${gone} file(s) (${gone_bytes}B)"
    freed=$(( freed + gone_bytes ))
    cleaned=$(( cleaned + 1 ))
  fi
  if (( missed > 0 )); then
    say "WARN runner $runner: ${missed} file(s) not removed"
    not_removed=$(( not_removed + missed ))
    sweep_fail=1
  fi
done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

if (( sweep_fail != 0 )); then
  say "FAIL runner sweep: $cleaned runner(s) cleaned, ${freed}B freed, ${not_removed} file(s) not removed"
  exit 1
fi
say "DONE runner sweep: $cleaned runner(s) cleaned, ${freed}B freed"
exit 0
