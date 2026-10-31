#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2122 (how-to-post.md rule 16) - do_spl_desk_reply and
#          do_spl_desk_post refuse a post that opens with **Live** unless it
#          carries its proof, and send every other post as before. Owner
#          HUM-10, t1 topic 28559e83, msgs 395a375b + 6c3fd53d: a **Live**
#          "every card is the same height" went out with the image cards
#          never measured.
#   1. RED CONTROL: the post that went out (Live, no sha, no checked lines)
#      is refused, FATAL names each missing piece + how-to-post.md, nothing
#      reaches the spool; the same text as **Landed, not live yet** is sent
#   2. Live with checked lines but no sha -> refused; a msg id or a topic
#      uuid is not a sha
#   3. Live with a sha that is not on origin/master -> refused
#   4. Live with a hub/wui sha that dev or prd does not serve -> refused
#   5. Live with a served sha + checked + not checked -> sent, body unchanged
#   6. an orc/doc-only sha: refused without `no deploy`, sent with it
#   7. Planned / In progress / Landed openings and a poll form -> sent, no proof
#   8. a reply tagged @HUM-n before **Live** is still checked
#   9. do_spl_desk_post: the same guard on a channel post
#  10. SPL-2420 LIVE_REPO=<cnf name>: a customer repo's sha on its fetched
#      trunk is Live with no deploy rule; a sha off its trunk, an unknown
#      name, a clone on another box and a csi-spl sha are refused
#  11. SPL-2706: an all-digit short sha of a commit on origin/master (c-597's
#      704617890 shape) is a sha; a 9-digit number that is no commit is not
#  12. SPL-3746: only the components whose input the sha changed are judged.
#      do_check_deploy_lag is stubbed (c-002's 701c8a61f lines: wui current,
#      hub pending): a wui-only sha is sent; a hub sha, a mixed sha and a
#      wui-only sha with the wui pending are still refused
# The served verdicts are stubbed at do_check_lane_served's seams
# (_spl_served_components / _spl_served_env, tested in lane-served.tst.sh);
# case 12 stubs one level lower, do_check_deploy_lag, to drive the seams;
# the git side is a real repo with a local origin.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=28559e83-ac82-4123-a2ef-4994da2c46a3

# A repo whose origin/master holds ON; OFF is a local commit never pushed.
g() { git -C "$T/wt" -c user.name=t -c user.email=t@example.com "$@"; }
# commit_sha_word <msg>: an empty commit whose 9-char prefix has a digit AND a
# letter. The guard used to skip a hex word without both, so an all-digit
# prefix (~1.5% of fresh hashes) turned cases 4-6 and 9 red at random (wf 10
# run 38954245818); since SPL-2706 case 11 covers the all-digit one.
commit_sha_word() {
  local i=0 h
  g commit -q --allow-empty -m "$1"
  while h="$(g rev-parse HEAD)"; [[ ! "${h:0:9}" =~ [0-9] || ! "${h:0:9}" =~ [a-f] ]]; do
    i=$((i + 1)); g commit -q --amend --allow-empty -m "$1 $i"
  done
}
git init -q --bare "$T/origin.git"
git init -q -b master "$T/wt"
g commit -q --allow-empty -m base
commit_sha_word on
ON="$(g rev-parse HEAD)"
g remote add origin "$T/origin.git"
g push -q origin master
commit_sha_word off
OFF="$(g rev-parse HEAD)"

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a prev=""; for a in "$@"; do [[ "$prev" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}
_spl_served_needs_deploy() { echo "$NEEDS"; }
_spl_served_components() { [[ "$NEEDS" == no ]] || echo "hub wui"; }
_spl_served_env() { echo "$SERVED"; }'

# send <action> <body> [VAR=value]... -> rc; output in $T/o, the sent body in $T/sent
send() {
  local act="$1" body="$2"; shift 2
  rm -f "$T/sent"
  SNIPPET="$STUBS"$'\n'"$act" in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-10 DESK_TASK="$TOPIC" \
    DESK_CHANNEL=ops DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" LANE_WT="$T/wt" FETCH_FRESH_MAX_AGE=0 \
    NEEDS=yes SERVED=served "$@" >"$T/o" 2>&1
}
refused() { # <label> <must-name>...: rc != 0, nothing sent, the FATAL names each piece and the rule
  local label="$1" n ok=1; shift
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -q 'FATAL a \*\*Live\*\* post must carry its proof' "$T/o" &&
    grep -q 'how-to-post.md rule 16' "$T/o" || ok=0
  for n in "$@"; do grep -q -- "$n" "$T/o" || ok=0; done
  (( ok )) && pass "$label" || fail "$label (rc $rc): $(cat "$T/o")"
}
sent() { # <label> <body>: rc 0 and the body reached the spool byte for byte
  (( rc == 0 )) && [[ -f "$T/sent" && "$(cat "$T/sent")" == "$2" ]] && ! grep -q FATAL "$T/o" &&
    pass "$1" || fail "$1 (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
}
PROOF=$'checked: text cards, moved-from cards, image cards at 1 and 5 rows on dev and prd\nnot checked: none'

# --- 1. RED CONTROL: the post that went out -----------------------------------------
B='**Live**: with the 5-row card setting, every card is the same height now, on dev and prd.'
send do_spl_desk_reply "$B"; rc=$?
refused "1. the owner's case (Live, no proof) is refused, nothing sent" "commit sha on origin/master" "'checked:' line" "'not checked:' line"
B2="**Landed, not live yet.** ${B#*: }"
send do_spl_desk_reply "$B2"; rc=$?
sent "1. CONTROL: the same text opening **Landed, not live yet** is sent" "$B2"

# --- 2. no sha (a msg id and a topic uuid are not shas) -----------------------------
B="**Live** per owner msg 395a375b in topic $TOPIC."$'\n'"$PROOF"
send do_spl_desk_reply "$B"; rc=$?
refused "2. Live with checked lines but no commit sha is refused" "commit sha on origin/master"
grep -q "'checked:' line\|'not checked:' line" "$T/o" && fail "2. the checked lines were present but reported missing: $(cat "$T/o")" ||
  pass "2. only the missing sha is named"

# --- 3. a sha not on master ---------------------------------------------------------
B="**Live** ${OFF:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B"; rc=$?
refused "3. Live with a sha not on origin/master is refused" "sha ${OFF:0:9} on origin/master"

# --- 4. not served ------------------------------------------------------------------
B="**Live** ${ON:0:9} on dev and prd"$'\n'"$PROOF"
send do_spl_desk_reply "$B" SERVED=lag; rc=$?
refused "4. Live with a wui/hub sha dev and prd do not serve is refused" "served on dev (do_check_deploy_lag says: lag)" "served on prd"

# --- 5. the full proof ----------------------------------------------------------------
send do_spl_desk_reply "$B"; rc=$?
sent "5. Live with a served sha + checked + not checked is sent unchanged" "$B"

# --- 6. orc / doc only --------------------------------------------------------------
send do_spl_desk_reply "$B" NEEDS=no; rc=$?
refused "6. an orc-only sha without 'no deploy' is refused" "'no deploy' for sha ${ON:0:9}"
B6="**Live** ${ON:0:9} (orc only, no deploy)"$'\n'"$PROOF"
send do_spl_desk_reply "$B6" NEEDS=no; rc=$?
sent "6. an orc-only sha that says 'no deploy' is sent" "$B6"

# --- 7. other states and a poll form ------------------------------------------------
for B in '**Planned, not built yet.** Tracked as SPL-1.' '**In progress** (c-1, since 10:00Z): cards.' \
  '**Landed, not live yet.** On master.' 'The cards are Live now? no: plain text is not a state.'; do
  # the Planned ask check is desk-planned-ask.tst.sh's (SPL-3525)
  send do_spl_desk_reply "$B" DESK_PLANNED_CHECK=0; rc=$?
  sent "7. '${B:0:28}' is sent without a proof" "$B"
done
B=$'Ship it?\n\n```poll\nDeploy to prd?\n(GO) Go\n```'
send do_spl_desk_reply "$B"; rc=$?
sent "7. a poll form is sent without a proof" "$B"

# --- 8. tagged reply ------------------------------------------------------------------
send do_spl_desk_reply $'\n@HUM-10 **Live:** cards fixed.'; rc=$?
refused "8. '@HUM-10 **Live:**' is checked like **Live**" "commit sha"

# --- 9. do_spl_desk_post ----------------------------------------------------------------
send do_spl_desk_post '**Live** cards fixed.'; rc=$?
refused "9. do_spl_desk_post refuses a Live channel post without its proof" "commit sha" "'checked:' line"
B="**Live** ${ON:0:9} served"$'\n'"$PROOF"
send do_spl_desk_post "$B"; rc=$?
sent "9. do_spl_desk_post sends a Live post with its proof" "$B"
send do_spl_desk_post '**In progress** cards.'; rc=$?
sent "9. do_spl_desk_post sends other states as before" '**In progress** cards.'

# --- 10. a customer repo of the cnf (SPL-2420) -------------------------------------
cg() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
git init -q --bare "$T/cust.git"
git init -q -b master "$T/cust-push" && cg "$T/cust-push" commit -q --allow-empty -m init &&
  cg "$T/cust-push" remote add origin "$T/cust.git" && cg "$T/cust-push" push -q origin master
git clone -q "$T/cust.git" "$T/cust"
cust_word() { # <msg>: a commit pushed to <branch> whose 9-char prefix has a digit and a letter
  local i=0 h
  cg "$T/cust-push" commit -q --allow-empty -m "$1"
  while h="$(cg "$T/cust-push" rev-parse HEAD)"; [[ ! "${h:0:9}" =~ [0-9] || ! "${h:0:9}" =~ [a-f] ]]; do
    i=$((i + 1)); cg "$T/cust-push" commit -q --amend --allow-empty -m "$1 $i"
  done
}
cg "$T/cust-push" checkout -q -b wip && cust_word cust-off && cg "$T/cust-push" push -q origin wip
COFF="$(cg "$T/cust-push" rev-parse HEAD)"
cg "$T/cust-push" checkout -q master && cust_word cust-on && cg "$T/cust-push" push -q origin master
CON="$(cg "$T/cust-push" rev-parse HEAD)"
printf 'env:\n  box:\n    landed_repos:\n      - {name: cust-rel, src_dir: %s, trunk: master}\n      - {name: far-rel, src_dir: %s, box: box-b}\n' \
  "$T/cust" "$T/not-here" >"$T/cust.yaml"
CUST=(LIVE_REPO=cust-rel LANE_LANDED_CNF="$T/cust.yaml" SPOOL_BOX_USER= SPOOL_BOX_TAG=box-a NEEDS=no SERVED=lag)
! cg "$T/cust" cat-file -e "$CON^{commit}" 2>/dev/null && pass "10. control: the clone has not fetched the landed sha yet" ||
  fail "10. control: the clone already has $CON"
B="**Live** csi-rel ${CON:0:9} on master"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}"; rc=$?
sent "10. a customer repo sha on its fetched trunk is Live, no deploy rule (NEEDS=no, SERVED=lag)" "$B"
B="**Live** csi-rel ${COFF:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}"; rc=$?
refused "10. RED CONTROL a customer sha on a branch only is refused" "cust-rel sha ${COFF:0:9} on origin/master (it is not"
B="**Live** ${ON:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}"; rc=$?
refused "10. a csi-spl sha under LIVE_REPO=cust-rel is not a cust-rel sha" "a commit sha of cust-rel on origin/master"
one_line() { # <label> <must-name>: rc != 0, nothing sent, exactly one FATAL line naming it
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && [[ "$(grep -c FATAL "$T/o")" == 1 ]] && grep -q -- "$2" "$T/o" &&
    pass "$1" || fail "$1 (rc $rc): $(cat "$T/o")"
}
B="**Live** csi-rel ${CON:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}" LIVE_REPO=other-rel; rc=$?
one_line "10. RED CONTROL an unknown LIVE_REPO name is refused in one line" "'other-rel' is no repo the cnf knows (src_dir names: cust-rel far-rel)"
send do_spl_desk_reply "$B" "${CUST[@]}" LIVE_REPO=far-rel; rc=$?
one_line "10. a clone on another box: one line naming this box and the cnf's" "not a git repo on this box (box-a); its clone is on box box-b: run it there"
send do_spl_desk_reply "$B" "${CUST[@]}" LIVE_REPO=../cust; rc=$?
one_line "10. a path as LIVE_REPO is refused" "must be a repo NAME the cnf knows, not a path or URL"

# SPL-3794: LIVE_REPO resolves through the same rows, the workspace box map's too.
git clone -q "$T/cust.git" "$T/wsc"
printf 'ws-a\tprd\tsite-alpha\t%s\tmaster\thttps://alpha.example.com\tc-901\tbox-a\n' "$T/wsc" >"$T/ws-map.tsv"
WS=(SPOOL_WORKSPACE_REPOS_MAP="$T/ws-map.tsv" LIVE_REPO=site-alpha)
B="**Live** site ${CON:0:9} on master"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}" "${WS[@]}"; rc=$?
sent "10. LIVE_REPO=<a workspace box map repo>: its sha on the fetched trunk is Live" "$B"
send do_spl_desk_reply "$B" "${CUST[@]}" LIVE_REPO=site-alpha; rc=$?
one_line "10. RED CONTROL the same LIVE_REPO with no box map is refused" "'site-alpha' is no repo the cnf knows (src_dir names: cust-rel far-rel)"
send do_spl_desk_reply "$B" "${CUST[@]}" "${WS[@]}" LIVE_REPO=other-rel; rc=$?
one_line "10. an unknown LIVE_REPO with a box map: the list counts the map's repos, naming none" "(src_dir names: cust-rel far-rel and 1 workspace repo(s))"
! grep -qE "site-alpha|$T/wsc" "$T/o" && pass "10. ... no map repo or clone in the refusal" || fail "10. map leak: $(cat "$T/o")"

# SPL-4471: LIVE_REPO of a GitHub-only row (its clone takes no git command) is
# proven on GitHub (stubbed), from any box; the row may come from the box-side
# SPOOL_LANDED_REPOS_FILE.
# gh_landed_stub: a GitHub stub on PATH for a GitHub-only landed_repos row
# (SPL-4471): repo $GH_REPO, trunk master, $GH_ON on it, $GH_OFF on a branch
# only, anything else a 404; each call logged to $GH_LOG.
gh_landed_stub() {
  mkdir -p "$T/stub"
  cat >"$T/stub/gh" <<'GHSTUB'
#!/bin/bash
echo "gh $*" >>"$GH_LOG"
r="repos/$GH_REPO"
[[ "$1" == api ]] || exit 1
case "$2" in
  "$r" | "$r/branches/master") echo master ;;
  "$r/commits/"*) for f in $GH_ON $GH_OFF; do [[ "$f" == "${2##*/}"* ]] && { echo "$f"; exit 0; }; done; echo 'HTTP 404' >&2; exit 1 ;;
  "$r/compare/master..."*) [[ " $GH_ON " == *" ${2##*...} "* ]] && echo behind || echo diverged ;;
  *) echo 'HTTP 404' >&2; exit 1 ;;
esac
GHSTUB
  chmod +x "$T/stub/gh"
}
GH_ON=1a2b3c4d1a2b3c4d1a2b3c4d1a2b3c4d1a2b3c4d
GH_OFF=9f8e7d6c9f8e7d6c9f8e7d6c9f8e7d6c9f8e7d6c
printf 'env:\n  box:\n    landed_repos:\n      - {name: far-hub, github: example-org/far-hub, trunk: master}\n' >"$T/gh.yaml"
chmod 644 "$T/gh.yaml"
GH=(LIVE_REPO=far-hub LANE_LANDED_CNF="$T/gh.yaml" GH_LOG="$T/gh.log" GH_REPO=example-org/far-hub GH_ON="$GH_ON" GH_OFF="$GH_OFF" SPOOL_BOX_TAG=box-z)
gh_landed_stub
B="**Live** far-hub ${GH_ON:0:9} on master, running on its hub box"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}" "${GH[@]}"; rc=$?
sent "10. LIVE_REPO=<a GitHub-only row>: a sha on its GitHub trunk is Live on any box (box-z)" "$B"
B="**Live** far-hub ${GH_OFF:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}" "${GH[@]}"; rc=$?
refused "10. RED CONTROL a GitHub-only row's sha on a branch only is refused" "far-hub sha ${GH_OFF:0:9} on origin/master (it is not"
B="**Live** far-hub ${CON:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}" "${GH[@]}"; rc=$?
refused "10. a hex word GitHub does not have is no far-hub sha" "a commit sha of far-hub on origin/master"
B="**Live** far-hub ${GH_ON:0:9}"$'\n'"$PROOF"
send do_spl_desk_reply "$B" "${CUST[@]}" "${GH[@]}" LANE_LANDED_CNF="$T/cust.yaml"; rc=$?
one_line "10. RED CONTROL a cnf with no far-hub row refuses LIVE_REPO=far-hub" "'far-hub' is no repo the cnf knows (src_dir names: cust-rel far-rel)"
# The file counts only when the spool root's owner (or root) owns it: the test's
# own SPOOL_ROOT, owned by the test user. The box's /var/spool-hub is owned by
# another user, or missing on a CI runner (wf 10 run 41182926135).
mkdir -p "$T/spool"
send do_spl_desk_reply "$B" "${CUST[@]}" "${GH[@]}" LANE_LANDED_CNF="$T/cust.yaml" SPOOL_LANDED_REPOS_FILE="$T/gh.yaml" SPOOL_ROOT="$T/spool"; rc=$?
sent "10. the box-side SPOOL_LANDED_REPOS_FILE's GitHub-only row beside the cnf's: Live" "$B"
send do_spl_desk_reply "$B" "${CUST[@]}" "${GH[@]}" LANE_LANDED_CNF="$T/cust.yaml" SPOOL_LANDED_REPOS_FILE="$T/gh.yaml" SPOOL_ROOT="$T/no-spool"; rc=$?
one_line "10. RED CONTROL the same file under a missing SPOOL_ROOT (no owner to match) adds no row" "'far-hub' is no repo the cnf knows (src_dir names: cust-rel far-rel)"
rm -f "$T/stub/gh"

# --- 11. an all-digit short sha (SPL-2706) ----------------------------------------
# digit_word <msg>: an empty commit on master whose 9-char prefix is all digits
# (~1.5% of hashes: amend until it is), pushed to origin.
digit_word() {
  local i=0 h
  g commit -q --allow-empty -m "$1"
  while h="$(g rev-parse HEAD)"; [[ ! "${h:0:9}" =~ ^[0-9]{9}$ ]]; do
    i=$((i + 1)); (( i < 3000 )) || { fail "11. no all-digit 9-char prefix in $i amends"; return 1; }
    g commit -q --amend --allow-empty -m "$1 $i"
  done
  g push -q origin HEAD:master
}
g checkout -q -b digit origin/master && digit_word digit
DIG="$(g rev-parse HEAD)"
B="**Live** ${DIG:0:9} (orc only, no deploy)"$'\n'"$PROOF"
send do_spl_desk_reply "$B" NEEDS=no; rc=$?
sent "11. an all-digit short sha (${DIG:0:9}) of a commit on origin/master is a sha: sent" "$B"
NUM=123456789
[[ "$(g cat-file -t "$NUM" 2>/dev/null)" != commit ]] && pass "11. control: $NUM is no commit of the checkout" ||
  fail "11. control: $NUM resolves to a commit"
B="**Live** run $NUM (orc only, no deploy)"$'\n'"$PROOF"
send do_spl_desk_reply "$B" NEEDS=no; rc=$?
refused "11. a 9-digit number that is no commit is still no sha" "commit sha on origin/master"

# --- 12. only the components the sha feeds are judged (SPL-3746) ------------------
# The seams run for real; do_check_deploy_lag is the stub. Asked with a file://
# probe it is _spl_served_components' question: TOUCH names the components
# whose input the sha changed. Asked for real it prints c-002's 701c8a61f
# lines: PENDING names the components still rolling, the others are current.
STUBS_SEAMS="${STUBS%%_spl_served_needs_deploy*}"'
do_check_deploy_lag() {
  local c
  for c in hub wui; do
    if [[ "${LAG_HUB_URL:-}" == file://* ]]; then
      if [[ " $TOUCH " == *" $c "* ]]; then echo "dev $c pending served=5ea1c2c0 sha=701c8a61 n=1 oldest=701c8a61 age=1m grace=99999999m"
      else echo "dev $c current served=5ea1c2c0 sha=701c8a61 n=0 (no $c build input changed since the served commit)"; fi
      continue
    fi
    [[ "$COMPONENT" == all || "$COMPONENT" == "$c" ]] || continue
    echo "$c" >>"$ASKED"
    if [[ " $PENDING " == *" $c "* ]]; then echo "$ENV $c pending served=ecb9ca07 sha=701c8a61 n=1 oldest=5ea1c2c0 age=22m grace=45m age_from=commit"
    else echo "$ENV $c current served=701c8a61 sha=701c8a61 (the env serves this commit or a later one)"; fi
  done
}'
seams() { # <action> <body> TOUCH=.. PENDING=..: send with the real seams
  local keep="$STUBS"; STUBS="$STUBS_SEAMS"; : >"$T/asked"
  send "$1" "$2" ASKED="$T/asked" "${@:3}"; rc=$?; STUBS="$keep"
}
B="**Live** ${ON:0:9} (the blog posts) on dev and prd"$'\n'"$PROOF"
seams do_spl_desk_reply "$B" TOUCH=wui PENDING=hub
sent "12. a wui-only sha with an unrelated hub roll pending is sent" "$B"
grep -qx hub "$T/asked" && fail "12. the hub was asked about a wui-only sha: $(sort "$T/asked" | uniq -c)" ||
  pass "12. only the wui was asked"
seams do_spl_desk_reply "$B" TOUCH=hub PENDING=hub
refused "12. CONTROL a hub sha with the hub pending is still refused" "sha ${ON:0:9} served on dev (do_check_deploy_lag says: lag) judged on: hub" "served on prd"
seams do_spl_desk_reply "$B" TOUCH="hub wui" PENDING=hub
refused "12. a mixed sha with the hub pending is refused" "served on dev (do_check_deploy_lag says: lag) judged on: hub wui"
seams do_spl_desk_reply "$B" TOUCH=wui PENDING=wui
refused "12. a wui-only sha with the wui pending is refused" "served on dev (do_check_deploy_lag says: lag) judged on: wui"
seams do_spl_desk_reply "$B" TOUCH=hub PENDING=wui
sent "12. a hub-only sha with only a wui roll pending is sent" "$B"
B6="**Live** ${ON:0:9} (orc only, no deploy)"$'\n'"$PROOF"
seams do_spl_desk_reply "$B6" TOUCH= PENDING="hub wui"
sent "12. a sha that feeds neither is sent with 'no deploy', nothing pending matters" "$B6"

echo "desk-live-proof: $fails failure(s)"
((fails == 0))
