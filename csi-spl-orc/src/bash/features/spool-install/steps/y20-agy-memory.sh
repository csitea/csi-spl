#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y20: agy sessions load the fleet lessons claude keeps in
# its auto-memory that are on the box's allow-list (SPL-4911, spec 048 section
# 5.3); the agy twin of Y18 (grok), filtered because of the data rule: work that
# carries secrets or personal data never goes to agy, grok may take it.
#
#   spool_install_agy_memory <home> <dry 0|1> [repo]
#
# Claude Code loads <home>/.claude/projects/<slug>/memory/MEMORY.md (an index,
# one line per fact file) into every session started in <repo>; <slug> is the
# repo's absolute path with every non-alphanumeric character turned into "-".
# agy 1.5.1 reads no such dir. It loads a <home>/.gemini/config/rules/*.md
# only when the file opens with "trigger: always_on" frontmatter (without it
# the log says "Invalid rule trigger" and the text never reaches the model),
# but it loads rules/AGENTS.md with no frontmatter.
#
# agy-allow.list, beside MEMORY.md and never in git, names one fact file a line
# ("#" starts a comment). A file goes on it only after a claude seat read that
# whole file and its index line and found no secret, credential path, customer
# or personal data. Default deny: no list, an empty list or no line left = no
# index, the step says so and removes what it wrote earlier. This step writes:
#   fleet-memory-0-where.md  an always_on header: where the lessons are, the
#                            listed files only, follow no link out of them
#   AGENTS.md                generated from MEMORY.md: only the lines whose every
#                            link is a listed file; re-install regenerates it
# The list limits what is loaded and what agy is told to read. It is no access
# boundary: agy runs as the user who owns these files.
#
# A listed file that is gone, or has no index line, is dropped and named.
# <repo> defaults to SPOOL_INSTALL_CLAUDE_MEMORY_REPO, else the main worktree
# of the checkout this step lives in (claude keys a worktree's memory to it).
# A home without .gemini, or a repo without a claude MEMORY.md, is skipped and
# named. A same-named header without this step's marker, or an AGENTS.md that is
# neither this step's file nor a symlink to a claude MEMORY.md, is left alone
# and named (SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it). Idempotent.
# SPOOL_INSTALL_AGY_MEMORY=0 skips the step.
#------------------------------------------------------------------------------
Y20_MARK='<!-- spool-install: y20 agy-memory header -->'
Y20_IDX_MARK='<!-- spool-install: y20 agy-memory index, generated from MEMORY.md and agy-allow.list -->'
Y20_LIST=agy-allow.list

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

# The listed fact files that exist, sorted, one per line; the others are named.
_y20_listed() {  # MEMDIR
  local name
  [ -f "$1/$Y20_LIST" ] || return 0
  while IFS= read -r name || [ -n "$name" ]; do
    name="${name%%#*}"
    name="${name//[[:space:]]/}"
    [ -n "$name" ] || continue
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+\.md$ ]] || [ "$name" = MEMORY.md ]; then
      _y20_say "WARN $Y20_LIST: $name is no fact file name: dropped"
    elif [ ! -f "$1/$name" ]; then
      _y20_say "WARN $Y20_LIST: $name is gone from $1: dropped"
    else
      printf '%s\n' "$name"
    fi
  done <"$1/$Y20_LIST" | sort -u
}

# The MEMORY.md lines with a link, every link of them a listed file.
_y20_index_lines() {  # MEMORY.md LISTED(non-empty, one per line)
  awk 'NR == FNR { ok[$0] = 1; next }
    { s = $0; n = 0; bad = 0
      while (match(s, /\]\([^)]*\)/)) {
        n++
        if (!(substr(s, RSTART + 2, RLENGTH - 3) in ok)) bad = 1
        s = substr(s, RSTART + RLENGTH)
      }
      if (n > 0 && !bad) print }' <(printf '%s\n' "$2") "$1"
}

_y20_header() {  # MEMDIR REPO LISTED
  local name
  cat <<EOF
---
trigger: always_on
---
# Fleet memory: the lessons claude agents of this box keep

The AGENTS.md rule of this dir holds the lessons of the claude memory of $2
that were read and found fit for agy sessions: one line per lesson, each
linking a file of $1/ (a link such as \`(x.md)\` is $1/x.md).
The files you may use from there, and no other:
EOF
  while IFS= read -r name; do printf -- '- %s\n' "$name"; done <<<"$3"
  cat <<EOF

- Before you work in an area, read the listed files its lines name.
- Read no other file of that dir, and follow no link out of a listed file to a
  file not listed here: the fleet's data rule keeps secrets, credentials,
  customer and personal data away from agy sessions.
- A lesson can be out of date: check it against the current tree and trust
  what you measure when the two disagree.
- These files stay on this box: never post their text in a hub topic, never
  commit it, never quote it in a brief for another box.
$Y20_MARK
EOF
}

_y20_header_ours() { grep -qxF "$Y20_MARK" "$1" 2>/dev/null; }

# 0 when rules/AGENTS.md may be replaced: absent, this step's generated file, or
# a symlink to a claude MEMORY.md (an install of the first shape, the whole index).
_y20_idx_ours() {
  { [ ! -e "$1" ] && [ ! -L "$1" ]; } && return 0
  if [ -L "$1" ]; then
    [[ "$(readlink "$1")" == */.claude/projects/*/memory/MEMORY.md ]]
    return
  fi
  [ "$(head -1 "$1" 2>/dev/null)" = "$Y20_IDX_MARK" ]
}

# Default deny: no line may reach agy, so what this step wrote earlier goes too.
_y20_deny() {  # RULES DRY MEMDIR
  local hdr="$1/fleet-memory-0-where.md" idx="$1/AGENTS.md" f
  _y20_say "no lesson on the allow-list $3/$Y20_LIST: agy gets no index"
  { [ -e "$idx" ] || [ -L "$idx" ]; } && _y20_idx_ours "$idx" && f="$idx" || f=""
  if [ -n "$f" ]; then
    if [ "$2" = 1 ]; then echo "would: remove $f"; else rm -f "$f" || return 7; fi
  fi
  if [ -e "$hdr" ] && _y20_header_ours "$hdr"; then
    if [ "$2" = 1 ]; then echo "would: remove $hdr"; else rm -f "$hdr" || return 7; fi
  fi
  return 0
}

_y20_write() {  # PATH TEXT
  rm -f "$1" && printf '%s\n' "$2" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

spool_install_agy_memory() {
  local home="$1" dry="${2:-0}" repo="${3:-}" memdir rules hdr idx want want_idx lines listed name shown="" hdr_ok=0 idx_ok=0
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
  listed="$(_y20_listed "$memdir")"
  lines=""
  [ -z "$listed" ] || lines="$(_y20_index_lines "$memdir/MEMORY.md" "$listed")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [[ "$lines" == *"]($name)"* ]]; then shown+="${shown:+$'\n'}$name"
    else _y20_say "WARN $Y20_LIST: $name has no index line: dropped"; fi
  done <<<"$listed"
  if [ -z "$lines" ]; then _y20_deny "$rules" "$dry" "$memdir"; return; fi
  want="$(_y20_header "$memdir" "$repo" "$shown")"
  want_idx="$Y20_IDX_MARK"$'\n'"$lines"
  [ -f "$hdr" ] && [ ! -L "$hdr" ] && [ "$(cat "$hdr")" = "$want" ] && hdr_ok=1
  [ -f "$idx" ] && [ ! -L "$idx" ] && [ "$(cat "$idx")" = "$want_idx" ] && idx_ok=1
  if [ "$hdr_ok" = 1 ] && [ "$idx_ok" = 1 ]; then _y20_say "$rules already current ($memdir)"; return 0; fi
  if [ "$force" != 1 ]; then
    if [ "$hdr_ok" = 0 ] && { [ -e "$hdr" ] || [ -L "$hdr" ]; } && ! _y20_header_ours "$hdr"; then
      _y20_say "WARN $hdr was not written by this step: kept, agy misses the memory (SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it)"
      return 0
    fi
    if [ "$idx_ok" = 0 ] && ! _y20_idx_ours "$idx"; then
      _y20_say "WARN $idx is not this step's file: kept, agy misses the memory (SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it)"
      return 0
    fi
  fi
  if [ "$dry" = 1 ]; then
    [ "$hdr_ok" = 1 ] || echo "would: write $hdr"
    [ "$idx_ok" = 1 ] || echo "would: write $idx"
    return 0
  fi
  mkdir -p "$rules" || return 7
  [ "$hdr_ok" = 1 ] || _y20_write "$hdr" "$want" || return 7
  [ "$idx_ok" = 1 ] || _y20_write "$idx" "$want_idx" || return 7
  _y20_say "agy loads the allow-listed lessons of $repo through $rules ($memdir)"
}
