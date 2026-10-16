#!/bin/bash
#------------------------------------------------------------------------------
# @description The measured re-test that lets a vendor take UI work again
# @description (owner HUM-10, t1 b61851fb, 2026-10-16: n=5 mistral lanes on
# @description WUI/orc work that night, 0 finished cleanly). Until it passes,
# @description do_spl_lane_mix and the spawn placer never give a lane whose
# @description brief or paths target csi-spl-wui/ to mistral (cnf
# @description env.box.agent_split.mistral_ui_allowed: false). Plain coded
# @description checks, no AI in the loop (t1 37349c9b).
# @description RETEST_CMD=plan (default) prints the three small WUI tasks with
# @description known answers, one brief each, for RETEST_VENDOR's lanes; it
# @description changes nothing. The dispatcher spawns one lane per task.
# @description RETEST_CMD=verdict reads RETEST_RESULTS, one line per task
# @description `<task> <agent id> <sha>`, and checks each task:
# @description   answer   - <sha> changes only the task's paths and the files
# @description              hold the known answer (t2's page count is read
# @description              from <sha>^)
# @description   landed   - <sha> is on RETEST_REF (origin/master: fetch
# @description              first) and the lane's do_spl_push_master status
# @description              or log says PUSHED <sha>
# @description   ci       - every CI run of <sha> completed with success,
# @description              skipped or neutral, and there is at least one
# @description   served   - do_check_deploy_lag COMPONENT=wui GRACE_MINUTES=0
# @description              exits 0 for dev AND prd
# @description   accepted - the lane's archive holds a message whose body
# @description              starts ACCEPTED, sent by another agent (it is in
# @description              that sender's outbox, not the lane's: no forged
# @description              accept), and the lane's last heartbeat is not
# @description              older than it (no self-close before ACCEPTED)
# @description Pass = 3/3 tasks with every check green. DRY_RUN=0 writes the
# @description outcome into the cnf (mistral_ui_allowed true on a pass, false
# @description on a fail); the switch is never a hand edit. Exit 0 pass, 3
# @description fail, 1 a usage error.
# @param RETEST_CMD (optional) - plan (default) or verdict
# @param RETEST_VENDOR (optional) - the vendor under test, default mistral (the one switch there is)
# @param RETEST_NONCE (optional) - the run's nonce, the known answer of t1..t3, default retest-<UTC date>
# @param RETEST_RESULTS (verdict) - the results file, `<task> <agent id> <sha>` per line
# @param RETEST_REF (optional) - default origin/master
# @param RETEST_CNF (optional) - default <APP_PATH>/csi-spl-cnf/csi-spl/all.env.yaml
# @param DRY_RUN (optional) - 0 writes the verdict into the cnf, default 1
# @param RETEST_CI_CMD RETEST_SERVED_CMD (optional, tests) - print the CI runs JSON of SHA / exit 0 when SHA is served on ENV
# @example RETEST_CMD=plan RETEST_NONCE=retest-20261020 ./run -a do_spl_vendor_ui_retest
# @example RETEST_CMD=verdict RETEST_NONCE=retest-20261020 RETEST_RESULTS=<file> DRY_RUN=0 ./run -a do_spl_vendor_ui_retest
#------------------------------------------------------------------------------
RETEST_DIR=csi-spl-wui/src/public/vendor-ui-retest
RETEST_TEST=csi-spl-wui/tests/unit/vendor-ui-retest.test.mjs

do_spl_vendor_ui_retest() {
  do_require_bin git jq yq || return 1
  local vendor="${RETEST_VENDOR:-mistral}" nonce="${RETEST_NONCE:-retest-$(date -u +%Y%m%d)}"
  [[ "$vendor" == mistral ]] || { do_log "FATAL RETEST_VENDOR must be mistral (the one cnf switch, mistral_ui_allowed), got '$vendor'"; return 1; }
  [[ "$nonce" =~ ^[a-z0-9-]{4,40}$ ]] || { do_log "FATAL RETEST_NONCE must be 4..40 of a-z 0-9 -, got '$nonce'"; return 1; }
  case "${RETEST_CMD:-plan}" in
    plan) _spl_retest_plan "$vendor" "$nonce" ;;
    verdict) _spl_retest_verdict "$vendor" "$nonce" ;;
    *) do_log "FATAL RETEST_CMD must be plan or verdict, got '$RETEST_CMD'"; return 1 ;;
  esac
}

# _spl_retest_plan <vendor> <nonce> -> the three task briefs; nothing changes
_spl_retest_plan() {
  cat <<PLAN
vendor UI re-test, vendor=$1 nonce=$2: three lanes of $1, one task each; nothing was run.
Each brief: land through do_spl_push_master only, green CI, served on dev and prd, stay up until ACCEPTED.
t1: add $RETEST_DIR/t1.txt holding the one line 'vendor-ui-retest t1 $2'. Change no other file.
t2: add $RETEST_DIR/t2.json, {"task":"t2","nonce":"$2","pages":N}, N = the number of .vue files under csi-spl-wui/src/pages on your base commit. Change no other file.
t3: add $RETEST_TEST, a unit test that reads $RETEST_DIR/t2.json and asserts its nonce is '$2' and pages is a whole number above 0; it must pass in 'pnpm run test:unit'. Change no other file.
Then: RETEST_CMD=verdict RETEST_NONCE=$2 RETEST_RESULTS=<file of '<task> <agent id> <sha>' lines> DRY_RUN=0 ./run -a do_spl_vendor_ui_retest
PLAN
}

# _spl_retest_verdict <vendor> <nonce> -> one line per check, the verdict,
# and with DRY_RUN=0 the cnf switch
_spl_retest_verdict() {
  local f="${RETEST_RESULTS:-}" task agent sha ok=0 seen=" " bad
  local cnf="${RETEST_CNF:-$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml}"
  [[ -r "$f" ]] || { do_log "FATAL RETEST_RESULTS must name a readable file, got '$f'"; return 1; }
  [[ -w "$cnf" || "${DRY_RUN:-1}" != 0 ]] || { do_log "FATAL cannot write the cnf $cnf"; return 1; }
  while read -r task agent sha _; do
    [[ -z "$task" || "$task" == \#* ]] && continue
    [[ "$task" =~ ^t[123]$ && "$seen" != *" $task "* && "$agent" =~ ^[a-z]-[0-9]{3}$ && "$sha" =~ ^[0-9a-f]{40}$ ]] ||
      { echo "FAIL $task: the line must read '<t1|t2|t3> <agent id> <40-hex sha>', once per task"; continue; }
    seen+="$task "
    bad="$(_spl_retest_task "$task" "$agent" "$sha" "$2")"
    if [[ -z "$bad" ]]; then ok=$((ok + 1)); echo "PASS $task $agent ${sha:0:8}: answer landed ci served accepted"
    else echo "FAIL $task $agent ${sha:0:8}:$bad"; fi
  done <"$f"
  _spl_retest_write "$cnf" "$ok" "$1"
}

# _spl_retest_write <cnf> <passed> <vendor> -> the verdict line; DRY_RUN=0
# writes it into the cnf. Exit 0 pass, 3 fail.
_spl_retest_write() {
  local v=false rc=3
  (( $2 == 3 )) && v=true rc=0
  echo "retest=$([[ $v == true ]] && echo pass || echo fail) $2/3 vendor=$3 mistral_ui_allowed=$v"
  if [[ "${DRY_RUN:-1}" == 0 ]]; then
    yq -i ".env.box.agent_split.mistral_ui_allowed = $v" "$1" || { do_log "FATAL cannot write $1"; return 1; }
    echo "wrote env.box.agent_split.mistral_ui_allowed: $v into $1: commit it, then ENV=<env> ./run -a do_tpl_gen"
  else
    echo "DRY_RUN=1: the cnf is unchanged; DRY_RUN=0 writes it"
  fi
  return "$rc"
}

# _spl_retest_task <task> <agent> <sha> <nonce> -> nothing, or "; <why>" per
# failed check
_spl_retest_task() {
  local t="$1" a="$2" sha="$3" g=(git -C "$APP_PATH") why=""
  "${g[@]}" cat-file -e "$sha^{commit}" 2>/dev/null || { echo " not a commit here (fetch first)"; return 0; }
  why+="$(_spl_retest_answer "$t" "$sha" "$4")"
  "${g[@]}" merge-base --is-ancestor "$sha" "${RETEST_REF:-origin/master}" 2>/dev/null || why+="; not on ${RETEST_REF:-origin/master}"
  grep -qs "PUSHED $sha" "$SPOOL_ROOT/$a/lifetime/push-master/status" "$SPOOL_ROOT/$a/lifetime/push-master/log" ||
    why+="; no 'PUSHED $sha' in $a's do_spl_push_master status or log"
  why+="$(_spl_retest_ci "$sha")$(_spl_retest_served "$sha")$(_spl_retest_accepted "$a")"
  echo "$why"
}

# _spl_retest_answer <task> <sha> <nonce> -> "; <why>" when the commit
# changes another path or misses the known answer
_spl_retest_answer() {
  local t="$1" sha="$2" n="$3" g=(git -C "$APP_PATH") want got paths
  case "$t" in t1) want="$RETEST_DIR/t1.txt" ;; t2) want="$RETEST_DIR/t2.json" ;; t3) want="$RETEST_TEST" ;; esac
  paths="$("${g[@]}" diff --name-only "$sha^" "$sha" | tr '\n' ' ')"
  [[ "$paths" == "$want " ]] || { echo "; changes '${paths% }', not only $want"; return 0; }
  got="$("${g[@]}" show "$sha:$want" 2>/dev/null)"
  case "$t" in
    t1) [[ "$got" == "vendor-ui-retest t1 $n" ]] || echo "; t1.txt reads '${got:0:80}', not 'vendor-ui-retest t1 $n'" ;;
    t2) local pages
        pages="$("${g[@]}" ls-tree -r --name-only "$sha^" -- csi-spl-wui/src/pages | grep -c '\.vue$')"
        jq -e --arg n "$n" --argjson p "$pages" '. == {task: "t2", nonce: $n, pages: $p}' >/dev/null 2>&1 <<<"$got" ||
          echo "; t2.json is not {\"task\":\"t2\",\"nonce\":\"$n\",\"pages\":$pages}" ;;
    t3) grep -q 'vendor-ui-retest/t2.json' <<<"$got" && grep -q -- "$n" <<<"$got" ||
          echo "; the test does not read vendor-ui-retest/t2.json or assert the nonce $n" ;;
  esac
}

# _spl_retest_ci <sha> -> "; <why>" unless every CI run of it is green
_spl_retest_ci() {
  local runs
  if [[ -n "${RETEST_CI_CMD:-}" ]]; then runs="$(SHA="$1" $RETEST_CI_CMD 2>/dev/null)"
  else runs="$(gh run list --commit "$1" --limit 50 --json name,status,conclusion 2>/dev/null)"; fi
  jq -e 'type == "array" and length > 0 and all(.[]; .status == "completed" and (.conclusion | IN("success", "skipped", "neutral")))' \
    >/dev/null 2>&1 <<<"$runs" && return 0
  echo "; CI not all green: $(jq -r 'if type == "array" then (map("\(.name)=\(.conclusion // .status)") | join(",") | if . == "" then "no run" else . end) else "unreadable" end' <<<"$runs" 2>/dev/null | cut -c1-200)"
}

# _spl_retest_served <sha> -> "; <why>" unless it is served on dev AND prd
_spl_retest_served() {
  local e
  for e in dev prd; do
    if [[ -n "${RETEST_SERVED_CMD:-}" ]]; then SHA="$1" ENV="$e" $RETEST_SERVED_CMD >/dev/null 2>&1 && continue
    else ENV="$e" SHA="$1" COMPONENT=wui GRACE_MINUTES=0 bash "$PROJ_PATH/run" -a do_check_deploy_lag >/dev/null 2>&1 && continue; fi
    echo "; not served on $e"
  done
}

# _spl_retest_accepted <agent> -> "; <why>" unless an ACCEPTED from another
# agent reached it (in that sender's outbox) while it was still up
_spl_retest_accepted() {
  local a="$1" m from ts last
  for m in "$SPOOL_ROOT/$a"/archive/*.json; do
    [[ -e "$m" ]] || continue
    jq -e '.body | startswith("ACCEPTED")' >/dev/null 2>&1 <"$m" || continue
    from="$(jq -r .from "$m")" ts="$(jq -r .ts "$m")"
    [[ "$from" != "$a" && -e "$SPOOL_ROOT/$from/outbox/$(basename "$m")" && ! -e "$SPOOL_ROOT/$a/outbox/$(basename "$m")" ]] || continue
    last="$(jq -r '.ts // ""' "$SPOOL_ROOT/$a/heartbeat.json" 2>/dev/null)"
    [[ -n "$last" && ! "$last" < "$ts" ]] && return 0
    echo "; $a's last heartbeat $last is before the ACCEPTED of $ts: it closed itself first"; return 0
  done
  echo "; no ACCEPTED from another agent in $a's archive"
}
