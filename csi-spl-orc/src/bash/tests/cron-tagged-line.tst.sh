#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: cron_drop_tagged_line (lib/bash/funcs/cron-tagged-line.func.sh), the
# helper the install-cron actions share, on a fixture crontab and a fake
# crontab command. Every check has a failing control.
#   1. drop a present tag: changed, rc 0, the tagged line goes, others stay
#   2. drop an absent tag: unchanged, rc 2, the crontab is not rewritten
#   3. a line that only CONTAINS the tag mid-line (or a longer tag) stays
#   4. a dry run reports PLAN and the diff, rc 2, writes nothing
#   5. append a line: replaced in place, the log dir created; again -> unchanged
#   6. a refusing crontab: FATAL, rc 1
#   7. cron_refuse_linked_worktree and wave-1 delegation (r06-02)
#   8. cron_refuse_linked_worktree wave-2 delegation (r07-01)
#   9. cron_refuse_linked_worktree optional wording and plural callers (r08-01)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CT="$T/crontab"
fixture() {
  printf '%s\n' '0 8 * * * /opt/other/run-me.sh # other:job' \
    '0 9 * * * true # csi-spl:demo mid-line # other:mid' \
    '0 10 * * * x # csi-spl:demo-longer' \
    '*/5 * * * * bash /x/demo.sh # csi-spl:demo' >"$CT"
}
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
printf '#!/bin/sh\n[ "$1" = -l ] && cat %q; exit 1\n' "$CT" >"$T/refusing-crontab"; chmod +x "$T/refusing-crontab"
drop() {
  env PROJ_PATH="$PROJ_ROOT" bash -c 'set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/cron-tagged-line.func.sh"; cron_drop_tagged_line "$@"' _ "$@" 2>&1
}
tagged() { grep -c ' # csi-spl:demo$' "$CT"; }

# 1. a present tag
fixture; cp "$CT" "$T/ct.0"
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log")"; rc=$?
[ "$rc" = 0 ] && [ "$(tagged)" = 0 ] && grep -q '^DO cron' <<<"$out" && grep -q '^  -\*/5 .* # csi-spl:demo$' <<<"$out" \
  && [ "$(wc -l <"$CT")" = 3 ] && pass "1. a present tag is dropped: changed, rc 0, the others stay" || fail "1. present tag ($rc: $out)"
[ ! -d "$T/log" ] && pass "1. ...and a drop alone creates no log dir" || fail "1. log dir created on a drop"
cmp -s "$CT" "$T/ct.0" && fail "1. control: the crontab did not change" || pass "1. control: the crontab differs from the fixture"

# 2. an absent tag (the crontab from 1 has none left)
cp "$CT" "$T/ct.1"; touch -d '1 hour ago' "$CT"; m0=$(stat -c %Y "$CT")
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log")"; rc=$?
[ "$rc" = 2 ] && grep -qx 'OK cron: nothing to change' <<<"$out" && cmp -s "$CT" "$T/ct.1" && [ "$(stat -c %Y "$CT")" = "$m0" ] \
  && pass "2. an absent tag: unchanged, rc 2, not rewritten" || fail "2. absent tag ($rc: $out)"

# 3. mid-line and longer tags stay (checked after 1 and 2)
grep -q '# other:mid$' "$CT" && grep -q '# csi-spl:demo-longer$' "$CT" \
  && pass "3. a line that only CONTAINS the tag mid-line, or a longer tag, stays" || fail "3. ($(cat "$CT"))"

# 4. a dry run
fixture; cp "$CT" "$T/ct.4"
out="$(drop "$T/fake-crontab" csi-spl:demo 1 "$T/log" '1 2 3 4 5 new # csi-spl:demo')"; rc=$?
[ "$rc" = 2 ] && grep -q '^PLAN cron' <<<"$out" && grep -q '^  +1 2 3 4 5 new # csi-spl:demo$' <<<"$out" \
  && grep -q 'OK DRY_RUN nothing was touched' <<<"$out" && cmp -s "$CT" "$T/ct.4" && [ ! -d "$T/log" ] \
  && pass "4. a dry run prints the diff, rc 2, writes nothing" || fail "4. dry run ($rc: $out)"

# 5. append: the tagged line is replaced in place, the log dir created
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log" '1 2 3 4 5 new # csi-spl:demo')"; rc=$?
[ "$rc" = 0 ] && [ "$(tagged)" = 1 ] && grep -q '^1 2 3 4 5 new # csi-spl:demo$' "$CT" && [ -d "$T/log" ] \
  && [ "$(wc -l <"$CT")" = 4 ] && pass "5. append replaces the tagged line and creates the log dir" || fail "5. append ($rc: $out)"
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log" '1 2 3 4 5 new # csi-spl:demo')"; rc=$?
[ "$rc" = 2 ] && grep -qx 'OK cron: nothing to change' <<<"$out" && pass "5. the same append again is unchanged" || fail "5. again ($rc: $out)"

# 6. a crontab that refuses the new file
fixture
out="$(drop "$T/refusing-crontab" csi-spl:demo 0 "$T/log")"; rc=$?
[ "$rc" = 1 ] && grep -q 'FATAL crontab refused the new file' <<<"$out" && pass "6. a refusing crontab: FATAL, rc 1" || fail "6. refused ($rc: $out)"

# 7. cron_refuse_linked_worktree and wave-1 delegation (r06-02 one copy)
git init -q -b master "$T/wt-main" && git -C "$T/wt-main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T/wt-main" worktree add -q --detach "$T/wt-linked"
mkdir -p "$T/wt-main/csi-spl-orc" "$T/wt-linked/csi-spl-orc" "$T/wt-nogit/csi-spl-orc"
wt_check() {
  local pp="$1"; shift
  env PROJ_PATH="$pp" LIB="$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    source "$LIB"; cron_refuse_linked_worktree "$@"' _ "$@" 2>&1
}
out="$(wt_check "$T/wt-main/csi-spl-orc" 0 0)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "7. cron_refuse_linked_worktree allows a main checkout (dry=0)" || fail "7. main ($rc: $out)"
out="$(wt_check "$T/wt-nogit/csi-spl-orc" 0 0)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "7. cron_refuse_linked_worktree allows a non-git dir (dry=0)" || fail "7. nogit ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 0)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" ] \
  && pass "7. cron_refuse_linked_worktree refuses a linked worktree when dry=0" || fail "7. linked dry=0 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 1 0)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" ] \
  && pass "7. cron_refuse_linked_worktree warns and returns 0 when dry=1" || fail "7. linked dry=1 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "7. cron_refuse_linked_worktree skips when allow=1" || fail "7. linked allow=1 ($rc: $out)"

ctl_f="$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh"
[ "$(grep -c 'is a linked worktree: \$fatal_verb from the main checkout' "$ctl_f")" -eq 1 ] && grep -q '^cron_refuse_linked_worktree()' "$ctl_f" \
  && pass "7. one copy: cron-tagged-line.func.sh hosts cron_refuse_linked_worktree" || fail "7. host one copy"
for sib in \
  "$PROJ_ROOT/src/bash/run/spl-box-update-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-cost-rollup-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/git-prune-merged-install-cron.func.sh"; do
  own="$(grep -nE 'is a linked worktree: install from the main checkout|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "7. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "7. one copy $(basename "$sib"): own=[$own]"
done

# standalone installer linked-worktree checks (dry=1 warns, dry=0 refuses)
out="$(env -u GIT_PRUNE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" GIT_PRUNE_CRONTAB="$T/fake-crontab" GIT_PRUNE_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_git_prune_merged_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/git-prune-merged-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "7. git-prune-merged refuses a linked worktree when DRY_RUN=0" || fail "7. git-prune dry=0 ($rc: $out)"
out="$(env -u GIT_PRUNE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" GIT_PRUNE_CRONTAB="$T/fake-crontab" GIT_PRUNE_CRON_LOG_DIR="$T/log" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_git_prune_merged_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/git-prune-merged-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "7. git-prune-merged warns on a linked worktree when DRY_RUN=1" || fail "7. git-prune dry=1 ($rc: $out)"
out="$(env -u COST_ROLLUP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" ENV=dev COST_ROLLUP_CRON_SCHEDULE="0 2 * * *" COST_ROLLUP_CRONTAB="$T/fake-crontab" COST_ROLLUP_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; source "$3"; do_spl_cost_rollup_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-cost-rollup-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "7. cost-rollup refuses a linked worktree when DRY_RUN=0" || fail "7. cost-rollup dry=0 ($rc: $out)"

# 8. cron_refuse_linked_worktree wave-2 delegation (r07-01 one copy)
for sib in \
  "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/prune-docker-images-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/tmp-scratch-sweep-install-cron.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-agent-id-reap-install-cron.func.sh"; do
  own="$(grep -nE 'is a linked worktree: install from the main checkout|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "8. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "8. one copy $(basename "$sib"): own=[$own]"
done

# standalone wave-2 installer linked-worktree checks (dry=0 refuses, dry=1 warns, remove skips)
out="$(env -u BOX_SWEEP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_box_disk_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. box-disk-sweep refuses a linked worktree when DRY_RUN=0" || fail "8. box-disk-sweep dry=0 ($rc: $out)"
out="$(env -u BOX_SWEEP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_box_disk_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the path below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "8. box-disk-sweep warns on a linked worktree when DRY_RUN=1" || fail "8. box-disk-sweep dry=1 ($rc: $out)"
out="$(env -u BOX_SWEEP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_SWEEP_CRONTAB="$T/fake-crontab" BOX_SWEEP_CRON_LOG_DIR="$T/log" BOX_SWEEP_CRON_ACTION=remove DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_box_disk_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/box-disk-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'linked worktree' <<<"$out" \
  && pass "8. box-disk-sweep remove skips worktree refusal" || fail "8. box-disk-sweep remove ($rc: $out)"
out="$(env -u PRUNE_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" PRUNE_CRONTAB="$T/fake-crontab" PRUNE_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_prune_docker_images_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/prune-docker-images-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. prune-docker-images refuses a linked worktree when DRY_RUN=0" || fail "8. prune-docker-images dry=0 ($rc: $out)"
out="$(env -u SCRATCH_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_AGENT_USER="$(id -un)" SCRATCH_CRONTAB="$T/fake-crontab" SCRATCH_CRON_LOG_DIR="$T/log" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_tmp_scratch_sweep_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/tmp-scratch-sweep-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. tmp-scratch-sweep refuses a linked worktree when DRY_RUN=0" || fail "8. tmp-scratch-sweep dry=0 ($rc: $out)"
out="$(env -u REAP_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/spool" REAP_CRONTAB="$T/fake-crontab" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; source "$2"; do_spl_agent_id_reap_install_cron' _ \
  "$PROJ_ROOT/lib/bash/funcs/cron-tagged-line.func.sh" "$PROJ_ROOT/src/bash/run/spl-agent-id-reap-install-cron.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "8. spl-agent-id-reap refuses a linked worktree when DRY_RUN=0" || fail "8. spl-agent-id-reap dry=0 ($rc: $out)"

# 9. cron_refuse_linked_worktree optional wording and plural callers (r08-01 one copy)
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 0 "run the install" "the paths below")"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: run the install from the main checkout - nothing changed" ] \
  && pass "9. cron_refuse_linked_worktree honours custom fatal_verb when dry=0" || fail "9. custom dry=0 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 1 0 "run the install" "the paths below")"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" ] \
  && pass "9. cron_refuse_linked_worktree honours custom warn_noun when dry=1" || fail "9. custom dry=1 ($rc: $out)"
out="$(wt_check "$T/wt-linked/csi-spl-orc" 0 1 "run the install" "the paths below")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "9. cron_refuse_linked_worktree custom wording still skips when allow=1" || fail "9. custom allow=1 ($rc: $out)"

for sib in \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh"; do
  own="$(grep -nE 'is a linked worktree:|--git-common-dir' "$sib" || true)"
  [ -z "$own" ] && grep -q 'cron_refuse_linked_worktree ' "$sib" \
    && pass "9. one copy: $(basename "$sib") delegates worktree check to cron_refuse_linked_worktree" \
    || fail "9. one copy $(basename "$sib"): own=[$own]"
done

# standalone plural-caller linked-worktree checks (lazy-loads cron-tagged-line.func.sh)
printf 'demo | * * * * * | demo.sh | demo.log |\n' >"$T/wt-linked/demo.manifest"
touch "$T/wt-linked/csi-spl-orc/demo.sh"
out="$(env -u BOX_CRONS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_CRONS_MANIFEST="$T/wt-linked/demo.manifest" BOX_CRONS_STATE_DIR="$T/state" BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_DESK_USER="$(id -un)" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_install_box_crons' _ \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. install-box-crons refuses a linked worktree when DRY_RUN=0" || fail "9. box-crons dry=0 ($rc: $out)"
out="$(env -u BOX_CRONS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_CRONS_MANIFEST="$T/wt-linked/demo.manifest" BOX_CRONS_STATE_DIR="$T/state" BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_DESK_USER="$(id -un)" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_install_box_crons' _ \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. install-box-crons warns with plural wording when DRY_RUN=1" || fail "9. box-crons dry=1 ($rc: $out)"
out="$(env -u BOX_CRONS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" BOX_CRONS_MANIFEST="$T/wt-linked/demo.manifest" BOX_CRONS_STATE_DIR="$T/state" BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_DESK_USER="$(id -un)" BOX_CRONS_ACTION=remove DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_install_box_crons' _ \
  "$PROJ_ROOT/src/bash/run/install-box-crons.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'linked worktree' <<<"$out" \
  && pass "9. install-box-crons remove skips worktree refusal" || fail "9. box-crons remove ($rc: $out)"

mkdir -p "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/scripts"
touch "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent-hook.sh"
printf '{}\n' >"$T/hooks-set.json"
out="$(env -u HOOKS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" HOOKS_SETTINGS="$T/hooks-set.json" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; do_require_bin() { return 0; }; source "$1"; do_spl_agent_hooks_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: run the install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-agent-hooks-install refuses a linked worktree when DRY_RUN=0" || fail "9. hooks dry=0 ($rc: $out)"
out="$(env -u HOOKS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" HOOKS_SETTINGS="$T/hooks-set.json" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; do_require_bin() { return 0; }; source "$1"; do_spl_agent_hooks_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-hooks-install warns with plural wording when DRY_RUN=1" || fail "9. hooks dry=1 ($rc: $out)"
out="$(env -u HOOKS_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" HOOKS_SETTINGS="$T/hooks-set.json" HOOKS_UNINSTALL=1 DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; do_require_bin() { return 0; }; source "$1"; do_spl_agent_hooks_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-hooks-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-hooks-install uninstall warns instead of refusing when DRY_RUN=0" || fail "9. hooks uninstall ($rc: $out)"

mkdir -p "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/lib" "$T/wt-linked/csi-spl-orc/lib/bash/funcs" "$T/wt-id-spool/agents"
cp "$PROJ_ROOT/src/bash/features/spawn-agents/lib/agent-identity.inc.sh" "$T/wt-linked/csi-spl-orc/src/bash/features/spawn-agents/lib/"
cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-lock.func.sh" "$T/wt-linked/csi-spl-orc/lib/bash/funcs/"
out="$(env -u IDENTITY_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-id-spool" IDENTITY_CRONTAB="$T/fake-crontab" SPOOL_TMUX_SOCKET="$T/no.sock" DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_spl_agent_identity_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -qxF "FATAL $T/wt-linked/csi-spl-orc is a linked worktree: run the install from the main checkout - nothing changed" <<<"$out" \
  && pass "9. spl-agent-identity-install refuses a linked worktree when DRY_RUN=0" || fail "9. identity dry=0 ($rc: $out)"
out="$(env -u IDENTITY_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-id-spool" IDENTITY_CRONTAB="$T/fake-crontab" SPOOL_TMUX_SOCKET="$T/no.sock" DRY_RUN=1 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_spl_agent_identity_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-identity-install warns with plural wording when DRY_RUN=1" || fail "9. identity dry=1 ($rc: $out)"
out="$(env -u IDENTITY_ALLOW_WORKTREE PROJ_PATH="$T/wt-linked/csi-spl-orc" SPOOL_ROOT="$T/wt-id-spool" IDENTITY_CRONTAB="$T/fake-crontab" SPOOL_TMUX_SOCKET="$T/no.sock" IDENTITY_UNINSTALL=1 DRY_RUN=0 \
  bash -c 'set -uo pipefail; do_log() { echo "$*"; }; source "$1"; do_spl_agent_identity_install' _ \
  "$PROJ_ROOT/src/bash/run/spl-agent-identity-install.func.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qxF "WARN $T/wt-linked/csi-spl-orc is a linked worktree: the paths below would vanish with it; install from the main checkout" <<<"$out" \
  && pass "9. spl-agent-identity-install uninstall warns instead of refusing when DRY_RUN=0" || fail "9. identity uninstall ($rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
