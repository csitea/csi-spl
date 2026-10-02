#!/usr/bin/env bash
# next-agent-id.sh — allocate the next free spool agent id (CLE-NN / GRK-NN /
# AGY-NN / QWN-NN) on THIS box and CLAIM it, atomically, by creating its spool dir.
#
# Forked from the box engine's allocator; adapted to the spool specs:
#   - the root is $SPOOL_ROOT (default /var/spool-hub), and the claim creates
#     $SPOOL_ROOT/<ID>/{inbox,outbox,archive} (local-folder-layout.md). The
#     roster IS that directory list (trust-modes §4), so an id with a dir is
#     taken.
#   - ids match ^[A-Z]{2,4}-[0-9]+$ and BOX is never an agent prefix
#     (SPEC-spool-identity-routing.md §2); uniqueness is per box.
#   - a fleet of MANY machines (specs/058): each machine allocates only inside
#     its own number band, SPOOL_AGENT_ID_RANGE=<lo>-<hi> (box.env), so two
#     machines that never see each other's spool root can never hand out the
#     same id. Unset = the whole line (one machine, as before).
#   - the numbers 1-3 are RESERVED on every box (owner, specs/058): CLE-001
#     orchestrator, CLE-002 master dispatcher, CLE-003 failover. They are only
#     ever --claim'ed, never handed out, so no CLE-01..03 look-alike appears.
#   - no key and no pin: local mode is unsigned (trust-modes §2).
#
# The id is allocated from records that PERSIST, and the allocation is a claim
# rather than a guess:
#
#   floor = max(id in registry.tsv, id on a live tmux window, id with a dir
#           <ID> or <ID>@<box>)
#   claim = the first id above that floor whose dir can be CREATED
#
# With a band, only ids inside it count toward the floor, the floor is at least
# <lo>-1, and an id past <hi> is never handed out (exit 1: the band is full).
# --claim of an id outside the band still works - an explicit id is a
# deliberate act (a role id, a takeover from another machine) - but says so on
# stderr.
#
# A live window alone is the one record that does not survive (the agent exits,
# tmux restarts), so it may only RAISE the floor. `mkdir` without -p fails on an
# existing dir: that one syscall both refuses a used id and locks out a
# concurrent spawn racing for the same one.
#
# Usage:
#   next-agent-id.sh --kind claude|grok|agy|qwen # prints e.g. CLE-08
#   next-agent-id.sh --prefix CLE|GRK|AGY|QWN    # same, by id prefix
#   next-agent-id.sh --kind claude --no-reserve  # compute only; claim nothing
#   next-agent-id.sh --kind claude --explain     # decision to stderr
#   next-agent-id.sh --claim CLE-4441            # claim THAT id, or fail (exit 3)
#
# Output: the id on stdout, nothing else. Exit 0 ok, 1 no id, 2 usage
# (also a malformed SPOOL_AGENT_ID_RANGE), 3 --claim of an id that is taken.
set -euo pipefail

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve

usage() {
  sed -n '/^# Usage:/,/^# Output:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

PREFIX=""; RESERVE=1; EXPLAIN=0; CLAIM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind)
      [ "$#" -ge 2 ] || usage
      PREFIX="$(spool_prefix_of_kind "$2")" || { echo "ERROR: --kind must be claude|grok|agy|qwen, got: $2" >&2; exit 2; }
      shift 2 ;;
    --prefix)
      [ "$#" -ge 2 ] || usage
      PREFIX="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
      case "$PREFIX" in
        CLE|GRK|AGY|QWN) ;;
        *) echo "ERROR: --prefix must be CLE|GRK|AGY|QWN, got: $2" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --claim)      [ "$#" -ge 2 ] || usage; CLAIM="$2"; shift 2 ;;
    --no-reserve) RESERVE=0; shift ;;
    --explain)    EXPLAIN=1; shift ;;
    -h|--help)    usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

say() { [ "$EXPLAIN" -eq 1 ] && printf 'next-agent-id: %s\n' "$*" >&2; return 0; }

# ---- this machine's band (specs/058) --------------------------------------
LO=1; HI=0
RANGE="${SPOOL_AGENT_ID_RANGE:-}"
if [ -n "$RANGE" ]; then
  if ! [[ "$RANGE" =~ ^([0-9]{1,9})-([0-9]{1,9})$ ]] \
     || [ "$((10#${BASH_REMATCH[1]}))" -lt 1 ] \
     || [ "$((10#${BASH_REMATCH[1]}))" -gt "$((10#${BASH_REMATCH[2]}))" ]; then
    echo "ERROR: SPOOL_AGENT_ID_RANGE must be <lo>-<hi> with 1 <= lo <= hi, got: ${RANGE}" >&2
    exit 2
  fi
  LO="$((10#${BASH_REMATCH[1]}))"; HI="$((10#${BASH_REMATCH[2]}))"
fi
# in_band N: 0 when N lies inside this machine's band (always, with no band).
in_band() { [ "$1" -ge "$LO" ] && { [ "$HI" -eq 0 ] || [ "$1" -le "$HI" ]; }; }
# band_max: the largest number on stdin inside the band, else 0.
band_max() { awk -v lo="$LO" -v hi="$HI" '{ n = $0 + 0; if (n >= lo && (hi == 0 || n <= hi) && n > m) m = n } END { print m + 0 }'; }

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
  in_band "$((10#${CLAIM##*-}))" \
    || echo "WARN: ${CLAIM} is outside this machine's band SPOOL_AGENT_ID_RANGE=${RANGE} (an explicit claim: no other machine may run it)" >&2
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

[ -n "$PREFIX" ] || { echo "ERROR: --kind, --prefix or --claim is required" >&2; usage; }

REGISTRY="${SPOOL_ROOT}/registry.tsv"

# ---- floor 1: the registry (append-only, one row per spawn) ---------------
# Anchored on column 1, so a rundir or branch naming "CLE-9" cannot raise it.
REG_MAX=0
if [ -r "$REGISTRY" ]; then
  REG_MAX="$(awk -F'\t' -v p="$PREFIX" '
      $1 ~ "^" p "-[0-9]+$" { n = $1; sub(/^[A-Z]+-/, "", n); print n + 0 }' "$REGISTRY" | band_max)"
fi
say "registry ${REGISTRY}: max ${REG_MAX}"

# ---- floor 2: live tmux windows (can only raise the floor) ----------------
# A loose token scan on purpose: a tag ("<tag>: CLE-07") or a badge after the
# id must still count, and over-reading only skips an id, never reuses one.
spool_tmux_argv
WIN_MAX="$("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
  | grep -oE "${PREFIX}-[0-9]+" | grep -oE '[0-9]+$' | band_max || true)"
[ -n "$WIN_MAX" ] || WIN_MAX=0
say "live windows on ${SPOOL_TMUX_SOCKET}: max ${WIN_MAX}"

# ---- floor 3: agent dirs already under the spool root ---------------------
DIR_MAX=0
if [ -d "$SPOOL_ROOT" ]; then
  DIR_MAX="$(find "$SPOOL_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E "^${PREFIX}-[0-9]+(@[a-z0-9][a-z0-9-]*)?$" | sed 's/@.*//' | grep -oE '[0-9]+$' | band_max || true)"
  [ -n "$DIR_MAX" ] || DIR_MAX=0
fi
say "agent dirs under ${SPOOL_ROOT}: max ${DIR_MAX}"

FLOOR="$REG_MAX"
[ "$WIN_MAX" -gt "$FLOOR" ] && FLOOR="$WIN_MAX"
[ "$DIR_MAX" -gt "$FLOOR" ] && FLOOR="$DIR_MAX"
[ "$FLOOR" -lt "$((LO - 1))" ] && FLOOR="$((LO - 1))"
[ "$FLOOR" -lt 3 ] && FLOOR=3   # 1-3: the reserved role ids
say "floor ${FLOOR} (registry ${REG_MAX} / windows ${WIN_MAX} / dirs ${DIR_MAX}${RANGE:+ / band ${RANGE}})"

[ "$RESERVE" -eq 1 ] && { mkdir -p "$SPOOL_ROOT" 2>/dev/null || true; }
n="$FLOOR"; tries=0
while [ "$tries" -lt 1000 ]; do
  tries=$((tries + 1)); n=$((n + 1))
  if [ "$HI" -ne 0 ] && [ "$n" -gt "$HI" ]; then
    echo "ERROR: this machine's ${PREFIX} band ${RANGE} is full (SPOOL_AGENT_ID_RANGE)" >&2
    exit 1
  fi
  ID="$(printf '%s-%02d' "$PREFIX" "$n")"
  if [ "$RESERVE" -eq 0 ]; then
    if _taken "$ID"; then say "skip ${ID}: exists"; continue; fi
    say "chose ${ID} (not claimed: --no-reserve)"
    printf '%s\n' "$ID"; exit 0
  fi
  if _claim "$ID"; then
    _mkdirs "$ID"
    say "claimed ${ID} (${SPOOL_ROOT}/${ID})"
    printf '%s\n' "$ID"; exit 0
  fi
  say "skip ${ID}: ${SPOOL_ROOT}/${ID} exists or is not creatable"
done
echo "ERROR: no free ${PREFIX} id in ${tries} tries above ${FLOOR} (${SPOOL_ROOT})" >&2
exit 1
