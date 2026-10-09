#!/bin/bash

#------------------------------------------------------------------------------
# @description The fleet rules say each fact once (csi-spl-doc/doc/md/
#   fleet-rules-index.md), but a few facts must still be written in several
#   places: a launcher is read on its own, the installed global CLAUDE.md is
#   read on every repo. This check fails when two of those copies disagree on a
#   PINNED fact:
#   1 id-letters      every agent-id letter class ([acg..]-[0-9]{3}) in the
#                     rule sources = the grammar, SPOOL_AGENT_ID_NEW_RX in
#                     spawn-agents/lib/spool-env.inc.sh
#   2 ceiling-count   the window-count `grep -cE '...'` regex is the same in
#                     the installed fragment, every launcher and any other
#                     rule source that carries it
#   3 ceiling-number  the default ceiling of install.sh = y4-claude-config.sh
#                     = the number in the repo CLAUDE.md
#   4 data-rule       every `<!-- fleet-pin data-rule-vendors: ... -->` pin
#                     agrees, each pinned vendor is named in the prose under
#                     its pin, and do_spl_lane_mix's secret pick is in the set
#   5 language-rule   the same for `fleet-pin language-rule-final` pins and
#                     do_spl_lane_mix's i18n pick
#   6 commit-address  the address on the repo CLAUDE.md "Commits:" line = the
#                     address of every recent commit by that author name
#   It runs in the pre-push hygiene part (do_check_pre_push) and in the orc
#   suite (tests/check-fleet-rules-drift.tst.sh). Read-only.
# @param FLEET_RULES_TREE (optional) - default: $APP_PATH, the checkout to read
# @param FLEET_RULES_HOME (optional) - also check a box's INSTALLED copies,
#   <home>/.claude/CLAUDE.md and <home>/.claude/commands/*-spawn.md (facts 1,
#   2, 4 and 5); they refresh only on a spool-install run
# @param FLEET_RULES_HISTORY (optional) - commits read for fact 6, default 50
# @example ./run -a do_check_fleet_rules_drift
# @example FLEET_RULES_HOME="$HOME" ./run -a do_check_fleet_rules_drift
#------------------------------------------------------------------------------
do_check_fleet_rules_drift() {
  local tree="${FLEET_RULES_TREE:-${APP_PATH:-}}" home="${FLEET_RULES_HOME:-}" rc=0
  [[ -n "$tree" && -d "$tree" ]] || { _frd_log "FATAL FLEET_RULES_TREE is not a directory: '$tree'"; return 1; }
  [[ -z "$home" || -d "$home/.claude" ]] || { _frd_log "FATAL FLEET_RULES_HOME has no .claude dir: '$home'"; return 1; }

  _frd_id_letters "$tree" "$home" || rc=1
  _frd_ceiling_count "$tree" "$home" || rc=1
  _frd_ceiling_number "$tree" || rc=1
  _frd_data_rule "$tree" "$home" || rc=1
  _frd_language_rule "$tree" "$home" || rc=1
  _frd_per_kind_main "$tree" "$home" || rc=1
  _frd_commit_address "$tree" || rc=1

  if (( rc )); then
    _frd_log "FAIL fleet rules drift: two sources disagree (above); fix the copy that is not the home named in fleet-rules-index.md"
    return 1
  fi
  _frd_log "OK fleet rules: no drift over 6 pinned facts in $tree${home:+ and the installed copies under $home/.claude}"
}

_frd_log() { if declare -F do_log >/dev/null; then do_log "$*"; else echo "$*"; fi; }

# The rule sources, relative to the tree. The installed ones are added per fact.
_FRD_FRAG=csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md
_FRD_CMDS=csi-spl-orc/src/bash/features/spawn-agents/assets/commands
_frd_sources() {  # <tree>: every rule source that exists, one path per line
  local t="$1" f
  for f in CLAUDE.md csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md csi-spl-doc/doc/md/fleet-rules-index.md \
           csi-spl-doc/doc/md/lane-integration-rules.md csi-spl-doc/doc/help/how-to-post.md \
           csi-spl-orc/src/bash/scripts/spl-session-prune.sh csi-spl-orc/src/bash/run/spl-orch-load-report.func.sh \
           "$t/$_FRD_FRAG"/*.md "$t/$_FRD_CMDS"/*.md; do
    f="${f#"$t"/}"
    [[ -f "$t/$f" ]] && echo "$t/$f"
  done
  return 0
}
_frd_installed() {  # <home>: the installed copies, one path per line
  local h="$1" f
  [[ -n "$h" ]] || return 0
  for f in "$h/.claude/CLAUDE.md" "$h"/.claude/commands/*-spawn.md; do [[ -f "$f" ]] && echo "$f"; done
  return 0
}

_frd_id_letters() {  # <tree> <home>
  local t="$1" h="$2" want f l bad=0 n=0
  want="$(sed -nE "s/^SPOOL_AGENT_ID_NEW_RX='\[([a-z]+)\]-\[0-9\]\{3\}'.*/\1/p" \
    "$t/csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh" 2>/dev/null)"
  [[ -n "$want" ]] || { _frd_log "FAIL id-letters: no SPOOL_AGENT_ID_NEW_RX grammar in spool-env.inc.sh"; return 1; }
  while IFS= read -r f; do
    while IFS= read -r l; do
      n=$((n + 1))
      [[ "$l" == "$want" ]] || { _frd_log "FAIL id-letters: ${f#"$t"/} has [$l], the grammar is [$want]"; bad=1; }
    done < <(grep -oE '\[[a-z]+\]-\[0-9\]\{3\}' "$f" | sed -E 's/^\[([a-z]+)\].*/\1/')
  done < <(_frd_sources "$t"; _frd_installed "$h")
  (( n )) || { _frd_log "FAIL id-letters: no agent-id letter class found in any source"; return 1; }
  (( bad )) || _frd_log "OK id-letters: $n copies = [$want]"
  return "$bad"
}

_frd_count_rx() { grep -oE "grep -cE '[^']*'" "$1" | sed -E "s/^grep -cE '(.*)'$/\1/"; }
_frd_ceiling_count() {  # <tree> <home>
  local t="$1" h="$2" want f r bad=0 n=0 k
  want="$(_frd_count_rx "$t/$_FRD_FRAG/20-spawn-an-agent.md" | sed -n 1p)"
  [[ -n "$want" ]] || { _frd_log "FAIL ceiling-count: the home ($_FRD_FRAG/20-spawn-an-agent.md) has no count regex"; return 1; }
  for k in claude grok agy qwen mistral; do
    [[ -f "$t/$_FRD_CMDS/$k-spawn.md" ]] && ! _frd_count_rx "$t/$_FRD_CMDS/$k-spawn.md" | grep . >/dev/null \
      && { _frd_log "FAIL ceiling-count: $_FRD_CMDS/$k-spawn.md has no count regex (section 1.1)"; bad=1; }
  done
  while IFS= read -r f; do
    while IFS= read -r r; do
      n=$((n + 1))
      [[ "$r" == "$want" ]] || { _frd_log "FAIL ceiling-count: ${f#"$t"/} counts '$r', the home counts '$want'"; bad=1; }
    done < <(_frd_count_rx "$f")
  done < <(_frd_sources "$t"; _frd_installed "$h")
  (( bad )) || _frd_log "OK ceiling-count: $n copies agree"
  return "$bad"
}

_frd_ceiling_number() {  # <tree>
  local t="$1" a b c
  a="$(grep -oE 'SPOOL_AGENT_CEILING:-[0-9]+' "$t/csi-spl-orc/src/bash/features/spool-install/install.sh" 2>/dev/null | sed 's/.*-//' | sort -u)"
  b="$(grep -oE 'SPOOL_AGENT_CEILING:-[0-9]+' "$t/csi-spl-orc/src/bash/features/spool-install/steps/y4-claude-config.sh" 2>/dev/null | sed 's/.*-//' | sort -u)"
  c="$(grep -oE 'Agent ceiling: [0-9]+' "$t/CLAUDE.md" 2>/dev/null | sed 's/.*: //' | sort -u)"
  if [[ -z "$a" || -z "$b" || -z "$c" ]]; then
    _frd_log "FAIL ceiling-number: missing (install.sh='$a' y4-claude-config.sh='$b' CLAUDE.md 'Agent ceiling: N'='$c')"; return 1
  fi
  if [[ "$a" == "$b" && "$b" == "$c" && "$a" != *$'\n'* ]]; then
    _frd_log "OK ceiling-number: $a"; return 0
  fi
  _frd_log "FAIL ceiling-number: install.sh=${a//$'\n'/,} y4-claude-config.sh=${b//$'\n'/,} CLAUDE.md=${c//$'\n'/,}"; return 1
}

# A pin line, e.g. <!-- fleet-pin data-rule-vendors: claude mistral -->: the
# vendors a rule names, pinned next to its prose in the home and its copies.
_frd_pin_rx() { echo "<!-- fleet-pin $1: ([a-z ]+) -->"; }
_frd_pins() {  # <fact> <pin key> <code pick sed -n script> <what the code pick is> <tree> <home>
  local fact="$1" key="$2" code_rx="$3" what="$4" t="$5" h="$6" rx want="" f ln v vs bad=0 n=0 req pick
  rx="$(_frd_pin_rx "$key")"
  for req in "$_FRD_FRAG/20-spawn-an-agent.md" "$_FRD_CMDS/spawn-an-agent.md"; do
    grep -qE "$rx" "$t/$req" 2>/dev/null || { _frd_log "FAIL $fact: no $key pin in $req"; bad=1; }
  done
  if [[ -n "$h" && -f "$h/.claude/CLAUDE.md" ]] && ! grep -qE "$rx" "$h/.claude/CLAUDE.md"; then
    _frd_log "FAIL $fact: $h/.claude/CLAUDE.md has no $key pin: it predates its source, re-run spool-install"; bad=1
  fi
  while IFS= read -r f; do
    while IFS=: read -r ln vs; do
      vs="$(sed -E "s/.*$rx.*/\1/" <<<"$vs" | xargs -n1 | sort | xargs)"
      n=$((n + 1))
      [[ -n "$want" ]] || want="$vs"
      [[ "$vs" == "$want" ]] || { _frd_log "FAIL $fact: ${f#"$t"/}:$ln pins '$vs', another pin says '$want'"; bad=1; }
      for v in $vs; do
        sed -n "$((ln + 1)),$((ln + 12))p" "$f" | grep -i "$v" >/dev/null \
          || { _frd_log "FAIL $fact: ${f#"$t"/}:$ln pins $v, the prose under the pin never names it"; bad=1; }
      done
    done < <(grep -nE "$rx" "$f")
  done < <(_frd_sources "$t"; _frd_installed "$h")
  pick="$(sed -nE "$code_rx" "$t/csi-spl-orc/src/bash/run/spl-lane-mix.func.sh" 2>/dev/null | sed -n 1p)"
  if [[ -z "$pick" ]]; then _frd_log "FAIL $fact: no $what in spl-lane-mix.func.sh"; bad=1
  elif [[ -n "$want" && " $want " != *" $pick "* ]]; then _frd_log "FAIL $fact: do_spl_lane_mix's $what is $pick, the pins allow '$want'"; bad=1; fi
  (( bad )) || _frd_log "OK $fact: $n pins = '$want', lane_mix picks $pick"
  return "$bad"
}
_frd_data_rule() {  # <tree> <home>
  _frd_pins data-rule data-rule-vendors 's/.*_spl_lane_mix_pick ([a-z]+) "data rule:.*/\1/p' "secret pick" "$1" "$2"
}
_frd_language_rule() {  # <tree> <home>
  _frd_pins language-rule language-rule-final 's/.*_spl_lane_mix_want ([a-z]+) "kind i18n:.*/\1/p' "i18n pick" "$1" "$2"
}

_frd_per_kind_main() {  # <tree> <home>
  local t="$1" h="$2" want f ln kind main bad=0 n=0
  want="specs_and_docs agy
tests claude
simple_coding mistral
complex_coding claude
i18n agy
secret claude"
  
  for f in "$t/$_FRD_FRAG/20-spawn-an-agent.md" "$t/$_FRD_CMDS/spawn-an-agent.md"; do
    [[ -f "$f" ]] || { _frd_log "FAIL per-kind-main: $f not found"; bad=1; continue; }
    for ln in 13 14 15 16 17 18; do
      line=$(sed -n "${ln}p" "$f")
      if [[ "$line" =~ \`([a-z_]+)\` ]]; then
        kind="${BASH_REMATCH[1]}"
        if [[ "$line" =~ \|[[:space:]]*([a-z]+)[[:space:]]*\| ]]; then
          main="${BASH_REMATCH[1]}"
          n=$((n + 1))
          if ! grep -q "^$kind $main$" <<<"$want"; then
            _frd_log "FAIL per-kind-main: ${f#"$t"/}:$line defines $kind main as $main, but the spec says $(grep "^$kind " <<<"$want" | cut -d' ' -f2)"
            bad=1
          fi
        fi
      fi
    done
  done
  
  if (( n == 0 )); then
    _frd_log "FAIL per-kind-main: no per-kind main table found in 20-spawn-an-agent.md or spawn-an-agent.md"
    bad=1
  elif (( bad == 0 )); then
    _frd_log "OK per-kind-main: $n per-kind main vendors match the spec"
  fi
  return "$bad"
}

_frd_commit_address() {  # <tree>
  local t="$1" line name addr bad=0 n=0 an ae
  line="$(grep -m1 -E '^- Commits: `[^`<]+ <[^>]+>`' "$t/CLAUDE.md" 2>/dev/null)"
  name="$(sed -E 's/^- Commits: `([^<`]+) <.*/\1/; s/ +$//' <<<"$line")"
  addr="$(sed -E 's/^- Commits: `[^<`]+<([^>]+)>.*/\1/' <<<"$line")"
  [[ -n "$line" && -n "$name" && -n "$addr" ]] || { _frd_log "FAIL commit-address: no '- Commits: \`Name <address>\`' line in CLAUDE.md"; return 1; }
  if ! git -C "$t" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    _frd_log "SKIP commit-address: $t has no git history to compare with"; return 0
  fi
  while IFS='|' read -r an ae; do
    [[ "$an" == "$name" ]] || continue
    n=$((n + 1))
    [[ "$ae" == "$addr" ]] || { _frd_log "FAIL commit-address: a commit by that author name uses <$ae>, CLAUDE.md says <$addr>"; bad=1; }
  done < <(git -C "$t" log -"${FLEET_RULES_HISTORY:-50}" --no-merges --no-mailmap --format='%an|%ae' 2>/dev/null | sort -u)
  (( bad )) || _frd_log "OK commit-address: CLAUDE.md = the recent commits by that author ($n distinct identities read)"
  return "$bad"
}
