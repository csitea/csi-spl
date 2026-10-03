#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_ysg_box_deps (specs/069 Y9) is a read-only gate. A control
#          both ways: a clean sandbox HOME + crontab FILE passes (exit 0, no
#          row); plant one link into the engine and one cron line calling it
#          and the check fails (exit 1) naming both; an unreadable crontab is
#          exit 2, never a pass. crontab, ps and tmux are stubbed; the system
#          paths are a sandbox dir; root's crontab is not read (a CI runner
#          has no sudo to it).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

ENGINE="$T/opt/engine/ysg-box"
mkdir -p "$T/home/.local/bin" "$T/home/.claude/skills" "$T/stub" "$T/sys/cron.d" "$ENGINE/ysg-box-orc"
: >"$T/crontab"
echo '# the box restore was here: ysg-box' >>"$T/crontab"
echo '*/5 * * * * /usr/bin/true' >>"$T/crontab"
echo 'set -g status on' >"$T/home/.tmux.conf"
echo 'echo hi' >"$T/sys/cron.d/other"

cat >"$T/stub/crontab" <<'S'
#!/usr/bin/env bash
[[ "${STUB_CRON_RC:-0}" == 0 ]] || { echo "crontab: permission denied" >&2; exit 1; }
cat "$STUB_CRONTAB"
S
cat >"$T/stub/ps" <<'S'
#!/usr/bin/env bash
echo "$(id -un) 1 /bin/sleep 9"
S
chmod +x "$T/stub/"*

run_check() {
  env -u SPOOL_BOX_USER -u SPOOL_AGENT_USER -u YSG_BOX_DEPS_PATTERN \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_CRONTAB="$T/crontab" PROJ_PATH="$PROJ_ROOT" \
    YSG_BOX_DEPS_USERS="$(id -un)" YSG_BOX_DEPS_CRON_USERS="$(id -un)" YSG_BOX_DEPS_SYS_PATHS="$T/sys" \
    YSG_BOX_DEPS_TMUX_SOCKET="$T/no-socket" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/check-ysg-box-deps.func.sh"
    do_check_ysg_box_deps' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/check-ysg-box-deps.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
grep -qE 'crontab -[re]|\brm -rf|\bln -s|\bunlink\b|tmux .*(set-|kill-|-g [a-z-]+ )' "$FUNC" \
  && fail "0. the action carries a write" || pass "0. no crontab install, link, rm or tmux set in the action"

# --- 1. clean sandbox passes ---------------------------------------------------
run_check; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK no dependency' "$T/out" && ! grep -qP '^(cron|link|home|tmux|systemd|proc)\t' "$T/out" \
  && pass "1. clean sandbox: exit 0, no row" || fail "1. clean: rc=$rc $(cat "$T/out")"

# --- 2. planted link + cron line fail, named --------------------------------
ln -s "$ENGINE/ysg-box-orc/mcp-start.sh" "$T/home/.local/bin/mcp-start.sh"
echo "@reboot $ENGINE/ysg-box-orc/boot.sh" >>"$T/crontab"
run_check; rc=$?
rows=$(grep -cP '^(cron|link|home|tmux|systemd|proc)\t' "$T/out")
[[ $rc -eq 1 ]] && pass "2. planted: exit 1" || fail "2. planted: rc=$rc $(cat "$T/out")"
grep -qP "^cron\t$(id -un)\tcrontab:3\t@reboot .*/ysg-box/ysg-box-orc/boot.sh" "$T/out" \
  && pass "2. the cron line is named (line 3; the comment line is not a row)" || fail "2. no cron row: $(cat "$T/out")"
grep -qP "^link\t$(id -un)\t$T/home/.local/bin/mcp-start.sh\t-> .*ysg-box-orc/mcp-start.sh \(BROKEN\)" "$T/out" \
  && pass "2. the link is named, BROKEN (its target does not exist)" || fail "2. no link row: $(cat "$T/out")"
[[ $rows -eq 2 ]] && grep -q 'FAIL 2 dependency row' "$T/out" && pass "2. exactly the 2 planted rows" || fail "2. rows=$rows: $(cat "$T/out")"

# --- 3. a live link, a home file, a system file --------------------------------
touch "$ENGINE/ysg-box-orc/mcp-start.sh"
echo "source $ENGINE/run.completion.bash" >>"$T/home/.bashrc"
echo "ExecStart=$ENGINE/x.sh" >"$T/sys/x.service"
run_check; rc=$?
grep -qP "^link\t.*mcp-start.sh\t.*\(live\)" "$T/out" && pass "3. a resolving link reads live" || fail "3. live: $(cat "$T/out")"
grep -qP "^home\t$(id -un)\t$T/home/.bashrc:1\tsource " "$T/out" && pass "3. the .bashrc line is a home row" || fail "3. bashrc: $(cat "$T/out")"
grep -qP "^systemd\t$(id -un)\t$T/sys/x.service:1\t" "$T/out" && pass "3. the unit file is a systemd row" || fail "3. unit: $(cat "$T/out")"
[[ $rc -eq 1 ]] && grep -q 'FAIL 4 dependency row' "$T/out" && pass "3. exit 1, 4 rows" || fail "3. rc=$rc $(cat "$T/out")"

# --- 4. an unreadable crontab is exit 2, never a pass -------------------------
rm -f "$T/home/.local/bin/mcp-start.sh" "$T/home/.bashrc" "$T/sys/x.service"
sed -i '$d' "$T/crontab"
run_check STUB_CRON_RC=1; rc=$?
[[ $rc -eq 2 ]] && grep -q 'cannot read the crontab' "$T/out" && pass "4. unreadable crontab: exit 2" || fail "4. rc=$rc $(cat "$T/out")"
run_check; rc=$?
[[ $rc -eq 0 ]] && pass "4. back to clean: exit 0" || fail "4. clean again: rc=$rc $(cat "$T/out")"

# --- 5. the rc-files and the .local/bin files are all scanned -----------------
echo "source $ENGINE/run.completion.bash" >"$T/home/.bashrc"
echo "exec $ENGINE/a.sh" >"$T/home/.local/bin/a.sh"
echo "exec $ENGINE/b.sh" >"$T/home/.local/bin/b.sh"
run_check; rc=$?
grep -qP "^home\t$(id -un)\t$T/home/.bashrc:1\t" "$T/out" \
  && grep -qP "^home\t$(id -un)\t$T/home/.local/bin/a.sh:1\t" "$T/out" \
  && grep -qP "^home\t$(id -un)\t$T/home/.local/bin/b.sh:1\t" "$T/out" \
  && [[ $rc -eq 1 ]] && grep -q 'FAIL 3 dependency row' "$T/out" \
  && pass "5. one rc-file + two .local/bin files: all 3 scanned" || fail "5. rc=$rc $(cat "$T/out")"
rm -f "$T/home/.bashrc" "$T/home/.local/bin/a.sh" "$T/home/.local/bin/b.sh"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
