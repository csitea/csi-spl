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
# @description   3. its GAP rows and the subscribe's DEAD lines form the gap
# @description      set, kept in <spool root>/dispatch/gaps.<env>. Only a
# @description      CHANGE is reported: a "DISPATCH gap" line per new item, a
# @description      "DISPATCH cleared" line per gone one, and ONE spool note
# @description      (task dispatch-gaps) to the orchestrator when a new GAP
# @description      row appears. DEAD lines are logged, never sent: agents
# @description      exit all day
# @description A no-op while <spool root>/dispatch/lease.conf is absent (the
# @description dispatcher opt-in, as do_spl_dispatch_lease ensure). Every
# @description line meant for the cron log starts with "DISPATCH "; a quiet
# @description tick prints none. Exit 1 only when the subscribe failed.
# @param ENV - required: dev or prd
# @param DISPATCH_* (optional) - as do_spl_dispatch_subscribe / do_spl_dispatch_check
# @param DISPATCH_TICK_NOTE (optional) - 0 sends no note (the log lines stay)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=prd ./run -a do_spl_dispatch_tick
#------------------------------------------------------------------------------
do_spl_dispatch_tick() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  spl_lease_init ro || return 1
  [[ -f "$LEASE_CONF" ]] || return 0
  local tmp rc=0 f="$LEASE_DIR/gaps.$ENV" line
  tmp="$(mktemp -d)" || return 1
  if ! ( DRY_RUN=0 do_spl_dispatch_subscribe ) >"$tmp/sub" 2>&1; then
    rc=1
    echo "DISPATCH subscribe FAILED ($ENV):"
    sed 's/^/DISPATCH   /' "$tmp/sub"
  fi
  sed -n 's/^PLAN /DISPATCH subscribe /p' "$tmp/sub"
  # the gap feed is OFF until its check resolves the dispatcher worktrees
  # outside the running checkout (2026-10-01: false GAPs from the cron tree)
  [[ "${DISPATCH_TICK_GAPS:-0}" == 1 ]] || { rm -rf "$tmp"; return $rc; }
  # one DEAD item per agent, so one agent's exit is one new item
  sed -n 's/^DEAD \([^ ]*\) \(#[^ ]*\) \(.*\) (no live process.*/\1 \2|\3/p' "$tmp/sub" |
    while IFS='|' read -r where ids; do
      for a in $ids; do echo "DEAD $where $a"; done
    done >"$tmp/gaps"
  ( DISPATCH_CHECK_SUBS=0 do_spl_dispatch_check ) >"$tmp/check" 2>&1
  # "| what | value | GAP ... |" -> "GAP what: verdict (value)"; the value
  # (an age, a count) is not part of the item, or every tick would be new
  awk -F' [|] ' '$3 ~ /^GAP/ { v = $3; sub(/ [|]$/, "", v); w = $1; sub(/^[|] /, "", w); print "GAP " w ": " v " (" $2 ")" }' \
    "$tmp/check" >>"$tmp/gaps"
  sort -u -o "$tmp/gaps" "$tmp/gaps"
  _spl_dispatch_tick_keys <"$tmp/gaps" >"$tmp/new.keys"
  [[ -f "$f" ]] && _spl_dispatch_tick_keys <"$f" >"$tmp/old.keys" || : >"$tmp/old.keys"
  if ! cmp -s "$tmp/new.keys" "$tmp/old.keys"; then
    comm -23 "$tmp/new.keys" "$tmp/old.keys" >"$tmp/added"
    comm -13 "$tmp/new.keys" "$tmp/old.keys" | sed 's/^/DISPATCH cleared /'
    while IFS= read -r line; do
      grep -F -- "$line" "$tmp/gaps" | head -1 | sed 's/^/DISPATCH gap /'
    done <"$tmp/added"
    if grep -q '^GAP ' "$tmp/added" && [[ "${DISPATCH_TICK_NOTE:-1}" != 0 ]]; then
      _spl_dispatch_tick_note "$tmp" || echo "DISPATCH WARN could not send the gap note"
    fi
    cp "$tmp/gaps" "$f.tmp" && mv -f "$f.tmp" "$f" || echo "DISPATCH WARN cannot write $f"
  fi
  rm -rf "$tmp"
  return $rc
}

# The identity of a gap item: the line without its "(value)" tail.
_spl_dispatch_tick_keys() {
  sed 's/ ([^()]*)$//' | sort -u
}

# ONE note to the orchestrator: the new GAP items, then the whole gap set.
_spl_dispatch_tick_note() {
  local tmp="$1" org_app send bin
  spl_lease_conf
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  send="${DISPATCH_TICK_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  bin="${SPOOL_BIN:-$HOME/.local/share/$org_app/cloud/$ENV/bin/spool}"
  [[ -x "$bin" ]] || bin=spool
  {
    echo "**dispatch gaps ($ENV)**: new since the last desk tick"
    echo
    grep -F -f "$tmp/added" "$tmp/gaps" | grep '^GAP ' | sed 's/^GAP /- /'
    echo
    echo "All open ($(wc -l <"$tmp/gaps")): \`ENV=$ENV ./run -a do_spl_dispatch_check\` shows them."
  } >"$tmp/note"
  SPOOL_BIN="$bin" SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "${LEASE_ORCH:-CLE-001}" \
    --to "${LEASE_ORCH:-CLE-001}" --kind note --task dispatch-gaps --body-file "$tmp/note" >/dev/null 2>&1 8>&- 9>&- || return 1
  echo "DISPATCH told ${LEASE_ORCH:-CLE-001}"
}
