#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_marketing_publish (SPL-1855) publishes a live blog post on
#          the owner's LinkedIn through `spool marketing-publish`, offline.
#          curl serves $T/index.json (the live blog index); the desk spool is
#          a stub that records its calls and answers like the hub.
#   1. a bad POST_ID or FOR_HUM is refused before any call
#   2. DRY_RUN=1 (the default) prints the post, its link and the emoji
#      commentary, and calls no spool verb: nothing is published
#   3. a post not in the live English index is refused, nothing published
#   4. DRY_RUN=0 runs `marketing-publish <post> --for <hum>` once, on the
#      agent's desk, and prints the hub's answer
#   5. the hub's refusal (409, once per post) is a FATAL, not an OK
#   6. DRY_RUN=0 with no desk for the agent is refused before any call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud docker cloud-sql-proxy spool tmux
AGENT=c-002
POST=2026-10-14-agents-publish
mkdir -p "$T/state/dev/desk/spool/box-desk/spool/$AGENT"
cat >"$T/index.json" <<EOF_JSON
{"locales": {"en": [{"id": "$POST", "title": "Agents (now) publish", "summary": "One line.", "image": "a.webp"},
                    {"id": "2026-10-01-older", "title": "Older", "summary": "Old."}],
             "bg": [{"id": "2026-10-13-bg-only", "title": "BG", "summary": "x"}]}}
EOF_JSON

# run [VAR=value]... - the action against the stubs; spool calls in $T/calls,
# output in $T/o, rc in $rc. HUB_CODE=409 makes the stub refuse.
run() {
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; SPL_WUI_URL=https://app.invalid; }
spl_host_spool() { :; }
curl() { [[ "${*: -1}" == https://app.invalid/blog-md/index.json ]] && cat "$INDEX_F"; }
spl_desk_spool() {
  shift 4; [[ "${1:-}" == -- ]] && shift
  { local IFS="|"; echo "$*" >>"$CALLS"; }
  [[ "${HUB_CODE:-200}" == 200 ]] || { echo "spool: publish refused, hub answered 409 (already_recorded: the post is already published)"; return 1; }
  echo "{\"post\":\"$2\",\"published\":1,\"scheduled\":1}"
}
do_spl_marketing_publish'
  in_orc SNIPPET="$SNIPPET" TENANT_ID=spool DESK_BOX=box-desk DESK_AGENT="$AGENT" POST_ID="$POST" FOR_HUM=HUM-10 \
    CALLS="$T/calls" INDEX_F="$T/index.json" "$@" >"$T/o" 2>&1
  rc=$?
}

# --- 1. bad input -------------------------------------------------------------------------
run POST_ID=../etc DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'POST_ID must be' "$T/o" &&
  pass "a bad POST_ID is refused before any call" || fail "bad post (rc=$rc): $(cat "$T/o")"
run FOR_HUM=admin DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'FOR_HUM must be' "$T/o" &&
  pass "a FOR_HUM that is not a HUM id is refused before any call" || fail "bad hum (rc=$rc): $(cat "$T/o")"

# --- 2. DRY_RUN=1, the default ----------------------------------------------------------------
run
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q "DRY_RUN would publish $POST on the LinkedIn of HUM-10 in spool" "$T/o" &&
  grep -q '"dry_run": true' "$T/o" && grep -q "https://app.invalid/blog/$POST" "$T/o" &&
  grep -qF $'\U0001F4DD Agents (now) publish | \U0001F4A1 One line. | \U0001F449 https://app.invalid/blog/'"$POST" "$T/o" &&
  grep -q 'OK DRY_RUN nothing was published' "$T/o" &&
  pass "DRY_RUN=1 prints the post and its emoji commentary, publishes nothing" || fail "dry run (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"

# --- 3. a post not live in English ------------------------------------------------------------------
for p in 2026-10-13-bg-only 2026-12-31-nope; do
  run POST_ID="$p" DRY_RUN=0
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "post $p is not in the live English blog index" "$T/o" &&
    pass "post $p (not live in en) is refused, nothing published" || fail "not live $p (rc=$rc): $(cat "$T/o")"
done

# --- 4. DRY_RUN=0 publishes once, for the owner, on the agent's desk ------------------------------------
run DRY_RUN=0
[[ $rc -eq 0 && "$(cat "$T/calls")" == "marketing-publish|$POST|--for|HUM-10" ]] && grep -q '"published": 1' "$T/o" &&
  grep -q '"dry_run": false' "$T/o" && grep -q "OK $AGENT published $POST" "$T/o" &&
  pass "DRY_RUN=0 runs marketing-publish once for HUM-10 and prints the hub's answer" || fail "publish (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"

# --- 5. the hub's 409 (once per post) ---------------------------------------------------------------------
run DRY_RUN=0 HUB_CODE=409
[[ $rc -ne 0 ]] && grep -q 'FATAL marketing-publish .*409' "$T/o" && ! grep -q '^OK' "$T/o" &&
  pass "a second publish (hub 409) is a FATAL, never an OK" || fail "409 (rc=$rc): $(cat "$T/o")"

# --- 6. no desk -------------------------------------------------------------------------------------------
run DRY_RUN=0 DESK_AGENT=c-009
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'FATAL no desk for c-009' "$T/o" &&
  pass "DRY_RUN=0 with no desk for the agent is refused before any call" || fail "no desk (rc=$rc): $(cat "$T/o")"

echo "fails=$fails"
exit $(( fails > 0 ))
