#!/bin/bash
#------------------------------------------------------------------------------
# @description The box file follower of spec 160 (row B1, F1): follows the
# @description allow-listed files of this box (cnf env.box.file_streams.allow)
# @description with tail -F semantics, masks every line (spool_redact plus the
# @description PEM state) before it is queued, and pushes the queued lines as
# @description file_streams_push frames until the hub acks them. It runs
# @description src/bash/scripts/file-stream-follow.py as the box's agent user
# @description (spl_cost_agent_users, never root): one long-lived process per
# @description box under flock (a second start exits 0) that exits after run_s
# @description (1 h); the minute cron row file-streams starts it again. The
# @description deny list (spec 160 3.2) is in the follower and wins over the
# @description allow-list. Off while cnf env.box.file_streams.enabled is not
# @description true: one INFO line, nothing followed.
# @param FILE_STREAMS_ENABLED (optional) - true | false; default the cnf
# @param   env.box.file_streams.enabled (false until row B2 is on master)
# @param FILE_STREAMS_TICKS (optional) - run N ticks, then exit; default the
# @param   long-lived loop
# @param FILE_STREAMS_PUSH (optional) - 1 (default) push, 0 queue only
# @param FILE_STREAMS_PUSH_CMD (optional) - one push command for ONE follower
# @param   (tests, a by-hand run); default one follower per hub below
# @param FILE_STREAMS_HUBS (optional) - the hub envs fed, space separated;
# @param   default box.env FILE_STREAMS_HUBS (the cron line carries no env:
# @param   owner poll 5a85c2c1, sat feeds prd only until its dev desk is
# @param   pinned), else the cnf env.box.file_streams.hubs (owner HUM-10,
# @param   poll 38eeb655: BOTH, dev and prd). Each env has its own follower, state
# @param   dir <state>/<env> and queue, so a line one hub acked still waits
# @param   for the other. The push rides the box's desk of that env, as the
# @param   token burn does: `timeout 20 <desk state>/bin/spool file-streams
# @param   push --json -` with the desk's keys, box id, tenant and the env's
# @param   hub (https://<cnf <env>.env.json env.dns.api_fqdn>), run as the
# @param   desk user. A hub with no desk on this box: one FATAL line, the
# @param   other hubs still run
# @param FILE_STREAMS_DESK_USER (optional) - default box.env SPOOL_DESK_USER,
# @param   else the owner of the spool root
# @param FILE_STREAMS_DESK_STATE (optional) - the desk state root, %ENV% for
# @param   the env; default <desk user home>/.local/share/<org-app>/cloud/%ENV%
# @param FILE_STREAMS_TENANT (optional) - default box.env SPOOL_FLEET_TENANT, else t1
# @param FILE_STREAMS_AGENT_USER (optional) - default the first
# @param   spl_cost_agent_users user
# @param FILE_STREAMS_STUCK_MARGIN_S (optional) - seconds past run_s before
# @param   the cron row's cron-no-stack.sh lock calls the follower stuck;
# @param   default 600 (spl_file_stream_stuck_max)
# @param FILE_STREAMS_CNF (optional) - default csi-spl-cnf/csi-spl/all.env.yaml
# @param FILE_STREAMS_FOLDERS (optional) - the folders a web glob may reach
# @param   (spec 160 3.8.2), a JSON list; default box.env FILE_STREAMS_FOLDERS
# @param   (paths, space separated: the box narrows or replaces the list),
# @param   else the cnf env.box.file_streams.folders. The globs themselves are
# @param   pulled from each hub by its follower (3.8.5), every cnf globs_s
# @param FILE_STREAMS_CONSOLE_TMUX (optional) - the JSON argv of tmux for a
# @param   lane's console (spec 153 3.18); default the box user's server
# @param   (box.env SPOOL_BOX_USER, else the spool root's owner), through
# @param   sudo -n -u when the agent user differs
# @param FILE_STREAMS_CONSOLE_SOCKET (optional) - default /tmp/tmux-<uid>/default
# @param FILE_STREAMS_STATE_DIR (optional) - default the agent user's
# @param   $HOME/.local/state/csi-spl/file-streams, or .../csi-spl-file-streams
# @param   when that user cannot write the csi-spl dir (plus /<env> per hub)
# @example ./run -a do_spl_file_stream_follow
# @example FILE_STREAMS_ENABLED=true FILE_STREAMS_TICKS=1 FILE_STREAMS_PUSH=0 ./run -a do_spl_file_stream_follow
#------------------------------------------------------------------------------

declare -F spl_cost_agent_users >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"
declare -F spl_desk_box_default >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"
declare -F spl_cron_no_stack_declare_max >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-lock.func.sh"

do_spl_file_stream_follow() {
  local orc cnf on user py
  local -a envs=()
  orc="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  cnf="${FILE_STREAMS_CNF:-$orc/../csi-spl-cnf/csi-spl/all.env.yaml}"
  py="$orc/src/bash/scripts/file-stream-follow.py"
  on="${FILE_STREAMS_ENABLED:-$(spl_file_stream_cnf "$cnf" enabled false)}"
  if [[ "$on" != true ]]; then
    echo "INFO file-streams: off (cnf env.box.file_streams.enabled is not true): nothing followed"
    return 0
  fi
  [[ -f "$py" ]] || { echo "FATAL file-streams: no follower at $py"; return 1; }
  spl_file_stream_env "$cnf" || return 1
  spl_file_stream_stuck_max || return 1
  user="${FILE_STREAMS_AGENT_USER:-$(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}" | sed -n 1p)}"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "FATAL file-streams: bad agent user '$user'"; return 1; }
  [[ "$user" != root ]] || { echo "FATAL file-streams: the agent user is root: refused"; return 1; }
  envs+=("FILE_STREAMS_CONSOLE_TMUX=$(spl_file_stream_console_tmux "$user")")
  local args=()
  [[ -n "${FILE_STREAMS_TICKS:-}" ]] && args=(--ticks "$FILE_STREAMS_TICKS")
  if [[ "${FILE_STREAMS_PUSH:-1}" == 0 || -n "${FILE_STREAMS_PUSH_CMD:-}" ]]; then
    local cmd=""
    [[ "${FILE_STREAMS_PUSH:-1}" == 0 ]] || cmd="$FILE_STREAMS_PUSH_CMD"
    spl_file_stream_run "$user" "$py" "FILE_STREAMS_PUSH_CMD=$cmd" -- "${args[@]}"
    return
  fi
  spl_file_stream_hubs "$cnf" "$user" "$py" "${args[@]}"
}

# spl_file_stream_stuck_max: the cron row's stuck threshold follows the run
# length the follower gets (SPL-4768): its FILE_STREAMS_RUN_S from envs (the
# env, else the cnf run_s; the follower's own default 3600 when neither) plus
# FILE_STREAMS_STUCK_MARGIN_S (default 600), declared on the cron-no-stack.sh
# lock. Without it every start after 1800 s of a healthy 3600 s run wrote a
# STUCK line (2475 on one box by 2026-11-04).
spl_file_stream_stuck_max() {
  local e run_s=3600 margin="${FILE_STREAMS_STUCK_MARGIN_S:-600}"
  for e in "${envs[@]}"; do [[ "$e" == FILE_STREAMS_RUN_S=* ]] && run_s="${e#*=}"; done
  [[ "$margin" =~ ^[0-9]+$ ]] || { echo "FATAL file-streams: FILE_STREAMS_STUCK_MARGIN_S must be a whole number, got: '$margin'"; return 1; }
  spl_cron_no_stack_declare_max "$(( 10#$run_s + 10#$margin ))"
}

# spl_file_stream_hubs <cnf> <user> <py> [args]: one follower per hub env,
# each with its own state dir and push; waits for all. A hub that is down is
# not an error: its follower logs push_rc=<n>, keeps the lines queued for the
# next tick and exits 0. Non-zero when a hub env is not dev or prd, a hub has
# no desk (that hub is not fed) or a follower exits non-zero (under ./run's
# pipefail); none of these stops the other hubs.
spl_file_stream_hubs() {
  local cnf="$1" user="$2" py="$3" e cmd base rc=0 hubs
  shift 3
  local -a pids=()
  hubs="${FILE_STREAMS_HUBS:-$(spl_file_stream_boxenv FILE_STREAMS_HUBS)}"
  [[ -n "${hubs// /}" ]] || hubs="$(yq -r '.env.box.file_streams.hubs // [] | join(" ")' "$cnf" 2>/dev/null)"
  [[ -n "${hubs// /}" ]] || { echo "FATAL file-streams: no hub env (box.env FILE_STREAMS_HUBS and cnf env.box.file_streams.hubs are empty)"; return 1; }
  base="${FILE_STREAMS_STATE_DIR:-$(spl_file_stream_state_base "$user")}"
  for e in $hubs; do
    [[ "$e" =~ ^(dev|prd)$ ]] || { echo "FATAL file-streams: hub env '$e' is not dev or prd"; rc=1; continue; }
    cmd="$(spl_file_stream_hub_cmd "$cnf" "$e" "$user")" || { echo "$cmd"; rc=1; continue; }
    spl_file_stream_run "$user" "$py" "FILE_STREAMS_PUSH_CMD=$cmd" "FILE_STREAMS_STATE_DIR=$base/$e" -- "$@" 2>&1 |
      sed -u "s/^/hub=$e /" &
    pids+=("$!")
  done
  for e in "${pids[@]}"; do wait "$e" || rc=1; done
  return "$rc"
}

# spl_file_stream_state_base <user> [<home>]: the default state dir, under
# the agent user's home. .local/state/csi-spl is shared with other tools and
# may belong to another user (one box: root:root, so every tick failed on its
# mkdir, SPL-4037): a dir the user cannot write gets a sibling of its own.
spl_file_stream_state_base() {
  local user="$1" home="${2:-$(getent passwd "$1" | cut -d: -f6)}" s p
  s="$home/.local/state"
  for p in "$s/csi-spl/file-streams" "$s/csi-spl"; do
    spl_file_stream_as "$user" test -e "$p" || continue
    if spl_file_stream_as "$user" test -w "$p"; then echo "$s/csi-spl/file-streams"; else echo "$s/csi-spl-file-streams"; fi
    return 0
  done
  echo "$s/csi-spl/file-streams"
}

# spl_file_stream_as <user> <cmd>...: <cmd> as <user> (sudo only when it differs).
spl_file_stream_as() {
  local user="$1"; shift
  if [[ "$user" == "$(id -un)" ]]; then "$@"; else sudo -n -u "$user" "$@"; fi
}

# spl_file_stream_run <user> <py> <env=val>... -- [args]: the follower as the
# agent user, with the caller's envs plus the given ones.
spl_file_stream_run() {
  local user="$1" py="$2"; shift 2
  local -a more=()
  while [[ $# -gt 0 && "$1" != -- ]]; do more+=("$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  if [[ "$user" == "$(id -un)" ]]; then
    env "${envs[@]}" "${more[@]}" python3 "$py" "$@"
  else
    sudo -n -H -u "$user" env "${envs[@]}" "${more[@]}" python3 "$py" "$@"
  fi
}

# spl_file_stream_boxenv <key>: one value of the box's spool box.env.
spl_file_stream_boxenv() {
  local f="${SPOOL_BOX_ENV:-${SPOOL_LIVE_ROOT:-/var/spool-hub}/box.env}" k v
  [[ "${SPOOL_TEST:-}" == 1 && -z "${SPOOL_BOX_ENV:-}" ]] && return 0
  [[ -r "$f" ]] || return 0
  while IFS='=' read -r k v || [[ -n "$k" ]]; do
    [[ "$k" == "$1" ]] || continue
    v="${v%$'\r'}"; v="${v#[\"\']}"; v="${v%[\"\']}"
    printf '%s' "$v"
  done <"$f"
}

# spl_file_stream_hub_cmd <cnf> <env> <agent user>: prints the push command
# the agent user runs (sudo to the desk user when they differ) through the
# box's desk of <env>; a missing desk, binary or hub: prints one FATAL line,
# non-zero. A bare `spool` is never called (under sudo, secure_path has none).
spl_file_stream_hub_cmd() {
  local cnf="$1" e="$2" au="$3" du root d bin fqdn tenant box oa as=""
  du="${FILE_STREAMS_DESK_USER:-$(spl_file_stream_boxenv SPOOL_DESK_USER)}"
  du="${du:-$(stat -c %U "${SPOOL_ROOT:-/var/spool-hub}" 2>/dev/null)}"
  [[ "$du" =~ ^[a-z_][a-z0-9_-]*$ && "$du" != root ]] || { echo "FATAL file-streams: hub=$e: bad desk user '$du'"; return 1; }
  oa="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)")"
  root="${FILE_STREAMS_DESK_STATE:-$(getent passwd "$du" | cut -d: -f6)/.local/share/${oa%-orc}/cloud/%ENV%}"
  root="${root//%ENV%/$e}"
  tenant="${FILE_STREAMS_TENANT:-$(spl_file_stream_boxenv SPOOL_FLEET_TENANT)}"
  tenant="${tenant:-t1}" box="$(spl_desk_box_default)"
  d="$root/desk/$tenant/$box" bin="$root/bin/spool"
  fqdn="$(jq -r '.env.dns.api_fqdn // ""' "$(dirname "$cnf")/$e.env.json" 2>/dev/null)"
  [[ "$fqdn" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "FATAL file-streams: hub=$e: no env.dns.api_fqdn in $(dirname "$cnf")/$e.env.json"; return 1; }
  [[ "$du" == "$au" ]] || as="sudo -n -u $du "
  if ! spl_cost_as "$du" test -x "$bin" || ! spl_cost_as "$du" test -d "$d/keys"; then
    echo "FATAL file-streams: hub=$e: no desk keys $d/keys or spool $bin for $du: this hub is not fed"
    return 1
  fi
  printf '%senv SPOOL_ROOT=%q SPOOL_KEYS_DIR=%q SPOOL_BOX_ID=%q SPOOL_HUB_URL=%q SPOOL_TENANT=%q timeout 20 %q file-streams push --json -' \
    "$as" "$d/spool" "$d/keys" "$box" "https://$fqdn" "$tenant" "$bin"
}

# spl_file_stream_console_tmux <agent user>: the JSON argv that runs tmux on
# the agents' server for a lane's console (spec 153 3.18, lane_console.py):
# env FILE_STREAMS_CONSOLE_TMUX wins; else the box user's (box.env
# SPOOL_BOX_USER, else the owner of the spool root, as spool-env.inc.sh)
# socket /tmp/tmux-<uid>/default, through `sudo -n -u <box user>` when the
# follower runs as another user.
spl_file_stream_console_tmux() {
  local au="$1" bu sock
  if [[ -n "${FILE_STREAMS_CONSOLE_TMUX:-}" ]]; then printf '%s' "$FILE_STREAMS_CONSOLE_TMUX"; return 0; fi
  bu="$(spl_file_stream_boxenv SPOOL_BOX_USER)"
  bu="${bu:-$(stat -c %U "${SPOOL_ROOT:-/var/spool-hub}" 2>/dev/null)}"
  [[ "$bu" =~ ^[a-z_][a-z0-9_-]*$ && "$bu" != root ]] || bu="$au"
  sock="${FILE_STREAMS_CONSOLE_SOCKET:-/tmp/tmux-$(id -u "$bu" 2>/dev/null || id -u)/default}"
  if [[ "$bu" == "$au" ]]; then
    jq -n -c --arg s "$sock" '["tmux", "-S", $s]'
  else
    jq -n -c --arg u "$bu" --arg s "$sock" '["sudo", "-n", "-u", $u, "tmux", "-S", $s]'
  fi
}

# spl_file_stream_cnf <cnf> <key> <default>: one scalar of env.box.file_streams.
spl_file_stream_cnf() {
  local v
  v="$(yq -r ".env.box.file_streams.$2 // \"\"" "$1" 2>/dev/null)"
  printf '%s' "${v:-$3}"
}

# spl_file_stream_folders <cnf>: the allowed folders of web globs (spec 160
# 3.8.2) as a JSON list: env FILE_STREAMS_FOLDERS (JSON), else box.env
# FILE_STREAMS_FOLDERS (space separated; the box's own file, never written
# from the hub), else the cnf. The follower checks every entry itself.
spl_file_stream_folders() {
  local v
  if [[ -n "${FILE_STREAMS_FOLDERS:-}" ]]; then printf '%s' "$FILE_STREAMS_FOLDERS"; return 0; fi
  v="$(spl_file_stream_boxenv FILE_STREAMS_FOLDERS)"
  if [[ -n "${v// /}" ]]; then
    printf '%s' "$v" | jq -R -c 'split(" ") | map(select(length > 0))'
    return 0
  fi
  v="$(yq -o json -I0 '.env.box.file_streams.folders // []' "$1" 2>/dev/null)"
  printf '%s' "${v:-[]}"
}

# spl_file_stream_env <cnf>: fill the caller's envs array, the follower's
# FILE_STREAMS_* settings from the cnf (an env var of the same name wins).
spl_file_stream_env() {
  local cnf="$1" k v allow extra="" r
  local -A keys=([START_LINES]=start_lines [TICK_S]=tick_s [RUN_S]=run_s [PEM_MAX_LINES]=pem_max_lines
    [LINE_BYTES]=line_bytes [RATE_PER_MIN]=rate_per_min [QUEUE_MAX]=queue_max [MAX]=max_streams
    [GLOBS_S]=globs_s [GLOBS_STALE_S]=globs_stale_s [GLOB_SCAN_S]=glob_scan_s [GLOB_SCAN_MAX]=glob_scan_max)
  for k in "${!keys[@]}"; do
    v="FILE_STREAMS_$k"; v="${!v:-$(spl_file_stream_cnf "$cnf" "${keys[$k]}" "")}"
    [[ -z "$v" ]] && continue
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "FATAL file-streams: $k must be a whole number, got: '$v'"; return 1; }
    envs+=("FILE_STREAMS_$k=$v")
  done
  allow="${FILE_STREAMS_ALLOW:-$(yq -o json -I0 '.env.box.file_streams.allow // []' "$cnf" 2>/dev/null)}"
  envs+=("FILE_STREAMS_ALLOW=${allow:-[]}")
  envs+=("FILE_STREAMS_FOLDERS=$(spl_file_stream_folders "$cnf")")
  # The deny list's extra roots: the cnf spool root and workspace bases,
  # and the desk dir of SPL_STATE_DIR (spec 160 3.2).
  for k in spool_root workspace_base fleet_workspace_base; do
    r="$(yq -r ".env.box.$k // \"\"" "$cnf" 2>/dev/null)"
    [[ -n "$r" ]] && extra+="${extra:+:}$r"
  done
  [[ -n "${SPL_STATE_DIR:-}" ]] && extra+="${extra:+:}$SPL_STATE_DIR/desk"
  # every root a desk may live in (spl_desk_roots: the desk user's too)
  while IFS=$'\t' read -r _ r; do
    [[ -n "$r" && "$r" != "${SPL_STATE_DIR:-}" ]] && extra+="${extra:+:}$r/desk"
  done < <(spl_desk_roots 2>/dev/null)
  envs+=("FILE_STREAMS_DENY_EXTRA=$extra")
  [[ -n "${FILE_STREAMS_STATE_DIR:-}" ]] && envs+=("FILE_STREAMS_STATE_DIR=$FILE_STREAMS_STATE_DIR")
  # cron sets no SPOOL_ROOT: end on success, not on that test's status
  [[ -n "${SPOOL_ROOT:-}" ]] && envs+=("SPOOL_ROOT=$SPOOL_ROOT")
  return 0
}
