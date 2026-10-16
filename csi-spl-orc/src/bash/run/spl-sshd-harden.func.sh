#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1960 (security round 1, row 2): this box's sshd takes keys
# @description only. One drop-in <SSHD_CONF_D>/05-spl-sshd-harden.conf, the
# @description settings the satellite box already has (sshd -T there):
# @description   PasswordAuthentication no, KbdInteractiveAuthentication no,
# @description   PermitRootLogin no, PubkeyAuthentication yes
# @description sshd keeps the FIRST value it reads, and the Include of the
# @description drop-ins comes before the main file's own lines, so 05- wins
# @description over the main file and every later drop-in. A Match block can
# @description still turn passwords on for some users: the check runs sshd -T
# @description globally AND per user (-C), and names every Match line that
# @description sets a password or root login back on.
# @description Before it writes, it lists who keeps key login (a login shell
# @description and >= 1 authorized key; root never) and who loses ssh; it
# @description refuses when no non-root user would keep key login.
# @description Apply order: write, sshd -t, sshd -T checks, and only then the
# @description reload; a failed step removes the file again, sshd keeps its
# @description old config. Open sessions stay. Idempotent. Dry run unless
# @description DRY_RUN=0. Users are named (that is the point of the list),
# @description keys are counted, never printed.
# @param SSHD_CONF (optional) - the main file, default /etc/ssh/sshd_config
# @param SSHD_CONF_D (optional) - the drop-in dir, default <dir of SSHD_CONF>/sshd_config.d
# @param SSHD_BIN (optional) - default sshd
# @param SSHD_ARGS (optional, tests) - extra sshd args, e.g. "-h <host key>"
# @param SSHD_RELOAD_CMD (optional) - default "systemctl reload ssh"
# @param SSHD_PASSWD_FILE (optional, tests) - a passwd file, default getent passwd
# @param SSHD_SUDO (optional) - the privilege prefix, default "sudo -n" ("" as root)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_sshd_harden
# @example DRY_RUN=0 ./run -a do_spl_sshd_harden
#------------------------------------------------------------------------------
do_spl_sshd_harden() {
  local conf="${SSHD_CONF:-/etc/ssh/sshd_config}"
  local d="${SSHD_CONF_D:-$(dirname "$conf")/sshd_config.d}" reload="${SSHD_RELOAD_CMD:-systemctl reload ssh}"
  local dry=1 f new now keep bad
  local -a su=()
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if [[ -n "${SSHD_SUDO+x}" ]]; then read -ra su <<<"$SSHD_SUDO"; elif (( EUID != 0 )); then su=(sudo -n); fi
  f="$d/05-spl-sshd-harden.conf"
  new="$(spl_sshd_harden_body)"
  "${su[@]}" test -f "$conf" || { do_log "FATAL no sshd config at $conf"; return 1; }

  now="$(spl_sshd_eff "" | tr '\n' ' ')"
  do_log "INFO sshd now: ${now% }"
  keep="$(spl_sshd_key_users)" || return 1
  printf '%s\n' "$keep"
  grep -q '^key login kept: ' <<<"$keep" || { do_log "FATAL no non-root user keeps key login after the fix: refused (nobody could ssh in)"; return 1; }

  if [[ "$("${su[@]}" cat "$f" 2>/dev/null)" == "$new" ]]; then
    bad="$(spl_sshd_check "$f" "$keep")" && { do_log "OK $f is already in place and in force: unchanged"; return 0; }
    printf '%s\n' "$bad"; do_log "FAIL $f is in place but passwords or root login are still on"; return 1
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would write $f:"
    printf '  %s\n' "${new//$'\n'/$'\n'  }"
    bad="$(spl_sshd_scan_match "$f")"
    [[ -n "$bad" ]] && { printf '%s\n' "$bad"; do_log "WARN a Match block above turns passwords or root login back on: fix it first, the apply would refuse"; }
    do_log "INFO DRY_RUN then: ${SSHD_BIN:-sshd} -t, the sshd -T checks (global + per user above), then $reload"
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to apply."
    return 0
  fi
  "${su[@]}" mkdir -p "$d" || { do_log "FATAL cannot make $d"; return 1; }
  printf '%s\n' "$new" | "${su[@]}" tee "$f" >/dev/null || { do_log "FATAL cannot write $f"; return 1; }
  if ! spl_sshd_run -t; then
    "${su[@]}" rm -f "$f"; do_log "FATAL sshd -t refused the new $f: removed again, sshd keeps its old config"; return 1
  fi
  if ! bad="$(spl_sshd_check "$f" "$keep")"; then
    printf '%s\n' "$bad"; "${su[@]}" rm -f "$f"
    do_log "FATAL with $f passwords or root login are still on: removed again, sshd not reloaded"; return 1
  fi
  # shellcheck disable=SC2086 # the reload command is a command line
  "${su[@]}" $reload || { do_log "FATAL '$reload' failed: $f is written, sshd not reloaded"; return 1; }
  now="$(spl_sshd_eff "" | tr '\n' ' ')"
  do_log "OK $f installed and sshd reloaded: ${now% } (new sessions; open ones stay)"
}

# spl_sshd_harden_body -> the drop-in, the same four lines as the satellite box.
spl_sshd_harden_body() {
  printf '%s\n' "# written by do_spl_sshd_harden (SPL-1960): keys only, no root login; do not edit" \
    "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin no" "PubkeyAuthentication yes"
}

# spl_sshd_run <sshd args>... - sshd on SSHD_CONF with SSHD_ARGS, under the prefix.
spl_sshd_run() {
  local -a extra=()
  read -ra extra <<<"${SSHD_ARGS:-}"
  "${su[@]}" "${SSHD_BIN:-sshd}" -f "$conf" "${extra[@]}" "$@"
}

# spl_sshd_eff <-C spec or ""> -> the four effective settings, one "key=value" per line.
spl_sshd_eff() {
  local -a c=()
  [[ -n "$1" ]] && c=(-C "$1")
  spl_sshd_run -T "${c[@]}" 2>/dev/null |
    awk '$1 ~ /^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication)$/ {print $1 "=" $2}' | sort
}

# spl_sshd_key_users -> "key login kept: user=<u> keys=<n>", "login refused
# after: root (keys=<n>)" and "no key: user=<u> (no ssh after the fix)", one
# per user with a login shell. Keys counted, never printed.
spl_sshd_key_users() {
  local akf u home shell n c f out=""
  akf="$(spl_sshd_run -T 2>/dev/null | sed -n 's/^authorizedkeysfile //p')"
  [[ -n "$akf" ]] || akf=".ssh/authorized_keys .ssh/authorized_keys2"
  while IFS=: read -r u _ _ _ _ home shell; do
    [[ -z "$shell" || "$shell" =~ (nologin|false|sync|shutdown|halt)$ ]] && continue
    n=0
    for f in $akf; do
      f="${f//%h/$home}"; f="${f//%u/$u}"; [[ "$f" == /* ]] || f="$home/$f"
      c="$("${su[@]}" grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null)"
      n=$(( n + ${c:-0} ))
    done
    if [[ "$u" == root ]]; then out+="login refused after: root (keys=$n)"$'\n'
    elif (( n > 0 )); then out+="key login kept: user=$u keys=$n"$'\n'
    else out+="no key: user=$u (no ssh after the fix)"$'\n'; fi
  done < <(if [[ -n "${SSHD_PASSWD_FILE:-}" ]]; then cat "$SSHD_PASSWD_FILE"; else getent passwd; fi)
  printf '%s' "$out"
}

# spl_sshd_scan_match <our file> -> "match-reenable <file>:<line>: <text>" per
# line inside a Match block (main file or any drop-in) that sets passwords,
# keyboard-interactive, empty passwords or root login back on.
spl_sshd_scan_match() {
  local ours="$1" f
  for f in "$conf" "$d"/*.conf; do
    [[ "$f" == "$ours" ]] && continue
    "${su[@]}" test -f "$f" || continue
    "${su[@]}" cat "$f" | awk -v f="$f" '
      tolower($1) == "match" { m = (tolower($2) != "all"); next }
      m && /^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitEmptyPasswords)[[:space:]]+yes/ { print "match-reenable " f ":" NR ": " $0; next }
      m && tolower($1) == "permitrootlogin" && tolower($2) != "no" { print "match-reenable " f ":" NR ": " $0 }'
  done
}

# spl_sshd_check <our file> <key-user rows> -> exit 0 when sshd -T says no
# passwords, no keyboard-interactive, no root login, globally and for every
# listed user and root; else the failing rows.
spl_sshd_check() {
  local ours="$1" rows="$2" u spec e bad
  bad="$(spl_sshd_scan_match "$ours")"$'\n'
  for u in "" root $(sed -nE 's/^(key login kept|no key): user=([^ ]+).*/\2/p' <<<"$rows"); do
    spec=""; [[ -n "$u" ]] && spec="user=$u,host=spl-sshd-check.invalid,addr=192.0.2.1"
    e="$(spl_sshd_eff "$spec")"
    grep -qx 'passwordauthentication=no' <<<"$e" && grep -qx 'kbdinteractiveauthentication=no' <<<"$e" &&
      grep -qx 'permitrootlogin=no' <<<"$e" || bad+="sshd -T ${u:-(global)}: $(tr '\n' ' ' <<<"$e")"$'\n'
  done
  bad="$(sed '/^$/d' <<<"$bad")"
  [[ -z "$bad" ]] || { printf '%s\n' "$bad"; return 1; }
}
