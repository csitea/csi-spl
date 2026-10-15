#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only drift check (SPL-1947): does prd lead dev anywhere?
# @description The rule: dev always equals or leads prd (owner, t1 msg
# @description 15204547). The apply side is enforced by the order gate
# @description (iac do_check_dev_leads_prd); this action finds what got past it.
# @description One row per item, dev vs prd:
# @description   tf  <step> - do_tf_plan_pending of each step in each env, in the
# @description                tf-runner: dev pending + prd clean = prd leads
# @description                (prd carries a change dev does not)
# @description   hub / wui  - the commit prd serves (/version, build.json) must
# @description                be served by dev too, or a later one: reuses
# @description                do_check_deploy_lag ENV=dev SHA=<prd's commit>
# @description                A deploy younger than ENV_ORDER_GRACE_MINUTES is
# @description                in-flight (CI deploys dev and prd on the same push)
# @description   cnf hub.image.tag - prd's tag must not be newer than dev's
# @description Verdicts: equal, dev-leads, prd-leads, both-behind (both envs
# @description pending against the tree), in-flight, unknown (cannot tell). Prints a table
# @description and exits 1 when any row is prd-leads, 2 when none is but a row
# @description is unknown, else 0. Plans only (-lock=false): nothing applied, no
# @description GCP mutation. The daily cron: do_check_env_order_install_cron.
# @param ENV_ORDER_TF (optional) - 0 skips the terraform rows (they need the tf-runner)
# @param ENV_ORDER_STEPS (optional) - comma list of steps, default every step dir
# @param ENV_ORDER_PLAN_CMD (optional) - a command run instead of the tf-runner
# @param   plan (tests); called with ENV STEP, prints a TF_PLAN line, exits 0/2/1
# @param ENV_ORDER_PRD_HUB_URL / ENV_ORDER_PRD_WUI_URL (optional) - prd probe URLs (tests)
# @param LAG_HUB_URL / LAG_WUI_URL (optional) - dev probe URLs, as do_check_deploy_lag
# @param ENV_ORDER_GRACE_MINUTES (optional) - default 45: prd's commit is in-flight
# @param   on dev until its oldest input dev lacks is older than this
# @example ./run -a do_check_env_order
# @example ENV_ORDER_TF=0 ./run -a do_check_env_order
# @example ENV_ORDER_STEPS=030-cloud-run-hub ./run -a do_check_env_order
#------------------------------------------------------------------------------
do_check_env_order() {
  do_require_bin yq jq curl git || return 1
  SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
  ENV_ORDER_ROWS=()
  [[ "${ENV_ORDER_TF:-1}" == 0 ]] || _env_order_tf_rows
  _env_order_served_row hub
  _env_order_served_row wui
  _env_order_cnf_row
  _env_order_report
}

# _env_order_row <kind> <item> <dev> <prd> <verdict> [note]
_env_order_row() { ENV_ORDER_ROWS+=("$1|$2|$3|$4|$5|${6:-}"); }

# _env_order_report: the table, then the exit: 1 prd leads, 2 unknown, 0 fine
_env_order_report() {
  local r k i d p v n lead=0 unknown=0
  printf '%-4s %-34s %-10s %-10s %-12s %s\n' kind item dev prd verdict note
  for r in "${ENV_ORDER_ROWS[@]}"; do
    IFS='|' read -r k i d p v n <<<"$r"
    printf '%-4s %-34s %-10s %-10s %-12s %s\n' "$k" "$i" "$d" "$p" "$v" "$n"
    [[ "$v" == prd-leads ]] && lead=$((lead + 1))
    [[ "$v" == unknown ]] && unknown=$((unknown + 1))
  done
  if ((lead)); then
    echo "ENV_ORDER FAIL: prd leads dev in $lead row(s): apply/deploy them on dev first (dev always equals or leads prd)"
    return 1
  fi
  ((unknown)) && { echo "ENV_ORDER UNKNOWN: $unknown row(s) could not be read; no row shows prd ahead"; return 2; }
  echo "ENV_ORDER OK: dev equals or leads prd in every row"
}

# _env_order_tf_rows: plan each step in dev and prd
_env_order_tf_rows() {
  local -a steps=()
  if [[ -n "${ENV_ORDER_STEPS:-}" ]]; then
    IFS=',' read -r -a steps <<<"$ENV_ORDER_STEPS"
  else
    local d
    for d in "$APP_PATH/$SPL_ORG_APP-iac/src/terraform"/[0-9]*/; do steps+=("$(basename "$d")"); done
  fi
  if [[ -z "${ENV_ORDER_PLAN_CMD:-}" ]] && ! _env_order_runner_up; then
    _env_order_row tf '*' - - unknown "the tf-runner $(_env_order_runner) is not running (make do-setup-app-inf)"
    return 0
  fi
  local s dv pv dsha
  for s in "${steps[@]}"; do
    dv="$(_env_order_plan dev "$s")"; pv="$(_env_order_plan prd "$s")"
    dsha="${dv#* }"; dv="${dv%% *}"; pv="${pv%% *}"
    _env_order_row tf "$s" "$dv" "$pv" "$(_env_order_tf_verdict "$dv" "$pv")" "tree=${dsha:0:8}"
  done
}

# _env_order_tf_verdict <dev> <prd>: each is clean, pending or error
_env_order_tf_verdict() {
  case "$1/$2" in
    clean/clean) echo equal ;;
    pending/clean) echo prd-leads ;;
    clean/pending) echo dev-leads ;;
    pending/pending) echo both-behind ;;
    *) echo unknown ;;
  esac
}

_env_order_runner() { echo "con-${SPL_ORG_APP%%-*}-$SPL_ORG_APP-tf-runner"; }
_env_order_runner_up() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$(_env_order_runner)" 2>/dev/null)" == true ]]
}

# _env_order_plan <env> <step>: prints "<clean|pending|error> <tree sha>"
_env_order_plan() {
  local out rc sha=""
  if [[ -n "${ENV_ORDER_PLAN_CMD:-}" ]]; then
    out="$(ENV="$1" STEP="$2" "$ENV_ORDER_PLAN_CMD" 2>/dev/null)"
    rc=$?
  else
    out="$(docker exec -e ORG="${SPL_ORG_APP%%-*}" -e ENV="$1" -e APP="${SPL_ORG_APP#*-}" -e STEP="$2" \
      -e ACTION=provision -e TF_VAR_billing_account_id="${GCP_BILLING_ACCOUNT_ID:-}" \
      "$(_env_order_runner)" ./run -a do_tf_plan_pending 2>/dev/null)"
    rc=$?
  fi
  local line; line="$(sed -n '/^TF_PLAN /{p;q}' <<<"$out")"
  [[ "$line" =~ sha=([^ ]+) ]] && sha="${BASH_REMATCH[1]}"
  case "$rc" in 0) echo "clean ${sha:--}" ;; 2) echo "pending ${sha:--}" ;; *) echo "error ${sha:--}" ;; esac
}

# _env_order_served_row <hub|wui>: dev must serve prd's commit or a later one
_env_order_served_row() {
  local comp="$1" url body prd line rc
  url="$(_env_order_prd_url "$comp")" || { _env_order_row "$comp" served - - unknown "no prd url in cnf"; return 0; }
  body="$(curl -sS --max-time "${LAG_HTTP_TIMEOUT:-15}" -H 'Cache-Control: no-cache' "$url" 2>/dev/null)"
  prd="$(jq -r 'if type == "object" and (.commit | type) == "string" then .commit else "" end' <<<"$body" 2>/dev/null)"
  [[ "$prd" =~ ^[0-9a-f]{40}$ ]] || { _env_order_row "$comp" served - - unknown "no 40-hex .commit at $url"; return 0; }
  line="$(ENV=dev SHA="$prd" COMPONENT="$comp" GRACE_MINUTES="${ENV_ORDER_GRACE_MINUTES:-45}" do_check_deploy_lag 2>/dev/null)"
  rc=$?
  local dev=""; [[ "$line" =~ served=([0-9a-f]+) ]] && dev="${BASH_REMATCH[1]}"
  case "$rc" in
    0) if [[ "$dev" == "${prd:0:8}" ]]; then _env_order_row "$comp" served "$dev" "${prd:0:8}" equal
       elif [[ "$line" == "dev $comp pending "* ]]; then
         _env_order_row "$comp" served "${dev:--}" "${prd:0:8}" in-flight "dev's deploy is within its grace"
       elif [[ "$line" == *" n=0 "* ]]; then _env_order_row "$comp" served "${dev:--}" "${prd:0:8}" equal "no $comp input changed between them"
       else _env_order_row "$comp" served "${dev:--}" "${prd:0:8}" dev-leads; fi ;;
    3) _env_order_row "$comp" served "${dev:--}" "${prd:0:8}" prd-leads "prd serves $comp inputs dev does not" ;;
    *) _env_order_row "$comp" served "${dev:--}" "${prd:0:8}" unknown "${line##*reason=}" ;;
  esac
}

# _env_order_prd_url <hub|wui>: prd's probe url from its cnf (a subshell: the
# cnf resolver exports per-env globals)
_env_order_prd_url() {
  local o
  [[ "$1" == hub && -n "${ENV_ORDER_PRD_HUB_URL:-}" ]] && { echo "$ENV_ORDER_PRD_HUB_URL"; return 0; }
  [[ "$1" == wui && -n "${ENV_ORDER_PRD_WUI_URL:-}" ]] && { echo "$ENV_ORDER_PRD_WUI_URL"; return 0; }
  o="$(ENV=prd; do_spl_cloud_cnf >/dev/null 2>&1 || exit 1
       if [[ "$1" == hub ]]; then yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF"; else yq -r '.env.dns.fqdn // ""' "$SPL_CNF"; fi)" || return 1
  [[ -n "$o" && "$o" != null ]] || return 1
  if [[ "$1" == hub ]]; then echo "https://$o/version"; else echo "https://$o/build.json"; fi
}

# _env_order_cnf_row: the hub image tag each env's cnf names
_env_order_cnf_row() {
  local d p newest
  d="$( (ENV=dev; do_spl_cloud_cnf >/dev/null 2>&1 && echo "${SPL_IMAGE_CNF_REF##*:}") )"
  p="$( (ENV=prd; do_spl_cloud_cnf >/dev/null 2>&1 && echo "${SPL_IMAGE_CNF_REF##*:}") )"
  if [[ -z "$d" || -z "$p" ]]; then
    _env_order_row cnf hub.image.tag "${d:--}" "${p:--}" unknown "the cnf did not resolve"
    return 0
  fi
  newest="$(printf '%s\n%s\n' "$d" "$p" | sort -V | tail -1)"
  if [[ "$d" == "$p" ]]; then _env_order_row cnf hub.image.tag "$d" "$p" equal
  elif [[ "$newest" == "$p" ]]; then _env_order_row cnf hub.image.tag "$d" "$p" prd-leads "raise dev's tag first"
  else _env_order_row cnf hub.image.tag "$d" "$p" dev-leads
  fi
}
