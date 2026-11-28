#!/usr/bin/env bash
#------------------------------------------------------------------------------
# ci-orc-test-plan.sh - which orc hermetic test files a workflow 10 push runs
# (SPL-6385, csi-spl-doc/specs/016-spool-testability/ci-volume-2026-11-24.md
# section 3 A3: "the changed tests plus their dependents; full suite on a
# shared lib and on the full run").
#
#   ci-orc-test-plan.sh <base-sha> <head-sha>
#     The plan for <base>..<head>. Prints ONE line on stdout:
#       orc_plan={"n":<1..3>,"shards":[1..n],"files":"<test file names, space-separated>"}
#     a MAPPED run: those files only, packed on n shards (ORC_TEST_ONLY and
#     ORC_TEST_SHARD=<k>/<n> of run-all-tests.sh), or
#       orc_plan=
#     the FULL suite on 4 shards. Reasons go to stderr, one line each.
#   ci-orc-test-plan.sh --base <jobs.tsv>
#     The orc part's base: the head sha of the newest run whose every `orc:`
#     job concluded success, on classify's rows (`<run> TAB <sha> TAB <job>
#     TAB <conclusion>`, newest run first): the rule ci-doc-only.sh --select
#     applies to the orc part. Nothing when no run qualifies.
#   ci-orc-test-plan.sh --map [<repo path>...]
#     THE MAP, for a reader and for the coverage measurement: one line per
#     path (default: every tracked orc file outside src/bash/tests that is not
#     a .md), `<path> TAB <test> <test>...` or `<path> TAB FULL <why>`: the
#     files a push that changes only <path> runs. CI never reads a stored
#     copy: the map is derived from the tree each time, so it cannot go stale.
#
# HOW A PATH MAPS (one engine: changed-tests.sh, the map `run-all-tests.sh
# --changed` and the pre-push orc part already use):
#   1. direct: changed-tests.sh with ORC_TEST_FILES=<the changed paths>: a
#      test that names the file (basename, stem, a function it defines, the
#      outside map), a changed test itself, plus ORC_TEST_ALWAYS. Its `full`
#      (an orc file no test names, the dispatcher) is the full suite.
#   2. dependents: an orc source file that names a changed orc source file
#      (its basename, stem or a function it defines, keyed as changed-tests.sh
#      keys it) is a dependent; the tests that name the dependent join the
#      plan. A dependent no test names adds nothing (it did not change). One
#      level, at most ORC_PLAN_MAX_DEPS (default 30), else the full suite.
#   3. a path outside csi-spl-orc that no orc test names (changed-tests.sh
#      ignores it): a test that names one of its parent dirs (two levels or
#      deeper, e.g. csi-spl-api/src/go/spool-hub-api) joins the plan.
#   4. the TREE GUARDS (ORC_PLAN_TREE_GUARDS) join every mapped plan: tests
#      that scan the whole tree, so no file key reaches them. Measured
#      2026-11-21..27: qto-private-index.tst.sh went red on a doc line
#      (bug-round-52-plan.md) in 2 push gates whose plan would have left it
#      out. The list is by hand (~61 s of weight): a guard missing from it
#      runs on the next full run only.
#
# FAILS SAFE to the full suite (orc_plan=): a base or head that is not a
# 40-hex sha, a base git cannot read or that is not an ancestor; the
# classifier's full gate for the range (ci-doc-only.sh <base> <head> ->
# parts=all: .github, a dispatcher or csi-spl-*/lib, cnf, .version, go.mod,
# the suite runners and the test lib, a merge); a lib/ dir under csi-spl-orc
# (a feature's lib too); a shared test helper or the runner's input (any
# non-test file directly in src/bash/tests: *.inc.sh, the shard weights);
# this file; any *.tfvars, Dockerfile, docker-compose file or
# csi-spl-orc/src/docker file (the C4 shape: a pin an orc test of another
# file reads); too many dependents; an empty selection; a selection that
# needs all 4 shards anyway; any error (the workflow reads a failed or
# partial plan as the full suite).
# Gate: csi-spl-orc/src/bash/tests/ci-orc-test-plan.tst.sh.
#------------------------------------------------------------------------------
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
orc=$(cd "$here/../../.." && pwd)
tests="$orc/src/bash/tests"
SHARDS=4
max_deps="${ORC_PLAN_MAX_DEPS:-30}"
always="${ORC_TEST_ALWAYS-require-cloud-env.tst.sh run-eager-files.tst.sh}"
always+=" ${ORC_PLAN_TREE_GUARDS-qto-private-index.tst.sh no-literal-paths.tst.sh func-name-unique.tst.sh check-fleet-rules-drift.tst.sh check-qto-doc-drift.tst.sh}"

full() { echo "orc_plan="; echo "ci-orc-test-plan: full suite: $1" >&2; exit 0; }

if [[ "${1:-}" == --base ]]; then
  awk -F'\t' '
    $3 ~ /^orc:/ { if (!($1 in sha)) { sha[$1] = $2; order[++n] = $1 } if ($4 != "success") bad[$1] = 1 }
    END { for (i = 1; i <= n; i++) if (!(order[i] in bad)) { print sha[order[i]]; exit } }' "${2:-/dev/null}" 2>/dev/null
  exit 0
fi

top=$(git -C "$orc" rev-parse --show-toplevel 2>/dev/null) || full "not a git tree"
o="${orc#"$top"/}/"                                 # csi-spl-orc/

# own_full <repo path>: why this path runs the full suite, or nothing
own_full() {
  local f="$1"
  case "$f" in
    "${o}src/bash/scripts/ci-orc-test-plan.sh") echo "$f is the plan itself" ;;
    "$o"lib/* | "$o"*/lib/*) echo "$f is a shared lib" ;;
    "${o}src/bash/tests/"*/* | "${o}src/bash/tests/"*.tst.sh) ;;
    "${o}src/bash/tests/"*) echo "$f is a shared test helper or the runner's input" ;;
    "${o}src/docker/"*) echo "$f is an image or compose pin" ;;
    *.tfvars | Dockerfile* | */Dockerfile* | *docker-compose*.yml | *docker-compose*.yaml) echo "$f is a tfvars or image pin" ;;
  esac
  return 0
}

# ct <ORC_TEST_ALWAYS value> <paths...>: changed-tests.sh on these paths
ct() {
  local a="$1"; shift
  ORC_TEST_BASE="$base" ORC_TEST_ALWAYS="$a" ORC_TEST_FILES="$*" bash "$tests/changed-tests.sh" 2>/dev/null
}

# keys <repo path>: the names changed-tests.sh keys an orc source file by
defs() { sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:.-]*)[[:space:]]*\(\).*$/\2/p'; }
keys() {
  local f="$1" b stem fn
  b=${f##*/}
  (( ${#b} >= 5 )) && echo "$b"
  stem="${b%.func.sh}"; stem="${stem%.inc.sh}"; stem="${stem%.sh}"
  [[ "$stem" != "$b" ]] && (( ${#stem} >= 5 )) && echo "$stem"
  case "$b" in *.sh|*.bash|run) ;; *) return 0 ;; esac
  { [[ -f "$top/$f" ]] && cat "$top/$f"; git -C "$top" show "$base:$f" 2>/dev/null; } | defs \
    | while read -r fn; do
        (( ${#fn} >= 5 )) && [[ "$fn" == *[_-]* && "$dispatcher_fns" != *" $fn "* ]] && echo "$fn"
      done
  return 0
}

# plan_files <paths...>: the test files these changed paths run, one per
# line, or one line FULL<TAB><why> when they need the full suite
plan_files() {
  local f why line kf d prefix
  local -a src=() outside=() deps=()
  for f in "$@"; do
    why=$(own_full "$f")
    [[ -z "$why" ]] || { printf 'FULL\t%s\n' "$why"; return 0; }
    case "$f" in
      *.md) ;;
      "${o}src/bash/tests/"* | "$o"src/bash/features/*/tests/*) ;;
      "$o"*) src+=("$f") ;;
      *) outside+=("$f") ;;
    esac
  done
  line=$(ct "$always" "$@") || line=$'full\tchanged-tests.sh failed'
  [[ -n "$line" ]] || line=$'full\tchanged-tests.sh printed nothing'
  if grep -q '^full' <<<"$line"; then
    printf 'FULL\t%s\n' "$(awk -F'\t' '$1 == "full" { print $2; exit }' <<<"$line")"; return 0
  fi
  awk -F'\t' '$1 == "run" { print $2 }' <<<"$line"
  # 3. an outside path no orc test names: the tests that name a parent dir
  for f in "${outside[@]}"; do
    awk -F'\t' -v f="$f" '$1 == "ignore" && $2 == f { hit = 1 } END { exit !hit }' <<<"$line" || continue
    prefix=${f%/*}
    while [[ "$prefix" == */* ]]; do
      (cd "$tests" && grep -lF -- "$prefix" -- *.tst.sh 2>/dev/null)
      prefix=${prefix%/*}
    done
  done
  # 2. dependents: the orc source files that name a changed orc source file
  (( ${#src[@]} )) || return 0
  kf=$(mktemp)
  for f in "${src[@]}"; do keys "$f"; done | sort -u >"$kf"
  if [[ -s "$kf" ]]; then
    mapfile -t deps < <(git -C "$top" grep -lwF -f "$kf" -- "$o" ":!${o}src/bash/tests" \
      ":!${o}src/bash/features/*/tests" ':!*.md' 2>/dev/null | grep -vxF -f <(printf '%s\n' "${src[@]}"))
  fi
  rm -f "$kf"
  if (( ${#deps[@]} > max_deps )); then
    printf 'FULL\t%s dependents of the changed orc files (over %s)\n' "${#deps[@]}" "$max_deps"; return 0
  fi
  for d in "${deps[@]}"; do
    [[ -z "$(own_full "$d")" ]] || continue
    ct "" "$d" | awk -F'\t' '$1 == "run" { print $2 }'
  done
  return 0
}

dispatcher_fns=" $(defs 2>/dev/null <"$orc/src/bash/run/run.sh" | tr '\n' ' ') "

if [[ "${1:-}" == --map ]]; then
  shift
  base=$(git -C "$top" rev-parse HEAD)
  if (( $# == 0 )); then
    mapfile -t paths < <(git -C "$top" ls-files -- "$o" ":!${o}src/bash/tests" ':!*.md')
    set -- "${paths[@]}"
  fi
  for f in "$@"; do
    out=$(plan_files "$f" | sort -u)
    if grep -q '^FULL' <<<"$out"; then
      printf '%s\tFULL %s\n' "$f" "$(awk -F'\t' '$1 == "FULL" { print $2; exit }' <<<"$out")"
    else
      printf '%s\t%s\n' "$f" "$(grep . <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
    fi
  done
  exit 0
fi

base="${1:-}" head="${2:-}"
[[ "$base" =~ ^[0-9a-f]{40}$ ]] || full "no base sha"
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || full "no head sha"
git -C "$top" cat-file -e "$base^{commit}" 2>/dev/null || full "base ${base:0:12} is not readable here"
git -C "$top" merge-base --is-ancestor "$base" "$head" 2>/dev/null || full "base ${base:0:12} is not an ancestor of ${head:0:12}"
cls=$(cd "$top" && bash "${o}src/bash/scripts/ci-doc-only.sh" "$base" "$head" 2>/dev/null) || cls=parts=all
[[ "$cls" == parts=* && "$cls" != parts=all ]] || full "the classifier's full gate for ${base:0:12}..${head:0:12} ($cls)"
mapfile -t changed < <(git -C "$top" diff --no-renames --name-only "$base" "$head" 2>/dev/null)
(( ${#changed[@]} )) || full "empty diff"
plan=$(plan_files "${changed[@]}") || full "the plan failed"
grep -q '^FULL' <<<"$plan" && full "$(awk -F'\t' '$1 == "FULL" { print $2; exit }' <<<"$plan")"
mapfile -t sel < <(grep . <<<"$plan" | sort -u)
(( ${#sel[@]} )) || full "no test file selected"

# n: the selection's weight over one full-run shard's (orc-shard-weights.txt)
declare -A wt=()
wdef=1
while read -r wf ws _; do
  [[ -z "$wf" || "$wf" == \#* ]] && continue
  [[ "$ws" =~ ^[0-9]+$ ]] || full "bad weights line '$wf $ws'"
  if [[ "$wf" == '*' ]]; then wdef=$ws; else wt[$wf]=$ws; fi
done <"${ORC_TEST_WEIGHTS:-$tests/orc-shard-weights.txt}"
total=0 sum=0
for t in "$tests"/*.tst.sh; do b=${t##*/}; total=$((total + ${wt[$b]:-$wdef})); done
for t in "${sel[@]}"; do
  [[ "$t" =~ ^[A-Za-z0-9._-]+\.tst\.sh$ && -f "$tests/$t" ]] || full "selected '$t' is not a test file here"
  sum=$((sum + ${wt[$t]:-$wdef}))
done
cap=$(( (total + SHARDS - 1) / SHARDS ))
n=$(( (sum + cap - 1) / cap ))
(( n >= 1 )) || n=1
(( n < SHARDS )) || full "${#sel[@]} files of $sum s need all $SHARDS shards anyway"
echo "ci-orc-test-plan: mapped: ${#sel[@]} file(s), $sum s of $total s, on $n shard(s), base ${base:0:12}" >&2
printf 'orc_plan={"n":%d,"shards":[%s],"files":"%s"}\n' "$n" "$(seq -s, 1 "$n")" "${sel[*]}"
