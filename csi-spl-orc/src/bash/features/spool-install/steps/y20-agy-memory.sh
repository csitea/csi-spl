#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y20: agy sessions load the fleet lessons claude keeps in
# its auto-memory (SPL-4911, spec 048 section 5); the agy twin of Y18 (grok).
#
#   spool_install_agy_memory <home> <dry 0|1> [repo]
#
# Claude Code loads <home>/.claude/projects/<slug>/memory/MEMORY.md (an index,
# one line per fact file) into every session started in <repo>; <slug> is the
# repo's absolute path with every non-alphanumeric character turned into "-".
# agy 1.5.1 reads no such dir. It loads a <home>/.gemini/config/rules/*.md
# only when the file opens with "trigger: always_on" frontmatter (without it
# the log says "Invalid rule trigger" and the text never reaches the model),
# but it loads rules/AGENTS.md with no frontmatter, and it follows a symlink
# there. MEMORY.md has no frontmatter, so this step writes two rules and
# copies no memory text (one source, nothing to drift):
#   fleet-memory-0-where.md  an always_on header: where the index and its fact
#                            files are on this box, read the files a line
#                            names before working in that area, verify a
#                            lesson against the tree, never post or commit it
#   AGENTS.md                a symlink to that claude MEMORY.md itself
# <repo> defaults to SPOOL_INSTALL_CLAUDE_MEMORY_REPO, else the main worktree
# of the checkout this step lives in (claude keys a worktree's memory to it).
# A home without .gemini, or a repo without a claude MEMORY.md, is skipped and
# named. A same-named header without this step's marker, or anything but a
# symlink to a claude MEMORY.md at rules/AGENTS.md, is left alone and named
# (SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it). Idempotent.
# SPOOL_INSTALL_AGY_MEMORY=0 skips the step.
#------------------------------------------------------------------------------
Y20_MARK='<!-- spool-install: y20 agy-memory header -->'

_y20_say() { echo "spool-install: agy memory: $*" >&2; }

# The claude project slug of an absolute path: /opt/x/y-z -> -opt-x-y-z.
_y20_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

_y20_repo() {
  local here common
  if [ -n "${SPOOL_INSTALL_CLAUDE_MEMORY_REPO:-}" ]; then
    printf '%s\n' "$SPOOL_INSTALL_CLAUDE_MEMORY_REPO"
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dirname "$common"
}

_y20_header() {  # MEMDIR REPO
  cat <<EOF
---
trigger: always_on
---
# Fleet memory: the lessons claude agents of this box keep

The AGENTS.md rule of this dir is the index of the memory every claude
session in $2 loads: one line per lesson, each linking a file of
$1/ (a link such as \`(x.md)\` is $1/x.md).
- Before you work in an area, read the files its index lines name; an
  "Area index" line names a second index in the same dir.
- A lesson can be out of date: check it against the current tree and trust
  what you measure when the two disagree.
- These files stay on this box: never post their text in a hub topic, never
  commit it, never quote it in a brief for another box.
$Y20_MARK
EOF
}

# 0 when rules/AGENTS.md may be replaced: absent, or a symlink to a claude
# MEMORY.md (this step's, perhaps for another repo).
_y20_idx_ours() {
  { [ ! -e "$1" ] && [ ! -L "$1" ]; } && return 0
  [ -L "$1" ] && [[ "$(readlink "$1")" == */.claude/projects/*/memory/MEMORY.md ]]
}

spool_install_agy_memory() {
  local home="$1" dry="${2:-0}" repo="${3:-}" memdir rules hdr idx want hdr_ok=0 idx_ok=0
  local force="${SPOOL_INSTALL_AGY_MEMORY_FORCE:-0}"
  if [ "${SPOOL_INSTALL_AGY_MEMORY:-1}" = 0 ]; then _y20_say "skipped (SPOOL_INSTALL_AGY_MEMORY=0)"; return 0; fi
  [ -d "$home/.gemini" ] || { _y20_say "no $home/.gemini (agy not installed for this user): skipped"; return 0; }
  [ -n "$repo" ] || repo="$(_y20_repo)" || { _y20_say "cannot tell the repo (set SPOOL_INSTALL_CLAUDE_MEMORY_REPO)"; return 7; }
  memdir="$home/.claude/projects/$(_y20_slug "$repo")/memory"
  if [ ! -f "$memdir/MEMORY.md" ]; then
    _y20_say "no claude memory index $memdir/MEMORY.md for $repo: skipped (SPOOL_INSTALL_CLAUDE_MEMORY_REPO names the repo)"
    return 0
  fi
  rules="$home/.gemini/config/rules"
  hdr="$rules/fleet-memory-0-where.md"
  idx="$rules/AGENTS.md"
  want="$(_y20_header "$memdir" "$repo")"
  [ -f "$hdr" ] && [ ! -L "$hdr" ] && [ "$(cat "$hdr")" = "$want" ] && hdr_ok=1
  [ -L "$idx" ] && [ "$(readlink "$idx")" = "$memdir/MEMORY.md" ] && idx_ok=1
  if [ "$hdr_ok" = 1 ] && [ "$idx_ok" = 1 ]; then _y20_say "$rules already current ($memdir)"; return 0; fi
  if [ "$force" != 1 ]; then
    if [ "$hdr_ok" = 0 ] && { [ -e "$hdr" ] || [ -L "$hdr" ]; } && ! grep -qxF "$Y20_MARK" "$hdr" 2>/dev/null; then
      _y20_say "WARN $hdr was not written by this step: kept, agy misses the memory (SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it)"
      return 0
    fi
    if [ "$idx_ok" = 0 ] && ! _y20_idx_ours "$idx"; then
      _y20_say "WARN $idx is not this step's symlink: kept, agy misses the memory (SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it)"
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
  _y20_say "agy loads the claude memory index of $repo through $rules ($memdir)"
}
