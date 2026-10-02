#!/usr/bin/env bash
# next-agent-id.sh — allocate the next free spool agent id (c-004 / g-004 /
# a-004 / q-004, specs/061 §2) on THIS machine and CLAIM it, atomically, by
# creating its spool dir.
#
# Adapted to the spool specs:
#   - the root is $SPOOL_ROOT (default /var/spool-hub), and the claim creates
#     $SPOOL_ROOT/<ID>/{inbox,outbox,archive} (local-folder-layout.md).
#   - numbers are 3 digits, 004-999, on EVERY machine (specs/061 §3.3, owner
#     Q3): no per-machine bands. An agent is unique as <ID>@<box>, so
#     SPOOL_AGENT_ID_RANGE (specs/058 F1) is ignored from here on.
#   - 001-003 are the role ids (c-001 orchestrator, c-002 / c-003 the
#     dispatchers): only ever --claim'ed, never handed out.
#   - no key and no pin: local mode is unsigned (trust-modes §2).
#
# Allocation (specs/061 §3.5, FR-008). A cursor file $SPOOL_ROOT/agent-id.cursor
# (flock) holds the last number handed out on this machine; the next candidate
# is cursor+1, wrapping 999 -> 004. A candidate is SKIPPED while any of these
# holds, because a live window alone is the one record that does not survive:
#   1. its spool dir exists (<ID>, <ID>@<box>, or a link of either name);
#   2. a registry.tsv row names it (column 1);
#   3. its identity record agents/<ID>.json exists;
#   4. a tmux window carries it;
#   5. it was retired (registry.retired.tsv) less than SPOOL_ID_QUARANTINE_H
#      hours ago (default 24).
# The claim is still `mkdir` without -p: one syscall both refuses a used id and
# locks out a concurrent spawn racing for the same one. A full line (every
# number skipped) is exit 1; nothing is ever reused silently.
#
# Usage:
#   next-agent-id.sh --kind claude|grok|agy|qwen # prints e.g. c-004
#   next-agent-id.sh --prefix c|g|a|q            # same, by id letter (CLE|GRK|AGY|QWN too)
#   next-agent-id.sh --kind claude --no-reserve  # compute only; claim nothing
#   next-agent-id.sh --kind claude --explain     # decision to stderr
#   next-agent-id.sh --kind claude --also-registry DIR  # DIR's registry.tsv and
#                                                # dirs hold ids too (a box spawner's own)
#   next-agent-id.sh --claim c-041               # claim THAT id, or fail (exit 3)
#
# Output: the id on stdout, nothing else. Exit 0 ok, 1 no id, 2 usage,
# 3 --claim of an id that is taken.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

# ---- the two owner switches (specs/061 §7, not yet confirmed) -------------
# Q1: which kinds keep 001-003 as role numbers. Recommended and built: every
# kind. "Only c-" flips this line to: ID_ROLE_LETTERS=c
ID_ROLE_LETTERS="${SPOOL_ID_ROLE_LETTERS:-acgq}"
# Q2: one counter per machine shared by all kinds (c-004 and a-004 never
# coexist). Recommended and built: machine. "One per kind" flips this line to:
# ID_COUNTER=kind
ID_COUNTER="${SPOOL_ID_COUNTER:-machine}"

usage() {
  sed -n '/^# Usage:/,/^# Output:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# The id letter a kind (or a legacy prefix, or a letter) stands for.
_letter_of() {  # KIND|PREFIX|LETTER
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    claude|cle|c) printf c ;;
    grok|grk|g)   printf g ;;
    agy|a)        printf a ;;
    qwen|qwn|q)   printf q ;;
    *) return 1 ;;
  esac
}

LETTER=""; RESERVE=1; EXPLAIN=0; CLAIM=""; ALSO_REG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      [ "$#" -ge 2 ] || usage
      case "$2" in claude|grok|agy|qwen) LETTER="$(_letter_of "$2")" ;;
        *) echo "ERROR: --kind must be claude|grok|agy|qwen, got: $2" >&2; exit 2 ;; esac
      shift 2 ;;
    --prefix)
      [ "$#" -ge 2 ] || usage
      LETTER="$(_letter_of "$2")" || { echo "ERROR: --prefix must be c|g|a|q (or CLE|GRK|AGY|QWN), got: $2" >&2; exit 2; }
      shift 2 ;;
    --claim)         [ "$#" -ge 2 ] || usage; CLAIM="$2"; shift 2 ;;
    --also-registry) [ "$#" -ge 2 ] || usage; ALSO_REG="$2"; shift 2 ;;
    --no-reserve)    RESERVE=0; shift ;;
    --explain)       EXPLAIN=1; shift ;;
    -h|--help)       usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

say() { [ "$EXPLAIN" -eq 1 ] && printf 'next-agent-id: %s\n' "$*" >&2; return 0; }

case "$ID_COUNTER" in machine|kind) ;;
  *) echo "ERROR: SPOOL_ID_COUNTER must be machine|kind, got: ${ID_COUNTER}" >&2; exit 2 ;; esac
[[ "$ID_ROLE_LETTERS" =~ ^[acgq]*$ ]] \
  || { echo "ERROR: SPOOL_ID_ROLE_LETTERS must be letters of acgq, got: ${ID_ROLE_LETTERS}" >&2; exit 2; }
QUAR_H="${SPOOL_ID_QUARANTINE_H:-24}"
[[ "$QUAR_H" =~ ^[0-9]+$ ]] || { echo "ERROR: SPOOL_ID_QUARANTINE_H must be whole hours, got: ${QUAR_H}" >&2; exit 2; }
[ -z "${SPOOL_AGENT_ID_RANGE:-}" ] \
  || say "SPOOL_AGENT_ID_RANGE=${SPOOL_AGENT_ID_RANGE} ignored: every machine numbers 004-999 (specs/061 §3.3)"

# ---- the mailbox layout (specs/058 6) -------------------------------------
# SPOOL_DIR_LAYOUT=qualified (box.env) + SPOOL_DESK_BOX: a claim creates the
# dir <ID>@<box> (the atomic claim) and the compat link <ID> -> <ID>@<box>, so
# every path built from the bare id resolves. Unset: the dir <ID>, as before.
QBOX=""
if [ "${SPOOL_DIR_LAYOUT:-}" = qualified ]; then
  [[ "${SPOOL_DESK_BOX:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] \
    || { echo "ERROR: SPOOL_DIR_LAYOUT=qualified needs a box id in SPOOL_DESK_BOX, got: '${SPOOL_DESK_BOX:-}'" >&2; exit 2; }
  QBOX="$SPOOL_DESK_BOX"
fi
# _taken ID: 0 when ID has a mailbox under SPOOL_ROOT in either layout (a
# dangling or looping link counts: a half-finished migration owns the id).
_taken() {
  [ -e "${SPOOL_ROOT}/$1" ] || [ -L "${SPOOL_ROOT}/$1" ] && return 0
  compgen -G "${SPOOL_ROOT}/$1@*" >/dev/null
}
# _claim ID: create ID's mailbox dir, or fail when it is taken.
_claim() {
  _taken "$1" && return 1
  if [ -z "$QBOX" ]; then mkdir "${SPOOL_ROOT}/$1" 2>/dev/null; return; fi
  mkdir "${SPOOL_ROOT}/$1@${QBOX}" 2>/dev/null || return 1
  ln -s "$1@${QBOX}" "${SPOOL_ROOT}/$1" 2>/dev/null && return 0
  rmdir "${SPOOL_ROOT}/$1@${QBOX}" 2>/dev/null; return 1
}

_mkdirs() {  # ID — the dir itself already exists
  mkdir -p "${SPOOL_ROOT}/$1/inbox" "${SPOOL_ROOT}/$1/outbox" "${SPOOL_ROOT}/$1/archive"
  # 0775 dirs (local-folder-layout.md); the group bit is how the box user and
  # the agent user share them.
  chmod 0775 "${SPOOL_ROOT}/$1" "${SPOOL_ROOT}/$1/inbox" "${SPOOL_ROOT}/$1/outbox" "${SPOOL_ROOT}/$1/archive" 2>/dev/null || true
}

# ---- an explicit id: validate and claim it, never renumber ----------------
if [ -n "$CLAIM" ]; then
  spool_valid_id "$CLAIM" || exit 2
  if [ "$RESERVE" -eq 0 ]; then
    _taken "$CLAIM" && { echo "ERROR: ${CLAIM} is taken (${SPOOL_ROOT}/${CLAIM} exists)" >&2; exit 3; }
    printf '%s\n' "$CLAIM"; exit 0
  fi
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || true
  if _claim "$CLAIM"; then
    _mkdirs "$CLAIM"
    say "claimed ${CLAIM} (${SPOOL_ROOT}/${CLAIM})"
    printf '%s\n' "$CLAIM"; exit 0
  fi
  echo "ERROR: ${CLAIM} is taken on this box (${SPOOL_ROOT}/${CLAIM} exists or is not creatable)" >&2
  exit 3
fi

[ -n "$LETTER" ] || { echo "ERROR: --kind, --prefix or --claim is required" >&2; usage; }

# ---- this kind's line ------------------------------------------------------
LO=1; case "$ID_ROLE_LETTERS" in *"$LETTER"*) LO=4 ;; esac
HI=999
# The letters whose ids share one number (Q2): all of them, or this kind's.
if [ "$ID_COUNTER" = machine ]; then SCOPE=acgq; CURSOR="${SPOOL_ROOT}/agent-id.cursor"
else SCOPE="$LETTER"; CURSOR="${SPOOL_ROOT}/agent-id.${LETTER}.cursor"; fi
ID_TOK="[${SCOPE}]-[0-9]{3}"

# ---- the held numbers: the 5 skip rules ------------------------------------
declare -A HELD=()
_hold() {  # WHY — ids on stdin, one per line (anything else is ignored)
  local id n
  while IFS= read -r id; do
    id="${id%%@*}"
    [[ "$id" =~ ^${ID_TOK}$ ]] || continue
    n=$((10#${id#?-}))
    [ -n "${HELD[$n]:-}" ] || HELD[$n]="$1 ${id}"
  done
  return 0
}
_dir_ids() {  # DIR — the names of its entries (dirs and links alike)
  [ -d "$1" ] && find "$1" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null
  return 0
}
_reg_ids() {  # FILE — column 1 of a registry
  [ -r "$1" ] && cut -f1 "$1"
  return 0
}
_hold "1:spool-dir" < <(_dir_ids "$SPOOL_ROOT")
_hold "2:registry"  < <(_reg_ids "${SPOOL_ROOT}/registry.tsv")
_hold "3:identity"  < <([ -d "${SPOOL_ROOT}/agents" ] \
  && find "${SPOOL_ROOT}/agents" -mindepth 1 -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null | sed 's/\.json$//')
# A loose token scan on purpose: a tag ("<tag>: c-007") or a badge after the id
# must still count, and over-reading only skips an id, never reuses one.
spool_tmux_argv
_hold "4:window" < <("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
  | grep -oE "(^|[^a-z0-9])${ID_TOK}([^0-9]|\$)" | grep -oE "${ID_TOK}" || true)
# Rule 5: registry.retired.tsv rows are id, kind, pane, rundir, spawned-utc,
# retired-utc (all %Y%m%dT%H%M%SZ, so fixed-width strings compare as times).
_now_epoch() {
  local n="${SPOOL_NOW:-}"
  if [ -z "$n" ]; then date -u +%s
  elif [[ "$n" =~ ^[0-9]+$ ]]; then printf '%s' "$n"
  else date -u -d "$n" +%s; fi
}
QUAR_FROM="$(date -u -d "@$(( $(_now_epoch) - QUAR_H * 3600 ))" +%Y%m%dT%H%M%SZ)"
if [ -r "${SPOOL_ROOT}/registry.retired.tsv" ]; then
  _hold "5:quarantine" < <(awk -F'\t' -v from="$QUAR_FROM" '$6 >= from { print $1 }' "${SPOOL_ROOT}/registry.retired.tsv")
fi
if [ -n "$ALSO_REG" ]; then
  _hold "2:also-registry" < <(_reg_ids "${ALSO_REG}/registry.tsv")
  _hold "1:also-registry" < <(_dir_ids "$ALSO_REG")
fi
say "line ${LETTER}-$(printf %03d "$LO")..${HI}, counter ${ID_COUNTER} (${SCOPE}), ${#HELD[@]} number(s) held, quarantine since ${QUAR_FROM}"

# ---- the cursor (flock), then the walk -------------------------------------
_cursor_read() {
  local c=""
  [ -r "$CURSOR" ] && c="$(head -c 16 "$CURSOR" | tr -dc 0-9)"
  if [[ "$c" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$c))" -ge "$LO" ] && [ "$((10#$c))" -le "$HI" ]; then
    printf '%s' "$((10#$c))"
  else
    printf '%s' "$((LO - 1))"
  fi
}
if [ "$RESERVE" -eq 1 ]; then
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || true
  exec 9>>"$CURSOR"
  chmod 0664 "$CURSOR" 2>/dev/null || true
  flock -w 30 9 || { echo "ERROR: ${CURSOR} stayed locked for 30 s" >&2; exit 1; }
fi
cur="$(_cursor_read)"
say "cursor ${CURSOR}: ${cur}"
span=$((HI - LO + 1)); n="$cur"
for ((i = 0; i < span; i++)); do
  n=$((n + 1)); [ "$n" -gt "$HI" ] && n="$LO"
  ID="$(printf '%s-%03d' "$LETTER" "$n")"
  if [ -n "${HELD[$n]:-}" ]; then say "skip ${ID}: rule ${HELD[$n]}"; continue; fi
  if [ "$RESERVE" -eq 0 ]; then
    if _taken "$ID"; then say "skip ${ID}: exists"; continue; fi
    say "chose ${ID} (not claimed: --no-reserve)"
    printf '%s\n' "$ID"; exit 0
  fi
  if _claim "$ID"; then
    _mkdirs "$ID"
    printf '%03d\n' "$n" >"$CURSOR"
    say "claimed ${ID} (${SPOOL_ROOT}/${ID}); cursor -> ${n}"
    printf '%s\n' "$ID"; exit 0
  fi
  say "skip ${ID}: ${SPOOL_ROOT}/${ID} exists or is not creatable"
done
echo "ERROR: the ${LETTER}- line $(printf %03d "$LO")-${HI} is full on this machine (${SPOOL_ROOT}; counter ${ID_COUNTER}, ${#HELD[@]} held)" >&2
exit 1
