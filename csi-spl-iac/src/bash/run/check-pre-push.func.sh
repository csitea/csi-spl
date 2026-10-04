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
# @description   lint-*      the scanner workflows (61..67, 85) + syntax, on the
# @description               TOUCHED files only -- check-pre-push-lint.func.sh
# @description   A push that touches none of a part's paths never runs it (it is
# @description   logged SKIP-untouched), so an orc- or doc-only push runs hygiene.
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
# @param PRE_PUSH_NO_CACHE (optional) - 1 = ignore the green cache (always run)
# @param PRE_PUSH_PART_TIMEOUT (optional) - seconds per part, default 300
# @param PRE_PUSH_WUI_TIMEOUT (optional) - seconds for the wui part, default 420
# @param PRE_PUSH_ONLY (optional) - lint = only the lint parts (do_check_pre_push_lint);
# @param        override = only the seconds-cheap correctness parts, hygiene + lint-migration
# @param        (what the hook still runs under SPL_PREPUSH_OVERRIDE=1; PRE_PUSH_LINT=0 cannot drop them)
# @param PRE_PUSH_EXTRA_PATH (optional) - dirs appended to PATH before the tool check, default /usr/local/bin:/usr/bin:/bin:~/.local/bin
# @example ./run -a do_check_pre_push
# @example PRE_PUSH_MODE=full PRE_PUSH_TIER=full ./run -a do_check_pre_push
# @example PRE_PUSH_PLAN=1 ./run -a do_check_pre_push
#------------------------------------------------------------------------------

# The lint parts live beside this file; the run loader sources both, a test
# that sources only this one gets them too.
declare -F _ppl_plan >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/check-pre-push-lint.func.sh"

# Bumped whenever what a part RUNS changes, so an old green cannot vouch for a
# new gate.
_PP_CACHE_V=6

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
#   - it names a DIRECTORY on a line that reads it (join, readFileSync,
#     readdirSync, existsSync, statSync, cpSync): join(REPO, '.github/workflows', wf).
# A directory named only as fixture data or in a message is NOT an input
# (2026-10-04: the 'csi-spl-doc/specs' fixture in docs.test.mjs made every
# spec tasks.md edit select the 5-min part and miss its cache; 4 lanes lost
# the trunk race to it within an hour). Before CLE-77946 none of them selected
# the wui part or keyed its cache, so a msg.go change re-used a green verdict
# the unit suite no longer gave.
_PP_WUI_EXT_RE='(csi-spl-(api|cnf|dat|doc|iac|orc|rdb|utl)|\.github)/[A-Za-z0-9_./-]*(\$\{[^}]*\}[A-Za-z0-9_./-]*)*'
_pp_wui_external() {  # <tree>
  local top="$1" wui="$1/csi-spl-wui" line m reads
  [[ -d "$wui/tests/unit" ]] || return 0
  local -a srcs=("$wui"/tests/unit/*.mjs)
  if [[ -d "$wui/src/node" ]]; then
    while IFS= read -r m; do srcs+=("$m"); done < <(find "$wui/src/node" -name '*.mjs' -not -path '*/node_modules/*' 2>/dev/null | sort)
  fi
  grep -hvE '^[[:space:]]*(//|\*)|mkdirSync|writeFileSync' "${srcs[@]}" 2>/dev/null \
    | grep -E "$_PP_WUI_EXT_RE" | while IFS= read -r line; do
      reads=0
      [[ "$line" =~ (join|readFileSync|readdirSync|existsSync|statSync|cpSync)\( ]] && reads=1
      while IFS= read -r m; do
        [[ -n "$m" && "$m" != *...* ]] || continue
        if [[ "$m" == *'${'* ]]; then
          sed -E 's/\$\{[^}]*\}/*/g' <<<"$m"
          continue
        fi
        while [[ "$m" == */ ]]; do m="${m%/}"; done
        if [[ -f "$top/$m" ]] || [[ "$reads" == 1 && -d "$top/$m" ]]; then echo "$m"; fi
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
    wui-vendor) _pp_need grep "install grep" ;;
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
_pp_part_hygiene() { HYGIENE_TREE="$1" do_check_dist_hygiene; }
_pp_part_api() {
  SPL_API_TEST_TIER="${_PP_TIER:-fast}" timeout -k 10 "$_pp_timeout" bash "$1/csi-spl-api/src/bash/tests/run-all-tests.sh"
}
_pp_part_iac() {
  IAC_TEST_TIER="${_PP_TIER:-fast}" timeout -k 10 "$_pp_timeout" bash "$1/csi-spl-iac/src/bash/tests/run-all-tests.sh"
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
  timeout -k 10 "${PRE_PUSH_WUI_TIMEOUT:-420}" bash -c '
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
_pp_fn() {  # <part>
  case "$1" in
    hygiene) echo _pp_part_hygiene ;; iac) echo _pp_part_iac ;; api) echo _pp_part_api ;;
    wui) echo _pp_part_wui ;; wui-vendor) echo _pp_part_wui_vendor ;;
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
  "$fn" "$tree" || rc=$?
  el=$((SECONDS - start))
  if [[ "$rc" -eq 0 ]]; then
    _pp_record "$label" "PASS" "$el"
    [[ -n "$part" ]] && { _pp_cache_add "$key"; _pp_verdict "$part" PASS "$el"; }
    do_log "INFO pre-push: PASS $label (${el}s)"
    return 0
  fi
  local note="rc=$rc"; [[ "$rc" -eq 124 || "$rc" -eq 137 ]] && note="TIMED OUT after ${_pp_timeout}s"
  if [[ "$rc" -eq 127 ]]; then
    # command not found: an environment gap, never "pre-existing on trunk"
    _pp_record "$label (rc=127: a command was not found)" "FAIL" "$el"; _PP_FAILED=$((_PP_FAILED + 1))
    [[ -n "$part" ]] && _pp_verdict "$part" FAIL "$el" "rc=127-command-not-found"
    do_log "FATAL pre-push: FAIL $label -- rc=127, a command it needs is not installed (see the output above)"
    return 0
  fi
  # Pre-existing on trunk? Re-run the SAME part against the base ref.
  local bwt brc=0 bsha
  bsha="$(git -C "$tree" rev-parse --short "$base" 2>/dev/null || echo '?')"
  if _pp_baseline_tree "$tree" "$base"; then
    bwt="$_PP_BASE_WT"
    do_log "INFO pre-push: $label failed ($note) -- re-checking it on $base ($bsha) to see if it is your break or trunk's"
    "$fn" "$bwt" || brc=$?
  else
    do_log "WARN pre-push: could not build a $base baseline for $label -- treating the failure as NEW"
    brc=0
  fi
  el=$((SECONDS - start))
  if [[ "$brc" -ne 0 ]]; then
    _pp_record "$label (PRE-EXISTING on $base $bsha)" "WARN" "$el"
    [[ -n "$part" ]] && _pp_verdict "$part" WARN-pre-existing "$el" "trunk=$bsha $note"
    do_log "WARN pre-push: $label fails on your tree AND on $base $bsha ($note) -- pre-existing trunk failure, NOT blocking your push"
  else
    _pp_record "$label" "FAIL" "$el"; _PP_FAILED=$((_PP_FAILED + 1))
    [[ -n "$part" ]] && _pp_verdict "$part" FAIL "$el" "$note trunk=$bsha-green"
    do_log "FATAL pre-push: FAIL $label ($note) -- a NEW failure your commits introduce"
  fi
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
  local _PP_TOP="$tree" _PP_HEAD
  _PP_HEAD="$(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo '?')"

  local only="${PRE_PUSH_ONLY:-}"
  case "$only" in ''|lint|override) ;; *) do_log "FATAL pre-push: PRE_PUSH_ONLY must be empty, lint or override (got '$only')"; return 2 ;; esac
  local all="hygiene iac wui-vendor wui api" parts="hygiene" p changed="" lint
  local -A _PPL_FILES=()
  local _PPL_SELECTED=""
  if [[ "$mode" == full ]]; then
    parts="$all"
  elif ! changed="$(_pp_changed "$tree" "$base")"; then
    do_log "WARN pre-push: cannot diff against '$base' (unknown ref?) -- widening to FULL so no gate is skipped silently"
    mode=full; parts="$all"
  else
    for p in iac wui-vendor wui api; do
      local sel="$changed"
      # wui: an edit to an existing e2e/bench file is not a wui input (CLE-77946:
      # an e2e-only lane re-ran the 150..260 s part after every rebase and lost
      # the trunk race 12 times in a row)
      [[ "$p" == wui ]] && sel="$(_pp_wui_select "$changed" "$tree" "$base")"
      # shellcheck disable=SC2046
      _pp_touches "$sel" $(_pp_paths "$p") && parts+=" $p"
    done
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
    all="hygiene $lint_all iac wui-vendor wui api"
    parts="${parts/hygiene/hygiene${lint:+ $lint}}"
    [[ "$only" == lint ]] && { parts="$lint"; all="$lint_all"; }
  fi

  # A machine-readable plan line (also the whole of PLAN mode's output).
  echo "PRE_PUSH_PLAN mode=$mode tier=$_PP_TIER parts=$parts"
  if [[ "${PRE_PUSH_PLAN:-0}" == 1 ]]; then
    do_log "INFO pre-push PLAN only (mode=$mode tier=$_PP_TIER): $parts"
    return 0
  fi

  do_log "INFO pre-push: mode=$mode tier=$_PP_TIER base=$base parts: $parts"
  [[ "$_PP_TIER" == fast ]] && do_log "INFO pre-push: fast tier -- go test -race, hub-pg, hub-gcs, build-stripped and the slow iac tests (terraform validate, tpl-gen renders) run in CI workflow 10/20, not here"

  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=()
  local _PP_FAILED=0
  _pp_baseline_reap "$tree"
  # a kill mid-run must not leave the baseline worktree behind
  local _pp_old_traps; _pp_old_traps="$(trap -p INT TERM HUP)"
  # shellcheck disable=SC2064
  trap "_pp_baseline_cleanup '$tree'; exit 130" INT
  # shellcheck disable=SC2064
  trap "_pp_baseline_cleanup '$tree'; exit 143" TERM
  # shellcheck disable=SC2064
  trap "_pp_baseline_cleanup '$tree'; exit 129" HUP
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
  do_log "INFO pre-push: all parts PASSED -- safe to push"
  return 0
}
