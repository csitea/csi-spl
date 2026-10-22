#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 114 section 9.4.2, tasks R5 (SPL-2950): a workspace's qto docs
#          reach md files of the PUBLIC repository only when cnf
#          docs.repo_export_tenants lists it. do_spl_doctree_export_md and
#          do_spl_doctree_import_md refuse any other TENANT_ID before any hub
#          call and write nothing.
#   1. the real cnf lists exactly system and t1
#   2. export, a map row, TENANT_ID off the list: rc != 0, the FATAL names
#      the workspace, no hub call, the md file not written; QTO_CHECK=1 too
#   3. import, TENANT_ID off the list, DRY_RUN=0 and the dry run: refused,
#      no hub call, the map unchanged
#   4. an empty TENANT_ID, and a cnf with no list, are refused (fail closed)
#   5. t1 and system still export (the page written, one head/read/export)
#   6. CONTROL: the same off-list export with the list check stubbed out
#      writes the page (what the action did before R5)
#   Every fixture is synthetic, under $T; the desk is a fake.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
RUN="$PROJ_ROOT/src/bash/run"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
GUARD="$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-tree-guard.func.sh"
R="$T/repo" PAGE="$T/repo/csi-spl-doc/doc/md/page.md" MAP="$T/repo/csi-spl-doc/doc/md/qto-docs.tsv"
mkdir -p "$R/csi-spl-doc/doc/md"

fresh() { printf 'doc-1\tcsi-spl-doc/doc/md/page.md\n' >"$MAP"; rm -f "$PAGE"; : >"$T/calls"; }

# act <snippet> [VAR=val...]: the export + import actions sourced in a clean
# shell, the desk a fake that logs each call to $T/calls and answers one doc.
# Output in $T/out, rc in $rc.
act() {
  local snip="$1"; shift
  rc=0
  env -u QTO_CHECK -u QTO_DOC -u QTO_MAP -u DRY_RUN -u TENANT_ID -u QTO_TENANT_CNF \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" CALLS="$T/calls" GUARD="$GUARD" RUN="$RUN" SNIP="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    source "$GUARD"
    for f in spl-doctree-export-md spl-doctree-import-md; do source "$RUN/$f.func.sh"; done
    do_spl_desk_doctree() {
      echo "$DOCTREE_ARGS" >>"$CALLS"
      case "$DOCTREE_ARGS" in
        head*) echo "{\"root\":\"r1\",\"title\":\"Allow fixture\"}" ;;
        read*) echo "{\"items\":[{\"id\":\"r1\",\"body\":\"Synthetic text.\"}]}" ;;
        export*) printf "# Allow fixture\n\nSynthetic text.\n" ;;
        *) echo "{\"id\":\"doc-2\",\"root\":\"r2\"}" ;;
      esac
    }
    eval "$SNIP"' >"$T/out" 2>&1 </dev/null || rc=$?
}

# refused <case> <tenant shown>: rc != 0, the FATAL, no hub call, nothing written
refused() {
  if (( rc != 0 )) && grep -q "FATAL do_spl_doctree_[a-z_]* refuses workspace '$2': not in cnf docs.repo_export_tenants" "$T/out" &&
    [[ ! -s "$T/calls" && ! -e "$PAGE" ]] && cmp -s "$T/map.before" "$MAP"; then
    pass "$1: refused (rc $rc), no hub call, nothing written"
  else fail "$1: rc $rc, calls $(wc -l <"$T/calls"), page $([[ -e "$PAGE" ]] && echo written || echo absent), $(tail -2 "$T/out")"; fi
}

# 1. the real list
list="$(yq -r '.env.docs.repo_export_tenants[]' "$CNF" 2>/dev/null | tr '\n' ' ')"
[[ "$list" == "system t1 " ]] && pass "1: cnf docs.repo_export_tenants = [system, t1]" || fail "1: cnf list is '$list'"

# 2. export off the list
fresh; cp "$MAP" "$T/map.before"
act do_spl_doctree_export_md TENANT_ID=ws-off
refused "2: export TENANT_ID=ws-off" ws-off
fresh
act do_spl_doctree_export_md TENANT_ID=ws-off QTO_CHECK=1
refused "2: export QTO_CHECK=1 TENANT_ID=ws-off" ws-off

# 3. import off the list
printf '# Imp\n\nPre.\n\n## 1. One\n\nBody.\n' >"$R/csi-spl-doc/doc/md/imp.md"
for dr in 0 1; do
  fresh
  act do_spl_doctree_import_md TENANT_ID=ws-off MD_PATH=csi-spl-doc/doc/md/imp.md DRY_RUN=$dr
  refused "3: import DRY_RUN=$dr TENANT_ID=ws-off" ws-off
done

# 4. fail closed
fresh
act do_spl_doctree_export_md TENANT_ID=
refused "4: export with an empty TENANT_ID" ""
printf 'env:\n  docs:\n    repo_edit: {}\n' >"$T/nolist.yaml"
fresh
act do_spl_doctree_export_md TENANT_ID=t1 QTO_TENANT_CNF="$T/nolist.yaml"
refused "4: export of t1 with a cnf that has no list" t1
fresh
act do_spl_doctree_export_md TENANT_ID=t1 QTO_TENANT_CNF="$T/missing.yaml"
(( rc != 0 )) && grep -q "FATAL do_spl_doctree_export_md: cnf docs.repo_export_tenants is not readable" "$T/out" &&
  [[ ! -s "$T/calls" && ! -e "$PAGE" ]] && pass "4: an unreadable cnf is refused, nothing written" ||
  fail "4: unreadable cnf: rc $rc, $(tail -2 "$T/out")"

# 5. the listed workspaces still export
for ten in t1 system; do
  fresh
  act do_spl_doctree_export_md TENANT_ID=$ten
  (( rc == 0 )) && grep -q "^Synthetic text.$" "$PAGE" && [[ "$(grep -c '^\(head\|read\|export\) doc-1' "$T/calls")" == 3 ]] &&
    pass "5: TENANT_ID=$ten exports (page written, 3 hub reads)" || fail "5: TENANT_ID=$ten: rc $rc, $(tail -2 "$T/out")"
done

# 6. CONTROL: without the list check the off-list workspace is written
fresh
act '_spl_doctree_tenant_allowed() { return 0; }; do_spl_doctree_export_md' TENANT_ID=ws-off
(( rc == 0 )) && grep -q "^Synthetic text.$" "$PAGE" 2>/dev/null &&
  pass "6: CONTROL: with the check stubbed out ws-off is exported into the repo (the leak R5 closes)" ||
  fail "6: CONTROL: the unchecked export did not write the page: rc $rc, $(tail -2 "$T/out")"

echo
(( fails == 0 )) && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
