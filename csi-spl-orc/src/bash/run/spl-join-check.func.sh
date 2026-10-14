#!/bin/bash
#------------------------------------------------------------------------------
# @description The end-to-end join check of spec 073 (T005, T007, AC8;
# @description SPL-907), run by workflow 23 per env: a workspace admin's
# @description session mints a join token, a throwaway box joins with
# @description `install.sh --join`, the seat is verified, then removed.
# @description   1. the box: a fresh HOME and a dedicated-box claim
# @description      (SPL_WS_BASE/claim = the workspace, spec 108 3.8) under a
# @description      0700 temp dir; install.sh --no-seat installs the toolchain
# @description   2. sign in as the admin member (POST /api/v1/auth/login)
# @description   3. mint a join token bound to the box id
# @description   4. the box joins: install.sh re-run with SPOOL_JOIN_TOKEN in
# @description      its environment (never argv); its wall clock is AC8's
# @description      "seated in < 1 min" and is enforced
# @description   5. verify: the token lists as used by that box
# @description   6. remove: DELETE the seat (200 revoked); a second DELETE is
# @description      the hub's no-op 200, a never-seated box id answers 404
# @description On any exit the seat is removed, an unused token revoked and
# @description the session signed out.
# @description The member's email and workspace are cnf env.box.join_check_email
# @description and join_check_tenant, never secret. The password comes ONLY
# @description from the env var SPL_PROBE_ADMIN_PW (wf 23 maps the GitHub
# @description secret SPL_PROBE_ADMIN_PW_<ENV> onto it): it goes into a 0600
# @description request body file, removed, never printed, never on a command
# @description line, never in the installer's environment. The token and the
# @description session cookie live only in that 0700 temp dir, removed.
# @description An absent password or cnf member SKIPS with a ::notice:: and
# @description returns 0; a check that runs and fails returns 1.
# @param ENV - required: dev or prd
# @param SPL_PROBE_ADMIN_PW (optional) - the admin member's password; empty = skip
# @param JOIN_CHECK_HUB (optional) - default https://<cnf env.dns.api_fqdn>
# @param JOIN_CHECK_BOX (optional) - default ci-join-<GITHUB_RUN_ID or epoch>-<env>
# @param JOIN_CHECK_INSTALL (optional) - the installer, default spool-install/install.sh (the tests' seam)
# @param JOIN_CHECK_SEAT_MAX_S (optional) - the seat's wall clock limit, default 60 (AC8)
# @example ENV=dev ./run -a do_spl_join_check
#------------------------------------------------------------------------------
do_spl_join_check() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  local org_app app cnf secret="SPL_PROBE_ADMIN_PW_${ENV^^}"
  org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  app="$(cd "$PROJ_PATH/.." && pwd)"
  cnf="$app/$org_app-cnf/$org_app/${ENV}.env.json"
  [[ -r "$cnf" ]] || { do_log "FATAL no readable cnf $cnf"; return 1; }
  local api email tenant
  { read -r api; read -r email; read -r tenant; } < <(python3 - "$cnf" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["env"]
b = e.get("box", {})
print(e.get("dns", {}).get("api_fqdn", ""))
print(str(b.get("join_check_email") or "").strip())
print(str(b.get("join_check_tenant") or "").strip())
PY
  )
  if [[ -z "${SPL_PROBE_ADMIN_PW:-}" ]]; then
    echo "::notice::$ENV join check skipped: the GitHub secret $secret is not set (spec 073 AC8)"
    return 0
  fi
  if [[ -z "$email" || -z "$tenant" ]]; then
    echo "::notice::$ENV join check skipped: cnf env.box.join_check_email / join_check_tenant is not set (spec 073 AC8)"
    return 0
  fi
  local hub="${JOIN_CHECK_HUB:-https://$api}" box
  box="${JOIN_CHECK_BOX:-ci-join-${GITHUB_RUN_ID:-$(date +%s)}-$ENV}"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL box id '$box' is not [a-z0-9-], up to 32"; return 1; }
  # global for the cleanup; every secret-bearing file lives in JC_W
  JC_W="$(umask 077 && mktemp -d)" || return 1
  JC_HUB="${hub%/}" JC_BOX="$box" JC_TOK_ID="" JC_SEATED=0 JC_SIGNED_IN=0 JC_SECRET="$secret"
  local rc=0
  spl_join_check_run "$app" "$org_app" "$email" "$tenant" || rc=$?
  spl_join_check_cleanup
  if [[ $rc -ne 0 ]]; then
    echo "::error::$ENV join check failed at $JC_HUB (workspace $tenant, box $box): see the FAIL line above"
    return 1
  fi
  do_log "INFO $ENV join check: minted, joined, verified and removed $box in $tenant at $JC_HUB"
}

# spl_join_check_run <app> <org_app> <email> <tenant>: steps 1-6; 1 = failed.
spl_join_check_run() {
  local app="$1" org_app="$2" email="$3" tenant="$4" w="$JC_W" code t0 secs
  local inst="${JOIN_CHECK_INSTALL:-$app/$org_app-orc/src/bash/features/spool-install/install.sh}"
  local max="${JOIN_CHECK_SEAT_MAX_S:-60}"
  # 1. the throwaway box: its own HOME, a claim that makes it dedicated
  mkdir -p "$w/home" "$w/ws/$tenant" && printf '%s\n' "$tenant" >"$w/ws/claim" || return 1
  local -a inst_args=(--cli none --no-hooks --no-skills --env "$ENV" --tenant "$tenant" --box "$JC_BOX")
  do_log "INFO 1/6 $ENV throwaway box $JC_BOX: install.sh --no-seat (toolchain)"
  spl_join_check_install "$inst" "${inst_args[@]}" --no-seat || { echo "FAIL 1/6 install.sh --no-seat (rc $?)"; return 1; }
  # 2. sign in: the body file is built from the env var, never an argv
  ( umask 077; EMAIL="$email" TENANT="$tenant" python3 -c '
import json, os, sys
json.dump({"email": os.environ["EMAIL"], "password": os.environ["SPL_PROBE_ADMIN_PW"],
           "tenant": os.environ["TENANT"]}, open(sys.argv[1], "w"))' "$w/login.json" ) || return 1
  code="$(spl_join_check_http POST /api/v1/auth/login "$w/login.json")"
  rm -f "$w/login.json"
  [[ "$code" == 200 ]] || { echo "FAIL 2/6 sign-in as $email in $tenant -> HTTP $code $(spl_join_check_err)"; return 1; }
  JC_SIGNED_IN=1
  do_log "INFO 2/6 signed in as $email in $tenant"
  # 3. mint, bound to this box
  python3 -c 'import json, sys; json.dump({"label": "CI join check (SPL-907) " + sys.argv[2], "box_id": sys.argv[2]}, open(sys.argv[1], "w"))' \
    "$w/mint.json" "$JC_BOX" || return 1
  code="$(spl_join_check_http POST /v1/tenant/agents/join-tokens "$w/mint.json")"
  [[ "$code" == 201 ]] || { echo "FAIL 3/6 mint a join token -> HTTP $code $(spl_join_check_err)"; return 1; }
  JC_TOK_ID="$(umask 077; python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(r["token"]); print(r["id"])' "$w/resp" "$w/token")" && [[ -s "$w/token" ]] ||
    { echo "FAIL 3/6 the mint answer carries no token"; return 1; }
  rm -f "$w/resp"
  [[ "${GITHUB_ACTIONS:-}" == true ]] && echo "::add-mask::$(cat "$w/token")"
  do_log "INFO 3/6 minted join token $JC_TOK_ID for $JC_BOX"
  # 4. the box joins; the token is in its environment only
  t0="$(date +%s)" JC_SEATED=1
  SPOOL_JOIN_TOKEN="$(cat "$w/token")" spl_join_check_install "$inst" "${inst_args[@]}" ||
    { echo "FAIL 4/6 install.sh with the join token (rc $?)"; rm -f "$w/token"; return 1; }
  secs=$(( $(date +%s) - t0 )); rm -f "$w/token"
  (( secs < max )) || { echo "FAIL 4/6 the seat took ${secs}s, AC8 wants < ${max}s"; return 1; }
  do_log "INFO 4/6 $JC_BOX joined in ${secs}s (AC8: < ${max}s)"
  # 5. verify: the token is used, by this box
  code="$(spl_join_check_http GET /v1/tenant/agents/join-tokens)"
  [[ "$code" == 200 ]] || { echo "FAIL 5/6 list join tokens -> HTTP $code $(spl_join_check_err)"; return 1; }
  python3 -c '
import json, sys
t = [x for x in json.load(open(sys.argv[1])).get("tokens", []) if x.get("id") == sys.argv[2]]
sys.exit(0 if t and t[0].get("state") == "used" and t[0].get("consumed_box") in (None, "", sys.argv[3]) else 1)' \
    "$w/resp" "$JC_TOK_ID" "$JC_BOX" || { echo "FAIL 5/6 token $JC_TOK_ID is not listed as used by $JC_BOX"; return 1; }
  JC_TOK_ID=""
  do_log "INFO 5/6 token used, $JC_BOX seated"
  # 6. remove the seat. The hub answers a revoke of an already revoked pin
  # as a no-op 200 and 404 only for a box never pinned (store RevokeSeat), so
  # a second removal answers 200 revoked, and a never-seated id answers 404.
  code="$(spl_join_check_http DELETE "/v1/tenant/agents/pins/$JC_BOX")"
  [[ "$code" == 200 ]] || { echo "FAIL 6/6 remove seat $JC_BOX -> HTTP $code $(spl_join_check_err)"; return 1; }
  spl_join_check_revoked "$JC_BOX" || { echo "FAIL 6/6 remove seat $JC_BOX answered no revoke"; return 1; }
  JC_SEATED=0
  code="$(spl_join_check_http DELETE "/v1/tenant/agents/pins/$JC_BOX")"
  [[ "$code" == 200 ]] && spl_join_check_revoked "$JC_BOX" ||
    { echo "FAIL 6/6 a second removal of $JC_BOX -> HTTP $code, want the no-op 200 revoked"; return 1; }
  code="$(spl_join_check_http DELETE "/v1/tenant/agents/pins/$JC_BOX-never")"
  [[ "$code" == 404 ]] || { echo "FAIL 6/6 a never-seated box $JC_BOX-never -> HTTP $code, want 404"; return 1; }
  do_log "INFO 6/6 seat $JC_BOX removed"
}

# spl_join_check_install <installer> <args...>: runs it as the throwaway box
# (its HOME, its claim), without the password in its environment; its output
# is printed with any join token masked. Returns the installer's rc.
spl_join_check_install() {
  local inst="$1" r=0; shift
  env -u SPL_PROBE_ADMIN_PW -u "$JC_SECRET" HOME="$JC_W/home" XDG_CONFIG_HOME="$JC_W/home/.config" \
    XDG_STATE_HOME="$JC_W/home/.local/state" XDG_DATA_HOME="$JC_W/home/.local/share" \
    SPL_WS_BASE="$JC_W/ws" SPOOL_HUB_URL="$JC_HUB" bash "$inst" "$@" </dev/null >"$JC_W/install.log" 2>&1 || r=$?
  sed -E 's/spj1\.[A-Za-z0-9._-]+/spj1.<redacted>/g' "$JC_W/install.log"
  rm -f "$JC_W/install.log"
  return "$r"
}

# spl_join_check_http <method> <path> [body file]: prints the HTTP code; the
# answer is in $JC_W/resp, the session cookie jar is $JC_W/jar.
spl_join_check_http() {
  local -a a=(-sS -o "$JC_W/resp" -w '%{http_code}' --max-time 30 -b "$JC_W/jar" -c "$JC_W/jar" -X "$1")
  [[ -n "${3:-}" ]] && a+=(-H 'Content-Type: application/json' --data-binary "@$3")
  (umask 077; curl "${a[@]}" "$JC_HUB$2" 2>/dev/null) || true
}

# spl_join_check_revoked <box>: the last answer is {"box_id": box, "revoked": "true"}.
spl_join_check_revoked() {
  python3 -c 'import json, sys; r = json.load(open(sys.argv[1]))
sys.exit(0 if r.get("box_id") == sys.argv[2] and r.get("revoked") == "true" else 1)' "$JC_W/resp" "$1" 2>/dev/null
}

# spl_join_check_err: the hub's error code and message of the last answer.
spl_join_check_err() {
  python3 -c 'import json, sys; e = json.load(open(sys.argv[1])); print(e.get("error", ""), "-", e.get("message", ""))' \
    "$JC_W/resp" 2>/dev/null || true
}

# spl_join_check_cleanup: whatever the run left (the seat, an unused token,
# the session), then the temp dir.
spl_join_check_cleanup() {
  if (( JC_SEATED )); then
    spl_join_check_http DELETE "/v1/tenant/agents/pins/$JC_BOX" >/dev/null
    do_log "INFO cleanup: removed seat $JC_BOX"
  fi
  if [[ -n "$JC_TOK_ID" ]]; then
    spl_join_check_http DELETE "/v1/tenant/agents/join-tokens/$JC_TOK_ID" >/dev/null
    do_log "INFO cleanup: revoked join token $JC_TOK_ID"
  fi
  (( JC_SIGNED_IN )) && spl_join_check_http POST /api/v1/auth/logout >/dev/null
  # the box's Go module cache is read-only, as Go writes it
  chmod -R u+w "$JC_W" 2>/dev/null
  rm -rf "$JC_W"
}
