#!/bin/bash
#------------------------------------------------------------------------------
# @description The shadow feed: a READ-ONLY mirror of the orchestrator's and
# @description the dispatcher's spool traffic for a shadow seat that posts
# @description nothing (owner, t1 ee1e58d5, 2026-10-11, msg f802ab00: "READ-ONLY
# @description access to a mirror of c-001/c-002/c-003's spool traffic (inbox,
# @description outbox, archive), refreshed every few minutes, with no write
# @description access to any spool dir and no desk seat ... Keep one safety:
# @description drop file attachments from the mirror").
# @description One pass: every message of SHADOW_FEED_AGENTS under SPOOL_ROOT
# @description becomes SHADOW_FEED_DIR/<box>/<agent>/<inbox|outbox|archive>/<file>,
# @description mode 0444, its `files` refs emptied (`files_dropped` = how many);
# @description a message gone from the spool is gone from the mirror. Each box
# @description in SHADOW_FEED_REMOTES is pulled first with rsync over ssh into a
# @description private stage (0700), then mirrored the same way; an unreachable
# @description box is a WARN and keeps its last mirror. Writes nothing under
# @description SPOOL_ROOT, refuses a feed dir inside it. SHADOW_FEED_DIR/LAST_RUN
# @description holds the time and counts of the last pass. Run it every few
# @description minutes with do_spl_shadow_feed_install_cron.
# @description Exit 0 (a WARN for an unreachable remote included), 1 a failed pass, 2 usage.
# @param SHADOW_FEED_DIR (optional) - default /var/spool-shadow, outside SPOOL_ROOT
# @param SHADOW_FEED_AGENTS (optional) - default "c-001 c-002 c-003"
# @param SHADOW_FEED_REMOTES (optional) - "<box>=<ssh host>[:<spool root>] ...", default none
# @param SHADOW_FEED_STAGE (optional) - the remote stage, default $HOME/.cache/csi-spl/shadow-feed-stage
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param BOX (optional) - this box's name; default SPOOL_BOX_TAG, box.env, hostname -s
# @example ./run -a do_spl_shadow_feed
# @example SHADOW_FEED_REMOTES="box-b=box-b.example.net" ./run -a do_spl_shadow_feed
#------------------------------------------------------------------------------
do_spl_shadow_feed() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" feed="${SHADOW_FEED_DIR:-/var/spool-shadow}"
  local agents="${SHADOW_FEED_AGENTS:-c-001 c-002 c-003}" stage="${SHADOW_FEED_STAGE:-$HOME/.cache/csi-spl/shadow-feed-stage}"
  local py="$PROJ_PATH/src/bash/scripts/spl-shadow-feed.py" box a r rbox rhost rroot out rc=0 sum=""
  local -a ids=()
  read -ra ids <<<"$agents"
  (( ${#ids[@]} )) || { do_log "FATAL SHADOW_FEED_AGENTS is empty"; return 2; }
  for a in "${ids[@]}"; do
    [[ "$a" =~ ^[a-z]-[0-9]{3,}$ ]] || { do_log "FATAL SHADOW_FEED_AGENTS: '$a' is not an agent id (c-001)"; return 2; }
  done
  box="$(spl_box_state_box)" || return 2
  case "$(realpath -m "$feed")/" in "$(realpath -m "$root")"/*)
    do_log "FATAL the feed $feed is inside the spool root $root: the seat must never read the spool"; return 2 ;; esac
  mkdir -p "$feed" 2>/dev/null && [[ -w "$feed" ]] || {
    do_log "FATAL cannot write $feed: create it once with: sudo install -d -o $USER -m 0755 $feed"; return 1; }
  chmod 0755 "$feed" 2>/dev/null || true
  out="$(python3 "$py" "$root" "$feed/$box" "${ids[@]}")" || { do_log "FATAL the mirror of $box failed: $out"; return 1; }
  echo "$box $out"; sum="$box ${out#OK shadow feed }"
  for r in ${SHADOW_FEED_REMOTES:-}; do
    rbox="${r%%=*}"; rhost="${r#*=}"; rroot="$root"
    [[ "$rhost" == *:* ]] && { rroot="${rhost#*:}"; rhost="${rhost%%:*}"; }
    [[ "$r" == *=* && "$rbox" =~ ^[a-z0-9][a-z0-9-]{0,39}$ && -n "$rhost" ]] || {
      do_log "FATAL SHADOW_FEED_REMOTES: '$r' is not <box>=<ssh host>[:<spool root>]"; return 2; }
    if ! spl_shadow_feed_pull "$rhost" "$rroot" "$stage/$rbox" "${ids[@]}"; then
      echo "WARN $rbox ($rhost) is unreachable: its mirror keeps the last pass"; continue
    fi
    out="$(python3 "$py" "$stage/$rbox" "$feed/$rbox" "${ids[@]}")" || { do_log "FATAL the mirror of $rbox failed: $out"; rc=1; continue; }
    echo "$rbox $out"; sum="$sum; $rbox ${out#OK shadow feed }"
  done
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$sum" >"$feed/.LAST_RUN.tmp" && chmod 0444 "$feed/.LAST_RUN.tmp" && mv -f "$feed/.LAST_RUN.tmp" "$feed/LAST_RUN"
  return "$rc"
}

# spl_shadow_feed_pull <ssh host> <remote spool root> <stage dir> <agent>...:
# ONE rsync over ssh of the agents' inbox/outbox/archive message files into
# the stage, which only this user can read (it holds the attachment refs
# until the mirror drops them). -k follows an <id> -> <id>@<box> dir symlink;
# an agent the far box does not have is simply absent. A failed pull leaves
# the stage as it was.
spl_shadow_feed_pull() {
  local host="$1" rroot="$2" stage="$3" a; shift 3
  local -a filt=()
  for a in "$@"; do
    filt+=("--include=/$a/" "--include=/$a/inbox/" "--include=/$a/outbox/" "--include=/$a/archive/"
      "--include=/$a/*/*.json" "--include=/$a/*/*.md")
  done
  mkdir -p "$stage" && chmod 0700 "${stage%/*}" "$stage" || return 1
  timeout 300 rsync -a -k --delete "${filt[@]}" --exclude='*' \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$host:$rroot/" "$stage/" 2>/dev/null
}
