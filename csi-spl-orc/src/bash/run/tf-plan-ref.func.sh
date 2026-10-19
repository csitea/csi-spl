#!/bin/bash
#------------------------------------------------------------------------------
# @description PLAN ONLY: a terraform plan of ANOTHER ref (a review branch or a
# @description sha), through the long-lived tf-runner, without touching the
# @description checkout it mounts (SPL-2602). The tf-runner mounts one tree,
# @description the main checkout, and no lane may switch it; so this action
#   1. resolves PLAN_REF to ONE commit in that tree's repo (worktree branches
#      share its refs; a remote branch resolves as origin/<ref>),
#   2. exports that commit's tree (`git archive`, tracked files only) into a
#      git-ignored scratch dir INSIDE the mounted tree,
#      <mounted tree>/.tf-plan-ref/<sha12>.<env>.<step>.<pid>/,
#   3. runs `./run -a do_tf_plan` of THAT tree in the tf-runner (`docker exec
#      -w <scratch>/csi-spl-iac`): its run.sh derives APP_PATH / PROJ_PATH from
#      its own location, so the ref's terraform, its rendered tfvars and its
#      env.json are read, and its run dir is <scratch>/csi-spl-iac/bin/...,
#      never the main checkout's (no clash with a run of the same env + step),
#   4. removes the scratch dir on every exit, success or failure.
# @description It never switches, resets or writes a tracked file of the
# @description mounted tree, and never applies:
#   - ACTION set to anything but "plan" is refused (do_tf_plan runs with
#     ACTION=provision inside, as make do-tf-plan does),
#   - ENV=prd is refused until a dev plan of the SAME sha and step exited 0
#     here; that run leaves a marker <state>/<sha>.<step>.dev.ok,
#   - the make apply targets refuse while PLAN_REF is set (tf-tasks.func.mk).
# @description The tfvars are the ref's committed render: CI's tpl-gen gate
# @description (`do_tpl_gen` then `git diff --exit-code`) keeps them equal to
# @description its cnf yaml. Steps whose terraform reads var.proj_path (036,
# @description 060, 061) show that path change in the plan: an artefact of the
# @description scratch dir, not a change of the ref.
# @param PLAN_REF - required: a branch, tag or sha the mounted tree's repo knows
# @param ENV - required: dev or prd (prd only after a clean dev plan of the sha)
# @param STEP - required: the terraform step, e.g. 070-gcp-monitoring
# @param TF_PLAN_REF_ROOT - the mounted tree on the host [default: the tf-runner's mount that holds csi-spl-iac]
# @param TF_PLAN_REF_CON_ROOT - the same tree inside the container [default: its mount destination]
# @param TF_PLAN_REF_STATE - dev-clean markers [default: ${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/tf-plan-ref]
# @param CON_TF_RUNNER - tf-runner container [default: con-<ORG>-<APP>-tf-runner]
# @example PLAN_REF=review/my-branch ENV=dev STEP=070-gcp-monitoring make do-tf-plan
# @example PLAN_REF=review/my-branch ENV=dev STEP=070-gcp-monitoring ./run -a do_tf_plan_ref
#------------------------------------------------------------------------------
do_tf_plan_ref() {
  local ref="${PLAN_REF:-}" env_name="${ENV:-}" step="${STEP:-}"
  [[ -n "$ref" ]] || { do_log "FATAL PLAN_REF is required (a branch, tag or sha)"; return 1; }
  [[ "$ref" =~ ^[A-Za-z0-9._/@^~{}-]+$ && "$ref" != -* ]] || { do_log "FATAL PLAN_REF '$ref' is not a ref name"; return 1; }
  case "$env_name" in dev|prd) ;; *) do_log "FATAL ENV must be dev or prd (got '$env_name')"; return 1 ;; esac
  [[ "$step" =~ ^[0-9]{3}-[a-z0-9-]+$ ]] || { do_log "FATAL STEP '$step' is not a terraform step name"; return 1; }
  case "${ACTION:-plan}" in
    plan) ;;
    *) do_log "FATAL REFUSED: PLAN_REF is plan-only; ACTION='${ACTION}' is not run. Land the ref, then apply from the main checkout with the owner's go."; return 1 ;;
  esac

  local orc_dir app_dir org app con
  orc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  app_dir="$(cd "$orc_dir/.." && pwd)"
  org="$(_tf_plan_ref_oap ORG "$app_dir" "$orc_dir")"
  app="$(_tf_plan_ref_oap APP "$app_dir" "$orc_dir")"
  con="${CON_TF_RUNNER:-con-${org}-${app}-tf-runner}"

  local root="${TF_PLAN_REF_ROOT:-}" con_root="${TF_PLAN_REF_CON_ROOT:-}" m
  if [[ -z "$root" ]]; then
    m="$(_tf_plan_ref_mount "$con")" || { do_log "FATAL cannot read the mounts of $con (is the tf-runner running? set TF_PLAN_REF_ROOT)"; return 1; }
    root="${m%%|*}" con_root="${con_root:-${m#*|}}"
  fi
  con_root="${con_root:-$root}"
  [[ -e "$root/.git" ]] || { do_log "FATAL $root is not a git checkout"; return 1; }

  local sha
  sha="$(git -C "$root" rev-parse --verify -q "${ref}^{commit}" 2>/dev/null)" ||
    sha="$(git -C "$root" rev-parse --verify -q "origin/${ref}^{commit}" 2>/dev/null)" ||
    { do_log "FATAL PLAN_REF '$ref' is not a commit in $root (push the branch, or fetch origin first)"; return 1; }

  local state="${TF_PLAN_REF_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/tf-plan-ref}"
  local marker="$state/$sha.$step.dev.ok"
  if [[ "$env_name" == prd && ! -f "$marker" ]]; then
    do_log "FATAL REFUSED: no clean dev plan of ${sha:0:12} STEP=$step yet. Run first: PLAN_REF=$ref ENV=dev STEP=$step make do-tf-plan"
    return 1
  fi

  # The scratch dir must be ignored by the mounted tree: an export that showed
  # in its `git status` would read as someone's untracked work.
  git -C "$root" check-ignore -q .tf-plan-ref/probe ||
    { do_log "FATAL REFUSED: .tf-plan-ref/ is not git-ignored in $root (its .gitignore predates SPL-2602: fast-forward it first)"; return 1; }

  local rel=".tf-plan-ref/${sha:0:12}.$env_name.$step.$$"
  local dir="$root/$rel" rc=0
  mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }
  # a subshell, so its EXIT trap removes the scratch dir however it ends
  (
    trap 'rm -rf "$dir"; rmdir "$root/.tf-plan-ref" 2>/dev/null' EXIT
    git -C "$root" archive --format=tar "$sha" | tar -x -C "$dir" ||
      { do_log "FATAL git archive of ${sha:0:12} failed"; exit 1; }
    [[ -d "$dir/csi-spl-iac/src/terraform/$step" ]] ||
      { do_log "FATAL ${sha:0:12} has no step $step (csi-spl-iac/src/terraform/$step)"; exit 1; }
    [[ -f "$dir/csi-spl-cnf/csi-spl/$env_name/tf/$step.vars.tfvars" ]] ||
      { do_log "FATAL ${sha:0:12} has no rendered tfvars csi-spl-cnf/csi-spl/$env_name/tf/$step.vars.tfvars"; exit 1; }
    extra=()
    if [[ "$step" == 061-gcp-vm-wine-box ]]; then
      [[ -n "${TF_VAR_iap_members:-}" ]] && extra+=(-e TF_VAR_iap_members)
      [[ -n "${TF_VAR_desktop_user_ssh_public_keys:-}" ]] && extra+=(-e TF_VAR_desktop_user_ssh_public_keys)
    fi
    do_log "INFO plan of ${sha:0:12} ($ref) ENV=$env_name STEP=$step from $rel in $con"
    docker exec "${extra[@]}" \
      -w "$con_root/$rel/csi-spl-iac" \
      -e "ORG=$org" -e "ENV=$env_name" -e "APP=${app#*-}" -e "STEP=$step" \
      -e ACTION=provision \
      -e "TF_VAR_billing_account_id=${GCP_BILLING_ACCOUNT_ID:-}" \
      "$con" ./run -a do_tf_plan
  ) || rc=$?

  if [[ $rc -eq 0 && "$env_name" == dev ]]; then
    mkdir -p "$state" && printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$ref" "$step" >"$marker"
  fi
  echo "TF_PLAN_REF $env_name $step sha=$sha ref=$ref rc=$rc"
  return "$rc"
}

# _tf_plan_ref_oap <ORG|APP> <app path> <orc dir>: that half of the naming
# pair, resolved in a clean shell exactly as the tf-tasks make targets do.
_tf_plan_ref_oap() {
  APP_PATH="$2" ORG='' APP='' bash -c 'source "$0"; do_resolve_oap "$1"; echo "${!1}"' \
    "$3/lib/bash/funcs/resolve-oap.func.sh" "$1"
}

# _tf_plan_ref_mount <container>: "<host source>|<container destination>" of
# its bind mount that holds csi-spl-iac outside the container user's home.
_tf_plan_ref_mount() {
  local line src dst
  while IFS= read -r line; do
    src="${line%%|*}" dst="${line#*|}"
    [[ -n "$src" && "$dst" != /home/* && -d "$src/csi-spl-iac" ]] && { echo "$src|$dst"; return 0; }
  done < <(docker inspect -f '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$1" 2>/dev/null)
  return 1
}
