#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_fleet_rules_drift passes on this tree and on a copy of its
#          rule sources, and turns red on a PLANTED disagreement of each pinned
#          fact (id letters, count regex, ceiling number, data-rule and
#          language-rule pins, commit address, a path / action / make target /
#          spec folder / terraform step named in the repo-root CLAUDE.md or
#          AGENTS.md that is not on the tree, a csi-spl-* dir with no row in
#          the CLAUDE.md dir table), in the tree and in a box's installed copies. Every
#          control names the fact that broke. The sources are copied into a
#          throwaway tree; nothing outside it is written.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Run from the throwaway dir, never the caller's: a glob that forgets
# $APP_ROOT is then red wherever the suite runs, not only off the repo root
# (SPL-3719: 24/27 from csi-spl-orc/, 27/27 from the root).
cd "$T" || exit 1
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
  (cd "$APP_ROOT" && cp --parents CLAUDE.md AGENTS.md .gitignore csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md \
     csi-spl-doc/doc/md/fleet-rules-index.md csi-spl-doc/doc/md/lane-integration-rules.md \
     csi-spl-doc/doc/help/how-to-post.md csi-spl-orc/src/bash/scripts/spl-session-prune.sh \
     csi-spl-orc/src/bash/run/spl-orch-load-report.func.sh csi-spl-orc/src/bash/run/spl-lane-mix.func.sh \
     csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh \
     csi-spl-orc/src/bash/features/spool-install/install.sh \
     csi-spl-orc/src/bash/features/spool-install/steps/y4-claude-config.sh \
     "$FRAG"/*.md "$CMDS"/*.md "$d"/)
  sed -i -E "s/^- Commits: \`[^\`]+\`/- Commits: \`$NAME <$ADDR>\`/" "$d/CLAUDE.md"
  stub_refs "$d"
  git -C "$d" init -q && git -C "$d" add -A \
    && git -C "$d" -c user.name="$NAME" -c user.email="$ADDR" commit -q -m base
}
# Every reference the agent docs make gets a stub in the copy, where the real
# tree has it: a path (file or dir, at the root or under its component), an
# action, a make target, a spec folder.
stub_refs() {  # <dir>
  local d="$1" kind ref c comps=("")
  for c in "$APP_ROOT"/csi-spl-*/; do comps+=("${c#"$APP_ROOT"/}"); done
  while IFS=$'\t' read -r kind ref _; do
    case "$kind" in
      path)
        for c in "${comps[@]}"; do [[ -e "$APP_ROOT/$c$ref" ]] && break; c=-; done
        [[ "$c" == - || -e "$d/$c$ref" ]] && continue
        if [[ -d "$APP_ROOT/$c$ref" ]]; then mkdir -p "$d/$c$ref"; else mkdir -p "$(dirname "$d/$c$ref")"; touch "$d/$c$ref"; fi ;;
      action) mkdir -p "$d/csi-spl-orc/src/bash/run"; echo "$ref() { :; }" >>"$d/csi-spl-orc/src/bash/run/stub-actions.sh" ;;
      target) mkdir -p "$d/csi-spl-orc/src/make"; printf '%s:\n' "$ref" >>"$d/csi-spl-orc/src/make/stub.mk" ;;
      spec)   compgen -G "$d/csi-spl-doc/specs/$ref-*" >/dev/null || mkdir -p "$d/csi-spl-doc/specs/$ref-stub" ;;
      tfstep) compgen -G "$d/csi-spl-iac/src/terraform/$ref-*" >/dev/null || mkdir -p "$d/csi-spl-iac/src/terraform/$ref-stub" ;;
    esac
  done < <(cd "$APP_ROOT" && _frd_doc_refs "$APP_ROOT")
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
if [[ $rc -eq 0 ]] && grep -q 'OK commit-address' "$T/out" && grep -q 'OK repo-refs: .* (1 git-ignored, skipped)' "$T/out"; then
  pass "2: the copied tree is green, commit-address compared, $(grep -oE 'repo-refs: [0-9]+ references' "$T/out")"
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
plant; sed -i 's/data-rule-vendors: claude grok mistral/data-rule-vendors: claude qwen/' "$T/p/$CMDS/spawn-an-agent.md"
run "$T/p"; rc=$?; control "6 data-rule pins" "data-rule: $CMDS/spawn-an-agent.md:[0-9]* pins 'claude qwen'"

# 6b. data-rule: both pins agree, but the prose under them never names a pinned vendor.
plant; sed -i 's/data-rule-vendors: claude grok mistral/data-rule-vendors: claude grok mistral zvendor/' "$T/p/$FRAG/20-spawn-an-agent.md" "$T/p/$CMDS/spawn-an-agent.md"
run "$T/p"; rc=$?; control "6b data-rule prose" "data-rule: $FRAG/20-spawn-an-agent.md:[0-9]* pins zvendor, the prose under the pin never names it"

# 7. data-rule: the home lost its pin.
plant; sed -i '/fleet-pin data-rule-vendors/d' "$T/p/$FRAG/20-spawn-an-agent.md"
run "$T/p"; rc=$?; control "7 data-rule missing pin" "data-rule: no data-rule-vendors pin in $FRAG/20-spawn-an-agent.md"

# 8. data-rule: the code sends secrets outside the pinned set.
plant; sed -i 's/_spl_lane_mix_pick claude "data rule:/_spl_lane_mix_pick qwen "data rule:/' "$T/p/csi-spl-orc/src/bash/run/spl-lane-mix.func.sh"
run "$T/p"; rc=$?; control "8 data-rule code" "data-rule: do_spl_lane_mix's secret pick is qwen"

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

# 12. repo-refs: CLAUDE.md or AGENTS.md names what is not on the tree, one plant per kind.
plant; echo 'See `csi-spl-doc/doc/md/no-such-page.md`.' >>"$T/p/CLAUDE.md"
run "$T/p"; rc=$?; control "12a repo-refs path" "repo-refs: CLAUDE.md:[0-9]* names path 'csi-spl-doc/doc/md/no-such-page.md'"
plant; echo 'See [the gone spec](csi-spl-doc/specs/999-gone/spec.md#1-x).' >>"$T/p/AGENTS.md"
run "$T/p"; rc=$?; control "12b repo-refs link" "repo-refs: AGENTS.md:[0-9]* names path 'csi-spl-doc/specs/999-gone/spec.md'"
plant; echo 'Run `./run -a do_no_such_action`.' >>"$T/p/CLAUDE.md"
run "$T/p"; rc=$?; control "12c repo-refs action" "repo-refs: CLAUDE.md:[0-9]* names action 'do_no_such_action'"
plant; echo 'Run `make do-no-such-target`.' >>"$T/p/CLAUDE.md"
run "$T/p"; rc=$?; control "12d repo-refs target" "repo-refs: CLAUDE.md:[0-9]* names target 'do-no-such-target'"
plant; echo 'Read spec 998 first.' >>"$T/p/AGENTS.md"
run "$T/p"; rc=$?; control "12e repo-refs spec" "repo-refs: AGENTS.md:[0-9]* names spec '998'"
# 12f. a referenced path removed from the tree (not only a new bad line) is red too.
plant; rm -f "$T/p/csi-spl-doc/doc/md/pre-push-gate.md"
run "$T/p"; rc=$?; control "12f repo-refs removed file" "repo-refs: CLAUDE.md:[0-9]* names path 'csi-spl-doc/doc/md/pre-push-gate.md'"
plant; echo 'Served by terraform steps `019`, `998`.' >>"$T/p/CLAUDE.md"
run "$T/p"; rc=$?; control "12g repo-refs terraform step" "repo-refs: CLAUDE.md:[0-9]* names tfstep '998'"
# 12h. a top-level csi-spl-* dir with no row in the CLAUDE.md dir table.
plant; sed -i '/^| `csi-spl-rdb` |/d' "$T/p/CLAUDE.md"
run "$T/p"; rc=$?; control "12h repo-refs dir table row" "repo-refs: the CLAUDE.md dir table has no row for csi-spl-rdb"
plant; mkdir -p "$T/p/csi-spl-new"
run "$T/p"; rc=$?; control "12i repo-refs new component" "repo-refs: the CLAUDE.md dir table has no row for csi-spl-new"

# 11. A tree with no git history skips fact 5 and says so; it never passes it silently.
plant; rm -rf "$T/p/.git"
run "$T/p"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'SKIP commit-address' "$T/out" && pass "11: no history = SKIP commit-address, named" \
  || { fail "11: no-history tree"; sed 's/^/    /' "$T/out"; }

echo "== $passes/$((passes + fails)) passed"
exit "$fails"
