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
#      bucket, one create-only JSON API upload with the writer SA's token
#      (impersonated by the project SA); the reported size is the verdict
#   6. owner rule (csitea fc0119cd msg 072a9990, "keys and secrets stay on
#      the box"): a 0600 file under a home's dot-dirs and a NetVisor / bank
#      credential file stay out and refuse an upload in the scan, naming the
#      path only; the allow-listed 0600 transcripts go in
#   7. a satellite (c-001 cf51ea4d): homes come from getent passwd, not a
#      /home/* guess (a home under /mnt/data/home); an agent home this user
#      cannot read FAILS loudly (exit != 0, 'unreadable', no upload), while a
#      source that is really absent is skipped
#   5. the key scan: a planted archive (key material, or an excluded name)
#      refuses the upload with exit 3, names the member, never prints the key;
#      bytes after tar's end marker never make a good archive "unreadable"
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
printf '{"type":"service_account","%s":"%s\\nMIIabc\\n"}\n' "private_$(printf key)" "$pem_head" >"$S/proj/.gcp/.csi/key-x-dev.json"
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
# gcloud: logs; prints a token for print-access-token. curl: logs its args
# (the header is a FILE, so no token here), answers with the -T file's size
# (CURL_SIZE overrides it) in the -o file.
mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\ncase "$*" in *print-access-token*) echo tok-FAKE-0123 ;; esac\nexit 0\n' >"$T/stub/gcloud"
cat >"$T/stub/curl" <<'STUBEOF'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
while [ $# -gt 0 ]; do case "$1" in -T) f="$2"; shift ;; -o) o="$2"; shift ;; -H) [[ "$2" == @* ]] && h="${2#@}"; shift ;; esac; shift; done
[ -n "${h:-}" ] && grep -q '^Authorization: Bearer tok-FAKE-0123$' "$h" && [ "$(stat -c %a "$h")" = 600 ] && echo "curl-header-ok" >>"$STUB_LOG"
printf '{"size":"%s"}' "${CURL_SIZE:-$(stat -c %s "$f")}" >"$o"
STUBEOF
chmod +x "$T/stub/gcloud" "$T/stub/curl"
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
names="$(zstd -dcq "$T/a.tar.zst" | tar -tif -)"
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
enc="${want//\//%2F}"
[[ $rc -eq 0 ]] && grep -qx "gcloud auth print-access-token --account=sa@example.com --impersonate-service-account=csi-spl-dev-box-state@csi-spl-dev.iam.gserviceaccount.com" "$T/calls.log" \
  && grep -qE "^curl .* -T $T/tmp/[^ ]+/box1-20261010T024100Z.tar.zst .*https://storage.googleapis.com/upload/storage/v1/b/csi-spl-dev-box-state/o\?uploadType=media&ifGenerationMatch=0&name=$enc\$" "$T/calls.log" \
  && grep -q "OK dev: box1 state -> gs://csi-spl-dev-box-state/$want" "$T/out" \
  && pass "4. DRY_RUN=0: one create-only upload of the object, with the writer's impersonated token (BOX lower-cased)" || fail "4. upload: rc=$rc $(cat "$T/calls.log" "$T/out")"
[[ "$(wc -l <"$T/calls.log")" == 3 ]] && grep -qx curl-header-ok "$T/calls.log" \
  && pass "4. ...the token rides in a 0600 header file; no other call (no ls, no read: the writer cannot)" || fail "4. calls: $(cat "$T/calls.log")"
grep -q tok-FAKE "$T/out" "$T/calls.log" && fail "4. the token reached a log or a command line" || pass "4. ...and the token is in no log and on no command line"
run_bk DRY_RUN=0 BOX_STATE_STAMP=20261010T024100Z CURL_SIZE=7; rc=$?
[[ $rc -ne 0 ]] && grep -q "reports size '7', the archive is" "$T/out" && ! grep -q '^OK dev: box1 state' "$T/out" \
  && pass "4. CONTROL: a size GCS reports that differs from the archive is a FATAL" || fail "4. size mismatch: rc=$rc $(cat "$T/out")"
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
# wf 10 run 38064273382: the scan read a good archive as "not readable" when
# tar -t stopped at the end-of-archive marker before zstd had written the rest
# (tar -A leaves a record after it). These make that race certain: more than a
# pipe buffer (64 KiB) follows the marker, or the key hit.
mkdir -p "$T/plant3/a" "$T/plant3/b"
echo 'fine' >"$T/plant3/a/ok.txt"
(cd "$T/plant3" && tar -b 2048 -cf - a) | zstd -q -o "$T/plant3.tar.zst"
out="$(bash "$PACK" scan "$T/plant3.tar.zst" 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "5. a clean archive with 1 MiB after its end marker scans clean" || fail "5. end marker: rc=$rc $out"
cp "$T/plant/a/notes.txt" "$T/plant3/a/notes.txt"
head -c 2097152 /dev/zero >"$T/plant3/b/big.bin"
(cd "$T/plant3" && tar -cf - a/notes.txt b) | zstd -q -o "$T/plant4.tar.zst"
out="$(bash "$PACK" scan "$T/plant4.tar.zst" 2>&1)"; rc=$?
[[ $rc -eq 3 ]] && grep -qx 'HIT a/notes.txt key' <<<"$out" \
  && pass "5. key material before 2 MiB of other bytes is a HIT naming the member" || fail "5. early key: rc=$rc $out"
(cd "$T/plant3" && tar -cf - a/ok.txt) >"$T/stray.tar"
(cd "$T/plant2" && tar -cf - .ssh) >>"$T/stray.tar"
zstd -q -o "$T/stray.tar.zst" "$T/stray.tar"
out="$(bash "$PACK" scan "$T/stray.tar.zst" 2>&1)"; rc=$?
[[ $rc -eq 3 ]] && grep -q 'HIT .ssh/id_x name' <<<"$out" \
  && pass "5. a member after a stray end marker is still named" || fail "5. stray marker: rc=$rc $out"
PRE='spl_box_state_pack() { cp "$PLANT" "$1"; };' run_bk DRY_RUN=0 PLANT="$T/plant.tar.zst"; rc=$?
[[ $rc -eq 3 && ! -s "$T/calls.log" ]] && grep -q 'upload REFUSED' "$T/out" && grep -q 'HIT a/notes.txt key' "$T/out" \
  && pass "5. a planted archive refuses the upload: exit 3, no gcloud call" || fail "5. refusal: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -q MIIsecretbytes "$T/out" && fail "5. the refusal printed key bytes" || pass "5. ...and the log holds no key bytes"
[[ -z "$(ls -A "$T/tmp")" ]] && pass "5. ...and the refused archive is removed" || fail "5. left: $(ls -A "$T/tmp")"

# 6 -------------------------------------------------------------------------
H="$T/homes/u1"
mkdir -p "$H/.config/app" "$H/.claude/projects/-x" "$H/.local/share/fin" "$H/notes"
echo 'cfg' >"$H/.config/app/ok.conf"
echo 'SECRET-BYTES-0600' >"$H/.config/app/secret.conf"; chmod 600 "$H/.config/app/secret.conf"
echo 'creds' >"$H/.local/share/fin/session.dat"; chmod 600 "$H/.local/share/fin/session.dat"
echo 'transcript' >"$H/.claude/projects/-x/t1.jsonl"; chmod 600 "$H/.claude/projects/-x/t1.jsonl"
echo 'NV-BYTES' >"$H/notes/NetVisor-api.json"
echo 'BK-BYTES' >"$H/notes/bank_credentials.txt"
echo 'plain 0600 note' >"$H/notes/todo.txt"; chmod 600 "$H/notes/todo.txt"
HOMES="$T/homes/*"
run_bk BOX_STATE_SOURCES="$H" BOX_STATE_HOMES="$HOMES" BOX_STATE_KEEP="$T/h.tar.zst"; rc=$?
hn="$(zstd -dcq "$T/h.tar.zst" | tar -tif -)"
[[ $rc -eq 0 ]] && grep -q 'dropped: 0600=2 cred=2$' "$T/out" && pass "6. two 0600 dot-dir files and two credential files dropped" || fail "6. rc=$rc $(cat "$T/out")"
for out in .config/app/secret.conf .local/share/fin/session.dat NetVisor-api.json bank_credentials.txt; do
  grep -qF "$out" <<<"$hn" && fail "6. a secret went in: $out" || pass "6. left out: $out"
done
for keep in .claude/projects/-x/t1.jsonl .config/app/ok.conf notes/todo.txt; do
  grep -qF "$keep" <<<"$hn" && pass "6. kept: $keep (allow-listed, not 0600, or not in a dot-dir)" || fail "6. missing $keep: $hn"
done
run_bk BOX_STATE_SOURCES="$H" BOX_STATE_KEEP="$T/h2.tar.zst"; rc=$?
grep -qF '.config/app/secret.conf' <<<"$(zstd -dcq "$T/h2.tar.zst" | tar -tif -)" && pass "6. CONTROL: outside BOX_STATE_HOMES the 0600 rule does not fire" \
  || fail "6. control: $(cat "$T/out")"
tar -cf - -C / "${H#/}/notes" 2>/dev/null | zstd -q -o "$T/h3.tar.zst"
out="$( (BOX_STATE_HOMES="$HOMES" bash "$PACK" scan "$T/h2.tar.zst"; BOX_STATE_HOMES="$HOMES" bash "$PACK" scan "$T/h3.tar.zst") )"; rc=$?
[[ $rc -eq 3 ]] && grep -q "^HIT ${H#/}/.config/app/secret.conf 0600$" <<<"$out" && grep -q "^HIT ${H#/}/notes/NetVisor-api.json cred$" <<<"$out" \
  && grep -q "^HIT ${H#/}/notes/bank_credentials.txt cred$" <<<"$out" && ! grep -q 't1.jsonl' <<<"$out" \
  && pass "6. scan: a 0600 dot-dir file and credential names are HITs; the allow-listed transcript is not" || fail "6. scan: rc=$rc $out"
PRE='spl_box_state_pack() { cp "$PLANT" "$1"; };' run_bk DRY_RUN=0 PLANT="$T/h2.tar.zst" BOX_STATE_HOMES="$HOMES"; rc=$?
[[ $rc -eq 3 && ! -s "$T/calls.log" ]] && grep -q 'upload REFUSED' "$T/out" && grep -q "HIT ${H#/}/.config/app/secret.conf 0600" "$T/out" \
  && pass "6. such an archive refuses the upload (exit 3), naming the path" || fail "6. refusal: rc=$rc $(cat "$T/calls.log" "$T/out")"
grep -qE 'SECRET-BYTES|NV-BYTES|BK-BYTES' "$T/out" && fail "6. the refusal printed file content" || pass "6. ...never the content"

# 7 -------------------------------------------------------------------------
M="$T/mnt/data/home"
mkdir -p "$M/boxu/.config/app" "$M/agentx/.claude/projects/-x" "$T/spool7/c-1"
echo 'S7-SECRET' >"$M/boxu/.config/app/secret.conf"; chmod 600 "$M/boxu/.config/app/secret.conf"
echo 'cfg' >"$M/boxu/.config/app/ok.conf"
echo 'msg' >"$T/spool7/c-1/m.json"
echo 't' >"$M/agentx/.claude/projects/-x/t.jsonl"
printf '#!/bin/sh\n[ "$1" = passwd ] && [ -n "$2" ] && echo "$2:x:1:1::%s/$2:/bin/bash"\n' "$M" >"$T/stub/getent"
chmod +x "$T/stub/getent"
SNIPPET='spl_box_state_homes' in_orc SPOOL_AGENT_USER=agentx >"$T/o7"
grep -q "$M/agentx" "$T/o7" && grep -q "$M/$(id -un)" "$T/o7" && ! grep -q '/home/\*' "$T/o7" \
  && pass "7. the 0600 homes are the getent passwd homes (here under mnt/data/home), no /home/* glob" || fail "7. homes: $(cat "$T/o7")"
run_bk BOX_STATE_SOURCES="$M/boxu" SPOOL_AGENT_USER=boxu BOX_STATE_KEEP="$T/h7.tar.zst"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'dropped: 0600=1$' "$T/out" && ! grep -qF 'secret.conf' <<<"$(zstd -dcq "$T/h7.tar.zst" | tar -tif -)" \
  && pass "7. with BOX_STATE_HOMES unset, a 0600 dot-dir file under a getent home outside /home stays out" || fail "7. outside /home: rc=$rc $(cat "$T/out")"
chmod 000 "$M/agentx"
printf '#!/bin/sh\necho "sudo $*" >>"$STUB_LOG"\nexit 1\n' >"$T/stub/sudo"; chmod +x "$T/stub/sudo"
bk7() { : >"$T/calls.log"; SNIPPET="$STUBS; do_spl_box_state_backup" in_orc CNF="$T/cnf.yaml" TMPDIR="$T/tmp" BOX=box1 SPOOL_AGENT_USER=agentx \
  SPOOL_ROOT="$T/spool7" BOX_CRONS_STATE_DIR="$T/nope-state" HOME="$M/boxu" "$@" >"$T/out" 2>&1; }
bk7 DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && grep -q "FATAL $M/agentx/.claude/projects is unreadable as $(id -un) and as agentx" "$T/out" \
  && ! grep -q "agentx.*not on this box" "$T/out" && ! grep -qE '^(gcloud|curl)' "$T/calls.log" \
  && pass "7. an agent home the runner cannot read fails loudly (exit $rc, 'unreadable'), nothing uploaded" || fail "7. unreadable: rc=$rc $(cat "$T/out" "$T/calls.log")"
grep -q "sudo -n -u agentx test -d $M/agentx/.claude/projects" "$T/calls.log" && pass "7. ...after trying to read it as its owner (sudo -n -u agentx)" || fail "7. no owner try: $(cat "$T/calls.log")"
chmod 755 "$M/agentx"; rm -rf "$M/agentx"
bk7; rc=$?
[[ $rc -eq 0 ]] && grep -q "INFO $M/agentx/.claude/projects is not on this box: skipped" "$T/out" && grep -q "packed $T/spool7 as" "$T/out" \
  && pass "7. CONTROL: a home that is really absent is skipped, the rest packs (exit 0)" || fail "7. absent: rc=$rc $(cat "$T/out")"
rm -f "$T/stub/getent" "$T/stub/sudo"

echo "spl-box-state-backup: ${fails} failure(s)"
[ "$fails" -eq 0 ]
