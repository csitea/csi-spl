#!/bin/bash
#------------------------------------------------------------------------------
# @description The ONE lock that serialises every move of the self-updating
# @description <shared checkout>-desk-cron checkout (bug round 2 row 03). Up to
# @description 16 crontab lines fetch and `git checkout --detach origin/<trunk>`
# @description in that checkout, several in the same minute, while the desk
# @description reconcile tick judges "is HEAD on trunk?". Unserialised, a tick
# @description read HEAD and trunk between another line's fetch and checkout,
# @description or a half-written tree, and reported (or "recovered") a checkout
# @description that was only moving. The lock file lives in that checkout's own
# @description git directory, so every line and the tick of ONE checkout share
# @description it and two checkouts never block each other.
# @description Sourced by every install-cron action and by desk-reconcile-cron.sh;
# @description it never exits and sets no trap.
#------------------------------------------------------------------------------

# The lock file name, inside `git rev-parse --absolute-git-dir` of the checkout.
SPL_DESK_CRON_LOCK_NAME="${SPL_DESK_CRON_LOCK_NAME:-desk-cron-checkout.lock}"

#------------------------------------------------------------------------------
# @description Print the crontab prefix that moves <src> to origin/<trunk>
# @description under the lock: cd, then flock (waits up to
# @description DESK_CRON_LOCK_WAIT seconds, default 300) around fetch +
# @description checkout. It ends in "; ", so the job after it runs even when the
# @description move failed, as before (the reconcile tick reports a stuck tree).
# @param src (required) - the checkout path (SPL_DESK_CRON_SRC)
# @param trunk (required) - the trunk branch, already checked as a branch name
# @return 0
# @example pre="$(spl_desk_cron_update_pre "$src" "$trunk")"
#------------------------------------------------------------------------------
spl_desk_cron_update_pre() {
  local src="$1" trunk="$2" wait="${DESK_CRON_LOCK_WAIT:-300}"
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=300
  printf 'cd %s && flock -w %s "$(git rev-parse --absolute-git-dir)/%s" sh -c '\''git fetch -q origin %s && git checkout -q --detach origin/%s'\''; ' \
    "$src" "$wait" "$SPL_DESK_CRON_LOCK_NAME" "$trunk" "$trunk"
}

#------------------------------------------------------------------------------
# @description Print the lock file path of the checkout at <root>; nothing and
# @description rc 1 when <root> is not a git checkout.
# @param root (required) - the checkout path
# @return 0 printed, 1 not a git checkout
# @example lock="$(spl_desk_cron_lock_path "$ROOT")" || lock=""
#------------------------------------------------------------------------------
spl_desk_cron_lock_path() {
  local gd
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" && [[ -n "$gd" ]] || return 1
  printf '%s/%s\n' "$gd" "$SPL_DESK_CRON_LOCK_NAME"
}
