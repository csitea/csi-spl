#!/bin/bash
#------------------------------------------------------------------------------
# @description The cross-box Claude login failover's mode (SPL-5695; owner
# @description HUM-10 t1 64ca0e0c msgs 1147c760 and 5ff9dea1; design
# @description csi-spl-doc/specs/060-role-rotation/claude-account-failover.md
# @description section 4.2): is this box on its OWN account (the agent user's
# @description main login) or on its BACKUP (the second folder, which holds
# @description the other box's account, kept by do_spl_agent_login2_sync)?
# @description Run inside every do_spl_agent_login_check tick (no cron row of
# @description its own). Writes <login-check state>/login-mode (format:
# @description lib/bash/funcs/spl-claude-login.func.sh), which new seats and
# @description rotations read (spawn-core); nothing is killed on a change.
# @description   own -> backup: the own weekly % at or over the claude mark
# @description     (spl_box_quota_max: task 8's mark, no second cutoff), the
# @description     backup's % (the BOX-0 row whose acct= is the backup's
# @description     label, not itself on backup) under it, its probe ok.
# @description     Else hold: stay own, one alert (Q2: never move onto an
# @description     account whose % is unknown).
# @description   backup -> own: the own label changed (the owner swapped it),
# @description     the own reset passed, a fresh own % under back_below_pct;
# @description     forced: the backup probes expired or limited, no fresh peer
# @description     row carries its label, or it reached the mark.
# @description One alert to the dispatch lease holder per change and per hold,
# @description keyed on (mode, own label, backup label). Labels only.
# @description Plans only (no file, no alert) unless cnf
# @description env.box.claude_login_pool.enabled is true AND DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LOGIN_MODE_ENABLED (optional) - true|false, overrides cnf env.box.claude_login_pool.enabled (false)
# @param LOGIN_MODE_BACK_PCT (optional) - overrides cnf env.box.claude_login_pool.back_below_pct (85)
# @param CLAUDE2_CONFIG_DIR (optional) - the second folder, default <agent home>/.claude-2
# @param LOGIN_STATE_DIR (optional) - default /var/csi/csi-spl/agent-login-check
# @param LOGIN_PROBE_EVERY (optional) - s between probes of the backup login, default 300
# @param LOGIN_MODE_OWN_JSON (optional, tests) - the main login's .claude.json in place of the agent user's
# @param LOGIN_MODE_ROWS_CMD (optional, tests) - prints the fleet's lane rows in place of the hub read
# @param LOGIN_MODE_HERE (optional, tests) - this box's tag
# @param LOGIN_NOW (optional, tests) - the epoch of now
# @example ./run -a do_spl_claude_login_mode
# @example LOGIN_MODE_ENABLED=true DRY_RUN=0 ./run -a do_spl_claude_login_mode
#------------------------------------------------------------------------------
_lm_deps() {
  local d; d="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  declare -F spl_claude_login_mode_line >/dev/null || source "$d/../../../lib/bash/funcs/spl-claude-login.func.sh"
  declare -F spl_box_quota_cache_read >/dev/null || source "$d/../../../lib/bash/funcs/spl-box-quota.func.sh"
  declare -F _lc_alert_to >/dev/null || source "$d/spl-agent-login-check.func.sh"
  declare -F _spool_box_env_load >/dev/null || source "$d/../features/spawn-agents/lib/spool-env.inc.sh"
}

do_spl_claude_login_mode() {
  local dry="${DRY_RUN:-1}" cnf on mark back home
  _lm_deps
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  cnf="${LOGIN_CNF:-$PROJ_PATH/../$(basename "$PROJ_PATH" -orc)-cnf/$(basename "$PROJ_PATH" -orc)/all.env.yaml}"
  on="${LOGIN_MODE_ENABLED:-$(yq -r '.env.box.claude_login_pool.enabled // false' "$cnf" 2>/dev/null)}"
  back="${LOGIN_MODE_BACK_PCT:-$(yq -r '.env.box.claude_login_pool.back_below_pct // 85' "$cnf" 2>/dev/null)}"
  mark="$(spl_box_quota_max "$cnf" claude)"
  [[ "$back" =~ ^[0-9]{1,3}$ ]] || back=85
  [[ -n "${SPOOL_AGENT_USER:-}" ]] || SPOOL_AGENT_USER="$(SPOOL_AGENT_USER=''; _spool_box_env_load; printf '%s' "${SPOOL_AGENT_USER:-}")"
  home="${LOGIN_AGENT_HOME:-$(getent passwd "${SPOOL_AGENT_USER:-$(id -un)}" | cut -d: -f6)}"
  LM_STATE="$(spl_claude_login_state_dir)"; LM_NOW="${LOGIN_NOW:-$(date +%s)}"
  LM_DIR2="${CLAUDE2_CONFIG_DIR:-$home/.claude-2}"
  LM_CRED="${LOGIN_CRED_CMD:-bash $PROJ_PATH/src/bash/scripts/agent-login-cred.sh}"
  mkdir -p "$LM_STATE" 2>/dev/null || { do_log "FATAL cannot create $LM_STATE"; return 1; }
  _lm_read_prev
  _lm_read_own
  _lm_read_backup
  _lm_decide "$mark" "$back"
  _lm_apply "$dry" "$on"
}

# The previous line (any age): LM_PMODE, LM_POWN, LM_PRESET.
_lm_read_prev() {
  LM_PMODE=own; LM_POWN=-; LM_PRESET=-
  local at="" m="" o="" r=""
  read -r at m o _ _ r _ 2>/dev/null <"$LM_STATE/login-mode" || return 0
  [[ "$m" == backup ]] && LM_PMODE=backup
  LM_POWN="${o:--}"; LM_PRESET="${r:--}"
}

# The own login: LM_OWN (label), LM_OPCT and LM_ORESET from the CLI's cached
# usage in the main login's .claude.json (spl_box_quota_cache_read).
_lm_read_own() {
  local json r u
  if [[ -n "${LOGIN_MODE_OWN_JSON:-}" ]]; then json="$(cat "$LOGIN_MODE_OWN_JSON" 2>/dev/null)"; else json="$(spl_box_quota_claude_json)"; fi
  u="$(jq -r '.oauthAccount.accountUuid // empty' <<<"$json" 2>/dev/null)"
  LM_OWN=-; [[ -n "$u" ]] && LM_OWN="acct-$(printf '%s' "$u" | sha256sum | cut -c1-8)"
  r="$(BOX_QUOTA_RESET=1 spl_box_quota_cache_read "$LM_NOW" <<<"$json")"
  LM_OPCT=-; LM_ORESET=-
  [[ "$r" =~ ^([0-9]{1,3})@([0-9]+)$ ]] && { LM_OPCT="${BASH_REMATCH[1]}"; LM_ORESET="${BASH_REMATCH[2]}"; }
  return 0
}

# The backup: LM_BACK (label of the second folder), LM_BROW (ok | none |
# backup: the peer row carrying that label), LM_BPCT (its claude %).
_lm_read_backup() {
  local rows here row
  LM_BACK="$(LOGIN_CRED_DIR2="$LM_DIR2" $LM_CRED acct 2 2>/dev/null | sed -n 1p)"
  [[ "$LM_BACK" =~ ^acct-[0-9a-f]{8}$ ]] || LM_BACK=-
  LM_BROW=none; LM_BPCT=-
  [[ "$LM_BACK" == - ]] && return 0
  here="$(_lm_here)"
  rows="$(_lm_rows)"
  row="$(jq -r --arg l "$LM_BACK" --arg here "$here" --argjson max "${LANE_BOX_ROW_MAX_S:-3600}" '
    [(.lanes // [])[] | select(.agent_id == "BOX-0" and .state == "live" and (.age_s // -1) >= 0 and .age_s < $max)
      | select(.agent_box != $here and ((.scope // "") | test("(^| )acct=" + $l + "( |$)")))]
    | min_by(.age_s) // empty | "\(.agent_box) \((.scope // "") | test("(^| )lm=backup( |$)"))"' <<<"${rows:-{\}}" 2>/dev/null)"
  [[ -n "$row" ]] || return 0
  [[ "${row#* }" == true ]] && { LM_BROW=backup; return 0; }
  LM_BROW=ok
  LM_BPCT="$(spl_box_quota_from_rows "$rows" BOX-0 "${LANE_BOX_ROW_MAX_S:-3600}" claude | jq -r --arg b "${row%% *}" '.[$b] // "-"')"
}

_lm_here() {
  [[ -n "${LOGIN_MODE_HERE:-}" ]] && { echo "$LOGIN_MODE_HERE"; return 0; }
  declare -F ai_tag >/dev/null || source "$PROJ_PATH/src/bash/features/spawn-agents/lib/agent-identity.inc.sh"
  ai_tag
}

_lm_rows() {
  if [[ -n "${LOGIN_MODE_ROWS_CMD:-}" ]]; then bash -c "$LOGIN_MODE_ROWS_CMD"; return 0; fi
  declare -F spl_lane_init >/dev/null || source "$PROJ_PATH/src/bash/run/spl-lane-map.func.sh"
  spl_lane_init >/dev/null 2>&1 && [[ "$LANE_MODE" == hub ]] && spl_lane_hub --fleet "$LANE_FLEET" 2>/dev/null
  return 0
}

# The backup login's probe verdict, cached LOGIN_PROBE_EVERY s in <state>/probe2.
_lm_probe2() {
  local at="" v="" every="${LOGIN_PROBE_EVERY:-300}"
  read -r at v _ 2>/dev/null <"$LM_STATE/probe2"
  if [[ "$at" =~ ^[0-9]+$ && -n "$v" ]] && (( at <= LM_NOW && LM_NOW - at < every )); then echo "$v"; return 0; fi
  v="$(LOGIN_CRED_DIR2="$LM_DIR2" $LM_CRED probe 2 2>/dev/null | sed -n 1p)"; v="${v%% *}"
  printf '%s %s\n' "$LM_NOW" "${v:-unknown}" >"$LM_STATE/probe2" 2>/dev/null || true
  echo "${v:-unknown}"
}

# Sets LM_MODE, LM_WHY and LM_HOLD (1 = at the mark, the backup unusable).
_lm_decide() {
  local mark="$1" back="$2" pv
  LM_HOLD=0
  if [[ "$LM_PMODE" == backup ]]; then _lm_decide_backup "$mark" "$back"; return; fi
  LM_MODE=own
  if [[ "$LM_OPCT" == - ]] || (( LM_OPCT < mark )); then LM_WHY="own at ${LM_OPCT}% (mark $mark)"; return 0; fi
  LM_HOLD=1
  if [[ "$LM_BACK" == - ]]; then LM_WHY="hold: own at ${LM_OPCT}%, no backup login in the second folder"
  elif [[ "$LM_BROW" == backup ]]; then LM_WHY="hold: own at ${LM_OPCT}%, the backup account's box is itself on backup"
  elif [[ "$LM_BPCT" == - ]]; then LM_WHY="hold: own at ${LM_OPCT}%, no reading of the backup account"
  elif (( LM_BPCT >= mark )); then LM_WHY="hold: own at ${LM_OPCT}%, backup at ${LM_BPCT}%"
  elif pv="$(_lm_probe2)"; [[ "$pv" != ok ]]; then LM_WHY="hold: own at ${LM_OPCT}%, the backup login probes $pv"
  else LM_MODE=backup; LM_HOLD=0; LM_WHY="own at ${LM_OPCT}%, backup at ${LM_BPCT}%"; fi
}

_lm_decide_backup() {
  local mark="$1" back="$2" pv
  LM_MODE=own
  # a reset carried from the line before when the own reading is gone
  [[ "$LM_ORESET" == - && "$LM_POWN" == "$LM_OWN" ]] && LM_ORESET="$LM_PRESET"
  if [[ "$LM_OWN" != "$LM_POWN" ]]; then LM_WHY="the own account changed ($LM_POWN -> $LM_OWN)"
  elif pv="$(_lm_probe2)"; [[ "$pv" == expired || "$pv" == limited ]]; then LM_WHY="forced: the backup login probes $pv"
  elif [[ "$LM_BROW" != ok ]]; then LM_WHY="forced: no fresh peer row carries the backup account $LM_BACK ($LM_BROW)"
  elif [[ "$LM_BPCT" != - ]] && (( LM_BPCT >= mark )); then LM_WHY="the backup reached ${LM_BPCT}% (mark $mark)"
  elif [[ "$LM_ORESET" =~ ^[0-9]+$ ]] && (( LM_NOW >= LM_ORESET )); then LM_WHY="the own reset passed"
  elif [[ "$LM_OPCT" != - ]] && (( LM_OPCT < back )); then LM_WHY="own at ${LM_OPCT}% (under $back)"
  else LM_MODE=backup; LM_WHY="own at ${LM_OPCT}%, backup at ${LM_BPCT}%"; fi
}

# Print the verdict; with the pool on and DRY_RUN=0 write the line and alert
# once per (mode, own label, backup label) on a change or a hold.
_lm_apply() {
  local dry="$1" on="$2" line key last=""
  line="$LM_MODE $LM_OWN $LM_BACK $LM_OPCT $LM_ORESET $LM_BPCT $LM_DIR2 $LM_WHY"
  if [[ "$on" != true || "$dry" == 1 ]]; then
    echo "login-mode: PLAN $LM_PMODE -> $LM_MODE ($LM_WHY; own $LM_OWN, backup $LM_BACK)$([[ "$on" != true ]] && echo ' (claude_login_pool.enabled is false)')$([[ "$dry" == 1 ]] && echo ' (DRY_RUN)')"
    return 0
  fi
  printf '%s %s\n' "$LM_NOW" "$line" >"$LM_STATE/login-mode.tmp" && mv -f "$LM_STATE/login-mode.tmp" "$LM_STATE/login-mode" ||
    { do_log "FATAL cannot write $LM_STATE/login-mode"; return 1; }
  echo "login-mode: $LM_PMODE -> $LM_MODE ($LM_WHY; own $LM_OWN, backup $LM_BACK)"
  if (( LM_HOLD )); then key="hold $LM_OWN $LM_BACK"
  elif [[ "$LM_MODE" != "$LM_PMODE" ]]; then key="$LM_MODE $LM_OWN $LM_BACK"
  else return 0; fi
  read -r last 2>/dev/null <"$LM_STATE/login-mode.alert"
  [[ "$key" == "$last" ]] && return 0
  printf '%s\n' "$key" >"$LM_STATE/login-mode.alert"
  _lm_alert "$(_lm_alert_text)"
}

_lm_alert_text() {
  local tag; tag="$(_lm_here)"
  if (( LM_HOLD )); then printf '**login-mode@%s**: claude stays on its own account %s, %s.' "${tag:-box}" "$LM_OWN" "${LM_WHY#hold: }"
  else printf '**login-mode@%s**: claude %s -> %s (own %s %s%%, backup %s %s%%): %s.' "${tag:-box}" "$LM_PMODE" "$LM_MODE" "$LM_OWN" "$LM_OPCT" "$LM_BACK" "$LM_BPCT" "$LM_WHY"; fi
}

_lm_alert() {
  local to send="${LOGIN_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  LC_TAG="$(_lm_here)"; to="$(_lc_alert_to)"
  SPOOL_ROOT="$SPOOL_ROOT" SPOOL_ASKS=0 bash "$send" --from "$(_lc_alert_from)" --to "$to" --kind note \
    --task "${LOGIN_ALERT_TASK:-dispatch-sat-login}" --no-ask --body "$1" >/dev/null 2>&1 ||
    { do_log "WARN the login-mode alert to $to was not sent"; return 0; }
  echo "ALERT sent to $to"
}
