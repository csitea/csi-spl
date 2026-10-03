#!/usr/bin/env bash
# test-graft-install.sh -- spec 069 Y6: the install step points H1, L4, L5 at
# csi-spl, in a sandbox HOME seeded the way a box looks today (the wrapper and
# both links pointing into a fake engine copy of the graft feature).
#
#   control   before the step the wrapper runs the ENGINE's graft-safe.sh
#   dry run   names every change, changes nothing
#   apply     the wrapper execs THIS checkout's graft-safe.sh and keeps the raw
#             launcher it named; the skill and agy-rule links resolve into
#             csi-spl; graft-safe's refusals are in force through it
#   rerun     idempotent: nothing rewritten
#   foreign   a real skill dir, or a link to something else, is left alone
#   absent    no graft on <bin>: named, rc 0; no ~/.gemini: no rule link
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ORC="$(cd "$FEATURE_DIR/../../../.." && pwd -P)"
STEP="$ORC/src/bash/features/spool-install/steps/y6-graft.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

# A fake engine copy of the feature: its graft-safe.sh announces itself.
ENG="$T/engine/src/bash/features/graft"
mkdir -p "$ENG/scripts" "$ENG/assets/skills/graft" "$ENG/assets/agy-rules" "$T/raw"
printf '#!/usr/bin/env bash\necho ENGINE-SAFE "$@"\n' > "$ENG/scripts/graft-safe.sh"
echo engine-skill > "$ENG/assets/skills/graft/SKILL.md"; echo engine-rule > "$ENG/assets/agy-rules/graft.md"
printf '#!/usr/bin/env bash\necho RAW-GRAFT "$@"\n' > "$T/raw/cli.js"; chmod 755 "$T/raw/cli.js"

seed() {  # HOME
  local h="$1"
  mkdir -p "$h/.local/bin" "$h/.claude/skills" "$h/.gemini/config/rules"
  printf '%s\n' '#!/usr/bin/env bash' '# installed by the graft feature — do not edit; edit the feature instead' \
    "export GRAFT_SAFE_BIN='$T/raw/cli.js'" "exec bash '$ENG/scripts/graft-safe.sh' \"\$@\"" > "$h/.local/bin/graft"
  chmod 755 "$h/.local/bin/graft"
  ln -s "$ENG/assets/skills/graft" "$h/.claude/skills/graft"
  ln -s "$ENG/assets/agy-rules/graft.md" "$h/.gemini/config/rules/graft.md"
}
step() {  # HOME DRY
  HOME="$1" bash -c '. "$1"; y6_graft_install "$2" "$3/.local/bin" "$4"' _ "$STEP" "$ORC" "$1" "$2" 2>&1
}
snap() { (cd "$1" && find . -printf '%p %l\n' | sort; cat .local/bin/graft); }

H="$T/h1"; seed "$H"
echo "== control"
has "$(cd "$T" && "$H/.local/bin/graft" ask x 2>&1)" "ENGINE-SAFE ask x" "control: today's wrapper runs the engine's graft-safe.sh"

echo "== dry run"
before="$(snap "$H")"
out="$(step "$H" 1)"; rc=$?
is "$rc" 0 "dry run: rc 0"
has "$out" "would: link $H/.claude/skills/graft -> $FEATURE_DIR/assets/skills/graft" "dry run: names the skill link (L4)"
has "$out" "would: link $H/.gemini/config/rules/graft.md -> $FEATURE_DIR/assets/agy-rules/graft.md" "dry run: names the agy rule link (L5)"
has "$out" "would: make $H/.local/bin/graft the wrapper stub for $SCRIPTS/graft-safe.sh (real: $T/raw/cli.js)" "dry run: names the wrapper (H1)"
is "$(snap "$H")" "$before" "dry run: nothing changed"

echo "== apply"
out="$(step "$H" 0)"; rc=$?
is "$rc" 0 "apply: rc 0"
is "$(readlink -f "$H/.claude/skills/graft")" "$FEATURE_DIR/assets/skills/graft" "L4: the skill resolves into csi-spl"
[ -r "$H/.claude/skills/graft/SKILL.md" ] && ok "L4: SKILL.md readable through the link" || bad "L4: no SKILL.md through the link"
is "$(readlink -f "$H/.gemini/config/rules/graft.md")" "$FEATURE_DIR/assets/agy-rules/graft.md" "L5: the agy rule resolves into csi-spl"
bash "$SCRIPTS/graft-wrap.sh" --check "$H/.local/bin/graft"; is "$?" 0 "H1: graft is the wrapper stub naming a raw launcher"
is "$(bash "$SCRIPTS/graft-wrap.sh" --target "$H/.local/bin/graft")" "$T/raw/cli.js" "H1: the raw launcher it named is kept"
out="$(cd "$T" && "$H/.local/bin/graft" ask x 2>&1)"
has "$out" "RAW-GRAFT ask x" "H1: graft runs, through csi-spl's graft-safe.sh, to the raw launcher"
hasnt "$out" "ENGINE-SAFE" "H1: the engine's graft-safe.sh is no longer run"
out="$(cd "$T" && "$H/.local/bin/graft" init 2>&1)"; rc=$?
is "$rc" 78 "H1: graft init is refused through the new wrapper"
is "$(grep -c "$T/engine" "$H/.local/bin/graft")" 0 "H1: the stub names no engine path"

echo "== rerun"
before="$(snap "$H")"
out="$(step "$H" 0)"; rc=$?
is "$rc|$out" "0|" "rerun: rc 0 and silent"
is "$(snap "$H")" "$before" "rerun: nothing rewritten"
is "$(step "$H" 1)" "" "rerun dry: nothing to do"

echo "== foreign"
H="$T/h2"; seed "$H"
rm "$H/.claude/skills/graft"; mkdir -p "$H/.claude/skills/graft"; echo mine > "$H/.claude/skills/graft/SKILL.md"
rm "$H/.gemini/config/rules/graft.md"; ln -s "$T/raw/cli.js" "$H/.gemini/config/rules/graft.md"
out="$(step "$H" 0)"; rc=$?
is "$rc" 0 "foreign: rc 0"
is "$(cat "$H/.claude/skills/graft/SKILL.md")" "mine" "foreign: a real skill dir is left alone"
has "$out" "$H/.claude/skills/graft is a real file, not ours: left alone" "foreign: ... and named"
is "$(readlink "$H/.gemini/config/rules/graft.md")" "$T/raw/cli.js" "foreign: a link to something else is left alone"
has "$out" "is not a graft feature link: left alone" "foreign: ... and named"

echo "== absent"
H="$T/h3"; mkdir -p "$H"
out="$(step "$H" 0)"; rc=$?
is "$rc" 0 "absent: no graft on bin is not a failure"
has "$out" "no graft at $H/.local/bin/graft: the wrapper is skipped" "absent: ... and is named"
[ -e "$H/.gemini" ] && bad "absent: ~/.gemini was created" || ok "absent: no ~/.gemini, no rule link"
is "$(readlink -f "$H/.claude/skills/graft")" "$FEATURE_DIR/assets/skills/graft" "absent: the skill is still linked"

echo "== a raw launcher on bin"
H="$T/h4"; mkdir -p "$H/.local/bin"; cp "$T/raw/cli.js" "$H/.local/bin/graft"
out="$(step "$H" 0)"; rc=$?
is "$rc" 0 "raw: rc 0"
has "$(cat "$H/.local/bin/graft.real")" "RAW-GRAFT" "raw: the launcher moved to graft.real"
has "$(cd "$T" && "$H/.local/bin/graft" ask y 2>&1)" "RAW-GRAFT ask y" "raw: graft runs through the wrapper"

finish
