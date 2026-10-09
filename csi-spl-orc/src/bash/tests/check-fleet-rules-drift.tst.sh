#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_fleet_rules_drift passes on this tree and on a copy of its
#          rule sources, and turns red on a PLANTED disagreement of each pinned
#          fact (id letters, count regex, ceiling number, data-rule and
#          language-rule pins, commit address), in the tree and in a box's installed copies. Every
#          control names the fact that broke. The sources are copied into a
#          throwaway tree; nothing outside it is written.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0 passes=0
pass() { echo "PASS: $1"; passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# shellcheck source=/dev/null
source "$PROJ_ROOT/src/bash/run/check-fleet-rules-drift.func.sh"

FRAG=csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md
CMDS=csi-spl-orc/src/bash/features/spawn-agents/assets/commands
NAME="FirstName LastName" ADDR="first.last@example.com"

# A copy of every source the check reads, its commit line made synthetic, one
# commit by that name and address.
mk_tree() {  # <dir>
  local d="$1"
  mkdir -p "$d"
  (cd "$APP_ROOT" && cp --parents CLAUDE.md csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md \
     csi-spl-doc/doc/md/fleet-rules-index.md csi-spl-doc/doc/md/lane-integration-rules.md \
     csi-spl-doc/doc/help/how-to-post.md csi-spl-orc/src/bash/scripts/spl-session-prune.sh \
     csi-spl-orc/src/bash/run/spl-orch-load-report.func.sh csi-spl-orc/src/bash/run/spl-lane-mix.func.sh \
     csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh \
     csi-spl-orc/src/bash/features/spool-install/install.sh \
     csi-spl-orc/src/bash/features/spool-install/steps/y4-claude-config.sh \
     "$FRAG"/*.md "$CMDS"/*.md "$d"/)
  sed -i -E "s/^- Commits: \`[^\`]+\`/- Commits: \`$NAME <$ADDR>\`/" "$d/CLAUDE.md"
  git -C "$d" init -q && git -C "$d" add -A \
    && git -C "$d" -c user.name="$NAME" -c user.email="$ADDR" commit -q -m base
}
run() { FLEET_RULES_TREE="$1" FLEET_RULES_HOME="${2:-}" do_check_fleet_rules_drift >"$T/out" 2>&1; }
# control <label> <expected FAIL fragment>: the last run must be red and name it
control() {
  if [[ $rc -ne 0 ]] && grep -q "FAIL $2" "$T/out"; then pass "control $1: red, $(grep -m1 "FAIL $2" "$T/out")"
  else fail "control $1 did not turn red on '$2' (rc=$rc)"; sed 's/^/    /' "$T/out"; fi
}

# 1. This tree: the real sources agree.
if FLEET_RULES_TREE="$APP_ROOT" do_check_fleet_rules_drift >"$T/out" 2>&1; then
  pass "1: this tree has no drift ($(grep -c '^OK' "$T/out") OK lines)"
else fail "1: this tree drifts"; sed 's/^/    /' "$T/out"; fi

# 2. The copy is green, so every red below is the plant alone.
mk_tree "$T/base"
run "$T/base"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'OK commit-address' "$T/out"; then pass "2: the copied tree is green, commit-address compared"
else fail "2: the copied tree is not green"; sed 's/^/    /' "$T/out"; fi

plant() { rm -rf "$T/p"; cp -a "$T/base" "$T/p"; }

# 3. id-letters: a doc counts the old letters.
plant; sed -i 's/\[acgmq\]-\[0-9\]{3}/[acgq]-[0-9]{3}/' "$T/p/csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md"
run "$T/p"; rc=$?; control "3 id-letters" "id-letters: csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md has \[acgq\]"

# 4. ceiling-count: one launcher's count regex differs from the home.
plant; sed -i 's/(CLE|GRK|AGY|QWN)-\[0-9\]+/(CLE|GRK)-[0-9]+/' "$T/p/$CMDS/grok-spawn.md"
run "$T/p"; rc=$?; control "4 ceiling-count" "ceiling-count: $CMDS/grok-spawn.md counts"

# 5. ceiling-number: the repo CLAUDE.md says another number.
plant; sed -i 's/Agent ceiling: 40/Agent ceiling: 41/' "$T/p/CLAUDE.md"
run "$T/p"; rc=$?; control "5 ceiling-number" "ceiling-number: install.sh=40 y4-claude-config.sh=40 CLAUDE.md=41"

# 6. data-rule: two pins disagree.
plant; sed -i 's/data-rule-vendors: claude mistral/data-rule-vendors: claude qwen/' "$T/p/$CMDS/spawn-an-agent.md"
run "$T/p"; rc=$?; control "6 data-rule pins" "data-rule: $CMDS/spawn-an-agent.md:[0-9]* pins 'claude qwen'"

# 6b. data-rule: both pins agree, but the prose under them never names a pinned vendor.
plant; sed -i 's/data-rule-vendors: claude mistral/data-rule-vendors: claude mistral zvendor/' "$T/p/$FRAG/20-spawn-an-agent.md" "$T/p/$CMDS/spawn-an-agent.md"
run "$T/p"; rc=$?; control "6b data-rule prose" "data-rule: $FRAG/20-spawn-an-agent.md:[0-9]* pins zvendor, the prose under the pin never names it"

# 7. data-rule: the home lost its pin.
plant; sed -i '/fleet-pin data-rule-vendors/d' "$T/p/$FRAG/20-spawn-an-agent.md"
run "$T/p"; rc=$?; control "7 data-rule missing pin" "data-rule: no data-rule-vendors pin in $FRAG/20-spawn-an-agent.md"

# 8. data-rule: the code sends secrets outside the pinned set.
plant; sed -i 's/_spl_lane_mix_pick claude "data rule:/_spl_lane_mix_pick grok "data rule:/' "$T/p/csi-spl-orc/src/bash/run/spl-lane-mix.func.sh"
run "$T/p"; rc=$?; control "8 data-rule code" "data-rule: do_spl_lane_mix's secret pick is grok"

# 8b. language-rule: a pin names another vendor; the code sends i18n elsewhere.
plant; sed -i 's/language-rule-final: agy/language-rule-final: grok/' "$T/p/$CMDS/spawn-an-agent.md"
run "$T/p"; rc=$?; control "8b language-rule pins" "language-rule: $CMDS/spawn-an-agent.md:[0-9]* pins 'grok'"
plant; sed -i 's/_spl_lane_mix_want agy "kind i18n:/_spl_lane_mix_want claude "kind i18n:/' "$T/p/csi-spl-orc/src/bash/run/spl-lane-mix.func.sh"
run "$T/p"; rc=$?; control "8c language-rule code" "language-rule: do_spl_lane_mix's i18n pick is claude"

# 9. per-kind-main: a per-kind main vendor is altered.
plant; sed -i 's/(`specs_and_docs`) *| agy *|/(`specs_and_docs`) | mistral |/' "$T/p/$FRAG/20-spawn-an-agent.md"
run "$T/p"; rc=$?; control "9 per-kind-main" "per-kind-main: $FRAG/20-spawn-an-agent.md:[0-9]* defines specs_and_docs main as mistral"
# 9b. the launcher's table sits further down the file (15080ef2e read lines 13..18 only).
plant; sed -i 's/`LANE_MIX_KIND=i18n` *| agy *|/`LANE_MIX_KIND=i18n` | grok |/' "$T/p/$CMDS/spawn-an-agent.md"
run "$T/p"; rc=$?; control "9b per-kind-main launcher" "per-kind-main: $CMDS/spawn-an-agent.md:[0-9]* defines i18n main as grok"

# 10. commit-address: a commit by the same name with another address.
plant; echo x >>"$T/p/x"; git -C "$T/p" add x
git -C "$T/p" -c user.name="$NAME" -c user.email="other@example.com" commit -q -m drift
run "$T/p"; rc=$?; control "9 commit-address" "commit-address: a commit by that author name uses <other@example.com>"

# 10. Installed copies: a current install is green; an old one is red.
H="$T/home"; mkdir -p "$H/.claude/commands"
cat "$T/base/$FRAG"/*.md >"$H/.claude/CLAUDE.md"; cp "$T/base/$CMDS"/*-spawn.md "$H/.claude/commands/"
run "$T/base" "$H"; rc=$?
[[ $rc -eq 0 ]] && pass "10: installed copies that match the sources are green" || { fail "10: a current install is red"; sed 's/^/    /' "$T/out"; }
sed -i 's/\[acgmq\]-\[0-9\]{3}/[acgq]-[0-9]{3}/' "$H/.claude/commands/qwen-spawn.md"
run "$T/base" "$H"; rc=$?; control "10 installed launcher" "id-letters: $H/.claude/commands/qwen-spawn.md has \[acgq\]"
cat "$T/base/$FRAG"/*.md | sed '/fleet-pin data-rule-vendors/d' >"$H/.claude/CLAUDE.md"; cp "$T/base/$CMDS"/qwen-spawn.md "$H/.claude/commands/"
run "$T/base" "$H"; rc=$?; control "10 installed CLAUDE.md predates the pin" "data-rule: $H/.claude/CLAUDE.md has no data-rule-vendors pin"

# 11. A tree with no git history skips fact 5 and says so; it never passes it silently.
plant; rm -rf "$T/p/.git"
run "$T/p"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'SKIP commit-address' "$T/out" && pass "11: no history = SKIP commit-address, named" \
  || { fail "11: no-history tree"; sed 's/^/    /' "$T/out"; }

echo "== $passes/$((passes + fails)) passed"
exit "$fails"
