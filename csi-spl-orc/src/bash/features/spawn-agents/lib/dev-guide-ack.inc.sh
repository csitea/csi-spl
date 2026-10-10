#!/usr/bin/env bash
# dev-guide-ack.inc.sh — has this coder confirmed reading the developer guide?
# Owner HUM-10, t1 4e373f5d msg 56d7073e: every new coding person or agent
# "must agree that they have read" csi-spl-doc/doc/md/developer-guide.md.
#
# The ack is one TSV line  <utc ts> <who> <guide blob sha>  in the per-user
# store $DEV_GUIDE_ACK_FILE, default
# ${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/dev-guide-ack.tsv. It is
# written by `cd csi-spl-orc && ./run -a do_dev_guide_ack` and read by the
# pre-push hook (dga_check) of the user that pushes.
#
#   who        AGENT_ID > SPOOL_AGENT_ID > the agent id a lane branch starts
#              with (c-736-dev-guide-ack -> c-736) > $USER
#   material   an ack is for ONE blob sha of the guide: any change to its blob
#              is material and asks every coder for a new ack (batch typo
#              fixes into one commit)
#   grandfather a work tree created before DEV_GUIDE_ACK_CUTOFF passes without
#              an ack while HEAD's guide is still the blob it had at the
#              cutoff: the rollout blocks no seat already running, and the
#              first guide change after the cutoff asks every tree
# Guard: csi-spl-orc/src/bash/tests/dev-guide-ack.tst.sh.

DGA_GUIDE_REL="csi-spl-doc/doc/md/developer-guide.md"
DGA_CUTOFF_DEFAULT="2026-10-11T00:00:00Z"

dga_store() { printf '%s\n' "${DEV_GUIDE_ACK_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/dev-guide-ack.tsv}"; }

dga_who() {  # <top>
  local b
  [ -n "${AGENT_ID:-}" ] && { printf '%s\n' "$AGENT_ID"; return 0; }
  [ -n "${SPOOL_AGENT_ID:-}" ] && { printf '%s\n' "$SPOOL_AGENT_ID"; return 0; }
  b="$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ "$b" =~ ^([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)(-|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  printf '%s\n' "${USER:-$(id -un 2>/dev/null)}"
}

# The guide blob HEAD carries (what a push ships); empty when there is none.
dga_head_sha() { git -C "$1" rev-parse -q --verify "HEAD:$DGA_GUIDE_REL" 2>/dev/null || true; }

dga_has_ack() {  # <who> <sha>
  local f; f="$(dga_store)"
  [ -r "$f" ] && awk -F'\t' -v w="$1" -v s="$2" '$2 == w && $3 == s { found = 1 } END { exit !found }' "$f"
}

dga_record() {  # <who> <sha>
  local f; f="$(dga_store)"
  mkdir -p "${f%/*}" && printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" >>"$f"
}

# When the work tree was created: the birth of its git dir, else (no birth
# time on this fs) the mtime of a linked worktree's commondir, which git
# writes once. Empty when neither is known.
dga_tree_born() {  # <top>
  local g b=""
  g="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  b="$(stat -c %W "$g" 2>/dev/null || true)"
  if [[ ! "$b" =~ ^[1-9][0-9]*$ ]] && [ -f "$g/commondir" ]; then
    b="$(stat -c %Y "$g/commondir" 2>/dev/null || true)"
  fi
  [[ "$b" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$b"
  return 0
}

dga_grandfathered() {  # <top> <sha>
  local cut born c at
  cut="$(date -u -d "${DEV_GUIDE_ACK_CUTOFF:-$DGA_CUTOFF_DEFAULT}" +%s 2>/dev/null)" || return 1
  born="$(dga_tree_born "$1")"
  [ -n "$born" ] && [ "$born" -ge "$cut" ] && return 1
  c="$(git -C "$1" rev-list -1 --before="@$cut" HEAD -- "$DGA_GUIDE_REL" 2>/dev/null || true)"
  [ -n "$c" ] || return 1
  at="$(git -C "$1" rev-parse -q --verify "$c:$DGA_GUIDE_REL" 2>/dev/null || true)"
  [ "$at" = "$2" ]
}

# rc 0 pass, rc 1 refuse. Sets DGA_WHY to one line for the hook's log; on a
# refusal prints the one command that fixes it on stderr.
# shellcheck disable=SC2034  # DGA_WHY is the caller's to read
dga_check() {  # <top>
  local top="$1" sha who
  DGA_WHY=""
  sha="$(dga_head_sha "$top")"
  [ -n "$sha" ] || { DGA_WHY="no developer guide in HEAD"; return 0; }
  who="$(dga_who "$top")"
  if dga_has_ack "$who" "$sha"; then DGA_WHY="acked by $who (${sha:0:9})"; return 0; fi
  if dga_grandfathered "$top" "$sha"; then DGA_WHY="grandfathered tree, guide unchanged since the cutoff"; return 0; fi
  DGA_WHY="no ack by $who for developer guide ${sha:0:9}"
  echo "pre-push: REFUSED -- $who has not confirmed reading the developer guide (blob ${sha:0:9}). Read $DGA_GUIDE_REL, then, as the user that pushes ($(id -un 2>/dev/null)): cd $top/csi-spl-orc && AGENT_ID=$who DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack" >&2
  return 1
}
