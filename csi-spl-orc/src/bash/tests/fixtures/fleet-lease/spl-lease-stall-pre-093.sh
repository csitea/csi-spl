# shellcheck shell=bash
# The spl_lease_stall of spl-dispatch-lease.func.sh BEFORE spec 093 T001
# (trunk 8f6064b54), renamed spl_lease_stall_pre093: the control of
# fleet-lease.tst.sh section 20 shows it returns able (prints nothing) on the
# 2026-10-05 login-expired fixture, so the fixture is the incident.
spl_lease_stall_pre093() {
  local pid="$1" text foot hit spin f st="" sat=0 now until
  text="$(spl_lease_pane_text "$pid" 2>/dev/null)" || return 0
  hit="$(spl_lease_modal_hit "$text")"
  [[ -n "$hit" ]] && { printf '%s\n' "$hit"; return 0; }
  foot="$(grep -v '^[[:space:]]*$' <<<"$text" | tail -n "${LEASE_PANE_TAIL:-12}")"
  hit="$(grep -oiE -m1 -- "${LEASE_BLOCK_RE:-$LEASE_BLOCK_RE_DEFAULT}" <<<"$foot" | sed -n 1p)"
  [[ -n "$hit" ]] && { echo "$hit"; return 0; }
  hit="$(grep -oiE -m1 -- "${LEASE_STALL_RE:-$LEASE_STALL_RE_DEFAULT}" <<<"$foot" | sed -n 1p)"
  f="$LEASE_DIR/spin.$pid"
  # the spinner's "(...)" only: its glyph and verb cycle while frozen
  spin="$(grep -oE -- '…[[:space:]]*\([0-9][^)]*\)' <<<"$foot" | tail -1 | grep -oE '\(.*\)')"
  if [[ -n "$hit" && -z "$spin" ]]; then
    rm -f "$f"; until="$(spl_lease_limit_until "$foot")"
    [[ -n "$until" ]] && echo "$hit, resets in $(( (until - $(spl_lease_now) + 59) / 60 )) min"
    return 0
  fi
  [[ -n "$hit" && -n "$spin" ]] || { rm -f "$f"; return 0; }
  now="$(spl_lease_now)"
  [[ -f "$f" ]] && IFS=$'\t' read -r sat st < "$f"
  # unchanged since <sat>: keep the first sighting's time (the able check
  # runs several times per tick, so "same as last call" is no proof)
  [[ "$st" == "$spin" && "$sat" =~ ^[0-9]+$ ]] || { printf '%s\t%s\n' "$now" "$spin" > "$f"; return 0; }
  (( now - sat >= ${LEASE_STALL_FROZEN:-45} )) && echo "$hit, turn frozen $((now - sat))s at $spin"
  return 0
}
