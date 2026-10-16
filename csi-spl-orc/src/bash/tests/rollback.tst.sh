#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the named rollbacks do_hub_rollback / do_wui_rollback (SPL-2131)
#          and their shared half lib/bash/funcs/spl-rollback.func.sh.
#   1. ENV, TO and DRY_RUN are checked first (rc 2), both actions
#   2. target resolution: a v-tag, a short sha, the newest key on a commit;
#      an unknown tag, a sha off trunk, an untagged commit are refused
#   3. hub TO=previous skips a revision that reuses the serving image (a heal
#      restart) and maps the older digest back to its release and commit
#   4. hub: an image not in the env's registry is refused (rc 3)
#   5. the schema: newer migrations are listed; a non-additive one refuses
#      (rc 5) until ROLLBACK_SCHEMA_OK=1; an added constraint is only listed
#   6. prd is refused unless dev serves the same commit (rc 4), both actions;
#      ENV_ORDER_OVERRIDE lets it through
#   7. DRY_RUN=1 (the default) makes no services update and no release POST;
#      DRY_RUN=0 makes exactly one, every gcloud call carries --account
#   8. wui: previous, a version id, a v-tag through the wf 30 step window; a
#      release that does not serve the target is undone (the live version is
#      released again) and fails
# CONTROL: the stubs record every call, so "no call" means not made.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/stub" "$T/served" "$T/g"

# --- fixture: a bare origin, trunk c1..c4 with tags, one local-only commit -----
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
g() { git -C "$T/repo" -c user.name=t -c user.email=t@example.com "$@"; }
g checkout -q -b master
mkdir -p "$T/repo/sql" "$T/repo/csi-spl-cnf/csi-spl"
printf '{"env":{"dns":{"api_fqdn":"dev-api.example.com"},"steps":{"019-firebase-static-site":{"site_id":"dev-site"}}}}\n' \
  >"$T/repo/csi-spl-cnf/csi-spl/dev.env.json"
echo 'CREATE TABLE a (x int);' >"$T/repo/sql/0001_a.sql"
g add -A; g commit -q -m c1; g tag v1.0.1
echo '-- DROP COLUMN in a comment is not DDL' >"$T/repo/sql/0002_b.sql"
echo 'CREATE TABLE b (y int);' >>"$T/repo/sql/0002_b.sql"
g add -A; g commit -q -m c2; g tag v1.0.2
echo 'ALTER TABLE a DROP COLUMN x;' >"$T/repo/sql/0003_drop.sql"
echo 'ALTER TABLE b ADD CONSTRAINT b_y CHECK (y > 0);' >"$T/repo/sql/0004_check.sql"
g add -A; g commit -q -m c3; g tag v1.0.3; g tag v1.0.3-c2
echo d >"$T/repo/d"; g add d; g commit -q -m c4
g push -q --tags origin master 2>/dev/null
C1="$(g rev-parse "v1.0.1^{commit}")"; C2="$(g rev-parse "v1.0.2^{commit}")"; C3="$(g rev-parse "v1.0.3^{commit}")"; C4="$(g rev-parse HEAD)"
echo e >"$T/repo/e"; g add e; g commit -q -m local-only
LOCAL="$(g rev-parse HEAD)"
g reset -q --hard "$C4"

cat >"$T/cnf.yaml" <<'EOF'
env:
  hub:
    service_name: hub-svc
  dns:
    api_fqdn: api.example.com
  steps:
    019-firebase-static-site:
      site_id: the-site
EOF

# --- stubs ----------------------------------------------------------------------
# curl: /version and build.json from $T/served/<host>.<kind>; Firebase REST
# from $T/fb (a POST logs its query, and moves the site to $T/fb/after)
cat >"$T/stub/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$STUB_LOG"
url="${*: -1}"; method=GET
for ((i = 1; i <= $#; i++)); do [[ "${!i}" == -X ]] && { j=$((i + 1)); method="${!j}"; }; done
case "$url" in
  https://firebasehosting.googleapis.com/*)
    cat >/dev/null
    if [[ "$method" == POST ]]; then
      echo "FBPOST ${url#*versionName=}" >>"$STUB_LOG"
      v="${url##*/}"; [[ -f "$T/fb/after.$v" ]] && cp "$T/fb/after.$v" "$T/served/the-site.build"
      echo '{"name":"sites/the-site/channels/live/releases/1"}'
    else cat "$T/fb/releases.json"; fi ;;
  https://*/version*) h="${url#https://}"; cat "$T/served/${h%%/*}.version" 2>/dev/null || exit 22 ;;
  https://*.web.app/build.json*) h="${url#https://}"; h="${h%%.web.app*}"; cat "$T/served/$h.build" 2>/dev/null || exit 22 ;;
  *) exit 7 ;;
esac
EOF
# gcloud: answers from $T/g; a services update serves $UPDATE_SERVES
cat >"$T/stub/gcloud" <<'EOF'
#!/bin/bash
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  "auth print-access-token"*) echo tok ;;
  "run services describe"*latestReadyRevisionName*) echo rev-3 ;;
  "run services describe"*) cat "$T/g/live" ;;
  "run services update"*) [[ -n "${UPDATE_SERVES:-}" ]] && printf '{"commit":"%s"}' "$UPDATE_SERVES" >"$T/served/api.example.com.version"; exit 0 ;;
  "run revisions list"*) cat "$T/g/revs.json" ;;
  "artifacts docker images describe"*) ref="$5"; grep -qx "$ref" "$T/g/images" && echo "sha256:${ref##*:}" || exit 1 ;;
  "artifacts docker tags list"*) for a in "$@"; do [[ "$a" == --filter=* ]] && d="${a#*version~}"; done
    grep "^$d " "$T/g/tags" | cut -d' ' -f2 ;;
  *) exit 1 ;;
esac
EOF
# gh: wf 30 runs and their deploy step windows from $T/gh
cat >"$T/stub/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >>"$STUB_LOG"
case "$2" in
  */workflows/*) q="${2#*\?}"; q="${q%%&*}"
    case "$q" in head_sha=*) grep " ${q#head_sha=}$" "$T/gh/runs" ;; *) cat "$T/gh/runs" ;; esac ;;
  */runs/*/jobs*) id="${2#*runs/}"; id="${id%%/*}"; cat "$T/gh/win.$id" 2>/dev/null ;;
esac
EOF
chmod +x "$T/stub/"*

printf 'reg/hub:1.0.1\nreg/hub:1.0.2\nreg/hub:1.0.3-c2\n' >"$T/g/images"
echo reg/hub:1.0.3-c2 >"$T/g/live"
# rev-3 serves d3, rev-2 is a heal restart of d3, rev-1 ran d2
cat >"$T/g/revs.json" <<'EOF'
[{"metadata":{"name":"rev-1","creationTimestamp":"2026-10-01T01:00:00Z"},"status":{"imageDigest":"reg/hub@sha256:d2"}},
 {"metadata":{"name":"rev-3","creationTimestamp":"2026-10-01T03:00:00Z"},"status":{"imageDigest":"reg/hub@sha256:d3"}},
 {"metadata":{"name":"rev-2","creationTimestamp":"2026-10-01T02:00:00Z"},"status":{"imageDigest":"reg/hub@sha256:d3"}}]
EOF
printf 'd2 ci-abc-v1.0.2\nd2 1.0.2\nd3 1.0.3-c2\n' >"$T/g/tags"
mkdir -p "$T/fb" "$T/gh"
cat >"$T/fb/releases.json" <<'EOF'
{"releases":[
 {"releaseTime":"2026-10-01T03:00:05.100Z","version":{"name":"sites/the-site/versions/aaaaaaaaaaaaaaa3"}},
 {"releaseTime":"2026-10-01T02:30:00.000Z","version":{"name":"sites/the-site/versions/aaaaaaaaaaaaaaa3"}},
 {"releaseTime":"2026-10-01T02:00:07.500Z","version":{"name":"sites/the-site/versions/aaaaaaaaaaaaaaa2"}},
 {"releaseTime":"2026-10-01T01:00:03.000Z","version":{"name":"sites/the-site/versions/aaaaaaaaaaaaaaa1"}}]}
EOF
printf '11 %s\n12 %s\n' "$C3" "$C2" >"$T/gh/runs"
echo '2026-10-01T03:00:00Z 2026-10-01T03:00:06Z' >"$T/gh/win.11"
echo '2026-10-01T02:00:00Z 2026-10-01T02:00:07Z' >"$T/gh/win.12"
printf '{"commit":"%s"}' "$C2" >"$T/fb/after.aaaaaaaaaaaaaaa2"

# served <host> <kind> <sha>
served() { printf '{"commit":"%s"}' "$3" >"$T/served/$1.$2"; }
reset_served() {
  served api.example.com version "$C3"; served dev-api.example.com version "$C3"
  served the-site build "$C3"; served dev-site build "$C3"
}

# rb <snippet> [VAR=value]... - libs + the two actions, cloud cnf and identity stubbed
rb() {
  local s="$1"; shift
  : >"$T/calls.log"
  env APP_PATH="$T/repo" PROJ_PATH="$PROJ_ROOT" T="$T" STUB_LOG="$T/calls.log" PATH="$T/stub:$PATH" ENV=dev \
    HUB_RB_WAIT_S=0 WUI_RB_WAIT_S=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    source "$PROJ_PATH/src/bash/run/hub-rollback.func.sh"
    source "$PROJ_PATH/src/bash/run/wui-rollback.func.sh"
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml" SPL_PROJECT=p SPL_REGION=r SPL_IMAGE_CNF_REF=reg/hub:1.0.0 SPL_IMAGE_SQL_SRC=sql; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { :; }
    do_check_hub_deploy() { echo "check-hub SPL_HUB_IMAGE_TAG=${SPL_HUB_IMAGE_TAG:-}" >>"$STUB_LOG"; }
    '"$s"
}
calls() { grep -c "$1" "$T/calls.log"; }

# --- 1. ENV / TO / DRY_RUN --------------------------------------------------------
for a in do_hub_rollback do_wui_rollback; do
  rc=0; rb "$a" ENV=qa TO=previous >"$T/out" 2>&1 || rc=$?
  [[ $rc == 2 ]] && pass "1. $a refuses ENV=qa (rc 2)" || fail "1. $a ENV=qa rc $rc"
  rc=0; rb "$a" >"$T/out" 2>&1 || rc=$?
  [[ $rc == 2 ]] && grep -q 'TO must be set' "$T/out" && pass "1. $a refuses a missing TO (rc 2)" || fail "1. $a no TO rc $rc: $(cat "$T/out")"
  rc=0; rb "$a" TO=previous DRY_RUN=yes >"$T/out" 2>&1 || rc=$?
  [[ $rc == 2 ]] && pass "1. $a refuses DRY_RUN=yes" || fail "1. $a DRY_RUN=yes rc $rc"
  rc=0; rb "$a" TO=junk >"$T/out" 2>&1 || rc=$?
  [[ $rc == 2 ]] && pass "1. $a refuses TO=junk (rc 2)" || fail "1. $a TO=junk rc $rc: $(tail -2 "$T/out")"
done

# --- 2. target resolution -------------------------------------------------------------
got="$(rb 'spl_rb_commit_of v1.0.2')"; [[ "$got" == "$C2" ]] && pass "2. v1.0.2 -> its commit" || fail "2. v1.0.2 -> '$got'"
got="$(rb "spl_rb_commit_of ${C3:0:9}")"; [[ "$got" == "$C3" ]] && pass "2. a short sha -> the full one" || fail "2. short sha -> '$got'"
rc=0; rb 'spl_rb_commit_of v1.9.9' >"$T/out" 2>&1 || rc=$?
[[ $rc == 3 ]] && pass "2. an unknown tag is refused (rc 3)" || fail "2. unknown tag rc $rc"
rc=0; rb "spl_rb_commit_of $LOCAL" >"$T/out" 2>&1 || rc=$?
[[ $rc == 3 ]] && grep -q 'not on origin/master' "$T/out" && pass "2. a sha off trunk is refused (rc 3)" || fail "2. off-trunk rc $rc: $(cat "$T/out")"
got="$(rb "spl_rb_key_of $C3")"; [[ "$got" == 1.0.3-c2 ]] && pass "2. the newest key on a commit wins (1.0.3-c2)" || fail "2. key of c3 '$got'"
rc=0; rb "spl_rb_key_of $C4" >/dev/null 2>&1 || rc=$?
[[ $rc == 1 ]] && pass "2. an untagged commit has no key" || fail "2. untagged rc $rc"
reset_served
rc=0; rb do_hub_rollback TO="${C4:0:10}" >"$T/out" 2>&1 || rc=$?
[[ $rc == 3 ]] && grep -q 'carries no v-tag' "$T/out" && pass "2. hub: a never-deployed commit is refused (rc 3)" || fail "2. hub untagged rc $rc: $(tail -2 "$T/out")"

# --- 3. hub TO=previous ---------------------------------------------------------------------
reset_served
rc=0; rb do_hub_rollback TO=previous ROLLBACK_SCHEMA_OK=1 >"$T/out" 2>&1 || rc=$?
grep -q "release 1.0.2 -> ${C2:0:12}" "$T/out" && grep -q 'target    reg/hub:1.0.2 ' "$T/out" &&
  pass "3. previous skips the heal restart and maps d2 -> 1.0.2 -> its commit" || fail "3. previous rc $rc: $(cat "$T/out")"
rc=0; rb do_hub_rollback TO=rev-1 ROLLBACK_SCHEMA_OK=1 >"$T/out" 2>&1 || rc=$?
[[ $rc == 2 ]] && pass "3. a revision of another service is not a target form (rc 2)" || fail "3. rev-1 rc $rc"

# --- 4. image not in the registry ---------------------------------------------------------------
rc=0; rb do_hub_rollback TO=v1.0.3 >"$T/out" 2>&1 || rc=$?
[[ $rc == 3 ]] && grep -q 'not in the dev registry' "$T/out" && pass "4. a release with no image here is refused (rc 3)" || fail "4. rc $rc: $(tail -2 "$T/out")"

# --- 5. the schema ----------------------------------------------------------------------------------
reset_served
rc=0; rb do_hub_rollback TO=v1.0.2 >"$T/out" 2>&1 || rc=$?
[[ $rc == 5 ]] && grep -q 'BREAKING sql/0003_drop.sql' "$T/out" && grep -q 'read     sql/0004_check.sql' "$T/out" &&
  pass "5. a DROP COLUMN newer than the target refuses (rc 5), a constraint is listed" || fail "5. rc $rc: $(cat "$T/out")"
grep -q 'sql/0002_b.sql' "$T/out" && fail "5. the target's own migration was listed" || pass "5. the target's own migrations are not listed"
rc=0; rb do_hub_rollback TO=v1.0.2 ROLLBACK_SCHEMA_OK=1 >"$T/out" 2>&1 || rc=$?
[[ $rc == 0 ]] && pass "5. ROLLBACK_SCHEMA_OK=1 lets it through" || fail "5. override rc $rc"
served api.example.com version "$C3"
rc=0; got="$(rb "spl_rb_schema_check $C1 $C2" SPL_IMAGE_SQL_SRC=sql 2>&1)" || rc=$?
[[ $rc == 0 ]] && grep -q 'additive sql/0002_b.sql' <<<"$got" && pass "5. a comment saying DROP COLUMN is not DDL" || fail "5. comment rc $rc: $got"

# --- 6. dev before prd --------------------------------------------------------------------------------
for comp in hub wui; do
  reset_served; served dev-api.example.com version "$C2"; served dev-site build "$C2"
  rc=0; rb "do_${comp}_rollback" ENV=prd TO=v1.0.3-c2 >"$T/out" 2>&1 || rc=$?
  [[ $rc == 4 ]] && grep -q 'prd refused' "$T/out" && pass "6. $comp prd refused while dev serves another commit (rc 4)" || fail "6. $comp rc $rc: $(tail -3 "$T/out")"
  [[ $(calls 'services update') == 0 && $(calls FBPOST) == 0 ]] && pass "6. $comp: the refusal changed nothing" || fail "6. $comp refusal made a change"
  served dev-api.example.com version "$C3"; served dev-site build "$C3"
  rc=0; rb "do_${comp}_rollback" ENV=prd TO=v1.0.3-c2 >"$T/out" 2>&1 || rc=$?
  [[ $rc == 0 ]] && grep -q 'dev already serves' "$T/out" && pass "6. $comp prd passes once dev serves the target" || fail "6. $comp prd after dev rc $rc: $(tail -3 "$T/out")"
  served dev-api.example.com version "$C2"; served dev-site build "$C2"
  rc=0; rb "do_${comp}_rollback" ENV=prd TO=v1.0.3-c2 ENV_ORDER_OVERRIDE=abc12345 >"$T/out" 2>&1 || rc=$?
  [[ $rc == 0 ]] && grep -q 'ENV_ORDER_OVERRIDE=abc12345' "$T/out" && pass "6. $comp ENV_ORDER_OVERRIDE lets prd through, named" || fail "6. $comp override rc $rc"
done
served dev-site build "$C3"
rc=0; rb do_wui_rollback ENV=prd TO=previous >"$T/out" 2>&1 || rc=$?
[[ $rc == 4 ]] && pass "6. wui prd TO=previous, its commit not dev's, is refused" || fail "6. wui prd previous rc $rc: $(tail -3 "$T/out")"

# --- 7. DRY_RUN changes nothing; DRY_RUN=0 changes once -----------------------------------------------
reset_served
rc=0; rb do_hub_rollback TO=v1.0.2 ROLLBACK_SCHEMA_OK=1 >"$T/out" 2>&1 || rc=$?
[[ $rc == 0 && $(calls 'services update') == 0 && $(calls check-hub) == 0 ]] && grep -q 'nothing was changed' "$T/out" &&
  pass "7. hub DRY_RUN default: a plan, no update" || fail "7. hub dry rc $rc: $(cat "$T/calls.log")"
rc=0; rb do_hub_rollback TO=v1.0.2 ROLLBACK_SCHEMA_OK=1 DRY_RUN=0 UPDATE_SERVES="$C2" >"$T/out" 2>&1 || rc=$?
[[ $rc == 0 && $(calls 'services update hub-svc') == 1 ]] && grep -q -- '--image reg/hub:1.0.2' "$T/calls.log" &&
  grep -q 'check-hub SPL_HUB_IMAGE_TAG=1.0.2' "$T/calls.log" && grep -q "OK https://api.example.com/version commit=$C2" "$T/out" &&
  pass "7. hub DRY_RUN=0: one update to 1.0.2, verified on /version" || fail "7. hub roll rc $rc: $(tail -4 "$T/out")"
[[ $(grep '^gcloud ' "$T/calls.log" | grep -vc -- '--account=sa@example.com') == 0 ]] &&
  pass "7. every gcloud call carries --account" || fail "7. a gcloud call without --account: $(grep '^gcloud ' "$T/calls.log" | grep -v -- --account=)"
reset_served
rc=0; rb do_hub_rollback TO=v1.0.2 ROLLBACK_SCHEMA_OK=1 DRY_RUN=0 >"$T/out" 2>&1 || rc=$?
[[ $rc == 1 ]] && grep -q 'serves .*not' "$T/out" && pass "7. hub: a roll that /version does not show fails" || fail "7. unverified roll rc $rc"
rc=0; rb do_wui_rollback TO=previous >"$T/out" 2>&1 || rc=$?
[[ $rc == 0 && $(calls FBPOST) == 0 ]] && pass "7. wui DRY_RUN default: a plan, no release" || fail "7. wui dry rc $rc"

# --- 8. wui targets and the release ---------------------------------------------------------------------
reset_served
rc=0; rb do_wui_rollback TO=previous >"$T/out" 2>&1 || rc=$?
grep -q "version aaaaaaaaaaaaaaa2 .* = commit $C2" "$T/out" && pass "8. previous = the newest other version, its commit from the step window" ||
  fail "8. previous: $(cat "$T/out")"
rc=0; rb do_wui_rollback TO=v1.0.2 >"$T/out" 2>&1 || rc=$?
grep -q 'target    version aaaaaaaaaaaaaaa2' "$T/out" && pass "8. v1.0.2 -> the version released in its deploy step" || fail "8. v1.0.2: $(cat "$T/out")"
rc=0; rb do_wui_rollback TO=v1.0.1 >"$T/out" 2>&1 || rc=$?
[[ $rc == 3 ]] && grep -q 'no wf 30 release' "$T/out" && pass "8. a commit with no WUI release is refused (rc 3)" || fail "8. v1.0.1 rc $rc"
rc=0; rb do_wui_rollback TO=aaaaaaaaaaaaaaa1 >"$T/out" 2>&1 || rc=$?
[[ $rc == 0 ]] && grep -q 'commit unknown until it is live' "$T/out" && pass "8. a version id with no run resolves, commit unknown" || fail "8. version id rc $rc: $(cat "$T/out")"
rc=0; rb do_wui_rollback TO=bbbbbbbbbbbbbbbb >"$T/out" 2>&1 || rc=$?
[[ $rc == 3 ]] && pass "8. a version id not in the live history is refused (rc 3)" || fail "8. unknown version rc $rc"
rc=0; rb do_wui_rollback TO=v1.0.2 DRY_RUN=0 >"$T/out" 2>&1 || rc=$?
[[ $rc == 0 && $(calls FBPOST) == 1 ]] && grep -q 'FBPOST sites/the-site/versions/aaaaaaaaaaaaaaa2' "$T/calls.log" &&
  grep -q "OK https://the-site.web.app/build.json commit=$C2" "$T/out" && pass "8. DRY_RUN=0: one release, build.json verified" || fail "8. release rc $rc: $(tail -3 "$T/out")"
grep -q 'Authorization' <(grep '^curl ' "$T/calls.log") && fail "8. the bearer token is on curl's argv" || pass "8. the bearer token never rides on argv"
reset_served; rm -f "$T/fb/after.aaaaaaaaaaaaaaa2"
rc=0; rb do_wui_rollback TO=v1.0.2 DRY_RUN=0 >"$T/out" 2>&1 || rc=$?
[[ $rc == 1 && $(calls FBPOST) == 2 ]] && grep -q 'FBPOST sites/the-site/versions/aaaaaaaaaaaaaaa3' "$T/calls.log" &&
  pass "8. a release that does not serve the target is undone and fails" || fail "8. undo rc $rc: $(grep FBPOST "$T/calls.log")"

echo "rollback.tst.sh: $fails failure(s)"
exit $((fails > 0))
