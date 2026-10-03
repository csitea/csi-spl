#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: steps/y5-adopt-skills.sh (specs/069 Y5), hermetic. A throwaway HOME
#          seeded the way the frozen engine left an agent's home: /signed-prompt
#          and three skills rendered WITHOUT the spool-install marker, one skill
#          a symlinked dir. Step 5b is install.sh's own python, cut out of it,
#          so the render under test is the shipped one.
#   1. CONTROL: 5b alone leaves the four engine copies unmarked ("not ours")
#   2. --dry-run (DRY=1) plans the four hand-overs and moves nothing
#   3. y5 then 5b: every file under ~/.claude/{commands,skills} carries the
#      marker; the engine copies are kept as .bak-spool-install; the symlinked
#      skill dir is unlinked and its target is untouched; a foreign file of
#      another name is never touched
#   4. a re-run moves nothing and rewrites nothing
#   5. the rendered /tmux-color and /signed-prompt run scripts that exist in
#      this checkout, and name no path outside it
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
INSTALL="$TEST_DIR/../install.sh"
STEP="$TEST_DIR/../steps/y5-adopt-skills.sh"
HARNESS="$(cd "$TEST_DIR/../../spawn-agents" && pwd)"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H"
MARK='<!-- spool-install: sha256='

# Step 5b's renderer, exactly as install.sh ships it.
awk "/<<'EOF_PY'/{f=1; next} /^EOF_PY\$/{f=0} f" "$INSTALL" >"$T/render.py"
grep -q 'spool-install: sha256' "$T/render.py" || { echo "FAIL: cannot cut step 5b out of $INSTALL"; exit 1; }
render() { python3 "$T/render.py" "$HARNESS/assets" "$H" 0 0 "$HARNESS" "$T/spool" 40 c-001 2>>"$T/o"; }
adopt() { ( DRY="${1:-0}"; say() { echo "spool-install: $*" >>"$T/o"; }; plan() { [ "$DRY" = 1 ] && echo "would: $*" >>"$T/o"; }
            # shellcheck source=../steps/y5-adopt-skills.sh
            . "$STEP" && y5_adopt_skills "$H" ); }
unmarked() { local f; for f in "$H"/.claude/commands/*.md "$H"/.claude/skills/*/SKILL.md; do grep -qF "$MARK" "$f" || echo "${f#"$H"/.claude/}"; done; }

# The home as the engine left it.
mkdir -p "$H/.claude/commands" "$H/.claude/skills/paste-html-into-chrome" "$H/.claude/skills/spec-kit-tasks" "$T/engine/tmux-color"
for f in commands/signed-prompt.md skills/paste-html-into-chrome/SKILL.md skills/spec-kit-tasks/SKILL.md; do
  echo "ENGINE COPY of $f" >"$H/.claude/$f"
done
echo "ENGINE COPY of tmux-color" >"$T/engine/tmux-color/SKILL.md"
ln -s "$T/engine/tmux-color" "$H/.claude/skills/tmux-color"
echo "mine" >"$H/.claude/commands/mine.md"

# --- 1. control -------------------------------------------------------------------
render
got="$(unmarked | sort | tr '\n' ' ')"
[ "$got" = "commands/mine.md commands/signed-prompt.md skills/paste-html-into-chrome/SKILL.md skills/spec-kit-tasks/SKILL.md skills/tmux-color/SKILL.md " ] &&
  pass "1. control: 5b alone leaves the 4 engine copies unmarked" || fail "1. control: unmarked = '$got'"

# --- 2. dry run -------------------------------------------------------------------
: >"$T/o"; adopt 1; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c '^would: ' "$T/o")" = 4 ] && [ -L "$H/.claude/skills/tmux-color" ] &&
  grep -q 'ENGINE COPY' "$H/.claude/commands/signed-prompt.md" && ! ls "$H"/.claude/commands/*.bak-spool-install >/dev/null 2>&1 &&
  pass "2. DRY=1 plans the 4 hand-overs and moves nothing" || fail "2. dry run: rc $rc $(cat "$T/o")"

# --- 3. hand over, then render ------------------------------------------------------
: >"$T/o"; adopt 0; rc=$?; render
[ "$rc" = 0 ] && [ "$(unmarked)" = "commands/mine.md" ] &&
  pass "3. after y5 + 5b every csi-spl command and skill carries the marker" || fail "3. rc $rc, unmarked: $(unmarked | tr '\n' ' ') $(cat "$T/o")"
total="$(ls "$H"/.claude/commands/*.md "$H"/.claude/skills/*/SKILL.md | wc -l)"
want=$(( $(ls "$HARNESS/assets/commands" | wc -l) + $(ls "$HARNESS/assets/skills" | wc -l) + 1 ))
[ "$total" = "$want" ] && pass "3. $((total - 1)) marked files, nothing extra in commands/ or skills/" || fail "3. $total files, want $want"
for f in commands/signed-prompt.md skills/paste-html-into-chrome/SKILL.md skills/spec-kit-tasks/SKILL.md; do
  grep -q 'ENGINE COPY' "$H/.claude/$f.bak-spool-install" 2>/dev/null || fail "3. no backup of $f"
done
[ ! -L "$H/.claude/skills/tmux-color" ] && grep -q 'ENGINE COPY' "$T/engine/tmux-color/SKILL.md" &&
  pass "3. the symlinked skill dir is unlinked, its target untouched" || fail "3. symlink: $(ls -la "$H/.claude/skills")"
[ "$(cat "$H/.claude/commands/mine.md")" = mine ] && pass "3. a foreign file of another name is never touched" || fail "3. mine.md changed"

# --- 4. re-run ----------------------------------------------------------------------
cp -a "$H/.claude" "$T/before"
: >"$T/o"; adopt 0; render
diff -r "$T/before" "$H/.claude" >/dev/null && ! grep -q adopted "$T/o" && grep -q 'skills: 0 written' "$T/o" &&
  pass "4. a re-run moves nothing and rewrites nothing" || fail "4. re-run: $(cat "$T/o")"

# --- 5. the rendered commands run this checkout's scripts ---------------------------------
tc="$(grep -oE "bash [^ ]+/tmux-window-color\.sh" "$H/.claude/skills/tmux-color/SKILL.md" | head -1)"
[ -n "$tc" ] && [ -f "${tc#bash }" ] && [ "$(readlink -f "${tc#bash }")" = "$HARNESS/scripts/tmux-window-color.sh" ] &&
  pass "5. /tmux-color runs this checkout's tmux-window-color.sh" || fail "5. tmux-color: '$tc'"
miss=""
for s in $(grep -oE "bash [^ ]+/directive-[a-z]+\.sh" "$H/.claude/commands/signed-prompt.md" | sed 's/^bash //' | sort -u); do
  [ -f "$s" ] || miss="$miss $s"
  case "$(readlink -f "$s")" in "$HARNESS/../directive/scripts/"*|"$(cd "$HARNESS/../directive/scripts" && pwd)/"*) ;; *) miss="$miss outside:$s" ;; esac
done
[ "$(grep -cE 'bash [^ ]+/directive-(session|sign)\.sh' "$H/.claude/commands/signed-prompt.md")" -ge 3 ] && [ -z "$miss" ] &&
  pass "5. /signed-prompt runs this checkout's directive scripts" || fail "5. signed-prompt:$miss"

echo "-- y5-adopt: $((n - fails))/$n passed"
[ "$fails" -eq 0 ]
