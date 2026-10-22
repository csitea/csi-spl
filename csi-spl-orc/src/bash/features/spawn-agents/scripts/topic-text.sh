#!/usr/bin/env bash
# topic-text.sh — the human posts of every owner topic a brief links, as a
# "Topic text" section the launcher appends to the lane's lifetime/brief.md
# (SPL-2107, owner HUM-10 topic e055195c). A lane seated in another workspace,
# or with no seat at all, cannot open a topic link; the brief then hangs on
# text the lane cannot see.
#
#   topic-text.sh [--spool-root <dir>] <brief file>
#
# stdout: nothing when the brief names no topic link
# (https://<host>/t/<uuid>); else the section: per topic, its human posts
# (from HUM-*: author, time, text), oldest first, the last
# TOPIC_TEXT_MAX_POSTS (20) of them and at most TOPIC_TEXT_MAX_BYTES (6144)
# of text per topic, and a line saying so when it is cut. A topic no desk on
# this box returns a post of gets one line saying so. Never fails a spawn: exit 0,
# 2 only on usage.
#
# Read path: the one spool-topic-kind.sh uses (keep the two in step): this
# box's desk sidecar (hub-run), its own spool env, `spool hub-tail --task
# <uuid> --json`, read-only. The hub serves a topic only to a desk seated in
# its workspace, so the desks are tried in turn: the tenant named by the
# link's first host label, then the fleet tenant, then every other seated
# tenant of the fleet env; in each, the box's desk box (SPOOL_DESK_BOX, else
# lease.conf LEASE_DESK_BOX) first, then its other desk boxes.
#
# Data rule: the text is personal data of its workspace. It goes only into
# the lane's brief on this box (the caller's file); never git, never a spool
# body to another workspace's agent.
#
# Seam (tests): TOPIC_TEXT_READ_CMD "<cmd>" is called as `<cmd> <tenant>
# <uuid>`, prints hub-tail NDJSON, non-zero = this desk cannot read it.
set -uo pipefail

ROOT="${SPOOL_ROOT:-/var/spool-hub}" BRIEF=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spool-root) [ "$#" -ge 2 ] || exit 2; ROOT="$2"; shift 2 ;;
    *) [ -z "$BRIEF" ] || exit 2; BRIEF="$1"; shift ;;
  esac
done
[ -n "$BRIEF" ] || exit 2
[ -r "$BRIEF" ] || exit 0

UUID='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
MAXT="${TOPIC_TEXT_MAX_TOPICS:-3}" MAXP="${TOPIC_TEXT_MAX_POSTS:-20}" MAXB="${TOPIC_TEXT_MAX_BYTES:-6144}"
# "<host> <uuid>" per linked topic, first mention first, each uuid once.
mapfile -t LINKS < <(grep -oE "https?://[A-Za-z0-9.-]+/t/${UUID}" "$BRIEF" 2>/dev/null |
  sed -E 's#^https?://([^/]+)/t/#\1 #' | awk '!seen[$2]++')
[ "${#LINKS[@]}" -gt 0 ] || exit 0

kv() {  # FILE KEY: KEY from a KEY=value file (read, never sourced)
  [ -r "$1" ] || return 0
  sed -n "s/^$2=[\"']\{0,1\}\([A-Za-z0-9_-]*\)[\"']\{0,1\}\$/\1/p" "$1" | tail -1
}
BOXENV="${SPOOL_BOX_ENV:-$ROOT/box.env}" LCONF="$ROOT/dispatch/lease.conf"
ENVN="${SPOOL_FLEET_ENV:-$(kv "$BOXENV" SPOOL_FLEET_ENV)}"; ENVN="${ENVN:-$(kv "$LCONF" LEASE_ENV)}"
FT="${SPOOL_FLEET_TENANT:-$(kv "$BOXENV" SPOOL_FLEET_TENANT)}"; FT="${FT:-$(kv "$LCONF" LEASE_TENANT)}"
DBOX="${SPOOL_DESK_BOX:-$(kv "$BOXENV" SPOOL_DESK_BOX)}"; DBOX="${DBOX:-$(kv "$LCONF" LEASE_DESK_BOX)}"
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/desk-root.inc.sh
. "$_here/../lib/desk-root.inc.sh"
# No desk root (SPOOL_DESK_USER has no home): no desk, each topic gets its line.
STATE="${SPOOL_FLEET_STATE_ROOT:-$(spool_desk_root "$(getent passwd "$(id -un)" | cut -d: -f6)" "$BOXENV")}" || STATE=/nonexistent
DESKS="$STATE/${ENVN:-none}/desk"

# The seated tenants to try for a link on HOST, best first.
tenants_for() {  # HOST
  local first="${1%%.*}" t
  { [ -d "$DESKS/$first" ] && echo "$first"
    [ -n "$FT" ] && [ -d "$DESKS/$FT" ] && echo "$FT"
    for t in "$DESKS"/*/; do [ -d "$t" ] && basename "$t"; done
  } 2>/dev/null | awk 'NF && !seen[$0]++' | grep -E '^[a-z0-9][a-z0-9-]{0,31}$'
}

# hub-tail NDJSON of UUID through one live desk sidecar of TENANT.
desk_read() {  # TENANT UUID
  if [ -n "${TOPIC_TEXT_READ_CMD:-}" ]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $TOPIC_TEXT_READ_CMD "$1" "$2"; return
  fi
  [[ "$ENVN" =~ ^(dev|prd|self)$ ]] || return 1
  local d pid e out tried=" " bin="${SPOOL_FLEET_BIN:-$STATE/$ENVN/bin/spool}"
  [ -x "$bin" ] || bin="${SPOOL_BIN:-spool}"
  for d in ${DBOX:+"$DESKS/$1/$DBOX"} "$DESKS/$1"/*; do
    [[ "$tried" != *" $d "* ]] || continue
    tried+="$d "
    pid="$(cat "$d/spool/.hub/hub-run.pid" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline" | grep ' hub-run' >/dev/null || continue
    local -a envv=()
    while IFS= read -r -d '' e; do
      case "${e%%=*}" in
        SPOOL_ROOT|SPOOL_KEYS_DIR|SPOOL_PINS_DIR|SPOOL_BOX_ID|SPOOL_HUB_URL|SPOOL_TENANT|SPOOL_MSG_VERSION) envv+=("$e") ;;
      esac
    done 2>/dev/null <"/proc/$pid/environ"
    [ "${#envv[@]}" -ge 5 ] || continue
    out="$(env -i HOME="$HOME" PATH=/usr/bin:/bin SPOOL_LOG_LEVEL=error "${envv[@]}" \
      timeout "${TOPIC_TEXT_TIMEOUT:-5}" "$bin" hub-tail --task "$2" --json 2>/dev/null)" || continue
    grep -q '^{' <<<"$out" || continue
    printf '%s\n' "$out"; return 0
  done
  return 1
}

# The human posts of one NDJSON read, capped, as markdown.
render() {  # TENANT UUID < NDJSON
  python3 -c '
import json, sys
tenant, uuid, maxp, maxb = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
posts = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if str(m.get("from", "")).startswith("HUM-"):
        posts.append(m)
posts.sort(key=lambda m: str(m.get("ts", "")))
total = len(posts)
kept, size = [], 0
for m in reversed(posts[-maxp:]):
    body = str(m.get("body", "")).rstrip()
    quoted = "\n".join("> " + l if l else ">" for l in body.split("\n"))
    block = "- %s, %s:\n%s\n" % (m.get("from", "?"), m.get("ts", "?"), quoted)
    n = len(block.encode())
    if size + n > maxb:
        if not kept:
            kept.append(block.encode()[:maxb].decode(errors="ignore") + "\n> [post cut at %d bytes]\n" % maxb)
        break
    kept.append(block)
    size += n
kept.reverse()
print("### Topic %s (workspace %s): %d human post(s)" % (uuid, tenant, total))
print()
if not total:
    print("No human post in what this desk holds of the topic.")
    print()
for b in kept:
    print(b)
if len(kept) < total:
    print("Cut: the last %d of %d human posts are shown (cap %d posts, %d bytes)." % (len(kept), total, maxp, maxb))
    print()
' "$1" "$2" "$MAXP" "$MAXB"
}

echo
echo "## Topic text (added by the launcher)"
echo
echo "The human posts of the owner topic(s) this brief links, read at $(date -u +%Y-%m-%dT%H:%M:%SZ) through this box's desk. Personal data of that workspace: it stays in this file, never in git, never in a spool body to another workspace's agent."
echo
n=0
for l in "${LINKS[@]}"; do
  host="${l%% *}" uuid="${l##* }"
  n=$((n + 1))
  if [ "$n" -gt "$MAXT" ]; then
    echo "Topic ${uuid}: not read (cap ${MAXT} topics per brief)."; echo; continue
  fi
  got=""
  while IFS= read -r t; do
    if out="$(desk_read "$t" "$uuid" 2>/dev/null)" && grep -q '^{' <<<"$out"; then
      render "$t" "$uuid" <<<"$out"; got=1; break
    fi
  done < <(tenants_for "$host")
  [ -n "$got" ] || { echo "Topic ${uuid}: no desk on this box returned a post of it (env ${ENVN:-?}, desks tried in: $(tenants_for "$host" | paste -sd, -)): a desk not seated there, or one that holds none of it; ask the dispatcher for its text."; echo; }
done
exit 0
