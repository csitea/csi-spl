#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1960 (security round 1, row 10): a dormant local user loses
# @description its root path: its own sudoers grant file(s) and its
# @description supplementary groups (docker, the other users' groups, ...).
# @description The user, its home, its files and its primary group stay, so
# @description nothing it owns is orphaned. First it PROVES nothing launches
# @description as the user, and refuses on any hit, by name:
# @description   - a running process of the user
# @description   - its crontab; a line naming it in any crontab, cron.d,
# @description     anacrontab, systemd unit (system and every home), or a
# @description     sudoers file other than its own grant
# @description   - a launcher script under DORMANT_SCAN_DIRS: sudo -u, su,
# @description     runuser -u, setpriv --reuid or User= with the user
# @description It refuses root, a uid below 1000, the user running it, the
# @description box / agent user of the spool, and a sudoers file that also
# @description grants someone else (named, left alone). DRY_RUN=0: each grant
# @description file is copied to the undo dir (mode 600) and removed,
# @description `visudo -c` must still pass (else the files go back), then
# @description gpasswd -d per group; it ends with no sudoers line and no
# @description supplementary group for the user. Dry run unless DRY_RUN=0.
# @param DORMANT_USER (required) - the user to revoke
# @param DORMANT_SCAN_DIRS (optional) - launcher dirs, default "/etc /usr/local /opt /home /root"
# @param DORMANT_SCAN_EXCLUDE (optional) - dirs the owner reviewed and rules out (an archive), printed in the output
# @param DORMANT_UNDO (optional) - the undo dir on DRY_RUN=0, default $HOME/.local/state/csi-spl/dormant-user-undo/<UTC stamp>
# @param DORMANT_ETC (optional, tests) - default /etc (sudoers, sudoers.d, crontab, cron.d, systemd)
# @param DORMANT_UNIT_DIRS (optional, tests) - default "/lib/systemd/system /usr/lib/systemd/system"
# @param DORMANT_CRON_SPOOL (optional, tests) - default /var/spool/cron
# @param DORMANT_SUDO (optional) - the privilege prefix, default "sudo -n" ("" as root)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example DORMANT_USER=<user> ./run -a do_spl_dormant_user_revoke
# @example DORMANT_USER=<user> DRY_RUN=0 ./run -a do_spl_dormant_user_revoke
#------------------------------------------------------------------------------
do_spl_dormant_user_revoke() {
  local u="${DORMANT_USER:-}" etc="${DORMANT_ETC:-/etc}" apply=1 uid prim groups g f hits grants=() mixed=() bad=0 undo
  local -a su=()
  if spl_dry_run; then apply=0; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  if [[ -n "${DORMANT_SUDO+x}" ]]; then read -ra su <<<"$DORMANT_SUDO"; elif (( EUID != 0 )); then su=(sudo -n); fi
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { do_log "FATAL DORMANT_USER must be a login name, got: '$u'"; return 1; }
  uid="$(id -u "$u" 2>/dev/null)" || { do_log "FATAL no user $u"; return 1; }
  (( uid >= 1000 )) || { do_log "FATAL $u has uid $uid (< 1000): a system user, refused"; return 1; }
  [[ "$u" != "$(id -un)" && "$u" != "${SUDO_USER:-}" ]] || { do_log "FATAL $u is the user running this: refused"; return 1; }
  [[ "$u" != "${SPOOL_AGENT_USER:-}" && "$u" != "${SPOOL_BOX_USER:-}" ]] || { do_log "FATAL $u is the spool's agent or box user: refused"; return 1; }
  prim="$(id -gn "$u")"
  groups="$(id -Gn "$u" | tr ' ' '\n' | grep -vx "$prim" | tr '\n' ' ')"; groups="${groups% }"

  # --- the proof that nothing launches as the user -----------------------------------------
  hits="$(spl_dur_launchers "$u" "$etc")"
  for f in "$etc"/sudoers.d/*; do
    "${su[@]}" test -f "$f" || continue
    if "${su[@]}" grep -qE "^[[:space:]]*${u}[[:space:]]" "$f"; then
      if "${su[@]}" grep -vE '^[[:space:]]*(#|$|Defaults)' "$f" | grep -vE "^[[:space:]]*${u}[[:space:]]" >/dev/null; then mixed+=("$f"); else grants+=("$f"); fi
    fi
  done
  echo "user $u uid=$uid primary group=$prim (kept) supplementary groups=${groups:-none}"
  echo "sudoers grant files: ${grants[*]:-none}"
  (( ${#mixed[@]} )) && { echo "REFUSED: sudoers files that grant $u AND others (edit by hand): ${mixed[*]}"; bad=1; }
  if [[ -n "$hits" ]]; then printf '%s\n' "$hits" | sed 's/^/launcher: /'; echo "REFUSED: something launches as $u (above)"; bad=1
  else echo "launchers: 0 (processes, crontabs, cron.d, anacrontab, systemd units, sudoers, scripts under ${DORMANT_SCAN_DIRS:-/etc /usr/local /opt /home /root})"; fi
  [[ -n "${DORMANT_SCAN_EXCLUDE:-}" ]] && echo "not scanned (DORMANT_SCAN_EXCLUDE, reviewed by hand): $DORMANT_SCAN_EXCLUDE"
  (( bad )) && { do_log "FAIL $u: not revoked (see REFUSED above)"; return 1; }
  if (( ${#grants[@]} == 0 )) && [[ -z "$groups" ]]; then do_log "OK $u has no sudoers grant and no supplementary group: nothing to do"; return 0; fi
  if (( ! apply )); then
    for f in "${grants[@]}"; do echo "would remove $f ($("${su[@]}" grep -cvE '^[[:space:]]*(#|$)' "$f") rule line(s))"; done
    for g in $groups; do echo "would: gpasswd -d $u $g"; done
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to revoke."
    return 0
  fi

  undo="${DORMANT_UNDO:-$HOME/.local/state/csi-spl/dormant-user-undo/$(date -u +%Y%m%dT%H%M%SZ)}"
  (umask 077 && mkdir -p "$undo") || { do_log "FATAL cannot make $undo"; return 1; }
  for f in "${grants[@]}"; do
    if ! { "${su[@]}" cat "$f" >"$undo/$(basename "$f")" && chmod 600 "$undo/$(basename "$f")"; }; then do_log "FATAL cannot back up $f"; return 1; fi
    "${su[@]}" rm -f "$f" || { do_log "FATAL cannot remove $f"; return 1; }
    echo "removed $f (copy in $undo)"
  done
  if ! "${su[@]}" "${VISUDO_BIN:-visudo}" -c >/dev/null 2>&1; then
    for f in "${grants[@]}"; do "${su[@]}" install -m 0440 "$undo/$(basename "$f")" "$f"; done
    do_log "FATAL visudo -c fails without the grant files: put back, nothing else changed"; return 1
  fi
  for g in $groups; do
    "${su[@]}" gpasswd -d "$u" "$g" >/dev/null || { echo "FAIL gpasswd -d $u $g"; bad=1; continue; }
    echo "$u removed from group $g"
    printf 'gpasswd -a %s %s\n' "$u" "$g" >>"$undo/groups.undo"
  done
  groups="$(id -Gn "$u" | tr ' ' '\n' | grep -vx "$prim" | tr '\n' ' ')"
  hits="$("${su[@]}" grep -lE "^[[:space:]]*${u}[[:space:]]" "$etc/sudoers" "$etc"/sudoers.d/* 2>/dev/null)"
  [[ $bad -eq 0 && -z "${groups// /}" && -z "$hits" ]] ||
    { do_log "FAIL $u after the revoke: groups='${groups% }' sudoers lines in: ${hits:-none}"; return 1; }
  do_log "OK $u revoked: no sudoers grant, no supplementary group (undo in $undo)"
}

# spl_dur_launchers <user> <etc> -> one "<what>: <where>" row per thing that
# launches as the user; nothing when none.
spl_dur_launchers() {
  local u="$1" etc="$2" n f d
  local -a unitdirs scan skip=()
  local own x
  own="$(getent passwd "$u" | cut -d: -f6)"
  for x in $own ${DORMANT_SCAN_EXCLUDE:-}; do [[ "$x" == /* ]] && skip+=("$x"); done
  # shellcheck disable=SC2009 # ps -u is stubbed in the test; pgrep -u is not
  n="$(ps -u "$u" --no-headers 2>/dev/null | grep -c .)"
  (( n == 0 )) || echo "processes: $n running"
  "${su[@]}" crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' >/dev/null && echo "crontab: $u has its own crontab"
  read -ra unitdirs <<<"${DORMANT_UNIT_DIRS:-/lib/systemd/system /usr/lib/systemd/system}"
  for d in "$etc/crontab" "$etc/cron.d" "$etc/anacrontab" "${DORMANT_CRON_SPOOL:-/var/spool/cron}" "$etc/systemd" "${unitdirs[@]}" "$etc/sudoers" "$etc/sudoers.d"; do
    "${su[@]}" test -e "$d" || continue
    "${su[@]}" grep -rlwE -- "$u" "$d" 2>/dev/null | while IFS= read -r f; do
      # its own grant file is what the revoke removes, not a launcher
      if [[ "$f" == "$etc/sudoers.d/"* ]] && ! "${su[@]}" grep -vE '^[[:space:]]*(#|$|Defaults)' "$f" | grep -vE "^[[:space:]]*${u}[[:space:]]" >/dev/null; then continue; fi
      echo "named in: $f"
    done
  done
  read -ra scan <<<"${DORMANT_SCAN_DIRS:-/etc /usr/local /opt /home /root}"
  for d in "${scan[@]}"; do
    "${su[@]}" test -d "$d" || continue
    # the user's own home and the excluded dirs are filtered after the grep (grep's --exclude-dir takes names, not paths);
    # transcripts, editor history and notes (.txt) quote commands, they run none
    "${su[@]}" grep -rIlE --exclude-dir=.git --exclude-dir=file-history --exclude-dir=tool-results --exclude='*.txt' --exclude-dir=node_modules --exclude-dir=.terraform --exclude-dir=.venv \
      --exclude-dir=venv --exclude-dir=__pycache__ --exclude-dir=.nuxt --exclude-dir=.output --exclude-dir=.cache \
      --exclude-dir=sudoers.d --exclude='*.md' --exclude='*.html' --exclude='*.jsonl' --exclude='*.log' --exclude=sudoers \
      -- "(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+-u[[:space:]]*|su[[:space:]]+(-[[:space:]]+|-l[[:space:]]+|-c[[:space:]]+[^[:space:]]+[[:space:]]+)?|runuser[[:space:]]+(-u|-l)[[:space:]]+|--reuid[= ]|^User=)['\"]?$u\\b" "$d" 2>/dev/null |
      while IFS= read -r f; do
        for x in "${skip[@]}"; do [[ "$f" == "$x"/* ]] && continue 2; done
        echo "script: $f"
      done
  done
}
