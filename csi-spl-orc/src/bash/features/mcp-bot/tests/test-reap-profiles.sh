#!/usr/bin/env bash
# test-reap-profiles.sh — regression tests for the mcp-bot profile reaper.
#
# Every case runs against a PRIVATE fixture MCP_BOT_HOME under a scratch dir.
# The real ~/.local/mcp-bot is never passed to the script by this suite.
#
# The defects pinned here are the ones that cost real data if they regress:
#
#   1. THE MASTER. `rm -rf ff-profile*` matches $MCP_BOT_HOME/ff-profile, the
#      471M base profile every clone is made from and the only copy of the
#      browser logins. Cases 1-3 assert it is never listed, never removed, and
#      not reachable through a symlink named like a clone.
#   2. LIVENESS. A clone a live browser holds must never be removed. Both
#      signals get their own control: a real live process whose argv names the
#      clone (case 6) and a `lock` symlink pointing at a live pid (case 7).
#      A green run with nothing live present proves nothing, which is why these
#      cases start a real process rather than asserting on an empty skip list.
#   3. AGE FROM THE WRONG CLOCK. `rsync -a` copies the master's mtimes into
#      every clone, so the newest mtime in a clone's tree is the master's
#      provisioning date and is identical across all of them. Case 10 gives a
#      clone an ancient tree and asserts it is still KEPT, because the signals
#      that move with use are birth time, the clone dir's own mtime, its direct
#      children, and run/<ID>.* — not the tree.
#
# Usage:  bash test-reap-profiles.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${HERE}/../scripts/reap-profiles.sh"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1
[[ -f "$SUT" ]] || { echo "FATAL: not found: $SUT" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
nok() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-reap-profiles-XXXXXX")"
HOLDERS=()
cleanup() {
  local p
  for p in ${HOLDERS+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ── fixture helpers ────────────────────────────────────────────────────────
H=""                      # current fixture MCP_BOT_HOME
new_home() {              # a fresh fixture home with a master profile in it
  H="$ROOT/home-$1"; rm -rf "$H"; mkdir -p "$H/run"
  mkdir -p "$H/ff-profile/extensions"
  printf 'pretend prefs\n' > "$H/ff-profile/prefs.js"
  head -c 4096 /dev/zero  > "$H/ff-profile/places.sqlite"
}
clone() {                 # clone <ID> — a plausible per-agent clone
  local d="$H/ff-profile-$1"
  mkdir -p "$d/extensions"
  printf 'pretend prefs\n' > "$d/prefs.js"
  head -c 4096 /dev/zero  > "$d/places.sqlite"
  printf '%s\n' "$d"
}
run_file() {              # run_file <ID> — what mcp-start.sh writes per launch
  printf '30123\n' > "$H/run/$1.marionette-port"
  printf '{}\n'    > "$H/run/mcp-config-$1.json"
}
# a live process whose argv names a dir, the way a browser's does
hold_argv() {             # hold_argv <dir> -> pid
  python3 -c 'import time; time.sleep(300)' --user-data-dir="$1" >/dev/null 2>&1 &
  local p=$!; HOLDERS+=("$p"); printf '%s\n' "$p"
}
dead_pid() {              # a pid that is certainly gone
  sh -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null; printf '%s\n' "$p"
}
lock_at() {               # lock_at <clone-dir> <pid> — Firefox's own lock shape
  ln -sfn "10.250.74.2:+$2" "$1/lock"; : > "$1/.parentlock"
}
# `touch -t` parses its stamp as LOCAL time, so a UTC-formatted one lands hours
# in the PAST on a +0300 box and silently makes a "fresh" fixture stale. -d with
# a relative string has no timezone to get wrong.
ahead() { touch -d '+1 hour' "$@"; }

reap() { MCP_BOT_HOME="$H" bash "$SUT" "$@" 2>&1; }
listed()   { printf '%s' "$1" | grep -x -- "$2" >/dev/null; }      # a bare removal line
skipped()  { printf '%s' "$1" | grep -E "^  SKIP  +$2 +$3( |$)" >/dev/null; }

echo "== reap-profiles.sh regression tests =="
echo "   fixtures under $ROOT"
echo

# ── 1. the master is never listed, and --dry-run is the DEFAULT ────────────
new_home master
clone CLE-old >/dev/null
out="$(reap --all-ages)"; rc=$?   # --all-ages is not a MODE flag: mode must still default
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if listed "$out" "$H/ff-profile"; then
  nok "the MASTER appears as a removal line — the one unrecoverable defect" "$out"
else
  ok "the master is never listed for removal"
fi
if [[ $rc -eq 1 ]]; then ok "no mode flag => dry run, exit 1 with candidates found"
else nok "default mode must be dry-run with exit 1" "rc=$rc"; fi
if [[ -d "$H/ff-profile-CLE-old" ]]; then ok "dry run removed nothing"
else nok "dry run DELETED a clone"; fi

# ── 2. --delete --all-ages leaves the master byte-intact ───────────────────
sum_before="$(cat "$H/ff-profile/prefs.js")"
out="$(reap --delete --all-ages)"; rc=$?
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$H/ff-profile" && -f "$H/ff-profile/prefs.js" && "$(cat "$H/ff-profile/prefs.js")" == "$sum_before" ]]; then
  ok "--delete --all-ages left the master intact"
else
  nok "--delete removed or damaged the MASTER profile" "$out"
fi
if [[ ! -d "$H/ff-profile-CLE-old" ]]; then ok "--delete removed the retired clone"
else nok "--delete did not remove the clone it listed" "$out"; fi
if [[ $rc -eq 0 ]]; then ok "a converged --delete exits 0"; else nok "--delete should exit 0" "rc=$rc"; fi

# ── 3. a SYMLINK named like a clone is not followed into the master ────────
new_home symlink
ln -sfn "$H/ff-profile" "$H/ff-profile-alias"
out="$(reap --delete --all-ages)"; rc=$?
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$H/ff-profile" && -f "$H/ff-profile/prefs.js" ]]; then
  ok "a clone-shaped symlink to the master did not get the master deleted"
else
  nok "the master was destroyed through ff-profile-alias -> ff-profile" "$out"
fi
if skipped "$out" symlink ff-profile-alias; then ok "the symlink is reported as skipped, with its target"
else nok "the symlink should be reported as a skip" "$out"; fi
if [[ -L "$H/ff-profile-alias" ]]; then ok "the symlink itself was left alone"
else nok "the symlink was removed" "$out"; fi

# ── 4. idempotence: a second --delete removes nothing and exits 0 ──────────
new_home idem
clone CLE-a >/dev/null; clone CLE-b >/dev/null
reap --delete --all-ages >/dev/null 2>&1
out="$(reap --delete --all-ages)"; rc=$?
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep 'nothing to reap' >/dev/null; then
  ok "a second --delete is a no-op: 'nothing to reap', exit 0"
else
  nok "the reaper is not idempotent" "rc=$rc / $out"
fi

# ── 5. --keep <ID> is honoured, in all three spellings ────────────────────
new_home keep
clone CLE-k1 >/dev/null; clone CLE-k2 >/dev/null; clone CLE-k3 >/dev/null; clone CLE-k4 >/dev/null
out="$(reap --delete --all-ages --keep CLE-k1 --keep ff-profile-CLE-k2 --keep "$H/ff-profile-CLE-k3")"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
for c in CLE-k1 CLE-k2 CLE-k3; do
  if [[ -d "$H/ff-profile-$c" ]]; then ok "--keep kept $c"
  else nok "--keep did NOT protect $c" "$out"; fi
done
if [[ ! -d "$H/ff-profile-CLE-k4" ]]; then ok "a clone not in --keep was still removed"
else nok "--keep leaked onto an unnamed clone" "$out"; fi

# ── 6. CONTROL: a clone named in a LIVE process's argv is skipped ──────────
# This is the process-table signal, exercised against a real running process.
new_home live-argv
d_live="$(clone CLE-live)"; d_dead="$(clone CLE-dead)"
pid="$(hold_argv "$d_live")"
sleep 0.3
out="$(reap --delete --all-ages)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$d_live" ]] && skipped "$out" live ff-profile-CLE-live; then
  ok "a clone held by live pid $pid was SKIPPED and survived (process-table signal)"
else
  nok "a LIVE profile was reaped — the data-loss defect" "$out"
fi
if printf '%s' "$out" | grep "live pid $pid names it as an argv path (argv-path)" >/dev/null; then
  ok "the report names the holding pid and calls the hold browser-shaped (argv-path)"
else nok "the skip line should name the pid and the shape of the hold" "$out"; fi

# the other shape: a process that merely MENTIONS the path inside a larger token
# (a shell -c body, a grep pattern). Still kept — the safe direction — but the
# report must not pass it off as a browser holding the profile.
d_ment="$(clone CLE-ment)"
python3 -c 'import time; time.sleep(300)' "pretend script text touching $d_ment here" >/dev/null 2>&1 &
pid2=$!; HOLDERS+=("$pid2"); sleep 0.3
out="$(reap --dry-run --all-ages)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if printf '%s' "$out" | grep "live pid $pid2 mentions it inside a larger argv token (argv-text)" >/dev/null; then
  ok "an incidental mention keeps the clone, reported as argv-text not as a browser"
else
  nok "the two shapes of argv hold are not distinguished" "$out"
fi
kill "$pid2" 2>/dev/null
if [[ ! -d "$d_dead" ]]; then ok "the unheld clone alongside it was still removed"
else nok "nothing was reaped at all — the control proves nothing" "$out"; fi
kill "$pid" 2>/dev/null

# ── 7. CONTROL: lock symlink pointing at a LIVE pid is skipped ────────────
# The lock owner's argv does NOT name the clone here, so this exercises the
# lock signal alone — and pins the deliberate divergence from mcp-start.sh,
# which would call this lock stale.
new_home live-lock
d_held="$(clone CLE-held)"; d_stale="$(clone CLE-stale)"
pid="$(hold_argv "$ROOT/unrelated")"
lock_at "$d_held" "$pid"
lock_at "$d_stale" "$(dead_pid)"
sleep 0.3
out="$(reap --delete --all-ages)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$d_held" ]] && skipped "$out" held ff-profile-CLE-held; then
  ok "a lock held by live pid $pid was SKIPPED (lock signal, argv silent)"
else
  nok "a profile whose lock pid is ALIVE was reaped" "$out"
fi
if [[ ! -d "$d_stale" ]]; then ok "a lock left by a DEAD pid is stale and reapable"
else nok "a stale lock blocked the reap" "$out"; fi
kill "$pid" 2>/dev/null

# ── 8. the age cutoff, and which signal decides it ────────────────────────
# --days 0 puts the cutoff at NOW, so a clone created a moment ago is past it
# unless something dates it into the future. Three clones, three outcomes.
new_home age
d_old="$(clone CLE-o)"; d_touch="$(clone CLE-t)"; d_run="$(clone CLE-r)"
ahead "$d_touch/prefs.js"                         # a direct child, freshly written
run_file CLE-r; ahead "$H/run/CLE-r.marionette-port"
# --days 0 puts the cutoff at NOW, and `stat %W` has one-second resolution: a
# clone born in the same second as the run compares EQUAL to the cutoff and
# reads fresh. Step past that second so the comparison is actually exercised.
sleep 1.5
out="$(reap --delete --days 0)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ ! -d "$d_old" ]]; then ok "--days 0: a clone with no recent activity is reaped"
else nok "the age cutoff did not fire" "$out"; fi
if [[ -d "$d_touch" ]] && skipped "$out" fresh ff-profile-CLE-t; then
  ok "a freshly written DIRECT CHILD keeps the clone"
else nok "top-level child mtime was not taken as activity" "$out"; fi
if [[ -d "$d_run" ]] && printf '%s' "$out" | grep 'run/CLE-r.marionette-port' >/dev/null; then
  ok "run/<ID>.marionette-port keeps the clone, and is named as the reason"
else nok "the run-dir signal was not consulted" "$out"; fi

# ── 9. --limit bounds a real run, oldest activity first ──────────────────
new_home limit
for i in 1 2 3 4 5; do clone "CLE-l$i" >/dev/null; done
out="$(reap --delete --all-ages --limit 2)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
left=$(find "$H" -maxdepth 1 -name 'ff-profile-CLE-l*' | wc -l)
if [[ $left -eq 3 ]]; then ok "--limit 2 removed exactly 2 of 5 clones"
else nok "--limit did not bound the run" "3 expected to remain, $left did / $out"; fi

# ── 10. TRAP 2: an ANCIENT tree does not make a clone reapable ───────────
# This is the rsync -a defect in isolation: every file in the clone carries the
# master's old mtime, so a tree-mtime reaper deletes clones made minutes ago.
new_home rsync-mtime
d_anc="$(clone CLE-anc)"
find "$d_anc" -exec touch -t 202001010000 {} +   # the whole tree, contents and dir
out="$(reap --delete --days 14)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$d_anc" ]] && skipped "$out" fresh ff-profile-CLE-anc; then
  ok "a clone whose whole tree reads 2020 is still KEPT (birth time decides)"
else
  nok "age was taken from the tree mtime — reaps clones made minutes ago" "$out"
fi

# ── 10b. NO BIRTH TIME (WSL1 lxfs/drvfs read %W as 0): ctime decides ─────
# Case 10 passes on ext4 only because %W is real there. On osp (WSL1) `stat %W`
# printed 0, BIRTH fell back to nothing, the 2020 tree mtimes decided, and a
# clone made minutes earlier was REMOVED. A stat shim that rewrites %W to a
# literal 0 reproduces that filesystem on ext4, so CI covers it.
#   shim_stat <dir> <field>... — a `stat` on PATH that reads each field as 0
shim_stat() {
  local dir="$1" real f sub=""; shift
  real="$(command -v stat)"
  for f in "$@"; do sub+='a="${a//"%'"$f"'"/0}"; '; done
  mkdir -p "$dir"
  cat > "$dir/stat" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do ${sub}args+=("\$a"); done
exec "$real" "\${args[@]}"
EOF
  chmod +x "$dir/stat"
}
shim_stat "$ROOT/shim-noW" W
shim_stat "$ROOT/shim-noWZ" W Z
if [[ "$(PATH="$ROOT/shim-noW:$PATH" stat -c '%W' "$ROOT")" == 0 ]]; then
  ok "control: the shim makes stat %W read 0, as on WSL1"
else nok "the %W shim does not work — case 10b would prove nothing"; fi

new_home no-birth
d_nb="$(clone CLE-anc)"
find "$d_nb" -exec touch -t 202001010000 {} +
out="$(PATH="$ROOT/shim-noW:$PATH" reap --delete --days 14)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$d_nb" ]] && skipped "$out" fresh ff-profile-CLE-anc; then
  ok "with %W=0 a clone whose whole tree reads 2020 is still KEPT"
else
  nok "with no birth time the tree mtime decided — the osp data loss" "$out"
fi
if printf '%s' "$out" | grep -E 'ff-profile-CLE-anc .*clone ctime \(%Z, no birth time\)' >/dev/null; then
  ok "the skip line names ctime as the age source"
else nok "the age source used with no birth time is not logged" "$out"; fi

# ── 10c. neither birth time nor ctime: SKIP no-birth-time, never "old" ───
new_home no-clock
d_nc="$(clone CLE-anc)"
find "$d_nc" -exec touch -t 202001010000 {} +
out="$(PATH="$ROOT/shim-noWZ:$PATH" reap --delete --days 14)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$d_nc" ]] && skipped "$out" no-birth-time ff-profile-CLE-anc; then
  ok "with %W and %Z both 0 the clone is SKIPPED as no-birth-time"
else
  nok "an unknown clone age was treated as old" "$out"
fi

# ── 11. partial dirs: .tmp-<dead> reaped, .tmp-<live> left alone ─────────
new_home partial
pid="$(hold_argv "$ROOT/unrelated2")"
mkdir -p "$H/ff-profile-CLE-p.tmp-$pid/extensions"
mkdir -p "$H/ff-profile-CLE-q.tmp-$(dead_pid)/extensions"
sleep 0.3
out="$(reap --delete --days 14)"       # note: a real age threshold, not --all-ages
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$H/ff-profile-CLE-p.tmp-$pid" ]] && skipped "$out" inflight "ff-profile-CLE-p.tmp-$pid"; then
  ok "an in-flight clone (.tmp-<live pid>) is skipped"
else nok "a clone in progress was deleted under the process making it" "$out"; fi
if [[ -z "$(find "$H" -maxdepth 1 -name 'ff-profile-CLE-q.tmp-*')" ]]; then
  ok "an abandoned .tmp-<dead pid> is reaped regardless of age"
else nok "an abandoned partial clone was kept" "$out"; fi
kill "$pid" 2>/dev/null

# ── 11b. an in-flight EPHEMERAL clone survives even --all-ages ──────────
# ff-profile-pid<N> is owned by mcp-start pid <N>. Its playwright-mcp process
# names only run/mcp-config-pid<N>.json in its argv, and until a client asks for
# a page there is no browser and no lock — so BOTH other liveness signals are
# silent and only the name saves it. Under the --days default birth time hides
# the gap; --all-ages is where it bit.
new_home ephemeral
python3 -c 'import time; time.sleep(300)' >/dev/null 2>&1 &
srv=$!; HOLDERS+=("$srv")
mkdir -p "$H/ff-profile-pid$srv/extensions"; printf 'x\n' > "$H/ff-profile-pid$srv/prefs.js"
printf '30123\n' > "$H/run/pid$srv.marionette-port"      # what mcp-start writes at launch
mkdir -p "$H/ff-profile-pid$(dead_pid)/extensions"
sleep 0.3
out="$(reap --dry-run --all-ages)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if skipped "$out" inflight "ff-profile-pid$srv"; then
  ok "--all-ages keeps an ephemeral clone whose mcp-start server is alive"
else
  nok "an in-flight ephemeral profile was listed for removal" "$out"
fi
if printf '%s' "$out" | grep -E '^  SKIP  +inflight +ff-profile-pid[0-9]+ +ephemeral clone of live mcp-start server pid' >/dev/null; then
  ok "the skip line says it is an ephemeral clone and names the server pid"
else nok "the inflight reason should name the owning mcp-start server" "$out"; fi
# and the dead one is still governed by the age threshold, not reaped on sight
out="$(reap --dry-run --days 14)"
if printf '%s' "$out" | grep 'nothing to reap' >/dev/null; then
  ok "an ephemeral clone with a DEAD pid is left to the age threshold, not reaped on sight"
else nok "closing the protection gap must not widen what gets deleted" "$out"; fi
kill "$srv" 2>/dev/null

# ── 12. cr-profile-* (the chrome MCP) is never touched ──────────────────
new_home chrome
mkdir -p "$H/cr-profile-CLE-01/Default" "$H/cr-profile-CLE-02/Default"
clone CLE-ff >/dev/null
out="$(reap --delete --all-ages)"
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$H/cr-profile-CLE-01" && -d "$H/cr-profile-CLE-02" ]]; then
  ok "cr-profile-* dirs survive (out of scope by design)"
else nok "the reaper deleted a CHROME profile" "$out"; fi
if printf '%s' "$out" | grep 'cr-profile-\* dirs: 2' >/dev/null; then
  ok "the report counts them and says they are not handled"
else nok "cr-profile-* should be named as explicitly unhandled" "$out"; fi

# ── 13. a missing master blocks --delete entirely ───────────────────────
new_home no-master
rm -rf "$H/ff-profile"
clone CLE-z >/dev/null
out="$(reap --delete --all-ages)"; rc=$?
[[ $VERBOSE -eq 1 ]] && printf '%s\n' "$out"
if [[ -d "$H/ff-profile-CLE-z" && $rc -eq 2 ]]; then
  ok "with no master profile, --delete refuses and exits 2"
else
  nok "deleting clones with no master destroys the only copy of those logins" "rc=$rc / $out"
fi

# ── 14. usage errors are rejected, not guessed at ──────────────────────
new_home usage
if out="$(reap --days notanumber 2>&1)"; [[ $? -eq 2 ]]; then ok "--days must be numeric"
else nok "a non-numeric --days was accepted" "$out"; fi
if out="$(reap --home "$ROOT/does-not-exist" 2>&1)"; [[ $? -eq 2 ]]; then ok "a missing --home exits 2"
else nok "a missing --home was accepted" "$out"; fi
if out="$(reap --wat 2>&1)"; [[ $? -eq 2 ]]; then ok "an unknown flag exits 2"
else nok "an unknown flag was ignored" "$out"; fi

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
