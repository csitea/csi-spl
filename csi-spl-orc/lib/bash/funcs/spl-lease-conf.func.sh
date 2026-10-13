#!/bin/bash
#------------------------------------------------------------------------------
# The ONE writer of <spool root>/dispatch/lease.conf (SPL-1713). Every action
# that changes the file goes through spl_lease_conf_write, so each rewrite
#   - keeps every KEY=value line the caller did not name (a writer that knows
#     three keys can never drop LEASE_FLEET, LEASE_ENV, ASKS_OWNER, ...),
#   - leaves a byte-identical backup <conf>.bak-<UTC>[-<tag>] first.
# On 2026-10-13 lease.conf was cut to its three LEASE_MASTER / FAILOVER / ORCH
# lines with no backup, and the next LEASE_CMD=ensure left fleet mode.
# Test: csi-spl-orc/src/bash/tests/lease-conf-write.tst.sh.
#------------------------------------------------------------------------------

# spl_lease_conf_write <conf> [tag] < new text: KEY=value lines, the keys to
# set. The current file's keys keep their order and take the new values; keys
# only in the new text follow; keys only in the current file are KEPT. Writes
# in place (cat >, not mv), so the owner, mode and ACL stay for every reader.
# Prints "BACKUP <path>" when it rewrote a file, nothing when the file already
# reads so. Non-zero = nothing written: an empty text, a line that is no
# KEY=value, or the backup or the write failed.
spl_lease_conf_write() {
  local conf="$1" tag="${2:-}" new merged bak
  [[ -n "$conf" ]] || { echo "spl_lease_conf_write: no lease.conf path" >&2; return 1; }
  new="$(grep -v '^[[:space:]]*$')"
  [[ -n "$new" ]] || { echo "spl_lease_conf_write: refused: an empty text for $conf" >&2; return 1; }
  grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=' <<<"$new" &&
    { echo "spl_lease_conf_write: refused: a line that is no KEY=value for $conf" >&2; return 1; }
  if [[ ! -f "$conf" ]]; then
    printf '%s\n' "$new" >"$conf" || { echo "spl_lease_conf_write: cannot write $conf" >&2; return 1; }
    return 0
  fi
  merged="$(printf '%s\n' "$new" | spl_lease_conf_merge "$conf")" || return 1
  [[ "$merged" == "$(cat "$conf")" ]] && return 0
  bak="$conf.bak-$(date -u +%Y%m%dT%H%M%SZ)${tag:+-$tag}"
  [[ -e "$bak" ]] && bak="$bak-$$"
  cp -p "$conf" "$bak" || { echo "spl_lease_conf_write: cannot back up $conf to $bak; nothing written" >&2; return 1; }
  printf '%s\n' "$merged" >"$conf" || { echo "spl_lease_conf_write: cannot write $conf; the old file is $bak" >&2; return 1; }
  echo "BACKUP $bak"
}

# spl_lease_conf_merge <conf> < new text: prints what spl_lease_conf_write
# would leave in <conf> (the same rule), touching nothing.
spl_lease_conf_merge() {
  [[ -f "$1" ]] || { grep -v '^[[:space:]]*$'; return 0; }
  awk 'FNR == NR { if ($0 ~ /^[[:space:]]*$/) next; k = $0; sub(/=.*/, "", k); if (!(k in nv)) { nv[k] = $0; order[++n] = k }; next }
    { k = $0; sub(/=.*/, "", k)
      if (k in nv) { if (!(k in done)) { print nv[k]; done[k] = 1 } } else print }
    END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print nv[order[i]] }' - "$1"
}

# spl_lease_conf_set <conf> <tag> KEY=value...: spl_lease_conf_write for a
# few keys given as arguments.
spl_lease_conf_set() {
  local conf="$1" tag="$2"; shift 2
  printf '%s\n' "$@" | spl_lease_conf_write "$conf" "$tag"
}

# spl_lease_conf_flip <conf> <tag> KEY OLD NEW: KEY=OLD -> KEY=NEW through
# spl_lease_conf_write. Already KEY=NEW: nothing to do. Non-zero, nothing
# written, when the file has no KEY=OLD or KEY=NEW line.
spl_lease_conf_flip() {
  local conf="$1" tag="$2" key="$3" old="$4" new="$5"
  grep -qx "$key=$new" "$conf" 2>/dev/null && return 0
  grep -qx "$key=$old" "$conf" 2>/dev/null ||
    { echo "spl_lease_conf_flip: $conf has no $key=$old line; nothing written" >&2; return 1; }
  spl_lease_conf_set "$conf" "$tag" "$key=$new" >/dev/null && grep -qx "$key=$new" "$conf"
}
