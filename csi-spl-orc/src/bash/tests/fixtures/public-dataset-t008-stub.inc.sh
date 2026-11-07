#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Shared by public-dataset-publish.tst.sh and public-dataset-takedown.tst.sh (spec
# 091 T008). A fake GCS on disk ($GS/<bucket>/<object>), a fake spool and the
# synthetic candidate. Not a test itself: run-all-tests.sh runs *.tst.sh only.
# The fake enforces what step 053 grants the publish SA on a real bucket: an
# existing public object is never overwritten but latest.json. With
# STUB_IAM=t007 it also refuses every delete, as that SA's roles do today.
# One failure injected: STUB_DESCRIBE=empty|fail (describe prints nothing, exit 0
# or 1), STUB_RM_DENY=<uri prefix> (rm refused there), STUB_LS_DOWN=<uri prefix>
# (ls answers an outage there).
#------------------------------------------------------------------------------
TOPIC=0f8fad5b-d9cb-469f-a165-70867728950e
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
STAGING=$(yq -r '.env.steps."053-gcs-public-dataset".staging_bucket_name' "$CNF/dev.env.yaml")
PUBLIC=$(yq -r '.env.steps."053-gcs-public-dataset".public_bucket_name' "$CNF/dev.env.yaml")
PUBLISH_SA="$(yq -r '.env.steps."053-gcs-public-dataset".publish_sa_account_id' "$CNF/dev.env.yaml")@csi-spl-dev.iam.gserviceaccount.com"
ENV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
GS="$T/gs"
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/desk/spool/c-900"
printf '{"type":"service_account","client_email":"%s"}\n' "$ENV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
printf '{"type":"service_account","client_email":"csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com"}\n' >"$T/home/.gcp/.csi/key-csi-spl-prd.json"
printf '{"type":"service_account","client_email":"%s"}\n' "$PUBLISH_SA" >"$T/publish-key.json"
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
case "$1 $2" in
  "auth activate-service-account") for a; do [[ "$a" == --key-file=* ]] && jq -r .client_email "${a#*=}" >"$CLOUDSDK_CONFIG/active"; done; exit 0 ;;
  "auth list") cat "$CLOUDSDK_CONFIG/active" 2>/dev/null; exit 0 ;;
  "auth print-access-token") echo ya29.stub_token_value_long_enough; exit 0 ;;
  "storage "*) ;;
  *) exit 0 ;;
esac
verb="$2"; shift 2; [[ "$verb" == objects ]] && { verb="$1"; shift; }
noclobber=0 uris=()
for a; do
  case "$a" in --no-clobber) noclobber=1 ;; --*) ;; *) uris+=("$a") ;; esac
done
path() { printf '%s/%s' "$GS" "${1#gs://}"; }
none() { echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects." >&2; exit 1; }
case "$verb" in
  cat) [[ -f "$(path "${uris[0]}")" ]] && cat "$(path "${uris[0]}")" ;;
  describe)
    [[ "${STUB_DESCRIBE:-}" == empty ]] && exit 0
    [[ "${STUB_DESCRIBE:-}" == fail ]] && exit 1
    [[ -f "$(path "${uris[0]}")" ]] && md5sum <"$(path "${uris[0]}")" | cut -d' ' -f1 ;;
  ls)
    u="${uris[0]}"
    [[ -n "${STUB_LS_DOWN:-}" && "$u" == "$STUB_LS_DOWN"* ]] && { echo "ERROR: 503 backend unavailable" >&2; exit 1; }
    [[ -f "$(path "$u")" ]] && { echo "$u"; exit 0; }
    if [[ "$u" == *'/**' ]]; then
      d="$(path "${u%/\*\*}")"; [[ -d "$d" ]] || none
      out="$(cd "$d" && find . -type f | sed "s|^\./|${u%\*\*}|" | sort)"
      [[ -n "$out" ]] && echo "$out" || none
    else
      d="$(path "$u")"; [[ -d "$d" ]] || none
      out="$(cd "$d" && for e in *; do [[ -d "$e" ]] && echo "$u$e/"; [[ -f "$e" ]] && echo "$u$e"; done)"
      [[ -n "$out" ]] && echo "$out" || none
    fi ;;
  rm)
    [[ "${STUB_IAM:-}" == t007 ]] && { echo "ERROR: 403 lacks storage.objects.delete" >&2; exit 1; }
    [[ -n "${STUB_RM_DENY:-}" && "${uris[0]}" == "$STUB_RM_DENY"* ]] && { echo "ERROR: 403 lacks storage.objects.delete" >&2; exit 1; }
    d="$(path "${uris[0]}")"; [[ -e "$d" ]] || { echo "ERROR: One or more URLs matched no objects." >&2; exit 1; }
    rm -rf "$d"; find "$GS" -mindepth 1 -type d -empty -delete ;;
  cp)
    src="${uris[0]}" dst="${uris[1]}"
    if [[ "$dst" == gs://* ]]; then
      p="$(path "$dst")"
      if [[ -e "$p" ]]; then
        (( noclobber )) && exit 0
        [[ "$dst" == */latest.json ]] || { echo "ERROR: 403 lacks storage.objects.delete" >&2; exit 1; }
      fi
      mkdir -p "$(dirname "$p")"
    else
      p="$dst"
    fi
    [[ "$src" == gs://* ]] && src="$(path "$src")"
    cp "$src" "$p" ;;
esac
EOF
cat >"$T/stub/spool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  hub-tail) [[ "${STUB_HUB:-}" == down ]] && exit 1; echo "spool|$*" >>"$STUB_LOG"; cat "$TAIL" ;;
  send) echo "spool|$*" >>"$STUB_LOG"; echo '{"delivery":"sent"}' ;;
esac
EOF
chmod +x "$T/stub/"*

# run_orc <snippet> [VAR=value]...: the snippet in a fresh shell with every
# action sourced, on the fake GCS and spool.
run_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u GCP_SA_KEY_FILE -u DRY_RUN -u PUBLIC_DATASET_FORCE -u SPOOL_BOX_TAG \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" GS="$GS" TAIL="$T/tail.ndjson" T="$T" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev PD_TOPIC="$TOPIC" TENANT_ID=t1 \
    DESK_AGENT=c-900 DESK_BOX=box-desk SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_host_spool() { SPL_SPOOL="$T/stub/spool"; }
    spl_desk_dir() { printf "%s" "$T/desk"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

# verdict_write <bucket> <sha> <kind> <lane id> <msg id>; a verdict and its hub line
verdict_write() {
  local d="$GS/$1/verdicts/$2"
  mkdir -p "$d"
  jq -n --arg s "$2" --arg k "$3" --arg l "$4" --arg m "$5" '{v: 1, file_sha256: $s, lane_id: $l, lane_kind: $k, method: "x",
    checks: [{name: "x", n: 1, result: "PASS", detail: ""}], verdict: "PASS", ts: "2026-11-03T10:00:00Z", hub_msg_id: $m}' >"$d/$3.json"
  jq -nc --arg s "$2" --arg l "$4" --arg m "$5" --arg t "$TOPIC" '{v: 1, msg_id: $m, task_id: $t, from: $l, to: "ALL-0", kind: "result", body: ("verdict PASS sha256 " + $s)}' >>"$T/tail.ndjson"
}

# stage <candidate> [exported_at]: a synthetic gzip, manifest, name lists and
# three good verdicts in staging. Sets CAND, NAME, SHA.
stage() {
  CAND="$1"; NAME="spool-hub-public-$CAND"
  local at="${2:-$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)}" d="$GS/$STAGING/candidates/$CAND"
  mkdir -p "$d/names"
  printf 'COPY tenants (tenant_id) FROM stdin;\nROWCANARY-%s\n\\.\n' "$CAND" | gzip -n >"$d/$NAME.sql.gz"
  SHA="$(sha256sum "$d/$NAME.sql.gz" | cut -d' ' -f1)"
  jq -n --arg f "$NAME.sql.gz" --arg s "$SHA" --arg at "$at" '{v: 1, file: $f, sha256: $s, version: "1.5.0", commit: ("a" * 40), migration_head: "0254_x.sql",
    allow_list_version: 1, allow_list_sha256: ("b" * 64), workspace_ids: ["t1"], row_counts: {tenants: 1, humans: 0, tenant_memberships: 0, channels: 0, messages: 0},
    removed_by_class: {}, release_note: "https://site.example.com/r", source_env: "dev", exported_at: $at}' >"$d/$NAME.manifest.json"
  printf 'ws-other\tNAMECANARY Holdings\n' >"$d/names/names.tsv"
  printf '%s\n' "$(printf namecanary | sha256sum | cut -d' ' -f1)" >"$d/names/names.sha256"
  verdict_write "$STAGING" "$SHA" agy a-101 "00000000-0000-4000-8000-${SHA:0:10}01"
  verdict_write "$STAGING" "$SHA" grok g-102 "00000000-0000-4000-8000-${SHA:0:10}02"
  verdict_write "$STAGING" "$SHA" claude c-103 "00000000-0000-4000-8000-${SHA:0:10}03"
}
reset_gs() { rm -rf "$GS"; mkdir -p "$GS/$STAGING" "$GS/$PUBLIC"; : >"$T/tail.ndjson"; }
public_files() { (cd "$GS/$PUBLIC" 2>/dev/null && find . -type f | sed 's|^\./||' | sort); }
no_content() { ! grep -qE 'ROWCANARY|NAMECANARY|ws-other|namecanary' "$T/out"; }
