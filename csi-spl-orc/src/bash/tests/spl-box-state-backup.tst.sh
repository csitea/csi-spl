#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_state_backup (owner t1 d80ed72c), the nightly box state
# copy to the 056 bucket, on a fixture box tree. No cloud call is real: gcloud
# is a stub that logs, the account pin is stubbed.
#   1. refusals before any work: ENV, DRY_RUN, BOX, BOX_STATE_STAMP
#   2. the excludes: .gcp, .ssh, key files, tokens, .env, .nano-banana, the
#      tenants store and every file holding key material stay out; a file that
#      only MENTIONS "private_key" goes in (no false drop)
#   3. the dry run uploads nothing and changes no source file
#   4. object naming: <box>/<YYYY-MM-DD>/<box>-<stamp>.tar.zst in the cnf
#      bucket, uploaded as the project SA impersonating the writer SA
#   5. the key scan: a planted archive (key material, or an excluded name)
#      refuses the upload with exit 3, names the member, never prints the key
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
PACK="$PROJ_ROOT/src/bash/scripts/box-state-pack.sh"

# The fixture box. Key material is ASSEMBLED at run time, so no literal key
# shape sits in this file (the repo's own secret scanners read it).
pem_head="-----BEGIN $(printf 'PRI%s' 'VATE') KEY-----"
S="$T/box"
mkdir -p "$S/proj/-opt-x/memory" "$S/proj/.gcp/.csi" "$S/proj/.ssh" "$S/proj/.github" "$S/proj/.vibe" \
  "$S/proj/.nano-banana" "$S/proj/.spool-hub/tenants" "$S/spool/c-1/inbox" "$S/state/logs" "$S/state/graft"
echo '{"type":"user","text":"we talk about the private_key field, no value"}' >"$S/proj/-opt-x/s1.jsonl"
echo 'memory note' >"$S/proj/-opt-x/memory/MEMORY.md"
echo '{"v":1,"body":"hello"}' >"$S/spool/c-1/inbox/m1.json"
echo 'a log line' >"$S/state/logs/run.log"
echo 'graft index' >"$S/state/graft/index.db"
printf '{"type":"service_account","private_key":"%s\\nMIIabc\\n"}\n' "$pem_head" >"$S/proj/.gcp/.csi/key-x-dev.json"
echo 'ssh' >"$S/proj/.ssh/id_ed25519"
echo 'tok' >"$S/proj/.github/token"
echo 'A=1' >"$S/proj/.vibe/.env"
echo 'B=2' >"$S/proj/.env"
echo 'k' >"$S/proj/.nano-banana/key"
echo '{"slug":"t9"}' >"$S/proj/.spool-hub/tenants/t9.json"
printf '{"root_private_key":"%s"}\n' "$(head -c 64 /dev/zero | base64 -w0 | tr 'A' 'Q')" >"$S/proj/-opt-x/leaked-tenant.json"
printf 'token=%s%s\n' 'ghp_' "$(printf 'a%.0s' $(seq 1 36))" >"$S/proj/-opt-x/leaked-token.txt"
printf '%s\nMIIabc\n' "$pem_head" >"$S/proj/-opt-x/server.pem"
printf 'log of a key\n%s\nMIIabc\n' "$pem_head" >"$S/state/logs/leak.log"
SRC="$S/proj $S/spool $S/state"
before="$(cd "$S" && find . -type f -exec sha256sum {} + | sort)"

cat >"$T/cnf.yaml" <<'EOF'
env:
  steps:
    056-gcs-box-state:
      state_bucket_name: csi-spl-dev-box-state
      writer_sa_account_id: csi-spl-dev-box-state
EOF
orc_stub 0 gcloud
STUBS='do_spl_cloud_cnf() { SPL_CNF="$CNF"; SPL_PROJECT=csi-spl-dev; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { return 0; }'
mkdir -p "$T/tmp"
run_bk() { : >"$T/calls.log"; SNIPPET="$STUBS; ${PRE:-} do_spl_box_state_backup" in_orc CNF="$T/cnf.yaml" TMPDIR="$T/tmp" \
  BOX=box1 BOX_STATE_SOURCES="$SRC" BOX_STATE_SKIP="$S/state/graft" "$@" >"$T/out" 2>&1; }

# 1 -------------------------------------------------------------------------
for kv in ENV=lde ENV= DRY_RUN=yes BOX='a/b' BOX='-x' BOX_STATE_STAMP=2026-10-10; do
  run_bk "$kv"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q FATAL "$T/out" && pass "1. $kv refused, no gcloud call" || fail "1. $kv: rc=$rc $(cat "$T/out")"
done

# 2 + 3 ---------------------------------------------------------------------
run_bk BOX_STATE_KEEP="$T/a.tar.zst" BOX_STATE_STAMP=20261010T024100Z; rc=$?
[[ $rc -eq 0 && -s "$T/a.tar.zst" ]] && pass "2. the dry run packs and scans clean" || fail "2. rc=$rc $(cat "$T/out")"
names="$(zstd -dcq "$T/a.tar.zst" | tar -tf -)"
for keep in proj/-opt-x/s1.jsonl proj/-opt-x/memory/MEMORY.md spool/c-1/inbox/m1.json state/logs/run.log; do
  grep -q "${S#/}/$keep\$" <<<"$names" && pass "2. kept: $keep" || fail "2. missing $keep: $names"
done
for out in .gcp/ .ssh/ .github/token .vibe/.env proj/.env .nano-banana .spool-hub/tenants leaked-tenant.json leaked-token.txt server.pem leak.log graft/; do
  grep -qF "$out" <<<"$names" && fail "2. an excluded file went in: $out" || pass "2. left out: $out"
done
[[ "$(grep -cE 'private_key|\.ssh/|\.gcp/' <<<"$names")" == 0 ]] && pass "2. tar -t | grep -cE 'private_key|.ssh/|.gcp/' -> 0" || fail "2. the brief's name check: $names"
re="$(bash "$PACK" key-re)"
[[ "$(zstd -dcq "$T/a.tar.zst" | grep -caE -e "$re")" == 0 ]] && pass "2. no key material in the archive bytes" || fail "2. key material in the archive"
grep -q "packed $S/proj as .*dropped: key=2 path=8\$" "$T/out" && grep -q "packed $S/state as .*dropped: key=1\$" "$T/out" \
  && pass "2. the log counts the drops per source (proj: 2 key, 8 path; state: 1 key)" || fail "2. drop counts: $(cat "$T/out")"
[[ ! -s "$T/calls.log" ]] && pass "3. the dry run made no gcloud call" || fail "3. dry run called: $(cat "$T/calls.log")"
[[ "$(cd "$S" && find . -type f -exec sha256sum {} + | sort)" == "$before" ]] && pass "3. ...and changed no source file" || fail "3. a source file changed"
[[ -z "$(ls -A "$T/tmp")" ]] && pass "3. ...and left no work dir behind" || fail "3. left in TMPDIR: $(ls -A "$T/tmp")"

# 4 -------------------------------------------------------------------------
want='box1/2026-10-10/box1-20261010T024100Z.tar.zst'
grep -q "would upload gs://csi-spl-dev-box-state/$want as csi-spl-dev-box-state@csi-spl-dev.iam.gserviceaccount.com" "$T/out" \
  && pass "4. the dry run names gs://<cnf bucket>/$want and the writer SA" || fail "4. dry-run name: $(cat "$T/out")"
run_bk DRY_RUN=0 BOX=BOX1 BOX_STATE_STAMP=20261010T024100Z; rc=$?
[[ $rc -eq 0 ]] && grep -qE "^gcloud storage cp $T/tmp/[^ ]+/box1-20261010T024100Z.tar.zst gs://csi-spl-dev-box-state/$want --account=sa@example.com --impersonate-service-account=csi-spl-dev-box-state@csi-spl-dev.iam.gserviceaccount.com" "$T/calls.log" \
  && pass "4. DRY_RUN=0: one cp to the object, as the project SA impersonating the writer (BOX lower-cased)" || fail "4. upload: rc=$rc $(cat "$T/calls.log" "$T/out")"
[[ "$(wc -l <"$T/calls.log")" == 1 ]] && pass "4. ...and no other gcloud call (no ls, no read: the writer cannot)" || fail "4. calls: $(cat "$T/calls.log")"
SNIPPET='spl_box_state_object box9 20260102T030405Z' in_orc >"$T/o2"
[[ "$(cat "$T/o2")" == 'box9/2026-01-02/box9-20260102T030405Z.tar.zst' ]] && pass "4. spl_box_state_object" || fail "4. object: $(cat "$T/o2")"

# 5 -------------------------------------------------------------------------
mkdir -p "$T/plant/a" "$T/plant2/.ssh"
printf 'x\n%s\nMIIsecretbytes\n' "$pem_head" >"$T/plant/a/notes.txt"
echo 'fine' >"$T/plant/a/ok.txt"
(cd "$T/plant" && tar -cf - a) | zstd -q -o "$T/plant.tar.zst"
out="$(bash "$PACK" scan "$T/plant.tar.zst")"; rc=$?
[[ $rc -eq 3 ]] && grep -qx 'HIT a/notes.txt key' <<<"$out" && ! grep -q 'ok.txt' <<<"$out" \
  && pass "5. scan: key material is a HIT naming only that member" || fail "5. scan key: rc=$rc $out"
grep -q MIIsecretbytes <<<"$out" && fail "5. the scan printed key bytes" || pass "5. ...and never prints the bytes"
echo 'id' >"$T/plant2/.ssh/id_x"
(cd "$T/plant2" && tar -cf - .ssh) | zstd -q -o "$T/plant2.tar.zst"
out="$(bash "$PACK" scan "$T/plant2.tar.zst")"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'HIT .ssh/id_x name' <<<"$out" && pass "5. scan: an excluded name is a HIT" || fail "5. scan name: rc=$rc $out"
out="$(bash "$PACK" scan "$T/a.tar.zst")"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "5. CONTROL: the clean archive scans clean" || fail "5. control: rc=$rc $out"
PRE='spl_box_state_pack() { cp "$PLANT" "$1"; };' run_bk DRY_RUN=0 PLANT="$T/plant.tar.zst"; rc=$?
[[ $rc -eq 3 && ! -s "$T/calls.log" ]] && grep -q 'upload REFUSED' "$T/out" && grep -q 'HIT a/notes.txt key' "$T/out" \
  && pass "5. a planted archive refuses the upload: exit 3, no gcloud call" || fail "5. refusal: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -q MIIsecretbytes "$T/out" && fail "5. the refusal printed key bytes" || pass "5. ...and the log holds no key bytes"
[[ -z "$(ls -A "$T/tmp")" ]] && pass "5. ...and the refused archive is removed" || fail "5. left: $(ls -A "$T/tmp")"

echo "spl-box-state-backup: ${fails} failure(s)"
[ "$fails" -eq 0 ]
