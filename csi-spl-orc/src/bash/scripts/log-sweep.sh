#!/usr/bin/env bash
# log-sweep.sh - the box sweep's `logs` step, run only under disk pressure
# (level low or crit): what grows on the ROOT disk outside the other steps.
# On sat, 2026-10-15, / was 88% full (3.5 of 30 GB free) and growing 1.5..3
# GB a day; /var/log/auth.log held 1.3 GB after 5 days (every `sudo -u` of the
# fleet logs three lines) and auth.log.1 another 0.7 GB, uncompressed: the
# distro's rotation is weekly, with delaycompress.
#
#   1. rotation: when a log the rsyslog logrotate config names (or its .1,
#      left uncompressed by delaycompress) is over LOG_SWEEP_MAX, the config
#      is rotated by force with logrotate's own state file, as its weekly run
#      would: the same names, the same `rotate N`, compressed. A second forced
#      round runs when a .1 is still over the limit (it compresses that one),
#      once its live log is not empty again (notifempty).
#   2. apt: `apt-get clean` (the downloaded .deb cache, re-fetched on need).
# The bytes of the rotated set and of the apt cache are measured before and
# after, and the DONE line reports the real delta.
#
#   DRY_RUN=1 (default) | 0      1: PLAN lines, nothing touched, no sudo
#   LOG_SWEEP_MAX                default 256M (a size with K/M/G)
#   LOG_SWEEP_CONF               default /etc/logrotate.d/rsyslog
#   LOG_SWEEP_STATE              logrotate's state, default its own
#   LOG_SWEEP_APT_DIR            default /var/cache/apt/archives
#   LOG_SWEEP_LOGROTATE / _APT   the commands to run (tests), default
#                                `sudo -n logrotate` / `sudo -n apt-get`
#
# Exit: 0 done; 1 a command failed; 2 usage.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
max="${LOG_SWEEP_MAX:-256M}"
conf="${LOG_SWEEP_CONF:-/etc/logrotate.d/rsyslog}"
apt_dir="${LOG_SWEEP_APT_DIR:-/var/cache/apt/archives}"
read -r -a lr <<<"${LOG_SWEEP_LOGROTATE:-sudo -n logrotate}"
read -r -a apt <<<"${LOG_SWEEP_APT:-sudo -n apt-get}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
[[ "$max" =~ ^([0-9]+)([KMG]?)$ ]] || { say "FAIL LOG_SWEEP_MAX must be a size like 256M, got '$max'"; exit 2; }
case "${BASH_REMATCH[2]}" in K) mul=1024 ;; M) mul=1048576 ;; G) mul=1073741824 ;; *) mul=1 ;; esac
max_b=$(( BASH_REMATCH[1] * mul ))

# The logs the config names (lines that start with a path), and their siblings.
logs=()
[[ -r "$conf" ]] && while read -r f; do logs+=("$f"); done < <(sed -nE 's@^[[:space:]]*(/[^[:space:]{]+).*@\1@p' "$conf")
bytes() { local n; n="$(du -scb -- "$@" 2>/dev/null | tail -1 | cut -f1)"; echo "${n:-0}"; }
set_bytes() {
  local f g=()
  for f in "${logs[@]}"; do g+=("$f"); compgen -G "$f.*" >/dev/null && g+=("$f".*); done
  if (( ${#g[@]} )); then bytes "${g[@]}"; else echo 0; fi
}
size() { stat -c %s -- "$1" 2>/dev/null || echo 0; }
# over <suffix>: the first log (or log<suffix>) over the limit, or nothing
over() { local f; for f in "${logs[@]}"; do (( $(size "$f$1") > max_b )) && { echo "$f$1"; return 0; }; done; return 1; }

log0="$(set_bytes)" apt0="$(bytes "$apt_dir")"
say "START log sweep dry_run=$dry max=$max conf=$conf logs=${#logs[@]} log_bytes=$log0 apt_bytes=$apt0"
rc=0
(( ${#logs[@]} )) || say "WARN no log is named by $conf: nothing to rotate"
for round in 1 2; do
  if (( round == 1 )); then big="$(over "")" || big="$(over .1)" || break
  else
    big="$(over .1)" || break
    # notifempty: an empty live log is not rotated, so its .1 would stay
    for _ in 1 2 3 4 5; do (( $(size "${big%.1}") > 0 )) && break; sleep 1; done
    (( $(size "${big%.1}") > 0 )) || { say "INFO ${big%.1} is empty: ${big} is compressed on a later tick"; break; }
  fi
  if [[ "$dry" == 1 ]]; then say "PLAN logrotate -f $conf (${big} is $(size "$big") bytes > $max)"; break; fi
  say "ROTATE round $round: ${big} is $(size "$big") bytes > $max"
  "${lr[@]}" ${LOG_SWEEP_STATE:+-s "$LOG_SWEEP_STATE"} -f "$conf" || { say "FAIL logrotate -f $conf rc=$?"; rc=1; break; }
done
if [[ "$dry" == 1 ]]; then say "PLAN apt-get clean ($apt0 bytes in $apt_dir)"
else "${apt[@]}" clean || { say "FAIL apt-get clean rc=$?"; rc=1; }; fi
log1="$(set_bytes)" apt1="$(bytes "$apt_dir")"
say "DONE log sweep rc=$rc log_bytes=$log0->$log1 apt_bytes=$apt0->$apt1 freed_bytes=$(( log0 - log1 + apt0 - apt1 ))"
exit "$rc"
