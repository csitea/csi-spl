#!/bin/bash
#------------------------------------------------------------------------------
# @description The owner-order GATE (spec 168 part c, build row B3, SPL-4372):
# @description ORDER_CMD=gate of do_spl_owner_order. A change to a path that an
# @description active `gate: go` or `gate: content` order of the repo's ledger
# @description covers is REFUSED unless it cites the owner's go for it: an
# @description `Owner-go: <msg uuid>` trailer (a staged change: ORDER_GO_MSGS)
# @description naming an owner message, not the order's own id, whose body
# @description names the order's id8.
# @description Which paths (N2, c-697 W5/W6):
# @description   gate go       every path of `git diff --name-status --no-renames`:
# @description                 both sides of a rename or move, so a file moved out
# @description                 of a covered folder (and edited) is covered
# @description   gate content  rename detection at 100% (-M100%): a pure rename or
# @description                 move (R100, the same blob) passes on both sides; any
# @description                 other change of a covered path needs the go
# @description   gate none     never gated (parts a and b only)
# @description The go and every lift of a gating order are verified on the hub
# @description (ORDER_GO_HUB): the message must be on it, from an owner (HUM-<n>)
# @description and its body must carry the marker for the order (N1, N3): a
# @description whole-word "go <id8>" (or "go for", "go:"; a lift "lift <id8>",
# @description "lift order <id8>", which is a go too), not negated ("do not go
# @description <id8>"); a bare mention of the id8 ("keep <id8>, do NOT change
# @description it") is no go. A lift that fails it
# @description does not lift (N3: the ledger's `source: hub` word is not
# @description trusted). Without a hub only the form is checked, and every PASS
# @description line says "NOT hub-checked".
# @description Merge commits are not read (their first-parent diff is the other
# @description side's work); the commits they bring are, one by one.
# @description stdout: ids, gates and paths, never an order's text (./run logs it).
# @description Exit: 0 passed (or no ledger, or nothing covered), 3 REFUSED, 2 the
# @description ledger is unreadable or malformed, 1 refused input or a hub read
# @description that failed. Every caller refuses on anything but 0.
# @param ORDER_REPO_DIR (required) - the checkout (or worktree) of the repo
# @param ORDER_REVS (one of) - the commits, as git rev-list arguments: '<old>..<new>' or '<new> --not --remotes'
# @param ORDER_STAGED (one of) - 1: the staged change of a commit not made yet (the harness guard)
# @param ORDER_STAGED_ALL (optional) - 1: with ORDER_STAGED, every tracked change of the work tree plus the untracked files (git commit -a, a pathspec, or a git add earlier in the same command)
# @param ORDER_STAGED_BASE (optional) - with ORDER_STAGED: the commit the change is read against, default HEAD (git commit --amend: HEAD^); none = the empty tree
# @param ORDER_GO_MSGS (optional) - with ORDER_STAGED: the Owner-go ids the commit message will carry, comma-separated
# @param ORDER_GO_HUB (optional) - dev | prd | none; default prd when this box holds the prd key, else none
# @param OWNER_ORDER_DIR (optional) - default $SPOOL_ROOT/owner-orders
# @example ORDER_CMD=gate ORDER_REPO_DIR="$PWD" ORDER_REVS='origin/master..HEAD' ./run -a do_spl_owner_order
# @example ORDER_CMD=gate ORDER_REPO_DIR="$PWD" ORDER_STAGED=1 ORDER_GO_MSGS=<uuid> ORDER_GO_HUB=none ./run -a do_spl_owner_order
#------------------------------------------------------------------------------
SPL_OO_EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# Per unit (a commit, or the staged change): the gating orders that cover a
# path of it, with those paths. Input: the folded orders; $all / $content the
# unit's paths for gate go / gate content.
# shellcheck disable=SC2016
SPL_OO_GATE_JQ='.[] | select((.gate == "go" or .gate == "content") and (.state == "active" or .state == "lifted"))
  | . as $o | (if $o.gate == "go" then $all else $content end) as $ps
  | [$ps[] | select(. as $p | any($o.paths[]; g2r as $rx | $p | test($rx)))] as $hit
  | select($hit | length > 0)
  | {order: $o.order, gate: $o.gate, state: $o.state, source: $o.source, lift_msg: ($o.lift.lift_msg // ""), paths: $hit}'

_spl_oo_gate() {
  local dir="$1" repo f all hub rc
  [[ -n "${ORDER_REPO_DIR:-}" ]] || { do_log "FATAL ORDER_REPO_DIR is required: the checkout to gate"; return 1; }
  repo="$(ORDER_REPO='' _spl_oo_repo)" || return 1
  f="$dir/$repo.jsonl"
  # W2: a dir the pusher cannot search hides its ledger; it is never "no ledger"
  [[ ! -e "$dir" || ( -d "$dir" && -x "$dir" ) ]] ||
    { echo "owner-orders: REFUSED the ledger dir $dir cannot be searched by $(id -un 2>/dev/null): fail closed"; return 2; }
  [[ ! -e "$f" || -r "$f" ]] ||
    { echo "owner-orders: REFUSED the $repo ledger $f cannot be read by $(id -un 2>/dev/null): fail closed"; return 2; }
  [[ -e "$f" ]] || { echo "owner-orders: PASS no ledger for $repo"; return 0; }
  all="$(_spl_oo_fold "$f")" || return 2
  all="$(jq -c '[.[] | select(.gate == "go" or .gate == "content") | select(.state != "expired")]' <<<"$all")"
  [[ "$all" != '[]' ]] || { echo "owner-orders: PASS the $repo ledger has no gating order"; return 0; }
  hub="$(_spl_oo_gate_hub)" || return 1
  local OO_VCACHE
  OO_VCACHE="$(mktemp -d)" || { do_log "FATAL cannot make a temp dir"; return 1; }
  _spl_oo_gate_run "$all" "$hub" "$repo"; rc=$?
  rm -rf "$OO_VCACHE"
  return "$rc"
}

# _spl_oo_gate_run <orders> <hub> <repo>: the staged change, or each commit
# of ORDER_REVS
_spl_oo_gate_run() {
  local all="$1" hub="$2" repo="$3" c list rc=0 n=0 nh=""
  local -a revs=()
  [[ "$hub" == none ]] && nh=" (NOT hub-checked: no hub on this box)"
  if [[ "${ORDER_STAGED:-0}" == 1 ]]; then
    _spl_oo_gate_unit "$all" "$hub" staged "${ORDER_GO_MSGS:-}" || return $?
    echo "owner-orders: PASS the staged change of $repo$nh"; return 0
  fi
  read -r -a revs <<<"${ORDER_REVS:-}"
  ((${#revs[@]} > 0)) || { do_log "FATAL ORDER_REVS (or ORDER_STAGED=1) is required"; return 1; }
  for c in "${revs[@]}"; do
    [[ "$c" =~ ^[A-Za-z0-9_./^~@{}:=-]+$ ]] || { do_log "FATAL ORDER_REVS: '$c' is not a rev-list argument"; return 1; }
  done
  list="$(git -C "$ORDER_REPO_DIR" rev-list --reverse --no-merges "${revs[@]}" 2>/dev/null)" ||
    { do_log "FATAL git rev-list ${revs[*]} failed in $ORDER_REPO_DIR"; return 1; }
  while read -r c; do
    [[ -n "$c" ]] || continue
    n=$((n + 1))
    _spl_oo_gate_unit "$all" "$hub" "$c" "$(git -C "$ORDER_REPO_DIR" log -1 --format='%(trailers:key=Owner-go,valueonly,separator=%x2C)' "$c")"
    case $? in 0) ;; 3) rc=3 ;; *) return 1 ;; esac
  done <<<"$list"
  [[ "$rc" == 0 ]] && echo "owner-orders: PASS $n commit(s) of $repo, none changes a covered path without its owner go$nh"
  return "$rc"
}

# _spl_oo_gate_hub: prints dev, prd or none. Unset = prd when this box holds
# the prd project's SA key (the one do_spl_db_query reads), else none.
_spl_oo_gate_hub() {
  local h="${ORDER_GO_HUB:-}"
  if [[ -z "$h" ]]; then
    h=none
    # shellcheck disable=SC2030 # ENV is the subshell's own
    ( ENV=prd; do_spl_cloud_cnf >/dev/null 2>&1 && do_gcp_sa_key_file "$SPL_CNF" >/dev/null 2>&1 ) && h=prd
  fi
  [[ "$h" =~ ^(dev|prd|none)$ ]] || { do_log "FATAL ORDER_GO_HUB must be dev, prd or none (got '$h')" >&2; return 1; }
  echo "$h"
}

# _spl_oo_gate_paths <unit> <go|content>: the unit's paths, NUL-separated.
# go: --no-renames (both sides of a move). content: -M100%, an R100 pair
# dropped (a pure rename or move changes no content). An untracked file
# (ORDER_STAGED_ALL) counts as added, for both.
_spl_oo_gate_paths() {
  local u="$1" st a b base
  local -a rng=() ren=(--no-renames)
  [[ "$2" == content ]] && ren=(-M100%)
  if [[ "$u" == staged ]]; then
    base="$(git -C "$ORDER_REPO_DIR" rev-parse -q --verify "${ORDER_STAGED_BASE:-HEAD}^{commit}" 2>/dev/null)" || base="$SPL_OO_EMPTY_TREE"
    rng=(--cached "$base")
    if [[ "${ORDER_STAGED_ALL:-0}" == 1 ]]; then
      rng=("$base")
      git -C "$ORDER_REPO_DIR" ls-files -z --others --exclude-standard 2>/dev/null
    fi
  else
    rng=("$SPL_OO_EMPTY_TREE" "$u")
    git -C "$ORDER_REPO_DIR" rev-parse -q --verify "$u^1" >/dev/null && rng=("$u^1" "$u")
  fi
  git -C "$ORDER_REPO_DIR" diff --name-status -z "${ren[@]}" "${rng[@]}" -- 2>/dev/null |
    while IFS= read -r -d '' st; do
      case "$st" in
        R*|C*) IFS= read -r -d '' a; IFS= read -r -d '' b
               [[ "$st" == R100 ]] || printf '%s\0%s\0' "$a" "$b" ;;
        *) IFS= read -r -d '' a; printf '%s\0' "$a" ;;
      esac
    done
}

# _spl_oo_gate_unit <orders> <hub> <unit: sha | staged> <go ids, comma-sep>:
# rc 0 pass, 3 refused, 1 a hub read failed
_spl_oo_gate_unit() {
  local orders="$1" hub="$2" u="$3" gos="$4" hits h lbl rc=0 pa pc
  pa="$(_spl_oo_gate_paths "$u" go | jq -R -s -c 'split("\u0000") | map(select(. != ""))')" || return 1
  pc="$(_spl_oo_gate_paths "$u" content | jq -R -s -c 'split("\u0000") | map(select(. != ""))')" || return 1
  hits="$(jq -c --argjson all "$pa" --argjson content "$pc" "$SPL_OO_G2R$SPL_OO_GATE_JQ" <<<"$orders")" ||
    { do_log "FATAL the gate match failed"; return 1; }
  [[ -n "$hits" ]] || return 0
  lbl="${u:0:9}"; [[ "$u" == staged ]] && lbl="the staged change"
  while read -r h; do
    [[ -n "$h" ]] || continue
    _spl_oo_gate_order "$hub" "$u" "$lbl" "$gos" "$h"
    case $? in 0) ;; 3) rc=3 ;; *) return 1 ;; esac
  done <<<"$hits"
  return "$rc"
}

# _spl_oo_gate_order <hub> <unit> <label> <go ids> <hit json>: one covering
# order. rc 0 lifted or cited, 3 refused, 1 a hub read failed.
_spl_oo_gate_order() {
  local hub="$1" u="$2" lbl="$3" gos="$4" o gate src st lm paths id8 why g
  # \x1f, not a tab: tab is IFS white space, so an empty lift_msg would shift the fields
  IFS=$'\x1f' read -r o gate src st lm paths < <(jq -r '[.order, .gate, .source, .state, .lift_msg, (.paths[:5] | join(", "))] | join("\u001f")' <<<"$5")
  id8="${o:0:8}"
  if [[ "$st" == lifted ]]; then
    why="$(_spl_oo_go_verdict "$hub" "$lm" "$o" lift)"
    case $? in
      0) echo "owner-orders: PASS $lbl order $id8 is lifted on ${lm:0:8} ($why)"; return 0 ;;
      1) echo "owner-orders: WARN order $id8: its lift ${lm:0:8} does not hold ($why): the order still applies" ;;
      *) echo "owner-orders: REFUSED the $hub hub read for lift ${lm:0:8} failed ($why)"; return 1 ;;
    esac
  fi
  for g in ${gos//,/ }; do
    why="$(_spl_oo_go_verdict "$hub" "$g" "$o" go)"
    case $? in
      0) echo "owner-orders: PASS $lbl order $id8 (gate $gate) go ${g:0:8} ($why)"; return 0 ;;
      1) echo "owner-orders: $lbl: Owner-go: $g does not count for order $id8 ($why)" ;;
      *) echo "owner-orders: REFUSED the $hub hub read for go $g failed ($why)"; return 1 ;;
    esac
  done
  echo "owner-orders: REFUSED $lbl changes path(s) covered by owner order $id8 (gate $gate, source $src): $paths"
  if [[ "$u" == staged ]]; then
    echo "owner-orders:   add this line to the commit message: Owner-go: <the owner's go message uuid; its body names $id8>"
  else
    echo "owner-orders:   add this trailer to commit $lbl (git commit --amend, or rebase -i reword): Owner-go: <the owner's go message uuid; its body names $id8>"
  fi
  return 3
}

# _spl_oo_go_verdict <hub> <msg> <order uuid> <go|lift>: the reason on stdout. rc 0 it
# counts, 1 it does not, 2 the hub read failed (never cached). Cached per
# (msg, order) for the run in the files of OO_VCACHE (callers run it in a
# subshell, so a variable would not keep it): one hub read per message.
_spl_oo_go_verdict() {
  local f="${OO_VCACHE:-}/${2//[^0-9a-f-]/_}.${3//[^0-9a-f-]/_}.${4:-go}" v rc
  if [[ -n "${OO_VCACHE:-}" && -s "$f" ]]; then
    v="$(cat "$f")"; echo "${v#?}"; return "${v:0:1}"
  fi
  v="$(_spl_oo_go_check "$@")"; rc=$?
  [[ -n "${OO_VCACHE:-}" && "$rc" != 2 ]] && printf '%s%s' "$rc" "$v" >"$f"
  echo "$v"; return "$rc"
}

_spl_oo_go_check() {  # <hub> <msg> <order uuid> <go|lift>
  [[ "$2" =~ $SPL_OO_UUID_RX ]] || { echo "not a full message uuid"; return 1; }
  [[ "$2" != "$3" ]] || { echo "the order's own id is not a go"; return 1; }
  [[ "$1" != none ]] || { echo "form only, NOT hub-checked: no hub on this box"; return 0; }
  _spl_oo_names_order "$@"
}

# _spl_oo_names_order <hub> <msg> <order uuid> [go|lift]: rc 0 when the hub
# holds <msg>, from an owner (HUM-<n>), and its body carries the marker
# (_spl_oo_marker) for the order (N1: an owner message about something else
# neither lifts nor passes the order; N3: nor does one that only mentions it);
# 1 it does not (the reason on stdout), 2 the hub read failed.
_spl_oo_names_order() {
  local hub="$1" m="$2" o="$3" kind="${4:-go}" row from body
  row="$(_spl_oo_hub "$hub" "$m" 2>&1)" || { echo "${row##*$'\n'}"; return 2; }
  [[ -n "$row" ]] || { echo "message ${m:0:8} is not on the $hub hub"; return 1; }
  IFS=$'\t' read -r from _ _ body <<<"$row"
  [[ "$from" =~ ^HUM-[0-9]+$ ]] || { echo "message ${m:0:8} is from '$from', not an owner (HUM-<n>)"; return 1; }
  body="$(base64 -d <<<"$body" 2>/dev/null)" || { echo "the hub body of ${m:0:8} did not decode"; return 1; }
  _spl_oo_marker "$body" "${o:0:8}" "$kind" ||
    { echo "owner message ${m:0:8} does not name the order's id8 ${o:0:8} as a $kind (a whole-word '$kind ${o:0:8}', not negated)"; return 1; }
  echo "hub-checked on $hub: from $from, names ${o:0:8} as a $kind"
}

# _spl_oo_marker <body> <id8> <go|lift>: rc 0 when the body says "<verb>
# <id8>" as whole words, case-insensitive: verb "lift" (a lift), "go" or
# "lift" (a go); "for", "order" or ":" may stand between. A match preceded
# by not / no / never / don't does not count (N3: "do not go <id8>").
_spl_oo_marker() {
  local verbs=lift neg="(not|no|never|don'?t)" m
  [[ "$3" == go ]] && verbs="go|lift"
  m="$(tr '[:upper:]' '[:lower:]' <<<"$1" | grep -oE "(^|[^a-z0-9_'])(${neg}[[:space:]]+)?($verbs)([[:space:]]*:[[:space:]]*|[[:space:]]+(for[[:space:]]+|order[[:space:]]+)?)${2}([^a-z0-9_]|\$)")" || return 1
  grep -vqE "(^|[^a-z0-9_'])${neg}[[:space:]]+($verbs)" <<<"$m"
}
