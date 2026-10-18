#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spool-install step Y17 - the rm guard for the agent user (SPL-2474).
# Every case runs inside a mktemp sandbox: RM_GUARD_ROOT=$SB makes the
# sandbox stand for / and RM_GUARD_PASSWD a fake passwd, so no operand here
# can ever name a real system path. The rm behind the guard is the real one,
# so a guard that fails deletes sandbox files only, and the test sees it.
#   1. the step installs rm into a sandbox bin
#   2. a recursive rm of the sandbox /, a top-level dir (also through a
#      symlink), a home root, a direct child of one or an ancestor of one
#      (/mnt/data/home on a box whose homes live there) is refused: exit 2,
#      one line, nothing removed; -r, -R, -fr, --recursive and --rec all count
#   3. the a-779 command shape (a heredoc delimiter collision that runs
#      `rm -rf "$PROC"/*` with PROC unset) is refused; RED CONTROL: the same
#      script without the guard on PATH empties the sandbox
#   4. normal calls pass: rm -rf "$tmpdir", a deep home path, the sweep
#      crons' targets (a /tmp scratch dir, a worktree), a non-recursive rm
#   5. idempotent; a file in the way that is not ours is left alone (rc 7)
#   6. skipped for a user that is not the agent user, without --fleet, and
#      with SPOOL_INSTALL_RM_GUARD=0
#   7. install.sh calls the step exactly once
#   8. INFO: 1,000 calls of the real rm and of the guard (non-recursive and
#      recursive), printed, not asserted (the box load moves them)
#------------------------------------------------------------------------------
# shellcheck disable=SC2016  # the bash -c bodies expand in the child
set -euo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT="$(cd "$TEST_DIR/.." && pwd)"
STEP="$FEAT/steps/y17-rm-guard.sh"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
[ -n "$T" ] && [ -d "$T" ] || { echo "FAIL: no sandbox"; exit 1; }
trap '/bin/rm -rf -- "$T"' EXIT
ME="$(id -un)"
REAL_RM="$(command -v -p rm)"
SYS_PATH="$(dirname "$REAL_RM"):/usr/bin:/bin"

# 1. install
mkdir -p "$T/bin"
rc=0
out="$(env -u SPOOL_INSTALL_RM_GUARD SPOOL_AGENT_USER="$ME" bash -c '. "$1"; spool_install_rm_guard "$2" 0 1' _ "$STEP" "$T/bin" 2>&1)" || rc=$?
if [ "$rc" = 0 ] && [ -x "$T/bin/rm" ]; then pass "installs rm"
else fail "install rc=$rc: $out"; echo "test-y17-rm-guard: install failed, stopping"; exit 1; fi

# the sandbox tree: SB stands for /, its passwd names the homes
SB="$T/root"
mk_tree() {
  mkdir -p "$SB"/{boot,etc,opt/csi/csi-spl-wt/c-x/f,var/lib/svc,usr/bin,usr/local/bin,tmp/scratch.abc/f,root,home}
  mkdir -p "$SB/hm/owner/.npm/_cacache" "$SB/hm/owner/.claude" "$SB/hm/seat/.claude/projects/p"
  mkdir -p "$SB/mnt/data/home/agent" "$SB/mnt/data/other/x"
  : >"$SB/hm/owner/.claude/settings.json"
  : >"$SB/hm/owner/CLAUDE.md"
  [ -L "$SB/bin" ] || ln -s usr/bin "$SB/bin"
}
mk_tree
printf '%s\n' "root:x:0:0::/root:/bin/bash" "owner:x:1000:1000::/hm/owner:/bin/bash" \
  "seat:x:1001:1001::/hm/seat/:/bin/bash" "svc:x:998:998::/var/lib/svc:/usr/sbin/nologin" \
  "nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin" "sync:x:4:65534::/:/bin/sync" \
  "agent:x:1002:1002::/mnt/data/home/agent:/usr/local/bin/x" >"$T/passwd"
count() { find "$SB" | wc -l; }
before="$(count)"

# guard <args...>: rm as an agent shell runs it, the guard first on PATH
guard() { RM_GUARD_ROOT="$SB" RM_GUARD_PASSWD="$T/passwd" PATH="$T/bin:$SYS_PATH" rm "$@"; }

# 2. refusals
refused() {
  local label="$1" o r=0; shift
  o="$(guard "$@" 2>&1)" || r=$?
  if [ "$r" = 2 ] && [ "$(wc -l <<<"$o")" = 1 ] && [[ "$o" == "rm-guard: refused: "* ]] && [ "$(count)" = "$before" ]; then
    pass "refused: $label"
  else
    fail "$label: rc=$r out='$o' files $before -> $(count)"
    mk_tree
    before="$(count)"
  fi
}
refused "rm -rf /"                      -rf "$SB"
refused "rm -rf / (trailing slash)"     -rf "$SB/"
refused "rm -rf /* (glob expanded)"     -rf "$SB"/*
refused "rm -r /opt"                    -r "$SB/opt"
refused "rm -R /etc"                    -R "$SB/etc"
refused "rm --recursive /var"           --recursive "$SB/var"
refused "rm --rec -f /var (prefix)"     --rec -f "$SB/var"
refused "rm -fr /bin (a symlink)"       -fr "$SB/bin"
refused "rm -rf -- /home"               -rf -- "$SB/home"
refused "rm -rf a home root"            -rf "$SB/hm/owner"
refused "rm -rf home root, trailing / in passwd" -rf "$SB/hm/seat"
refused "rm -rf ~/.npm (home child)"    -rf "$SB/hm/owner/.npm"
refused "rm -rf ~/.claude via .."       -rf "$SB/hm/seat/x/../.claude"
refused "rm -rf a service home child"   -rf "$SB/var/lib/svc/data"
refused "rm -rf an ancestor of a home"  -rf "$SB/mnt/data/home"
refused "rm -rf a higher ancestor"      -rf "$SB/mnt/data"
refused "rm -rf a home below /mnt/data" -rf "$SB/mnt/data/home/agent"
refused "one bad operand among good"    -rf "$SB/tmp/scratch.abc" "$SB/hm/owner/CLAUDE.md"

# 3. the a-779 shape: the inner <<'EOF' stub closes the outer heredoc, the
# rest runs in the calling shell with PROC unset and no set -u. ${SB:?}
# keeps even a broken run inside the sandbox.
cat >"$T/a779.sh" <<'EOF_A779_SHAPE'
sudo_free_cat() { cat >"$SB/written.tst.sh"; }
sudo_free_cat << 'EOF'
set -uo pipefail
T=$(mktemp -d)
BIN="$T/bin" PROC="$T/proc"
cat >"$BIN/send-stub" <<'EOF'
echo stub
EOF
clear_procs() { rm -rf "${SB:?}$PROC"/*; }
clear_procs
echo after
EOF
EOF_A779_SHAPE
a779() {  # <PATH>
  env -u PROC -u BIN SB="$SB" RM_GUARD_ROOT="$SB" RM_GUARD_PASSWD="$T/passwd" PATH="$1" bash "$T/a779.sh" 2>&1 || true
}
o="$(a779 "$T/bin:$SYS_PATH")"
if grep -q "rm-guard: refused: recursive rm of a protected path: $SB/" <<<"$o" && [ "$(count)" -ge "$before" ]; then
  pass "a-779 shape: refused, sandbox intact"
else fail "a-779 shape not refused: $o (files $before -> $(count))"; fi
/bin/rm -f "$SB/written.tst.sh"
# RED CONTROL: without the guard the same script empties the sandbox root
o="$(a779 "$SYS_PATH")"
if [ ! -e "$SB/home" ] && [ ! -e "$SB/opt" ]; then pass "red control: without the guard the a-779 shape empties the sandbox /"
else fail "red control: the a-779 shape left the sandbox alone without the guard ($o)"; fi
mk_tree
before="$(count)"

# 4. pass-through, with the real rm
passed() {
  local label="$1" path="$2" o r=0; shift 2
  o="$(guard "$@" 2>&1)" || r=$?
  if [ "$r" = 0 ] && [ ! -e "$path" ]; then pass "passed: $label"
  else fail "$label: rc=$r out='$o' (exists: $([ -e "$path" ] && echo yes || echo no))"; fi
}
d="$(mktemp -d)"; : >"$d/f"
passed 'rm -rf "$tmpdir" (real tree, no sandbox root)' "$d" -rf "$d"
d="$(mktemp -d)"
passed 'tmp-scratch-sweep shape: rm -rf -- <mktemp dir>' "$d" -rf -- "$d"
passed "sweep target: a /tmp scratch dir"  "$SB/tmp/scratch.abc"  -rf -- "$SB/tmp/scratch.abc"
passed "gc / disk sweep: a worktree"        "$SB/opt/csi/csi-spl-wt/c-x" -rf "$SB/opt/csi/csi-spl-wt/c-x"
passed "a sibling of a home ancestor"     "$SB/mnt/data/other/x" -rf "$SB/mnt/data/other/x"
passed "a dir named like a shell field"  "$SB/usr/local" -rf "$SB/usr/local"
passed "a deep home path"                   "$SB/hm/seat/.claude/projects/p" -rf "$SB/hm/seat/.claude/projects/p"
passed "non-recursive rm of a home file"    "$SB/hm/owner/CLAUDE.md" -f "$SB/hm/owner/CLAUDE.md"
r=0; guard -f "$SB/nope" || r=$?
if [ "$r" = 0 ]; then pass "passed: rm -f of a missing file, rc 0"; else fail "rm -f missing rc=$r"; fi
r=0; guard "$SB/nope" 2>/dev/null || r=$?
if [ "$r" = 1 ]; then pass "passed: the real rm's own rc (1) comes back"; else fail "missing file rc=$r, want 1"; fi

# 5. idempotent; a file not ours
rc=0; out="$(SPOOL_AGENT_USER="$ME" bash -c '. "$1"; spool_install_rm_guard "$2" 0 1' _ "$STEP" "$T/bin" 2>&1)" || rc=$?
if [ "$rc" = 0 ] && grep -q 'already current' <<<"$out"; then pass "re-run: already current"
else fail "re-run rc=$rc: $out"; fi
mkdir -p "$T/other"; echo '#!/bin/sh' >"$T/other/rm"
rc=0; SPOOL_AGENT_USER="$ME" bash -c '. "$1"; spool_install_rm_guard "$2" 0 1' _ "$STEP" "$T/other" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 7 ] && [ "$(cat "$T/other/rm")" = '#!/bin/sh' ]; then pass "an rm not ours: left alone, rc 7"
else fail "not-ours rc=$rc"; fi

# 6. skips
skip_case() {
  local label="$1" dir="$T/skip-$2"; shift 2
  env "$@" bash -c '. "$1"; spool_install_rm_guard "$2" 0 "$3"' _ "$STEP" "$dir" "${FLEET_ARG:-1}" >/dev/null 2>&1 || true
  if [ ! -e "$dir/rm" ]; then pass "skipped: $label"; else fail "installed although $label"; fi
}
skip_case "not the agent user" a SPOOL_AGENT_USER="not-$ME"
FLEET_ARG=0 skip_case "no --fleet" b SPOOL_AGENT_USER="$ME"
skip_case "SPOOL_INSTALL_RM_GUARD=0" c SPOOL_AGENT_USER="$ME" SPOOL_INSTALL_RM_GUARD=0
skip_case "no agent user anywhere" d -u SPOOL_AGENT_USER SPOOL_BOX_ENV="$T/none.env"

# 7. wired once
c="$(grep -c 'spool_install_rm_guard "$BIN" "$DRY" "$FLEET"' "$FEAT/install.sh" || true)"
if [ "$c" = 1 ]; then pass "install.sh calls the step once"; else fail "install.sh calls the step $c times"; fi

# 8. timing, 1,000 calls each
ms() { local s e; s=$(date +%s%N); "$@"; e=$(date +%s%N); echo $(((e - s) / 1000000)); }
loop() { local i; for ((i = 0; i < 1000; i++)); do "$@" >/dev/null 2>&1 || true; done; }
mkdir -p "$T/t"
t_real="$(ms loop "$REAL_RM" -f "$T/t/none")"
t_guard="$(ms loop "$T/bin/rm" -f "$T/t/none")"
t_real_r="$(ms loop "$REAL_RM" -rf "$T/t/none")"
t_guard_r="$(ms loop "$T/bin/rm" -rf "$T/t/none")"
echo "INFO: 1000 x rm -f:  real ${t_real} ms, guard ${t_guard} ms; 1000 x rm -rf: real ${t_real_r} ms, guard ${t_guard_r} ms (load $(cut -d' ' -f1 /proc/loadavg))"

echo "test-y17-rm-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
