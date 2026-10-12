#!/bin/bash
#------------------------------------------------------------------------------
# @description The pre-push part `wui-e2e` (spec 133 action 7, L6): the browser
# @description e2e files a WUI change touches, run before the push against a
# @description generated mock bundle, under a time cap. Before it, a WUI
# @description change met its e2e only in CI, minutes after it had landed.
# @description THE MAP (change -> tests/e2e/*.test.mjs), read from the tree so
# @description it cannot go stale:
# @description   an edited e2e test           itself (score 100)
# @description   an edited tests/e2e helper   the tests that name its file
# @description   a WUI source file            the tests that name a testid it
# @description                                declares (data-testid="x", a
# @description                                testid prop, or the static prefix
# @description                                of a bound one: 'pane-divider-'),
# @description                                weight 3; then the same for the
# @description                                files that use it (its exported
# @description                                names, its component name), weight
# @description                                2, and their users, weight 1
# @description Never a ci-skip.txt file or a *.proof.mjs. The highest score
# @description first, the CI weight (e2e-shard-weights.txt) as the tie-break;
# @description taken while the summed CI seconds fit PRE_PUSH_E2E_BUDGET and
# @description the count PRE_PUSH_E2E_MAX (the top file always runs). What is
# @description cut is printed: CI still runs every file.
# @description THE RUN: the mock bundle (as wf 10 builds it) is cached by the
# @description WUI tree without e2e/bench contents, so an e2e-only edit and a
# @description rebase over non-WUI commits reuse it; the files run through
# @description csi-spl-orc's wui-e2e-mock-serve.sh, as wf 10 runs them. The
# @description whole part runs under PRE_PUSH_E2E_TIMEOUT.
# @param PRE_PUSH_E2E (optional) - 0 = never select the part, default 1
# @param PRE_PUSH_E2E_MAX (optional) - most files run, default 6
# @param PRE_PUSH_E2E_BUDGET (optional) - CI seconds the files may sum to, default 240
# @param PRE_PUSH_E2E_TIMEOUT (optional) - seconds for the whole part, default 600
# @param PRE_PUSH_E2E_BUNDLES (optional) - bundle cache dir, default ~/.cache/csi-spl/wui-e2e-bundle
# @param PRE_PUSH_E2E_GENERATE (optional) - the build command (tests), default the mock generate
# @param PRE_PUSH_E2E_RUNNER (optional) - the run command (tests), default mock-serve + run-e2e-tests.mjs
# @example WUI_E2E_CHANGED="csi-spl-wui/src/components/Foo.vue" ./run -a do_check_pre_push_e2e
# @example WUI_E2E_RANGE=origin/master..HEAD ./run -a do_check_pre_push_e2e
#------------------------------------------------------------------------------

# do_check_pre_push_e2e - print the e2e files a change selects, "<file> <score>
# <ci secs>" per line, then one "CUT" line per file left out by the cap. The
# change: WUI_E2E_CHANGED (paths, space or newline separated) or the files of
# WUI_E2E_RANGE (a git range), in PRE_PUSH_TREE (default the checkout).
do_check_pre_push_e2e() {
  local tree="${PRE_PUSH_TREE:-$(git rev-parse --show-toplevel 2>/dev/null)}" changed
  if [[ -n "${WUI_E2E_RANGE:-}" ]]; then
    changed="$(git -C "$tree" diff --name-only "$WUI_E2E_RANGE" 2>/dev/null)" \
      || { do_log "FATAL wui-e2e: cannot diff $WUI_E2E_RANGE"; return 1; }
  else
    changed="$(tr ' ' '\n' <<<"${WUI_E2E_CHANGED:-}")"
  fi
  _ppe_select "$tree" "$changed"
}

# _ppe_select <tree> <changed-list> - the selection (see do_check_pre_push_e2e).
_ppe_select() {
  local tree="$1" changed="$2" wui="$1/csi-spl-wui"
  [[ -d "$wui/tests/e2e" ]] || return 0
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-ppe.XXXXXX")" || return 1
  _ppe_candidates "$wui" >"$tmp/cand"
  : >"$tmp/keys"; : >"$tmp/direct"
  local f rel
  while IFS= read -r f; do
    [[ "$f" == csi-spl-wui/* ]] || continue
    rel="${f#csi-spl-wui/}"
    case "$rel" in
      tests/e2e/*.test.mjs) grep -qxF "$rel" "$tmp/cand" && printf '%s\t100\n' "$rel" >>"$tmp/direct" ;;
      tests/e2e/*.proof.mjs|tests/e2e/ci-skip.txt) ;;
      tests/e2e/*)
        [[ -e "$wui/$rel" ]] || continue
        local base="${rel##*/}"
        local -a cand; mapfile -t cand <"$tmp/cand"
        while IFS= read -r t; do printf '%s\t50\n' "$t" >>"$tmp/direct"; done < <(
          cd "$wui" && grep -lF -- "$base" "${cand[@]}" 2>/dev/null) ;;
      src/*.vue|src/*.ts|src/*.js|src/*.mjs|src/*.tsx)
        [[ "$rel" == src/node/* || "$rel" == src/python/* || "$rel" == src/docker/* || "$rel" == *.d.ts ]] && continue
        [[ -e "$wui/$rel" ]] && _ppe_closure "$wui" "$rel" >>"$tmp/keys" ;;
    esac
  done <<<"$changed"
  _ppe_score "$wui" "$tmp" | _ppe_cap "$wui"
  rm -rf "$tmp"
}

# _ppe_candidates <wui> - the tests the CI suite runs: tests/e2e/*.test.mjs
# minus the files ci-skip.txt names.
_ppe_candidates() {
  local skip="$1/tests/e2e/ci-skip.txt"
  ( cd "$1" && ls tests/e2e/*.test.mjs 2>/dev/null ) | while IFS= read -r t; do
    [[ -f "$skip" ]] && grep -qE "^${t##*/}([[:space:]]|$)" "$skip" && continue
    echo "$t"
  done
}

# _ppe_keys <wui> <rel> - the testids a source file declares: "x" exact, or
# "x-" for the static prefix of a bound one. At least 4 characters.
_ppe_keys() {
  grep -oE "[Tt]est[Ii]d[\"']?[[:space:]]*[=:][[:space:]]*\"?['\`\"][a-z0-9][a-z0-9-]{3,}" "$1/$2" 2>/dev/null |
    sed -E "s/.*['\`\"]([a-z0-9-]+)$/\1/" | sort -u
}

# _ppe_names <wui> <rel> - the names other files use a source file by: its
# exported names (5+ chars), and for a .vue its component name, bare and
# prefixed by its directories under components/ (Nuxt's auto-import name).
# A page, a layout and the app shell are used by no name: nothing.
_ppe_names() {
  local wui="$1" rel="$2" b
  [[ "$rel" == src/pages/* || "$rel" == src/layouts/* || "$rel" == src/app.vue || "$rel" == src/error.vue ]] && return 0
  grep -oE 'export (default )?(async )?(function|const|let|class) [A-Za-z_][A-Za-z0-9_]{4,}' "$wui/$rel" 2>/dev/null |
    awk '{ print $NF }'
  grep -oE "defineStore\\(['\"][A-Za-z0-9_-]{3,}" "$wui/$rel" 2>/dev/null | sed -E "s/.*['\"]//"
  if [[ "$rel" == *.vue ]]; then
    b="${rel##*/}"; b="${b%.vue}"; echo "$b"
    if [[ "$rel" == src/components/*/* ]]; then
      local d="${rel#src/components/}"; d="${d%/*}"
      echo "$(sed -E 's#(^|/)([a-z])#\U\2#g; s#-([a-z])#\U\1#g' <<<"$d")$b"
    fi
  fi
  return 0
}

# _ppe_closure <wui> <rel> - "<key>\t<weight>": the file's own testids and,
# for a page, its route (weight 9), the testids of the files that use it (3),
# and of their users (1). The layouts and the app shell render every page, so
# they are no "user": through them a util would select the whole suite. At
# most 40 files per level.
_ppe_closure() {
  local wui="$1" rel="$2" lvl next names f d=0 r
  local -a wt=(9 3 1)
  local -A seen=(["$rel"]=1)
  if [[ "$rel" == src/pages/* ]]; then
    r="/${rel#src/pages/}"; r="${r%.vue}"; r="${r%/index}"; r="${r%%/[[]*}"
    [[ "${#r}" -ge 4 ]] && printf '%s\t9\n' "$r"
  fi
  lvl="$rel"
  while [[ -n "$lvl" && "$d" -lt 3 ]]; do
    next=""
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      _ppe_keys "$wui" "$f" | sed "s/\$/\t${wt[$d]}/"
      names="$(_ppe_names "$wui" "$f" | sort -u | grep -E '.{5,}')" || continue
      while IFS= read -r u; do
        [[ -n "${seen[$u]:-}" ]] && continue
        seen["$u"]=1; next+="$u"$'\n'
      done < <(cd "$wui" && grep -rlwF -f <(printf '%s\n' "$names") --include='*.vue' --include='*.ts' --include='*.js' --include='*.mjs' \
                 src 2>/dev/null | grep -vE '^src/(node|python|docker|layouts)/|^src/(app|error)\.vue$|\.d\.ts$' | sort | sed -n '1,40p')
    done <<<"$lvl"
    lvl="$next"; d=$((d + 1))
  done
}

# _ppe_score <wui> <tmp> - "<test>\t<score>": the direct hits, plus per test
# the sum of the best weight of each distinct key it names.
_ppe_score() {
  local wui="$1" tmp="$2"
  if [[ -s "$tmp/keys" ]]; then
    sort -t$'\t' -k1,1 -k2,2nr "$tmp/keys" | awk -F'\t' '!s[$1]++' >"$tmp/kbest"
    # exact keys end at a non-testid character; a prefix key ("x-") need not
    awk -F'\t' '{ print ($1 ~ /-$/) ? $1 : $1 "([^a-z0-9/-]|$)" }' "$tmp/kbest" >"$tmp/pat"
    local -a cand; mapfile -t cand <"$tmp/cand"
    ( cd "$wui" && grep -oE -f "$tmp/pat" "${cand[@]}" 2>/dev/null ) |
      awk -F'\t' -v kb="$tmp/kbest" '
        BEGIN { while ((getline l < kb) > 0) { split(l, a, "\t"); w[a[1]] = a[2] } }
        { i = index($0, ":"); t = substr($0, 1, i - 1); m = substr($0, i + 1)
          sub(/[^a-z0-9\/-]$/, "", m)
          if (!(m in w)) { for (k in w) if (k ~ /-$/ && index(m, k) == 1) { m = k; break } }
          if ((m in w) && !seen[t SUBSEP m]++) sc[t] += w[m] }
        END { for (t in sc) print t "\t" sc[t] }' >>"$tmp/direct"
  fi
  awk -F'\t' '{ if ($2 > s[$1]) s[$1] = $2 } END { for (t in s) print t "\t" s[t] }' "$tmp/direct"
}

# _ppe_cap <wui> - stdin "<test>\t<score>" -> the files that fit, best first,
# "<test> <score> <ci secs>", then "CUT <test> <score> <ci secs>" per file
# left out. The CI weight of a file with no line is the median.
_ppe_cap() {
  local wts="$1/src/node/test/e2e-shard-weights.txt"
  awk -F'\t' -v wf="$wts" -v max="${PRE_PUSH_E2E_MAX:-6}" -v budget="${PRE_PUSH_E2E_BUDGET:-240}" '
    BEGIN { n = 0
      while ((getline l < wf) > 0) { sub(/#.*/, "", l); if (split(l, a, " ") == 2) { w[a[1]] = a[2]; v[++n] = a[2] } }
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { x = v[i]; v[i] = v[j]; v[j] = x }
      med = n ? v[int((n + 1) / 2)] : 30 }
    { print $2 "\t" (($1 in w) ? w[$1] : med) "\t" $1 }' |
    sort -t$'\t' -k1,1nr -k2,2n -k3,3 |
    awk -F'\t' -v max="${PRE_PUSH_E2E_MAX:-6}" -v budget="${PRE_PUSH_E2E_BUDGET:-240}" '
      { if (k == 0 || (k < max && sum + $2 <= budget)) { print $3 " " $1 " " $2; k++; sum += $2 }
        else print "CUT " $3 " " $1 " " $2 }'
}

# The files this push selects, set by _ppe_plan for the part to run (the part
# runs in this shell, and the baseline re-run reads the same list).
_PPE_FILES=""

# _ppe_plan <changed-list> <tree> - 0 when the part is selected (sets
# _PPE_FILES and prints what the cap left out).
_ppe_plan() {
  _PPE_FILES=""
  [[ "${PRE_PUSH_E2E:-1}" == 1 ]] || return 1
  grep -q '^csi-spl-wui/' <<<"$1" || return 1
  local sel; sel="$(_ppe_select "$2" "$1")"
  _PPE_FILES="$(grep -v '^CUT ' <<<"$sel" | cut -d' ' -f1)"
  _PPE_CUT="$(grep '^CUT ' <<<"$sel" | cut -d' ' -f2)"
  [[ -n "$_PPE_FILES" ]]
}

# _ppe_parts <changed-list> <tree> - do_check_pre_push's `parts` gets
# wui-e2e only when the change maps to an e2e file, FULL mode too: the map
# needs a change, and CI runs every file anyway.
_ppe_parts() {
  parts="${parts/ wui-e2e/}"
  _ppe_plan "$1" "$2" && parts+=" wui-e2e"
  return 0
}

# _ppe_bundle_key <tree> - the bundle's cache key: the WUI tree without
# e2e/bench contents (_pp_wui_tree_id) and the node version; empty when a
# WUI input is dirty (then HEAD is not what would be built).
_ppe_bundle_key() {
  local dirty
  dirty="$(git -C "$1" status --porcelain -- csi-spl-wui 2>/dev/null | awk '{ print $NF }' |
           grep -vE '^csi-spl-wui/tests/(e2e|bench)/' | grep -vE '^csi-spl-wui/(\.output|\.nuxt|node_modules)')"
  [[ -z "$dirty" ]] || return 0
  printf '%s' "$(_pp_wui_tree_id "$1") $(node -v 2>/dev/null)" | sha1sum | cut -c1-40
}

# _ppe_generate - the mock bundle, as wf 10's wui-generate job builds it.
_ppe_generate() {
  NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en \
  NUXT_PUBLIC_REPO_WEB_URL="https://git.example.org/acme/spool" NUXT_PUBLIC_REPO_COMMIT_PATH="/commit/" \
  NUXT_PUBLIC_REPO_CLONE_URL="https://git.example.org/acme/spool" NUXT_PUBLIC_REPO_HELP_PATH="/blob/master/csi-spl-doc/doc/help/" \
    "$(_pp_pnpm)" run generate
}

# _pp_part_wui_e2e <tree> - build or reuse the bundle, run the files.
_pp_part_wui_e2e() {
  local tree="$1"
  [[ -n "$_PPE_FILES" ]] || { echo "wui-e2e: no e2e file maps to this change"; return 0; }
  echo "wui-e2e: runs $(wc -w <<<"$_PPE_FILES") file(s): $(paste -sd' ' <<<"$_PPE_FILES")"
  [[ -n "${_PPE_CUT:-}" ]] && echo "wui-e2e: left to CI by the cap (PRE_PUSH_E2E_MAX / _BUDGET): $(paste -sd' ' <<<"$_PPE_CUT")"
  local files="$_PPE_FILES" t missing=""
  for t in $files; do [[ -f "$tree/csi-spl-wui/$t" ]] || missing+=" $t"; done
  [[ -z "$missing" ]] || echo "wui-e2e: not in this tree (new in the push?):$missing"
  export -f _pp_pnpm _pp_wui_tree_id _ppe_bundle_key _ppe_generate
  timeout -k 10 "${PRE_PUSH_E2E_TIMEOUT:-600}" bash -c '
    set -uo pipefail
    tree="$1" files="$2"
    wui="$tree/csi-spl-wui"; cd "$wui" || exit 1
    export PATH="$HOME/.local/bin:$PATH"
    run_dir="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-ppe-run.XXXXXX")" || exit 1
    trap '\''rm -rf "$run_dir"; [[ -L .output/public ]] && rm -f .output/public && rmdir .output 2>/dev/null
             [[ -d .output.ppe-keep ]] && { rm -rf .output; mv .output.ppe-keep .output; }; true'\'' EXIT
    if [[ ! -d node_modules ]] || ! cmp -s pnpm-lock.yaml node_modules/.pnpm/lock.yaml; then
      [[ -L node_modules ]] && rm -f node_modules
      echo "wui-e2e: pnpm install --frozen-lockfile"
      "$(_pp_pnpm)" install --frozen-lockfile || exit 1
    fi
    key="$(_ppe_bundle_key "$tree")"
    cache="${PRE_PUSH_E2E_BUNDLES:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/wui-e2e-bundle}"
    [[ -e .output ]] && mv .output .output.ppe-keep
    if [[ -n "$key" && -f "$cache/$key/public/index.html" ]]; then
      echo "wui-e2e: bundle re-used ($cache/${key:0:12}): no WUI input changed since it was built"
    else
      echo "wui-e2e: building the mock bundle"
      start=$SECONDS
      # the build also writes ignored outputs into the tree (.nuxt, dist,
      # src/public/roadmap.json, docs-public ...): the iac suite scans the
      # tree, so the ones this build made are removed again below
      git ls-files --others --ignored --exclude-standard --directory . | grep -v "^node_modules/" | sort >"$run_dir/before"
      ${PRE_PUSH_E2E_GENERATE:-_ppe_generate} || { echo "FAIL: wui-e2e: the mock bundle did not build"; exit 1; }
      [[ -f .output/public/index.html ]] || { echo "FAIL: wui-e2e: no .output/public/index.html after the build"; exit 1; }
      echo "wui-e2e: bundle built in $((SECONDS - start)) s"
      git ls-files --others --ignored --exclude-standard --directory . | grep -v "^node_modules/" | sort |
        comm -13 "$run_dir/before" - | grep -v "^\.output/" | while IFS= read -r p; do rm -rf -- "./$p"; done
      if [[ -n "$key" ]]; then
        mkdir -p "$cache/$key" && rm -rf "$cache/$key/public" && mv .output/public "$cache/$key/public" && rm -rf .output
        # the newest 3 bundles only (~4 MB each)
        ls -1dt "$cache"/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
      fi
    fi
    if [[ -n "$key" ]]; then mkdir -p .output && ln -s "$cache/$key/public" .output/public; fi
    export CHROME_PATH="${CHROME_PATH:-$(command -v google-chrome || command -v chromium || command -v chromium-browser)}"
    export TMPDIR="$run_dir" SHOT_DIR="$run_dir/shots"; mkdir -p "$SHOT_DIR"
    # shellcheck disable=SC2086 # files: one word each
    if [[ -n "${PRE_PUSH_E2E_RUNNER:-}" ]]; then
      $PRE_PUSH_E2E_RUNNER $files
    else
      bash "$tree/csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh" node src/node/test/run-e2e-tests.mjs $files
    fi
  ' _ "$tree" "$files"
}
