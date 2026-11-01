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
# @description (spl_cron_boot_gate, BOOT_CRON_WAIT). Every scheduled row runs
# @description under its own lock (cron-no-stack.sh, <log dir>/<name>.cron.lock,
# @description SPL-4495): a start while the last run still goes exits 0 with
# @description one SKIP line, so a slow job never stacks.
# @description A row marked `desk` (its job reaches a desk, SPL-4558) goes to
# @description the crontab of the user whose state root holds the desk it
# @description reaches (spec 069 section 8.3.1: a moved desk is 0700 under
# @description that user): the running user or the desk user (spl_desk_user).
# @description The desk is <SPOOL_FLEET_TENANT>/<spl_desk_box_default> for
# @description `desk`, <SPOOL_FLEET_TENANT>/<SPOOL_RSP_BOX> for `desk:rsp`, in
# @description env SPOOL_FLEET_ENV; it is held where its `pinned` file is. No
# @description pin under either user, or `desk:any` (reads no one desk): the
# @description row stays in the crontab that holds it (a WARN names it). No
# @description desk user, or the running user is it: one crontab, as before.
# @description The desk user's crontab is written first.
# @description Dry run unless DRY_RUN=0 (prints the crontab diff).
# @param BOX_CRONS_ACTION (optional) - install (default) | remove (drops the
# @param   tagged lines only; it never puts an engine line back)
# @param BOX_CRONS_ONLY (optional) - space/comma-separated row names; default
# @param   every row (and any stale `csi-spl:box-cron:` line is dropped)
# @param BOX_CRONS_STATE_DIR (optional) - the logs' root, default /var/csi/csi-spl
# @param BOX_CRONS_MANIFEST (optional) - default cnf/box-crons/box-crons.manifest
# @param BOX_CRONS_DESK_USER (optional) - the desk user, default spl_desk_user
# @param BOX_CRONS_DESK_CRONTAB (optional) - default `sudo -n crontab -u <desk user>`
# @param BOX_CRONS_DESK_ROOTS (optional) - `<user>=<cloud state root> ...`, the
# @param   roots the pins are looked up in; default each user's from
# @param   spl_desk_state_root (<home>/.local/share/<org>-<app>/cloud/<env>)
# @param BOX_CRONS_SUDO (optional) - default `sudo -n`: looks up the desk user's pin
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_install_box_crons
# @example BOX_CRONS_ONLY=graft-index-refresh,graft-index-final ./run -a do_install_box_crons
# @example DRY_RUN=0 ./run -a do_install_box_crons
#------------------------------------------------------------------------------
do_install_box_crons() {
  local dry="${DRY_RUN:-1}" act="${BOX_CRONS_ACTION:-install}" only="${BOX_CRONS_ONLY:-}"
  local state="${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}" ct="${BOX_CRONS_CRONTAB:-crontab}"
  local man="${BOX_CRONS_MANIFEST:-$PROJ_PATH/cnf/box-crons/box-crons.manifest}"
  local -a names=() scheds=() scripts=() logs=() repls=() ases=() sel=() bsel=() dsel=()
  local i missing="" gd cd du dct
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
  du="$(box_crons_desk_user)" || return 1
  bsel=("${sel[@]}")
  if [[ -n "$du" ]]; then
    dct="${BOX_CRONS_DESK_CRONTAB:-sudo -n crontab -u $du}"
    box_crons_split "$du" "$dct" || return 1
    # the desk user's first: refused, the box user's still holds every row
    box_crons_apply "$dct" " ($du)" "${dsel[@]}" || return 1
  fi
  box_crons_apply "$ct" "${du:+ ($(id -un))}" "${bsel[@]}" || return 1
  [[ "$dry" == 1 ]] && { do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."; return 0; }
  do_log "OK the box crons are $([[ "$act" == install ]] && echo "installed (${#sel[@]} row(s)${du:+, ${#dsel[@]} as $du})" || echo removed)"
}

# box_crons_desk_user - the user whose crontab takes the `desk` rows:
# BOX_CRONS_DESK_USER, else spl_desk_user (SPOOL_DESK_USER of box.env); empty
# when none or when it is the running user (one crontab). A user with no
# passwd entry is refused.
box_crons_desk_user() {
  local u="${BOX_CRONS_DESK_USER:-}"
  if [[ -z "$u" ]]; then
    declare -F spl_desk_user >/dev/null ||
      source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-cloud-cnf.func.sh"
    u="$(spl_desk_user)"
  fi
  [[ -z "$u" || "$u" == "$(id -un)" ]] && return 0
  getent passwd "$u" >/dev/null || { do_log "FATAL the desk user '$u' has no passwd entry - nothing changed" >&2; return 1; }
  printf '%s' "$u"
}

# box_crons_split <desk user> <desk crontab cmd> - splits the caller's sel into
# bsel (the running user's crontab) and dsel (the desk user's): a desk row goes
# to the user that holds its desk's pin (box_crons_desk_owner); remove acts on
# both crontabs alike
box_crons_split() {
  local du="$1" i o held
  bsel=(); dsel=()
  [[ "$act" == remove ]] && { bsel=("${sel[@]}"); dsel=("${sel[@]}"); return 0; }
  held="$($2 -l 2>/dev/null)"
  for i in "${sel[@]}"; do
    [[ "${ases[$i]}" == desk* ]] || { bsel+=("$i"); continue; }
    o="$(box_crons_desk_owner "$i" "$du" "$held")" || return 1
    if [[ "$o" == "$du" ]]; then dsel+=("$i"); else bsel+=("$i"); fi
  done
}

# box_crons_desk_owner <index> <desk user> <desk crontab text> - prints the user
# whose crontab takes this desk row: the first of the running user and the
# desk user that holds the pin of the desk it reaches; no pin, or `desk:any`:
# the user whose crontab holds the row now (the running user's when neither)
box_crons_desk_owner() {
  local i="$1" du="$2" me ws e id="" u now
  me="$(id -un)"
  declare -F spl_desk_box_default >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"
  ws="$(spl_box_key SPOOL_FLEET_TENANT)" e="$(spl_box_key SPOOL_FLEET_ENV)"
  case "${ases[$i]}" in
    desk) id="$(spl_desk_box_default)" ;;
    desk:rsp) id="$(spl_box_key SPOOL_RSP_BOX)" ;;
  esac
  if [[ -n "$id" && -n "$ws" && -n "$e" ]]; then
    for u in "$me" "$du"; do box_crons_pinned "$u" "$e" "$ws/$id" && { printf '%s' "$u"; return 0; }; done
  fi
  now="$me"; grep -q " # csi-spl:box-cron:${names[$i]}\$" <<<"$3" && now="$du"
  echo "WARN ${names[$i]} (${ases[$i]}): $([[ -n "$id" ]] && echo "no pin of ${e:-<no SPOOL_FLEET_ENV>}/${ws:-<no SPOOL_FLEET_TENANT>}/$id under $me or $du" || echo "reaches no one desk"): kept in $now's crontab" >&2
  printf '%s' "$now"
}

# box_crons_pinned <user> <env> <workspace>/<desk id> - true when that desk's
# pinned file is in the user's cloud state root (BOX_CRONS_DESK_ROOTS, else
# spl_desk_state_root); another user's root is looked into as that user
box_crons_pinned() {
  local u="$1" e="$2" w r=""
  for w in ${BOX_CRONS_DESK_ROOTS:-}; do [[ "${w%%=*}" == "$u" ]] && r="${w#*=}"; done
  [[ -n "$r" ]] || r="$(SPOOL_DESK_USER="$u" spl_desk_state_root "$e" 2>/dev/null)" || return 1
  [[ -n "$r" ]] || return 1
  if [[ "$u" == "$(id -un)" ]]; then [[ -e "$r/desk/$3/pinned" ]]
  else ${BOX_CRONS_SUDO:-sudo -n} -u "$u" test -e "$r/desk/$3/pinned" 2>/dev/null; fi
}

# box_crons_apply <crontab cmd> <label> [index...] - one crontab: drop the lines
# this run owns (box_crons_filter), append the given rows, print the diff; with
# DRY_RUN=0 create their log dirs and write it. A row whose line is already
# there, unchanged, keeps its place: a re-run on a crontab in another order
# plans nothing (SPL-4558). Uses the caller's locals.
box_crons_apply() {
  local c="$1" lbl="$2" before after i l err; shift 2
  local -a want=()
  if [[ "$act" == install ]]; then
    for i in "$@"; do l="$(box_crons_line "$i")" || return 1; want+=("$l"); done
  fi
  before="$(mktemp)"; after="$(mktemp)"
  # an empty crontab lists as "no crontab for <user>"; any other failed list
  # would write the new crontab from an empty "before" and drop its other lines
  if ! err="$($c -l 2>&1 >"$before")"; then
    [[ "$err" == *"no crontab for"* ]] || { rm -f "$before" "$after"; do_log "FATAL crontab$lbl refused to list (${err:-no message}) - nothing changed"; return 1; }
    : >"$before"
  fi
  box_crons_filter "${want[@]}" <"$before" >"$after"
  for l in "${want[@]}"; do grep -qxF -- "$l" "$after" || printf '%s\n' "$l" >>"$after"; done
  if cmp -s "$before" "$after"; then
    echo "OK cron$lbl: nothing to change"; rm -f "$before" "$after"; return 0
  fi
  echo "$([[ "$dry" == 1 ]] && echo PLAN || echo DO) cron$lbl: the crontab before -> after"
  diff -u --label before --label after "$before" "$after" | sed 's/^/  /'
  [[ "$dry" == 1 ]] && { rm -f "$before" "$after"; return 0; }
  if [[ "$act" == install ]]; then
    for i in "$@"; do
      mkdir -p "$(dirname "$state/${logs[$i]}")" || { rm -f "$before" "$after"; do_log "FATAL cannot create the log dir of ${names[$i]} under $state"; return 1; }
    done
  fi
  $c "$after" || { rm -f "$before" "$after"; do_log "FATAL crontab$lbl refused the new file"; return 1; }
  rm -f "$before" "$after"
}

# box_crons_line <index> - the crontab line of one row. An @reboot row runs
# behind the boot gate (spl_cron_boot_gate): cron's @reboot pass comes before
# the nofail binds that hold the script and the log (drill 8, 2026-10-09).
# Every other row runs behind cron-no-stack.sh on its own lock (SPL-4495)
box_crons_line() {
  local i="$1" pre="" tag="csi-spl:box-cron:${names[$1]}"
  if [[ "${scheds[$i]}" == @reboot ]]; then
    declare -F spl_cron_boot_gate >/dev/null ||
      source "$(dirname "${BASH_SOURCE[0]}")/spl-desk-install-service.func.sh"
    pre="$(spl_cron_boot_gate "$state/${logs[$i]}" "$PROJ_PATH/${scripts[$i]}" "$tag")" || return 1
  else
    declare -F spl_cron_no_stack_pre >/dev/null ||
      source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-lock.func.sh"
    pre="$(spl_cron_no_stack_pre "$PROJ_PATH" "$state/$(dirname "${logs[$i]}")/${names[$i]}.cron.lock")" || return 1
  fi
  printf "%s %s/bin/bash '%s' >> '%s' 2>&1 # %s\n" \
    "${scheds[$i]}" "$pre" "$PROJ_PATH/${scripts[$i]}" "$state/${logs[$i]}" "$tag"
}

# box_crons_read_manifest <file> - fills names/scheds/scripts/logs/repls/ases
# of the caller; one malformed row refuses the whole manifest
box_crons_read_manifest() {
  local f="$1" line n=0 name sched script log repl as j
  [[ -r "$f" ]] || { do_log "FATAL cannot read the manifest $f"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    IFS='|' read -r name sched script log repl as <<<"$line"
    name="$(box_crons_trim "$name")"; sched="$(box_crons_trim "$sched")"; script="$(box_crons_trim "$script")"
    log="$(box_crons_trim "$log")"; repl="$(box_crons_trim "$repl")"; as="$(box_crons_trim "$as")"
    [[ -z "$as" || "$as" =~ ^desk(:rsp|:any)?$ ]] || { do_log "FATAL manifest line $n: as must be empty, desk, desk:rsp or desk:any, got '$as'"; return 1; }
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || { do_log "FATAL manifest line $n: bad name '$name'"; return 1; }
    [[ "$sched" == @reboot || "$sched" =~ ^[^[:space:]]+([[:space:]]+[^[:space:]]+){4}$ ]] \
      || { do_log "FATAL manifest line $n: schedule must be 5 cron fields or @reboot, got '$sched'"; return 1; }
    for j in "$script" "$log"; do
      [[ -n "$j" && "$j" != /* && "$j" != *..* && "$j" != *"'"* && "$j" =~ ^[^[:space:]]+$ ]] \
        || { do_log "FATAL manifest line $n: '$j' must be a relative path with no blank, quote or .."; return 1; }
    done
    for j in "${names[@]}"; do [[ "$j" == "$name" ]] && { do_log "FATAL manifest line $n: duplicate name $name"; return 1; }; done
    names+=("$name"); scheds+=("$sched"); scripts+=("$script"); logs+=("$log"); repls+=("$repl"); ases+=("$as")
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

# box_crons_filter [wanted line...] - stdin crontab -> stdout without the lines
# this run owns: the tagged lines of the selected rows (every tagged line when
# no ONLY), and on install the engine lines the selected rows replace. The
# first copy of a wanted line stays where it is
box_crons_filter() {
  local line tag i p
  local -a drop=() parts=()
  local -A seen=()
  for i in "${sel[@]}"; do
    [[ "$act" == install && -n "${repls[$i]}" ]] || continue
    IFS=',' read -r -a parts <<<"${repls[$i]}"
    for p in "${parts[@]}"; do p="$(box_crons_trim "$p")"; [[ -n "$p" ]] && drop+=("ysg-box/$p"); done
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ \ \#\ csi-spl:box-cron:([a-z0-9-]+)$ ]]; then
      tag="${BASH_REMATCH[1]}"
      for p in "$@"; do
        [[ "$line" == "$p" && -z "${seen[$tag]:-}" ]] && { seen[$tag]=1; printf '%s\n' "$line"; continue 2; }
      done
      [[ -z "$only" ]] && continue
      for i in "${sel[@]}"; do [[ "${names[$i]}" == "$tag" ]] && continue 2; done
    else
      for p in "${drop[@]}"; do [[ "$line" == *"$p"* ]] && continue 2; done
    fi
    printf '%s\n' "$line"
  done
}
