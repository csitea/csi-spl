#!/bin/bash
#------------------------------------------------------------------------------
# @description ONE pre-push gate: the checks the deploy pipeline blocks on that
# @description are cheap enough to run before every push, for exactly the parts
# @description the push touches. A break is then caught in the lane that wrote
# @description it, not after it has stalled every deploy.
# @description PARTS (selected by the paths the push changes vs PRE_PUSH_BASE):
# @description   hygiene     always (~1 s)
# @description   iac         csi-spl-iac/ csi-spl-cnf/ .github/ .zap/ root scanner configs
# @description   wui-vendor  csi-spl-wui/ (the api's payment-vendor grep over WUI)
# @description   wui         csi-spl-wui/ minus edits to e2e/bench files, plus the
# @description               repo files the unit tests read (unit tests + typecheck)
# @description   api         csi-spl-api/ csi-spl-rdb/ .version
# @description   orc         csi-spl-orc/: the orc *.tst.sh that name a touched
# @description               file (run-all-tests.sh --changed) + bash-cleancode
# @description   cnf         INSTEAD of iac when every changed path is under
# @description               csi-spl-cnf/csi-spl/ (the env yaml + its rendered
# @description               tfvars/json): ENV=dev|prd do_tpl_gen must leave the
# @description               render unchanged. Any other path = the iac suite.
# @description   blog        csi-spl-doc/blog/ + the check itself: do_spl_blog_check
# @description               (csi-spl-orc, spec 111 4.4) on the post files the
# @description               push adds or changes, and the commit shape of
# @description               PRE_PUSH_BASE..HEAD; reads the ban-list secret
# @description               (fail closed) only when a post file changed
# @description   lint-*      the scanner workflows (61..67, 85) + syntax, on the
# @description               TOUCHED files only -- check-pre-push-lint.func.sh
# @description   A push that touches none of a part's paths never runs it (it is
# @description   logged SKIP-untouched), so a doc-only push runs hygiene.
# @description TIERS (CLE-77824, owner 2026-10-01): the hook runs the FAST tier,
# @description which leaves the slow checks to CI -- api: go test -race,
# @description build-stripped, hub-pg (Postgres, ~384 s), hub-gcs; iac: every
# @description test marked '# pre-push-tier: slow' (terraform validate, tpl-gen
# @description renders). Workflow 10 (and the workflow 20 deploy gate) runs the
# @description FULL suites on every push and fails on any skip.
# @description VERDICT CACHE: a part's green verdict is keyed by the git tree of
# @description the paths that part reads (plus the tier), so a rebase over
# @description commits that only touch OTHER parts re-uses it instead of
# @description re-running; any change under the part's own paths re-runs it.
# @description NO SILENT SKIPS: a part's tools are checked up front; a missing
# @description one is a FAIL that names the tool and the fix. A failure is
# @description re-run on PRE_PUSH_BASE and WARNs (does not block) only when it is
# @description red there too, so a fix still lands on a red trunk.
# @description Every part writes one line to PRE_PUSH_LOG: PASS, PASS-cached,
# @description WARN-pre-existing (with the trunk sha), FAIL or SKIP-untouched,
# @description with its duration.
# @param PRE_PUSH_MODE (optional) - fast (default: parts the push touches) | full (every part)
# @param PRE_PUSH_TIER (optional) - fast (default: the hook tier) | full (also the CI-only slow checks)
# @param PRE_PUSH_BASE (optional) - diff base, default origin/master
# @param PRE_PUSH_PLAN (optional) - 1 = print the selected parts and exit 0
# @param PRE_PUSH_TREE (optional) - checkout root, default $APP_PATH
# @param PRE_PUSH_LOG (optional) - per-part verdict log, default ~/.cache/csi-spl/pre-push.log
# @param PRE_PUSH_CACHE (optional) - per-part green cache, default ~/.cache/csi-spl/pre-push.parts.green
# @param PRE_PUSH_PASS (optional) - whole-tree pass record, default pre-push.tree.pass beside PRE_PUSH_CACHE
# @param PRE_PUSH_SKIP_PASSED (optional) - 1 = return PASS at once when this exact clean tree, parts set,
# @param        tier, merge-base and gate code already passed whole (the pre-push hook sets it)
# @param PRE_PUSH_NO_CACHE (optional) - 1 = ignore the green cache and the tree-pass record (always run)
# @param PRE_PUSH_PART_TIMEOUT (optional) - seconds per part, default 300 (overrides the full-tier defaults too)
# @param PRE_PUSH_API_FULL_TIMEOUT (optional) - seconds for the api part on the full tier, default 900
# @param PRE_PUSH_IAC_FULL_TIMEOUT (optional) - seconds for the iac part on the full tier, default 600
# @param PRE_PUSH_ORC_FULL_TIMEOUT (optional) - seconds for the orc part on the full tier, default 1800
# @param PRE_PUSH_WUI_TIMEOUT (optional) - seconds for the wui part, default 420
# @param PRE_PUSH_ONLY (optional) - lint = only the lint parts (do_check_pre_push_lint);
# @param        override = only the seconds-cheap correctness parts, hygiene + lint-migration
# @param        (what the hook still runs under SPL_PREPUSH_OVERRIDE=1; PRE_PUSH_LINT=0 cannot drop them)
# @param PRE_PUSH_PIDFILE (optional) - where the run records its pid for do_stop_pre_push, default ~/.cache/csi-spl/pre-push.<tree-hash>.pid
# @param PRE_PUSH_EXTRA_PATH (optional) - dirs appended to PATH before the tool check, default /usr/local/bin:/usr/bin:/bin:~/.local/bin
# @example ./run -a do_check_pre_push
# @example PRE_PUSH_MODE=full PRE_PUSH_TIER=full ./run -a do_check_pre_push
# @example PRE_PUSH_PLAN=1 ./run -a do_check_pre_push
# @description STOPPING A RUN: ./run -a do_stop_pre_push (by the pidfile above),
# @description never `pkill -f do_check_pre_push` -- the action name is on every
# @description agent's argv (2026-10-06: 15 claude sessions killed in 0.7 s).
#------------------------------------------------------------------------------

# The lint parts live beside this file; the run loader sources both, a test
# that sources only this one gets them too.
declare -F _ppl_plan >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/check-pre-push-lint.func.sh"

# Bumped whenever what a part RUNS changes, so an old green cannot vouch for a
# new gate.
_PP_CACHE_V=6
# Where this gate's own code lives: its content is part of the tree-pass key.
_PP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The repo files OUTSIDE csi-spl-wui that the wui unit tests read (hub Go
# sources, migrations, the firebase render script, cnf env JSON, workflows,
# help docs), taken from the tests (tests/unit/*.mjs) and the build modules
# they import (src/node/**/*.mjs) so the list cannot go stale. A line that
# builds a scratch repo (mkdirSync / writeFileSync) names paths it WRITES, not
# reads, so it is left out. A '<dir>/...' literal counts when:
#   - it carries a template ('csi-spl-cnf/csi-spl/${env}.env.json'): it is
#     the glob 'csi-spl-cnf/csi-spl/*.env.json', not the whole directory (the
#     dir form keyed the part on every <env>/tf tfvars);
#   - it names a FILE in the tree;
#   - it names a DIRECTORY as the literal argument of a read (join,
#     readFileSync, readdirSync, existsSync, statSync, cpSync), bare or
#     anchored at a checkout CONSTANT (an upper-case name: REPO, WUI):
#     join(REPO, '.github/workflows', wf), join(WUI, '../csi-spl-doc/doc/help').
# A directory named only as fixture data or in a message is NOT an input
# (2026-10-04: the 'csi-spl-doc/specs' fixture in docs.test.mjs made every
# spec tasks.md edit select the 5-min part and miss its cache; 4 lanes lost
# the trunk race to it within an hour), and neither is one read under a
# PARAMETER or a scratch dir (2026-10-10, c-786: sync-roadmap.mjs's
# existsSync(join(repo, 'csi-spl-doc/specs')) reads the real tree only in
# `pnpm run generate`, its unit test passes a throwaway repo; matched as "a
# line holding a read call" it re-selected the part for every spec-only
# change, 361 s each, 5 lost ref locks in a row). Before CLE-77946 none of them selected
# the wui part or keyed its cache, so a msg.go change re-used a green verdict
# the unit suite no longer gave.
_PP_WUI_EXT_RE='(csi-spl-(api|cnf|dat|doc|iac|orc|rdb|utl)|\.github)/[A-Za-z0-9_./-]*(\$\{[^}]*\}[A-Za-z0-9_./-]*)*'
_pp_wui_external() {  # <tree>
  local top="$1" wui="$1/csi-spl-wui" line m re q=$'[\'"`]'
  [[ -d "$wui/tests/unit" ]] || return 0
  local -a srcs=("$wui"/tests/unit/*.mjs)
  if [[ -d "$wui/src/node" ]]; then
    while IFS= read -r m; do srcs+=("$m"); done < <(find "$wui/src/node" -name '*.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
  fi
  grep -hvE '^[[:space:]]*(//|\*)|mkdirSync|writeFileSync' "${srcs[@]}" 2>/dev/null \
    | grep -E "$_PP_WUI_EXT_RE" | while IFS= read -r line; do
      while IFS= read -r m; do
        [[ -n "$m" && "$m" != *...* ]] || continue
        if [[ "$m" == *'${'* ]]; then
          sed -E 's/\$\{[^}]*\}/*/g' <<<"$m"
          continue
        fi
        while [[ "$m" == */ ]]; do m="${m%/}"; done
        if [[ -f "$top/$m" ]]; then echo "$m"; continue; fi
        [[ -d "$top/$m" ]] || continue
        re="(join|readFileSync|readdirSync|existsSync|statSync|cpSync)[(]([A-Z][A-Z0-9_]*,[[:space:]]*)?${q}([.][.]/)*${m//./[.]}/?${q}"
        [[ "$line" =~ $re ]] && echo "$m"
      done < <(grep -oE "$_PP_WUI_EXT_RE" <<<"$line")
    done | sort -u | paste -sd' ' -
}

# Within csi-spl-wui, the e2e and bench files are never RUN by the wui part:
# unit reads only the e2e file NAMES and ci-skip.txt (e2e-runner-coverage), and
# typecheck only parses them as JS (allowJs, no checkJs), which lint-wui-syntax
# already does for every touched one. So their CONTENT neither selects the part
# nor keys its cache; a name (an added, deleted or renamed file) still does.
_pp_wui_content_free() {  # <repo-relative path>
  [[ "$1" == csi-spl-wui/tests/e2e/ci-skip.txt ]] && return 1
  [[ "$1" == csi-spl-wui/tests/e2e/* || "$1" == csi-spl-wui/tests/bench/* ]]
}

# The changed files that count for the wui part: all of them, minus an edit to
# an e2e/bench file that exists on both sides (its name is unchanged).
_pp_wui_select() {  # <changed-list> <tree> <base>
  local changed="$1" tree="$2" base="$3" f mb
  mb="$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null)" || mb="$base"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if _pp_wui_content_free "$f" && [[ -e "$tree/$f" ]] \
       && git -C "$tree" cat-file -e "$mb:$f" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$f"
  done <<< "$changed"
}

# The cache id of csi-spl-wui at HEAD: its file list with blob ids, where an
# e2e/bench file contributes its name only.
_pp_wui_tree_id() {  # <tree>
  git -C "$1" ls-tree -r HEAD -- csi-spl-wui 2>/dev/null \
    | awk -F'\t' '{ p=$2; split($1, m, " ")
        if (p != "csi-spl-wui/tests/e2e/ci-skip.txt" && (p ~ /^csi-spl-wui\/tests\/e2e\// || p ~ /^csi-spl-wui\/tests\/bench\//)) print "name " p
        else print m[3] " " p }' \
    | sha1sum | cut -c1-40
}

# The paths each part reads: they select it AND key its green cache.
_pp_paths() {  # <part>
  case "$1" in
    # .github (not only workflows: actionlint.yaml, dependabot.yml), .zap and
    # the root scanner configs are read by iac tests: a .zap-only push once
    # selected NO part and reddened trunk 13 times (domain-single-source).
    iac)        echo "csi-spl-iac csi-spl-cnf .github .zap .hadolint.yaml .gitleaks.toml .trivyignore.yaml osv-scanner.toml docker-compose.yml" ;;
    wui)        echo "csi-spl-wui${_PP_TOP:+ $(_pp_wui_external "$_PP_TOP")}" ;;
    wui-vendor) echo "csi-spl-wui csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh" ;;
    api)        echo "csi-spl-api csi-spl-rdb .version" ;;
    orc)        echo "csi-spl-orc" ;;
    cnf)        echo "csi-spl-cnf/csi-spl csi-spl-iac/src/tpl csi-spl-iac/cnf/tpl-gen.ref csi-spl-iac/src/bash/run/tpl-gen.func.sh csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh" ;;
    blog)       echo "csi-spl-doc/blog csi-spl-orc/src/bash/run/spl-blog-check.func.sh" ;;
    lint-*)     _ppl_paths "$1" ;;
    *)          echo "" ;;
  esac
}
_pp_label() {  # <part>
  case "$1" in
    hygiene)    echo "distribution-hygiene" ;;
    iac)        echo "csi-spl-iac suite" ;;
    wui-vendor) echo "csi-spl-wui payment-vendor gate" ;;
    wui)        echo "csi-spl-wui unit + typecheck" ;;
    api)        echo "csi-spl-api suite" ;;
    orc)        echo "csi-spl-orc suite (tests naming a touched file) + bash-cleancode" ;;
    cnf)        echo "csi-spl-cnf tpl-gen render check (dev, prd)" ;;
    blog)       echo "blog post check (spec 111 4.4)" ;;
    lint-*)     echo "$1 (touched files, CI's version + baseline)" ;;
  esac
}

# What this push would carry: commits ahead of the base, plus staged, unstaged
# and untracked working-tree changes (so it is useful before a commit too).
# Returns 1 when the base ref is unknown, so the caller can widen to FULL.
_pp_changed() {  # <tree> <base>
  local tree="$1" base="$2"
  git -C "$tree" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 || return 1
  {
    git -C "$tree" diff --name-only "$base"...HEAD 2>/dev/null
    git -C "$tree" diff --name-only HEAD 2>/dev/null
    git -C "$tree" diff --name-only --cached 2>/dev/null
    git -C "$tree" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}

# Does a changed file fall under one of a part's paths?
_pp_touches() {  # <changed-list> <paths...>
  local changed="$1" f p; shift
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for p in "$@"; do
      [[ "$f" == "$p" || "$f" == "$p"/* ]] && return 0
      # shellcheck disable=SC2053 # a templated wui input is a glob (_pp_wui_external)
      [[ "$p" == *'*'* && "$f" == $p ]] && return 0
    done
  done <<< "$changed"
  return 1
}

# The cache key of a part: the git trees of its paths at HEAD, plus the tier and
# the gate version. Empty (= uncacheable) when any of those paths is dirty in
# the working tree, since then HEAD is not what was tested. It is a CONTENT
# key: no commit sha and no base sha, so a re-push after a rebase that only
# brought in files the part does not read re-uses the verdict in seconds.
# Two parts read more than their selecting paths, and key on it:
#   wui            node + pnpm versions (a tool upgrade re-runs it)
#   lint-migration the whole migration dir at HEAD AND on the base: its
#                  prefix rule (one file per NNNN, new = head+1) reads both,
#                  so keyed on the touched files alone a rebase over another
#                  lane's same-number file re-used the old green (0119, c-226)
_pp_key() {  # <tree> <part> <tier>
  local tree="$1" part="$2" tier="$3" p ids=""
  local -a paths; read -r -a paths <<< "$(_pp_paths "$part")"
  [[ "${#paths[@]}" -gt 0 ]] || return 0
  if [[ "$part" == lint-migration ]]; then
    paths+=("$_PPL_MIG_DIR")
    ids+="base=$(git -C "$tree" rev-parse -q --verify "${PRE_PUSH_BASE:-origin/master}:$_PPL_MIG_DIR" 2>/dev/null || echo -) "
  fi
  if [[ "$part" == wui ]]; then
    local pn; pn="$(_pp_pnpm 2>/dev/null)" || pn=""
    ids+="node=$(node -v 2>/dev/null || echo -) pnpm=$([[ -n "$pn" ]] && "$pn" -v 2>/dev/null || echo -) "
  fi
  local dirty; dirty="$(git -C "$tree" status --porcelain -- "${paths[@]}" 2>/dev/null)"
  # wui: an edited (M) e2e/bench file is not an input -- see _pp_wui_content_free
  [[ "$part" == wui && -n "$dirty" ]] && dirty="$(while IFS= read -r l; do
      [[ "${l:0:2}" =~ ^(M.|.M)$ ]] && _pp_wui_content_free "${l:3}" || printf '%s\n' "$l"
    done <<< "$dirty")"
  [[ -z "$dirty" ]] || return 0
  for p in "${paths[@]}"; do
    # '.' (a whole-scope lint part) is the root tree: 'HEAD:.' does not
    # resolve, and its '-' made one constant key re-use a green verdict
    # across every tree.
    if [[ "$part" == wui && "$p" == csi-spl-wui ]]; then
      ids+="$p=$(_pp_wui_tree_id "$tree") "
    elif [[ "$p" == *'*'* ]]; then
      ids+="$p=$(git -C "$tree" ls-files -s -- "$p" 2>/dev/null | sha1sum | cut -c1-40) "
    elif [[ "$p" == . ]]; then
      ids+=".=$(git -C "$tree" rev-parse -q --verify "HEAD^{tree}" 2>/dev/null || echo -) "
    else
      ids+="$p=$(git -C "$tree" rev-parse -q --verify "HEAD:$p" 2>/dev/null || echo -) "
    fi
  done
  printf '%s' "v$_PP_CACHE_V $part $tier $ids" | sha1sum | cut -c1-40
}
_pp_cache_has() {  # <key>
  [[ -n "$1" && "${PRE_PUSH_NO_CACHE:-0}" != 1 && -f "$_PP_CACHE" ]] && grep -qxF "$1" "$_PP_CACHE" 2>/dev/null
}
_pp_cache_add() {  # <key>
  [[ -n "$1" ]] || return 0
  mkdir -p "$(dirname "$_PP_CACHE")" 2>/dev/null || return 0
  printf '%s\n' "$1" >>"$_PP_CACHE" 2>/dev/null || return 0
  # keep it bounded: the newest 2000 verdicts
  if [[ "$(wc -l <"$_PP_CACHE" 2>/dev/null || echo 0)" -gt 4000 ]]; then
    tail -n 2000 "$_PP_CACHE" >"$_PP_CACHE.tmp.$$" 2>/dev/null && mv -f "$_PP_CACHE.tmp.$$" "$_PP_CACHE"
  fi
}

# The TREE-PASS record (fleet-hot-commands 3.2): the hook re-ran the whole
# gate inside `git push` right after the lane ran it by hand on the same tree.
# One line per WHOLE run that passed every part it selected, so the hook
# (PRE_PUSH_SKIP_PASSED=1) can skip a run that would only repeat it. The key:
#   the commit tree (HEAD^{tree}); empty = never recorded nor matched unless the
#     working tree is clean, so the tree tested IS the tree pushed
#   the parts this run selected, the tier, and the merge-base with the base
#     (the parts set and lint-migration read it)
#   the gate's own code (_PP_SELF_DIR) and _PP_CACHE_V
#   node + pnpm when the wui part is selected (as _pp_key)
# Written only by a run with no FAIL and no WARN-pre-existing, never by an
# override, a lint-only run, PRE_PUSH_LINT=0 / PRE_PUSH_LINT_ONLY (fewer parts
# than the hook would run), and only when the key still holds at the end.
_pp_gate_id() {
  cat "$_PP_SELF_DIR/check-pre-push.func.sh" "$_PP_SELF_DIR/check-pre-push-lint.func.sh" \
    "$_PP_SELF_DIR/check-release-note.func.sh" 2>/dev/null | sha1sum | cut -c1-40
}
_pp_tree_key() {  # <tree> <tier> <parts> <base>
  local tree="$1" tier="$2" parts="$3" base="$4" st t mb ids=""
  st="$(git -C "$tree" status --porcelain 2>/dev/null)" || return 0
  [[ -z "$st" ]] || return 0
  t="$(git -C "$tree" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" || return 0
  mb="$(git -C "$tree" merge-base "$base" HEAD 2>/dev/null)" || mb=-
  if [[ " $parts " == *" wui "* ]]; then
    local pn; pn="$(_pp_pnpm 2>/dev/null)" || pn=""
    ids="node=$(node -v 2>/dev/null || echo -) pnpm=$([[ -n "$pn" ]] && "$pn" -v 2>/dev/null || echo -)"
  fi
  printf '%s' "tree-pass v$_PP_CACHE_V gate=$(_pp_gate_id) tree=$t tier=$tier base=$mb parts=$parts $ids" \
    | sha1sum | cut -c1-40
}
_pp_tree_pass_has() {  # <key>
  [[ -n "$1" && "${PRE_PUSH_NO_CACHE:-0}" != 1 && -f "$_PP_PASS" ]] && grep -qxF "$1" "$_PP_PASS" 2>/dev/null
}
# Would this run, if green, vouch for the whole tree? (see the record above)
_pp_tree_pass_eligible() {  # <only>
  [[ -z "$1" && "${PRE_PUSH_LINT:-1}" != 0 && -z "${PRE_PUSH_LINT_ONLY:-}" ]]
}
_pp_tree_pass_add() {  # <key>
  [[ -n "$1" ]] || return 0
  local _PP_CACHE="$_PP_PASS"
  _pp_cache_add "$1"
}

# One verdict line per part, so an audit of a push answers itself.
_pp_verdict() {  # <part> <VERDICT> <secs> [detail]
  local who="${SPOOL_AGENT_ID:-${USER:-$(id -un 2>/dev/null)}}"
  local line
  line="$(date -u +%FT%TZ) $who PART $1 $2 ${3}s tree=$_PP_TOP HEAD=$_PP_HEAD${4:+ $4}"
  mkdir -p "$(dirname "$_PP_LOG")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$_PP_LOG" 2>/dev/null || true
}

# pnpm is often a user-local install (~/.local/bin) not on the minimal PATH a
# git hook or a `sudo -u <box-user> env` shell sees, so resolve it explicitly
# before deciding it is missing.
_pp_pnpm() {
  local c; c="$(command -v pnpm 2>/dev/null)" && { printf '%s' "$c"; return 0; }
  local p
  for p in "$HOME/.local/bin/pnpm" /usr/local/bin/pnpm /usr/bin/pnpm; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# The tools a part needs, checked BEFORE it runs. A missing tool used to fail
# the part on HEAD and on trunk alike, which read as "pre-existing" and let the
# push through untested (rc=127 'yq: command not found', CLE-77820). Prints one
# "<tool> -- <fix>" line per missing tool.
_pp_missing_tools() {  # <part> <tree>
  local part="$1" tree="$2"
  _pp_need() { command -v "$1" >/dev/null 2>&1 || echo "$1 -- $2"; }
  case "$part" in
    hygiene)
      _pp_need yq "install mikefarah yq v4 (https://github.com/mikefarah/yq) into /usr/local/bin" ;;
    iac)
      _pp_need yq "install mikefarah yq v4 (https://github.com/mikefarah/yq) into /usr/local/bin"
      _pp_need jq "apt-get install jq"
      _pp_need python3 "apt-get install python3" ;;
    orc)
      _pp_need yq "install mikefarah yq v4 (https://github.com/mikefarah/yq) into /usr/local/bin"
      _pp_need jq "apt-get install jq"
      _pp_need timeout "apt-get install coreutils" ;;
    wui-vendor) _pp_need grep "install grep" ;;
    blog)
      _pp_need yq "install mikefarah yq v4 (https://github.com/mikefarah/yq) into /usr/local/bin"
      _pp_need jq "apt-get install jq"
      _pp_need perl "apt-get install perl" ;;
    cnf)
      _pp_need yq "install mikefarah yq v4 (https://github.com/mikefarah/yq) into /usr/local/bin"
      _pp_tpl_gen_dir "$tree" >/dev/null || echo "tpl-gen -- cd csi-spl-iac && ./run -a do_setup_tpl_gen (in the main checkout)" ;;
    wui)
      _pp_pnpm >/dev/null || echo "pnpm -- corepack enable pnpm, or install it into ~/.local/bin"
      _pp_need node "install Node (the version in csi-spl-wui/package.json engines)" ;;
    api)
      _pp_need yq "install mikefarah yq v4 (https://github.com/mikefarah/yq) into /usr/local/bin"
      ( export GOTOOLCHAIN=local
        # shellcheck source=/dev/null
        source "$tree/csi-spl-api/src/bash/use-go-toolchain.sh" 2>/dev/null && spl_export_go_path 2>/dev/null
        command -v go >/dev/null 2>&1 ) \
        || echo "go -- install the Go in csi-spl-api/src/go/spool-hub-api/go.mod under /usr/local/go<ver>"
      [[ "${_PP_TIER:-fast}" == full ]] && { _pp_need gcc "apt-get install gcc (go test -race needs cgo)"; }
      [[ "${_PP_TIER:-fast}" == full ]] && { _pp_need docker "install docker and pull postgres:16-alpine (hub-pg)"; } ;;
    lint-*) _ppl_missing "$part" ;;
  esac
  return 0
}

# Every part runs under a hard timeout so the hook can never block a push
# forever: `timeout` returns 124, reported as "TIMED OUT", never a hang.
_pp_timeout="${PRE_PUSH_PART_TIMEOUT:-300}"
# hygiene is ~1 s and cannot hang, so it runs directly (no timeout, no subshell).
# The fleet rules drift check (csi-spl-orc, csi-spl-doc/doc/md/fleet-rules-index.md)
# rides along: under a second, read-only, red when two rule copies disagree.
_pp_part_hygiene() {
  local rc=0 drift="$1/csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh"
  HYGIENE_TREE="$1" do_check_dist_hygiene || rc=$?
  if [[ -r "$drift" ]]; then
    # shellcheck source=/dev/null
    ( source "$drift" && FLEET_RULES_TREE="$1" do_check_fleet_rules_drift ) || rc=1
  fi
  return "$rc"
}
# The FULL-tier api suite cannot fit 300 s: the hub Postgres gate alone is
# ~384 s. Measured uncapped on sat (n=3, GOFLAGS=-timeout=15m): 514 s at load
# 1.85 (master 712ff98d), 319 s at load 13.08 (848e20c0), 318 s (d5611241).
# 900 s is 1.75x the slowest; every full-tier push timed out at 300 s.
# The FULL-tier iac suite (IAC_TEST_TIER=full, 119 files) on sat, run alone
# (n=3, master 672ad2598): 191 s at load 18.7..37.6, 213 s at 37.6..16.8,
# 148 s at 16.8..15.7. Inside the gate at 00:10Z (2026-10-10) it passed 300 s
# and TIMED OUT, so every full-tier iac push failed (r5-07). 600 s is 1.75x
# that censored 300+ s (525 s), rounded up.
# The fast tier keeps the 300 s default; PRE_PUSH_PART_TIMEOUT overrides both.
_pp_full_timeout() {  # <full-tier default>
  if [[ -n "${PRE_PUSH_PART_TIMEOUT:-}" ]]; then echo "$PRE_PUSH_PART_TIMEOUT"
  elif [[ "${_PP_TIER:-fast}" == full ]]; then echo "$1"
  else echo "$_pp_timeout"; fi
}
# The budget a part runs under: the ONE source both the part's `timeout` and
# the TIMED OUT note read. The note used to print the shared 300 s for every
# part, so lanes whose api (900 s) or wui (420 s) budget ran out raised the
# wrong number (c-448, c-464, c-465, 2026-10-07).
_pp_budget() {  # <part-fn>
  case "$1" in
    _pp_part_api) _pp_full_timeout "${PRE_PUSH_API_FULL_TIMEOUT:-900}" ;;
    _pp_part_iac) _pp_full_timeout "${PRE_PUSH_IAC_FULL_TIMEOUT:-600}" ;;
    # the full tier runs every orc file: 16..17 min per CI shard of two
    _pp_part_orc) _pp_full_timeout "${PRE_PUSH_ORC_FULL_TIMEOUT:-1800}" ;;
    _pp_part_wui) echo "${PRE_PUSH_WUI_TIMEOUT:-420}" ;;
    *) echo "$_pp_timeout" ;;
  esac
}
_pp_part_api() {
  SPL_API_TEST_TIER="${_PP_TIER:-fast}" timeout -k 10 "$(_pp_budget _pp_part_api)" bash "$1/csi-spl-api/src/bash/tests/run-all-tests.sh"
}
_pp_part_iac() {
  IAC_TEST_TIER="${_PP_TIER:-fast}" timeout -k 10 "$(_pp_budget _pp_part_iac)" bash "$1/csi-spl-iac/src/bash/tests/run-all-tests.sh"
}
# An orc-only push ran no orc test, and orc was the real red in 7 of the 19 red
# workflow 10 runs among the last 100 on master (refactor round 5, action 07).
# FAST tier: the orc *.tst.sh that name a touched file or a function it
# defines, plus the always-run list (run-all-tests.sh --changed; the map is
# changed-tests.sh). When a touched orc file is named by no test the map falls
# back to every file (~10 min): the fast tier says so and leaves the suite to
# CI. FULL tier: every file, as CI runs it. Both then run bash-cleancode.
# The agent's SPOOL_* env is dropped (CI has none; an inherited SPOOL_BOX_TAG
# reddens orch-rotate). On the base-ref tree nothing has changed, so it is
# handed this push's change list: the trunk re-check runs the same files.
# <base> is _pp_run's own (bash scoping).
_pp_part_orc() {  # <tree>
  local t="$1/csi-spl-orc/src/bash/tests" rc=0 plan files="" v
  local -a envv=(env) args=()
  for v in $(compgen -e); do [[ "$v" == SPOOL_* ]] && envv+=(-u "$v"); done
  if [[ "${_PP_TIER:-fast}" != full ]]; then
    [[ "$1" != "$_PP_TOP" ]] && files="$(_pp_changed "$_PP_TOP" "$base")"
    envv+=(ORC_TEST_BASE="$base") args=(--changed)
    [[ -n "$files" ]] && envv+=(ORC_TEST_FILES="$files")
    plan="$(cd "$1" && "${envv[@]}" bash "$t/changed-tests.sh")"
    if grep -q '^full' <<<"$plan"; then
      echo "pre-push orc: $(grep '^full' <<<"$plan" | cut -f2) -- the orc map falls back to every file: left to CI workflow 10 (or PRE_PUSH_TIER=full)"
      args=()
    fi
  fi
  if [[ "${_PP_TIER:-fast}" == full || "${#args[@]}" -gt 0 ]]; then
    ( cd "$1" && timeout -k 10 "$(_pp_budget _pp_part_orc)" "${envv[@]}" bash "$t/run-all-tests.sh" "${args[@]}" ) || rc=$?
  fi
  bash "$1/csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh" || { [[ "$rc" -ne 0 ]] || rc=1; }
  return "$rc"
}
# The payment-vendor gate READS csi-spl-wui (it greps it) but LIVES in the api
# suite, so a WUI-only change used to skip it and a vendor word ("stripe") in a
# .vue comment reached trunk and failed hub deploy 20 twice. It is a fast,
# tree-relative grep, so run it whenever WUI changed -- selected by the tree it
# reads, not the tree it lives in.
_pp_part_wui_vendor() { bash "$1/csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh"; }
_pp_part_wui() {
  local wui="$1/csi-spl-wui" pn
  [[ -d "$wui" ]] || { do_log "FATAL pre-push: no csi-spl-wui at $wui"; return 1; }
  pn="$(_pp_pnpm)" || { do_log "FATAL pre-push: pnpm not found (checked PATH, ~/.local/bin, /usr/local/bin)"; return 1; }
  # unit (57 s) + typecheck (77..134 s) + a re-install (52 s) measured past the
  # 300 s default on a loaded box (CLE-77831): the wui part gets its own.
  timeout -k 10 "$(_pp_budget _pp_part_wui)" bash -c '
    cd "$1/csi-spl-wui" || exit 1
    export PATH="$HOME/.local/bin:$PATH"
    # A node_modules SYMLINK into another checkout (the stale shared one) made
    # a lane FAIL on packages its lockfile has (2026-10-01): replace the LINK
    # (never its target) with an install of its own. Re-install too when
    # the installed lock (pnpm keeps a copy) is not this pnpm-lock.yaml.
    if [[ -L node_modules ]]; then
      echo "pre-push: WUI node_modules is a symlink to $(readlink node_modules) -- replacing the link with an install of its own"
      rm -f node_modules || exit 1
    fi
    if [[ ! -d node_modules ]] || ! cmp -s pnpm-lock.yaml node_modules/.pnpm/lock.yaml; then
      echo "pre-push: WUI node_modules absent or built from another lockfile -- pnpm install --frozen-lockfile"
      "$2" install --frozen-lockfile || exit 1
    fi
    "$2" run test:unit || exit 1
    "$2" run typecheck  || exit 1
  ' _ "$1" "$pn"
}
# The blog post check (spec 111 4.4) on the post files THIS push adds or
# changes, plus the commit shape of <base>..HEAD, through the orc action. On
# the base-ref worktree nothing has changed, so it checks nothing and passes:
# a refused post is always this push's, never waived as "pre-existing".
# <base> is _pp_run's own (bash scoping).
_pp_part_blog() {  # <tree>
  local f files=""
  while IFS= read -r f; do
    [[ "$f" =~ ^csi-spl-doc/blog/posts/[^/]+/[^/]+\.md$ && -f "$1/$f" ]] && files+="$f "
  done < <(_pp_changed "$1" "$base")
  ( cd "$1/csi-spl-orc" && BLOG_TREE="$1" BLOG_FILES="${files:-none}" BLOG_CHECK_REF="$base" \
      BLOG_CHECK_RANGE="$base..HEAD" timeout -k 10 "$(_pp_budget _pp_part_blog)" ./run -a do_spl_blog_check )
}
# A cnf-only push (the env yaml and its render, nothing else) cannot break what
# the iac suite tests beyond the render itself, yet ran it for 6+ min (a 4-file
# workspace mapping, 2026-10-07). Code under csi-spl-cnf/src (conf-validator)
# is not "cnf-only": it still runs the suite. CI workflow 10 runs it anyway.
_pp_cnf_only() {  # <changed-list>
  local f n=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == csi-spl-cnf/csi-spl/* ]] || return 1
    n=$((n + 1))
  done <<< "$1"
  [[ "$n" -gt 0 ]]
}
# The tpl-gen clone with a venv: TPL_GEN_PATH, the tree's own, else the main
# checkout's (a lane worktree carries none; it is git-ignored).
_pp_tpl_gen_dir() {  # <tree>
  local c main
  main="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs -r dirname)"
  for c in "${TPL_GEN_PATH:-}" "$1/tpl-gen" "${main:+$main/tpl-gen}"; do
    [[ -n "$c" && -x "$c/src/python/tpl-gen/.venv/bin/python" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
# The content id of an env's rendered files in the working tree.
_pp_cnf_render_id() {  # <tree> <env>
  ( cd "$1/csi-spl-cnf/csi-spl" 2>/dev/null && find "$2/tf" "$2.env.json" -type f 2>/dev/null | sort | xargs -r sha1sum | sha1sum | cut -c1-40 )
}
# Re-render both envs in place (ENV=<env> do_tpl_gen): the render must not
# change, i.e. the committed tfvars/json are what the yaml renders to. A stale
# render is left re-rendered in the tree, ready to commit.
_pp_part_cnf() {  # <tree>
  local tree="$1" tg env before rc=0
  tg="$(_pp_tpl_gen_dir "$tree")" || { echo "FAIL: tpl-gen render -- no tpl-gen venv"; return 1; }
  for env in dev prd; do
    before="$(_pp_cnf_render_id "$tree" "$env")"
    if ! ( APP_PATH="$tree" PROJ_PATH="$tree/csi-spl-iac" ENV="$env" TPL_GEN_PATH="$tg" do_tpl_gen ); then
      echo "FAIL: tpl-gen render $env -- do_tpl_gen failed"; rc=1; continue
    fi
    if [[ "$(_pp_cnf_render_id "$tree" "$env")" != "$before" ]]; then
      echo "FAIL: tpl-gen render $env -- csi-spl-cnf/csi-spl/$env is stale: commit what ENV=$env ./run -a do_tpl_gen just wrote"
      git -C "$tree" status --short -- "csi-spl-cnf/csi-spl/$env" "csi-spl-cnf/csi-spl/$env.env.json"
      rc=1
    fi
  done
  return "$rc"
}
_pp_fn() {  # <part>
  case "$1" in
    hygiene) echo _pp_part_hygiene ;; iac) echo _pp_part_iac ;; api) echo _pp_part_api ;; cnf) echo _pp_part_cnf ;;
    orc) echo _pp_part_orc ;;
    wui) echo _pp_part_wui ;; wui-vendor) echo _pp_part_wui_vendor ;; blog) echo _pp_part_blog ;;
    lint-*) echo "_pp_part_${1//-/_}" ;;
  esac
}

# A single base-ref worktree, built lazily on the first failure and reused, so
# a FAILED part can be re-run against trunk: a failure that ALSO fails on trunk
# is pre-existing (someone else's red) and must NOT block this push -- that is
# the mutual-hook deadlock that stopped a fix from ever landing.
_PP_BASE_WT=""
# Sets _PP_BASE_WT; call it directly, never in $(...): the subshell dropped
# the variable, so the end-of-run cleanup never saw the worktree and EVERY
# pre-existing re-check leaked one into the shared .git (132 by 2026-10-01).
_pp_baseline_tree() {  # <tree> <base>
  [[ -n "$_PP_BASE_WT" ]] && return 0
  git -C "$1" rev-parse --verify -q "$2^{commit}" >/dev/null 2>&1 || return 1
  # Named for this process, so a later run can tell a dead run's leftover
  # (_pp_baseline_reap) from a live one's.
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-pre-push-base.$$.XXXXXX" 2>/dev/null)" || return 1
  if git -C "$1" worktree add --detach -q "$tmp" "$2" >/dev/null 2>&1; then
    _PP_BASE_WT="$tmp"; return 0
  fi
  rmdir "$tmp" 2>/dev/null; return 1
}
# A killed hook (timeout, Ctrl-C, a closed pane) used to leave its baseline
# worktree registered in the SHARED .git: 132 /tmp/tmp.* entries piled up by
# 2026-10-01. The trap in do_check_pre_push removes it on INT/TERM/HUP; this
# reaps the ones a SIGKILL left, i.e. whose owning pid is gone.
_pp_baseline_reap() {  # <tree>
  local wt pid
  git -C "$1" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | grep -E '/csi-spl-pre-push-base\.[0-9]+\.[^/]+$' | while IFS= read -r wt; do
      pid="${wt##*/csi-spl-pre-push-base.}"; pid="${pid%%.*}"
      kill -0 "$pid" 2>/dev/null && continue
      git -C "$1" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    done
  git -C "$1" worktree prune 2>/dev/null || true
}
_pp_baseline_cleanup() {  # <tree>
  [[ -n "$_PP_BASE_WT" ]] || return 0
  git -C "$1" worktree remove --force "$_PP_BASE_WT" >/dev/null 2>&1 || rm -rf "$_PP_BASE_WT"
  _PP_BASE_WT=""
}

# The pidfile of the run gating <tree>: one per checkout, so a stop in one lane
# never reaches another lane's run on the same box and user.
_pp_pidfile() {  # <tree>
  local h; h="$(printf '%s' "$1" | sha1sum | cut -c1-12)"
  echo "${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/pre-push.$h.pid"
}
# Start time of <pid> in clock ticks (/proc stat field 22): a pid plus its start
# time names one process even after the pid is re-used.
_pp_starttime() {  # <pid>
  local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"; awk '{ print $20 }' <<<"$s"
}
# Remove the pidfile only while it still names this run (a newer run on the same
# tree may have replaced it).
_pp_pidfile_drop() {
  [[ -n "${_PP_PIDFILE:-}" ]] || return 0
  local pid; read -r pid _ <"$_PP_PIDFILE" 2>/dev/null || return 0
  [[ "$pid" == "$_PP_PID" ]] && rm -f "$_PP_PIDFILE"
  return 0
}

_pp_record() {  # <label> <STAT> <secs>
  _PP_NAMES+=("$1"); _PP_STAT+=("$2"); _PP_SECS+=("$3")
}

# Run one part: cached green -> PASS-cached; missing tool -> FAIL (never a
# pre-existing WARN); else run it, and on failure re-run it on the base ref and
# BLOCK only when it passes there. Optional <part> keys the cache and the log;
# without it (the tests' stub parts) neither is touched.
_pp_run() {  # <label> <fn> <tree> <base> [<part>]
  local label="$1" fn="$2" tree="$3" base="$4" part="${5:-}"
  local start="$SECONDS" rc=0 key="" missing="" el
  if [[ -n "$part" ]]; then
    key="$(_pp_key "$tree" "$part" "$_PP_TIER")"
    if _pp_cache_has "$key"; then
      _pp_record "$label (green verdict re-used: its paths are unchanged)" "PASS" 0
      _pp_verdict "$part" PASS-cached 0 "key=${key:0:12}"
      do_log "INFO pre-push: PASS $label (cached: nothing under $(_pp_paths "$part") changed since it was green)"
      return 0
    fi
    missing="$(_pp_missing_tools "$part" "$tree")"
    if [[ -n "$missing" ]]; then
      _pp_record "$label (MISSING TOOL: $(cut -d' ' -f1 <<<"$missing" | paste -sd, -))" "FAIL" 0
      _PP_FAILED=$((_PP_FAILED + 1))
      _pp_verdict "$part" FAIL 0 "missing-tool=$(cut -d' ' -f1 <<<"$missing" | paste -sd, -)"
      while IFS= read -r m; do do_log "FATAL pre-push: $label cannot run -- missing tool: $m"; done <<<"$missing"
      return 0
    fi
  fi
  do_log "INFO pre-push: ==> $label"
  local out; out="$(mktemp "${TMPDIR:-/tmp}/csi-spl-pre-push-out.XXXXXX")"
  _pp_capture "$out" "$fn" "$tree" || rc=$?
  el=$((SECONDS - start))
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$out"
    _pp_record "$label" "PASS" "$el"
    [[ -n "$part" ]] && { _pp_cache_add "$key"; _pp_verdict "$part" PASS "$el"; }
    do_log "INFO pre-push: PASS $label (${el}s)"
    return 0
  fi
  local note="rc=$rc"; [[ "$rc" -eq 124 || "$rc" -eq 137 ]] && note="TIMED OUT after $(_pp_budget "$fn")s"
  if [[ "$rc" -eq 127 ]]; then
    # command not found: an environment gap, never "pre-existing on trunk"
    _pp_record "$label (rc=127: a command was not found)" "FAIL" "$el"; _PP_FAILED=$((_PP_FAILED + 1))
    [[ -n "$part" ]] && _pp_verdict "$part" FAIL "$el" "rc=127-command-not-found"
    do_log "FATAL pre-push: FAIL $label -- rc=127, a command it needs is not installed (see the output above)"
    rm -f "$out"; return 0
  fi
  # Pre-existing on trunk? Re-run the SAME part against the base ref.
  local bwt brc=0 bsha bout="" tsig bsig=""
  bsha="$(git -C "$tree" rev-parse --short "$base" 2>/dev/null || echo '?')"
  tsig="$(_pp_sig "$out" "$tree")"
  if _pp_baseline_tree "$tree" "$base"; then
    bwt="$_PP_BASE_WT"
    bout="$(mktemp "${TMPDIR:-/tmp}/csi-spl-pre-push-out.XXXXXX")"
    do_log "INFO pre-push: $label failed ($note) -- re-checking it on $base ($bsha) to see if it is your break or trunk's"
    _pp_capture "$bout" "$fn" "$bwt" || brc=$?
    bsig="$(_pp_sig "$bout" "$bwt")"
  else
    do_log "WARN pre-push: could not build a $base baseline for $label -- treating the failure as NEW"
  fi
  rm -f "$out" ${bout:+"$bout"}
  el=$((SECONDS - start))
  if [[ "$brc" -eq 0 ]]; then
    _pp_record "$label" "FAIL" "$el"; _PP_FAILED=$((_PP_FAILED + 1))
    [[ -n "$part" ]] && _pp_verdict "$part" FAIL "$el" "$note trunk=$bsha-green"
    do_log "FATAL pre-push: FAIL $label ($note) -- a NEW failure your commits introduce"
    return 0
  fi
  _pp_compare "$label" "$part" "$el" "$note" "$base" "$bsha" "$tsig" "$bsig"
}

# A part's output is tee'd to <file> as it streams (stdout + stderr), and the
# part runs in THIS shell (a process substitution, not a pipeline), so its rc
# is its own and nothing it sets is lost.
_pp_capture() {  # <file> <fn> <tree>
  local f="$1" fn="$2" rc=0; shift 2
  "$fn" "$@" > >(tee "$f") 2>&1 || rc=$?
  wait $! 2>/dev/null || true
  return "$rc"
}

# The FAILURE SIGNATURE of a part's output: one normalised item per failing
# thing, sorted, unique. "Pre-existing" is decided on these, never on the rc
# alone: c-304's new gofmt + TestCleanCodeGate failures (2026-10-05) hid
# behind an unrelated trunk red because both trees merely exited non-zero.
#   go-test <Name>         '--- FAIL: <Name>'          go-pkg <pkg>  'FAIL<tab><pkg> ...'
#   gofmt <file>           the list after 'gofmt needed on:'
#   diag <file>: <msg>     'file.ext:L[:C]: msg' (vet, compile, shellcheck,
#                          hygiene, ruff), 'file.ts(L,C): error ...',
#                          'file.vue:L:C - error ...' -- line:col dropped,
#                          so an edit above a trunk finding does not "move" it
#   fail <desc>            bash 'FAIL: <desc> -- <detail>' / 'FAIL - <desc>' (detail dropped)
#   suite <file>           'FAILED: <file>' (the iac/orc suite runners)
#   timeout <file>         'TIMED OUT ... killed: <file>'
#   test <title>           TAP 'not ok N - <title>', node '✖ <title>'
#   e2e <spec> › <title>   playwright '✘ ... › <spec> › <title>'
#   lint <line>            'SYNTAX ...:', 'COMPOSE schema:', 'HCL parse:',
#                          'LOCKFILE', 'GO MOD:', 'terraform fmt:'
#   panic <msg>            'panic: <msg>'
# Normalised: the tree root (a bare mention reads <tree>), /tmp and $TMPDIR
# paths (CI's TMPDIR is not /tmp), hex ids (7+), colour codes and a
# trailing duration are stripped, so the same failure reads the same on both
# trees. An output with no such line yields an EMPTY signature.
_pp_sig() {  # <output-file> <tree-root>
  [[ -s "$1" ]] || return 0
  local tmpd="${TMPDIR:-/tmp}"
  awk -v root="${2%/}" -v tmpd="${tmpd%/}" '
    function lit(s, a, b,   i, o) { o = ""; if (a == "" || a == "/tmp") return s
      while ((i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
      return o s }
    function norm(s) {
      s = lit(s, root "/", ""); s = lit(s, root, "<tree>"); s = lit(s, tmpd "/", "/tmp/")
      gsub(/\033\[[0-9;]*[A-Za-z]/, "", s); gsub(/\r/, "", s)
      gsub(/\/tmp\/[^ \t:\047")]*/, "<tmp>", s)
      gsub(/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*/, "<sha>", s)
      sub(/[ \t]*\(?[0-9]+(\.[0-9]+)?m?s\)?[ \t]*$/, "", s)
      gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
      return s }
    function emit(kind, s) { s = norm(s); if (s != "") print kind " " s }
    function after(s, re) { if (match(s, re)) return substr(s, RSTART + RLENGTH); return s }
    { line = $0; gsub(/\033\[[0-9;]*[A-Za-z]/, "", line) }
    fmt && line ~ /^[ \t]*[^ \t]+\.go[ \t]*$/ { emit("gofmt", line); next }
    { fmt = 0 }
    line ~ /^gofmt needed on:/ { fmt = 1; next }
    line ~ /--- FAIL: / { s = after(line, "--- FAIL: "); sub(/ .*/, "", s); emit("go-test", s); next }
    line ~ /^[ \t]*FAIL(:| -) / { s = after(line, "FAIL(:| -) "); sub(/ -- .*/, "", s); emit("fail", s); next }
    line ~ /^FAIL[ \t]+[^ \t]+/ { split(line, f, /[ \t]+/); emit("go-pkg", f[2]); next }
    line ~ /^FAILED: / { s = after(line, "^FAILED: "); sub(/ .*/, "", s); emit("suite", s); next }
    line ~ /TIMED OUT .*killed: / { s = after(line, "killed: "); emit("timeout", s); next }
    line ~ /^[ \t]*not ok [0-9]+ / { s = after(line, "not ok [0-9]+ (- )?"); sub(/ # .*/, "", s); emit("test", s); next }
    line ~ /^[ \t]*✖ / { emit("test", after(line, "✖ ")); next }
    line ~ /✘/ && line ~ /›/ { s = after(line, "\\] › "); gsub(/:[0-9]+:[0-9]+/, "", s); emit("e2e", s); next }
    line ~ /^[ \t]*panic: / { emit("panic", after(line, "panic: ")); next }
    line ~ /^(SYNTAX [^:]*|COMPOSE schema|HCL parse|LOCKFILE|GO MOD|terraform fmt):? / { emit("lint", line); next }
    line ~ /^[^ \t]+\([0-9]+,[0-9]+\): / {
      s = line; p = index(s, "("); f1 = substr(s, 1, p - 1); emit("diag", f1 ": " after(s, "\\([0-9]+,[0-9]+\\): ")); next }
    line ~ /^[ \t]*(vet: )?[^ \t:]+\.[A-Za-z0-9]+:[0-9]+(:[0-9]+)?(:| - )/ {
      s = line; sub(/^[ \t]*(vet: )?/, "", s); f1 = s; sub(/:.*/, "", f1); sub(/^\.\//, "", f1)
      emit("diag", f1 ": " after(s, ":[0-9]+(:[0-9]+)?(:| - )[ \\t]*")); next }
  ' "$1" | sort -u
}

# Block or WARN on two failure signatures: WARN-pre-existing only when every
# item failing on the tree also fails on the base; an empty tree signature
# (nothing parseable) BLOCKS -- fail closed, never "pre-existing" by default.
_pp_compare() {  # <label> <part> <secs> <note> <base> <bsha> <tree-sig> <base-sig>
  local label="$1" part="$2" el="$3" note="$4" base="$5" bsha="$6" tsig="$7" bsig="$8" new old
  if [[ -z "$tsig" ]]; then
    _pp_record "$label (no parseable failure to compare with $base $bsha)" "FAIL" "$el"; _PP_FAILED=$((_PP_FAILED + 1))
    [[ -n "$part" ]] && _pp_verdict "$part" FAIL "$el" "$note trunk=$bsha-red unparseable"
    do_log "FATAL pre-push: FAIL $label ($note) -- it fails on $base $bsha too, but its output names no failing item to compare (fail closed: blocked, not pre-existing)"
    return 0
  fi
  new="$(comm -23 <(printf '%s\n' "$tsig") <(printf '%s\n' "$bsig" | sed '/^$/d') | paste -sd';' -)"
  old="$(comm -12 <(printf '%s\n' "$tsig") <(printf '%s\n' "$bsig" | sed '/^$/d') | paste -sd';' -)"
  if [[ -n "$new" ]]; then
    _pp_record "$label (NEW on your tree: $new)" "FAIL" "$el"; _PP_FAILED=$((_PP_FAILED + 1))
    [[ -n "$part" ]] && _pp_verdict "$part" FAIL "$el" "$note trunk=$bsha-red new=$(tr ';' '\n' <<<"$new" | wc -l)"
    do_log "FATAL pre-push: FAIL $label ($note) -- $base $bsha is red too, but NOT with these: NEW on your tree: $new"
    [[ -n "$old" ]] && do_log "INFO pre-push: $label pre-existing: $old"
    return 0
  fi
  _pp_record "$label (PRE-EXISTING on $base $bsha)" "WARN" "$el"; _PP_PREEXIST=$((${_PP_PREEXIST:-0} + 1))
  [[ -n "$part" ]] && _pp_verdict "$part" WARN-pre-existing "$el" "trunk=$bsha $note"
  do_log "WARN pre-push: $label fails on your tree AND on $base $bsha ($note) with the same failures -- pre-existing: $old -- NOT blocking your push"
  return 0
}

do_check_pre_push() {
  local tree="${PRE_PUSH_TREE:-$APP_PATH}"
  local mode="${PRE_PUSH_MODE:-fast}"
  local base="${PRE_PUSH_BASE:-origin/master}"
  local _PP_TIER="${PRE_PUSH_TIER:-fast}"
  case "$mode" in fast|full) ;; *) do_log "FATAL pre-push: PRE_PUSH_MODE must be fast or full (got '$mode')"; return 2 ;; esac
  case "$_PP_TIER" in fast|full) ;; *) do_log "FATAL pre-push: PRE_PUSH_TIER must be fast or full (got '$_PP_TIER')"; return 2 ;; esac
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 \
    || { do_log "FATAL pre-push: $tree is not a git checkout"; return 2; }
  # A git hook can inherit a stripped PATH (measured 2026-10-01: a lane's push
  # FAILed missing-tool=yq with yq in /usr/local/bin). APPEND the usual install
  # dirs, as _pp_pnpm does, so a present tool is found; an absent one still FAILs.
  local extra="${PRE_PUSH_EXTRA_PATH-/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin}"
  [[ -n "$extra" ]] && export PATH="$PATH:$extra"
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl"
  local _PP_LOG="${PRE_PUSH_LOG:-$cache_dir/pre-push.log}"
  local _PP_CACHE="${PRE_PUSH_CACHE:-$cache_dir/pre-push.parts.green}"
  local _PP_PASS="${PRE_PUSH_PASS:-$(dirname "$_PP_CACHE")/pre-push.tree.pass}" _PP_SKIP="${PRE_PUSH_SKIP_PASSED:-0}"
  # Not inherited by the parts: the iac suite's own tests run this gate on
  # throwaway trees, and must neither skip on nor write to the caller's record.
  export -n PRE_PUSH_SKIP_PASSED PRE_PUSH_PASS 2>/dev/null || true
  local _PP_TOP="$tree" _PP_HEAD
  _PP_HEAD="$(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo '?')"

  local only="${PRE_PUSH_ONLY:-}"
  case "$only" in ''|lint|override) ;; *) do_log "FATAL pre-push: PRE_PUSH_ONLY must be empty, lint or override (got '$only')"; return 2 ;; esac
  local all="hygiene blog iac orc wui-vendor wui api" parts="hygiene" p changed="" lint
  local -A _PPL_FILES=()
  local _PPL_SELECTED=""
  if [[ "$mode" == full ]]; then
    parts="$all"
  elif ! changed="$(_pp_changed "$tree" "$base")"; then
    do_log "WARN pre-push: cannot diff against '$base' (unknown ref?) -- widening to FULL so no gate is skipped silently"
    mode=full; parts="$all"
  else
    for p in blog iac orc wui-vendor wui api; do
      local sel="$changed"
      # wui: an edit to an existing e2e/bench file is not a wui input (CLE-77946:
      # an e2e-only lane re-ran the 150..260 s part after every rebase and lost
      # the trunk race 12 times in a row)
      [[ "$p" == wui ]] && sel="$(_pp_wui_select "$changed" "$tree" "$base")"
      # shellcheck disable=SC2046
      _pp_touches "$sel" $(_pp_paths "$p") && parts+=" $p"
    done
    _pp_cnf_only "$changed" && parts="${parts/ iac/ cnf}"
  fi
  # The lint parts run right after hygiene: seconds, and the likeliest red.
  if [[ "$only" == override ]]; then
    # The override skips the slow parts, never these: c-226's override landed
    # a duplicate migration 0119 that lint-migration refuses in a second.
    PRE_PUSH_LINT=1 PRE_PUSH_LINT_ONLY=lint-migration _ppl_plan "$changed" "$mode" "$_PP_TIER" "$tree"
    lint="$_PPL_SELECTED"
    parts="hygiene${lint:+ $lint}"; all="hygiene lint-migration"
  else
    _ppl_plan "$changed" "$mode" "$_PP_TIER" "$tree"; lint="$_PPL_SELECTED"
    local lint_all="$_PPL_FAST"; [[ "$_PP_TIER" == full ]] && lint_all+=" $_PPL_SLOW"
    all="hygiene $lint_all blog cnf iac orc wui-vendor wui api"
    parts="${parts/hygiene/hygiene${lint:+ $lint}}"
    [[ "$only" == lint ]] && { parts="$lint"; all="$lint_all"; }
  fi

  # A machine-readable plan line (also the whole of PLAN mode's output).
  echo "PRE_PUSH_PLAN mode=$mode tier=$_PP_TIER parts=$parts"
  if [[ "${PRE_PUSH_PLAN:-0}" == 1 ]]; then
    do_log "INFO pre-push PLAN only (mode=$mode tier=$_PP_TIER): $parts"
    return 0
  fi

  # The hook's second run on a tree this gate already passed whole: skip it.
  local tkey=""
  _pp_tree_pass_eligible "$only" && tkey="$(_pp_tree_key "$tree" "$_PP_TIER" "$parts" "$base")"
  if [[ "$_PP_SKIP" == 1 ]] && _pp_tree_pass_has "$tkey"; then
    _pp_verdict tree PASS-tree 0 "key=${tkey:0:12} parts=${parts// /,}"
    do_log "INFO pre-push: PASS -- this exact tree ($(git -C "$tree" rev-parse --short 'HEAD^{tree}' 2>/dev/null)) already passed every part above (key ${tkey:0:12}); nothing re-run"
    return 0
  fi

  do_log "INFO pre-push: mode=$mode tier=$_PP_TIER base=$base parts: $parts"
  [[ "$_PP_TIER" == fast ]] && do_log "INFO pre-push: fast tier -- go test -race, hub-pg, hub-gcs, build-stripped and the slow iac tests (terraform validate, tpl-gen renders) run in CI workflow 10/20, not here"

  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=()
  local _PP_FAILED=0 _PP_PREEXIST=0
  _pp_baseline_reap "$tree"
  # Record this run so do_stop_pre_push can stop it by pid -- never by a
  # pattern (`pkill -f do_check_pre_push` also matches every agent's argv).
  local _PP_PID="$BASHPID" _PP_PIDFILE="${PRE_PUSH_PIDFILE:-$(_pp_pidfile "$tree")}"
  mkdir -p "$(dirname "$_PP_PIDFILE")" 2>/dev/null || true
  printf '%s %s %s %s\n' "$_PP_PID" "$(ps -o pgid= -p "$_PP_PID" 2>/dev/null | tr -d ' ')" \
    "$(_pp_starttime "$_PP_PID")" "$tree" >"$_PP_PIDFILE" 2>/dev/null \
    || do_log "WARN pre-push: cannot write $_PP_PIDFILE -- do_stop_pre_push will not find this run"
  # a kill mid-run must not leave the baseline worktree (or the pidfile) behind
  local _pp_old_traps; _pp_old_traps="$(trap -p INT TERM HUP)"
  # shellcheck disable=SC2064
  trap "_pp_baseline_cleanup '$tree'; _pp_pidfile_drop; exit 130" INT
  # shellcheck disable=SC2064
  trap "_pp_baseline_cleanup '$tree'; _pp_pidfile_drop; exit 143" TERM
  # shellcheck disable=SC2064
  trap "_pp_baseline_cleanup '$tree'; _pp_pidfile_drop; exit 129" HUP
  for p in $all; do
    if [[ " $parts " == *" $p "* ]]; then
      _pp_run "$(_pp_label "$p")" "$(_pp_fn "$p")" "$tree" "$base" "$p"
    else
      _pp_verdict "$p" SKIP-untouched 0
    fi
  done

  [[ -n "$changed" && "${PRE_PUSH_LINT:-1}" != 0 && "$only" != override ]] && _ppl_typos "$changed" "$tree"
  # spec 065 L2: every pushed commit carries its release note -- WARN only, never blocks
  [[ "${PRE_PUSH_LINT:-1}" != 0 && "$only" != override ]] && { declare -F _pp_release_note >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/check-release-note.func.sh"; } && _pp_release_note "$tree" "$base"

  _pp_baseline_cleanup "$tree"
  _pp_pidfile_drop
  trap - INT TERM HUP
  [[ -n "$_pp_old_traps" ]] && eval "$_pp_old_traps"

  echo ""
  echo "============ pre-push summary (mode=$mode tier=$_PP_TIER) ============"
  local i
  for i in "${!_PP_NAMES[@]}"; do
    printf '  %-4s %5ss  %s\n' "${_PP_STAT[$i]}" "${_PP_SECS[$i]}" "${_PP_NAMES[$i]}"
  done
  echo "======================================================================"

  if [[ "$_PP_FAILED" -gt 0 ]]; then
    do_log "FATAL pre-push: $_PP_FAILED part(s) FAILED -- do not push until green"
    return 1
  fi
  # Record the whole-tree pass: every part PASS (a pre-existing red is not;
  # the advisory typos / release-note WARNs are), and the tree unchanged since
  # the plan (a part such as cnf can rewrite it).
  if [[ -n "$tkey" && "$_PP_PREEXIST" -eq 0 ]] \
     && [[ "$(_pp_tree_key "$tree" "$_PP_TIER" "$parts" "$base")" == "$tkey" ]]; then
    _pp_tree_pass_add "$tkey"
  fi
  do_log "INFO pre-push: all parts PASSED -- safe to push"
  return 0
}
