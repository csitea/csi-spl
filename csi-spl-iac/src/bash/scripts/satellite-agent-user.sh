#!/usr/bin/env bash
#------------------------------------------------------------------------------
# satellite-agent-user.sh — runs ON the satellite as its box user, sent by
# do_satellite_agent_user (CLE-77911). Makes the agent user the fleet's agents
# run as (global rule: every programmatic Claude Code start runs as the agent
# user), the group they share the spool root with, and the spool root itself.
# Idempotent; one verdict line per part:
#   AGENT <part> OK|CHANGED|PLAN|FAIL <detail>
# Env: AGENT_USER (required, no default: the box's SPOOL_AGENT_USER), AGENT_UID (default 1001: a FIXED uid, so
#      the files it owns on the data disk survive a VM recreate), SPOOL_GROUP
#      (default spool-agents), SPOOL_ROOT (default /var/spool-hub), DRY_RUN
#      (default 1: PLAN lines, nothing changed), SUDO (default "sudo -n"; the
#      tests set it empty and stub the commands), LINGER_DIR (tests).
#------------------------------------------------------------------------------
set -uo pipefail
AGENT_USER="${AGENT_USER:-}" AGENT_UID="${AGENT_UID:-1001}"
SPOOL_GROUP="${SPOOL_GROUP:-spool-agents}" SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
DRY_RUN="${DRY_RUN:-1}" SUDO="${SUDO-sudo -n}"
BOX_USER="$(id -un)"
DATA_HOME="/mnt/data/home/$AGENT_USER"
LINGER_DIR="${LINGER_DIR:-/var/lib/systemd/linger}"
fails=0
verdict() { echo "AGENT $1 $2 ${3:-}"; [[ "$2" == FAIL ]] && fails=$((fails + 1)); return 0; }
# do_or_plan <part> <what> <cmd...>: PLAN in a dry run, else run it
do_or_plan() {
  local part="$1" what="$2"; shift 2
  if [[ "$DRY_RUN" != 0 ]]; then verdict "$part" PLAN "$what"; return 0; fi
  # shellcheck disable=SC2086 # SUDO is a word list on purpose ("sudo -n")
  $SUDO "$@" >/dev/null 2>&1 && verdict "$part" CHANGED "$what" || verdict "$part" FAIL "$what"
}

[[ "$AGENT_USER" =~ ^[a-z][a-z0-9-]{0,30}$ && "$AGENT_UID" =~ ^[1-9][0-9]{3,5}$ ]] ||
  { verdict input FAIL "AGENT_USER / AGENT_UID malformed"; exit 1; }

# group: the spool root's group, shared by the box user and the agent user
if getent group "$SPOOL_GROUP" >/dev/null; then verdict group OK "$SPOOL_GROUP"
else do_or_plan group "groupadd $SPOOL_GROUP" groupadd "$SPOOL_GROUP"; fi

# user: fixed uid, home on the data disk (a recreate keeps its claude login)
if id "$AGENT_USER" >/dev/null 2>&1; then
  [[ "$(id -u "$AGENT_USER")" == "$AGENT_UID" ]] && verdict user OK "$AGENT_USER uid $AGENT_UID" ||
    verdict user FAIL "$AGENT_USER exists with uid $(id -u "$AGENT_USER"), not $AGENT_UID"
elif getent passwd "$AGENT_UID" >/dev/null; then
  verdict user FAIL "uid $AGENT_UID is taken by $(getent passwd "$AGENT_UID" | cut -d: -f1)"
else
  mountpoint -q /mnt/data 2>/dev/null || [[ -n "${AGENT_SKIP_MOUNT_CHECK:-}" ]] ||
    { verdict user FAIL "/mnt/data is not mounted"; exit 1; }
  do_or_plan user "useradd $AGENT_USER uid $AGENT_UID home $DATA_HOME" \
    useradd -u "$AGENT_UID" -m -d "$DATA_HOME" -s /bin/bash "$AGENT_USER"
fi

# groups: the agent user in docker + the spool group; the box user in the spool group
for pair in "$AGENT_USER:docker" "$AGENT_USER:$SPOOL_GROUP" "$BOX_USER:$SPOOL_GROUP"; do
  u="${pair%%:*}" g="${pair#*:}"
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then verdict groups OK "$u in $g"
  else do_or_plan groups "usermod -aG $g $u" usermod -aG "$g" "$u"; fi
done

# linger: the agent user's tmux and agents survive logout
if [[ -e "$LINGER_DIR/$AGENT_USER" ]]; then verdict linger OK "$AGENT_USER"
else do_or_plan linger "loginctl enable-linger $AGENT_USER" loginctl enable-linger "$AGENT_USER"; fi

# spool root: <box user>:<group> 2770 with group-rwX default ACLs, as on the box PC
want="$BOX_USER:$SPOOL_GROUP 2770"
have="$(stat -c '%U:%G %a' "$SPOOL_ROOT" 2>/dev/null)"
if [[ "$have" == "$want" ]] && getfacl -p "$SPOOL_ROOT" 2>/dev/null | grep -qx 'default:group::rwx'; then
  verdict spool-root OK "$SPOOL_ROOT $want"
else
  do_or_plan spool-root "$SPOOL_ROOT -> $want + default ACL group rwX (was: ${have:-absent})" \
    bash -c 'install -d "$1" && chown "$2" "$1" && chmod 2770 "$1" && setfacl -R -m g::rwX,d:g::rwX "$1"' \
    _ "$SPOOL_ROOT" "$BOX_USER:$SPOOL_GROUP"
fi

echo "AGENT-USER fails=$fails dry_run=$DRY_RUN"
(( fails == 0 ))
