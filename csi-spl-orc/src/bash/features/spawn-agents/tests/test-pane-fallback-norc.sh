#!/usr/bin/env bash
# SPL-1898: a finished agent pane falls through to an interactive bash so the
# window stays visible. A plain `exec bash` read the box user's ~/.bashrc, whose
# identity loader runs `git config --global` three times; the lane rotation
# kills that window a second later, and a kill inside git's lock window left a
# stale ~/.gitconfig.lock (10-14 04:50:32Z = the c-296/c-373 rotations' CLOSE)
# that failed every agent's `git config --global` on the box. Every such
# fallback is `exec bash --norc`.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox

# An interactive fallback: `exec bash` with no script argument (end of line, or
# followed by ; } fi or the closing quote of a pane command).
NORC_RE="exec bash(\$|[;'}]| +(;|fi|\}))"
scan() {  # FILE... -> the offending lines
  grep -nE "$NORC_RE" "$@" 2>/dev/null
}

# --- 1. the code: no fallback without --norc --------------------------------
ORC="$T_REPO/csi-spl-orc/src/bash"
files=("$T_SCRIPTS"/*.sh "$ORC/run/spl-lane-restart.func.sh")
eq "every pane fallback in spawn/restore/lane-restart is exec bash --norc" "" "$(scan "${files[@]}")"
n="$(cat "${files[@]}" | grep -cE 'exec bash --norc')"
check "control: the scan sees the fallbacks it guards (>= 20, saw $n)" test "$n" -ge 20

# --- 2. control: the scan flags the old forms --------------------------------
printf '%s\n' '  exec bash' 'x || { echo e; exec bash; }' '  if _sp_live; then exec bash; fi' \
  "printf \"bash -c 'spool_agent_exec x; exec bash'\"" > "$T_TMP/old.sh"
eq "control: all 4 old forms are flagged" 4 "$(scan "$T_TMP/old.sh" | grep -c .)"
printf '%s\n' 'exec bash "$x" a' 'exec bash --norc' 'exec bash --norc; }' > "$T_TMP/new.sh"
eq "control: a script exec and --norc are not flagged" "" "$(scan "$T_TMP/new.sh")"

# --- 3. the mechanism, under a pty: bash reads ~/.bashrc, bash --norc does not
if command -v script >/dev/null 2>&1; then
  H="$T_TMP/home"; mkdir -p "$H"
  printf 'touch "%s/rc-ran"\n' "$H" > "$H/.bashrc"
  HOME="$H" script -qec "bash" /dev/null <<<'exit' >/dev/null 2>&1
  check "control: an interactive bash runs the sandbox ~/.bashrc" test -e "$H/rc-ran"
  rm -f "$H/rc-ran"
  HOME="$H" script -qec "bash --norc" /dev/null <<<'exit' >/dev/null 2>&1
  check "bash --norc does not run ~/.bashrc" test ! -e "$H/rc-ran"
else
  ok "skip: no script(1) for the pty check"
fi

t_done
