#!/usr/bin/env bash
# restore-drill-red-note-cron.sh — the alert of the DB restore drill (SPL-2310,
# spec 029 §6.9). Runs ci-red-note-cron.sh against workflow 49 instead of
# wf 10: ONE blocker to the dispatch lease holder when the scheduled drill
# goes red on master, ONE green line when it passes again - the same path as a
# red CI job (spec 131 C2). Own streak file and lock, so it never shares a
# streak with wf 10. No lane notes: a drill red is the backup's or the
# estate's, not a lane commit's. No stuck-queue check: wf 10 has it.
# Installed by do_install_box_crons as the
# manifest row restore-drill-red-note, tagged `# csi-spl:box-cron:restore-drill-red-note`.
#
#   restore-drill-red-note-cron.sh [--check-tools]
#
# Exit: as ci-red-note-cron.sh.
set -uo pipefail
SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
st="${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl"
export CI_GATE_WORKFLOW="${RESTORE_DRILL_WORKFLOW:-49_db-restore-drill.yml}"
export CI_RED_NOTE_STATE="${RESTORE_DRILL_RED_NOTE_STATE:-$st/restore-drill-red-note.tsv}"
export CI_RED_NOTE_LOCK="${RESTORE_DRILL_RED_NOTE_LOCK:-$st/restore-drill-red-note.lock}"
export CI_RED_NOTE_LANES=0
export CI_GATE_STUCK_CHECK=0
exec bash "$SELF/ci-red-note-cron.sh" "$@"
