#!/usr/bin/env bash
# SPL-1898: a finished agent pane falls through to an interactive bash so the
# window stays visible. A plain `exec bash` read the box user's ~/.bashrc, whose
# identity loader runs `git config --global` three times; the lane rotation
# kills that window a second later, and a kill inside git's lock window left a
# stale ~/.gitconfig.lock (10-14 04:50:32Z = the c-296/c-373 rotations' CLOSE)
# that failed every agent's `git config --global` on the box. Every such
# fallback is `exec bash --norc`. SPL-3892: a --norc shell runs on bash's
# history defaults (500 lines, no histappend) and cut the box user's shared
# ~/.bash_history to 500 lines on exit (two boxes, 10-27), so every fallback
# is the one form PANE_SHELL below.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox

# An interactive fallback: `exec bash` with no script argument (end of line, or
# followed by ; } fi or the closing quote of a pane command).
NORC_RE="exec bash(\$|[;'}]| +(;|fi|\}))"
PANE_SHELL='exec env HISTSIZE=-1 HISTFILESIZE=-1 BASHOPTS=histappend bash --norc'
scan() {  # FILE... -> the offending lines
  grep -nE "$NORC_RE" "$@" 2>/dev/null
}
scan_hist() {  # FILE... -> code lines with a --norc shell not in the PANE_SHELL form
  grep -nE 'bash --norc' "$@" 2>/dev/null | grep -vE '^([^:]*:)?[0-9]+:[[:space:]]*#' | grep -vF "$PANE_SHELL"
}

# --- 1. the code: no fallback without --norc --------------------------------
ORC="$T_REPO/csi-spl-orc/src/bash"
files=("$T_SCRIPTS"/*.sh "$ORC/run/spl-lane-restart.func.sh")
eq "every pane fallback in spawn/restore/lane-restart is exec bash --norc" "" "$(scan "${files[@]}")"
eq "every pane fallback keeps the box user's history (SPL-3892)" "" "$(scan_hist "${files[@]}")"
n="$(cat "${files[@]}" | grep -cF "$PANE_SHELL")"
check "control: the scan sees the fallbacks it guards (>= 20, saw $n)" test "$n" -ge 20

# --- 2. control: the scan flags the old forms --------------------------------
printf '%s\n' '  exec bash' 'x || { echo e; exec bash; }' '  if _sp_live; then exec bash; fi' \
  "printf \"bash -c 'spool_agent_exec x; exec bash'\"" > "$T_TMP/old.sh"
eq "control: all 4 old forms are flagged" 4 "$(scan "$T_TMP/old.sh" | grep -c .)"
printf '%s\n' 'exec bash "$x" a' 'exec bash --norc' 'exec bash --norc; }' > "$T_TMP/new.sh"
eq "control: a script exec and --norc are not flagged" "" "$(scan "$T_TMP/new.sh")"
eq "control: both bare --norc forms are flagged by the history scan" 2 "$(scan_hist "$T_TMP/new.sh" | grep -c .)"
printf '%s\n' "  $PANE_SHELL" "x || { echo e; $PANE_SHELL; }" '# a comment on exec bash --norc' > "$T_TMP/hist.sh"
eq "control: the PANE_SHELL form and a comment are not flagged" "" "$(scan_hist "$T_TMP/hist.sh")"

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

# --- 4. SPL-3892: the fallback keeps the box user's history ------------------
# A --norc shell runs on bash defaults (HISTSIZE=HISTFILESIZE=500, no
# histappend) and cut the shared ~/.bash_history to 500 lines on exit (two
# boxes, 10-27). Run the REAL fallbacks under a pty on a 2000-line HISTFILE: the
# chain core's _ch_keep_pane, and an adapter's load fallback (its core absent).
hist_after() {  # CMD -> line count of the sandbox history after the pane exits
  local h="$T_TMP/hh"; rm -rf "$h"; mkdir -p "$h"; seq 1 2000 > "$h/.bash_history"
  env -u HISTFILE -u HISTSIZE -u HISTFILESIZE HOME="$h" script -qec "$1" /dev/null <<<$'echo pane-cmd\nexit' >/dev/null 2>&1
  wc -l < "$h/.bash_history"
}
if command -v script >/dev/null 2>&1; then
  eq "control: a bare --norc pane cuts the history to 500" 500 "$(hist_after 'bash --norc')"
  got="$(hist_after "bash -c '. \"$T_SCRIPTS/spawn-chain-core.inc.sh\"; _ch_keep_pane done'")"
  check "_ch_keep_pane keeps the 2000 history lines (got $got)" test "$got" -ge 2000
  mkdir -p "$T_TMP/nocore"; cp "$T_SCRIPTS/spawn-claude.sh" "$T_TMP/nocore/"
  got="$(hist_after "bash $T_TMP/nocore/spawn-claude.sh")"
  check "a load fallback (spawn-claude.sh, no core) keeps the 2000 lines (got $got)" test "$got" -ge 2000
else
  ok "skip: no script(1) for the history check"
fi

t_done
