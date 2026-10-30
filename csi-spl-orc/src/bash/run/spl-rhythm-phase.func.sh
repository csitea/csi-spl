#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_rhythm_phase - prints `day` or `night`, the orchestrators'
# @description daily rhythm (spec 166 row B1; owner HUM-10, t1 c0b0d572 msg
# @description 421e479a: "starting from 20:00 till 07:00 CET"). The one
# @description definition every job that changes behaviour by hour reads; no
# @description job does its own hour arithmetic. Night is night_start:00 up to
# @description night_end:00 in the cnf timezone (20 to 7, Europe/Berlin: CET
# @description in winter, CEST in summer), day is the rest, seven days a week
# @description (spec 166 section 4.5). The hour is read with TZ=<zone> date,
# @description never a fixed UTC offset; a zone with no tz database file is
# @description refused, because glibc reads it as UTC with no error (TZ=CET on
# @description a box with no zoneinfo/CET, spec 166 section 0.2).
# @param RHYTHM_NOW (optional) - the moment to judge, any `date -d` form (2026-01-15T19:00Z); default now
# @param RHYTHM_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml (env.rhythm)
# @example ./run -a do_spl_rhythm_phase
# @example RHYTHM_NOW=2026-07-15T18:00Z ./run -a do_spl_rhythm_phase
#------------------------------------------------------------------------------
# Test seam: TZDIR (the tz database root, default /usr/share/zoneinfo).

do_spl_rhythm_phase() {
  local now="${RHYTHM_NOW:-now}" hour
  spl_rhythm_conf || return 1
  hour="$(spl_rhythm_hour "$now" "$SPL_RHYTHM_TZ")" || { do_log "FATAL RHYTHM_NOW is not a date: '$now'"; return 1; }
  if spl_rhythm_is_night "$((10#$hour))" "$SPL_RHYTHM_START" "$SPL_RHYTHM_END"; then echo night; else echo day; fi
}

# spl_rhythm_hour NOW TZ: the hour (00..23) of NOW in TZ.
spl_rhythm_hour() {
  TZ="$2" date -d "$1" +%H 2>/dev/null
}

# spl_rhythm_is_night HOUR START END: 0 when HOUR is in [START, END), the
# window wrapping midnight when START > END; START == END is no night.
spl_rhythm_is_night() {
  local h="$1" s="$2" e="$3"
  if ((s > e)); then ((h >= s || h < e)); else ((h >= s && h < e)); fi
}

# spl_rhythm_conf: SPL_RHYTHM_TZ / _START / _END from cnf env.rhythm; the
# spec's value when the cnf or the key is absent, a refusal when it is wrong.
spl_rhythm_conf() {
  local oa="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}" cnf k v
  oa="${oa%-orc}"; cnf="${RHYTHM_CNF:-${APP_PATH:-.}/$oa-cnf/$oa/all.env.yaml}"
  SPL_RHYTHM_TZ=Europe/Berlin SPL_RHYTHM_START=20 SPL_RHYTHM_END=7
  if [[ -f "$cnf" ]] && command -v yq >/dev/null 2>&1; then
    v="$(yq -r '.env.rhythm.timezone // ""' "$cnf" 2>/dev/null)"; [[ -n "$v" ]] && SPL_RHYTHM_TZ="$v"
    v="$(yq -r '.env.rhythm.night_start // ""' "$cnf" 2>/dev/null)"; [[ -n "$v" ]] && SPL_RHYTHM_START="$v"
    v="$(yq -r '.env.rhythm.night_end // ""' "$cnf" 2>/dev/null)"; [[ -n "$v" ]] && SPL_RHYTHM_END="$v"
  fi
  for k in start end; do
    v="SPL_RHYTHM_${k^^}"; v="${!v}"
    [[ "$v" =~ ^[0-9]{1,2}$ ]] && ((10#$v <= 23)) ||
      { do_log "FATAL cnf env.rhythm.night_$k must be an hour 0..23, got: '$v'"; return 1; }
  done
  SPL_RHYTHM_START=$((10#$SPL_RHYTHM_START)) SPL_RHYTHM_END=$((10#$SPL_RHYTHM_END))
  [[ "$SPL_RHYTHM_TZ" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ && -f "${TZDIR:-/usr/share/zoneinfo}/$SPL_RHYTHM_TZ" ]] ||
    { do_log "FATAL cnf env.rhythm.timezone '$SPL_RHYTHM_TZ' has no tz database file under ${TZDIR:-/usr/share/zoneinfo}: glibc would read it as UTC"; return 1; }
}
