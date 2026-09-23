#!/usr/bin/env bash
# The notice strip carries BOTH directions: what an agent was sent, and what it
# sent. The owner's ask, 2026-09-22 - "all the post and replies ... read them
# from the right pane".
#
# The premise this suite was written against, measured in this same sandbox on
# 2026-09-22 (n=1) BEFORE the change: one `spool-send.sh --from CLE-90 --to
# CLE-91` left NEITHER agent with a .pokes/notices.log. spool_poke_show is
# reached only through scripts/spool-notify.sh, which the binary runs on
# delivery, and spool-send.sh runs the binary with SPOOL_NOTIFY_CMD=off. So the
# local peer path - the one two agents on one box actually use - recorded
# nothing at all, in either direction.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/spool-notify.inc.sh"
. "$T_FEAT/lib/spool-poke-queue.inc.sh"
spool_env_resolve

# ── the two heads ───────────────────────────────────────────────────────────
eq "an inbound head is unchanged" \
  "SPOOL CLE-91: note from CLE-90 task T-1 msg M-1" \
  "$(spool_notice_head_in CLE-91 note CLE-90 T-1 M-1)"
eq "an outbound head names the PEER, not the sender's own id" \
  "SPOOL -> CLE-91: note task T-1 msg M-1" \
  "$(spool_notice_head_out CLE-91 note T-1 M-1)"
# The marker is the SEVENTH column. A distinction that arrives after the ids is
# one a reader scanning a 48-column strip meets too late, and it is the one that
# has to survive NO_COLOR.
eq "the direction marker sits at column 7" "->" \
  "$(spool_notice_head_out CLE-91 note '' '' | cut -c7-8)"
# An inbound head can never be mistaken for one: <id> matches ^[A-Z]{2,4}-[0-9]+$.
hasnt "an inbound head never begins with the arrow" "SPOOL -> " \
  "$(spool_notice_head_in CLE-91 note CLE-90 '' '')"

# ── the renderer tells them apart, with colour and without ──────────────────
t_tmux
log="$T_TMP/two-way.log"
printf 'SPOOL CLE-90: note from CLE-91\tthey said this\n'  >"$log"
printf 'SPOOL -> CLE-91: note\twe said that\n'            >>"$log"

PC="$(t_window two-way-colour "exec $T_SCRIPTS/spool-notice-pane.sh --log $log")"
sleep 1
screen="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -e -t "$PC")"
has "an INBOUND head is still blue"    "$(printf '\033[38;5;39m')"  "$screen"
has "an OUTBOUND head is a THIRD colour" "$(printf '\033[38;5;114m')" "$screen"
has "…and its body too"                "$(printf '\033[38;5;108m')" "$screen"
has "both texts are on screen"         "we said that"               "$screen"

# NO_COLOR is the control: the colour is the fast path, the ARROW is the
# distinction that always works. A test that only asserted the escape would
# pass while the strip was unreadable for anyone who sets NO_COLOR.
PN="$(t_window two-way-nc "NO_COLOR=1 exec $T_SCRIPTS/spool-notice-pane.sh --log $log")"
sleep 1
plain="$(tmux -S "$SPOOL_TMUX_SOCKET" capture-pane -p -e -t "$PN")"
hasnt "NO_COLOR drops every escape"        "$(printf '\033[')"   "$plain"
has   "…and the outbound record is STILL marked" "SPOOL -> CLE-91" "$plain"
has   "…beside the inbound one"            "SPOOL CLE-90:"        "$plain"

# ── a real send records both sides, once each ───────────────────────────────
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
P90="$(t_window CLE-90 'sleep 600')"
P91="$(t_window CLE-91 'sleep 600')"
printf 'CLE-90\tclaude\t%s\t/x\t20260101T000000Z\n' "$P90" >> "$SPOOL_ROOT/registry.tsv"
printf 'CLE-91\tclaude\t%s\t/x\t20260101T000000Z\n' "$P91" >> "$SPOOL_ROOT/registry.tsv"

SPOOL_SHOW_PANE=1 bash "$SS" --from CLE-90 --to CLE-91 --kind task --body 'ping from 90' >/dev/null 2>&1
eq "the send succeeded" 0 "$?"
log90="$(spool_poke_queue_dir CLE-90)/notices.log"
log91="$(spool_poke_queue_dir CLE-91)/notices.log"
check "the SENDER now has a notices log at all" test -s "$log90"
check "the RECIPIENT has one too"               test -s "$log91"
eq "the sender's log holds exactly ONE record"    1 "$(wc -l <"$log90")"
eq "the recipient's holds exactly ONE - not two"  1 "$(wc -l <"$log91")"
has "the sender's record is OUTBOUND"  "SPOOL -> CLE-91: task" "$(cat "$log90")"
has "the recipient's record is INBOUND" "SPOOL CLE-91: task from CLE-90" "$(cat "$log91")"
has "both carry the body" "ping from 90" "$(cat "$log90")$(cat "$log91")"

# The reply closes the loop: each column now reads as a conversation, and each
# message appears once on each side, never twice on either.
SPOOL_SHOW_PANE=1 bash "$SS" --from CLE-91 --to CLE-90 --kind result --body 'pong from 91' >/dev/null 2>&1
eq "the sender's column now holds both directions" 2 "$(wc -l <"$log90")"
eq "…and so does the peer's"                       2 "$(wc -l <"$log91")"
eq "the reply appears ONCE in the replier's column" 1 "$(grep -c 'pong from 91' "$log91")"
eq "…and ONCE in the original sender's"             1 "$(grep -c 'pong from 91' "$log90")"
has "the replier's copy is outbound" "SPOOL -> CLE-90: result" "$(cat "$log91")"
has "…and the peer's is inbound"     "SPOOL CLE-90: result from CLE-91" "$(cat "$log90")"

# --no-poke is about the recipient's PROMPT. The strip injects nothing - it is
# the surface the safe-poke rule deliberately does not gate - so silencing it
# here would drop the record and buy none of the safety.
SPOOL_SHOW_PANE=1 bash "$SS" --from CLE-90 --to CLE-91 --kind note --body 'quiet one' --no-poke >/dev/null 2>&1
eq "--no-poke still records the sender's copy" 1 "$(grep -c 'quiet one' "$log90")"
eq "…and the recipient's"                      1 "$(grep -c 'quiet one' "$log91")"

# SPOOL_SHOW=0 turns the visible half off entirely, this half included.
SPOOL_SHOW=0 bash "$SS" --from CLE-90 --to CLE-91 --kind note --body 'invisible one' >/dev/null 2>&1
eq "SPOOL_SHOW=0 records nothing for the sender"  0 "$(grep -c 'invisible one' "$log90")"
eq "…nor for the recipient"                       0 "$(grep -c 'invisible one' "$log91")"


# The strip body is the WUI body. The shell cleaner rewrites apostrophes so a
# poke line stays inside single quotes; that rewrite must not reach the column
# a person reads.
SPOOL_SHOW_PANE=1 bash "$SS" --from CLE-90 --to CLE-91 --kind note --body "it's the same words" >/dev/null 2>&1
eq "the strip keeps the apostrophe" 1 "$(grep -c "it's the same words" "$log90")"
eq "…and does not rewrite it" 0 "$(grep -c 'it"s the same words' "$log90")"

# A strip the sender already had is ADOPTED, never split twice: the at-spawn
# split (ysg-box CLE-3450) means a live agent always has one before it sends.
eq "the sender kept exactly one strip" 1 \
  "$(tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{@spool_notices}' | grep -c '^CLE-90$')"

t_done
