#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y18: grok sessions load the fleet lessons claude keeps in
# its auto-memory (SPL-2738, spec 048 section 5).
#
#   spool_install_grok_memory <home> <dry 0|1> [repo]
#
# Claude Code loads <home>/.claude/projects/<slug>/memory/MEMORY.md (an index,
# one line per fact file) into every session started in <repo>; <slug> is the
# repo's absolute path with every non-alphanumeric character turned into "-".
# grok reads no such dir, but it loads every *.md in <home>/.grok/rules at
# session start and follows a symlink there anywhere. So this step writes two
# home rules and copies no memory text (one source, nothing to drift):
#   fleet-memory-0-where.md  a short header: where the index and its fact
#                            files are on this box, read the files a line
#                            names before working in that area, verify a
#                            lesson against the tree, never post or commit it
#   fleet-memory-1-index.md  a symlink to that claude MEMORY.md itself
# <repo> defaults to SPOOL_INSTALL_CLAUDE_MEMORY_REPO, else the main worktree
# of the checkout this step lives in (claude keys a worktree's memory to it).
# A home without .grok, or a repo without a claude MEMORY.md, is skipped and
# named. A same-named header without this step's marker, or a regular file
# in place of the symlink, is left alone and named
# (SPOOL_INSTALL_GROK_MEMORY_FORCE=1 replaces it). Idempotent.
# SPOOL_INSTALL_GROK_MEMORY=0 skips the step.
#------------------------------------------------------------------------------
Y18_MARK='<!-- spool-install: y18 grok-memory header -->'

_y18_say() { echo "spool-install: grok memory: $*" >&2; }

# The claude project slug of an absolute path: /opt/x/y-z -> -opt-x-y-z.
_y18_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

_y18_repo() {
  local here common
  if [ -n "${SPOOL_INSTALL_CLAUDE_MEMORY_REPO:-}" ]; then
    printf '%s\n' "$SPOOL_INSTALL_CLAUDE_MEMORY_REPO"
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dirname "$common"
}

_y18_header() {  # MEMDIR REPO
  cat <<EOF
# Fleet memory: the lessons claude agents of this box keep

The next rule file (fleet-memory-1-index.md) is the index of the memory every
claude session in $2 loads: one line per lesson, each linking a file
of $1/ (a link such as \`(x.md)\` is $1/x.md).
- Before you work in an area, read the files its index lines name; an
  "Area index" line names a second index in the same dir.
- A lesson can be out of date: check it against the current tree and trust
  what you measure when the two disagree.
- These files stay on this box: never post their text in a hub topic, never
  commit it, never quote it in a brief for another box.
$Y18_MARK
EOF
}

spool_install_grok_memory() {
  local home="$1" dry="${2:-0}" repo="${3:-}" memdir rules hdr idx want hdr_ok=0 idx_ok=0
  local force="${SPOOL_INSTALL_GROK_MEMORY_FORCE:-0}"
  if [ "${SPOOL_INSTALL_GROK_MEMORY:-1}" = 0 ]; then _y18_say "skipped (SPOOL_INSTALL_GROK_MEMORY=0)"; return 0; fi
  [ -d "$home/.grok" ] || { _y18_say "no $home/.grok (grok not installed for this user): skipped"; return 0; }
  [ -n "$repo" ] || repo="$(_y18_repo)" || { _y18_say "cannot tell the repo (set SPOOL_INSTALL_CLAUDE_MEMORY_REPO)"; return 7; }
  memdir="$home/.claude/projects/$(_y18_slug "$repo")/memory"
  if [ ! -f "$memdir/MEMORY.md" ]; then
    _y18_say "no claude memory index $memdir/MEMORY.md for $repo: skipped (SPOOL_INSTALL_CLAUDE_MEMORY_REPO names the repo)"
    return 0
  fi
  rules="$home/.grok/rules"
  hdr="$rules/fleet-memory-0-where.md"
  idx="$rules/fleet-memory-1-index.md"
  want="$(_y18_header "$memdir" "$repo")"
  [ -f "$hdr" ] && [ ! -L "$hdr" ] && [ "$(cat "$hdr")" = "$want" ] && hdr_ok=1
  [ -L "$idx" ] && [ "$(readlink "$idx")" = "$memdir/MEMORY.md" ] && idx_ok=1
  if [ "$hdr_ok" = 1 ] && [ "$idx_ok" = 1 ]; then _y18_say "$rules already current ($memdir)"; return 0; fi
  if [ "$force" != 1 ]; then
    if [ "$hdr_ok" = 0 ] && { [ -e "$hdr" ] || [ -L "$hdr" ]; } && ! grep -qxF "$Y18_MARK" "$hdr" 2>/dev/null; then
      _y18_say "WARN $hdr was not written by this step: kept, grok misses the memory (SPOOL_INSTALL_GROK_MEMORY_FORCE=1 replaces it)"
      return 0
    fi
    if [ "$idx_ok" = 0 ] && [ -e "$idx" ] && [ ! -L "$idx" ]; then
      _y18_say "WARN $idx is a file, not this step's symlink: kept, grok misses the memory (SPOOL_INSTALL_GROK_MEMORY_FORCE=1 replaces it)"
      return 0
    fi
  fi
  if [ "$dry" = 1 ]; then
    [ "$hdr_ok" = 1 ] || echo "would: write $hdr"
    [ "$idx_ok" = 1 ] || echo "would: ln -s $memdir/MEMORY.md $idx"
    return 0
  fi
  mkdir -p "$rules" || return 7
  if [ "$hdr_ok" = 0 ]; then
    rm -f "$hdr" && printf '%s\n' "$want" >"$hdr.tmp.$$" && mv -f "$hdr.tmp.$$" "$hdr" || return 7
  fi
  if [ "$idx_ok" = 0 ]; then
    rm -f "$idx" && ln -s "$memdir/MEMORY.md" "$idx" || return 7
  fi
  _y18_say "grok loads the claude memory index of $repo through $rules ($memdir)"
}
