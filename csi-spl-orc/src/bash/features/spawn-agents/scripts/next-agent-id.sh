#!/usr/bin/env bash
# next-agent-id.sh — allocate the next free spool agent id (CLE-NN / GRK-NN /
# AGY-NN) on THIS box and CLAIM it, atomically, by creating its spool dir.
#
# Forked from the box engine's allocator; adapted to the spool specs:
#   - the root is $SPOOL_ROOT (default /var/spool-hub), and the claim creates
#     $SPOOL_ROOT/<ID>/{inbox,outbox,archive} (local-folder-layout.md). The
#     roster IS that directory list (trust-modes §4), so an id with a dir is
#     taken.
#   - ids match ^[A-Z]{2,4}-[0-9]+$ and BOX is never an agent prefix
#     (SPEC-spool-identity-routing.md §2); uniqueness is per box.
#   - no key and no pin: local mode is unsigned (trust-modes §2).
#
# The id is allocated from records that PERSIST, and the allocation is a claim
# rather than a guess:
#
#   floor = max(id in registry.tsv, id on a live tmux window, id with a dir)
#   claim = the first id above that floor whose dir can be CREATED
#
# A live window alone is the one record that does not survive (the agent exits,
# tmux restarts), so it may only RAISE the floor. `mkdir` without -p fails on an
# existing dir: that one syscall both refuses a used id and locks out a
# concurrent spawn racing for the same one.
#
# Usage:
#   next-agent-id.sh --kind claude|grok|agy      # prints e.g. CLE-08
#   next-agent-id.sh --prefix CLE|GRK|AGY        # same, by id prefix
#   next-agent-id.sh --kind claude --no-reserve  # compute only; claim nothing
#   next-agent-id.sh --kind claude --explain     # decision to stderr
#   next-agent-id.sh --claim CLE-4441            # claim THAT id, or fail (exit 3)
#
# Output: the id on stdout, nothing else. Exit 0 ok, 1 no id, 2 usage,
# 3 --claim of an id that is taken.
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
      PREFIX="$(spool_prefix_of_kind "$2")" || { echo "ERROR: --kind must be claude|grok|agy, got: $2" >&2; exit 2; }
      shift 2 ;;
    --prefix)
      [ "$#" -ge 2 ] || usage
      PREFIX="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
      case "$PREFIX" in
        CLE|GRK|AGY) ;;
        *) echo "ERROR: --prefix must be CLE|GRK|AGY, got: $2" >&2; exit 2 ;;
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
    [ -e "${SPOOL_ROOT}/${CLAIM}" ] && { echo "ERROR: ${CLAIM} is taken (${SPOOL_ROOT}/${CLAIM} exists)" >&2; exit 3; }
    printf '%s\n' "$CLAIM"; exit 0
  fi
  mkdir -p "$SPOOL_ROOT" 2>/dev/null || true
  if mkdir "${SPOOL_ROOT}/${CLAIM}" 2>/dev/null; then
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
      $1 ~ "^" p "-[0-9]+$" { n = $1; sub(/^[A-Z]+-/, "", n); n += 0; if (n > m) m = n }
      END { print m + 0 }' "$REGISTRY")"
fi
say "registry ${REGISTRY}: max ${REG_MAX}"

# ---- floor 2: live tmux windows (can only raise the floor) ----------------
# A loose token scan on purpose: a tag ("<tag>: CLE-07") or a badge after the
# id must still count, and over-reading only skips an id, never reuses one.
spool_tmux_argv
WIN_MAX="$("${SPOOL_TM[@]}" list-windows -a -F '#{window_name}' 2>/dev/null \
  | grep -oE "${PREFIX}-[0-9]+" | grep -oE '[0-9]+$' \
  | awk '{ n = $0 + 0; if (n > m) m = n } END { print m + 0 }' || true)"
[ -n "$WIN_MAX" ] || WIN_MAX=0
say "live windows on ${SPOOL_TMUX_SOCKET}: max ${WIN_MAX}"

# ---- floor 3: agent dirs already under the spool root ---------------------
DIR_MAX=0
if [ -d "$SPOOL_ROOT" ]; then
  DIR_MAX="$(find "$SPOOL_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E "^${PREFIX}-[0-9]+$" | grep -oE '[0-9]+$' \
    | awk '{ n = $0 + 0; if (n > m) m = n } END { print m + 0 }' || true)"
  [ -n "$DIR_MAX" ] || DIR_MAX=0
fi
say "agent dirs under ${SPOOL_ROOT}: max ${DIR_MAX}"

FLOOR="$REG_MAX"
[ "$WIN_MAX" -gt "$FLOOR" ] && FLOOR="$WIN_MAX"
[ "$DIR_MAX" -gt "$FLOOR" ] && FLOOR="$DIR_MAX"
say "floor ${FLOOR} (registry ${REG_MAX} / windows ${WIN_MAX} / dirs ${DIR_MAX})"

[ "$RESERVE" -eq 1 ] && { mkdir -p "$SPOOL_ROOT" 2>/dev/null || true; }
n="$FLOOR"; tries=0
while [ "$tries" -lt 1000 ]; do
  tries=$((tries + 1)); n=$((n + 1))
  ID="$(printf '%s-%02d' "$PREFIX" "$n")"
  if [ "$RESERVE" -eq 0 ]; then
    if [ -e "${SPOOL_ROOT}/${ID}" ]; then say "skip ${ID}: exists"; continue; fi
    say "chose ${ID} (not claimed: --no-reserve)"
    printf '%s\n' "$ID"; exit 0
  fi
  if mkdir "${SPOOL_ROOT}/${ID}" 2>/dev/null; then
    _mkdirs "$ID"
    say "claimed ${ID} (${SPOOL_ROOT}/${ID})"
    printf '%s\n' "$ID"; exit 0
  fi
  say "skip ${ID}: ${SPOOL_ROOT}/${ID} exists or is not creatable"
done
echo "ERROR: no free ${PREFIX} id in ${tries} tries above ${FLOOR} (${SPOOL_ROOT})" >&2
exit 1
