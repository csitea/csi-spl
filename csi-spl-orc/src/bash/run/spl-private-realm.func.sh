#!/bin/bash
# @description The box-local list of PRIVATE workspaces (spec 129 G1, phase
# @description A0, Q2 decided a): a lane whose brief comes from a topic of a
# @description listed workspace, or whose checkout is a listed private repo, is
# @description a private lane. The spawn harness records its realm and refuses
# @description it a worktree of the public repository; the pre-push hook and
# @description its trampoline refuse its push. The list names customers, so it
# @description lives ONLY on each fleet box ($SPOOL_ROOT/private-realms.conf,
# @description 0640, group spool-agents): never in git, the hub database, a
# @description message, a report or a log line. This action prints its path and
# @description record count, never its content. Format and readers:
# @description csi-spl-orc/src/bash/features/spawn-agents/lib/private-realm.inc.sh.
# @description OWNER RULE for adding a workspace: on EVERY fleet box, as the box
# @description user, REALM_CMD=add with the workspace id and its topics (later
# @description topics of the same workspace are added the same way); then
# @description REALM_CMD=show on each box must report the same record count.
# @param REALM_CMD (optional) - show (default) | add | check | install-hook
# @param REALM_WORKSPACE (add) - the workspace id ([A-Za-z0-9_-], up to 64)
# @param REALM_TOPICS (add) - comma-separated topic uuids or their first 8 hex chars
# @param REALM_CHECKOUT (add, optional) - absolute dir of a private repo checkout on this box
# @param REALM_TEXT / REALM_DIR (check) - a topic, task id or brief text / a work dir; prints realm=public or realm=private (never the workspace)
# @param REALM_REPO (install-hook, optional) - the checkout whose common hooks dir gets the trampoline; default this repo's main checkout
# @param SPOOL_PRIVATE_REALMS (optional) - the list file; default $SPOOL_ROOT/private-realms.conf
# @example ./run -a do_spl_private_realm
# @example REALM_CMD=add REALM_WORKSPACE=<workspace> REALM_TOPICS=<topic8>,<topic8> ./run -a do_spl_private_realm
# @example REALM_CMD=check REALM_TEXT=dispatch-<topic8>-a0 ./run -a do_spl_private_realm
# @example REALM_CMD=install-hook ./run -a do_spl_private_realm

do_spl_private_realm() {
  local lib="$PROJ_PATH/src/bash/features/spawn-agents/lib/private-realm.inc.sh"
  [[ -r "$lib" ]] || { do_log "FATAL no $lib"; return 1; }
  # shellcheck source=../features/spawn-agents/lib/private-realm.inc.sh
  . "$lib"
  export SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  case "${REALM_CMD:-show}" in
    show) spl_private_realm_show ;;
    add) spl_private_realm_add ;;
    check) spl_private_realm_check ;;
    install-hook) spl_private_realm_install_hook ;;
    *) do_log "FATAL REALM_CMD must be show, add, check or install-hook"; return 1 ;;
  esac
}

# Path, mode, group and record counts; never a record.
spl_private_realm_show() {
  local f n_ws n_co
  f="$(pr_file)"
  if [[ ! -e "$f" ]]; then
    do_log "INFO no private list at $f: every lane on this box is public"
    return 0
  fi
  [[ -r "$f" ]] || { do_log "FATAL $f is not readable by $(id -un)"; return 1; }
  n_ws="$(pr_records | grep -c '^workspace ')"; n_co="$(pr_records | grep -c '^checkout ')"
  do_log "INFO private list $f: $(stat -c '%a %U:%G' "$f"), $(wc -l <"$f") lines, $n_ws workspace record(s), $n_co checkout record(s)"
}

# Adds topics to a workspace's record (creating it) and, with REALM_CHECKOUT,
# a checkout record. Idempotent; the file is created 0640 group spool-agents.
spl_private_realm_add() {
  local f ws="${REALM_WORKSPACE:-}" t topics="" cur new tmp grp
  f="$(pr_file)"
  [[ "$ws" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL REALM_WORKSPACE must be [A-Za-z0-9_-], up to 64"; return 1; }
  for t in ${REALM_TOPICS//,/ }; do
    t="$(tr 'A-F' 'a-f' <<<"${t:0:8}")"
    [[ "$t" =~ ^[0-9a-f]{8}$ ]] || { do_log "FATAL REALM_TOPICS: each topic is a uuid or its first 8 hex chars"; return 1; }
    topics+=" $t"
  done
  [[ -n "$topics" || -n "${REALM_CHECKOUT:-}" ]] || { do_log "FATAL give REALM_TOPICS and/or REALM_CHECKOUT"; return 1; }
  [[ -z "${REALM_CHECKOUT:-}" || "$REALM_CHECKOUT" == /* ]] || { do_log "FATAL REALM_CHECKOUT must be an absolute dir"; return 1; }
  if [[ ! -e "$f" ]]; then
    printf '# Box-local list of private workspaces (spec 129 G1). Never in git, the\n# hub database, a message, a report or a log. Edit with do_spl_private_realm.\n' >"$f" || return 1
    grp="$(stat -c %G "$(dirname "$f")")"
    chgrp "$grp" "$f" 2>/dev/null; chmod 0640 "$f" || return 1
  fi
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  cur="$(awk -v w="$ws" '$1 == "workspace" && $2 == w { for (i = 3; i <= NF; i++) print $i }' "$f")"
  new="$(printf '%s\n' $cur $topics | grep -v '^$' | sort -u | tr '\n' ' ')"
  awk -v w="$ws" '!($1 == "workspace" && $2 == w)' "$f" >"$tmp"
  [[ -z "${new// }" ]] || printf 'workspace %s %s\n' "$ws" "${new% }" >>"$tmp"
  if [[ -n "${REALM_CHECKOUT:-}" ]] && ! awk -v w="$ws" -v d="$REALM_CHECKOUT" '$1 == "checkout" && $2 == w && $3 == d { f = 1 } END { exit !f }' "$f"; then
    printf 'checkout %s %s\n' "$ws" "$REALM_CHECKOUT" >>"$tmp"
  fi
  chmod --reference="$f" "$tmp" && chgrp --reference="$f" "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  do_log "OK private list updated"
  spl_private_realm_show
}

# The realm of a topic text or a work dir, without the workspace.
spl_private_realm_check() {
  local r
  r="$(pr_resolve "${REALM_TEXT:-}" "" "${REALM_DIR:-}")" || return 1
  echo "${r%%:*}"
}

# The trampoline into the main checkout's common hooks dir, and its version line.
spl_private_realm_install_hook() {
  local repo="${REALM_REPO:-}" common
  if [[ -z "$repo" ]]; then
    common="$(git -C "$PROJ_PATH" rev-parse --path-format=absolute --git-common-dir)" || return 1
    repo="$(dirname "$common")"
  fi
  bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/install-pre-push-hook.sh" "$repo" || return 1
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" || return 1
  do_log "INFO $common/hooks/pre-push: $(grep -m1 '^# spl-pre-push-trampoline version: ' "$common/hooks/pre-push" || echo 'no version line (older than spec 129 A0)')"
}
