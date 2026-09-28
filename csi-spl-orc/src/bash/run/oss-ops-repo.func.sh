#!/bin/bash
#------------------------------------------------------------------------------
# @description Stand up the PRIVATE ops repo of the open-source split (spec 044,
# @description SPL-61, CLE-35070): the public repo carries the product only
# @description (the do_oss_export projection, published by do_oss_mirror), and
# @description the ops repo carries the whole working tree - cnf, iac, orc, doc,
# @description the deploy workflows, the agent instructions - plus the deploy
# @description secrets and the self-hosted runners. Idempotent; each step is
# @description skipped when already done:
# @description   1. create OSS_OPS_REPO private, with GitHub Actions DISABLED
# @description      (nothing runs there before the cutover: OSS_OPS_ACTIONS=1
# @description      enables them)
# @description   2. push OSS_REF as its master (fast-forward only) and every
# @description      v<X.Y.Z> tag (do_release_version keeps counting from them)
# @description   3. the environments dev and prd (the deploy jobs name them)
# @description   4. the secrets GCP_KEY_<ORG>_<APP>_<ENV> from the per-env key
# @description      files, read by `gh secret set` on stdin exactly as iac 120
# @description      does (the value is never printed, logged or put in argv)
# @description   5. the mirror credential: a fresh ed25519 key, its public half a
# @description      WRITE deploy key on OSS_PUBLIC_REPO (title oss-mirror), its
# @description      private half the ops secret OSS_MIRROR_DEPLOY_KEY; the local
# @description      copy is removed. Skipped while the deploy key exists.
# @description Needs gh with repo + workflow scope (GH_TOKEN or a gh login).
# @description Dry run unless DRY_RUN=0: prints what each step would do.
# @param OSS_OPS_REPO - required: <owner>/<repo> of the private ops repo
# @param OSS_PUBLIC_REPO - required: <owner>/<repo> of the public product repo
# @param OSS_REF (optional) - what becomes ops master, default origin/master
# @param OSS_OPS_ACTIONS (optional) - 0 (default) keeps Actions disabled, 1 enables them
# @param OSS_KEY_DIR (optional) - default ~/.gcp/.<org>, the per-env SA keys
# @param DRY_RUN (optional) - 1 (default) or 0
# @example OSS_OPS_REPO=<owner>/<app>-ops OSS_PUBLIC_REPO=<owner>/<app> ./run -a do_oss_ops_repo
#------------------------------------------------------------------------------
do_oss_ops_repo() {
  do_require_bin git gh ssh-keygen || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local ops="${OSS_OPS_REPO:-}" pub="${OSS_PUBLIC_REPO:-}" ref="${OSS_REF:-origin/master}"
  local re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  [[ "$ops" =~ $re ]] || { do_log "FATAL OSS_OPS_REPO must be <owner>/<repo> (no default), got: '$ops'"; return 1; }
  [[ "$pub" =~ $re ]] || { do_log "FATAL OSS_PUBLIC_REPO must be <owner>/<repo> (no default), got: '$pub'"; return 1; }
  [[ "$ops" != "$pub" ]] || { do_log "FATAL OSS_OPS_REPO and OSS_PUBLIC_REPO are the same repo"; return 1; }
  local sha; sha="$(git -C "$APP_PATH" rev-parse --verify -q "$ref^{commit}")" \
    || { do_log "FATAL OSS_REF '$ref' is not a commit"; return 1; }
  # <org>-<app> from this project's own dir name (<org>-<app>-orc), which is
  # the same in the main checkout and in a worktree
  local oa org app; oa="$(basename "${PROJ_PATH:-$APP_PATH/x-orc}")"; oa="${oa%-orc}"
  org="${oa%%-*}"; app="${oa#*-}"
  local keydir="${OSS_KEY_DIR:-$HOME/.gcp/.$org}"
  _oss_run() { if ((dry)); then do_log "INFO DRY_RUN would: $*"; else "$@"; fi; }

  # 1. the repo, private, Actions off until the cutover
  local priv
  if priv="$(gh api "repos/$ops" --jq .private 2>/dev/null)"; then
    [[ "$priv" == true ]] || { do_log "FATAL $ops exists and is NOT private - refusing to put ops there"; return 1; }
    do_log "INFO $ops exists and is private"
  else
    _oss_run gh repo create "$ops" --private --disable-wiki --disable-issues \
      --description "Private ops of $pub: cnf, iac, orc, deploy workflows" >/dev/null || return 1
    ((dry)) || do_log "OK created $ops (private)"
  fi
  local actions=false; [[ "${OSS_OPS_ACTIONS:-0}" == 1 ]] && actions=true
  _oss_run gh api -X PUT "repos/$ops/actions/permissions" -F enabled="$actions" >/dev/null || return 1
  do_log "INFO $ops GitHub Actions enabled=$actions"

  # 2. master + the release tags (fast-forward only: never rewrite ops history)
  local url="git@github.com:$ops.git"
  _oss_run git -C "$APP_PATH" push -q "$url" "$sha:refs/heads/master" \
    || { do_log "FATAL push of ${sha:0:8} to $ops master refused (not a fast-forward?)"; return 1; }
  _oss_run git -C "$APP_PATH" push -q "$url" 'refs/tags/v*:refs/tags/v*' \
    || { do_log "FATAL push of the v-tags to $ops failed"; return 1; }
  ((dry)) || do_log "OK $ops master = ${sha:0:8}, v-tags pushed"

  # 3. environments
  local e
  for e in dev prd; do _oss_run gh api -X PUT "repos/$ops/environments/$e" >/dev/null || return 1; done

  # 4. the deploy key secrets, stdin only
  local have; have="$(gh api "repos/$ops/actions/secrets" --jq '.secrets[].name' 2>/dev/null)"
  for e in dev prd; do
    local name="GCP_KEY_${org^^}_${app^^}_${e^^}" f="$keydir/key-$org-$app-$e.json"
    if [[ ! -f "$f" ]]; then do_log "WARN no key file for $e ($f): $name is not set, the $e deploy will be skipped"; continue; fi
    if ((dry)); then
      do_log "INFO DRY_RUN would: gh secret set $name --repo $ops < $f$(grep -qx "$name" <<<"$have" && echo ' (replaces the existing one)')"
      continue
    fi
    gh secret set "$name" --repo "$ops" <"$f" >/dev/null || { do_log "FATAL gh secret set $name failed"; return 1; }
    do_log "OK $ops secret $name set from the $e key file"
  done

  # 5. the mirror's write credential on the public repo
  if gh api "repos/$pub/keys" --jq '.[].title' 2>/dev/null | grep -qx oss-mirror; then
    do_log "INFO $pub already has the oss-mirror deploy key - not re-minted (delete it to rotate)"
  elif ((dry)); then
    do_log "INFO DRY_RUN would: mint an ed25519 key, add it to $pub as the WRITE deploy key oss-mirror, and store the private half as $ops secret OSS_MIRROR_DEPLOY_KEY"
  else
    local kd rc=0; kd="$(mktemp -d)"; chmod 700 "$kd"
    ssh-keygen -q -t ed25519 -N '' -C oss-mirror -f "$kd/k" || { rm -rf "$kd"; return 1; }
    gh secret set OSS_MIRROR_DEPLOY_KEY --repo "$ops" <"$kd/k" >/dev/null \
      && gh api -X POST "repos/$pub/keys" -f title=oss-mirror -f key="$(cat "$kd/k.pub")" -F read_only=false >/dev/null \
      || rc=$?
    shred -u "$kd/k" 2>/dev/null; rm -rf "$kd"
    ((rc == 0)) || { do_log "FATAL the mirror deploy key was not installed (rc=$rc)"; return 1; }
    do_log "OK $pub deploy key oss-mirror (write) + $ops secret OSS_MIRROR_DEPLOY_KEY"
  fi
  do_log "OK ops repo $ops ready$( ((dry)) && echo ' (DRY_RUN: nothing changed; DRY_RUN=0 applies)')"
}
