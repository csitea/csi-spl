#!/usr/bin/env bash
# spool-verb-shims.sh — the hyphenated `spool-<verb>` commands of
# specs/012-spool-box-api FR-006 / T012 (box-image packaging): one two-line
# shim per verb that `exec`s `spool <verb> "$@"`, so a box (or an agent's
# PATH) offers `spool-send`, `spool-recv`, … as well as `spool send`.
#
#   spool-verb-shims.sh [--bin DIR] [--spool PATH] [--dry-run]
#
#   --bin DIR     where the shims go, default ~/.local/bin
#   --spool PATH  the spool binary the shims run, default: $SPOOL_BIN, else
#                 `spool` resolved on PATH at the time the shim RUNS
#   --dry-run     print what would be written; write nothing
#
# The five verbs are the five MCP tools of FR-002 (§4): put-file, get-file,
# send, recv, tail. Idempotent: a shim that already carries the same body is
# left alone; a file of the same name that is NOT a shim of ours is never
# overwritten (exit 3, named).
set -uo pipefail

VERBS=(put-file get-file send recv tail)
MARK="# spool-verb-shim (specs/012 FR-006)"
BIN="$HOME/.local/bin" SPOOL="${SPOOL_BIN:-}" DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin)     [ "$#" -ge 2 ] || { echo "usage: --bin DIR" >&2; exit 2; }; BIN="$2"; shift 2 ;;
    --spool)   [ "$#" -ge 2 ] || { echo "usage: --spool PATH" >&2; exit 2; }; SPOOL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "spool-verb-shims: unknown argument $1" >&2; exit 2 ;;
  esac
done

target="${SPOOL:-spool}"
rc=0
[ "$DRY" = 1 ] || mkdir -p "$BIN" || { echo "spool-verb-shims: cannot create $BIN" >&2; exit 1; }
for v in "${VERBS[@]}"; do
  f="$BIN/spool-$v"
  body="$(printf '#!/bin/sh\n%s\nexec %q %s "$@"\n' "$MARK" "$target" "$v")"
  if [ -e "$f" ] && ! grep -qF "$MARK" "$f" 2>/dev/null; then
    echo "spool-verb-shims: $f exists and is not a spool shim - left alone" >&2; rc=3; continue
  fi
  if [ -e "$f" ] && [ "$(cat "$f")" = "$body" ]; then
    echo "same     $f"; continue
  fi
  if [ "$DRY" = 1 ]; then echo "would    $f -> $target $v"; continue; fi
  printf '%s\n' "$body" >"$f.tmp.$$" && chmod 755 "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" ||
    { echo "spool-verb-shims: cannot write $f" >&2; rc=1; continue; }
  echo "wrote    $f -> $target $v"
done
exit "$rc"
