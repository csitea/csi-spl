#!/bin/bash
#------------------------------------------------------------------------------
# @description Tests for spl-desk-cron-checkout.func.sh: the helper and its dry run.
# @example ./run -a do_test_spl_desk_cron_checkout
#------------------------------------------------------------------------------

source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh"

# Mocks
#------------------------------------------------------------------------------

mock_git() {
  case "$*" in
    "-C /fake/repo fetch -q origin master") return 0 ;;
    "-C /fake/repo worktree add -q --detach /fake/checkout origin/master") return 0 ;;
    *)
      echo "mock_git: unexpected call: $*" >&2
      return 1
      ;;
  esac
}

mock_git_fail() {
  case "$*" in
    "-C /fake/repo fetch -q origin master") return 0 ;;
    "-C /fake/repo worktree add -q --detach /fake/checkout origin/master") return 1 ;;
    *)
      echo "mock_git_fail: unexpected call: $*" >&2
      return 1
      ;;
  esac
}

mock_do_log() {
  local msg="$*"
  if [[ "$msg" == "FATAL could not create the self-updating checkout /fake/checkout" ]]; then
    return 0
  else
    echo "mock_do_log: unexpected message: $msg" >&2
    return 1
  fi
}

mock_do_log_dry() {
  local msg="$*"
  if [[ "$msg" == "INFO DRY_RUN would: git worktree add --detach /fake/checkout origin/master (the self-updating checkout)" ]]; then
    return 0
  else
    echo "mock_do_log_dry: unexpected message: $msg" >&2
    return 1
  fi
}

# Tests
#------------------------------------------------------------------------------

test_spl_desk_cron_checkout_success() {
  SPL_DESK_CRON_REPO="/fake/repo"
  git() { mock_git "$@"; }
  do_log() { mock_do_log "$@"; }

  spl_desk_cron_checkout "/fake/checkout" "master"
  local rc=$?
  assertEquals "spl_desk_cron_checkout should succeed" 0 $rc
}

test_spl_desk_cron_checkout_failure() {
  SPL_DESK_CRON_REPO="/fake/repo"
  git() { mock_git_fail "$@"; }
  do_log() { mock_do_log "$@"; }

  spl_desk_cron_checkout "/fake/checkout" "master"
  local rc=$?
  assertEquals "spl_desk_cron_checkout should fail" 1 $rc
}

test_spl_desk_cron_checkout_dry() {
  do_log() { mock_do_log_dry "$@"; }

  spl_desk_cron_checkout_dry "/fake/checkout" "master"
  local rc=$?
  assertEquals "spl_desk_cron_checkout_dry should succeed" 0 $rc
}

test_spl_desk_cron_checkout_missing_args() {
  do_log() { true; }

  spl_desk_cron_checkout "" "master"
  local rc=$?
  assertEquals "spl_desk_cron_checkout should fail on missing src" 1 $rc

  spl_desk_cron_checkout "/fake/checkout" ""
  rc=$?
  assertEquals "spl_desk_cron_checkout should fail on missing trunk" 1 $rc
}

test_spl_desk_cron_checkout_invalid_trunk() {
  do_log() { true; }

  spl_desk_cron_checkout "/fake/checkout" "invalid@branch"
  local rc=$?
  assertEquals "spl_desk_cron_checkout should fail on invalid trunk" 1 $rc
}

#------------------------------------------------------------------------------
# Load and run shunit2
#------------------------------------------------------------------------------

source "/usr/share/shunit2/shunit2"