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
# agy-allow.list, beside MEMORY.md and never in git, holds one row per lesson
# ("#" starts a comment): <sha256 of the file> <sha256 of its index line> <file>.
# A row goes on it only after a claude seat read that whole file and that line
# and found no secret, credential path, customer or personal data; then
# spool_install_agy_memory_row <memdir> <file> prints the row. A file or a line
# that no longer matches its row is dropped and named until a seat reads it again
# (checked at each install). Default deny: no list, an empty list or no line left = no
# index, the step says so and removes what it wrote earlier. This step writes:
#   fleet-memory-0-where.md  an always_on header: where the lessons are, the
#                            listed files only, follow no link out of them
#   AGENTS.md                generated from MEMORY.md: only the lines whose every
#                            link is a listed file with this line's hash in its
#                            row; re-install regenerates it
# The list limits what is loaded and what agy is told to read. It is no access
# boundary: agy runs as the user who owns these files.
#
# A listed file that is gone, or has no index line, is dropped and named.
# <repo> defaults to SPOOL_INSTALL_CLAUDE_MEMORY_REPO, else the main worktree
# of the checkout this step lives in (claude keys a worktree's memory to it).
# A home without .gemini is skipped and named; a repo without a claude MEMORY.md
# too, and what this step wrote earlier goes. A same-named header without this
# step's marker, or an AGENTS.md that is neither this step's file nor a symlink to
# a claude MEMORY.md, is left alone and named (SPOOL_INSTALL_AGY_MEMORY_FORCE=1
# replaces it); the step's other file then goes too, so no stale or whole index
# stays behind it. Default deny names a foreign file the same way and then does not
# say "no index", because agy still loads that file. Idempotent.
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

_y20_sha() { sha256sum | cut -d' ' -f1; }

# The rows of agy-allow.list a seat appends for a file it read whole: one per
# index line that links it. Prints only; a row is one lesson as it reads now.
spool_install_agy_memory_row() {  # MEMDIR FILE
  local fh lines line
  [ ! -L "$1/$2" ] || { _y20_say "$1/$2 is a symlink: no row"; return 1; }
  [ -f "$1/$2" ] || { _y20_say "no $1/$2"; return 1; }
  lines="$(grep -F "]($2)" "$1/MEMORY.md")" || { _y20_say "$2 has no index line in $1/MEMORY.md"; return 1; }
  fh="$(_y20_sha <"$1/$2")"
  while IFS= read -r line; do
    printf '%s %s %s\n' "$fh" "$(printf '%s' "$line" | _y20_sha)" "$2"
  done <<<"$lines"
}

# "<file> <line sha>" of each row whose file exists and matches, sorted, one per
# line; the other rows are named.
_y20_rows() {  # MEMDIR
  local row fh lh name extra
  [ -f "$1/$Y20_LIST" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    row="${row%%#*}"
    fh="" lh="" name="" extra=""
    read -r fh lh name extra <<<"$row"
    [ -n "$fh" ] || continue
    if [ -n "$extra" ] || [ -z "$name" ] || [[ ! "$fh" =~ ^[0-9a-f]{64}$ ]] || [[ ! "$lh" =~ ^[0-9a-f]{64}$ ]]; then
      _y20_say "WARN $Y20_LIST: '$row' is no row <file sha256> <line sha256> <file>: dropped"
    elif [[ ! "$name" =~ ^[A-Za-z0-9._-]+\.md$ ]] || [ "$name" = MEMORY.md ]; then
      _y20_say "WARN $Y20_LIST: $name is no fact file name: dropped"
    elif [ -L "$1/$name" ]; then
      _y20_say "WARN $Y20_LIST: $name is a symlink: dropped"
    elif [ ! -f "$1/$name" ]; then
      _y20_say "WARN $Y20_LIST: $name is gone from $1: dropped"
    elif [ "$(_y20_sha <"$1/$name")" != "$fh" ]; then
      _y20_say "WARN $Y20_LIST: $name changed since a claude seat read it: dropped until one reads it again"
    else
      printf '%s %s\n' "$name" "$lh"
    fi
  done <"$1/$Y20_LIST" | sort -u
}

# The MEMORY.md lines with a link, every link a listed file whose row holds this
# line's hash; a line of a listed file that does not match is named.
_y20_index_lines() {  # MEMORY.md ROWS(non-empty, one per line)
  local line h link ok
  awk 'NR == FNR { ok[$1] = 1; next }
    { s = $0; n = 0; bad = 0
      while (match(s, /\]\([^)]*\)/)) {
        n++
        if (!(substr(s, RSTART + 2, RLENGTH - 3) in ok)) bad = 1
        s = substr(s, RSTART + RLENGTH)
      }
      if (n > 0 && !bad) print }' <(printf '%s\n' "$2") "$1" |
    while IFS= read -r line; do
      h="$(printf '%s' "$line" | _y20_sha)"
      ok=1
      while IFS= read -r link; do
        link="${link#](}"; link="${link%)}"
        if [[ $'\n'"$2"$'\n' != *$'\n'"$link $h"$'\n'* ]]; then
          ok=0
          _y20_say "WARN $Y20_LIST: $link: its index line changed since a claude seat read it: dropped until one reads it again"
        fi
      done < <(grep -oE '\]\([^)]*\)' <<<"$line")
      [ "$ok" = 0 ] || printf '%s\n' "$line"
    done
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
    [[ "$(readlink "$1")" == */.claude/projects/*/memory/MEMORY.md ]] ||
      [[ "$(readlink -f "$1")" == */.claude/projects/*/memory/MEMORY.md ]]
    return
  fi
  [ "$(head -1 "$1" 2>/dev/null)" = "$Y20_IDX_MARK" ]
}

_y20_rm() {  # PATH DRY
  if [ "$2" = 1 ]; then echo "would: remove $1"; else rm -f "$1" || return 7; fi
}

_y20_rm_idx() {  # IDX DRY
  if { [ -e "$1" ] || [ -L "$1" ]; } && _y20_idx_ours "$1"; then _y20_rm "$1" "$2"; fi
}

_y20_rm_hdr() {  # HDR DRY
  if [ -e "$1" ] && _y20_header_ours "$1"; then _y20_rm "$1" "$2"; fi
}

_y20_idx_foreign() { { [ -e "$1" ] || [ -L "$1" ]; } && ! _y20_idx_ours "$1"; }
_y20_hdr_foreign() { { [ -e "$1" ] || [ -L "$1" ]; } && ! _y20_header_ours "$1"; }

# Names what stays; removes this step's own files.
_y20_keep_foreign() {  # IDX HDR DRY HOW
  _y20_hdr_foreign "$2" && _y20_say "WARN $2 was not written by this step: kept, agy still reads it ($4)"
  _y20_idx_foreign "$1" && _y20_say "WARN $1 is not this step's file: kept, agy still loads it and no listed lesson ($4)"
  _y20_rm_idx "$1" "$3" || return 7
  _y20_rm_hdr "$2" "$3" || return 7
}

# Default deny: no line may reach agy, so what this step wrote earlier goes too;
# "no index" is said only when no foreign index stays.
_y20_deny() {  # IDX HDR DRY WHY
  if _y20_idx_foreign "$1"; then _y20_say "$4"; else _y20_say "$4: agy gets no index"; fi
  _y20_keep_foreign "$1" "$2" "$3" "remove it by hand"
}

_y20_write() {  # PATH TEXT
  rm -f "$1" && printf '%s\n' "$2" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

spool_install_agy_memory() {
  local home="$1" dry="${2:-0}" repo="${3:-}" memdir rules hdr idx want want_idx lines rows name shown="" hdr_ok=0 idx_ok=0
  local force="${SPOOL_INSTALL_AGY_MEMORY_FORCE:-0}"
  if [ "${SPOOL_INSTALL_AGY_MEMORY:-1}" = 0 ]; then _y20_say "skipped (SPOOL_INSTALL_AGY_MEMORY=0)"; return 0; fi
  [ -d "$home/.gemini" ] || { _y20_say "no $home/.gemini (agy not installed for this user): skipped"; return 0; }
  [ -n "$repo" ] || repo="$(_y20_repo)" || { _y20_say "cannot tell the repo (set SPOOL_INSTALL_CLAUDE_MEMORY_REPO)"; return 7; }
  memdir="$home/.claude/projects/$(_y20_slug "$repo")/memory"
  rules="$home/.gemini/config/rules"
  hdr="$rules/fleet-memory-0-where.md"
  idx="$rules/AGENTS.md"
  if [ ! -f "$memdir/MEMORY.md" ]; then
    _y20_deny "$idx" "$hdr" "$dry" "no claude memory index $memdir/MEMORY.md for $repo, skipped (SPOOL_INSTALL_CLAUDE_MEMORY_REPO names the repo)"
    return
  fi
  rows="$(_y20_rows "$memdir")"
  lines=""
  [ -z "$rows" ] || lines="$(_y20_index_lines "$memdir/MEMORY.md" "$rows")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [[ "$lines" == *"]($name)"* ]]; then shown+="${shown:+$'\n'}$name"
    else _y20_say "WARN $Y20_LIST: $name has no index line to load: dropped"; fi
  done < <(cut -d' ' -f1 <<<"$rows" | sort -u)
  if [ -z "$lines" ]; then
    _y20_deny "$idx" "$hdr" "$dry" "no lesson on the allow-list $memdir/$Y20_LIST"
    return
  fi
  want="$(_y20_header "$memdir" "$repo" "$shown")"
  want_idx="$Y20_IDX_MARK"$'\n'"$lines"
  [ -f "$hdr" ] && [ ! -L "$hdr" ] && [ "$(cat "$hdr")" = "$want" ] && hdr_ok=1
  [ -f "$idx" ] && [ ! -L "$idx" ] && [ "$(cat "$idx")" = "$want_idx" ] && idx_ok=1
  if [ "$hdr_ok" = 1 ] && [ "$idx_ok" = 1 ]; then _y20_say "$rules already current ($memdir)"; return 0; fi
  if [ "$force" != 1 ] && { _y20_hdr_foreign "$hdr" || _y20_idx_foreign "$idx"; }; then
    _y20_keep_foreign "$idx" "$hdr" "$dry" "SPOOL_INSTALL_AGY_MEMORY_FORCE=1 replaces it"
    return
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
