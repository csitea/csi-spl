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
#   6 per-kind-main   each per-kind table (found by its "main | backup"
#                     header, anywhere in the file) in the installed fragment
#                     and the spawn-an-agent launcher names the spec's main
#   7 commit-address  the address on the repo CLAUDE.md "Commits:" line = the
#                     address of every recent commit by that author name
#   8 repo-refs       every path, action (do_*), make target (make do-*) and
#                     spec folder (spec NNN) that the repo-root CLAUDE.md and
#                     AGENTS.md name exists on the tree: a path at the root or
#                     under a csi-spl-* component (a git-ignored one, e.g.
#                     tpl-gen/, is skipped and counted), an action defined in a
#                     *.sh, a target in a Makefile or *.mk, a folder
#                     csi-spl-doc/specs/NNN-*, a terraform step ("terraform
#                     steps NNN, NNN") csi-spl-iac/src/terraform/NNN-*; and
#                     the CLAUDE.md dir table has a row per top-level
#                     csi-spl-* dir of the tree
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
  _frd_repo_refs "$tree" || rc=1

  if (( rc )); then
    _frd_log "FAIL fleet rules drift: two sources disagree, or an agent doc names what is not on the tree (above); fix the copy that is not the home named in fleet-rules-index.md"
    return 1
  fi
  _frd_log "OK fleet rules: no drift over 8 pinned facts in $tree${home:+ and the installed copies under $home/.claude}"
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

# _frd_kind_rows <file>: "<line> <kind> <main>" per row of the per-kind table,
# found by its header row (cells "main" and "backup"), wherever it sits
_frd_kind_rows() {
  awk '
    /^\|/ && $0 ~ /\| *main *\|/ && $0 ~ /\| *backup *\|/ { in_t = 1; next }
    in_t && !/^\|/ { in_t = 0 }
    in_t && /^\|[-| ]+\|$/ { next }
    in_t {
      split($0, c, "|"); kind = ""; main = c[3]; gsub(/ /, "", main)
      if (match(c[2], /LANE_MIX_KIND=[a-z0-9_]+/)) kind = substr(c[2], RSTART + 14, RLENGTH - 14)
      else if (match(c[2], /`[a-z0-9_]+`/)) kind = substr(c[2], RSTART + 1, RLENGTH - 2)
      print NR, (kind == "" ? "?" : kind), main
    }' "$1"
}

_frd_per_kind_main() {  # <tree> <home>
  local t="$1" want f ln kind main exp seen bad=0 n=0
  want="specs_and_docs agy
tests claude
simple_coding claude
complex_coding claude
i18n agy
secret claude
orchestration claude"

  for f in "$t/$_FRD_FRAG/20-spawn-an-agent.md" "$t/$_FRD_CMDS/spawn-an-agent.md"; do
    [[ -f "$f" ]] || { _frd_log "FAIL per-kind-main: $f not found"; bad=1; continue; }
    seen=""
    while read -r ln kind main; do
      n=$((n + 1)); seen+="$kind "
      exp="$(grep "^$kind " <<<"$want" | cut -d' ' -f2)"
      if [[ -z "$exp" ]]; then
        _frd_log "FAIL per-kind-main: ${f#"$t"/}:$ln names kind '$kind', the spec has no such kind"; bad=1
      elif [[ "$main" != "$exp" ]]; then
        _frd_log "FAIL per-kind-main: ${f#"$t"/}:$ln defines $kind main as $main, but the spec says $exp"; bad=1
      fi
    done < <(_frd_kind_rows "$f")
    while read -r kind _; do
      [[ " $seen" == *" $kind "* ]] || { _frd_log "FAIL per-kind-main: ${f#"$t"/} has no per-kind table row for $kind"; bad=1; }
    done <<<"$want"
  done

  if (( bad == 0 )); then
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

# _frd_doc_refs <tree>: "<kind>\t<ref>\t<file>:<line>" for each reference the
# repo-root agent docs make; kinds: path, action, target, spec, tfstep
_FRD_AGENT_DOCS="CLAUDE.md AGENTS.md"
_frd_doc_refs() {
  local t="$1" f ln m w ws
  for f in $_FRD_AGENT_DOCS; do
    [[ -f "$t/$f" ]] || continue
    while IFS=: read -r ln m; do
      m="${m#](}"; m="${m%)}"; m="${m%%#*}"
      [[ -z "$m" || "$m" =~ ^[a-z]+: ]] || printf 'path\t%s\t%s:%s\n' "$m" "$f" "$ln"
    done < <(grep -noE '\]\([^)]+\)' "$t/$f")
    while IFS=: read -r ln m; do
      read -ra ws <<<"${m//\`/ }"
      for w in "${ws[@]}"; do _frd_is_path_word "$w" && printf 'path\t%s\t%s:%s\n' "${w%/}" "$f" "$ln"; done
    done < <(grep -noE '`[^`]+`' "$t/$f")
    grep -noE '(^|[^A-Za-z0-9_])do_[a-z0-9_]+' "$t/$f" | sed -E "s/^([0-9]+):[^d]?(do_.*)/action\t\2\t$f:\1/"
    grep -noE 'make do-[a-z0-9-]+[*]?' "$t/$f" | grep -vE '[-*]$' | sed -E "s/^([0-9]+):make (.*)/target\t\2\t$f:\1/"
    grep -noiE '(^|[^a-z])specs? [0-9]{3}([^0-9]|$)' "$t/$f" | sed -E "s/^([0-9]+):.*([0-9]{3}).*/spec\t\2\t$f:\1/"
    while IFS=: read -r ln m; do
      grep -oE '[0-9]{3}' <<<"$m" | sed "s|^|tfstep\t|; s|\$|\t$f:$ln|"
    done < <(grep -noiE 'terraform steps? (`?[0-9]{3}`?(, | and | or |/)?)+' "$t/$f")
  done
  return 0
}
# A word inside backticks names a repo path when it has a '/', no placeholder
# or shell character, and is neither a host ("github.com/...") nor a list of
# extensions (".mjs/.js").
_frd_is_path_word() {
  local w="$1"
  [[ "$w" == */* && "$w" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] || return 1
  [[ "$w" =~ ^[A-Za-z0-9-]+\.[a-z]{2,}/ || "$w" =~ ^\.[a-z]+/\.[a-z]+$ ]] && return 1
  return 0
}
# _frd_path_ok <tree> <path>: 0 on the tree (root or a csi-spl-* component),
# 2 git-ignored (a sibling clone such as tpl-gen/), 1 missing
_frd_path_ok() {
  local t="$1" p="$2" c
  [[ -e "$t/$p" ]] && return 0
  for c in "$t"/csi-spl-*/; do [[ -e "$c$p" ]] && return 0; done
  git -C "$t" check-ignore "$p" "$p/" >/dev/null 2>&1 && return 2
  grep -qxF -e "/$p/" -e "/$p" -e "$p/" "$t/.gitignore" 2>/dev/null && return 2  # a tree with no git
  return 1
}
_frd_defined_actions() {  # <tree>: every do_* function a *.sh defines
  grep -rhoE '^[[:space:]]*(function[[:space:]]+)?do_[a-z0-9_]+[[:space:]]*\(\)' --include='*.sh' \
    --exclude-dir=node_modules --exclude-dir=.git "$1"/csi-spl-* 2>/dev/null \
    | sed -E 's/^[[:space:]]*(function[[:space:]]+)?//; s/[[:space:]]*\(\)$//' | sort -u
}
_frd_defined_targets() {  # <tree>: every do-* make target
  grep -rhoE '^do-[a-z0-9-]+:' --include='*.mk' --include=Makefile \
    --exclude-dir=node_modules --exclude-dir=.git "$1"/csi-spl-* 2>/dev/null | sed 's/:$//' | sort -u
}

# _frd_dir_table <tree>: the CLAUDE.md dir table ("| `csi-spl-x` | ... |")
# has a row for each top-level csi-spl-* dir, so a new component is listed
_frd_dir_table() {
  local t="$1" d bad=0
  for d in "$t"/csi-spl-*/; do
    [[ -d "$d" ]] || continue
    d="$(basename "$d")"
    grep -qE "^\| \`$d\` \|" "$t/CLAUDE.md" 2>/dev/null \
      || { _frd_log "FAIL repo-refs: the CLAUDE.md dir table has no row for $d"; bad=1; }
  done
  return "$bad"
}

_frd_repo_refs() {  # <tree>
  local t="$1" kind ref at acts tgts bad=0 n=0 ign=0 ok
  acts="$(_frd_defined_actions "$t")"; tgts="$(_frd_defined_targets "$t")"
  while IFS=$'\t' read -r kind ref at; do
    n=$((n + 1)); ok=1
    case "$kind" in
      path)   _frd_path_ok "$t" "$ref"; case $? in 0) ;; 2) ign=$((ign + 1)) ;; *) ok=0 ;; esac ;;
      action) grep -qxF "$ref" <<<"$acts" || ok=0 ;;
      target) grep -qxF "$ref" <<<"$tgts" || ok=0 ;;
      spec)   compgen -G "$t/csi-spl-doc/specs/$ref-*" >/dev/null || ok=0 ;;
      tfstep) compgen -G "$t/csi-spl-iac/src/terraform/$ref-*" >/dev/null || ok=0 ;;
    esac
    (( ok )) || { _frd_log "FAIL repo-refs: $at names $kind '$ref', not on the tree"; bad=1; }
  done < <(_frd_doc_refs "$t")
  _frd_dir_table "$t" || bad=1
  (( n )) || { _frd_log "FAIL repo-refs: no reference found in $_FRD_AGENT_DOCS"; return 1; }
  (( bad )) || _frd_log "OK repo-refs: $n references in $_FRD_AGENT_DOCS are on the tree ($ign git-ignored, skipped)"
  return "$bad"
}
