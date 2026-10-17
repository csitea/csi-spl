#!/usr/bin/env bash
# test-gh-tmpdir-shim.sh — SPL-2336: a lane's gh gets a TMPDIR of its user's own.
# gh writes its run logs to $TMPDIR/gh-cli-cache (os.TempDir()); on a shared
# /tmp the first user owns that dir 0755 and every other user is denied. The
# stub gh below writes where gh writes. The other user's dir is a 0555 dir
# here (same denial, no second user or root needed).
#   1. CONTROL: without the shim the stub's write into that dir fails
#   2. the harness puts shims/ first on the lane's PATH, once
#   3. through the shim the write lands in <TMPDIR>/gh-<uid>, mode 700
#   4. only gh sees the new TMPDIR; a nested gh keeps the same dir
#   5. an unusable gh-<uid> dir warns and leaves TMPDIR as it was
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.inc.sh"
t_sandbox
H="$T_SCRIPTS/spool-harness.sh"
SHIMS="$T_FEAT/shims"
export HOME="$T_TMP/home"
unset SPOOL_HUB_URL SPOOL_BOX_ID SPOOL_KEYS_DIR GH_SHIM_TMPDIR
U="$(id -u)"

# The stub gh: `gh run view --log` writes its zip under os.TempDir().
SB="$T_TMP/stubbin"; mkdir -p "$SB"
cat >"$SB/gh" <<'EOF'
#!/bin/sh
d="${TMPDIR:-/tmp}/gh-cli-cache"
mkdir -p "$d" 2>/dev/null
touch "$d/run-log-1-2.zip" 2>/dev/null || { echo "failed to get run log: open $d/run-log-1-2.zip: permission denied" >&2; exit 1; }
echo "wrote $d"
EOF
chmod +x "$SB/gh"

# The shared /tmp, with the other user's gh-cli-cache in it.
SH="$T_TMP/shared"; mkdir -p "$SH/gh-cli-cache"; chmod 555 "$SH/gh-cli-cache"

# ── 1. CONTROL: no shim ──
err="$(TMPDIR="$SH" PATH="$SB:$PATH" gh run view 1 --log-failed 2>&1)"; rc=$?
eq "1. CONTROL: without the shim the run-log write fails (rc 1)" 1 "$rc"
has "1. CONTROL: ...with the defect's error" "permission denied" "$err"

# ── 2. the harness PATH ──
out="$(TMPDIR="$SH" PATH="$SB:$PATH" bash "$H" --as c-901 -- sh -c 'command -v gh' 2>/dev/null)"
eq "2. the lane's gh is the shim" "$SHIMS/gh" "${out%%$'\n'*}"
out="$(TMPDIR="$SH" PATH="$SB:$PATH" bash "$H" --as c-901 -- bash "$H" --as c-901 -- sh -c 'echo "$PATH"' 2>/dev/null)"
eq "2. a nested harness adds shims/ once" 1 "$(printf '%s\n' "$out" | tr : '\n' | grep -cxF "$SHIMS")"

# ── 3. through the shim ──
out="$(TMPDIR="$SH" PATH="$SB:$PATH" bash "$H" --as c-901 -- gh run view 1 --log-failed 2>"$T_TMP/err")"; rc=$?
eq "3. the lane's gh run view --log-failed exits 0" 0 "$rc"
eq "3. ...the zip lands in <TMPDIR>/gh-<uid>/gh-cli-cache" "wrote $SH/gh-$U/gh-cli-cache" "$out"
check "3. ...and is there" test -f "$SH/gh-$U/gh-cli-cache/run-log-1-2.zip"
eq "3. gh-<uid> is 700" 700 "$(stat -c %a "$SH/gh-$U")"
eq "3. silent on stderr" "" "$(cat "$T_TMP/err")"
out="$(PATH="$SHIMS:$SB:$PATH" env -u TMPDIR GH_SHIM_TMPDIR="$T_TMP/own" gh run view 1)"
eq "3. GH_SHIM_TMPDIR wins" "wrote $T_TMP/own/gh-cli-cache" "$out"

# ── 4. scope ──
out="$(TMPDIR="$SH" PATH="$SB:$PATH" bash "$H" --as c-901 -- sh -c 'echo "$TMPDIR"' 2>/dev/null)"
eq "4. the agent CLI keeps its own TMPDIR" "$SH" "$out"
out="$(TMPDIR="$SH/gh-$U" PATH="$SHIMS:$SB:$PATH" gh run view 1)"
eq "4. a gh run under the shim's TMPDIR keeps that dir" "wrote $SH/gh-$U/gh-cli-cache" "$out"
NG="$T_TMP/nogh"; mkdir -p "$NG"
for c in readlink dirname id; do ln -s "$(command -v "$c")" "$NG/$c"; done
PATH="$SHIMS:$NG" "$BASH" "$SHIMS/gh" --version >/dev/null 2>"$T_TMP/err"; rc=$?
eq "4. no gh besides the shim -> 127" 127 "$rc"
has "4. ...and says so" "no gh on PATH" "$(cat "$T_TMP/err")"

# ── 5. an unusable dir ──
S2="$T_TMP/shared2"; mkdir -p "$S2/gh-$U"; chmod 555 "$S2/gh-$U"
out="$(TMPDIR="$S2" PATH="$SHIMS:$SB:$PATH" gh run view 1 2>"$T_TMP/err")"
eq "5. a read-only gh-<uid>: gh runs with the old TMPDIR" "wrote $S2/gh-cli-cache" "$out"
has "5. ...and the shim warns" "gh-shim: $S2/gh-$U is not a dir of" "$(cat "$T_TMP/err")"

chmod 755 "$SH/gh-cli-cache" "$S2/gh-$U"
t_done
