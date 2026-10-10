#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the harness-agnostic force-push matcher
# (features/spawn-agents/lib/force-push-guard.inc.sh), every form:
#   1. each forbidden push form is refused: rc 2, one "force-push-guard:
#      refused:" line on stderr - bare, combined flags, +refspecs, deletes of
#      master, git -c smuggling, SPL_PREPUSH_OVERRIDE, and every wrapper
#      (bash -c, sh -c, env, sudo, eval, git -C / -c, $( ), backticks, &&, ;)
#      and the skip-hooks forms: git push --no-verify (and its prefixes), git
#      -c / --config-env core.hooksPath, GIT_CONFIG_KEY_<n>=core.hooksPath
#   2. the allowed forms pass: rc 0, nothing on stderr - a plain push to
#      master, a feature-branch delete, read-only git, commit messages that
#      only mention push, SPL_PREPUSH_OVERRIDE=0
#   3. the direct CLI form (--check) answers the same, and a bad call is 64
#   4. fail closed: with no python3 on PATH even a plain push is refused
# Control: a matcher that allows everything fails every case in 1.
#------------------------------------------------------------------------------
# shellcheck disable=SC2016,SC1091  # the cases are literal commands, never expanded
set -uo pipefail
G="$(cd "$(dirname "$0")/../features/spawn-agents/lib" && pwd)/force-push-guard.inc.sh"
# shellcheck source=../features/spawn-agents/lib/force-push-guard.inc.sh
. "$G"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }

refuse() {  # <command>
  local err rc
  err="$(force_push_guard_check "$1" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 2 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && [[ "$err" == "force-push-guard: refused: "* ]]
  then pass "refused: $1"; else fail "should refuse (rc=$rc err=$err): $1"; fi
}
allow() {  # <command>
  local err rc
  err="$(force_push_guard_check "$1" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" = 0 ] && [ -z "$err" ]; then pass "allowed: $1"; else fail "should allow (rc=$rc err=$err): $1"; fi
}

# 1. forbidden
refuse 'git push --force origin HEAD:master'
refuse 'git push origin HEAD:master --force'
refuse 'git push -f origin master'
refuse 'git push -uf origin master'
refuse 'git push -fu origin HEAD:master'
refuse 'git push --force-with-lease origin HEAD:master'
refuse 'git push --force-with-lease=master:abc123 origin HEAD:master'
refuse 'git push --force-if-includes origin HEAD:master'
refuse 'git push --mirror origin'
refuse 'git push origin +HEAD:master'
refuse 'git push origin +master'
refuse 'git push origin main +HEAD:master'
refuse 'git push origin :master'
refuse 'git push origin :refs/heads/master'
refuse 'git push --delete origin master'
refuse 'git push -d origin master'
refuse 'git push origin --delete refs/heads/master'
refuse 'SPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master'
refuse 'export SPL_PREPUSH_OVERRIDE=1; git push origin HEAD:master'
refuse 'env SPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master'
refuse 'SPL_PREPUSH_OVERRIDE="1" git push'
refuse 'SPL_PREPUSH_OVERRIDE=yes git push'
refuse 'sudo -u agentusr bash -c "SPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master"'
refuse 'declare -x SPL_PREPUSH_OVERRIDE=1; git push origin HEAD:master'
refuse 'typeset -x SPL_PREPUSH_OVERRIDE=yes'
refuse 'export FOO=1 SPL_PREPUSH_OVERRIDE=1'
refuse 'bash -c "env SPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master"'
# untokenizable (an unclosed quote): refused only where a push can hide
refuse 'git push --force origin master "unclosed'
refuse 'git -C repo push origin "unclosed'
refuse 'SPL_PREPUSH_OVERRIDE=1 git commit -m "unclosed'
refuse 'bash -c "git push --force origin HEAD:master"'
refuse "sh -c 'git push -f origin master'"
refuse "bash -lc 'cd /x && git push --force-with-lease origin HEAD:master'"
refuse 'sudo -u agentusr bash -c "cd /opt/x && git push origin HEAD:master --force"'
refuse 'sudo -u agentusr git push -f origin master'
refuse 'sudo -u agentusr git -C /opt/csi/x push --force origin HEAD:master'
refuse 'env GIT_TRACE=1 git push --force origin master'
refuse 'env -i PATH=/usr/bin /usr/bin/git push --force origin master'
refuse 'command git push -f'
refuse 'nohup git push -f origin master &'
refuse 'timeout 60 git push --force origin master'
refuse 'eval "git push --force origin master"'
refuse 'git -c user.name=x -c user.email=y push --force origin HEAD:master'
refuse 'git -C /opt/x -c core.pager=cat push -f'
refuse 'git -c remote.origin.push=+HEAD:master push origin'
refuse 'git -c remote.origin.mirror=true push origin'
refuse "git -c alias.p='push --force' p origin master"
refuse "git -c 'alias.p=!git push -f' p"
refuse 'cd /opt/x && git fetch && git push -f origin master'
refuse 'git status; git push --force origin master'
refuse 'true || git push --force origin master'
refuse 'echo $(git push --force origin master)'
refuse 'echo `git push --force origin master`'
refuse 'git status
git push --force origin master'
refuse "su agentusr -c 'git push --force origin master'"
refuse "ssh box 'cd /opt/x && git push --force origin master'"
refuse 'env -S "git push --force origin master"'
refuse 'git push --force'
refuse 'git push "unterminated --force'
# skip-hooks: each one skips the pre-push hook, whatever the refspec
refuse 'git push --no-verify origin HEAD:master'
refuse 'git push origin HEAD:master --no-verify'
refuse 'git push --no-veri origin HEAD:master'
refuse 'git push -u --no-verify origin c-792-branch'
refuse 'git -C /opt/x push --no-verify origin HEAD:master'
refuse 'sudo -u agentusr git -C /opt/x push --no-verify origin HEAD:master'
refuse 'sudo -u agentusr bash -c "cd /opt/x && git push --no-verify origin HEAD:master"'
refuse "bash -lc 'git push --no-verify'"
refuse 'env GIT_TRACE=1 git push --no-verify'
refuse 'eval "git push --no-verify origin HEAD:master"'
refuse 'timeout 60 git push --no-verify origin HEAD:master'
refuse 'nohup git push --no-verify origin HEAD:master &'
refuse "ssh box 'cd /opt/x && git push --no-verify origin HEAD:master'"
refuse "su agentusr -c 'git push --no-verify origin HEAD:master'"
refuse 'echo $(git push --no-verify origin HEAD:master)'
refuse 'echo `git push --no-verify origin HEAD:master`'
refuse 'git fetch && git rebase origin/master && git push --no-verify origin HEAD:master'
refuse 'git status; git push --no-verify'
refuse 'false || git push --no-verify'
refuse 'git status
git push --no-verify origin HEAD:master'
refuse "git -c alias.p='push --no-verify' p origin HEAD:master"
refuse 'git -c core.hooksPath=/dev/null push origin HEAD:master'
refuse 'git -c core.hookspath= push'
refuse 'git -c CORE.HOOKSPATH=/tmp/none -C /opt/x push origin HEAD:master'
refuse 'sudo -u agentusr git -c core.hooksPath=/dev/null push origin HEAD:master'
refuse 'bash -c "git -c core.hooksPath=/dev/null push origin HEAD:master"'
refuse 'git --config-env=core.hooksPath=NOHOOKS push origin HEAD:master'
refuse 'git --config-env core.hooksPath=NOHOOKS push origin HEAD:master'
refuse 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git push origin HEAD:master'
refuse 'env GIT_CONFIG_PARAMETERS="'"'core.hooksPath=/dev/null'"'" git push'
refuse 'git push --mirr origin'
refuse 'git push --forc origin HEAD:master'

# 2. allowed
allow 'git push origin HEAD:master'
allow 'git push'
allow 'git push origin c-766-branch'
allow 'git push origin --delete c-766-branch'
allow 'git push origin :c-766-branch'
allow 'git push -u origin c-766-branch'
allow 'git push origin v1.2.3'
allow 'git push --no-force-with-lease origin HEAD:master'
allow 'sudo -u agentusr git -C /opt/csi/x push origin HEAD:master'
allow "sudo -u agentusr bash -c 'cd /opt/x && git push origin HEAD:master'"
allow 'git log --oneline -5'
allow 'git fetch --force origin'
allow 'git commit -m "doc: never git push --force to master"'
allow 'echo "git push -f is forbidden"'
allow 'grep -rn force-with-lease docs/'
allow 'SPL_PREPUSH_OVERRIDE=0 git push origin HEAD:master'
# false positives, the orchestrator 2026-10-10 08:4xZ: a command that only NAMES the
# override, or only mentions push, inside a read-only search
allow 'grep -n "SPL_PREPUSH_OVERRIDE=1" /tmp/vibe-session.log'
allow "grep -c 'SPL_PREPUSH_OVERRIDE=yes' /tmp/a.log /tmp/b.log"
allow 'rg -n "SPL_PREPUSH_OVERRIDE" /var/tmp/logs'
allow 'echo "set SPL_PREPUSH_OVERRIDE=1 only with the owner go"'
allow 'grep -E "push.*--force\\"|-f " /tmp/vibe.log "unclosed'
allow 'grep "push --force" log "unclosed'
# heredocs (c-792, 2026-10-10): a heredoc BODY is data; a commit message whose
# prose has an apostrophe and names git and push is not a command
allow $'git commit -q -F - <<\'EOF\'\nfix: the guard didn\'t let git push run\n\nnever git push --force master\nEOF'
allow $'git commit -m "$(cat <<\'EOF\'\nwhy: it\'s about git push -f\nEOF\n)"'
allow $'cat > /tmp/note.md <<EOF\nsomeone\'s git push --force, blocked\nEOF\ngit push origin HEAD:master'
# ... but a body a shell reads is a command, and stays refused
refuse $'bash <<\'EOF\'\ngit push --force origin master\nEOF'
refuse $'sudo -u agentusr bash <<EOF\ngit push -f origin master\nEOF'
refuse $'cat <<EOF | sh\ngit push origin +HEAD:master\nEOF'
refuse $'bash <<-EOF\n\tSPL_PREPUSH_OVERRIDE=1 git push origin HEAD:master\n\tEOF'
refuse $'git commit -F - <<EOF\nmsg\nEOF\ngit push --force origin master'
allow 'git -c user.name=x -c user.email=y commit -m "x"'
allow 'git -c alias.p=push p origin HEAD:master'
allow 'git push -n origin HEAD:master'
allow 'git push --dry-run origin HEAD:master'
allow 'git push --verify origin HEAD:master'
allow 'git -c core.hooksPath=/dev/null commit -m "x"'
allow 'git -c core.pager=cat push origin HEAD:master'
allow 'git commit -m "never git push --no-verify"'
allow 'grep -rn "no-verify" csi-spl-doc/'

# 3. the CLI form
bash "$G" --check 'git push -f origin master' 2>/dev/null; rc=$?
if [ "$rc" = 2 ]; then pass "--check refuses with rc 2"; else fail "--check refuse rc=$rc"; fi
bash "$G" --check 'git push origin HEAD:master' 2>/dev/null; rc=$?
if [ "$rc" = 0 ]; then pass "--check allows with rc 0"; else fail "--check allow rc=$rc"; fi
bash "$G" 2>/dev/null; rc=$?
if [ "$rc" = 64 ]; then pass "a bad call is rc 64"; else fail "bad call rc=$rc"; fi

# 4. fail closed without python3
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ln -s "$(command -v bash)" "$T/bash"
err="$(PATH="$T" "$T/bash" -c '. "$1"; force_push_guard_check "git push origin HEAD:master"' _ "$G" 2>&1)"; rc=$?
if [ "$rc" = 2 ] && [[ "$err" == *"fail closed"* ]]; then pass "no python3: refused (fail closed)"
else fail "no python3: rc=$rc err=$err"; fi

echo "force-push-guard: $((n - fails))/$n passed"
[ "$fails" = 0 ]
