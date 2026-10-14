#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only smoke suite of the LIVE hub API on the env's api host
# @description (cnf env.dns.api_fqdn = [<env_subdomain>.]api.<BASE_DOMAIN>),
# @description the gap T6 of the devops guide section 16. GET requests only,
# @description one at a time, no retry, never a sign-in: it writes nothing.
# @description   public tier  /version {version,commit,built_at}, /v1/health
# @description                {"status":"ok"}, and the door: anonymous
# @description                /v1/view/me and /v1/operator/workspaces -> 401
# @description   member tier  only with a session cookie of a TEST workspace
# @description                (e2e or e2e-<x>): /v1/view/me must name that
# @description                workspace (any other tenant stops the tier before
# @description                a second read; an expired cookie, 401, is a SKIP),
# @description                then /v1/view/channels, /v1/view/roster,
# @description                /v1/openapi.json
# @description One line per check, "<check> <PASS|FAIL|SKIP> <detail>"; exit 0
# @description only when no check failed. The cookie is never printed.
# @param ENV - required: dev or prd (prd needs API_SMOKE_PRD_GO=1)
# @param API_SMOKE_PRD_GO (optional) - 1 = the operator opts in to prd
# @param TENANT (optional) - the test workspace of the member tier, default e2e
# @param API_SMOKE_COOKIE_FILE (optional) - a 0600 file holding
# @param   "spool_session=<value>"; default the m3 e2e member's cookie of
# @param   TENANT under the state dir; absent = member tier SKIP
# @param API_SMOKE_GAP_S (optional) - seconds between requests, default 1 on
# @param   prd, 0 on dev
# @param API_SMOKE_HOST (optional) - probe this host instead of the cnf one
# @example ENV=dev ./run -a do_spl_api_smoke
# @example ENV=prd API_SMOKE_PRD_GO=1 ./run -a do_spl_api_smoke
#------------------------------------------------------------------------------
do_spl_api_smoke() {
  do_require_bin curl jq || return 1
  _spl_api_smoke_guard || return 1
  local host="${API_SMOKE_HOST:-}" tenant="${TENANT:-e2e}" fails=0
  if [[ -z "$host" ]]; then
    do_spl_cloud_cnf || return 1
    spl_cnf_api_fqdn host || return 1
  fi
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || { do_log "FATAL api host must be a DNS name, got: '$host'"; return 1; }
  _spl_api_smoke_test_ws "$tenant" || { do_log "FATAL TENANT=$tenant is not a test workspace (e2e or e2e-<x>)"; return 1; }
  local gap="${API_SMOKE_GAP_S:-}"
  [[ -n "$gap" ]] || { [[ "$ENV" == prd ]] && gap=1 || gap=0; }
  [[ "$gap" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { do_log "FATAL API_SMOKE_GAP_S must be seconds, got: '$gap'"; return 1; }
  local cookie_file="${API_SMOKE_COOKIE_FILE:-${SPL_STATE_DIR:-/nonexistent}/m3-e2e/$tenant/cookie-human}"
  do_log "INFO api smoke ENV=$ENV host=$host tenant=$tenant gap=${gap}s (GET only, no retry)"
  _spl_api_smoke_public "https://$host" "$gap" || fails=$?
  local mf=0
  _spl_api_smoke_member "https://$host" "$gap" "$tenant" "$cookie_file" || mf=$?
  fails=$((fails + mf))
  if (( fails == 0 )); then
    do_log "OK api smoke $host: every check passed"
    return 0
  fi
  do_log "FATAL api smoke $host: $fails check(s) failed"
  return 1
}

# ENV dev or prd; prd only with the operator's API_SMOKE_PRD_GO=1.
_spl_api_smoke_guard() {
  spl_require_cloud_env || return 1
  [[ "$ENV" == dev || "${API_SMOKE_PRD_GO:-}" == 1 ]] && return 0
  do_log "FATAL ENV=prd is opt-in: set API_SMOKE_PRD_GO=1 (read-only GETs, test workspace only)"
  return 1
}

# A test workspace: e2e or e2e-<x>; t1 and customer workspaces never pass.
_spl_api_smoke_test_ws() {
  [[ "$1" =~ ^e2e(-[a-z0-9][a-z0-9-]*)?$ ]]
}

_spl_api_smoke_line() { printf '%-16s %s %s\n' "$1" "$2" "$3"; }

# _spl_api_smoke_get <url> <body file> [cookie file] -> prints the HTTP code
# (000 when curl failed). The cookie goes in through a header file, never argv.
_spl_api_smoke_get() {
  local url="$1" body="$2" cf="${3:-}" hdr code
  if [[ -n "$cf" ]]; then
    hdr="$(mktemp)" || return 1
    chmod 600 "$hdr"
    printf 'Cookie: %s\n' "$(head -n 1 "$cf")" >"$hdr"
    code="$(curl -sS --max-time 15 -o "$body" -w '%{http_code}' -H @"$hdr" "$url" 2>/dev/null)"
    rm -f "$hdr"
  else
    code="$(curl -sS --max-time 15 -o "$body" -w '%{http_code}' "$url" 2>/dev/null)"
  fi
  printf '%s' "${code:-000}"
}

# _spl_api_smoke_check <name> <base> <path> <want code> <jq test> <gap> [cookie]
# One GET, judged by its status and a jq test of the body; returns 1 on FAIL.
_spl_api_smoke_check() {
  local name="$1" url="$2$3" want="$4" test="$5" gap="$6" cf="${7:-}" body code
  body="$(mktemp)" || return 1
  code="$(_spl_api_smoke_get "$url" "$body" "$cf")"
  sleep "$gap"
  if [[ "$code" == "$want" ]] && jq -e "$test" "$body" >/dev/null 2>&1; then
    _spl_api_smoke_line "$name" PASS "$3 $code"
    rm -f "$body"; return 0
  fi
  _spl_api_smoke_line "$name" FAIL "$3 $code (want $want and $test): $(head -c 120 "$body" | tr '\n' ' ')"
  rm -f "$body"; return 1
}

# The public tier: no credential at all. Returns the number of failed checks.
_spl_api_smoke_public() {
  local b="$1" g="$2" f=0
  _spl_api_smoke_check version "$b" /version 200 \
    '[.version, .commit, .built_at] | all(type == "string" and length > 0)' "$g" || f=$((f + 1))
  _spl_api_smoke_check health "$b" /v1/health 200 '.status == "ok"' "$g" || f=$((f + 1))
  _spl_api_smoke_check "door view" "$b" /v1/view/me 401 '.error == "view_door"' "$g" || f=$((f + 1))
  _spl_api_smoke_check "door operator" "$b" /v1/operator/workspaces 401 '.error | type == "string"' "$g" || f=$((f + 1))
  return "$f"
}

# The member tier, with the test workspace's session cookie. /v1/view/me runs
# first and must name the test workspace; any other tenant stops the tier.
_spl_api_smoke_member() {
  local b="$1" g="$2" t="$3" cf="$4" f=0
  if [[ ! -s "$cf" ]]; then
    _spl_api_smoke_line member SKIP "no session cookie file for $t (API_SMOKE_COOKIE_FILE)"
    return 0
  fi
  if [[ "$(stat -c %a "$cf" 2>/dev/null)" != 600 ]]; then
    _spl_api_smoke_line member FAIL "the cookie file must be mode 0600"
    return 1
  fi
  local body code
  body="$(mktemp)" || return 1
  code="$(_spl_api_smoke_get "$b/v1/view/me" "$body" "$cf")"
  sleep "$g"
  if [[ "$code" == 401 ]]; then
    rm -f "$body"
    _spl_api_smoke_line member SKIP "the session cookie expired (401): a run of do_spl_m3_e2e on $t writes a fresh one"
    return 0
  fi
  if [[ "$code" != 200 ]] || ! jq -e --arg t "$t" '(.tenant_id == $t) and (.permissions | type == "array")' "$body" >/dev/null 2>&1; then
    local seen
    seen="$(jq -c '{tenant_id, error}' "$body" 2>/dev/null)"
    _spl_api_smoke_line "member me" FAIL "/v1/view/me $code is not a member session of $t: ${seen:0:120}"
    rm -f "$body"
    return 1
  fi
  rm -f "$body"
  _spl_api_smoke_line "member me" PASS "/v1/view/me 200 tenant $t"
  _spl_api_smoke_check "member channels" "$b" /v1/view/channels 200 '.channels | type == "array"' "$g" "$cf" || f=$((f + 1))
  _spl_api_smoke_check "member roster" "$b" /v1/view/roster 200 'type == "object"' "$g" "$cf" || f=$((f + 1))
  _spl_api_smoke_check "member openapi" "$b" /v1/openapi.json 200 '.paths | type == "object"' "$g" "$cf" || f=$((f + 1))
  return "$f"
}
