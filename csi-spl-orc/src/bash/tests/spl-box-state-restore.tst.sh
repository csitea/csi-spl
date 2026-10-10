#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_state_restore (owner t1 d80ed72c), a box's state back
# from the 056 bucket onto a new box, on a fixture target root. gcloud is a
# stub that lists two objects and serves a fixture archive.
#   1. refusals before any work: ENV, DATE, BOX, DRY_RUN, a non-empty staging
#      dir, a target root that is not a dir
#   2. object pick: BOX + DATE list gs://<cnf bucket>/<box>/<date>/ as the
#      project SA and take the newest .tar.zst
#   3. the dry run stages, prints NEW / OVERWRITE, and changes no target file
#   4. DRY_RUN=0 writes the archive's files and deletes nothing else
#   5. the key scan: a planted archive refuses the restore (exit 3), target
#      untouched; the excludes of the backup hold on the way back too
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# A night's archive, packed by the backup action itself from a fixture box.
S="$T/box"
mkdir -p "$S/proj/-opt-x" "$S/spool/c-1/inbox"
echo 'transcript v2' >"$S/proj/-opt-x/s1.jsonl"
echo 'new msg' >"$S/spool/c-1/inbox/m2.json"
echo 'same' >"$S/spool/c-1/inbox/m1.json"
cat >"$T/cnf.yaml" <<'EOF'
env:
  steps:
    056-gcs-box-state:
      state_bucket_name: csi-spl-dev-box-state
      writer_sa_account_id: csi-spl-dev-box-state
EOF
STUBS='do_spl_cloud_cnf() { SPL_CNF="$CNF"; SPL_PROJECT=csi-spl-dev; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { return 0; }'
SNIPPET="$STUBS; do_spl_box_state_backup" in_orc CNF="$T/cnf.yaml" BOX=box1 BOX_STATE_SOURCES="$S/proj $S/spool" \
  BOX_STATE_KEEP="$T/night.tar.zst" >"$T/out" 2>&1 || { fail "setup: the backup could not pack: $(cat "$T/out")"; exit 1; }

# gcloud: ls prints two objects of the night (older first, out of order on
# purpose: the pick sorts), cp serves the fixture archive
mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<EOF
#!/bin/sh
echo "gcloud \$*" >>"\$STUB_LOG"
case "\$1 \$2" in
  "storage ls") printf '%s\n' "\$3box1-20261010T234100Z.tar.zst" "\$3box1-20261010T024100Z.tar.zst" "\$3" ;;
  "storage cp") cp "\${SERVE:-$T/night.tar.zst}" "\$4" ;;
esac
EOF
chmod +x "$T/stub/gcloud"

# The new box: one file the archive overwrites, one it holds unchanged, one it
# does not know (must survive), none of the m2 it adds.
R="$T/root"
mkdir -p "$R${S}/proj/-opt-x" "$R${S}/spool/c-1/inbox"
echo 'transcript v1' >"$R${S}/proj/-opt-x/s1.jsonl"
echo 'same' >"$R${S}/spool/c-1/inbox/m1.json"
echo 'local only' >"$R${S}/spool/c-1/inbox/local.json"
snap() { (cd "$R" && find . -type f -exec sha256sum {} + | sort); }
before="$(snap)"
run_rs() { : >"$T/calls.log"; SNIPPET="$STUBS; do_spl_box_state_restore" in_orc CNF="$T/cnf.yaml" BOX=box1 DATE=2026-10-10 \
  BOX_STATE_RESTORE_ROOT="$R" BOX_STATE_STAGING="$T/stg" "$@" >"$T/out" 2>&1; }

# 1 -------------------------------------------------------------------------
mkdir -p "$T/full"; echo x >"$T/full/x"
for kv in ENV=lde DATE= DATE=20261010 DATE=latest BOX='a/b' DRY_RUN=2 BOX_STATE_STAGING="$T/full" BOX_STATE_RESTORE_ROOT="$T/nope"; do
  rm -rf "$T/stg"; run_rs "$kv"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q FATAL "$T/out" && pass "1. $kv refused, no gcloud call" || fail "1. $kv: rc=$rc $(cat "$T/out")"
done
[[ "$(snap)" == "$before" ]] && pass "1. ...and the target is unchanged" || fail "1. target changed"

# 2 + 3 ---------------------------------------------------------------------
rm -rf "$T/stg"; run_rs; rc=$?
[[ $rc -eq 0 ]] && grep -q '^gcloud storage ls gs://csi-spl-dev-box-state/box1/2026-10-10/ --account=sa@example.com$' "$T/calls.log" \
  && grep -q '^gcloud storage cp gs://csi-spl-dev-box-state/box1/2026-10-10/box1-20261010T234100Z.tar.zst ' "$T/calls.log" \
  && pass "2. BOX + DATE list the night's prefix as the project SA and read the newest object" || fail "2. pick: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -q 'impersonate' "$T/calls.log" && fail "2. the restore impersonated the writer (it cannot read)" || pass "2. ...as the project SA, not the writer"
grep -q "would write 1 new and OVERWRITE 1 existing" "$T/out" && grep -qx "  OVERWRITE $R$S/proj/-opt-x/s1.jsonl" "$T/out" \
  && grep -qx "NEW $R$S/spool/c-1/inbox/m2.json" "$T/stg/plan.txt" && ! grep -q 'm1.json' "$T/stg/plan.txt" \
  && pass "3. the dry run prints NEW / OVERWRITE (content compared; an equal file is not listed)" || fail "3. plan: $(cat "$T/out" "$T/stg/plan.txt")"
[[ "$(cat "$T/stg/root$S/proj/-opt-x/s1.jsonl")" == 'transcript v2' ]] && pass "3. ...the archive is staged in the staging dir" || fail "3. staging"
[[ "$(snap)" == "$before" ]] && pass "3. ...and no target file changed" || fail "3. the dry run wrote the target"

# 4 -------------------------------------------------------------------------
rm -rf "$T/stg"; run_rs DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(cat "$R$S/proj/-opt-x/s1.jsonl")" == 'transcript v2' && "$(cat "$R$S/spool/c-1/inbox/m2.json")" == 'new msg' ]] \
  && pass "4. DRY_RUN=0 writes the archive's files" || fail "4. apply: rc=$rc $(cat "$T/out")"
[[ "$(cat "$R$S/spool/c-1/inbox/local.json" 2>/dev/null)" == 'local only' ]] && pass "4. ...and deletes nothing it does not hold" || fail "4. local.json gone"

# 5 -------------------------------------------------------------------------
before="$(snap)"
mkdir -p "$T/plant/a"
printf 'x\n-----BEGIN %s KEY-----\nMIIsecretbytes\n' "$(printf 'PRI%s' 'VATE')" >"$T/plant/a/notes.txt"
(cd "$T/plant" && tar -cf - a) | zstd -q -o "$T/plant.tar.zst"
rm -rf "$T/stg"; run_rs DRY_RUN=0 SERVE="$T/plant.tar.zst"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'restore REFUSED' "$T/out" && grep -q 'HIT a/notes.txt key' "$T/out" && [[ "$(snap)" == "$before" ]] \
  && pass "5. a planted archive refuses the restore (exit 3), the target unchanged" || fail "5. refusal: rc=$rc $(cat "$T/out")"
grep -q MIIsecretbytes "$T/out" && fail "5. the refusal printed key bytes" || pass "5. ...and the log holds no key bytes"
rm -rf "$T/stg"; run_rs BOX_STATE_ARCHIVE="$T/night.tar.zst"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q "from $T/night.tar.zst" "$T/out" \
  && pass "5. CONTROL: a local BOX_STATE_ARCHIVE restores with no gcloud call" || fail "5. local archive: rc=$rc $(cat "$T/out")"

echo "spl-box-state-restore: ${fails} failure(s)"
[ "$fails" -eq 0 ]
