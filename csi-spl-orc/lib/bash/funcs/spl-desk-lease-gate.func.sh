#!/bin/bash
#------------------------------------------------------------------------------
# The new-topic lease gate of do_spl_desk_reply (SPL-3520, grade fix C; owner
# HUM-10, t1 99ffa592 answer msg ce2045be; grounds:
# csi-spl-doc/doc/md/grok-dispatch-grade-2026-10-25.md section 5: g-001,
# outside the lease, wrote 14 first replies, and three graded cases had two
# seats answering the same post).
#
# SPEC-spool-fleet-roles.md section 3: a new topic is the dispatch lease
# holder's, and the first agent reply in a topic makes its author the owner.
# So the FIRST agent reply in a topic is refused, for every vendor, unless the
# replying seat:
#   0. in a SOLE-SEAT channel (channel-rules map column 6, cr_sole_seat,
#      SPL-3542; e.g. a channel only one named seat posts in): is that seat.
#      Nobody else passes there, the lease holders included. Unknown (a map
#      column 6 that is not "<id>@<box>", a topic that cannot be read): refused

#   1. holds the dispatch lease right now (<lease dir>/lease, "<ID>[@<box>]",
#      the box compared with LEASE_MACHINE, else lease.conf, else this
#      machine's desk box id), or the orchestrator lease (lease.orch): the
#      3-minute backstop that then owns the topic
#   2. is a workspace seat in its own workspace: this box is claimed by the
#      reply's workspace (spec 108 3.5, spl_box_ws_claim)
#   3. is a channel seat of the topic's channel: its brief
#      (<spool root>/<id>/lifetime/brief.md) has `Channel: <tenant> #<ch>`
#      (SPL-3500) and the topic was posted in <ch> (hub-tail --with-channel);
#      a spool binary without --with-channel: <tenant> alone is matched
#   4. was addressed by the human: a HUM-* post in the topic is a DM to it
#      or names it (@<id>)
# A reply that is not the first (an agent already answered in the topic; the
# topic's owner answering again) is never refused here. The topic is read
# from this desk box (hub-tail): a reply from another machine's box may not
# be visible, which can only refuse, never let a second first reply through.
# The topic is read with hub-tail --with-channel (its envelope channel, "" = a
# DM), and with plain --json by a spool binary that lacks the flag: then the
# sole-seat rule cannot be checked (a WARN) and rule 3 matches the tenant.
# No lease file (a box without dispatchers): no gate. A hub-tail that fails:
# refused, the seat is not the holder and the holder can answer. Under
# SPOOL_TEST=1 with no SPOOL_ROOT the live lease is never read: no gate.
#------------------------------------------------------------------------------

declare -F spl_desk_box_default >/dev/null ||
  source "${BASH_SOURCE[0]%/*}/spl-desk-box.func.sh"
declare -F spl_box_ws_claim >/dev/null ||
  source "${BASH_SOURCE[0]%/*}/spl-box-workspace.func.sh"
# channel-rules.inc.sh is sourced on first use, never at load: a tree that
# copies lib/bash/funcs alone (the ./run framework tests) has no features dir.
SPL_DESK_LEASE_CR_LIB="${BASH_SOURCE[0]%/*}/../../../src/bash/features/spawn-agents/lib/channel-rules.inc.sh"

# spl_desk_lease_gate <state dir> <box> <tenant> <hub> <agent> <task>: 0 when
# <agent> may post in topic <task>, else 8 with the FATAL that names the lease
# holder and where the answer goes instead.
spl_desk_lease_gate() {
  local d="$1" box="$2" tenant="$3" hub="$4" agent="$5" task="$6"
  local dir="${SPOOL_ROOT:-/var/spool-hub}/dispatch" holder="" orch="" claim seat_ch
  local tail="" tail_read=0 tail_err="" ch_known=0 topic_ch=""
  [[ -z "${SPOOL_ROOT:-}" && "${SPOOL_TEST:-}" == 1 ]] && return 0
  [[ -s "$dir/lease" ]] || return 0
  read -r holder _ < "$dir/lease"
  [[ -s "$dir/lease.orch" ]] && read -r orch _ < "$dir/lease.orch"
  if [[ -z "$holder" || "$holder" == none* ]]; then
    do_log "WARN the dispatch lease names no holder ($dir/lease: '${holder:-}'): the new-topic lease gate is off for this reply"
    return 0
  fi
  # shellcheck source=../../../src/bash/features/spawn-agents/lib/channel-rules.inc.sh
  declare -F cr_channel_of >/dev/null || { [[ -r "$SPL_DESK_LEASE_CR_LIB" ]] && source "$SPL_DESK_LEASE_CR_LIB"; }
  # 0. a sole-seat channel: read the topic first, the holders do not pass there
  if declare -F cr_sole_seat >/dev/null && [[ -s "$(cr_map)" ]]; then
    _spl_desk_lease_tail || { _spl_desk_lease_unreadable; return 8; }
    _spl_desk_lease_sole
    case $? in 0) return 0 ;; 8) return 8 ;; esac
  fi
  spl_desk_lease_is "$agent" "$holder" "$dir" && return 0
  spl_desk_lease_is "$agent" "$orch" "$dir" && return 0
  claim="$(spl_box_ws_claim)"
  [[ -n "$claim" && "$claim" == "$tenant" ]] && return 0
  [[ "$tail_read" == 1 ]] || _spl_desk_lease_tail || { _spl_desk_lease_unreadable; return 8; }
  seat_ch="$(declare -F cr_channel_of >/dev/null && cr_channel_of "${SPOOL_ROOT:-/var/spool-hub}/$agent/lifetime/brief.md")"
  if [[ "$seat_ch" == "$tenant "* ]]; then
    [[ "$ch_known" == 1 ]] || return 0
    [[ "$seat_ch" == "$tenant $topic_ch" ]] && return 0
  fi
  [[ "$(spl_desk_lease_topic_verdict "$agent" <<<"$tail")" == first ]] || return 0
  do_log "FATAL nothing was sent: this would be the first agent reply in topic $task, and a new topic is the dispatch lease holder's ($holder), not $agent's (SPEC-spool-fleet-roles.md 3, SPL-3520). Leave it to $holder, or send it your answer: spool-send.sh --to $holder"
  return 8
}

# _spl_desk_lease_tail: the topic into the caller's tail, ch_known and
# topic_ch (dynamic scope). --with-channel first; a binary that lacks it is
# asked with plain --json (ch_known=0). 1 when the topic cannot be read.
_spl_desk_lease_tail() {
  local out rc=0
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-tail --task "$task" --with-channel 2>&1)" || rc=$?
  if (( rc != 0 )) && grep -q 'flag provided but not defined: -with-channel' <<<"$out"; then
    rc=0
    out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-tail --task "$task" --json 2>&1)" || rc=$?
    (( rc == 0 )) && ch_known=0
  elif (( rc == 0 )); then
    topic_ch="$(spl_desk_lease_topic_channel <<<"$out")" && ch_known=1
  fi
  if (( rc != 0 )); then tail_err="$out"; return 1; fi
  tail="$out" tail_read=1
}

# _spl_desk_lease_unreadable: the FATAL for a topic the gate cannot read.
_spl_desk_lease_unreadable() {
  do_log "FATAL nothing was sent: $agent does not hold the dispatch lease ($holder) and cannot read topic $task to prove this is not its first reply there: $(head -c 300 <<<"$tail_err"). Send the answer to the lease holder: spool-send.sh --to $holder (SPEC-spool-fleet-roles.md 3, SPL-3520)"
}

# _spl_desk_lease_sole: rule 0, on the caller's tail and topic_ch. 0 = the
# reply may go (the sole seat, or not a first reply); 8 = refused; 1 = no
# sole seat here (or not checkable): the other rules decide.
_spl_desk_lease_sole() {
  local sole rc=0
  if [[ "$ch_known" != 1 ]]; then
    do_log "WARN the sole-seat rule is not checked for topic $task: this spool binary has no hub-tail --with-channel (SPL-3542); rebuild it"
    return 1
  fi
  [[ -n "$topic_ch" ]] || return 1
  sole="$(cr_sole_seat "$tenant" "$topic_ch" 2>&1)" || rc=$?
  (( rc == 1 )) && return 1
  if (( rc != 0 )); then
    do_log "FATAL nothing was sent: cannot tell the sole seat of $tenant #$topic_ch, so no first reply goes there: $(head -c 300 <<<"$sole") (SPL-3542, SPL-3520)"
    return 8
  fi
  spl_desk_lease_is "$agent" "$sole" "$dir" && return 0
  [[ "$(spl_desk_lease_topic_verdict "$agent" <<<"$tail")" == first ]] || return 0
  do_log "FATAL nothing was sent: $tenant #$topic_ch has a sole seat, $sole, and this would be the first agent reply in topic $task; only $sole answers there, the lease holders included (SPL-3542, SPL-3520). Send it your answer: spool-send.sh --to $sole"
  return 8
}

# spl_desk_lease_topic_channel, hub-tail --with-channel NDJSON on stdin: the
# topic's channel ("" = a DM), from its first message; 1 when no line has one.
spl_desk_lease_topic_channel() {
  python3 -c '
import json, sys
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and isinstance(m.get("channel"), str):
        print(m["channel"])
        sys.exit(0)
sys.exit(1)'
}

# spl_desk_lease_is <agent> <lease holder "<ID>[@<box>]"> <lease dir>: 0 when
# the holder is <agent> on this machine (a bare id is any machine).
spl_desk_lease_is() {
  local agent="$1" h="$2" me
  [[ -n "$h" && "${h%@*}" == "$agent" ]] || return 1
  [[ "$h" == *@* ]] || return 0
  me="${LEASE_MACHINE:-}"
  [[ -z "$me" && -r "$3/lease.conf" ]] && me="$(sed -n 's/^LEASE_MACHINE=\([a-z0-9][a-z0-9-]*\)$/\1/p' "$3/lease.conf" | tail -n 1)"
  [[ "${h##*@}" == "${me:-$(spl_desk_box_default)}" ]]
}

# spl_desk_lease_topic_verdict <agent>, the topic's hub-tail NDJSON on stdin:
# "replied" when an agent already posted in it (not a HUM-* person, not an
# RSP-* responder), "addressed" when a person's post is a DM to <agent> or
# names @<agent>, else "first".
spl_desk_lease_topic_verdict() {
  python3 -c '
import json, re, sys
agent = sys.argv[1]
named = re.compile(r"(^|[^A-Za-z0-9_-])@" + re.escape(agent) + r"([^A-Za-z0-9_-]|$)")
addressed = False
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if not isinstance(m, dict):
        continue
    frm = str(m.get("from", ""))
    if not frm or frm.startswith("RSP-"):
        continue
    if not frm.startswith("HUM-"):
        print("replied")
        sys.exit(0)
    if str(m.get("to", "")).split("@")[0] == agent or named.search(str(m.get("body", ""))):
        addressed = True
print("addressed" if addressed else "first")' "$1"
}
