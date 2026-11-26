#!/usr/bin/env bash
# y9-vendor-lane-rule.sh — install.sh step: the fleet-rule parts that bind every
# vendor's seat (Y9_PARTS) into the rules file each OTHER vendor loads,
# rendered by y8's renderer from the same parts (one home, no copy).
#
#   claude  ~/.claude/CLAUDE.md                  step y4 (every part)
#   grok    ~/.claude/CLAUDE.md                  grok's compat.claude scan (default on)
#   mistral ~/.vibe/AGENTS.md                    step y8 (every part)
#   agy     ~/.gemini/config/rules/<part>.md     this step, one file per part (agy loads a
#                                                rules/*.md only under "trigger: always_on" frontmatter, SPL-5106)
#   qwen    ~/.qwen/QWEN.md                      this step, one block per part (qwen's global
#                                                context; its save_memory appends there, so it is qwen's memory file too)
#
# Y9_PARTS is an explicit list, not "every part" (SPL-6533): the parts left out
# (Y9_SKIP) speak to a claude seat or an orchestrator, and need {{placeholders}}
# this step has no values for:
#   00-title                    its heading is "Global Claude Code Instructions"
#   05-agents-run-as-agent-user how a Claude Code instance is launched (claude binary, user)
#   07-permission-mode-bypass   claude's --dangerously-skip-permissions and settings.json
#   10-push-and-deploy          the claude seat's land path; every seed carries its own
#   20-spawn-an-agent           spawning and the agent ceiling: the claude / grok orchestrator's
# A new part goes in one list or the other: test-agy-qwen-fleet-rules.sh fails otherwise.
#
# Each file gets one block per part "spool-install: begin lane-rule (... fleet
# rule <part> ...) ... end lane-rule sha256=<hex>"; everything outside them is
# kept, a hand-edited block is left alone (--force-skills replaces it): y8's
# rules. QWEN.md is rendered in a staging copy first, so a run that changes it
# keeps the old file once (QWEN.md.bak-spool-install-<UTC stamp>), not once per part.
# A vendor whose home dir (~/.gemini, ~/.qwen) is absent is skipped.
# Env: SPOOL_INSTALL_VENDOR_RULES=0 skips the step (install.sh sets it without
#      --fleet); SPOOL_INSTALL_CLAUDE_ASSETS overrides the assets dir (tests).
# Reads install.sh's DRY and FORCE_SKILLS when set.

Y9_PARTS="22-ui-forms-for-user-input 25-stay-in-your-lane 27-lane-issue-and-docs 28-wiki-designated-team-branch 30-cross-lane-findings"
# shellcheck disable=SC2034  # read by test-agy-qwen-fleet-rules.sh: every part is in Y9_PARTS or here
Y9_SKIP="00-title 05-agents-run-as-agent-user 07-permission-mode-bypass 10-push-and-deploy 20-spawn-an-agent"

spool_install_vendor_lane_rule() {
  [ "${SPOOL_INSTALL_VENDOR_RULES:-1}" = 0 ] && return 0
  local here assets part rc=0 rev=""
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets="${SPOOL_INSTALL_CLAUDE_ASSETS:-$here/../assets/claude}"
  _y9_one() {  # PART TARGET [HEAD]
    Y8_HEAD="${3:-}" Y8_ONLY="$1" Y8_TAG=lane-rule python3 "$here/y8-vibe-agents.py" "$assets/claude-md" "$2" "${DRY:-0}" "${FORCE_SKILLS:-0}" || rc=1
  }
  if [ -d "$HOME/.gemini" ]; then
    for part in $Y9_PARTS; do _y9_one "$part" "$HOME/.gemini/config/rules/$part.md" $'---\ntrigger: always_on\n---\n'; done
  fi
  [ -d "$HOME/.qwen" ] || return "$rc"
  # a new block goes first in the file: the last part first, so a new QWEN.md reads in part order
  for part in $Y9_PARTS; do rev="$part $rev"; done
  if [ "${DRY:-0}" = 1 ]; then
    for part in $rev; do _y9_one "$part" "$HOME/.qwen/QWEN.md"; done
  else
    _y9_qwen "$rev" || rc=1
  fi
  return "$rc"
}

# _y9_qwen PARTS - every part into a staging copy of QWEN.md, then the copy
# over QWEN.md with ONE backup of the old file; nothing changed, nothing written.
# A part that fails has its whole output forwarded; a passing part only its notices.
_y9_qwen() {
  local q="$HOME/.qwen/QWEN.md" stage part bak="" rc=0 prc msg
  stage="$(mktemp -d "$HOME/.qwen/.y9-stage.XXXXXX")" || return 1
  [ -f "$q" ] && cp -p "$q" "$stage/QWEN.md"
  for part in $1; do
    msg="$(rc=0; _y9_one "$part" "$stage/QWEN.md" 2>&1; echo "rc=$rc")"
    prc="${msg##*rc=}"
    msg="${msg%rc=*}"; msg="${msg//"$stage/QWEN.md"/$q}"
    if [ "$prc" != 0 ]; then
      rc=1
      [ -n "$msg" ] && printf '%s' "$msg" >&2
    else
      case "$msg" in *"edited by hand"* | *FATAL* | *"no such part"* | *"has no value"*) printf '%s' "$msg" >&2 ;; esac
    fi
  done
  if [ "$rc" = 0 ] && [ -f "$stage/QWEN.md" ] && ! cmp -s "$stage/QWEN.md" "$q"; then
    if [ -f "$q" ]; then
      bak="$(_y9_qwen_backup "$q")" || rc=1
    fi
    if [ "$rc" = 0 ] && mv -f "$stage/QWEN.md" "$q"; then
      echo "spool-install: vibe-agents: $q: the fleet rule parts rendered${bak:+, the old file kept as $bak}" >&2
    else
      rc=1
    fi
  elif [ "$rc" = 0 ]; then
    echo "spool-install: vibe-agents: $q: already current" >&2
  fi
  rm -rf "${stage:?}"
  return "$rc"
}

# _y9_qwen_backup Q - the whole old Q to Q.bak-spool-install-<UTC stamp>[-k],
# created exclusively (noclobber = O_EXCL, mode 0600) for k = 1..99 and printed;
# all 99 taken: refuse, nothing replaced. y8-vibe-agents.py's backup_stamped, in bash.
_y9_qwen_backup() {
  local q="$1" stamp cand k
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for (( k = 1; k < 100; k++ )); do
    cand="$q.bak-spool-install-$stamp$([ "$k" = 1 ] || echo "-$k")"
    if (umask 077; set -C; cat <"$q" >"$cand") 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  echo "spool-install: vibe-agents: $q: no free backup name for $stamp: nothing replaced" >&2
  return 1
}
