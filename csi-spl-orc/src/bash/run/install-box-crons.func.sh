#!/bin/bash
#------------------------------------------------------------------------------
# @description Install (or remove) the box owner's spool cron jobs (specs/069
# @description lane Y3): one line per row of cnf/box-crons/box-crons.manifest
# @description (the boot restore, the session snapshot and the graft index
# @description refresh, C1..C4 of spec 069 section 2.2) in the running user's
# @description crontab, run from this checkout and tagged
# @description `# csi-spl:box-cron:<name>`, matched only as the whole END of a
# @description line. The install also removes each engine line a row
# @description `replaces` (a line naming `ysg-box/<path>`, commented or not);
# @description every other line is kept byte for byte. Idempotent. A row whose
# @description script is not in this checkout yet (its lane not landed) is
# @description refused unless BOX_CRONS_ONLY leaves it out. From a linked
# @description worktree the install is refused (its paths vanish with it).
# @description An @reboot row waits for its script and log dir first
# @description (spl_cron_boot_gate, BOOT_CRON_WAIT).
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param BOX_CRONS_ACTION (optional) - install (default) | remove (drops the
# @param   tagged lines only; it never puts an engine line back)
# @param BOX_CRONS_ONLY (optional) - space/comma-separated row names; default
# @param   every row (and any stale `csi-spl:box-cron:` line is dropped)
# @param BOX_CRONS_STATE_DIR (optional) - the logs' root, default /var/csi/csi-spl
# @param BOX_CRONS_MANIFEST (optional) - default cnf/box-crons/box-crons.manifest
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_install_box_crons
# @example BOX_CRONS_ONLY=graft-index-refresh,graft-index-final ./run -a do_install_box_crons
# @example DRY_RUN=0 ./run -a do_install_box_crons
#------------------------------------------------------------------------------
do_install_box_crons() {
  local dry="${DRY_RUN:-1}" act="${BOX_CRONS_ACTION:-install}" only="${BOX_CRONS_ONLY:-}"
  local state="${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}" ct="${BOX_CRONS_CRONTAB:-crontab}"
  local man="${BOX_CRONS_MANIFEST:-$PROJ_PATH/cnf/box-crons/box-crons.manifest}"
  local -a names=() scheds=() scripts=() logs=() repls=() sel=()
  local before after i missing="" gd cd
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  case "$act" in install|remove) ;; *) do_log "FATAL BOX_CRONS_ACTION must be install or remove, got: '$act'"; return 1 ;; esac
  box_crons_read_manifest "$man" || return 1
  box_crons_select "$only" || return 1
  gd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
  cd="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [[ "$act" == install && -n "$gd" && "$gd" != "$cd" && "${BOX_CRONS_ALLOW_WORKTREE:-0}" != 1 ]]; then
    [[ "$dry" == 0 ]] && { do_log "FATAL $PROJ_PATH is a linked worktree: install from the main checkout - nothing changed"; return 1; }
    echo "WARN $PROJ_PATH is a linked worktree: the paths below would vanish with it; install from the main checkout"
  fi
  if [[ "$act" == install ]]; then
    for i in "${sel[@]}"; do
      [[ -f "$PROJ_PATH/${scripts[$i]}" ]] || missing+=" ${names[$i]}"
    done
    if [[ -n "$missing" ]]; then
      [[ "$dry" == 0 ]] && { do_log "FATAL the script of row(s)$missing is not in $PROJ_PATH yet (its lane not landed): BOX_CRONS_ONLY= the others - nothing changed"; return 1; }
      echo "WARN the script of row(s)$missing is not in $PROJ_PATH yet: a DRY_RUN=0 install refuses them"
    fi
  fi
  before="$(mktemp)"; after="$(mktemp)"
  $ct -l 2>/dev/null >"$before"
  box_crons_filter <"$before" >"$after"
  if [[ "$act" == install ]]; then
    for i in "${sel[@]}"; do
      box_crons_line "$i" >>"$after" || { rm -f "$before" "$after"; return 1; }
    done
  fi
  if cmp -s "$before" "$after"; then
    echo "OK cron: nothing to change"; rm -f "$before" "$after"; return 0
  fi
  echo "$([[ "$dry" == 1 ]] && echo PLAN || echo DO) cron: the crontab before -> after"
  diff -u --label before --label after "$before" "$after" | sed 's/^/  /'
  if [[ "$dry" == 1 ]]; then
    rm -f "$before" "$after"; do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0
  fi
  if [[ "$act" == install ]]; then
    for i in "${sel[@]}"; do
      mkdir -p "$(dirname "$state/${logs[$i]}")" || { rm -f "$before" "$after"; do_log "FATAL cannot create the log dir of ${names[$i]} under $state"; return 1; }
    done
  fi
  $ct "$after" || { rm -f "$before" "$after"; do_log "FATAL crontab refused the new file"; return 1; }
  rm -f "$before" "$after"
  do_log "OK the box crons are $([[ "$act" == install ]] && echo "installed (${#sel[@]} row(s))" || echo removed)"
}

# box_crons_line <index> - the crontab line of one row. An @reboot row runs
# behind the boot gate (spl_cron_boot_gate): cron's @reboot pass comes before
# the nofail binds that hold the script and the log (drill 8, 2026-10-09)
box_crons_line() {
  local i="$1" pre="" tag="csi-spl:box-cron:${names[$1]}"
  if [[ "${scheds[$i]}" == @reboot ]]; then
    declare -F spl_cron_boot_gate >/dev/null ||
      source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
    pre="$(spl_cron_boot_gate "$state/${logs[$i]}" "$PROJ_PATH/${scripts[$i]}" "$tag")" || return 1
  fi
  printf "%s %s/bin/bash '%s' >> '%s' 2>&1 # %s\n" \
    "${scheds[$i]}" "$pre" "$PROJ_PATH/${scripts[$i]}" "$state/${logs[$i]}" "$tag"
}

# box_crons_read_manifest <file> - fills names/scheds/scripts/logs/repls of the
# caller; one malformed row refuses the whole manifest
box_crons_read_manifest() {
  local f="$1" line n=0 name sched script log repl j
  [[ -r "$f" ]] || { do_log "FATAL cannot read the manifest $f"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    IFS='|' read -r name sched script log repl <<<"$line"
    name="$(box_crons_trim "$name")"; sched="$(box_crons_trim "$sched")"; script="$(box_crons_trim "$script")"
    log="$(box_crons_trim "$log")"; repl="$(box_crons_trim "$repl")"
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || { do_log "FATAL manifest line $n: bad name '$name'"; return 1; }
    [[ "$sched" == @reboot || "$sched" =~ ^[^[:space:]]+([[:space:]]+[^[:space:]]+){4}$ ]] \
      || { do_log "FATAL manifest line $n: schedule must be 5 cron fields or @reboot, got '$sched'"; return 1; }
    for j in "$script" "$log"; do
      [[ -n "$j" && "$j" != /* && "$j" != *..* && "$j" != *"'"* && "$j" =~ ^[^[:space:]]+$ ]] \
        || { do_log "FATAL manifest line $n: '$j' must be a relative path with no blank, quote or .."; return 1; }
    done
    for j in "${names[@]}"; do [[ "$j" == "$name" ]] && { do_log "FATAL manifest line $n: duplicate name $name"; return 1; }; done
    names+=("$name"); scheds+=("$sched"); scripts+=("$script"); logs+=("$log"); repls+=("$repl")
  done <"$f"
  (( ${#names[@]} )) || { do_log "FATAL the manifest $f has no row"; return 1; }
}

box_crons_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# box_crons_select <only> - fills sel with the manifest indexes to act on
box_crons_select() {
  local w i hit
  if [[ -z "$1" ]]; then sel=("${!names[@]}"); return 0; fi
  for w in ${1//,/ }; do
    hit=""
    for i in "${!names[@]}"; do [[ "${names[$i]}" == "$w" ]] && hit="$i"; done
    [[ -n "$hit" ]] || { do_log "FATAL BOX_CRONS_ONLY names '$w', which is no manifest row"; return 1; }
    sel+=("$hit")
  done
}

# box_crons_filter - stdin crontab -> stdout without the lines this run owns:
# the tagged lines of the selected rows (every tagged line when no ONLY), and
# on install the engine lines the selected rows replace
box_crons_filter() {
  local line tag i p
  local -a drop=() parts=()
  for i in "${sel[@]}"; do
    [[ "$act" == install && -n "${repls[$i]}" ]] || continue
    IFS=',' read -r -a parts <<<"${repls[$i]}"
    for p in "${parts[@]}"; do p="$(box_crons_trim "$p")"; [[ -n "$p" ]] && drop+=("ysg-box/$p"); done
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ \ \#\ csi-spl:box-cron:([a-z0-9-]+)$ ]]; then
      tag="${BASH_REMATCH[1]}"
      [[ -z "$only" ]] && continue
      for i in "${sel[@]}"; do [[ "${names[$i]}" == "$tag" ]] && continue 2; done
    else
      for p in "${drop[@]}"; do [[ "$line" == *"$p"* ]] && continue 2; done
    fi
    printf '%s\n' "$line"
  done
}
