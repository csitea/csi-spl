#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push part wui-e2e never leaves csi-spl-wui/.output.ppe-keep
#          behind for the next run (SPL-3090). The part moves .output aside
#          and puts it back only in its inner shell's EXIT trap; a SIGKILL
#          (timeout -k 10, do_stop_pre_push's KILL step) skips that trap.
#   1. a run KILLed mid-build leaves .output.ppe-keep and no .output; the
#      next run puts the keep back: .output (with its file) is there after
#      it, no .output.ppe-keep, and it says so in one line
#   2. a stale keep next to a real .output: the keep is removed, the
#      .output stays
#   3. a run KILLed in the browser leg (.output = the bundle symlink only):
#      the next run restores the keep, not the symlink
#   4. the gate's plan (_ppe_parts) heals the tree before any part runs, a
#      change with no WUI path too: the parts before wui-e2e never see a keep
#   CONTROL: on a copy of the part with both _ppe_keep_heal calls removed,
#            checks 1 and 4 fail (the keep is still there)
#   Hermetic: a throwaway git tree; the build is a stub that records its
#   parent (the part's inner shell) and sleeps, or writes a bundle; the
#   runner is `true`.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
for v in $(compgen -e); do [[ "$v" == PRE_PUSH_* ]] && unset "$v"; done
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fail() { echo "FAIL: $1${2:+ -- $2}"; fails=$((fails + 1)); }
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
# The part puts $HOME/.local/bin first on PATH: an empty HOME keeps a real pnpm out.
export HOME="$T/home"; mkdir -p "$HOME"

mkdir -p "$T/bin"
# slow-build: the part's inner shell is its parent; record both pids, then hang
cat >"$T/bin/slow-build" <<'STUB'
#!/usr/bin/env bash
echo "$PPID $$" >"$PIDS"
exec sleep 60
STUB
# fast-build: the bundle, as nuxt generate leaves it
cat >"$T/bin/fast-build" <<'STUB'
#!/usr/bin/env bash
mkdir -p .output/public && echo built >.output/public/index.html
STUB
chmod +x "$T/bin/slow-build" "$T/bin/fast-build"

# new_tree <dir>: a committed WUI with installed modules and a user .output
new_tree() {
  local r="$1" w="$1/csi-spl-wui"; rm -rf "$r"; mkdir -p "$w/node_modules/.pnpm" "$w/.output"
  echo lock >"$w/pnpm-lock.yaml"; cp "$w/pnpm-lock.yaml" "$w/node_modules/.pnpm/lock.yaml"
  printf 'node_modules/\n.output/\n.output.ppe-keep/\n' >"$w/.gitignore"
  git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  echo mine >"$w/.output/marker"
}

# part <run dir> <tree> <build> [timeout]: one run of the part, in a fresh bash
part() {
  bash -c '
    do_log() { echo "$*"; }
    . "$1/check-pre-push.func.sh"
    _PPE_FILES="tests/e2e/x.test.mjs" PRE_PUSH_E2E_GENERATE="$3" PRE_PUSH_E2E_RUNNER=true \
      PRE_PUSH_E2E_BUNDLES="$2/.bundles" PRE_PUSH_E2E_TIMEOUT="$4" _pp_part_wui_e2e "$2"' _ "$1" "$2" "$3" "${4:-60}"
}

# killed_run <run dir> <tree>: a run KILLed mid-build, as timeout -k does it
killed_run() {
  export PIDS="$T/pids"; rm -f "$PIDS"
  part "$1" "$2" "$T/bin/slow-build" >"$T/out.killed" 2>&1 &
  local bg=$!
  for _ in $(seq 1 100); do [[ -s "$PIDS" ]] && break; sleep 0.1; done
  local inner stub; read -r inner stub <"$PIDS"
  kill -KILL "$inner" "$stub" 2>/dev/null
  wait "$bg" 2>/dev/null
}

# check1 <run dir>: 0 when the run after a KILLed one leaves the tree clean
check1() {
  local r="$T/tree1" w="$T/tree1/csi-spl-wui"; new_tree "$r"
  killed_run "$1" "$r"
  if [[ -d "$w/.output.ppe-keep" && ! -e "$w/.output" ]]; then
    pass "1. a KILLed run leaves .output.ppe-keep and no .output (the state the fix must clear)"
  else fail "1. the KILLed run leaves the keep" "$(ls -A "$w" | paste -sd' ')"; return 1; fi
  part "$1" "$r" "$T/bin/fast-build" >"$T/out.1" 2>&1
  [[ -f "$w/.output/marker" && ! -e "$w/.output.ppe-keep" ]] && grep -q 'restored .output from a stale .output.ppe-keep' "$T/out.1"
}

if check1 "$RUN"; then pass "1. the next run restores .output (its file kept), no .output.ppe-keep, one log line"
else fail "1. the next run clears the stale keep" "$(ls -A "$T/tree1/csi-spl-wui" | paste -sd' ') / $(tail -3 "$T/out.1" | paste -sd' ')"; fi

# 2. a stale keep next to a real .output
r="$T/tree2" w="$T/tree2/csi-spl-wui"; new_tree "$r"
mkdir -p "$w/.output.ppe-keep"; echo stale >"$w/.output.ppe-keep/old"
part "$RUN" "$r" "$T/bin/fast-build" >"$T/out.2" 2>&1
if [[ -f "$w/.output/marker" && ! -e "$w/.output/old" && ! -e "$w/.output.ppe-keep" ]] && grep -q 'removed a stale .output.ppe-keep' "$T/out.2"; then
  pass "2. a stale keep next to a .output is removed, the .output stays"
else fail "2. stale keep + .output" "$(ls -A "$w" "$w/.output" | paste -sd' ') / $(tail -3 "$T/out.2" | paste -sd' ')"; fi

# 3. KILLed in the browser leg: .output holds only the bundle symlink
r="$T/tree3" w="$T/tree3/csi-spl-wui"; new_tree "$r"
mv "$w/.output" "$w/.output.ppe-keep"; mkdir -p "$w/.output" "$T/bundle"; ln -s "$T/bundle" "$w/.output/public"
part "$RUN" "$r" "$T/bin/fast-build" >"$T/out.3" 2>&1
if [[ -f "$w/.output/marker" && ! -L "$w/.output/public" && ! -e "$w/.output.ppe-keep" ]]; then
  pass "3. a keep next to the bundle symlink only is restored, the symlink is gone"
else fail "3. keep + bundle symlink" "$(ls -A "$w" "$w/.output" 2>&1 | paste -sd' ') / $(tail -3 "$T/out.3" | paste -sd' ')"; fi

# check4 <run dir>: 0 when the plan alone puts a stale keep back
check4() {
  local r="$T/tree4" w="$T/tree4/csi-spl-wui"; new_tree "$r"
  mv "$w/.output" "$w/.output.ppe-keep"
  bash -c 'do_log() { echo "$*"; }; . "$1/check-pre-push.func.sh"; parts="hygiene"; _ppe_parts "csi-spl-iac/x.sh" "$2"' _ "$1" "$r" >"$T/out.4" 2>&1
  [[ -f "$w/.output/marker" && ! -e "$w/.output.ppe-keep" ]]
}
if check4 "$RUN"; then pass "4. the plan (_ppe_parts) restores a stale keep, before any part, with no WUI change"
else fail "4. plan-time heal" "$(ls -A "$T/tree4/csi-spl-wui" | paste -sd' ') / $(tail -3 "$T/out.4" | paste -sd' ')"; fi

# CONTROL: the part without its two _ppe_keep_heal calls
c="$T/ctl"; mkdir -p "$c"; cp "$RUN"/check-pre-push*.func.sh "$c/"
perl -i -ne 'print unless /^\s+_ppe_keep_heal (\.|"\$2\/csi-spl-wui")$/' "$c/check-pre-push-e2e.func.sh"
n="$(diff "$c/check-pre-push-e2e.func.sh" "$RUN/check-pre-push-e2e.func.sh" | grep -c '^>')"
if [[ "$n" != 2 ]]; then fail "CONTROL: both _ppe_keep_heal calls are removed from the copy" "removed $n line(s)"
else
  if check1 "$c" >/dev/null; then fail "CONTROL: without the calls, check 1 must fail" "it passed"
  else pass "CONTROL: without the calls the keep survives the next run (check 1 fails)"; fi
  if check4 "$c"; then fail "CONTROL: without the calls, check 4 must fail" "it passed"
  else pass "CONTROL: without the calls the plan leaves the keep (check 4 fails)"; fi
fi

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
