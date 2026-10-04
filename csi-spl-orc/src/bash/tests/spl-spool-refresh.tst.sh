#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_spool_refresh + install.sh --binary-only, hermetic. A
# throwaway HOME holding the five config paths a full install writes; the
# spool build is a stub that writes a fake binary carrying a commit, read
# back by a SPOOL_INSTALL_BINREV stub; Go is a stub root. Every check has a
# failing control.
#   1. the dry run builds nothing and touches nothing
#   2. a live run: the new binary carries trunk, the old one is spool.bak,
#      and the five config paths are byte-identical (cmp against a copy)
#   3. a build that changes a config path is caught and named (control of 2)
#   4. a new binary with the wrong commit: refused, the old one untouched
#   5. a failing build: the old binary untouched
#   6. a checkout that is not at trunk: refused before any build
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

H="$T/home"; P="$H/.local"; BIN="$P/share/spool-agent/tools/bin/spool"
HEAD_SHA="$(git -C "$APP_ROOT" rev-parse HEAD)"
OLD_SHA=0000000000000000000000000000000000000001
mkdir -p "$H/.config/spool-agent" "$H/.claude" "$H/.local/mcp-bot" "$P/share/spool-agent/tools/bin" "$T/go/bin"
printf 'SPOOL_ENV=prd\nSPOOL_TENANT=t1\nSPOOL_BOX=box-x\n' >"$H/.config/spool-agent/env"
printf 'export X=1\n' >"$H/.bashrc"
printf '# fleet rules\n' >"$H/.claude/CLAUDE.md"
printf '{"hooks": {}}\n' >"$H/.claude/settings.json"
for n in mcp-start.sh mcp-start-chrome.sh reap-profiles.sh; do ln -s "/elsewhere/$n" "$H/.local/mcp-bot/$n"; done
printf '#!/bin/sh\n[ "$1" = version ] && echo "go version go1.99.0 linux/amd64"\nexit 0\n' >"$T/go/bin/go"
# fake binary: `version` prints 9.9.9; its commit is on its second line
mk_bin() { printf '#!/bin/sh\n# commit=%s\n[ "$1" = version ] && echo 9.9.9\nexit 0\n' "$2" >"$1"; chmod +x "$1"; }
printf '#!/bin/sh\nsed -n "s/^# commit=//p" "$1"\n' >"$T/binrev"
# the build stub: STUB_COMMIT (default HEAD), STUB_BUILD_FAIL=1 fails,
# STUB_TOUCH=<path> appends to that file (an installer that is not binary-only)
cat >"$T/build.sh" <<EOF
#!/bin/bash
[ "\${STUB_BUILD_FAIL:-0}" = 1 ] && exit 1
[ -n "\${STUB_TOUCH:-}" ] && echo touched >>"\$STUB_TOUCH"
printf '#!/bin/sh\n# commit=%s\n[ "\$1" = version ] && echo 9.9.9\nexit 0\n' "\${STUB_COMMIT:-$HEAD_SHA}" >"\$1"; chmod +x "\$1"
EOF
chmod +x "$T/go/bin/go" "$T/binrev" "$T/build.sh"
snap() { rm -rf "$T/snap"; mkdir -p "$T/snap"; cp -a "$H/.config/spool-agent/env" "$H/.bashrc" "$H/.claude/CLAUDE.md" "$H/.claude/settings.json" "$T/snap/"; cp -a "$H/.local/mcp-bot" "$T/snap/mcp"; }
same() {
  cmp -s "$T/snap/env" "$H/.config/spool-agent/env" && cmp -s "$T/snap/.bashrc" "$H/.bashrc" &&
    cmp -s "$T/snap/CLAUDE.md" "$H/.claude/CLAUDE.md" && cmp -s "$T/snap/settings.json" "$H/.claude/settings.json" &&
    [ "$(ls -l "$T/snap/mcp" | awk '{print $9,$10,$11}')" = "$(ls -l "$H/.local/mcp-bot" | awk '{print $9,$10,$11}')" ]
}
refresh() {
  SNIPPET='do_spl_spool_refresh' in_orc HOME="$H" XDG_CONFIG_HOME= SPOOL_INSTALL_PREFIX="$P" SPOOL_REFRESH_TRUNK=HEAD \
    SPOOL_INSTALL_BUILD="$T/build.sh" SPOOL_INSTALL_BINREV="$T/binrev" SPOOL_INSTALL_GO_ROOTS="$T/go" PATH="$T/go/bin:$PATH" USER=tester "$@" 2>&1
}

# 1. dry run
mk_bin "$BIN" "$OLD_SHA"; cp "$BIN" "$T/old.bin"; snap
out="$(refresh)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$BIN" "$T/old.bin" && [ ! -e "$BIN.bak" ] && same && grep -q 'OK DRY_RUN nothing was touched' <<<"$out" \
  && pass "1. the dry run builds nothing and touches nothing" || fail "1. dry run (rc $rc: $out)"
grep -q "BEFORE binary: commit $OLD_SHA version 9.9.9" <<<"$out" && pass "1. ...and prints the binary's commit and version" || fail "1. before line ($out)"

# 2. live run
out="$(refresh DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$("$T/binrev" "$BIN")" = "$HEAD_SHA" ] && cmp -s "$BIN.bak" "$T/old.bin" \
  && grep -q "AFTER binary: commit $HEAD_SHA" <<<"$out" && pass "2. the new binary carries trunk, the old one is spool.bak" || fail "2. live (rc $rc: $out)"
same && grep -q 'OK config: the five config paths are byte-identical' <<<"$out" \
  && pass "2. ...and the five config paths are byte-identical" || fail "2. config changed ($out)"
! compgen -G "$P/share/spool-agent/tools/bin/spool.new.*" >/dev/null && pass "2. ...no temp binary left behind" || fail "2. temp left ($(ls "$P/share/spool-agent/tools/bin"))"

# 3. control: a build that writes a config path is caught and named
out="$(refresh DRY_RUN=0 STUB_TOUCH="$H/.bashrc")"; rc=$?
[ "$rc" -ne 0 ] && grep -q "CHANGED config: $H/.bashrc" <<<"$out" && ! same \
  && pass "3. control: a changed config path fails the run and is named" || fail "3. control (rc $rc: $out)"
cp -a "$T/snap/.bashrc" "$H/.bashrc"

# 4. wrong commit
mk_bin "$BIN" "$OLD_SHA"; cp "$BIN" "$T/old.bin"
out="$(refresh DRY_RUN=0 STUB_COMMIT=0000000000000000000000000000000000000002)"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$BIN" "$T/old.bin" && grep -q "carries commit '0000000000000000000000000000000000000002', want $HEAD_SHA" <<<"$out" \
  && pass "4. a new binary with the wrong commit is refused, the old one untouched" || fail "4. wrong commit (rc $rc: $out)"

# 5. failing build
out="$(refresh DRY_RUN=0 STUB_BUILD_FAIL=1)"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$BIN" "$T/old.bin" && grep -q 'the spool build failed' <<<"$out" \
  && pass "5. a failing build leaves the old binary untouched" || fail "5. build fail (rc $rc: $out)"

# 6. not at trunk
out="$(refresh DRY_RUN=0 SPOOL_REFRESH_TRUNK=HEAD~1)"; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$BIN" "$T/old.bin" && grep -qE 'fetch first|cannot resolve' <<<"$out" && ! grep -q 'REFRESH' <<<"$out" \
  && pass "6. a checkout that is not at trunk is refused before any build" || fail "6. not at trunk (rc $rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
