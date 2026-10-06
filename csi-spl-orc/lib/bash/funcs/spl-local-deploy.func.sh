#!/bin/bash
#------------------------------------------------------------------------------
# Shared half of the LOCAL cloud deploys (do_deploy_hub, do_deploy_wui): ship
# one trunk commit to a cloud env from a box, with no GitHub workflow in the
# path (owner order 2026-10-06, t1 916c8696: "Deploy either from the SAT or
# from the Think box"). The two actions call the SAME orc actions the deploy
# jobs of workflows 20 and 30 call; this file only holds what both need:
#   - the commit: SHA (default origin/<trunk> head), refused unless it is on
#     origin/<trunk> -- only landed trunk code ships
#   - a clean checkout of exactly that commit (a detached git worktree), so a
#     lane's uncommitted work never lands in an image or a bundle
#   - one deploy per <component, env> per box at a time (flock); across boxes
#     the release tag (pushed, the remote is the lock) and the hub's
#     forward-only guard keep two deploys from fighting
#   - the env's project SA (do_gcp_pin_account): its key in a throwaway
#     CLOUDSDK_CONFIG, never the owner account, never ~/.config/gcloud
#------------------------------------------------------------------------------

# spl_ld_trunk -> the trunk branch name (RELEASE_TRUNK, default master)
spl_ld_trunk() { printf '%s' "${RELEASE_TRUNK:-master}"; }

# spl_ld_resolve_sha -> the full sha to deploy on stdout: SHA, else the head of
# origin/<trunk> after a fetch. rc 1 (FATAL) when it is not a commit or not an
# ancestor of origin/<trunk>.
spl_ld_resolve_sha() {
  local trunk remote="${RELEASE_REMOTE:-origin}" want sha
  trunk="$(spl_ld_trunk)"
  git -C "$APP_PATH" fetch -q "$remote" "$trunk" 2>/dev/null ||
    { do_log "FATAL cannot fetch $remote $trunk" >&2; return 1; }
  want="${SHA:-$remote/$trunk}"
  sha="$(git -C "$APP_PATH" rev-parse --verify -q "$want^{commit}")" ||
    { do_log "FATAL not a commit: '$want'" >&2; return 1; }
  git -C "$APP_PATH" merge-base --is-ancestor "$sha" "$remote/$trunk" ||
    { do_log "FATAL ${sha:0:12} is not on $remote/$trunk: only a landed trunk commit is deployed" >&2; return 1; }
  printf '%s' "$sha"
}

# spl_ld_lock <component> -> holds an exclusive flock on fd 9 for
# <component>-<ENV> until the action's shell exits. rc 1 when another deploy
# holds it after DEPLOY_LOCK_WAIT_S (default 0: refuse at once).
spl_ld_lock() {
  local comp="$1" dir file wait="${DEPLOY_LOCK_WAIT_S:-0}"
  dir="${DEPLOY_LOCK_DIR:-${TMPDIR:-/tmp}/$SPL_ORG_APP-deploy-lock}"
  mkdir -p "$dir" 2>/dev/null && chmod 1777 "$dir" 2>/dev/null
  file="$dir/$comp-$ENV.lock"
  exec 9>>"$file" || { do_log "FATAL cannot open the deploy lock $file"; return 1; }
  if ! flock -w "$wait" 9; then
    do_log "FATAL another $comp deploy to $ENV holds $file ($(cat "$file.who" 2>/dev/null || echo unknown)): wait for it, or DEPLOY_LOCK_WAIT_S=<s>"
    return 1
  fi
  printf '%s pid %s since %s\n' "${USER:-?}" "$$" "$(date -u +%FT%TZ)" >"$file.who" 2>/dev/null || true
}

# spl_ld_checkout <sha> -> sets SPL_LD_WT to a detached worktree of <sha>
# (removed again by spl_ld_cleanup). DEPLOY_WORK_DIR names the parent.
spl_ld_checkout() {
  local sha="$1" parent wt
  parent="${DEPLOY_WORK_DIR:-${TMPDIR:-/tmp}/$SPL_ORG_APP-deploy}"
  mkdir -p "$parent" || return 1
  wt="$(mktemp -d "$parent/${ENV}-${sha:0:8}-XXXX")" || return 1
  rmdir "$wt"
  git -C "$APP_PATH" worktree add -q --detach "$wt" "$sha" >/dev/null 2>&1 ||
    { do_log "FATAL git worktree add $wt ${sha:0:12} failed"; return 1; }
  SPL_LD_WT="$wt"
}

# spl_ld_cleanup -> remove the worktree spl_ld_checkout made (KEEP_WORKTREE=1 keeps it)
spl_ld_cleanup() {
  [[ -n "${SPL_LD_WT:-}" && -d "$SPL_LD_WT" ]] || return 0
  if [[ "${KEEP_WORKTREE:-0}" == 1 ]]; then do_log "INFO kept the deploy checkout $SPL_LD_WT"; return 0; fi
  git -C "$APP_PATH" worktree remove --force "$SPL_LD_WT" >/dev/null 2>&1 || rm -rf "$SPL_LD_WT"
  git -C "$APP_PATH" worktree prune >/dev/null 2>&1 || true
}

# spl_ld_user_bins -> put the user's own tool dirs ($HOME/.local/bin, $HOME/bin:
# pnpm, cloud-sql-proxy) on PATH; a `sudo -u <user> env ...` shell lacks them.
spl_ld_user_bins() {
  local d
  for d in "$HOME/bin" "$HOME/.local/bin"; do
    [[ -d "$d" && ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"
  done
  export PATH
}

# spl_ld_go_on_path -> make `go` callable (the hub migrate builds the host
# spool CLI): when it is not on PATH, the newest /usr/local/go*/bin is added.
spl_ld_go_on_path() {
  command -v go >/dev/null && return 0
  local d
  d="$(find /usr/local -maxdepth 1 -name 'go*' -type d 2>/dev/null | sort -V | tail -1)"
  [[ -n "$d" && -x "$d/bin/go" ]] || { do_log "FATAL no go on PATH (the migrate step builds the spool CLI)"; return 1; }
  export PATH="$d/bin:$PATH"
}

# spl_ld_run <wt> <action> [VAR=value]... -> run <action> of the checkout's own
# orc (the code of the commit being deployed, as a CI checkout does)
spl_ld_run() {
  local wt="$1" action="$2"; shift 2
  (cd "$wt" && env "$@" ./csi-spl-orc/run -a "$action")
}

# spl_ld_mint <wt> <sha> -> sets SPL_LD_VERSION (X.Y.Z) and SPL_LD_KEY (the
# release key = the image tag) via do_release_version DRY_RUN=0, which pushes
# the v-tag (or re-reads the one the commit has). rc 3: the commit's
# .github/workflows differs from trunk head's -- deploy trunk head instead.
spl_ld_mint() {
  local wt="$1" sha="$2" out rc=0
  out="$(mktemp)" || return 1
  spl_ld_run "$wt" do_release_version DRY_RUN=0 RELEASE_SHA="$sha" GITHUB_OUTPUT="$out" >/dev/null || rc=$?
  if grep -qx 'stale=true' "$out"; then
    rm -f "$out"
    do_log "FATAL ${sha:0:12} cannot be tagged: its .github/workflows differs from trunk head's -- deploy trunk head instead"
    return 3
  fi
  SPL_LD_VERSION="$(sed -n 's/^version=//p' "$out" | tail -1)"
  SPL_LD_KEY="$(sed -n 's/^key=//p' "$out" | tail -1)"
  rm -f "$out"
  ((rc == 0)) || { do_log "FATAL do_release_version failed (rc $rc)"; return 1; }
  [[ "$SPL_LD_VERSION" =~ ^[0-9]\.[0-9]\.[0-9]$ ]] || { do_log "FATAL no release version minted"; return 1; }
  [[ "$SPL_LD_KEY" == "$SPL_LD_VERSION" || "$SPL_LD_KEY" =~ ^$SPL_LD_VERSION-c[0-9]+$ ]] ||
    { do_log "FATAL no release key minted for $SPL_LD_VERSION (got '$SPL_LD_KEY')"; return 1; }
}

# spl_ld_predict <wt> <sha> -> the version a mint WOULD claim (dry run, no push)
spl_ld_predict() {
  spl_ld_run "$1" do_release_version DRY_RUN=1 RELEASE_SHA="$2" 2>/dev/null | grep -xE '[0-9]\.[0-9]\.[0-9]' | tail -1
}

# spl_ld_served <url> <field> -> the JSON string <field> the url serves, "" when unread
spl_ld_served() {
  curl -fsS --max-time 15 -H 'Cache-Control: no-cache' "$1" 2>/dev/null |
    jq -r --arg f "$2" 'if type == "object" and (.[$f] | type) == "string" then .[$f] else "" end' 2>/dev/null
}
