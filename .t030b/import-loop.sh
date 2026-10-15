#!/bin/bash
# loop over the named action; resumable: a page already in the map is skipped
set -u
W=/opt/csi/csi-spl-wt/c-129; map=$W/csi-spl-doc/doc/md/qto-docs.tsv
while read -r f; do
  [[ -n "$f" ]] || continue
  if cut -f2 "$map" | grep -qxF -- "$f"; then echo "SKIP $f (mapped)"; continue; fi
  ( cd "$W/csi-spl-orc" && sudo -u ysg env ENV=prd TENANT_ID=t1 DESK_AGENT=c-001 MD_PATH="$f" QTO_FS=repo DRY_RUN=0 ./run -a do_spl_doctree_import_md 2>&1 | grep -E '^(INFO|OK|FATAL)' ) || echo "FAIL $f"
done
