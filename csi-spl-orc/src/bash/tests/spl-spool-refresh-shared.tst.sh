#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_spool_refresh in its ONE-installed-copy mode, hermetic. A
# fixture box with two users (tester = $USER, other = a second home reached
# through a SPOOL_REFRESH_AS stub standing in for `sudo -n -u`), each with
# its own real spool copy at a different old commit and the five config
# paths. The build and the commit reader are the stubs of
# spl-spool-refresh.tst.sh. Every check has a failing control.
#   0. without SPOOL_SHARED_BIN and no link yet: the per-user mode (never
#      adopted implicitly), the adopt line printed, the other user untouched
#   1. the dry run touches neither home and builds no shared copy
#   2. one live run: both users' spool resolve to the SAME file, the shared
#      copy, at trunk; each old real copy is kept as spool.bak; both users'
#      five config paths are byte-identical
#   3. a second run, WITHOUT SPOOL_SHARED_BIN (the cron), follows the
#      adopted link and changes nothing (no build, no relink: same tree)
#   4. control: a user hop that fails is named, the run fails, and that
#      user's own copy is untouched
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

HEAD_SHA="$(git -C "$APP_ROOT" rev-parse HEAD)"
SHARED="$T/shared/bin/spool"
H1="$T/home1"; H2="$T/home2"
TL=.local/share/spool-agent/tools/bin/spool
mkdir -p "$T/go/bin"
printf '#!/bin/sh\n[ "$1" = version ] && echo "go version go1.99.0 linux/amd64"\nexit 0\n' >"$T/go/bin/go"
printf '#!/bin/sh\nsed -n "s/^# commit=//p" "$1"\n' >"$T/binrev"
mk_bin() { printf '#!/bin/sh\n# commit=%s\n[ "$1" = version ] && echo 9.9.9\nexit 0\n' "$2" >"$1"; chmod +x "$1"; }
cat >"$T/build.sh" <<STUB
#!/bin/bash
echo build >>"$T/builds"
printf '#!/bin/sh\n# commit=%s\n[ "\$1" = version ] && echo 9.9.9\nexit 0\n' "$HEAD_SHA" >"\$1"; chmod +x "\$1"
STUB
# the user hop: "<as> <user> -- <cmd...>", logged; as-fail refuses every hop
printf '#!/bin/sh\necho "$1" >>"%s/hops"; shift; [ "$1" = -- ] && shift; exec "$@"\n' "$T" >"$T/as"
printf '#!/bin/sh\necho "sudo: a password is required" >&2; exit 1\n' >"$T/as-fail"
chmod +x "$T/go/bin/go" "$T/binrev" "$T/build.sh" "$T/as" "$T/as-fail"
for h in "$H1" "$H2"; do
  mkdir -p "$h/.config/spool-agent" "$h/.claude" "$h/.local/mcp-bot" "$h/.local/bin" "${h}/${TL%/*}"
  printf 'SPOOL_ENV=prd\nSPOOL_TENANT=t1\n' >"$h/.config/spool-agent/env"
  printf 'export X=%s\n' "${h##*/}" >"$h/.bashrc"
  printf '# rules\n' >"$h/.claude/CLAUDE.md"; printf '{}\n' >"$h/.claude/settings.json"
  for n in mcp-start.sh mcp-start-chrome.sh reap-profiles.sh; do ln -s "/elsewhere/$n" "$h/.local/mcp-bot/$n"; done
  ln -s "$h/$TL" "$h/.local/bin/spool"
done
mk_bin "$H1/$TL" 0000000000000000000000000000000000000001
mk_bin "$H2/$TL" 0000000000000000000000000000000000000002
cp "$H1/$TL" "$T/old1"; cp "$H2/$TL" "$T/old2"
# tree <dir...>: every path with its type, link target, sha and mtime
tree() { find "$@" -printf '%p %y %l %T@\n' | sort; find "$@" -type f -exec sha256sum {} + | sort; }
cfg() { for h in "$H1" "$H2"; do sha256sum "$h/.config/spool-agent/env" "$h/.bashrc" "$h/.claude/CLAUDE.md" "$h/.claude/settings.json"; ls -l "$h/.local/mcp-bot" | awk 'NR>1{print $9,$10,$11}'; done; }
# refresh [VAR=value]...: NO_SB=1 leaves SPOOL_SHARED_BIN unset (as the cron)
refresh() {
  local -a sb=(SPOOL_SHARED_BIN="$SHARED")
  [ "${NO_SB:-0}" = 1 ] && sb=()
  SNIPPET='do_spl_spool_refresh' in_orc HOME="$H1" XDG_CONFIG_HOME= MCP_BOT_HOME= SPOOL_INSTALL_PREFIX="$H1/.local" \
    "${sb[@]}" SPOOL_REFRESH_USERS="tester other" SPOOL_REFRESH_HOMES="other=$H2" \
    SPOOL_REFRESH_AS="$T/as" SPOOL_ROOT="$T/no-root" SPOOL_REFRESH_TRUNK=HEAD \
    SPOOL_INSTALL_BUILD="$T/build.sh" SPOOL_INSTALL_BINREV="$T/binrev" SPOOL_INSTALL_GO_ROOTS="$T/go" \
    PATH="$T/go/bin:$PATH" USER=tester "$@" 2>&1
}
cfg0="$(cfg)"

# 0. never adopted implicitly
t0="$(tree "$H1/.local" "$H2/.local")"
out="$(NO_SB=1 refresh)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'NOTE per-user copy: adopt the one installed copy with SPOOL_SHARED_BIN=/var/' <<<"$out" \
  && ! grep -q 'LINK other' <<<"$out" && [ ! -e "$T/shared" ] && [ "$(tree "$H1/.local" "$H2/.local")" = "$t0" ] \
  && pass "0. without SPOOL_SHARED_BIN and no link: per-user mode, the adopt line, the other user untouched" || fail "0. implicit (rc $rc: $out)"

# 1. dry run
out="$(refresh)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tree "$H1/.local" "$H2/.local")" = "$t0" ] && [ ! -e "$T/shared" ] && [ ! -e "$T/builds" ] \
  && grep -q 'OK DRY_RUN nothing was touched' <<<"$out" && grep -q "would: link $H2/$TL -> $SHARED" <<<"$out" \
  && pass "1. the dry run touches neither home, builds nothing, plans both links" || fail "1. dry run (rc $rc: $out)"

# 2. one live run
out="$(refresh DRY_RUN=0)"; rc=$?
r1="$(readlink -f "$H1/.local/bin/spool")"; r2="$(readlink -f "$H2/.local/bin/spool")"
[ "$rc" -eq 0 ] && [ "$r1" = "$(readlink -f "$SHARED")" ] && [ "$r2" = "$r1" ] && [ "$("$T/binrev" "$r1")" = "$HEAD_SHA" ] \
  && [ "$(wc -l <"$T/builds")" -eq 1 ] && grep -q "OK one installed copy: $SHARED at $HEAD_SHA, run by tester other" <<<"$out" \
  && pass "2. one run: both users' spool resolve to the same shared file at trunk (one build)" || fail "2. live (rc $rc: $out)"
cmp -s "$H1/$TL.bak" "$T/old1" && cmp -s "$H2/$TL.bak" "$T/old2" && [ -L "$H1/$TL" ] && [ -L "$H2/$TL" ] \
  && pass "2. ...each old real copy is kept as spool.bak, the tools paths are links" || fail "2. backups ($(ls -l "${H1}/${TL%/*}" "${H2}/${TL%/*}"))"
[ "$(cfg)" = "$cfg0" ] && grep -q 'OK config: the five config paths are byte-identical' <<<"$out" && grep -q "BEFORE config: $H2/.bashrc" <<<"$out" \
  && pass "2. ...both users' five config paths are byte-identical (and both were checked)" || fail "2. config ($out)"

# 3. a second run changes nothing
t1="$(tree "$H1/.local" "$H2/.local" "$T/shared")"
out="$(NO_SB=1 refresh DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tree "$H1/.local" "$H2/.local" "$T/shared")" = "$t1" ] && [ "$(wc -l <"$T/builds")" -eq 1 ] \
  && grep -q 'already at' <<<"$out" && grep -q 'LINK other' <<<"$out" \
  && pass "3. a second run without SPOOL_SHARED_BIN follows the link and changes nothing (no build, same tree)" || fail "3. second run (rc $rc: $out)"
# control of 3: the tree comparison sees a relink
ln -sfn "$T/elsewhere" "$H2/$TL"
[ "$(tree "$H1/.local" "$H2/.local" "$T/shared")" != "$t1" ] && pass "3. control: a changed link is seen by the tree check" || fail "3. control"

# 4. control: a hop that fails
mk_bin "$H2/$TL.real" 0000000000000000000000000000000000000002; mv -f "$H2/$TL.real" "$H2/$TL"; t2="$(tree "$H2/.local")"
out="$(refresh DRY_RUN=0 SPOOL_REFRESH_AS="$T/as-fail")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'FAIL link other' <<<"$out" && [ "$(tree "$H2/.local")" = "$t2" ] \
  && pass "4. control: a failing user hop fails the run, is named, and leaves that user's copy" || fail "4. hop fail (rc $rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
