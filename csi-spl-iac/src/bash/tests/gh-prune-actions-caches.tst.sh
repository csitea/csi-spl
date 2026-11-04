#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4790, do_gh_prune_actions_caches (hermetic: `gh` is a stub that
# serves two pages of caches and logs every DELETE). Fixture, now =
# 2026-11-04T12:00:00Z, the store as measured that day plus two:
#   1 old-unused        100 MB  last 2026-10-20  (unused > 7 days)
#   2 go-race-pg-v1    6410 MB  last 2026-11-04T10:13
#   3 setup-go          350 MB  last 2026-11-04T10:12
#   4 go-race-pg-v2    2560 MB  last 2026-11-03T09:00
#   1. DRY_RUN default: "would delete" 1 (unused 7d) and 4 (total over 8 GB,
#      the least recently used), no DELETE call, the summary line
#  1b. DRY_RUN empty, "false", "no" or "00": still a dry run (only 0 deletes)
#   2. DRY_RUN=0: exactly two DELETEs, 1 then 4; the rest fit under 8 GB
#   3. nothing old, the store under the limit: 0 deleted, no DELETE
#   4. a DELETE that fails: exit 1 and the ERROR line, the others still go
#   5. the repo comes from the origin remote, else refused (no default)
#   6. a lower limit (6 GB) deletes least recently used first: 4, 3, then 2
#   7. static, 14_ci-cache-prune.yml: a weekly schedule runs the action and
#      deletes (DRY_RUN=0); a dispatch is a dry run by default; any other
#      event (a push, where inputs.dry_run is null and null == false) is a
#      dry run too; actions: write
#   CONTROL: the stub serves both pages (a lost page would hide a cache).
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/gh-prune-actions-caches.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
require_action "$FUNC"

MB=1048576
cat >"$T/caches.json" <<EOF
{"total_count":4,"actions_caches":[
 {"id":2,"key":"go-race-pg-v1","size_in_bytes":$((6410 * MB)),"last_accessed_at":"2026-11-04T10:13:04Z","ref":"refs/heads/master"},
 {"id":1,"key":"old-unused","size_in_bytes":$((100 * MB)),"last_accessed_at":"2026-10-20T08:00:00Z","ref":"refs/heads/master"}]}
{"total_count":4,"actions_caches":[
 {"id":3,"key":"setup-go","size_in_bytes":$((350 * MB)),"last_accessed_at":"2026-11-04T10:12:58Z","ref":"refs/heads/master"},
 {"id":4,"key":"go-race-pg-v2","size_in_bytes":$((2560 * MB)),"last_accessed_at":"2026-11-03T09:00:00Z","ref":"refs/heads/master"}]}
EOF
mkdir -p "$T/bin" "$T/app"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# lists the fixture's pages; logs each DELETE, failing the id in GH_STUB_FAIL_ID
case "$*" in
  "api --paginate repos/o/app/actions/caches?per_page=100") cat "$GH_STUB_CACHES" ;;
  "api -X DELETE repos/o/app/actions/caches/"*)
    id="${4##*/}"; echo "DELETE $id" >>"$GH_STUB_LOG"; [[ "$id" != "${GH_STUB_FAIL_ID:-}" ]] ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$T/bin/gh"
git -C "$T/app" init -q
[[ "$(git -C "$T/app" rev-parse --absolute-git-dir)" == "$T/app/.git" ]] || { echo "FAIL: fixture repo is not isolated"; exit 1; }
git -C "$T/app" remote add origin https://github.com/o/app.git

NOW=$(date -u -d 2026-11-04T12:00:00Z +%s)
act() {  # runs the action in a clean shell; output in $T/out, DELETEs in $T/log
  : >"$T/log"
  env -u GH_CACHE_PRUNE_REPO -u DRY_RUN -u CACHE_PRUNE_DAYS -u CACHE_PRUNE_MAX_GB PATH="$T/bin:$PATH" \
    GH_STUB_CACHES="$T/caches.json" GH_STUB_LOG="$T/log" APP_PATH="$T/app" CACHE_PRUNE_NOW="$NOW" "$@" \
    bash -c 'do_log() { echo "$*"; }; source "$1"; do_gh_prune_actions_caches' _ "$FUNC" >"$T/out" 2>&1
}
deletes() { tr '\n' ' ' <"$T/log" | sed 's/ $//'; }

# 1
act; rc=$?
[[ $rc == 0 && ! -s "$T/log" ]] \
  && grep -qE '^INFO DRY_RUN would delete 1 old-unused 100 MB last=2026-10-20T08:00:00Z ref=refs/heads/master \(unused 7d\)$' "$T/out" \
  && grep -qE '^INFO DRY_RUN would delete 4 go-race-pg-v2 2560 MB .*\(total over 8 GB\)$' "$T/out" \
  && grep -qF 'OK o/app: DRY_RUN would delete 2 caches (2660 MB); kept 2 caches (6760 MB, limit 8 GB, unused limit 7d)' "$T/out" \
  && pass "1. DRY_RUN default: would delete 1 (unused) and 4 (LRU over 8 GB), no DELETE" \
  || fail "1. rc=$rc deletes=[$(deletes)] $(cat "$T/out")"

# 1b
for v in "" false no 00; do
  act DRY_RUN="$v"; rc=$?
  [[ $rc == 0 && ! -s "$T/log" ]] && grep -qF 'OK o/app: DRY_RUN would delete 2 caches' "$T/out" \
    && pass "1b. DRY_RUN='$v': a dry run, no DELETE (only the exact 0 deletes)" \
    || fail "1b. DRY_RUN='$v' rc=$rc deletes=[$(deletes)] $(cat "$T/out")"
done

# 2
act DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(deletes)" == "DELETE 1 DELETE 4" ]] && grep -q '^OK deleted 4 go-race-pg-v2' "$T/out" \
  && grep -qF 'OK o/app: deleted 2 caches (2660 MB); kept 2 caches (6760 MB' "$T/out" \
  && pass "2. DRY_RUN=0: DELETE 1 then 4, the rest (6760 MB) fit under 8 GB" \
  || fail "2. rc=$rc deletes=[$(deletes)] $(cat "$T/out")"

# 3
act DRY_RUN=0 CACHE_PRUNE_DAYS=30 CACHE_PRUNE_MAX_GB=20; rc=$?
[[ $rc == 0 && ! -s "$T/log" ]] && grep -qF 'deleted 0 caches (0 MB); kept 4 caches (9420 MB' "$T/out" \
  && pass "3. nothing old, under the limit: 0 deleted" || fail "3. rc=$rc deletes=[$(deletes)] $(cat "$T/out")"

# 4
act DRY_RUN=0 GH_STUB_FAIL_ID=1; rc=$?
[[ $rc == 1 && "$(deletes)" == "DELETE 1 DELETE 4" ]] && grep -q '^ERROR cannot delete 1 old-unused' "$T/out" \
  && pass "4. a failed DELETE: exit 1, the ERROR line, the next cache still goes" \
  || fail "4. rc=$rc deletes=[$(deletes)] $(cat "$T/out")"

# 5
git -C "$T/app" remote set-url origin git@github.com:o/app.git
act; rc=$?
[[ $rc == 0 ]] && grep -q '^OK o/app:' "$T/out" && pass "5a. the repo from an ssh origin" || fail "5a. rc=$rc $(cat "$T/out")"
git -C "$T/app" remote remove origin
act; rc=$?
[[ $rc == 1 ]] && grep -q '^FATAL no <owner>/<repo>' "$T/out" && pass "5b. no origin, no GH_CACHE_PRUNE_REPO: refused" \
  || fail "5b. rc=$rc $(cat "$T/out")"
act GH_CACHE_PRUNE_REPO=o/app; rc=$?
[[ $rc == 0 ]] && pass "5c. GH_CACHE_PRUNE_REPO names the repo" || fail "5c. rc=$rc $(cat "$T/out")"

# 6
act DRY_RUN=0 GH_CACHE_PRUNE_REPO=o/app CACHE_PRUNE_MAX_GB=6; rc=$?
[[ $rc == 0 && "$(deletes)" == "DELETE 1 DELETE 4 DELETE 3 DELETE 2" ]] \
  && pass "6. a 6 GB limit: least recently used first, 4 then 3 then 2" || fail "6. rc=$rc deletes=[$(deletes)] $(cat "$T/out")"

# 7
WF14="$APP_ROOT/.github/workflows/14_ci-cache-prune.yml"
wf=$(grep -vE '^\s*#' "$WF14" 2>/dev/null)
want_dry="DRY_RUN: \${{ (github.event_name == 'schedule' || (github.event_name == 'workflow_dispatch' && inputs.dry_run == false)) && '0' || '1' }}"
miss=""
grep -qE '^\s+- cron: "[0-9]+ [0-9]+ \* \* [0-6]"' <<<"$wf" || miss+=" weekly-cron"
grep -qF './run -a do_gh_prune_actions_caches' <<<"$wf" || miss+=" action"
grep -qF "$want_dry" <<<"$wf" || miss+=" DRY_RUN-expression"
grep -A3 -E '^\s+dry_run:' <<<"$wf" | grep -E 'default: true' >/dev/null || miss+=" dispatch-default-dry"
grep -qE '^\s+actions: write' <<<"$wf" || miss+=" actions-write"
[[ -z "$miss" ]] && pass "7. wf 14: weekly cron runs the action with DRY_RUN=0, dispatch dry by default, other events dry, actions: write" \
  || fail "7. wf 14 lacks:$miss"

# CONTROL
n=$(env GH_STUB_CACHES="$T/caches.json" "$T/bin/gh" api --paginate 'repos/o/app/actions/caches?per_page=100' | jq -r '.actions_caches[].id' | sort | tr '\n' ' ')
[[ "$n" == "1 2 3 4 " ]] && pass "CONTROL: the stub serves both pages (ids 1 2 3 4)" || fail "CONTROL: stub ids '$n'"

echo "=== $([[ $fails -eq 0 ]] && echo 'all gh-prune-actions-caches.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
