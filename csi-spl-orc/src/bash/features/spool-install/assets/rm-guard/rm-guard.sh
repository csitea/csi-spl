#!/bin/bash
# spool rm-guard, written by spool-install (y17-rm-guard.sh)
#------------------------------------------------------------------------------
# Installed as `rm` in the agent user's ~/.local/bin, ahead of /usr/bin. On
# 2026-10-17 a heredoc delimiter collision left PROC unset in an agent's tool
# shell and `rm -rf "$PROC"/*` ran as `rm -rf /*`: it emptied every
# group-writable dir in the box user's home. This refuses a RECURSIVE rm
# (-r, -R, --recursive, in any cluster or as a prefix) when ANY operand
# resolves (realpath -m: as written, and with its links followed) to:
#   /                    the root
#   /<dir>               a top-level dir (/bin, /home, /opt, /var, ...)
#   <home>               a home root from /etc/passwd (/home/<user>, /root)
#   <home>/<entry>       a direct child of one (~/.npm, ~/.claude)
#   <dir>/.../<home>     an ancestor of one (/mnt/data/home, /mnt/data)
# with exit 2 and one stderr line. A glob arrives expanded (/* = /bin /boot
# ...), so one matching operand refuses the whole call. Every other call goes
# unchanged to the next rm on PATH that is not this file. Only builtins
# decide, with no fork, unless an operand passes through a symlink (then one
# realpath per such operand). Re-run install.sh to rewrite this file.
# Tests only: RM_GUARD_ROOT=<dir> makes <dir> stand for / and
# RM_GUARD_PASSWD=<file> replaces /etc/passwd (home paths are read below that
# root), so a sandbox can play the real tree.
#------------------------------------------------------------------------------
set -u
REFUSED="rm-guard: refused: recursive rm of a protected path"
RULE="never rm -r /, a top-level dir, a home root or a direct child of one (an unset variable? use set -u)"

# real_rm: the next rm on PATH that is not this file (builtins only: -ef).
real_rm() {
  local d c dirs
  IFS=: read -ra dirs <<<"${PATH:-}"
  for d in "${dirs[@]}"; do
    c="${d:-.}/rm"
    { [ -x "$c" ] && [ ! -d "$c" ]; } || continue
    [ "$c" -ef "$0" ] && continue
    RM_REAL="$c"
    return 0
  done
  return 1
}

# norm <path>: NORM = the absolute path as written, with . and .. and //
# folded (realpath -m -s, in builtins); LINKED=1 when any step of it is a link.
norm() {
  local a="$1" c cur="" out=() parts
  [ "${a:0:1}" = / ] || a="$PWD/$a"
  LINKED=0
  IFS=/ read -ra parts <<<"$a"
  for c in "${parts[@]}"; do
    [ -n "$c" ] || continue
    cur="$cur/$c"
    [ "$LINKED" = 1 ] || { [ -L "$cur" ] && LINKED=1; }
    case "$c" in
      .) ;;
      ..) [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
      *) out+=("$c") ;;
    esac
  done
  local IFS=/
  NORM="/${out[*]}"
}

# protected <resolved-path>: 0 when a recursive rm of it is refused.
protected() {
  local p="$1" rest h
  if [ -n "$ROOT" ]; then
    if [ "$p" = "$ROOT" ]; then p=/
    elif [ "${p#"$ROOT"/}" != "$p" ]; then p="/${p#"$ROOT"/}"
    else return 1
    fi
  fi
  [ "$p" = / ] && return 0
  rest="${p#/}"
  [[ "$rest" == */* ]] || return 0
  # a home root, or a direct child of one: p or its parent is a home
  [[ "$HOMES" == *$'\n'"$p"$'\n'* || "$HOMES" == *$'\n'"${p%/*}"$'\n'* ]] && return 0
  # an ancestor of a home root (/mnt/data/home holds /mnt/data/home/<user>)
  [[ "$HOMES" == *$'\n'"$p/"* ]] && return 0
  return 1
}

recursive=0 ends=0 ops=()
for a in "$@"; do
  if [ "$ends" = 1 ]; then ops+=("$a"); continue; fi
  case "$a" in
    --) ends=1 ;;
    --r*) [[ --recursive == "$a"* ]] && recursive=1 ;;
    --*) ;;
    -?*) [[ "$a" == *[rR]* ]] && recursive=1 ;;
    *) ops+=("$a") ;;
  esac
done

if [ "$recursive" = 1 ] && [ "${#ops[@]}" -gt 0 ]; then
  ROOT="${RM_GUARD_ROOT:-}"
  ROOT="${ROOT%/}"
  # HOMES: the passwd home fields, one per line, without a trailing /
  HOMES=$'\n'
  while IFS=: read -r _ _ _ _ _ h _; do
    h="${h%/}"
    [ -n "$h" ] && HOMES+="$h"$'\n'
  done <"${RM_GUARD_PASSWD:-/etc/passwd}"
  for a in "${ops[@]}"; do
    [ -n "$a" ] || continue
    norm "$a"
    if protected "$NORM"; then
      echo "$REFUSED: $NORM; $RULE" >&2
      exit 2
    fi
    [ "$LINKED" = 1 ] || continue
    # a link on the way: check where it leads as well (/bin -> /usr/bin)
    p="$(realpath -m -- "$a" 2>/dev/null)" || p=""
    if [ -z "$p" ] || protected "$p"; then
      echo "$REFUSED: ${p:-$a (cannot resolve, fail closed)}; $RULE" >&2
      exit 2
    fi
  done
fi
real_rm || { echo "rm: no real rm on PATH" >&2; exit 127; }
exec "$RM_REAL" "$@"
