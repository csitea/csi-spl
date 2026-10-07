#!/bin/bash
#------------------------------------------------------------------------------
# @description Provision / deprovision the tenant hosts the hub DB asks for
# @description (specs/024; run by .github/workflows/40_tenant-host-reconcile.yml
# @description on a schedule, the owner's standing go of 2026-09-19). Reads
# @description tenant_hosts (rdb 0015: a trigger queues every new tenant,
# @description a delete marks it removing) as the env SA, then in ONE pass:
# @description   pending / failed, already mapped -> CHECK only: custom domain
# @description                      + WUI probe (DNS, TLS, HTTP 200) -> ready
# @description                      / failed, no terraform (dispatch c7b6e8db:
# @description                      niba-consult sat pending for a week)
# @description   pending / failed, not mapped -> add to env.dns.mapped_tenants
# @description   removing         -> drop from env.dns.mapped_tenants
# @description   (a tenant whose billing_status is unpaid is left pending)
# @description render 019 + 025, push that cnf change to the trunk from a
# @description throwaway worktree BEFORE the apply (a run that dies mid-apply
# @description leaves trunk declaring the host, and the next run completes it),
# @description plan with the destroy gate (only the removing tenants'
# @description addresses), provision, then per added tenant: custom domain
# @description wait + WUI probe -> ready (or failed + detail, retried next run);
# @description removed tenants -> removed. A host that turns ready is announced
# @description (spl_th_notify_ready). Nothing open: exits 0 before terraform.
# @description First, every run checks that each tenant with a WUI entry point
# @description in cnf (steps.052 workspaces, the enabled demo workspace) is in
# @description env.dns.mapped_tenants, and FAILS naming the missing one.
# @description Prints `open=<n>` and `apply=<n>` (the rows that need terraform)
# @description on stdout and to GITHUB_OUTPUT when set (also `pushed=1`).
# @description DRY_RUN=1 (default): list what it would do, touch nothing.
# @param ENV - dev or prd
# @param DRY_RUN (optional) - 1 (default) or 0
# @param CHECK_ONLY (optional) - 1: only the mapped rows are checked and
# @param   recorded; an unmapped or removing row is listed, never applied
# @param CNF_PUSH (optional) - 1 (default): push the cnf change to the trunk
# @param   (spl_th_cnf_push). 0: leave it uncommitted in the tree, loudly
# @param CNF_GIT_BRANCH (optional) - trunk branch, default master
# @example ENV=dev ./run -a do_spl_tenant_host_reconcile
# @example ENV=prd DRY_RUN=0 CHECK_ONLY=1 ./run -a do_spl_tenant_host_reconcile
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_tenant_host_reconcile
#------------------------------------------------------------------------------
do_spl_tenant_host_reconcile() {
  do_require_bin yq psql flock || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local cnf
  cnf="$(spl_th_cnf_file)" || return 1
  spl_th_entry_check "$cnf" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local rows
  rows="$(spl_via_proxy _spl_th_open_rows)" || { do_log "FATAL cannot read tenant_hosts in $ENV"; return 1; }
  local -a add=() chk=() del=() held=()
  local tag t st bill
  # only `row <tenant> <status> <billing>` lines: the proxy start logs to
  # stdout too, and a log line must never read as a tenant
  while read -r tag t st bill; do
    [[ "$tag" == row && -n "$t" ]] || continue
    spl_th_valid_slug "$t" 2>/dev/null || { do_log "WARN skipping invalid tenant id '$t'"; continue; }
    if [[ "$st" == removing ]]; then del+=("$t")
    elif [[ "$bill" == unpaid ]]; then held+=("$t")
    elif spl_th_cnf_has "$cnf" "$t" || spl_th_is_apex "$cnf" "$t"; then chk+=("$t")
    else add+=("$t"); fi
  done <<<"$rows"
  local open=$(( ${#add[@]} + ${#chk[@]} + ${#del[@]} )) apply=$(( ${#add[@]} + ${#del[@]} ))
  [[ "${CHECK_ONLY:-0}" == 1 ]] && apply=0
  spl_th_output open "$open"; spl_th_output apply "$apply"
  (( ${#held[@]} )) && do_log "INFO left pending (billing unpaid): ${held[*]}"
  if (( open == 0 )); then
    do_log "OK nothing to reconcile in $ENV"
    return 0
  fi
  do_log "INFO $ENV reconcile: check [${chk[*]}] add [${add[*]}] remove [${del[*]}]${CHECK_ONLY:+ CHECK_ONLY=$CHECK_ONLY}"
  if (( dry )); then
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi

  local fails=0
  for t in "${chk[@]}"; do spl_th_finish "$t" || fails=$((fails + 1)); done
  if (( apply )); then
    spl_th_reconcile_apply "$cnf" || return 1
  elif (( ${#add[@]} + ${#del[@]} )); then
    do_log "INFO CHECK_ONLY: add [${add[*]}] remove [${del[*]}] left for a full run"
  fi
  (( fails == 0 )) || { do_log "FATAL $fails tenant host(s) not ready in $ENV (tenant_hosts.status = failed, retried next run)"; return 1; }
  do_log "OK $ENV tenant hosts reconciled: check [${chk[*]}] add [${add[*]}] remove [${del[*]}]"
}

# spl_th_reconcile_apply <cnf>: the caller's add / del through cnf, the trunk,
# terraform and the finish; adds to the caller's fails.
spl_th_reconcile_apply() {
  local cnf="$1" t
  spl_th_lock || return 1
  for t in "${add[@]}"; do spl_th_cnf_set "$cnf" add "$t" || return 1; done
  for t in "${del[@]}"; do spl_th_cnf_set "$cnf" del "$t" || return 1; done
  spl_th_render || return 1
  spl_th_cnf_publish "cnf(024): $ENV tenant hosts${add[*]:+ +${add[*]}}${del[*]:+ -${del[*]}} (do_spl_tenant_host_reconcile)" || {
    for t in "${add[@]}" "${del[@]}"; do spl_th_mark_one "$t" failed "cnf push to the trunk failed"; done
    return 1
  }
  if ! spl_th_apply "$(spl_th_destroy_allow "${del[@]}")"; then
    for t in "${add[@]}" "${del[@]}"; do spl_th_mark_one "$t" failed "plan / apply refused or failed"; done
    return 1
  fi
  for t in "${del[@]}"; do spl_th_mark_one "$t" removed ""; done
  for t in "${add[@]}"; do spl_th_finish "$t" || fails=$((fails + 1)); done
}

# spl_th_output <key> <value>: key=value on stdout and to GITHUB_OUTPUT
spl_th_output() {
  printf '%s=%s\n' "$1" "$2"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  return 0
}

_spl_th_open_rows() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT 'row', h.tenant_id, h.status, coalesce(t.billing_status, '-')
  FROM tenant_hosts h LEFT JOIN tenants t USING (tenant_id)
 WHERE h.status IN ('pending', 'failed', 'removing')
 ORDER BY h.requested_at, h.tenant_id;
ROLLBACK;
SQL
}

# spl_th_entry_check <env cnf file> (dispatch c7b6e8db, option 6): every
# tenant the WUI has an entry point for, as cnf states it (all.env.yaml merged
# under the env file): the steps.052 workspaces and, while env.demo is
# enabled, env.demo.workspace, must be in env.dns.mapped_tenants (the apex
# tenant excepted) wherever steps.019 wui_tenant_hosts is on. demo sat out of
# the list for 2 days while its WUI sent visitors to demo.<fqdn>.
spl_th_entry_check() {
  local f="$1" all out
  all="$(dirname "$f")/all.env.yaml"
  [[ -f "$all" ]] || { do_log "FATAL no $all next to $f"; return 1; }
  out="$(yq eval-all '. as $i ireduce ({}; . * $i) | .env as $e
    | select($e.steps."019-firebase-static-site".wui_tenant_hosts == true)
    | ($e.steps."052-gcs-workspace-docs".workspaces // []) as $docs
    | ([$e.demo | select(.enabled == true) | .workspace]) as $demo
    | (($docs + $demo) - ($e.dns.mapped_tenants // [])) - [$e.steps."019-firebase-static-site".wui_default_tenant]
    | unique | .[]' "$all" "$f")" ||
    { do_log "FATAL cannot read the WUI entry points of $f"; return 1; }
  [[ -z "$out" ]] && return 0
  do_log "FATAL WUI entry point(s) not in env.dns.mapped_tenants of $f: $(tr '\n' ' ' <<<"$out")- map each with ENV=$ENV TENANT_ID=<id> DRY_RUN=0 ./run -a do_spl_tenant_host_provision"
  return 1
}

# spl_th_cnf_publish <message>: spl_th_cnf_push, or with CNF_PUSH=0 a loud
# warning that the trunk does not declare the hosts the apply is about to make.
spl_th_cnf_publish() {
  [[ "${CNF_PUSH:-1}" == 1 ]] && { spl_th_cnf_push "$1"; return; }
  do_log "WARN CNF_PUSH=0: the cnf edit stays UNCOMMITTED in $APP_PATH and the trunk does not declare it; the next render from trunk drops it"
}

# spl_th_cnf_paths: the env's cnf file and the files rendered from it
spl_th_cnf_paths() {
  printf '%s\n' "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV.env.yaml" "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV.env.json" \
    "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf/019-firebase-static-site.vars.tfvars" \
    "$SPL_ORG_APP-cnf/$SPL_ORG_APP/$ENV/tf/025-gcp-dns-zone.vars.tfvars"
}

# (th_msg, never msg: do_log assigns a global msg, which bash's dynamic scope
# lets overwrite a caller's local - the dev demo cnf commit 2691e80d carried a
# log line as its message.)
# spl_th_cnf_push <message> -> lands this run's edit of the env's cnf +
# rendered files on the trunk, and fails loudly (non-zero) when it cannot.
# The tree the tf-runner mounts keeps the edit (the apply needs it) and is
# never committed in: the edit is replayed onto origin/<br> in a THROWAWAY
# worktree (_spl_th_wt_apply), committed as the identity the trunk's
# own cnf history carries (no literal in the tree, no AI trailer), pushed,
# rebased + retried on a race. Landed is read from merge-base, never the push
# text. A local commit of those paths that the trunk lacks is refused (the
# aleko-gik hour). Afterwards the tree is brought onto the trunk
# (spl_th_root_sync). Sets SPL_TH_PUSHED to the landed sha.
spl_th_cnf_push() {
  local th_msg="$1" br="${CNF_GIT_BRANCH:-master}" root tmp rc
  root="$(git -C "$APP_PATH" rev-parse --show-toplevel)" || return 1
  local -a paths; mapfile -t paths < <(spl_th_cnf_paths)
  git -C "$root" fetch -q origin "$br" || { do_log "FATAL CNF push: cannot fetch origin/$br"; return 1; }
  local ahead
  ahead="$(git -C "$root" log --format='%h %s' "origin/$br..HEAD" -- "${paths[@]}")"
  [[ -z "$ahead" ]] || { do_log "FATAL CNF push: $root has local commit(s) of the $ENV cnf that origin/$br lacks - push or drop them first: $(tr '\n' ';' <<<"$ahead")"; return 1; }
  if git -C "$root" diff --quiet "origin/$br" -- "${paths[@]}"; then
    do_log "INFO cnf already equals origin/$br: nothing to push"; return 0
  fi
  # next to the checkout, on its filesystem: under /tmp the pre-push gate's
  # pnpm install picks /tmp/.pnpm-store, owned by another user (EACCES, the
  # wui part red on all 5 tries, dev demo 2026-10-07)
  tmp="$(mktemp -d -p "${SPL_TH_WT_DIR:-$(dirname "$root")}" ".${root##*/}-cnf-push.XXXXXX")" || return 1
  git -C "$root" diff --binary HEAD -- "${paths[@]:1}" >"$tmp/render.patch" || { rm -rf "$tmp"; return 1; }
  git -C "$root" worktree add -q --detach "$tmp/wt" "origin/$br" 2>"$tmp/err" ||
    { do_log "FATAL CNF push: cannot add a throwaway worktree: $(cat "$tmp/err")"; rm -rf "$tmp"; return 1; }
  do_log "INFO cnf push from the throwaway worktree $tmp/wt (origin/$br)"
  _spl_th_push_in "$tmp" "$br" "$th_msg" "$root"; rc=$?
  git -C "$root" worktree remove --force "$tmp/wt" 2>/dev/null; git -C "$root" worktree prune 2>/dev/null
  rm -rf "$tmp"
  (( rc == 0 )) || return "$rc"
  spl_th_root_sync "$root" "$br" "${paths[@]}"
  return 0
}

# _spl_th_push_in <tmp> <br> <message> <root>: commit + push from <tmp>/wt,
# up to 5 tries; the push's own output is shown when the last one fails.
_spl_th_push_in() {
  local tmp="$1" br="$2" th_msg="$3" root="$4" wt="$1/wt" name email i
  name="$(git -C "$wt" log -1 --no-mailmap --format=%an -- "$SPL_ORG_APP-cnf")"
  email="$(git -C "$wt" log -1 --no-mailmap --format=%ae -- "$SPL_ORG_APP-cnf")"
  [[ -n "$name" && -n "$email" && "$email" != *noreply* ]] || { do_log "FATAL CNF push: cannot read the cnf author from the history"; return 1; }
  local -a id=(-c "user.name=$name" -c "user.email=$email")
  for i in 1 2 3 4 5; do
    git -C "$wt" reset -q --hard "origin/$br" || return 1
    _spl_th_wt_apply "$tmp" "$root" || return 1
    if git -C "$wt" diff --cached --quiet; then
      do_log "OK cnf already on origin/$br: nothing to push"; return 0
    fi
    git -C "$wt" "${id[@]}" commit -q -m "$th_msg" || { do_log "FATAL CNF push: commit failed"; return 1; }
    git -C "$wt" push origin "HEAD:$br" >"$tmp/push.out" 2>&1
    git -C "$wt" fetch -q origin "$br"
    if git -C "$wt" merge-base --is-ancestor HEAD "origin/$br"; then
      SPL_TH_PUSHED="$(git -C "$wt" rev-parse HEAD)"
      do_log "OK cnf pushed: ${SPL_TH_PUSHED:0:9} $th_msg"
      spl_th_output pushed 1 >/dev/null
      return 0
    fi
    do_log "INFO push $i did not land on $br ($(grep -E 'rejected|error|FATAL' "$tmp/push.out" | tail -2 | tr '\n' ' ')); retrying"
    sleep $((i * ${SPL_TH_PUSH_BACKOFF:-3}))
  done
  do_log "FATAL CNF push: the $ENV cnf commit did not land on $br after 5 tries (the edit is still uncommitted in $root): $(tail -5 "$tmp/push.out" | tr '\n' ' ')"
  return 1
}

# _spl_th_wt_apply <tmp> <root>: in <tmp>/wt, at origin/<br>: the env yaml
# gets the same mapped_tenants adds / dels the root tree has against its HEAD
# (spl_th_cnf_set, so a tenant the trunk gained meanwhile is kept and nobody
# else's uncommitted line rides along); the rendered files are root's when the
# two yamls are now byte-equal (same render input), else root's render diff
# applied 3-way. A conflict FAILS: render again from an up-to-date checkout.
_spl_th_wt_apply() {
  local tmp="$1" root="$2" wt="$1/wt" y t
  local -a paths; mapfile -t paths < <(spl_th_cnf_paths)
  y="${paths[0]}"
  local head work
  head=" $(git -C "$root" show "HEAD:$y" 2>/dev/null | yq -r '(.env.dns.mapped_tenants // [])[]' | tr '\n' ' ') "
  work=" $(yq -r '(.env.dns.mapped_tenants // [])[]' "$root/$y" | tr '\n' ' ') "
  for t in $work; do [[ "$head" == *" $t "* ]] || spl_th_cnf_set "$wt/$y" add "$t" >/dev/null || return 1; done
  for t in $head; do [[ "$work" == *" $t "* ]] || spl_th_cnf_set "$wt/$y" del "$t" >/dev/null || return 1; done
  if cmp -s "$wt/$y" "$root/$y"; then
    for t in "${paths[@]:1}"; do [[ -f "$root/$t" ]] && cp "$root/$t" "$wt/$t"; done
  elif [[ -s "$tmp/render.patch" ]]; then
    git -C "$wt" apply --3way "$tmp/render.patch" 2>"$tmp/err" ||
      { do_log "FATAL CNF push: the $ENV render does not apply onto origin/$br (render again from an up-to-date checkout): $(tr '\n' ' ' <"$tmp/err")"; return 1; }
  fi
  git -C "$wt" add -- "${paths[@]}"
}

# spl_th_root_sync <root> <br> <path...>: the tree that kept the edit is
# brought onto the trunk that now holds it, so it is clean again and a later
# `git merge --ff-only` is not refused over those paths. Only when it is on
# <br>, has no other change, and each path already equals origin/<br>;
# otherwise it is left as it is (logged). Content never changes.
spl_th_root_sync() {
  local root="$1" br="$2"; shift 2
  local p other
  [[ "$(git -C "$root" symbolic-ref -q --short HEAD)" == "$br" ]] || { do_log "INFO $root is not on $br: its cnf edit stays uncommitted (same content as the trunk)"; return 0; }
  for p in "$@"; do
    git -C "$root" diff --quiet "origin/$br" -- "$p" || { do_log "INFO $root $p differs from origin/$br: left uncommitted"; return 0; }
  done
  other="$(git -C "$root" status --porcelain --untracked-files=no -- . "${@/#/:!}")"
  [[ -z "$other" ]] || { do_log "INFO $root has other changes: its cnf edit stays uncommitted (same content as the trunk)"; return 0; }
  git -C "$root" checkout -q -- "$@" &&
    git -C "$root" merge -q --ff-only "origin/$br" 2>/dev/null && { do_log "INFO $root fast-forwarded onto origin/$br"; return 0; }
  git -C "$root" restore --source="origin/$br" --worktree -- "$@"
  do_log "INFO $root could not fast-forward onto origin/$br: its cnf edit stays uncommitted (same content as the trunk)"
}
