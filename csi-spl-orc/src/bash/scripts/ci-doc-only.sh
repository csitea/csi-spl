#!/usr/bin/env bash
#------------------------------------------------------------------------------
# ci-doc-only.sh - classify a push for workflow 10: which PARTS' jobs it needs.
#
#   ci-doc-only.sh <base-sha> <head-sha>
#     Prints ONE line, `parts=<list>`: the parts whose jobs the changes in
#     <base>..<head> need, from {cnf hub iac orc wui}, sorted, space-separated;
#     `parts=all` for the full gate; `parts=` (empty) for a docs-only push (the
#     express docs lane: owner, t1 a477c187, msgs 50a349f4 + 31e00aee).
#
#   ci-doc-only.sh --select <head-sha> <jobs.tsv>
#     Per-JOB base (spec 133 seat C rule 4). <jobs.tsv> holds the jobs of recent
#     finished wf 10 runs on master, NEWEST RUN FIRST, one per line:
#     `<run id> TAB <head sha> TAB <job name> TAB <conclusion>`. A part's base
#     is the head sha of the newest run where it had a job and EVERY one of its
#     jobs concluded success (a skipped job is not a success). Prints one line
#     per part, `run_<part>=true|false`; false ONLY when the part is proven
#     untouched since its own base.
#
# Why a per-part base: the express lane's base was the last GREEN gate, and on
# a trunk that is red 96 % of the time it fired 0 of 51 times (spec 133 seat C,
# section 1.3). Per part, a red hub job keeps running until it is green, while
# a wui-only push no longer waits for a green hub before skipping hub.
#
# Owner order (t1 f67e3656, msg 52474112, CI action 1): a push that touches
# only one part runs that part's jobs, plus the cheap always-on jobs. The full
# gate stays on the hourly run and on any change to the workflow or shared test
# infra. By FILES, never by author. Reason lines go to stderr. Exits 0 with a
# verdict; any other exit is an error the caller must read as the full gate.
#
# The PART MAP (seat C section 2.2, dir level, plus its fail-safe rules 1-3):
#   - the full gate: .github/**, the gate's own code (this file, gate-fail-fast,
#     docker-pull-mirror, any run-all-tests/run-ci-tests/changed-tests and test
#     lib), the dispatchers and shared libs (csi-spl-*/run, src/bash/run/run.sh,
#     csi-spl-*/lib/**), go.mod/go.sum, the wui package.json/lockfile,
#     .version, csi-spl-cnf/** (cnf feeds every part), check-pre-push.func.sh
#     (the source of the wui list), and any path no rule maps;
#   - a *.md outside csi-spl-wui/ and .github/: nothing (the express lane),
#     unless the wui unit tests read it (below);
#   - csi-spl-api, csi-spl-rdb -> hub orc iac  (orc builds the spool binary)
#   - csi-spl-wui              -> wui iac orc
#   - csi-spl-iac              -> iac orc cnf
#   - csi-spl-orc              -> orc iac cnf hub  (hub runs the gate scripts)
#   - csi-spl-doc (not .md)    -> iac orc
#   - plus wui for every repo file the wui unit tests read (_pp_wui_external
#     of check-pre-push.func.sh, the pre-push map: one source of truth), the
#     blog posts, and the scripts the e2e and generate jobs run (WUI_EXTRA).
#   CI_WUI_EXTERNAL (space-separated) replaces the computed wui list (tests).
#
# FAILS SAFE: anything it cannot prove is the full gate:
#   - an empty or all-zero base (a new branch, a first push), or a base or
#     head git cannot read (a force-push past a commit the clone lacks);
#   - a base that is not an ancestor of the head (a force-push);
#   - a merge commit anywhere in the range;
#   - an empty diff, or a git error while listing it.
# A rename counts both sides (--no-renames lists the old path deleted + the new
# one added). Gate: csi-spl-iac/src/bash/tests/ci-doc-only.tst.sh.
#------------------------------------------------------------------------------
set -uo pipefail

PARTS=(cnf hub iac orc wui)
WUI_EXTRA=(
  csi-spl-doc/blog
  csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json
  csi-spl-orc/src/bash/scripts/perf-budget.py
  csi-spl-orc/src/bash/scripts/render.sh
  csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh
  csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh
)

verdict() {  # <parts> <reason>
  echo "parts=$1"
  echo "ci-doc-only: parts=$1 - $2" >&2
  exit 0
}

# The repo files the wui jobs read outside csi-spl-wui/ (globs allowed).
wui_external() {
  if [[ -n "${CI_WUI_EXTERNAL+x}" ]]; then
    tr ' ' '\n' <<<"$CI_WUI_EXTERNAL"
  elif [[ -f csi-spl-iac/src/bash/run/check-pre-push.func.sh ]]; then
    # shellcheck source=/dev/null
    (. csi-spl-iac/src/bash/run/check-pre-push.func.sh >/dev/null 2>&1 && _pp_wui_external .) | tr ' ' '\n'
  fi
  printf '%s\n' "${WUI_EXTRA[@]}"
}

# 0 when <path> is one of <entries> or under one of them (an entry may be a glob).
listed() {  # <path> <entry>...
  local f="$1" e; shift
  for e in "$@"; do
    [[ -n "$e" ]] || continue
    # shellcheck disable=SC2053 # an entry is a glob on purpose
    [[ "$f" == $e || "$f" == "$e"/* ]] && return 0
  done
  return 1
}

# Prints the parts one path needs, `all`, or nothing.
part_of() {  # <path> <wui entry>...
  local f="$1"; shift
  # a part's own dispatcher or shared lib (csi-spl-orc/lib/**, not a feature's lib/)
  [[ "$f" =~ ^csi-spl-[a-z]+/(run|lib/.*)$ ]] && { echo all; return; }
  case "$f" in
    .github/* | .version | csi-spl-cnf/* | */src/bash/run/run.sh \
      | */go.mod | */go.sum | csi-spl-wui/package.json | csi-spl-wui/pnpm-lock.yaml \
      | */run-all-tests.sh | */run-ci-tests.sh | */changed-tests.sh | */test-lib.inc.sh | */lib.inc.sh \
      | csi-spl-orc/src/bash/scripts/ci-doc-only.sh | csi-spl-orc/src/bash/scripts/gate-fail-fast.sh \
      | csi-spl-orc/src/bash/scripts/docker-pull-mirror.sh | csi-spl-iac/src/bash/run/check-pre-push.func.sh)
      echo all; return ;;
  esac
  listed "$f" "$@" && echo wui
  case "$f" in
    csi-spl-wui/*)                 echo wui iac orc ;;
    *.md)                          ;;
    csi-spl-api/* | csi-spl-rdb/*) echo hub orc iac ;;
    csi-spl-iac/*)                 echo iac orc cnf ;;
    csi-spl-orc/*)                 echo orc iac cnf hub ;;
    csi-spl-doc/*)                 echo iac orc ;;
    *)                             echo all ;;
  esac
}

# parts <base> <head>: the verdict line for <base>..<head>.
parts() {
  local base="$1" head="$2" files f p merges n=0
  [[ -n "$head" ]] || verdict all "no head sha"
  [[ -n "$base" && ! "$base" =~ ^0+$ ]] || verdict all "no base sha (new branch or first push)"
  git cat-file -e "$base^{commit}" 2>/dev/null || verdict all "base $base is not readable here"
  git cat-file -e "$head^{commit}" 2>/dev/null || verdict all "head $head is not readable here"
  git merge-base --is-ancestor "$base" "$head" 2>/dev/null || verdict all "base is not an ancestor of head (force-push)"

  merges=$(git rev-list --min-parents=2 "$base..$head" 2>/dev/null) || verdict all "git rev-list failed"
  [[ -z "$merges" ]] || verdict all "a merge commit is in the range"

  files=$(git diff --no-renames --name-only -z "$base" "$head" 2>/dev/null | tr '\0' '\n') \
    || verdict all "git diff failed"
  [[ -n "$files" ]] || verdict all "empty diff"

  local -a wui=()
  mapfile -t wui < <(wui_external)
  local -A need=()
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n=$((n + 1))
    for p in $(part_of "$f" "${wui[@]}"); do
      [[ "$p" == all ]] && verdict all "$f needs the full gate"
      need[$p]=1
    done
  done <<<"$files"
  local out=""
  for p in "${PARTS[@]}"; do [[ -n "${need[$p]:-}" ]] && out+="${out:+ }$p"; done
  verdict "$out" "$n path(s) since ${base:0:12}"
}

# select_parts <head> <jobs.tsv>: run_<part>= per part, each from its own base.
select_parts() {
  local head="$1" tsv="$2" p base line run sha name concl
  local -A has=() bad=() seen=() basesha=()
  local -a order=()
  if [[ -r "$tsv" ]]; then
    while IFS=$'\t' read -r run sha name concl; do
      [[ -n "$run" && -n "$sha" ]] || continue
      [[ -n "${seen[$run]:-}" ]] || { seen[$run]=1; order+=("$run"); basesha[$run]=$sha; }
      [[ "$name" == *:* ]] || continue
      p=${name%%:*}
      [[ " ${PARTS[*]} " == *" $p "* ]] || continue
      has[$run.$p]=1
      [[ "$concl" == success ]] || bad[$run.$p]=1
    done <"$tsv"
  fi
  for p in "${PARTS[@]}"; do
    base=""
    for run in "${order[@]}"; do
      [[ -n "${has[$run.$p]:-}" && -z "${bad[$run.$p]:-}" ]] && { base=${basesha[$run]}; break; }
    done
    if [[ -z "$base" ]]; then
      echo "run_$p=true"; echo "ci-doc-only: $p: no green $p run listed: run it" >&2; continue
    fi
    line=$(parts "$base" "$head" 2>/dev/null) || line="parts=all"
    if [[ "$line" != parts=* || "$line" == parts=all || " ${line#parts=} " == *" $p "* ]]; then
      echo "run_$p=true"; echo "ci-doc-only: $p: base ${base:0:12}, $line: run it" >&2
    else
      echo "run_$p=false"; echo "ci-doc-only: $p: base ${base:0:12}, $line: skip" >&2
    fi
  done
  exit 0
}

if [[ "${1:-}" == --select ]]; then
  select_parts "${2:-}" "${3:-}"
fi
parts "${1:-}" "${2:-}"
