#!/bin/bash
#------------------------------------------------------------------------------
# @description The pre-push part `orc-features` (spec 133 F1, CI-refactor round
# @description 3): the csi-spl-orc feature tests (features/*/tests/test-*.sh,
# @description wf 10 job orc-features) of the features a push touches. Before
# @description it no local gate ran them: a change under features/ made the orc
# @description map fall back to `full`, which the fast tier leaves to CI, so a
# @description feature red was first seen on trunk (22 red job rows in 125 red
# @description wf 10 runs, 2026-10-08T23:51Z..10-12T08:29Z).
# @description THE MAP (change -> feature), read from the tree:
# @description   a file under features/<f>/            <f> (when it has tests/)
# @description   a file directly under features/        every feature (the runner,
# @description                                          ci-skip.txt, ci-serial.txt)
# @description   any other csi-spl-orc file (not .md)   the features whose
# @description                                          tests/test-*.sh name its
# @description                                          basename or its stem
# @description                                          (5+ characters)
# @description The FULL tier runs every feature. The run is wf 10's own:
# @description features/run-ci-tests.sh <features>, with a short TMPDIR (tmux
# @description sockets) and the agent's SPOOL_* env dropped, under
# @description PRE_PUSH_FEATURES_TIMEOUT. Measured 2026-10-12 on the first box
# @description (16 cpus, load 15.7, n=1): spawn-agents, 80 files, 85 s.
# @param PRE_PUSH_FEATURES (optional) - 0 = never select the part, default 1
# @description A part that runs out of time names every file still running
# @description (FAILED: <feature>/<file> (still running at the timeout)).
# @param PRE_PUSH_FEATURES_TIMEOUT (optional) - seconds for the part, default 300, full tier 900
# @example FEATURES_CHANGED="csi-spl-orc/src/bash/run/spl-lane-map.func.sh" ./run -a do_check_pre_push_features
# @example FEATURES_RANGE=origin/master..HEAD ./run -a do_check_pre_push_features
#------------------------------------------------------------------------------

# do_check_pre_push_features - print the features a change selects, one per
# line. The change: FEATURES_CHANGED (paths, space or newline separated) or
# the files of FEATURES_RANGE (a git range), in PRE_PUSH_TREE (default the
# checkout).
do_check_pre_push_features() {
  local tree="${PRE_PUSH_TREE:-$(git rev-parse --show-toplevel 2>/dev/null)}" changed
  if [[ -n "${FEATURES_RANGE:-}" ]]; then
    changed="$(git -C "$tree" diff --name-only "$FEATURES_RANGE" 2>/dev/null)" \
      || { do_log "FATAL orc-features: cannot diff $FEATURES_RANGE"; return 1; }
  else
    changed="$(tr ' ' '\n' <<<"${FEATURES_CHANGED:-}")"
  fi
  _ppf_select "$tree" "$changed"
}

# _ppf_all <tree> - every feature with a tests/ dir.
_ppf_all() {
  local d
  for d in "$1"/csi-spl-orc/src/bash/features/*/tests; do
    [[ -d "$d" ]] && basename "$(dirname "$d")"
  done
}

# _ppf_select <tree> <changed-list> - the features (see do_check_pre_push_features).
_ppf_select() {
  local tree="$1" feat="$1/csi-spl-orc/src/bash/features" f rel b stem
  [[ -d "$feat" ]] || return 0
  while IFS= read -r f; do
    [[ "$f" == csi-spl-orc/* && "$f" != *.md ]] || continue
    rel="${f#csi-spl-orc/src/bash/features/}"
    if [[ "$rel" != "$f" && "$rel" != */* ]]; then _ppf_all "$tree"; continue; fi
    [[ "$rel" != "$f" && -d "$feat/${rel%%/*}/tests" ]] && echo "${rel%%/*}"
    b="${f##*/}"; stem="${b%.func.sh}"; stem="${stem%.inc.sh}"; stem="${stem%.sh}"
    local -a pats=(-e "$b"); (( ${#stem} >= 5 )) && pats+=(-e "$stem")
    grep -lwF "${pats[@]}" "$feat"/*/tests/test-*.sh 2>/dev/null \
      | sed 's|.*/features/\([^/]*\)/tests/.*|\1|'
  done <<<"$2" | sort -u
}

# _ppf_parts <changed-list> <tree> - do_check_pre_push's `parts` gets
# orc-features when the change maps to a feature (every feature on the FULL
# tier); _PPF_FEATS holds them for the part and its trunk re-check.
_ppf_parts() {
  parts="${parts/ orc-features/}"
  [[ "${PRE_PUSH_FEATURES:-1}" == 0 ]] && return 0
  if [[ "${_PP_TIER:-fast}" == full ]]; then _PPF_FEATS="$(_ppf_all "$2")"
  else _PPF_FEATS="$(_ppf_select "$2" "$1")"; fi
  [[ -n "$_PPF_FEATS" ]] && parts+=" orc-features"
  return 0
}

# _pp_part_orc_features <tree> - run the selected features that exist in
# <tree> (a feature new in the push is absent on trunk: the re-check then
# runs nothing and passes, so the push's red stays its own). Each failing
# file is also printed as `FAILED: <feature>/<file>`, so the signature
# names it even when the test printed no FAIL line.
_pp_part_orc_features() {
  local tree="$1" f feats="" tmp rc=0 v
  for f in $_PPF_FEATS; do [[ -d "$tree/csi-spl-orc/src/bash/features/$f/tests" ]] && feats+=" $f"; done
  [[ -n "$feats" ]] || { echo "orc-features: no selected feature in this tree"; return 0; }
  echo "orc-features: runs${feats}"
  local -a envv=(env)
  for v in $(compgen -e); do [[ "$v" == SPOOL_* ]] && envv+=(-u "$v"); done
  # a tmux socket path over 107 bytes fails to bind: a short TMPDIR, not the agent's
  tmp="$(mktemp -d /tmp/ppf.XXXXXX)" || return 1
  # shellcheck disable=SC2086 # feats: one word each
  ( cd "$tree" || exit 1
    # shellcheck source=/dev/null
    source csi-spl-api/src/bash/use-go-toolchain.sh 2>/dev/null && spl_export_go_path 2>/dev/null
    timeout -k 10 "$(_pp_budget _pp_part_orc_features)" "${envv[@]}" TMPDIR="$tmp" \
      bash csi-spl-orc/src/bash/features/run-ci-tests.sh $feats ) >"$tmp.out" 2>&1 || rc=$?
  cat "$tmp.out"
  awk '$2 ~ /^FAIL\(rc=/ { print "FAILED: " $1 }
    $1 == "UNFINISHED" { print "FAILED: " $2 " (still running at the timeout)" }' "$tmp.out"
  # A TERM before the runner set its trap (wf 10 38693664604), or one that
  # killed it before it named a file, leaves no UNFINISHED line; name the
  # runner, so a timed-out part never names nothing.
  [[ "$rc" -eq 124 ]] && ! grep -q '^UNFINISHED ' "$tmp.out" &&
    echo "FAILED: run-ci-tests.sh (stopped before it named a file:${feats})"
  rm -rf "$tmp" "$tmp.out"
  return "$rc"
}
