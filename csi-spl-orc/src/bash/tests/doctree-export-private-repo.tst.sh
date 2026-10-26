#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3543 (owner HUM-10, csitea 8c223c17 msgs 9538871d, 2b3de92e):
#          a workspace cnf docs.private_repos maps to a PRIVATE repository has
#          its qto docs exported by do_spl_doctree_export_md into a clone of
#          THAT repository (QTO_PRIVATE_REPO_DIR, its own qto-docs.tsv), never
#          into this public one; do_spl_doctree_import_md refuses it (the hub
#          keeps the primary copy, owner polls 7aef27b6 / f76e38e4).
#   1. the real cnf maps csitea to csitea/csitea-ws-docs, and csitea is not
#      in docs.repo_export_tenants
#   2. export csitea into a clone of csitea/csitea-ws-docs: the page lands in
#      the clone, nothing in the public tree (3 hub reads)
#   3. a planted public target is refused, no hub call, nothing written: the
#      public tree itself, a dir inside it, a clone of csi-spl, a dir that is
#      not the top of a clone, no QTO_PRIVATE_REPO_DIR, a QTO_MAP override
#   4. import csitea is refused (DRY_RUN=0 and the dry run), no hub call
#   5. a cnf naming csitea in both lists is refused (fail closed)
#   6. QTO_MAP_SEED=1 adds a docs/<id>.md row per listed doc the map lacks,
#      then exports them; in compare mode (QTO_CHECK=1) it is refused
#   7. t1 still exports into the public tree
#   8. CONTROL: with the target check stubbed back to the public tree, the
#      csitea export writes the page INTO the public repository (the leak)
#   Every fixture is synthetic, under $T; the desk is a fake.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
RUN="${DOCTREE_RUN_DIR:-$PROJ_ROOT/src/bash/run}"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
GUARD="$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-tree-guard.func.sh"
D1=11111111-1111-4111-8111-111111111111 D2=22222222-2222-4222-8222-222222222222
R="$T/pub" P="$T/priv" REL=docs/page.md
PUBMAP="$R/csi-spl-doc/doc/md/qto-docs.tsv"
mkgit() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" remote add origin "$2"; }
mkgit "$R" git@github.com:csitea/csi-spl.git
mkgit "$P" git@github.com:csitea/csitea-ws-docs.git
mkgit "$T/other" https://github.com/csitea/csi-spl.git
mkdir -p "$R/csi-spl-doc/doc/md" "$R/sub" "$P/notop"

fresh() {
  printf '%s\t%s\n' "$D1" "$REL" >"$P/qto-docs.tsv"
  printf '%s\tcsi-spl-doc/doc/md/page.md\n' "$D1" >"$PUBMAP"
  rm -rf "$P/docs" "$R/docs" "$R/csi-spl-doc/doc/md/page.md" "$R/sub/docs" "$T/other/docs"
  : >"$T/calls"
}

# act <snippet> [VAR=val...]: the export + import actions sourced in a clean
# shell, the desk a fake that logs each call to $T/calls. Output in $T/out,
# rc in $rc.
act() {
  local snip="$1"; shift
  rc=0
  env -u QTO_CHECK -u QTO_DOC -u QTO_MAP -u DRY_RUN -u TENANT_ID -u QTO_TENANT_CNF -u QTO_PRIVATE_REPO_DIR -u QTO_MAP_SEED \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" CALLS="$T/calls" GUARD="$GUARD" RUN="$RUN" SNIP="$snip" D1="$D1" D2="$D2" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    source "$GUARD"
    for f in spl-doctree-export-md spl-doctree-import-md; do source "$RUN/$f.func.sh"; done
    do_spl_desk_doctree() {
      echo "$DOCTREE_ARGS" >>"$CALLS"
      case "$DOCTREE_ARGS" in
        list*) echo "{\"docs\":[{\"id\":\"$D1\",\"title\":\"A\"},{\"id\":\"$D2\",\"title\":\"B\"}]}" ;;
        head*) echo "{\"root\":\"r1\",\"title\":\"Private fixture\"}" ;;
        read*) echo "{\"items\":[{\"id\":\"r1\",\"body\":\"Synthetic text.\"}]}" ;;
        export*) printf "# Private fixture\n\nSynthetic text.\n" ;;
        *) echo "{\"id\":\"doc-2\",\"root\":\"r2\"}" ;;
      esac
    }
    eval "$SNIP"' >"$T/out" 2>&1 </dev/null || rc=$?
}

# nothing_public: no page under the public tree (or the planted targets)
nothing_public() {
  [[ -z "$(find "$R" "$T/other" -name '*.md' -newer "$T/calls" 2>/dev/null)" ]] && cmp -s "$T/pubmap.before" "$PUBMAP"
}

# refused <case> <FATAL pattern>: rc != 0, the FATAL, no hub call, nothing written
refused() {
  if (( rc != 0 )) && grep -q -- "$2" "$T/out" && [[ ! -s "$T/calls" && ! -e "$P/$REL" ]] && nothing_public; then
    pass "$1: refused (rc $rc), no hub call, nothing written"
  else fail "$1: rc $rc, calls $(wc -l <"$T/calls"), $(tail -2 "$T/out")"; fi
}

fresh; cp "$PUBMAP" "$T/pubmap.before"

# 1. the real cnf
got="$(yq -r '.env.docs.private_repos.csitea' "$CNF" 2>/dev/null)"
inpub="$(yq -r '.env.docs.repo_export_tenants[]' "$CNF" 2>/dev/null | grep -cx csitea)"
[[ "$got" == csitea/csitea-ws-docs && "$inpub" == 0 ]] &&
  pass "1: cnf docs.private_repos.csitea = csitea/csitea-ws-docs, csitea not in repo_export_tenants" ||
  fail "1: cnf private_repos.csitea '$got', in repo_export_tenants $inpub"

# 2. export into the private clone
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P"
(( rc == 0 )) && grep -q "^Synthetic text.$" "$P/$REL" 2>/dev/null && nothing_public &&
  [[ "$(grep -c "^\(head\|read\|export\) $D1" "$T/calls")" == 3 ]] &&
  pass "2: csitea exported into the private clone ($REL), nothing in the public tree" ||
  fail "2: rc $rc, $(tail -3 "$T/out")"

# 3. planted public targets
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$R"
refused "3: QTO_PRIVATE_REPO_DIR = the public tree" "it is or holds this public repository"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$R/sub"
refused "3: QTO_PRIVATE_REPO_DIR inside the public tree" "it is or holds this public repository"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$T/other"
refused "3: a clone of csi-spl elsewhere" "not the top of a clone of csitea/csitea-ws-docs"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P/notop"
refused "3: a dir that is not the top of the clone" "not the top of a clone of csitea/csitea-ws-docs"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea
refused "3: no QTO_PRIVATE_REPO_DIR" "needs QTO_PRIVATE_REPO_DIR"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P" QTO_MAP="$PUBMAP"
refused "3: a QTO_MAP override" "QTO_MAP is not used for workspace 'csitea'"

# 4. import refused
printf '# Imp\n\nPre.\n\n## 1. One\n\nBody.\n' >"$R/imp.md"
for dr in 0 1; do
  fresh
  act do_spl_doctree_import_md TENANT_ID=csitea MD_PATH=imp.md DRY_RUN=$dr QTO_PRIVATE_REPO_DIR="$P"
  refused "4: import DRY_RUN=$dr TENANT_ID=csitea" "do_spl_doctree_import_md refuses workspace 'csitea': its docs are exported to its private repository"
done

# 5. both lists
printf 'env:\n  docs:\n    repo_export_tenants: [system, csitea]\n    private_repos: {csitea: csitea/csitea-ws-docs}\n' >"$T/both.yaml"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P" QTO_TENANT_CNF="$T/both.yaml"
refused "5: csitea in both lists" "is in both cnf docs.private_repos and docs.repo_export_tenants"

# 6. seed the private map from doctree list
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P" QTO_MAP_SEED=1
(( rc == 0 )) && grep -qxF "$(printf '%s\tdocs/%s.md' "$D2" "$D2")" "$P/qto-docs.tsv" &&
  [[ "$(grep -c "^$D1" "$P/qto-docs.tsv")" == 1 && -s "$P/$REL" && -s "$P/docs/$D2.md" ]] && nothing_public &&
  grep -q "OK map seeded: 1 row(s) added for 2 doc(s)" "$T/out" &&
  pass "6: QTO_MAP_SEED=1 added docs/<id>.md for the unmapped doc and exported both, privately" ||
  fail "6: seed: rc $rc, $(tail -3 "$T/out")"
fresh
act do_spl_doctree_export_md TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P" QTO_MAP_SEED=1 QTO_CHECK=1
refused "6: QTO_MAP_SEED=1 in compare mode" "QTO_MAP_SEED=1 is for the export of a workspace with a private repository"

# 7. t1 still exports into the public tree
fresh
act do_spl_doctree_export_md TENANT_ID=t1
(( rc == 0 )) && grep -q "^Synthetic text.$" "$R/csi-spl-doc/doc/md/page.md" 2>/dev/null && [[ ! -e "$P/$REL" ]] &&
  pass "7: t1 still exports into the public tree" || fail "7: t1: rc $rc, $(tail -2 "$T/out")"

# 8. CONTROL: no target check = the csitea doc lands in the public repository
fresh
act '_spl_doctree_target() { QTO_ROOT="$APP_PATH" QTO_PRIVATE_REPO=""; }; _spl_doctree_tenant_allowed() { return 0; }; do_spl_doctree_export_md' \
  TENANT_ID=csitea QTO_PRIVATE_REPO_DIR="$P"
(( rc == 0 )) && grep -q "^Synthetic text.$" "$R/csi-spl-doc/doc/md/page.md" 2>/dev/null &&
  pass "8: CONTROL: with the target check stubbed out, csitea's doc is written into the public repository (the leak SPL-3543 closes)" ||
  fail "8: CONTROL: the unchecked export did not write the public page: rc $rc, $(tail -2 "$T/out")"

echo
(( fails == 0 )) && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
