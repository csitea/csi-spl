#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The order gate (SPL-1947): dev always equals or leads prd.
# @description A prd apply of STEP first plans dev for the same step from the
# @description same tree (or reads a fresh cached clean dev plan). Dev pending
# @description -> the prd apply is REFUSED, naming the step: apply dev first,
# @description prove it there, then repeat it on prd. A dev plan that fails is
# @description refused too (fail closed): dev's state is unknown.
# @description Owner, t1 msg 15204547: "Dev should always be in sync with Prod,
# @description or it should be in a newer version than Prod."
# @description do_provision, do_tf_apply and do_tf_apply_target call it through
# @description env_order_gate; dev applies and divest are never gated.
# @description Prints `ENV_ORDER prd <step> allowed ...` or a `REFUSED:` line, exits:
# @description   0 allowed (dev clean), or refused but ENV_ORDER_OVERRIDE is set
# @description   3 refused: dev has pending changes for the step
# @description   1 refused: the dev plan failed, cannot tell
# @description The plan itself is read-only (do_tf_plan_pending); nothing applied.
# @param ENV - required: the env being applied; only prd is gated
# @param STEP - required: the terraform step
# @param ENV_ORDER_OVERRIDE (optional) - the owner's msg id approving THIS
# @param   emergency prd apply ahead of dev (8+ hex). Logged to
# @param   dat/log/env-order-override.log and as a WARN line; never a default
# @param ENV_ORDER_CACHE_MINUTES (optional) - age of a usable cached clean dev
# @param   plan of the same tree sha, default 60; 0 always plans
# @param ENV_ORDER_CACHE_DIR (optional) - default <iac>/dat/log/env-order
# @param ENV_ORDER_PLAN_CMD (optional) - a command run instead of the dev plan
# @param   (tests); called with ENV=dev STEP=<step>, its exit is the plan's
# @example ENV=prd STEP=030-cloud-run-hub ./run -a do_check_dev_leads_prd
#------------------------------------------------------------------------------

do_check_dev_leads_prd() {
  local env="${ENV:?}" step="${STEP:?}" sha line rc verdict why
  if [[ "$env" != prd ]]; then
    echo "ENV_ORDER $env $step not-gated (only a prd apply waits for dev)"
    return 0
  fi
  sha="$(env_order_tree_sha)"
  if env_order_cache_fresh dev "$step" "$sha"; then
    echo "ENV_ORDER prd $step allowed dev=clean sha=$sha (cached dev plan of this tree)"
    return 0
  fi
  line="$(env_order_plan_dev "$step")"
  rc=$?
  [[ -n "$line" ]] && echo "$line"
  case "$rc" in
    0) echo "ENV_ORDER prd $step allowed dev=clean sha=$sha"; return 0 ;;
    2) verdict=pending; why="dev has pending changes for $step from this tree" ;;
    *) verdict=unknown; why="the dev plan of $step failed, so dev's state is unknown" ;;
  esac
  echo "REFUSED: prd apply of STEP=$step: $why. Apply dev first (ENV=dev STEP=$step make do-provision), prove it on dev, then apply prd from the same commit. An owner-approved emergency only: ENV_ORDER_OVERRIDE=<owner msg id>."
  if [[ -n "${ENV_ORDER_OVERRIDE:-}" ]]; then
    env_order_override_log "$step" "$sha" "$verdict" || return 1
    return 0
  fi
  [[ "$verdict" == pending ]] && return 3
  return 1
}

# env_order_gate: the apply actions' one call. Gates a prd apply once per
# step and process (do_provision -> do_tf_apply would plan dev twice).
env_order_gate() {
  [[ "${ENV:-}" == prd && "${ACTION:-provision}" != divest ]] || return 0
  [[ "${_ENV_ORDER_GATED:-}" == "${STEP:-}" ]] && return 0
  do_check_dev_leads_prd || return $?
  export _ENV_ORDER_GATED="$STEP"
}

# env_order_plan_dev <step>: the dev plan line on stdout, its rc (0/2/1).
env_order_plan_dev() {
  if [[ -n "${ENV_ORDER_PLAN_CMD:-}" ]]; then
    ENV=dev STEP="$1" "$ENV_ORDER_PLAN_CMD"
  else
    ENV=dev STEP="$1" do_tf_plan_pending
  fi
}

# env_order_tree_sha: HEAD of the mounted tree, `<sha>-dirty` when the
# terraform or cnf tree has local edits (never cached), `unknown` without git.
env_order_tree_sha() {
  local oa="${ORG:-csi}-${APP#"${ORG:-csi}"-}" sha
  sha="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)" || { echo unknown; return 0; }
  if [[ -n "$(git -C "$APP_PATH" status --porcelain -- "$oa-iac/src/terraform" "$oa-cnf" 2>/dev/null)" ]]; then
    echo "$sha-dirty"; return 0
  fi
  echo "$sha"
}

env_order_cache_dir() { echo "${ENV_ORDER_CACHE_DIR:-$PROJ_PATH/dat/log/env-order}"; }

# env_order_cache_put <env> <step> <sha>: remember a clean plan of a clean tree.
env_order_cache_put() {
  [[ "$3" =~ ^[0-9a-f]{40}$ ]] || return 0
  local d; d="$(env_order_cache_dir)"
  mkdir -p "$d" 2>/dev/null && echo "$(date -u +%s) $3" >"$d/$1.$2.clean" 2>/dev/null
  return 0
}

# env_order_cache_fresh <env> <step> <sha>: a clean plan of THIS sha, young enough.
env_order_cache_fresh() {
  local f mins="${ENV_ORDER_CACHE_MINUTES:-60}" at csha
  [[ "$3" =~ ^[0-9a-f]{40}$ && "$mins" =~ ^[0-9]+$ ]] && ((mins > 0)) || return 1
  f="$(env_order_cache_dir)/$1.$2.clean"
  read -r at csha <"$f" 2>/dev/null || return 1
  [[ "$csha" == "$3" && "$at" =~ ^[0-9]+$ ]] || return 1
  (($(date -u +%s) - at <= mins * 60))
}

# env_order_override_log <step> <sha> <dev verdict>: the override is an
# owner's msg id, written where the next reader of the apply finds it.
env_order_override_log() {
  local id="$ENV_ORDER_OVERRIDE" log
  [[ "$id" =~ ^[0-9a-f]{8}[0-9a-f-]*$ ]] || {
    echo "REFUSED: ENV_ORDER_OVERRIDE must be the owner's msg id approving this apply (8+ hex), got: '$id'"
    return 1; }
  log="$PROJ_PATH/dat/log/env-order-override.log"
  mkdir -p "$(dirname "$log")" 2>/dev/null
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) env=prd step=$1 sha=$2 dev=$3 override=$id user=$(id -un)" >>"$log"
  do_log "WARN ENV_ORDER_OVERRIDE=$id: prd apply of $1 goes AHEAD of dev (dev=$3), logged to $log"
}
