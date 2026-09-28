#!/bin/bash
#------------------------------------------------------------------------------
# @description Publish the PUBLIC product repo from the private ops repo (spec
# @description 044, SPL-61, CLE-35070). The public master is, commit by commit,
# @description the do_oss_export projection of ops master: the export
# @description allow-list, the export scrub, and do_oss_gate at 0. Nothing
# @description reaches the public repo without passing the gate.
# @description   1. clone the public master (blobless) into a scratch dir
# @description   2. its newest commit carrying an `Ops-Commit: <sha>` trailer
# @description      is where the last run stopped. The FIRST run has none: the
# @description      public master must then BE OSS_MIRROR_BASE (the shared
# @description      history of both repos), and that commit is projected first
# @description      - which removes every non-product path from public HEAD
# @description   3. for each first-parent ops commit after it, up to OSS_REF:
# @description        - no allow-listed path (nor the oss cnf) changed -> skip
# @description        - else export it with the allow-list + scrub AS OF that
# @description          commit, gate it, and commit the tree on the public
# @description          branch with the ops author, the ops message run through
# @description          oss-redact.py (the gate's literal rules), and the
# @description          trailer Ops-Commit: <ops sha>
# @description        - a commit the gate FAILS is never published: it is
# @description          folded into the next commit that passes (its message
# @description          says so), so a leak and its fix go public only as the
# @description          fixed tree
# @description   4. push the new public master, fast-forward only
# @description Exit 0 = published (or nothing to publish). 1 = the newest
# @description commits fail the gate (the ones before them were still pushed),
# @description or the public master carries a commit that did not come from the
# @description mirror (bring it into ops first; never overwritten). 2 = cannot
# @description measure. Dry run unless DRY_RUN=0: everything but the push.
# @param OSS_MIRROR_URL - required: the public repo's git URL (no default)
# @param OSS_REF (optional) - the ops commit to publish up to, default origin/master
# @param OSS_MIRROR_BASE (optional) - required on the FIRST run only: the ops
# @param   commit the public master currently is
# @param OSS_MIRROR_WORK (optional) - scratch dir, default a new mktemp dir
# @param DRY_RUN (optional) - 1 (default) or 0
# @example OSS_MIRROR_URL=git@github.com:<owner>/<app>.git ./run -a do_oss_mirror
# @example OSS_MIRROR_URL=<url> OSS_MIRROR_BASE=<sha> DRY_RUN=0 ./run -a do_oss_mirror
#------------------------------------------------------------------------------

OSS_MIRROR_TRAILER="Ops-Commit"

# oss_mirror_entries <allow-list file> - the raw allow-list paths, one per line
oss_mirror_entries() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"; line="${line#\?}"; line="${line%/}"
    [[ -n "$line" ]] && echo "$line"
  done <"$1"
}

# oss_mirror_relevant <repo> <commit> <allow-list file> <oss cnf dir rel> - 0
# when the commit's first-parent diff touches an allow-listed path or the oss
# cnf (the allow-list, scrub, rules or assets list decide the projection too)
oss_mirror_relevant() {
  local repo="$1" c="$2" list="$3" cnfrel="$4" p e
  local -a entries; mapfile -t entries < <(oss_mirror_entries "$list")
  while IFS= read -r p; do
    [[ "$p" == "$cnfrel"/* ]] && return 0
    for e in "${entries[@]}"; do [[ "$p" == "$e" || "$p" == "$e"/* ]] && return 0; done
  done < <(git -C "$repo" diff --name-only "$c^1" "$c" 2>/dev/null)
  return 1
}

do_oss_mirror() {
  do_require_bin git python3 || return 2
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 2; dry=0; fi
  local url="${OSS_MIRROR_URL:-}" ref="${OSS_REF:-origin/master}" repo orc cnfrel
  [[ -n "$url" ]] || { do_log "FATAL OSS_MIRROR_URL must name the public repo (no default)"; return 2; }
  repo=$(cd "$APP_PATH" && pwd); orc="${PROJ_PATH:-$APP_PATH/csi-spl-orc}"
  cnfrel="$(basename "$orc")/cnf/oss"
  local head; head=$(git -C "$repo" rev-parse --verify -q "$ref^{commit}") \
    || { do_log "FATAL OSS_REF '$ref' is not a commit"; return 2; }
  local work="${OSS_MIRROR_WORK:-}"; [[ -n "$work" ]] || work="$(mktemp -d)"
  mkdir -p "$work" && rm -rf "${work:?}/pub" "$work/tree" "$work/cnf"; mkdir -p "$work/cnf"
  git clone -q --filter=blob:none --no-checkout --single-branch --branch master "$url" "$work/pub" \
    || { do_log "FATAL cannot clone the public master from $url"; return 2; }
  local pub="$work/pub" start tip last base first=0
  start=$(git -C "$pub" rev-parse HEAD); tip="$start"

  # 2. where the last run stopped
  last=$(git -C "$pub" log --format="%H %(trailers:key=$OSS_MIRROR_TRAILER,valueonly,separator=)" HEAD | awk 'NF==2{print; exit}')
  if [[ -n "$last" ]]; then
    [[ "${last%% *}" == "$start" ]] || {
      do_log "FATAL the public master ${start:0:8} carries commit(s) after the last mirrored one ${last:0:8} that did not come from the mirror (a direct push or a merged PR): bring them into ops first - the mirror never overwrites them"
      return 1; }
    base="${last#* }"
    git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null \
      || { do_log "FATAL the last mirrored ops commit $base is not in this checkout (fetch the full ops history)"; return 2; }
  else
    base="${OSS_MIRROR_BASE:-}"
    [[ -n "$base" ]] || { do_log "FATAL the public master has no $OSS_MIRROR_TRAILER trailer yet: set OSS_MIRROR_BASE to the ops commit it currently is (the first run)"; return 2; }
    base=$(git -C "$repo" rev-parse --verify -q "$base^{commit}") || { do_log "FATAL OSS_MIRROR_BASE is not a commit"; return 2; }
    [[ "$base" == "$start" ]] \
      || { do_log "FATAL first run: the public master is ${start:0:8}, not OSS_MIRROR_BASE ${base:0:8} - the two repos must share that commit"; return 1; }
    first=1
  fi
  git -C "$repo" merge-base --is-ancestor "$base" "$head" \
    || { do_log "FATAL ${base:0:8} is not an ancestor of $ref (${head:0:8})"; return 2; }

  # the gate's literal rules + cnf values, for the message redaction
  local rules="$orc/cnf/oss/banned-literals.tsv" cnf="$APP_PATH/csi-spl-cnf/csi-spl/all.env.yaml"
  local cnfvars="$work/cnf/vars.json" redact=(python3 "$orc/src/bash/scripts/oss-redact.py" --rules "$rules")
  if oss_gate_cnf_vars "$rules" "$cnf" "$cnfvars" 2>/dev/null; then redact+=(--cnf-vars "$cnfvars"); fi

  local -a todo; mapfile -t todo < <(git -C "$repo" rev-list --reverse --first-parent "$base..$head")
  ((first)) && todo=("$base" "${todo[@]}")
  local c n=0 skipped=0 published=0 rc folded=() list scrub
  for c in "${todo[@]}"; do
    [[ -n "$c" ]] || continue
    list="$work/cnf/allow.$c"; scrub="$work/cnf/scrub.$c"
    git -C "$repo" show "$c:$cnfrel/export-allow-list.txt" >"$list" 2>/dev/null \
      || { do_log "FATAL ${c:0:8} has no $cnfrel/export-allow-list.txt"; return 2; }
    git -C "$repo" show "$c:$cnfrel/export-scrub.tsv" >"$scrub" 2>/dev/null || : >"$scrub"
    if ! ((first)) && ((${#folded[@]} == 0)) && ! oss_mirror_relevant "$repo" "$c" "$list" "$cnfrel"; then
      skipped=$((skipped + 1)); continue
    fi
    first=0; n=$((n + 1))
    rm -rf "$work/tree" "$work/tree.oss-gate-report.tsv"
    rc=0
    # npm licences come from THIS checkout's node_modules, which match only
    # its own lockfile: an older commit of the batch is measured against it
    # (a licence is not a leak), the newest one exactly
    local nm=""
    [[ "$c" != "$head" && -d "$repo/csi-spl-wui/node_modules" ]] && nm="$repo/csi-spl-wui/node_modules"
    OUT_DIR="$work/tree" OSS_REF="$c" OSS_ALLOW_LIST="$list" OSS_EXPORT_SCRUB="$scrub" OSS_GATE_NODE_MODULES="$nm" \
      do_oss_export >"$work/gate.log" 2>&1 || rc=$?
    if ((rc == 1)); then
      do_log "WARN ${c:0:8} FAILS the gate ($(grep -E '^TOTAL' "$work/gate.log" | tr '\t' ' ')): NOT published, folded into the next commit that passes (report: $work/tree.oss-gate-report.tsv)"
      cp -f "$work/tree.oss-gate-report.tsv" "$work/gate-fail.${c:0:12}.tsv" 2>/dev/null
      folded+=("$c"); continue
    elif ((rc != 0)); then
      do_log "FATAL the export/gate of ${c:0:8} could not measure (rc=$rc): $(tail -3 "$work/gate.log" | tr '\n' ' ')"
      break
    fi
    # the projected tree as a git tree object in the public clone
    local idx="$work/index" t msg
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" GIT_WORK_TREE="$work/tree" git -C "$pub" add -A -f . \
      && t=$(GIT_INDEX_FILE="$idx" git -C "$pub" write-tree) || { do_log "FATAL cannot write the tree of ${c:0:8}"; rc=2; break; }
    if [[ "$t" == "$(git -C "$pub" rev-parse "$tip^{tree}")" ]] && ((${#folded[@]} == 0)); then
      skipped=$((skipped + 1)); continue
    fi
    msg="$work/msg"
    {
      if [[ "$c" == "$base" && "$tip" == "$start" && -z "$last" ]]; then
        printf 'chore(oss): the public tree is the product only\n\nFrom here on this repository is the projection of the private ops\nrepository onto the open-source allow-list, published commit by commit\nand only when the OSS gate reads 0. Configuration, infrastructure,\noperations tooling and the internal docs live in the private repository.\n'
      else
        git -C "$repo" log -1 --format=%B "$c" | "${redact[@]}" 2>/dev/null
      fi
      if ((${#folded[@]})); then
        printf '\nThis commit also carries %d earlier commit(s) that did not pass the\nOSS gate on their own and were never published separately.\n' "${#folded[@]}"
      fi
      printf '\n%s: %s\n' "$OSS_MIRROR_TRAILER" "$c"
    } >"$msg"
    local an ae ad cn ce
    IFS=$'\t' read -r an ae ad cn ce < <(git -C "$repo" log -1 --format=$'%an\t%ae\t%aI\t%cn\t%ce' "$c")
    tip=$(GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
          GIT_COMMITTER_NAME="$cn" GIT_COMMITTER_EMAIL="$ce" \
          git -C "$pub" commit-tree "$t" -p "$tip" -F "$msg") || { do_log "FATAL commit-tree failed for ${c:0:8}"; rc=2; break; }
    published=$((published + 1)); folded=()
    do_log "INFO ${c:0:8} -> public ${tip:0:8}"
  done
  ((rc == 0 || rc == 1)) || rc=2

  if [[ "$tip" != "$start" ]]; then
    if ((dry)); then
      do_log "INFO DRY_RUN would push $published commit(s) to the public master (${start:0:8} -> ${tip:0:8}): $(git -C "$pub" log --format=%s -n "$published" "$tip" | head -3 | tr '\n' '|')"
    else
      git -C "$pub" push -q origin "$tip:refs/heads/master" \
        || { do_log "FATAL the public master refused ${tip:0:8} (it moved: a direct push?) - nothing was overwritten"; return 1; }
      do_log "OK pushed $published commit(s) to the public master: ${start:0:8} -> ${tip:0:8}"
    fi
  fi
  do_log "INFO examined ${#todo[@]} ops commit(s) ${base:0:8}..${head:0:8}: $n projected, $published published, $skipped without product change"
  if ((${#folded[@]})); then
    do_log "FATAL ${#folded[@]} newest ops commit(s) fail the OSS gate and wait unpublished (first: ${folded[0]:0:8}; reports: $work/gate-fail.*.tsv)"
    return 1
  fi
  ((rc == 2)) && return 2
  do_log "OK the public master carries ops ${head:0:8}$( ((dry)) && echo ' (DRY_RUN: not pushed)')"
  return 0
}
