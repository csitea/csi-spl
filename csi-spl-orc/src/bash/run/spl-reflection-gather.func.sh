#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_reflection_gather - the night's reflection (spec 166 row
# @description B8, section 3.3; owner HUM-10, t1 c0b0d572 msg 421e479a:
# @description "internal reflections ... starting from 20:00 till 07:00 CET";
# @description poll d102c775 Q4 A: a Qto doc page per day in the system
# @description workspace, never git, the repo is public). It gathers the last
# @description 24 h mechanically, no tokens:
# @description   1. CI reds per job (csi-spl-iac do_report_ci_gate, its failed
# @description      runs created in the window),
# @description   2. reverts on master (git log --grep='^Revert' in the window),
# @description   3. lanes that ended without landing (issues ended diss),
# @description   4. the owner's messages in the lease's workspace, ids only (a
# @description      READ ONLY hub DB read as the env's project service account),
# @description   5. the class share and the last 24 h share (do_spl_spawn_share),
# @description   6. the zombie count (the last summary line of row B6's log),
# @description into one file under the spool root (REFLECTION_DIR), and queues
# @description ONE lane (class refactor, kind specs_and_docs) whose brief,
# @description rendered from features/dispatch/brief-reflection.tpl.md, carries
# @description that file, its Epic: and Spec: lines, and asks for the day's Qto
# @description page plus at most 3 proposed rows. The ask goes through
# @description do_spl_spawn_enqueue and its gates. A source that cannot be read
# @description is one "(not read: ...)" line, never a stop. Nothing is written
# @description to git. The vendor is do_spl_lane_mix with LANE_MIX_SENSITIVE=1:
# @description the owner's messages may carry private matter (data rule).
# @description It acts only (section 4.4) in phase night (do_spl_rhythm_phase,
# @description no hour arithmetic here), only on the box of the dispatch lease
# @description holder, and once a night (a stamp holding the night's date, as
# @description row B6 names it: spl_zombie_night). REFLECTION_FORCE=1 skips
# @description those three. DRY_RUN=1 (default) writes the gathered file,
# @description prints the brief and queues nothing; switching it off on a box is
# @description the orchestrator holder's call (REFLECTION_DRY_RUN=0 in the
# @description dispatch lease.conf, read by reflection-cron.sh).
# @param ENV (optional) - dev or prd; default the lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - the workspace whose owner messages are read; default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - the issue desk agent; default the dispatch lease holder's id
# @param REFLECTION_FORCE (optional) - 1 runs now, whatever the phase, box or stamp
# @param REFLECTION_STATE (optional) - the stamp file, default $XDG_STATE_HOME/csi-spl/reflection.last
# @param REFLECTION_DIR (optional) - the gathered files, default <spool root>/dispatch/reflection
# @param REFLECTION_REPO (optional) - the git checkout whose origin/master is read; default APP_PATH
# @param REFLECTION_REF (optional) - default origin/master (fetched first, unless REFLECTION_FETCH=0)
# @param REFLECTION_ZOMBIE_LOG (optional) - default /var/csi/csi-spl/zombie-topics/cron.log
# @param REFLECTION_TPL (optional) - the brief template, default features/dispatch/brief-reflection.tpl.md
# @param REFLECTION_MIX_CMD (optional, tests) - prints the lane mix (gets LANE_MIX_KIND, LANE_MIX_SENSITIVE)
# @param SPAWN_PLACE_BRIEF_DIR (optional) - where the brief goes, default <spool root>/dispatch/briefs
# @param RHYTHM_NOW RHYTHM_CNF (optional) - as do_spl_rhythm_phase (tests: the moment judged, the window's end)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_reflection_gather
# @example REFLECTION_FORCE=1 ./run -a do_spl_reflection_gather
# @example REFLECTION_FORCE=1 DRY_RUN=0 ./run -a do_spl_reflection_gather
#------------------------------------------------------------------------------
# Test seams: the readers spl_reflection_ci_report, spl_reflection_owner_msgs,
# spl_reflection_ended_read, spl_reflection_share_line and the hub's ask put
# (spl_asks_hub) are functions a test replaces.

declare -F spl_zombie_night >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-zombie-topics.func.sh"

do_spl_reflection_gather() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 night holder until since dir gather brief
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  if [[ "${REFLECTION_FORCE:-0}" != 1 ]]; then
    night="$(spl_reflection_gate "$root" "$holder")" || return 0
  else
    night="$(spl_zombie_night)" || { do_log "FATAL reflection: the night could not be named"; return 1; }
  fi
  export ENV="${ENV:-$(spl_owner_digest_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_owner_digest_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  until="$(date -u -d "${RHYTHM_NOW:-now}" +%s)" || { do_log "FATAL reflection: RHYTHM_NOW is not a date"; return 1; }
  since=$((until - 86400))
  dir="${REFLECTION_DIR:-$root/dispatch/reflection}"
  gather="$dir/$night.md"
  mkdir -p "$dir" && spl_reflection_gather_md "$since" "$until" "$night" >"$gather" ||
    { do_log "FATAL reflection: the gathered file $gather was not written"; return 1; }
  echo "OK reflection: gathered $gather ($(grep -c '^- ' "$gather") item line(s))"
  brief="$(mktemp)" || return 1
  spl_reflection_brief "$night" "$gather" "$since" "$until" >"$brief" || { rm -f "$brief"; return 1; }
  local rc=0
  if ((dry)); then
    echo "PLAN reflection: would queue reflection-$night (refactor, specs_and_docs) with this brief:"
    cat "$brief"
  else
    spl_reflection_queue "$night" "$brief" "$root" || rc=1
  fi
  rm -f "$brief"
  ((rc == 0)) || return 1
  mkdir -p "$(dirname "$(spl_reflection_state)")" && printf '%s\n' "$night" >"$(spl_reflection_state)" ||
    do_log "WARN reflection: cannot write the stamp $(spl_reflection_state)"
  return 0
}

spl_reflection_state() {
  echo "${REFLECTION_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/reflection.last}"
}

# spl_reflection_gate <root> <holder>: the night's date on stdout when this
# tick acts (night, the holder's box, not yet this night); else one OK line, rc 1.
spl_reflection_gate() {
  local root="$1" holder="$2" phase box hbox night
  phase="$(do_spl_rhythm_phase)" || { echo "OK reflection: the rhythm phase could not be read: nothing this tick" >&2; return 1; }
  [[ "$phase" == night ]] || { echo "OK reflection: phase $phase: the reflection runs at night only" >&2; return 1; }
  [[ "$holder" =~ ^[A-Za-z][A-Za-z0-9-]*(@[a-z0-9][a-z0-9-]*)?$ ]] ||
    { echo "OK reflection: no dispatch lease holder in $root/dispatch/lease: nothing" >&2; return 1; }
  box="$(spl_owner_digest_box "$root")"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  [[ "$hbox" == "$box" ]] || { echo "OK reflection: the dispatch holder $holder is not on this box ($box); its box reflects" >&2; return 1; }
  night="$(spl_zombie_night)" || return 1
  [[ "$(cat "$(spl_reflection_state)" 2>/dev/null)" != "$night" ]] ||
    { echo "OK reflection: already ran in the night of $night" >&2; return 1; }
  echo "$night"
}

# spl_reflection_iso <epoch>: 2026-01-15T19:30:00Z.
spl_reflection_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# spl_reflection_gather_md <since> <until> <night>: the gathered file, markdown.
spl_reflection_gather_md() {
  local s="$1" u="$2" si ui out
  si="$(spl_reflection_iso "$s")"; ui="$(spl_reflection_iso "$u")"
  printf '# Reflection gather, night of %s\n\nWindow: %s .. %s (the last 24 h). Gathered by do_spl_reflection_gather (spec 166 row B8); never git.\n' "$3" "$si" "$ui"
  printf '\n## 1. CI reds per job (failed runs created in the window)\n\n'
  if out="$(spl_reflection_ci_report 2>&1)"; then spl_reflection_ci_reds "$si" "$ui" <<<"$out"; else echo "(not read: do_report_ci_gate failed: $(tail -1 <<<"$out" | cut -c1-200))"; fi
  printf '\n## 2. Reverts on master\n\n'
  spl_reflection_reverts "$si" "$ui"
  printf '\n## 3. Lanes ended without landing (issues ended diss)\n\n'
  if out="$(spl_reflection_ended_read 2>/dev/null)"; then spl_reflection_ended "$si" "$ui" <<<"$out"; else echo "(not read: the diss issues were not listed)"; fi
  printf '\n## 4. The owner'"'"'s messages in %s (ids only)\n\n' "${TENANT_ID:-?}"
  if out="$(spl_reflection_owner_msgs "$s" "$u" 2>/dev/null)"; then
    awk -F'\t' 'NF >= 3 { printf "- msg %s, topic %s, %s\n", $1, $2, $3; n++ } END { if (!n) print "(none)" }' <<<"$out"
  else
    echo "(not read: the hub DB read failed)"
  fi
  printf '\n## 5. Class share\n\n'
  if out="$(spl_reflection_share_line 2>/dev/null)" && [[ -n "$out" ]]; then echo "$out"; else echo "(not read: do_spl_spawn_share failed)"; fi
  printf '\n## 6. Zombie sweep (row B6, its last summary)\n\n'
  out="$(grep -h 'OK zombie sweep, night of' "${REFLECTION_ZOMBIE_LOG:-/var/csi/csi-spl/zombie-topics/cron.log}" 2>/dev/null | tail -1)"
  echo "${out:-(no zombie sweep summary in the log)}"
}

# spl_reflection_ci_report: the CI gate report (csi-spl-iac), per job, with signatures.
spl_reflection_ci_report() {
  (cd "${APP_PATH:-.}/csi-spl-iac" && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 timeout 900 ./run -a do_report_ci_gate)
}

# spl_reflection_ci_reds <since iso> <until iso> < report: one line per red
# job of the report's "failed runs" list created in the window.
spl_reflection_ci_reds() {
  awk -v s="$1" -v u="$2" '
    /^== / { inr = ($0 ~ /^== failed runs, newest first/); next }
    inr && $1 ~ /^[0-9]+$/ && $2 >= s && $2 < u { sub(/^ +/, ""); print "- run " $0; n++ }
    END { if (!n) print "(none)" }'
}

# spl_reflection_reverts <since iso> <until iso>: the reverts on REFLECTION_REF.
spl_reflection_reverts() {
  local repo="${REFLECTION_REPO:-${APP_PATH:-.}}" ref="${REFLECTION_REF:-origin/master}" out
  if [[ "${REFLECTION_FETCH:-1}" != 0 && "$ref" == origin/* ]]; then
    timeout 120 git -c safe.directory='*' -C "$repo" fetch -q origin "${ref#origin/}" </dev/null >/dev/null 2>&1 ||
      echo "(fetch failed: $ref as of the last fetch)"
  fi
  out="$(git -c safe.directory='*' -C "$repo" log "$ref" --since="$1" --until="$2" --grep='^Revert' --format='- %h %cI %s' 2>&1)" ||
    { echo "(not read: git log $ref: $(tail -1 <<<"$out" | cut -c1-200))"; return 0; }
  echo "${out:-(none)}"
}

# spl_reflection_ended_read: one page of diss issues, newest update first.
spl_reflection_ended_read() {
  do_spl_desk_cnf >/dev/null 2>&1 || return 1
  spl_desk_issue_run list --status diss --sort updated --limit 200
}

# spl_reflection_ended <since iso> <until iso> < issues JSON: the ones ended in the window.
spl_reflection_ended() {
  jq -r --arg s "${1:0:19}" --arg u "${2:0:19}" '
    [((.result // .).issues // [])[]
     | ((if (.canceled_at // "") != "" then .canceled_at else (.updated_at // "") end) | .[0:19]) as $at
     | select($at >= $s and $at < $u)
     | "- \(.key) ended diss \($at)Z: \((.title // "") | gsub("[\r\n]"; " "))"]
    | if length == 0 then "(none)" else .[] end'
}

# spl_reflection_owner_msgs <since epoch> <until epoch>: msg_id, task_id,
# received_at (TSV) of the posts by an owner of TENANT_ID in the window, read
# as the env's project SA in a READ ONLY transaction, in a subshell.
spl_reflection_owner_msgs() {
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1
  (
    do_spl_cloud_cnf >/dev/null 2>&1 && do_gcp_pin_account "$SPL_CNF" >/dev/null 2>&1 || exit 1
    spl_via_proxy spl_reflection_owner_sql "$TENANT_ID" "$1" "$2"
  )
}

spl_reflection_owner_sql() {  # TENANT SINCE UNTIL
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v t="$1" -v since="$2" -v until="$3" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT m.msg_id, m.task_id, to_char(m.received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  FROM messages m
  JOIN tenant_memberships tm ON tm.tenant_id = m.tenant_id AND tm.human_id = m.from_id AND tm.role = 'owner'
 WHERE m.tenant_id = :'t' AND m.received_at >= to_timestamp(:since) AND m.received_at < to_timestamp(:until)
 ORDER BY m.received_at;
ROLLBACK;
SQL
}

# spl_reflection_share_line: the live share and the last 24 h share, one line.
spl_reflection_share_line() {
  local share
  spl_spawn_q_init >/dev/null 2>&1 && share="$(spl_spawn_share 2>/dev/null)" && spl_spawn_share_line "$share"
}

# spl_reflection_brief <night> <gather file> <since> <until>: the lane brief.
spl_reflection_brief() {
  local tpl="${REFLECTION_TPL:-$PROJ_PATH/src/bash/features/dispatch/brief-reflection.tpl.md}"
  [[ -r "$tpl" ]] || { do_log "FATAL reflection: no brief template $tpl"; return 1; }
  NIGHT="$1" GATHER_FILE="$2" SINCE="$(spl_reflection_iso "$3")" UNTIL="$(spl_reflection_iso "$4")" \
    python3 - "$tpl" <<'PY'
import os, sys
s = open(sys.argv[1], encoding="utf-8").read()
e = os.environ
gather = open(e["GATHER_FILE"], encoding="utf-8").read().rstrip("\n")
# the gathered file's own headings sit two levels below the brief's section
gather = "\n".join("##" + l if l.startswith("#") else l for l in gather.splitlines())
for k, v in {"NIGHT": e["NIGHT"], "SINCE": e["SINCE"], "UNTIL": e["UNTIL"],
             "GATHER_FILE": e["GATHER_FILE"], "GATHER": gather}.items():
    s = s.replace("{" + k + "}", v)
sys.stdout.write(s)
PY
}

# spl_reflection_vendor: the lane mix's pick for specs_and_docs on data that
# may be private (claude, grok or mistral only), or nothing.
spl_reflection_vendor() {
  local out v
  if [[ -n "${REFLECTION_MIX_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    out="$(LANE_MIX_KIND=specs_and_docs LANE_MIX_SENSITIVE=1 $REFLECTION_MIX_CMD 2>&1)"
  else
    out="$(LANE_MIX_KIND=specs_and_docs LANE_MIX_SENSITIVE=1 timeout 60 bash "$PROJ_PATH/run" -a do_spl_lane_mix 2>&1)"
  fi
  v="$(sed -nE 's/^pick=([a-z]+)( .*)?$/\1/p' <<<"$out" | tail -1)"
  [[ "$v" =~ ^(claude|grok|mistral)$ ]] && printf '%s' "$v"
  return 0
}

# spl_reflection_ask_id <night>: a UUID from its sha1, so a replay is the same ask.
spl_reflection_ask_id() {
  local h
  h="$(printf 'reflection:%s' "$1" | sha1sum | cut -c1-32)"
  printf '%s-%s-5%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

# spl_reflection_queue <night> <brief> <root>: the brief file, the ask, the enqueue.
spl_reflection_queue() {
  local night="$1" slug="reflection-$1" dir vendor id from out
  dir="${SPAWN_PLACE_BRIEF_DIR:-$3/dispatch/briefs}"
  spl_spawn_q_init || return 1
  vendor="$(spl_reflection_vendor)"
  [[ -n "$vendor" ]] || { do_log "WARN reflection: the lane mix gave no vendor for private data (claude, grok or mistral): not queued"; return 1; }
  { mkdir -p "$dir" && cp "$2" "$dir/$slug.md"; } || { do_log "WARN reflection: the brief $dir/$slug.md was not written: not queued"; return 1; }
  id="$(spl_reflection_ask_id "$night")"
  from="$(spl_spawn_place_dispatch)"; from="${from:-$(spl_asks_holder)}"
  out="$(spl_asks_hub put --fleet "$LANE_FLEET" --id "$id" --kind task --role orch --from "$from" \
    --topic "$slug" --summary "REFLECTION night of $night (refactor, specs_and_docs): the day's review page and at most 3 rows" 2>&1)" ||
    { do_log "WARN reflection: the hub did not take the ask: $(tail -1 <<<"$out" | cut -c1-200)"; return 1; }
  ASK_ID="$id" SPAWN_CLASS=refactor SPAWN_KIND=specs_and_docs SPAWN_PLACE="$vendor:$slug" ASK_BY="$(spl_asks_holder)" \
    SPAWN_URGENT=0 SPAWN_BYPASS='' do_spl_spawn_enqueue || { do_log "WARN reflection: the enqueue of $slug failed"; return 1; }
  echo "OK reflection: queued $slug as $vendor:$slug, ask ${id:0:8}"
}
