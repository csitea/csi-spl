#!/bin/bash
#------------------------------------------------------------------------------
# @description Switch this box's working repo from the public product repo to
# @description the private ops repo (spec 044 / SPL-61, CLE-35070). Before: the
# @description fleet pushes to OSS_PUBLIC_REPO. After: it pushes to
# @description OSS_OPS_REPO (the full tree: deploys, runners, secrets), and
# @description OSS_PUBLIC_REPO is written ONLY by do_oss_mirror.
# @description   1. OSS_OPS_REPO exists and is private (do_oss_ops_repo)
# @description   2. sync: the public master + v-tags -> ops master (fast-forward)
# @description   3. `origin` of this checkout -> OSS_OPS_REPO. The remote lives in
# @description      the COMMON git config, so every worktree of it follows
# @description   4. sync again until both masters agree (a push that raced 3)
# @description   5. a ruleset on the public master: updates, deletion and
# @description      force-push only by a deploy key (the mirror's), so a stale
# @description      push from anywhere else fails loudly instead of landing
# @description   6. GitHub Actions on in the ops repo
# @description Idempotent: a step already done is reported and skipped.
# @description Dry run unless DRY_RUN=0.
# @param OSS_OPS_REPO - required: <owner>/<repo> of the private ops repo
# @param OSS_PUBLIC_REPO - required: <owner>/<repo> of the public product repo
# @param OSS_OPS_URL, OSS_PUBLIC_URL (optional) - git URLs, default the ssh URLs of the two repos
# @param DRY_RUN (optional) - 1 (default) or 0
# @example OSS_OPS_REPO=<owner>/<app>-ops OSS_PUBLIC_REPO=<owner>/<app> ./run -a do_oss_cutover
#------------------------------------------------------------------------------

OSS_CUTOVER_RULESET="oss-mirror-only"

# oss_cutover_sync <repo dir> <public url> <ops url> - fast-forward ops master
# to the public master (and the v-tags); prints the PUBLIC master sha (the
# mirror's first base), also when ops is already ahead of it
oss_cutover_sync() {
  local repo="$1" pub="$2" ops="$3" p o
  git -C "$repo" fetch -q "$pub" "+refs/heads/master:refs/oss-cutover/public" '+refs/tags/v*:refs/tags/v*' || return 1
  git -C "$repo" fetch -q "$ops" "+refs/heads/master:refs/oss-cutover/ops" || return 1
  p=$(git -C "$repo" rev-parse refs/oss-cutover/public); o=$(git -C "$repo" rev-parse refs/oss-cutover/ops)
  if [[ "$p" != "$o" ]]; then
    git -C "$repo" merge-base --is-ancestor "$o" "$p" || {
      git -C "$repo" merge-base --is-ancestor "$p" "$o" && { echo "$p"; return 0; }
      do_log "FATAL the two masters diverged (public ${p:0:8}, ops ${o:0:8}) - resolve by hand, nothing was forced" >&2; return 1; }
    git -C "$repo" push -q "$ops" "$p:refs/heads/master" || return 1
  fi
  git -C "$repo" push -q "$ops" 'refs/tags/v*:refs/tags/v*' || return 1
  echo "$p"
}

do_oss_cutover() {
  do_require_bin git gh || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local ops="${OSS_OPS_REPO:-}" pub="${OSS_PUBLIC_REPO:-}" re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  [[ "$ops" =~ $re && "$pub" =~ $re && "$ops" != "$pub" ]] \
    || { do_log "FATAL OSS_OPS_REPO and OSS_PUBLIC_REPO must be two different <owner>/<repo> (no default)"; return 1; }
  local ops_url="${OSS_OPS_URL:-git@github.com:$ops.git}" pub_url="${OSS_PUBLIC_URL:-git@github.com:$pub.git}" repo cur
  repo=$(cd "$APP_PATH" && pwd)

  # 1.
  [[ "$(gh api "repos/$ops" --jq .private 2>/dev/null)" == true ]] \
    || { do_log "FATAL $ops is not a private repo this token can read - run do_oss_ops_repo first"; return 1; }
  cur="$(git -C "$repo" remote get-url origin)"
  do_log "INFO origin of $repo is $cur"
  if ((dry)); then
    [[ "$cur" == "$ops_url" ]] && do_log "INFO DRY_RUN origin already points at $ops" \
      || do_log "INFO DRY_RUN would: sync $pub master -> $ops, set origin to $ops_url, sync again"
    do_log "INFO DRY_RUN would: ruleset $OSS_CUTOVER_RULESET on $pub master (deploy keys only), Actions on in $ops"
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0."
    return 0
  fi

  # 2. - 4.
  local s1 s2 i
  s1=$(oss_cutover_sync "$repo" "$pub_url" "$ops_url") || { do_log "FATAL the first sync failed - origin NOT switched"; return 1; }
  do_log "OK $ops master = ${s1:0:8} (synced from $pub)"
  if [[ "$cur" != "$ops_url" ]]; then
    git -C "$repo" remote set-url origin "$ops_url" || { do_log "FATAL cannot set origin"; return 1; }
    do_log "OK origin of $repo (and every worktree of it) -> $ops_url"
  fi
  for i in 1 2 3; do
    s2=$(oss_cutover_sync "$repo" "$pub_url" "$ops_url") || { do_log "FATAL the re-sync failed (origin IS switched): re-run this action"; return 1; }
    [[ "$s2" == "$s1" ]] && break
    do_log "INFO a push raced the switch: ${s1:0:8} -> ${s2:0:8} carried into $ops"; s1="$s2"
  done
  git -C "$repo" fetch -q origin master

  # 5.
  local rid; rid="$(gh api "repos/$pub/rulesets" --jq ".[]|select(.name==\"$OSS_CUTOVER_RULESET\")|.id" 2>/dev/null)"
  if [[ -n "$rid" ]]; then
    do_log "INFO $pub already carries ruleset $OSS_CUTOVER_RULESET ($rid)"
  else
    gh api -X POST "repos/$pub/rulesets" --input - >/dev/null <<EOF || { do_log "FATAL cannot create ruleset $OSS_CUTOVER_RULESET on $pub"; return 1; }
{"name":"$OSS_CUTOVER_RULESET","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/heads/master"],"exclude":[]}},
 "rules":[{"type":"update"},{"type":"deletion"},{"type":"non_fast_forward"}],
 "bypass_actors":[{"actor_type":"DeployKey","bypass_mode":"always"}]}
EOF
    do_log "OK $pub master: only a deploy key (the mirror) may update it"
  fi

  # 6.
  gh api -X PUT "repos/$ops/actions/permissions" -F enabled=true -f allowed_actions=all >/dev/null \
    || { do_log "FATAL cannot enable Actions in $ops"; return 1; }
  do_log "OK cutover done: the box pushes to $ops (master ${s1:0:8}); next: do_oss_runners_move, then the first do_oss_mirror (OSS_MIRROR_BASE=${s1:0:8}...)"
}
