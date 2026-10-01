#!/bin/bash
#------------------------------------------------------------------------------
# @description The dispatchers' per-tick upkeep, called by the desk reconcile
# @description cron (desk-reconcile-cron.sh, every tick, dev and prd). On
# @description 2026-10-01 two channels created after the morning's
# @description do_spl_dispatch_subscribe reached nobody until it was re-run by
# @description hand (owner: "the pulling mechanism should work for all the
# @description tenants"). So every tick:
# @description   1. do_spl_dispatch_subscribe DRY_RUN=0 over every workspace:
# @description      a new channel gets both dispatchers on the next tick. One
# @description      read per workspace in one proxy session; nothing is written
# @description      when nothing changed
# @description   2. do_spl_dispatch_check DISPATCH_CHECK_SUBS=0 (local only:
# @description      processes, seats, lease, loops, sweep; no second DB read)
# @description   3. its GAP rows, the subscribe's DEAD lines and its SILENT /
# @description      UNSIGNED lines (a workspace whose people post and whose
# @description      dispatchers receive nothing, CLE-77876) form the gap
# @description      set, kept in <spool root>/dispatch/gaps.<env>.state with the time
# @description      each item was first seen. Only a CHANGE is reported: a
# @description      "DISPATCH gap" line per new item, "DISPATCH cleared" per
# @description      gone one. On prd a new GAP row is ONE spool note (task
# @description      dispatch-gaps) to the lease holder, and a GAP still open
# @description      DISPATCH_GAP_ESCALATE s later goes to the orchestrator,
# @description      once. Dev gaps and DEAD lines (agents exit all day) are
# @description      logged, never sent. Test workspaces are left out
# @description      (spl_test_workspaces, the sweep's list)
# @description A no-op while <spool root>/dispatch/lease.conf is absent (the
# @description dispatcher opt-in, as do_spl_dispatch_lease ensure). Every
# @description line meant for the cron log starts with "DISPATCH "; a quiet
# @description tick prints none. Exit 1 only when the subscribe failed.
# @param ENV - required: dev or prd
# @param DISPATCH_* (optional) - as do_spl_dispatch_subscribe / do_spl_dispatch_check
# @param DISPATCH_TICK_GAPS (optional) - 0 turns steps 2 and 3 off, default 1
# @param DISPATCH_TICK_NOTE (optional) - 0 sends no note (the log lines stay); default 1 on prd, 0 on dev
# @param DISPATCH_GAP_ESCALATE (optional) - seconds a GAP stays open before the orchestrator is told, default 3600
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=prd ./run -a do_spl_dispatch_tick
#------------------------------------------------------------------------------
do_spl_dispatch_tick() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  spl_lease_init ro || return 1
  [[ -f "$LEASE_CONF" ]] || return 0
  local tmp rc=0 f="$LEASE_DIR/gaps.$ENV.state"
  tmp="$(mktemp -d)" || return 1
  if ! ( DRY_RUN=0 do_spl_dispatch_subscribe ) >"$tmp/sub" 2>&1; then
    rc=1
    echo "DISPATCH subscribe FAILED ($ENV):"
    sed 's/^/DISPATCH   /' "$tmp/sub"
  fi
  sed -n 's/^PLAN /DISPATCH subscribe /p' "$tmp/sub"
  [[ "${DISPATCH_TICK_GAPS:-1}" == 1 ]] || { rm -rf "$tmp"; return $rc; }
  # one DEAD item per agent, so one agent's exit is one new item
  sed -n 's/^DEAD \([^ ]*\) \(#[^ ]*\) \(.*\) (no live process.*/\1 \2|\3/p' "$tmp/sub" |
    while IFS='|' read -r where ids; do
      for a in $ids; do echo "DEAD $where $a"; done
    done >"$tmp/gaps"
  # CLE-77876: humans post, the dispatchers receive nothing; the counts are
  # the value, so one silent workspace stays one item while it lasts
  sed -n 's/^SILENT \([^ ]*\) \([^:]*\): \(.*\)$/GAP \1 inbound: \3 (\2)/p; s/^UNSIGNED \([^ ]*\) \([^,]*\), \(.*\)$/GAP \1 unsigned posts: \3 (\2)/p' \
    "$tmp/sub" >>"$tmp/gaps"
  ( DISPATCH_CHECK_SUBS=0 do_spl_dispatch_check ) >"$tmp/check" 2>&1
  # "| what | value | GAP ... |" -> "GAP what: verdict (value)"; the value
  # (an age, a count) is not part of the item's identity
  awk -F' [|] ' '$3 ~ /^GAP/ { v = $3; sub(/ [|]$/, "", v); w = $1; sub(/^[|] /, "", w); print "GAP " w ": " v " (" $2 ")" }' \
    "$tmp/check" >>"$tmp/gaps"
  sort -u -o "$tmp/gaps" "$tmp/gaps"
  [[ -f "$f" ]] || : >"$tmp/old"
  [[ -f "$f" ]] && cp "$f" "$tmp/old"
  NOW="${DISPATCH_NOW:-$(date +%s)}" ESC="${DISPATCH_GAP_ESCALATE:-3600}" ENVN="$ENV" OUT="$tmp" awk '
    function key(l) { sub(/ \([^()]*\)$/, "", l); return l }
    FILENAME == ARGV[1] { split($0, p, "|"); l = substr($0, length(p[1]) + length(p[2]) + 3)
                k = key(l); ts[k] = p[1]; esc[k] = p[2]; next }
    { k = key($0); seen[k] = 1
      if (k in ts) { t = ts[k]; e = esc[k] } else { t = ENVIRON["NOW"]; e = 0; print > (ENVIRON["OUT"] "/added") }
      if ($0 ~ /^GAP / && ENVIRON["ENVN"] == "prd" && e == 0 && ENVIRON["NOW"] - t >= ENVIRON["ESC"] + 0) {
        e = 1; print > (ENVIRON["OUT"] "/escalate") }
      print t "|" e "|" $0 > (ENVIRON["OUT"] "/state") }
    END { for (k in ts) if (!(k in seen)) print k > (ENVIRON["OUT"] "/cleared") }
  ' "$tmp/old" "$tmp/gaps"
  touch "$tmp/state" "$tmp/added" "$tmp/escalate" "$tmp/cleared"
  if [[ -s "$tmp/added" || -s "$tmp/escalate" || -s "$tmp/cleared" ]]; then
    sort "$tmp/cleared" | sed 's/^/DISPATCH cleared /'
    sed 's/^/DISPATCH gap /' "$tmp/added"
    sed 's/^/DISPATCH still open after '"${DISPATCH_GAP_ESCALATE:-3600}"'s: /' "$tmp/escalate"
    if [[ "${DISPATCH_TICK_NOTE:-$([[ "$ENV" == prd ]] && echo 1 || echo 0)}" == 1 ]]; then
      spl_lease_conf
      grep '^GAP ' "$tmp/added" >"$tmp/new.gap"
      [[ -s "$tmp/new.gap" ]] && { _spl_dispatch_tick_note "$(_spl_dispatch_tick_holder)" "new since the last desk tick" "$tmp/new.gap" "$tmp" ||
        echo "DISPATCH WARN could not send the gap note"; }
      [[ -s "$tmp/escalate" ]] && { _spl_dispatch_tick_note "${LEASE_ORCH:-CLE-001}" "open for over ${DISPATCH_GAP_ESCALATE:-3600}s" "$tmp/escalate" "$tmp" ||
        echo "DISPATCH WARN could not send the escalation"; }
    fi
    cp "$tmp/state" "$f.tmp" && mv -f "$f.tmp" "$f" || echo "DISPATCH WARN cannot write $f"
  fi
  rm -rf "$tmp"
  return $rc
}

# The lease holder, else the master in lease.conf, else the orchestrator. A
# holder on another machine (fleet mode) cannot read this spool: the gaps of
# THIS machine go to its own orchestrator.
_spl_dispatch_tick_holder() {
  spl_lease_read
  if spl_lease_remote; then echo "${LEASE_ORCH:-CLE-001}"
  elif [[ "$LH" != none ]]; then spl_lease_holder_id
  elif [[ -n "${LEASE_MASTER:-}" ]]; then echo "$LEASE_MASTER"
  else echo "${LEASE_ORCH:-CLE-001}"; fi
}

# _spl_dispatch_tick_note <to> <why> <items file> <tmp>: ONE spool note.
_spl_dispatch_tick_note() {
  local to="$1" why="$2" items="$3" tmp="$4" org_app send bin
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  send="${DISPATCH_TICK_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  bin="${SPOOL_BIN:-$HOME/.local/share/$org_app/cloud/$ENV/bin/spool}"
  [[ -x "$bin" ]] || bin=spool
  {
    echo "**dispatch gaps ($ENV)**: $why"
    echo
    sed 's/^GAP /- /' "$items"
    echo
    echo "Open GAP rows: $(grep -c '^GAP ' "$tmp/gaps"). \`ENV=$ENV ./run -a do_spl_dispatch_check\` shows them."
  } >"$tmp/note"
  SPOOL_BIN="$bin" SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "${LEASE_ORCH:-CLE-001}" \
    --to "$to" --kind note --task dispatch-gaps --body-file "$tmp/note" >/dev/null 2>&1 8>&- 9>&- || return 1
  echo "DISPATCH told $to"
}
