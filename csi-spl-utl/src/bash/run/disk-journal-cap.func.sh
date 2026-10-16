#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Install the systemd journald size cap drop-in
# @description <root>/etc/systemd/journald.conf.d/60-disk-hygiene.conf
# @description ([Journal] SystemMaxUse=500M, SystemMaxFileSize=100M), so journald
# @description holds the journal bounded between box sweeps. Disk hygiene round
# @description row 02, feat(hyg-02-journald-caps), SPL-2234 (Refs: SPL-2111).
# @description Dry run unless DRY_RUN=0: prints the file it would write and its
# @description diff against the file on the box. A real apply on the root /
# @description writes the file and restarts systemd-journald through `sudo -n`
# @description (journald has no reload: CanReload=no, and systemd-journald(8)
# @description calls a restart safe); under any other root it only writes the
# @description file. It never vacuums: journal-sweep.sh (csi-spl-orc) does
# @description that in every box sweep. JOURNAL_CAP_OP=check validates the
# @description installed drop-in (exit 1 on a bad or missing value) and prints
# @description `systemd-analyze cat-config systemd/journald.conf`.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param JOURNAL_CAP_OP (optional) - apply (default) or check
# @param JOURNAL_CAP_ROOT (optional) - the root the /etc path lives under, default /
# @param JOURNAL_CAP_MAX_USE (optional) - SystemMaxUse, default 500M
# @param JOURNAL_CAP_MAX_FILE (optional) - SystemMaxFileSize, default 100M
# @example ./run -a do_disk_journal_cap
# @example JOURNAL_CAP_OP=check ./run -a do_disk_journal_cap
# @example DRY_RUN=0 ./run -a do_disk_journal_cap
#------------------------------------------------------------------------------

# journal_cap_size_ok <value> - a journald.conf(5) size: bytes, or a number
# with one of the units K, M, G, T, P, E.
journal_cap_size_ok() {
  [[ "$1" =~ ^[0-9]+[KMGTPE]?$ ]]
}

# journal_cap_render <max_use> <max_file> - the drop-in's content.
journal_cap_render() {
  printf '%s\n' \
    '# Disk hygiene round row 02 (SPL-2234): journald size cap.' \
    '# Written by csi-spl-utl do_disk_journal_cap; edit there, not here.' \
    '[Journal]' \
    "SystemMaxUse=$1" \
    "SystemMaxFileSize=$2"
}

# journal_cap_check_file <file> <max_use> <max_file> - validate a drop-in:
# both keys set under [Journal] to valid sizes equal to the wanted ones.
# Prints one FAIL line per problem; returns 1 on any.
journal_cap_check_file() {
  local file=$1 want_use=$2 want_file=$3 bad=0 key want got
  [[ -r "$file" ]] || { echo "FAIL $file: missing or unreadable"; return 1; }
  for key in SystemMaxUse SystemMaxFileSize; do
    want=$want_use
    [[ "$key" == SystemMaxFileSize ]] && want=$want_file
    got="$(awk -v k="$key" '
      /^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
      sec == "[Journal]" && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
        v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); last = v; seen = 1
      }
      END { if (seen) print last; else print "<unset>" }
    ' "$file")"
    if [[ "$got" == "<unset>" ]]; then
      echo "FAIL $file: $key not set under [Journal]"; bad=1
    elif ! journal_cap_size_ok "$got"; then
      echo "FAIL $file: $key=$got is not a size (bytes or K M G T P E)"; bad=1
    elif [[ "$got" != "$want" ]]; then
      echo "FAIL $file: $key=$got, want $want"; bad=1
    else
      echo "OK $file: $key=$got"
    fi
  done
  return "$bad"
}

do_disk_journal_cap() {
  local dry="${DRY_RUN:-1}" op="${JOURNAL_CAP_OP:-apply}"
  local root="${JOURNAL_CAP_ROOT:-/}"
  local max_use="${JOURNAL_CAP_MAX_USE:-500M}" max_file="${JOURNAL_CAP_MAX_FILE:-100M}"
  local dir file new rc
  root="${root%/}"
  dir="$root/etc/systemd/journald.conf.d"
  file="$dir/60-disk-hygiene.conf"

  [[ "$dry" == 0 || "$dry" == 1 ]] || { echo "FAIL DRY_RUN must be 0 or 1, got '$dry'"; return 2; }
  journal_cap_size_ok "$max_use" || { echo "FAIL JOURNAL_CAP_MAX_USE must be a size like 500M, got '$max_use'"; return 2; }
  journal_cap_size_ok "$max_file" || { echo "FAIL JOURNAL_CAP_MAX_FILE must be a size like 100M, got '$max_file'"; return 2; }

  if [[ "$op" == check ]]; then
    journal_cap_check_file "$file" "$max_use" "$max_file"; rc=$?
    if command -v systemd-analyze >/dev/null 2>&1; then
      echo "--- systemd-analyze cat-config systemd/journald.conf (root ${root:-/})"
      if [[ -z "$root" ]]; then
        systemd-analyze cat-config systemd/journald.conf 2>&1
      else
        systemd-analyze cat-config --root="$root" systemd/journald.conf 2>&1
      fi
    fi
    [[ -z "$root" ]] && command -v journalctl >/dev/null 2>&1 && journalctl --disk-usage 2>&1 | grep -v -E '^(Hint|  )'
    [[ "$rc" == 0 ]] && echo "PASS drop-in $file caps the journal" || echo "FAIL drop-in $file does not cap the journal"
    return "$rc"
  fi
  [[ "$op" == apply ]] || { echo "FAIL JOURNAL_CAP_OP must be apply or check, got '$op'"; return 2; }

  new="$(mktemp)"
  journal_cap_render "$max_use" "$max_file" > "$new"
  journal_cap_check_file "$new" "$max_use" "$max_file" >/dev/null || { echo "FAIL rendered drop-in does not validate"; rm -f "$new"; return 1; }

  echo "FILE $file"
  cat "$new"
  echo "--- diff against the box"
  if [[ -f "$file" ]] && cmp -s "$file" "$new"; then
    echo "OK $file is already current, nothing to write"
    rm -f "$new"
    return 0
  fi
  if [[ -f "$file" ]]; then
    diff -u --label "$file (box)" --label "$file (new)" "$file" "$new"
  else
    diff -u --label "$file (absent)" --label "$file (new)" /dev/null "$new"
  fi

  if [[ "$dry" == 1 ]]; then
    echo "PLAN would write $file"
    [[ -z "$root" ]] && echo "PLAN would restart systemd-journald (sudo -n systemctl restart systemd-journald)"
    echo "DRY_RUN=1: nothing written; DRY_RUN=0 applies"
    rm -f "$new"
    return 0
  fi

  if [[ -z "$root" ]]; then
    sudo -n install -D -m 0644 "$new" "$file" || { echo "FAIL could not write $file (needs root: sudo -n)"; rm -f "$new"; return 1; }
    echo "WROTE $file"
    sudo -n systemctl restart systemd-journald || { echo "FAIL could not restart systemd-journald"; rm -f "$new"; return 1; }
    echo "RESTARTED systemd-journald"
  else
    install -D -m 0644 "$new" "$file" || { echo "FAIL could not write $file"; rm -f "$new"; return 1; }
    echo "WROTE $file"
    echo "SKIP restart: root is $root, not /"
  fi
  rm -f "$new"
  JOURNAL_CAP_OP=check do_disk_journal_cap
}
