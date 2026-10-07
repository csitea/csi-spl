#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: steps/y4-claude-config.sh (spec 069 lane Y4), hermetic: a throwaway
#          HOME, every placeholder value given in the environment.
#   1. an empty HOME: CLAUDE.md and settings.json carry the spool-install
#      marker, no {{placeholder}} is left; a re-run rewrites nothing
#   2. a CLAUDE.md an older renderer wrote: the personal fragments and the
#      header stay byte for byte, a same-NN fleet fragment is taken over (gone,
#      named), the block is there once, a backup is kept
#   3. a hand-edited block is left alone and named; --force-skills replaces it
#   4. settings.json: other keys and the mirror hooks kept, ours win; a file
#      that is not JSON fails the step and is left untouched
#   5. DRY=1 and SPOOL_INSTALL_CLAUDE_CONFIG=0 write nothing
#   6. the assets carry no banned literal (the distribution-hygiene sweep)
#   8. the BOX_USER's settings.json (the human's): only the 5 fleet keys and
#      the box marker are set; every other key keeps its value (allow list,
#      statusLine, theme, hooks, a stale fleet value under another key);
#      a backup of the old file, valid JSON, owner kept (in place); a re-run
#      rewrites nothing; a reachable file uses no sudo; a file in a home
#      closed to this user goes through sudo -n -u <box user> (stubbed), and
#      without sudo is named and left alone; DRY=1, a missing, an
#      unwritable and a non-JSON file
#      are left alone and the step still exits 0; the box path equal to the
#      agent's is the agent merge only; the marker exported in the
#      environment (a seat does that) does not move the path
#   7. the diff against a CLAUDE.md of today = only the personal fragments:
#      the control (an asset changed by one word) FAILS it; with
#      SPOOL_CLAUDE_MD_LIVE=<an agent's live CLAUDE.md> it runs against that
#      file too (plus SPOOL_AGENT_USER / SPOOL_BOX_USER / SPOOL_BOX_TAG /
#      SPOOL_TMUX_SOCKET of that box), else against claude-md-today.fixture.md
#      (the assets rendered with the fixed values of TODAY_VALS below, plus
#      one personal fragment): an asset changed without that fixture FAILS.
#      Re-pin it after a deliberate asset change with
#        python3 ../steps/y4-claude-config.py ../assets/claude <dir> 0 0 <TODAY_VALS>
#      (<dir>/.claude/CLAUDE.md, then append the org/55-personal fragment)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
STEP="$TEST_DIR/../steps/y4-claude-config.sh"
ASSETS="$TEST_DIR/../assets/claude"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LIVE="${SPOOL_CLAUDE_MD_LIVE:-}"

# A live comparison keeps the caller's box values; a hermetic run fixes them.
if [ -z "$LIVE" ]; then
  SPOOL_AGENT_USER="$(id -un)"
  export SPOOL_AGENT_USER SPOOL_BOX_USER="$SPOOL_AGENT_USER" SPOOL_BOX_TAG=box1 \
    SPOOL_TMUX_SOCKET=/tmp/tmux-test/default SPOOL_AGENT_CEILING=40
fi
unset DRY FORCE_SKILLS SPOOL_INSTALL_CLAUDE_CONFIG SPOOL_INSTALL_CLAUDE_ASSETS
# Never the real box user's file: sections 1-7 point it at a path that is not
# there; section 8 passes its own.
export SPOOL_INSTALL_BOX_SETTINGS_FILE="$T/no-box/settings.json"
# Never the real sudo: a stub that logs its argv and refuses (sudo -n with no
# rule), one that logs and runs the command with the dir it needs opened.
cat >"$T/sudo-no" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${SUDO_LOG:-/dev/null}"; exit 1
EOF
cat >"$T/sudo-ok" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SUDO_LOG"; [ "$1 $2 $3" = "-n -u $SPOOL_BOX_USER" ] || exit 1; shift 3
chmod 755 "$SUDO_DIR"; "$@"; rc=$?; chmod 000 "$SUDO_DIR"; exit $rc
EOF
chmod +x "$T/sudo-no" "$T/sudo-ok"
export SPOOL_INSTALL_SUDO="$T/sudo-no"
step() {  # HOME [VAR=value ...]
  local h="$1"; shift
  env HOME="$h" "$@" bash -c 'source "$0" && spool_install_claude_config' "$STEP"
}
fresh() { rm -rf "${T:?}/$1"; mkdir -p "$T/$1/.claude"; echo "$T/$1"; }

# ── 1. empty HOME ────────────────────────────────────────────────────────────
H=$(fresh h1)
step "$H" 2>"$T/err1"; rc=$?
[ "$rc" = 0 ] && pass "1: the step exits 0 on an empty HOME" || { fail "1: rc $rc"; cat "$T/err1"; }
grep -q '^<!-- spool-install: begin claude-md' "$H/.claude/CLAUDE.md" &&
  grep -qE '^<!-- spool-install: end claude-md sha256=[0-9a-f]{64} -->$' "$H/.claude/CLAUDE.md" &&
  pass "1: CLAUDE.md carries the spool-install marker" || fail "1: no spool-install marker in CLAUDE.md"
python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["env"]["SPOOL_INSTALL_SETTINGS"]; assert v.startswith("sha256=")' \
  "$H/.claude/settings.json" 2>/dev/null &&
  pass "1: settings.json carries the spool-install marker" || fail "1: no SPOOL_INSTALL_SETTINGS marker in settings.json"
nfr=$(grep -c '^<!-- fragment spool-install/' "$H/.claude/CLAUDE.md")
nas=$(find "$ASSETS/claude-md" -name '*.md' | wc -l)
[ "$nfr" = "$nas" ] && pass "1: every fleet fragment rendered ($nfr)" || fail "1: $nfr fragments rendered, $nas assets"
grep -qE '\{\{[A-Z_]+\}\}' "$H/.claude/CLAUDE.md" && fail "1: a {{placeholder}} is left" || pass "1: no placeholder left"
cp "$H/.claude/CLAUDE.md" "$T/md1"; cp "$H/.claude/settings.json" "$T/st1"
step "$H" 2>"$T/err1b"
cmp -s "$T/md1" "$H/.claude/CLAUDE.md" && cmp -s "$T/st1" "$H/.claude/settings.json" &&
  [ "$(grep -c 'already current' "$T/err1b")" = 2 ] &&
  pass "1: a re-run rewrites nothing" || fail "1: a re-run changed a file"

# ── 2. a CLAUDE.md an older renderer wrote ───────────────────────────────────
H=$(fresh h2)
personal=$'<!-- fragment org/55-personal -->\n## Personal rule\n\nkeep me\n<!-- /fragment -->\n'
{ echo '<!-- generated by claude-config: box b, role agent. Edit the fragments, not this file. -->'
  printf '<!-- fragment engine/20-spawn-an-agent -->\n## old spawn rule\n<!-- /fragment -->\n'
  printf '%s' "$personal"
} >"$H/.claude/CLAUDE.md"
cp "$H/.claude/CLAUDE.md" "$T/md2"
step "$H" 2>"$T/err2"
md="$H/.claude/CLAUDE.md"
head -1 "$md" | grep '^<!-- generated by claude-config' >/dev/null && pass "2: the header line stays first" || fail "2: header moved"
grep -qF "$(printf '%s' "$personal" | sed -n 2p)" "$md" && grep -q '^keep me$' "$md" &&
  [ "$(sed -n '/^<!-- fragment org\/55-personal -->$/,/^<!-- \/fragment -->$/p' "$md")" = "${personal%$'\n'}" ] &&
  pass "2: the personal fragment is kept byte for byte" || fail "2: the personal fragment changed"
grep -q 'old spawn rule' "$md" && fail "2: the old same-NN fragment is still there" ||
  pass "2: the old same-NN fragment is taken over"
grep -q 'took over fragment engine/20-spawn-an-agent' "$T/err2" && pass "2: the take-over is named" || fail "2: take-over not named"
[ "$(grep -c '^<!-- spool-install: begin claude-md' "$md")" = 1 ] && pass "2: one block" || fail "2: block count"
cmp -s "$T/md2" "$md.bak-spool-install" && pass "2: the old file is kept as .bak-spool-install" || fail "2: no backup"
cp "$md" "$T/md2b"; step "$H" 2>/dev/null
cmp -s "$T/md2b" "$md" && pass "2: a re-run rewrites nothing" || fail "2: a re-run changed CLAUDE.md"

# ── 3. a hand-edited block ──────────────────────────────────────────────────
H=$(fresh h3); step "$H" 2>/dev/null
md="$H/.claude/CLAUDE.md"
sed -i 's/^# Global Claude Code Instructions$/# Global Claude Code Instructions (edited)/' "$md"
cp "$md" "$T/md3"
step "$H" 2>"$T/err3"
cmp -s "$T/md3" "$md" && grep -q 'edited by hand: left alone' "$T/err3" &&
  pass "3: a hand-edited block is left alone and named" || fail "3: a hand-edited block was overwritten"
step "$H" FORCE_SKILLS=1 2>/dev/null
cmp -s "$T/md1" "$md" && cmp -s "$T/md3" "$md.bak-spool-install" &&
  pass "3: --force-skills replaces it, the edit kept as .bak-spool-install" || fail "3: --force-skills did not replace it"

# ── 4. settings.json ────────────────────────────────────────────────────────
H=$(fresh h4)
cat >"$H/.claude/settings.json" <<'EOF'
{"theme": "light", "skipDangerousModePermissionPrompt": false,
 "env": {"KEEP": "1"},
 "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "python3 /x/spool-mirror.py hook"}]}]}}
EOF
step "$H" 2>/dev/null
python3 - "$H/.claude/settings.json" <<'EOF' && pass "4: other keys + hooks kept, the fleet keys win" || fail "4: settings merge"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["theme"] == "light" and s["env"]["KEEP"] == "1", s
assert "spool-mirror.py" in json.dumps(s["hooks"]["Stop"]), s
assert s["skipDangerousModePermissionPrompt"] is True and "SPOOL_INSTALL_SETTINGS" in s["env"], s
assert s["skillOverrides"]["auto-mode-setup"] == "off", s
assert s["permissions"] == {"defaultMode": "bypassPermissions", "disableAutoMode": "disable"}, s
EOF
H=$(fresh h4b); echo '{not json' >"$H/.claude/settings.json"
step "$H" 2>"$T/err4"; rc=$?
[ "$rc" != 0 ] && [ "$(cat "$H/.claude/settings.json")" = '{not json' ] &&
  pass "4: a settings.json that is not JSON fails the step and stays untouched" || fail "4: bad JSON rc=$rc"

# ── 5. DRY=1 and the off switch ──────────────────────────────────────────────
H=$(fresh h5)
step "$H" DRY=1 >"$T/out5" 2>/dev/null
[ -z "$(ls -A "$H/.claude")" ] && grep -q '^would: write .*CLAUDE.md$' "$T/out5" &&
  pass "5: DRY=1 prints the plan and writes nothing" || fail "5: DRY=1 wrote a file"
step "$H" SPOOL_INSTALL_CLAUDE_CONFIG=0 2>/dev/null
[ -z "$(ls -A "$H/.claude")" ] && pass "5: SPOOL_INSTALL_CLAUDE_CONFIG=0 skips the step" || fail "5: the off switch wrote a file"

# ── 6. hygiene of the assets ─────────────────────────────────────────────────
hits=$(grep -rnIP '(?i)\bysg\b(?!-box)|\bclaude-user\b|\bai-usr\b|\btnk\b|/home/(?!runner\b)[a-z][a-z0-9_-]*/|@gmail\.com' "$ASSETS" "$STEP" "${STEP%.sh}.py")
[ -z "$hits" ] && pass "6: no banned literal in the assets or the step" || { fail "6: banned literal"; echo "$hits"; }

# ── 7. the diff against today's CLAUDE.md = only the personal fragments ──────
# compare LIVE RENDERED: every rendered fleet fragment has a fragment of the
# same NN in LIVE with the same body; prints the LIVE fragments not ours.
compare() {
  python3 - "$1" "$2" <<'EOF'
import re, sys
F = re.compile(r"<!-- fragment ([a-z-]+)/((\d{2})-[a-z0-9-]+) -->\n(.*?)<!-- /fragment -->\n", re.S)
live = {m.group(3): (m.group(1) + "/" + m.group(2), m.group(4)) for m in F.finditer(open(sys.argv[1]).read())}
ours = {m.group(3): (m.group(2), m.group(4)) for m in F.finditer(open(sys.argv[2]).read())}
bad = 0
for nn, (name, body) in sorted(ours.items()):
    if nn not in live:
        print("  missing in live: %s" % name); bad = 1
    elif live[nn][1] != body:
        print("  differs: %s vs live %s" % (name, live[nn][0])); bad = 1
print("  personal (live only): " + " ".join(live[k][0] for k in sorted(set(live) - set(ours))))
sys.exit(bad)
EOF
}
H=$(fresh h7); step "$H" 2>/dev/null
{ cat "$H/.claude/CLAUDE.md"; printf '%s' "$personal"; } >"$T/today.md"
compare "$T/today.md" "$H/.claude/CLAUDE.md" >"$T/out7" && grep -q 'personal (live only): org/55-personal$' "$T/out7" &&
  pass "7: the diff against a CLAUDE.md of today is the personal fragment only" || { fail "7: compare"; cat "$T/out7"; }
cp -r "$ASSETS" "$T/ctl"
sed -i '0,/standing order/s//STANDING ORDER/' "$T/ctl/claude-md/20-spawn-an-agent.md"
H=$(fresh h7c); step "$H" SPOOL_INSTALL_CLAUDE_ASSETS="$T/ctl" 2>/dev/null
if compare "$T/today.md" "$H/.claude/CLAUDE.md" >"$T/out7c"; then fail "7: the control (one word changed) passed"
else grep -q 'differs: 20-spawn-an-agent' "$T/out7c" && pass "7: the control FAILS: $(grep differs "$T/out7c" | sed 's/^ *//')" ||
  fail "7: the control failed for another reason"; fi
if [ -n "$LIVE" ] && [ -r "$LIVE" ]; then
  if compare "$LIVE" "$T/h7/.claude/CLAUDE.md" >"$T/out7l"; then
    pass "7: live $LIVE: fleet fragments identical;$(grep personal "$T/out7l" | sed 's/^ *personal/ personal/')"
  else fail "7: live $LIVE differs"; cat "$T/out7l"; fi
else
  # Hermetic stand-in for a live file: the pinned fixture, rendered by the
  # renderer itself with fixed values (no passwd lookup, so CI renders the same).
  TODAY="$TEST_DIR/claude-md-today.fixture.md"
  TODAY_VALS=(AGENT_USER=agent-user AGENT_HOME=/srv/agent-user BOX_USER=box-user BOX_HOME=/srv/box-user
    TMUX_SOCKET=/tmp/tmux-box/default BOX_TAG=box1 AGENT_CEILING=40)
  mkdir -p "$T/h7f/.claude"
  python3 "${STEP%.sh}.py" "$ASSETS" "$T/h7f" 0 0 "${TODAY_VALS[@]}" 2>/dev/null
  if compare "$TODAY" "$T/h7f/.claude/CLAUDE.md" >"$T/out7f" && grep -q 'personal (live only): org/55-personal$' "$T/out7f"; then
    pass "7: fixture $(basename "$TODAY"): fleet fragments identical, personal org/55-personal only"
  else fail "7: fixture $(basename "$TODAY") differs from the assets"; cat "$T/out7f"; fi
  sed '0,/standing order/s//STANDING ORDER/' "$TODAY" >"$T/today-ctl.md"
  if compare "$T/today-ctl.md" "$T/h7f/.claude/CLAUDE.md" >"$T/out7fc"; then fail "7: the fixture control (one word changed) passed"
  else grep -q 'differs: 20-spawn-an-agent' "$T/out7fc" && pass "7: the fixture control FAILS: $(grep differs "$T/out7fc" | sed 's/^ *//')" ||
    fail "7: the fixture control failed for another reason"; fi
fi

# ── 8. the BOX_USER's settings.json: the 5 fleet keys only ──────────────────
H=$(fresh h8); B="$T/box8/.claude"; mkdir -p "$B"; BS="$B/settings.json"
cp "$TEST_DIR/box-settings.fixture.json" "$BS"; chmod 640 "$BS"
# the marker in the environment, as a seat whose settings carry it exports it
step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" SPOOL_INSTALL_BOX_SETTINGS=sha256=0 SUDO_LOG="$T/sudo8" 2>"$T/err8"; rc=$?
[ "$rc" = 0 ] && grep -q "box user's fleet keys set, other keys kept" "$T/err8" &&
  pass "8: the step sets the box user's fleet keys" || { fail "8: rc $rc"; cat "$T/err8"; }
[ ! -e "$T/sudo8" ] && pass "8: a reachable box file: no sudo used" || fail "8: sudo used on a reachable file: $(cat "$T/sudo8")"
python3 - "$TEST_DIR/box-settings.fixture.json" "$BS" <<'EOF' && pass "8: only the 5 keys + the marker changed, every other key byte-identical in value" || fail "8: box merge"
import json, sys
old, new = (json.load(open(p)) for p in sys.argv[1:3])
want = {("permissions", "defaultMode"): "bypassPermissions", ("permissions", "disableAutoMode"): "disable",
        ("skipDangerousModePermissionPrompt",): True, ("skillOverrides", "auto-mode-setup"): "off",
        ("env", "DISABLE_AUTOUPDATER"): "1"}
def leaves(d, pre=()):
    for k, v in d.items():
        yield from leaves(v, pre + (k,)) if isinstance(v, dict) and v else [(pre + (k,), v)]
o, n = dict(leaves(old)), dict(leaves(new))
for p, v in want.items(): assert n.pop(p) == v, (p, n)
assert n.pop(("env", "SPOOL_INSTALL_BOX_SETTINGS")).startswith("sha256="), n
for p in want: o.pop(p, None)
assert o.keys() == n.keys() and all(json.dumps(o[k]) == json.dumps(n[k]) for k in o), (o, n)
assert "SPOOL_INSTALL_SETTINGS" not in new["env"] and "agentPushNotifEnabled" not in new, new
EOF
cmp -s "$TEST_DIR/box-settings.fixture.json" "$BS.bak-spool-install-box" &&
  pass "8: the old file is kept as .bak-spool-install-box" || fail "8: no backup"
[ "$(stat -c %a "$BS")" = 640 ] && pass "8: written in place (mode kept)" || fail "8: mode $(stat -c %a "$BS")"
cp "$BS" "$T/bs8"; step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" 2>"$T/err8b"
cmp -s "$T/bs8" "$BS" && grep -q "box user's fleet keys already current" "$T/err8b" &&
  pass "8: a re-run rewrites nothing" || fail "8: a re-run changed the box file"
cp "$TEST_DIR/box-settings.fixture.json" "$BS"; rm -f "$BS.bak-spool-install-box"
step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" DRY=1 >"$T/out8" 2>/dev/null
cmp -s "$TEST_DIR/box-settings.fixture.json" "$BS" && [ ! -e "$BS.bak-spool-install-box" ] && grep -q "^would: write $BS$" "$T/out8" &&
  pass "8: DRY=1 names the box file and writes nothing" || fail "8: DRY=1 wrote the box file"
chmod 440 "$BS"; step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" 2>"$T/err8c"; rc=$?; chmod 640 "$BS"
if [ "$(id -u)" = 0 ]; then pass "8: unwritable: skipped (root writes anything)"
else [ "$rc" = 0 ] && cmp -s "$TEST_DIR/box-settings.fixture.json" "$BS" && grep -q 'not writable by this user: left alone' "$T/err8c" &&
  pass "8: an unwritable box file is named and left alone, rc 0" || fail "8: unwritable rc=$rc"; fi
echo '{not json' >"$BS"; step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" 2>"$T/err8d"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$BS")" = '{not json' ] && grep -q 'not valid settings JSON' "$T/err8d" &&
  pass "8: a non-JSON box file is named and left alone, rc 0" || fail "8: bad JSON rc=$rc"
step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$T/box8/none.json" 2>"$T/err8e"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/box8/none.json" ] && grep -q 'has no settings.json: left alone' "$T/err8e" &&
  pass "8: a missing box file is named, not created" || fail "8: missing rc=$rc"
cp "$TEST_DIR/box-settings.fixture.json" "$BS"; rm -f "$BS.bak-spool-install-box" "$T/sudo8g"; chmod 000 "$T/box8"
step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" SUDO_LOG="$T/sudo8g" 2>"$T/err8g"; rc=$?; chmod 755 "$T/box8"
if [ "$(id -u)" = 0 ]; then pass "8: unreachable: skipped (root reaches anything)"
else [ "$rc" = 0 ] && cmp -s "$TEST_DIR/box-settings.fixture.json" "$BS" && grep -q "not reachable by this user .* and no sudo -n -u $SPOOL_BOX_USER: left alone" "$T/err8g" &&
  grep -q "^-n -u $SPOOL_BOX_USER " "$T/sudo8g" &&
  pass "8: unreachable + sudo refused: named, untouched, rc 0" || fail "8: unreachable, no sudo: rc=$rc $(cat "$T/err8g")"; fi
rm -f "$T/sudo8h"; chmod 000 "$T/box8"
step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$BS" SPOOL_INSTALL_SUDO="$T/sudo-ok" SUDO_LOG="$T/sudo8h" SUDO_DIR="$T/box8" 2>"$T/err8h"; rc=$?; chmod 755 "$T/box8"
if [ "$(id -u)" = 0 ]; then pass "8: unreachable + sudo: skipped (root reaches anything)"
else [ "$rc" = 0 ] && grep -q "(as $SPOOL_BOX_USER) .*box user's fleet keys set, other keys kept" "$T/err8h" &&
  cmp -s "$T/bs8" "$BS" && cmp -s "$TEST_DIR/box-settings.fixture.json" "$BS.bak-spool-install-box" &&
  grep -q -- "^-n -u $SPOOL_BOX_USER .*--box-file $BS 0 " "$T/sudo8h" &&
  pass "8: unreachable + sudo ok: merged through sudo -n -u <box user>, same result, backup kept" || fail "8: unreachable + sudo: rc=$rc $(cat "$T/err8h")"; fi
H=$(fresh h8s); step "$H" SPOOL_INSTALL_BOX_SETTINGS_FILE="$H/.claude/settings.json" 2>"$T/err8f"
grep -q "the box user's file is the agent's" "$T/err8f" && ! grep -q SPOOL_INSTALL_BOX_SETTINGS "$H/.claude/settings.json" &&
  pass "8: box file = agent file: the agent merge only" || fail "8: same file"

echo "== $((n - fails))/$n passed"
[ "$fails" = 0 ]
