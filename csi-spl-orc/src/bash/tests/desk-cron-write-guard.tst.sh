#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: bug round 1 row 04 (SPL-2491): an action that writes the repo tree
#          refuses a `*-desk-cron` checkout, the desk crons' self-updating
#          worktree, where a written file blocks the next tick's checkout
#          (desk-reconcile: 11 of 16 blockers carried `dirty:`). One shared
#          guard, spl_refuse_desk_cron_tree, called by every tree writer:
#          do_spl_doctree_export_md, do_spl_doctree_import_md,
#          do_spl_i18n_mask, do_spl_i18n_unmask.
#   1. the guard: PROJ_PATH, APP_PATH or a given path under a component
#      named *-desk-cron -> rc 1 + FATAL naming it; a symlink into one too;
#      an ordinary tree, and a name that only contains "desk-cron", pass
#   2. export, APP_PATH + PROJ_PATH a mock desk-cron checkout: non-zero,
#      the FATAL, no hub call and the md file not written.
#      CONTROL: the same run with the guard stubbed out writes the file
#      (what the action did before the fix); an ordinary tree is written
#   3. export QTO_CHECK=1 (compare only, writes nothing) still runs there
#   4. import DRY_RUN=0 from the mock checkout: refused before the hub
#      create, no map row
#   5. unmask into a desk-cron destination and mask from a desk-cron
#      PROJ_PATH: refused, nothing written
#   Every fixture is synthetic, under $T; nothing reads the live box.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
GUARD="$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-tree-guard.func.sh"
RUN="$PROJ_ROOT/src/bash/run"

# a mock checkout: <root>/csi-spl-orc (PROJ_PATH) and the qto map + its page
mock_tree() {
  local root="$1"
  mkdir -p "$root/csi-spl-orc/src/bash/run" "$root/csi-spl-doc/doc/md"
  cp "$RUN/spl-doctree-md.py" "$root/csi-spl-orc/src/bash/run/"
  printf 'doc-1\tcsi-spl-doc/doc/md/page.md\n' >"$root/csi-spl-doc/doc/md/qto-docs.tsv"
}
CRON="$T/csi-spl-desk-cron" OWN="$T/csi-spl-wt/c-000"
mock_tree "$CRON"; mock_tree "$OWN"

# act <root> <snippet> [VAR=val...]: the doctree + i18n actions and the guard
# sourced in a clean shell; the desk is a fake that logs each call to
# $T/calls and answers one doc. Output in $T/out, rc in $rc.
act() {
  local root="$1" snip="$2"; shift 2
  rc=0
  env -u QTO_CHECK -u QTO_DOC -u QTO_MAP -u DRY_RUN -u I18N_MASK_OUT -u I18N_UNMASK_DST \
    PROJ_PATH="$root/csi-spl-orc" APP_PATH="$root" TENANT_ID=t1 QTO_TENANT_CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" \
    CALLS="$T/calls" GUARD="$GUARD" RUN="$RUN" SNIP="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    source "$GUARD"
    for f in spl-doctree-export-md spl-doctree-import-md spl-i18n-mask spl-i18n-unmask; do source "$RUN/$f.func.sh"; done
    do_spl_desk_doctree() {
      echo "$DOCTREE_ARGS" >>"$CALLS"
      case "$DOCTREE_ARGS" in
        head*) echo "{\"root\":\"r1\",\"title\":\"Guard fixture\"}" ;;
        read*) echo "{\"items\":[{\"id\":\"r1\",\"body\":\"Synthetic text.\"}]}" ;;
        export*) printf "# Guard fixture\n\nSynthetic text.\n" ;;
        *) echo "{\"id\":\"doc-2\",\"root\":\"r2\"}" ;;
      esac
    }
    eval "$SNIP"' >"$T/out" 2>&1 </dev/null || rc=$?
}

# 1. the guard on its own
guard() {
  (
    do_log() { echo "$*"; }
    export PROJ_PATH="$1" APP_PATH="$2"
    shift 2
    # shellcheck source=../../../lib/bash/funcs/spl-desk-cron-tree-guard.func.sh
    source "$GUARD"
    spl_refuse_desk_cron_tree do_x "$@"
  ) >"$T/g" 2>&1
}
guard "$CRON/csi-spl-orc" "$CRON" && fail "1: PROJ_PATH in a desk-cron checkout passed" ||
  { grep -q "FATAL do_x .*refuses a desk-cron checkout: $CRON/csi-spl-orc" "$T/g" && pass "1: PROJ_PATH in a desk-cron checkout: rc 1, FATAL names it" || fail "1: no FATAL: $(cat "$T/g")"; }
guard "$OWN/csi-spl-orc" "$OWN" && pass "1: an ordinary worktree passes" || fail "1: an ordinary worktree refused: $(cat "$T/g")"
guard "$OWN/csi-spl-orc" "$OWN" "$CRON/csi-spl-wui/i18n/locales" && fail "1: a desk-cron destination passed" || pass "1: a destination in a desk-cron checkout is refused"
ln -s "$CRON" "$T/plain-link"
guard "$T/plain-link/csi-spl-orc" "$T/plain-link" && fail "1: a symlink into a desk-cron checkout passed" || pass "1: a symlink into a desk-cron checkout is refused (resolved)"
mkdir -p "$T/my-desk-cronx/a" "$T/desk-cron-notes"
guard "$T/my-desk-cronx/a" "$T/desk-cron-notes" && pass "1: '*-desk-cronx' and 'desk-cron-notes' are not desk-cron checkouts" || fail "1: a look-alike name was refused"

# 2. export into the mock desk-cron checkout
: >"$T/calls"
act "$CRON" do_spl_doctree_export_md
if (( rc != 0 )) && grep -q "FATAL do_spl_doctree_export_md .*refuses a desk-cron checkout" "$T/out" &&
  [[ ! -e "$CRON/csi-spl-doc/doc/md/page.md" && ! -s "$T/calls" ]]; then
  pass "2: export refuses the desk-cron checkout: rc $rc, FATAL, no hub call, page.md not written"
else fail "2: export into the desk-cron checkout: rc $rc, calls $(wc -l <"$T/calls"), $(tail -2 "$T/out")"; fi
act "$CRON" 'spl_refuse_desk_cron_tree() { return 0; }; do_spl_doctree_export_md'
if (( rc == 0 )) && grep -q "^Synthetic text.$" "$CRON/csi-spl-doc/doc/md/page.md" 2>/dev/null; then
  pass "2: CONTROL: without the guard the export writes page.md into the desk-cron checkout (the bug)"
else fail "2: CONTROL: the unguarded export did not write the page: rc $rc, $(tail -2 "$T/out")"; fi
rm -f "$CRON/csi-spl-doc/doc/md/page.md"
act "$OWN" do_spl_doctree_export_md
(( rc == 0 )) && grep -q "^Synthetic text.$" "$OWN/csi-spl-doc/doc/md/page.md" &&
  pass "2: an ordinary worktree is still exported" || fail "2: ordinary export: rc $rc, $(tail -2 "$T/out")"

# 3. compare mode writes nothing, so the drift check still runs there
act "$CRON" do_spl_doctree_export_md QTO_CHECK=1
grep -q "refuses a desk-cron checkout" "$T/out" && fail "3: QTO_CHECK=1 was refused" ||
  { [[ ! -e "$CRON/csi-spl-doc/doc/md/page.md" ]] && pass "3: QTO_CHECK=1 compares in the desk-cron checkout and writes nothing (rc $rc: page missing = drift)" ||
    fail "3: QTO_CHECK=1 wrote the page"; }

# 4. import from the mock checkout, writes on
printf '# Imp\n\nPre.\n\n## 1. One\n\nBody.\n' >"$CRON/csi-spl-doc/doc/md/imp.md"
cp "$CRON/csi-spl-doc/doc/md/qto-docs.tsv" "$T/map.before"
: >"$T/calls"
act "$CRON" do_spl_doctree_import_md MD_PATH=csi-spl-doc/doc/md/imp.md DRY_RUN=0
if (( rc != 0 )) && grep -q "FATAL do_spl_doctree_import_md .*refuses a desk-cron checkout" "$T/out" &&
  [[ ! -s "$T/calls" ]] && cmp -s "$T/map.before" "$CRON/csi-spl-doc/doc/md/qto-docs.tsv"; then
  pass "4: import DRY_RUN=0 refuses before the hub create; map untouched"
else fail "4: import: rc $rc, calls $(cat "$T/calls"), $(tail -2 "$T/out")"; fi

# 5. i18n: a reviewed copy into the desk-cron locales, and a mask run there
M="$T/mask" && mkdir -p "$M/agy" && echo '{"a":"[EMAIL_1]"}' >"$M/agy/en.json" &&
  printf '[EMAIL_1]\tx@example.org\n' >"$M/map.tsv"
act "$OWN" do_spl_i18n_unmask I18N_MASK_OUT="$M" I18N_UNMASK_DST="$CRON/csi-spl-wui/i18n/locales"
(( rc != 0 )) && grep -q "FATAL do_spl_i18n_unmask .*refuses a desk-cron checkout: $CRON/csi-spl-wui/i18n/locales" "$T/out" &&
  [[ ! -e "$CRON/csi-spl-wui" ]] && pass "5: unmask into desk-cron locales refused, nothing written" ||
  fail "5: unmask: rc $rc, $(tail -2 "$T/out")"
mkdir -p "$T/src" && echo '{"a":"b"}' >"$T/src/en.json" && : >"$T/terms"
act "$CRON" do_spl_i18n_mask I18N_MASK_SRC="$T/src" I18N_MASK_TERMS="$T/terms" I18N_MASK_OUT="$T/mask2"
(( rc != 0 )) && grep -q "FATAL do_spl_i18n_mask .*refuses a desk-cron checkout" "$T/out" && [[ ! -e "$T/mask2" ]] &&
  pass "5: mask run from a desk-cron checkout refused, no output dir" || fail "5: mask: rc $rc, $(tail -2 "$T/out")"

echo
(( fails == 0 )) && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
