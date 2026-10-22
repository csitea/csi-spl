#!/usr/bin/env bash
# SPL-2864: the spawn's fetch of the main checkout never prompts. A lane
# rotation of a seat whose worktree is another repo with an https origin
# (rid 20261022T1101Z-lane-c-179) stopped its new pane at "Username for
# 'https://...':" and failed SPAWN after 120 s, every 15 min. Hermetic: the
# origin is a local remote helper that asks for a login the way an https
# remote does (git credential fill), run on a pty (script) so the prompt can
# block; no network. Fixed: no prompt, one WARN, the worktree still made.
# Red control: the pre-fix spawn-core blocks on the prompt until `timeout`.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
command -v script >/dev/null || { echo "SKIP: no script(1) for a pty"; exit 0; }
id() { git -c user.name=FirstName\ LastName -c user.email=dev@example.com "$@"; }
# no global/system credential helper may answer the prompt
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$T_TMP"
unset GIT_ASKPASS SSH_ASKPASS GIT_TERMINAL_PROMPT
export FETCH_FRESH_MAX_AGE=0
mkdir -p "$T_TMP/bin"
cat > "$T_TMP/bin/git-remote-prompt" <<'H'
#!/usr/bin/env bash
printf 'protocol=https\nhost=git.example.invalid\n\n' | git credential fill >/dev/null
exit 1
H
chmod +x "$T_TMP/bin/git-remote-prompt"
export PATH="$T_TMP/bin:$PATH"

git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && id -C "$T_TMP/repo" commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null
git -C "$T_TMP/repo" fetch -q origin 2>/dev/null
git -C "$T_TMP/repo" remote set-url origin "prompt::https://git.example.invalid/repo.git"

# _spawn_worktree as a rotation's launcher runs it, on a pty, bounded.
# Prints its output, then "RC <exit>". CORE: the spawn-core to load.
cat > "$T_TMP/run-wt.sh" <<'R'
. "$1/../lib/spool-env.inc.sh"; . "$5"
_SP_DIR="$1" WORKDIR="$2" TITLE="$3" SLUG="$4"
_spawn_worktree
echo "RESULT branch=${BRANCH} rundir=${RUNDIR}"
R
wt() {  # TITLE CORE WAIT
  local out rc=0
  # stdin a fifo opened read-write: never data, never an EOF (an EOF on the
  # pty would answer the prompt)
  [ -p "$T_TMP/stdin" ] || mkfifo "$T_TMP/stdin"
  out="$(SPAWN_DRY_RUN=0 SPAWN_REUSE_ID=1 SHELL=/bin/bash timeout "$3" \
    script -qfec "bash $T_TMP/run-wt.sh $T_SCRIPTS $T_TMP/repo $1 rotate $2" /dev/null 0<>"$T_TMP/stdin" 2>&1)" || rc=$?
  printf '%s\nRC %s\n' "$out" "$rc"
}

# --- 1. fixed: no prompt, fails fast, one WARN, the worktree is made -------
t0=$SECONDS
out="$(wt c-401 "$T_SCRIPTS/spawn-core.inc.sh" 30)"
el=$(( SECONDS - t0 ))
hasnt "fixed: no login prompt on the pane" "Username for" "$out"
has "fixed: the launcher went on" "RESULT branch=c-401-rotate rundir=$T_TMP/repo-wt/c-401" "$out"
has "fixed: one WARN names the step and the repo" "WARN: spawn fetch: git fetch origin master in $T_TMP/repo failed or timed out" "$out"
has "fixed: exit 0" "RC 0" "$out"
check "fixed: done well inside the wait (${el} s < 20 s)" test "$el" -lt 20

# --- 2. a fetch that hangs is cut at SPAWN_FETCH_TIMEOUT --------------------
cat > "$T_TMP/bin/git-remote-prompt" <<'H'
#!/usr/bin/env bash
sleep 60
H
t0=$SECONDS
out="$(SPAWN_FETCH_TIMEOUT=2 wt c-402 "$T_SCRIPTS/spawn-core.inc.sh" 30)"
el=$(( SECONDS - t0 ))
has "hang: the launcher went on" "RESULT branch=c-402-rotate" "$out"
has "hang: the WARN says timed out (exit 124)" "(exit 124, prompts off)" "$out"
check "hang: bounded (${el} s < 15 s)" test "$el" -lt 15
cat > "$T_TMP/bin/git-remote-prompt" <<'H'
#!/usr/bin/env bash
printf 'protocol=https\nhost=git.example.invalid\n\n' | git credential fill >/dev/null
exit 1
H

# --- 3. RED control: the pre-fix spawn-core blocks on the prompt -----------
old_core="$T_TMP/spawn-core.old.inc.sh"
awk '
  /^  # SPL-2864: it runs in the new pane/ { skip = 1; next }
  skip && /^  fi$/ { skip = 0
    print "  _sp_live && bash \"${_SP_DIR}/git-fetch-fresh.sh\" -C \"$REPO\" --branch \"$DEFBRANCH\" >/dev/null 2>&1"
    next }
  skip { next }
  { print }
' "$T_SCRIPTS/spawn-core.inc.sh" > "$old_core"
hasnt "control: the old copy has no prompt guard" "GIT_TERMINAL_PROMPT" "$(cat "$old_core")"
out="$(wt c-403 "$old_core" 8)"
has "control: the pane shows the login prompt" "Username for 'https://git.example.invalid'" "$out"
has "control: it hangs until timeout (124)" "RC 124" "$out"
hasnt "control: the launcher never got past it" "RESULT branch=c-403" "$out"

t_done
