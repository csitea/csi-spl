#!/bin/bash
#------------------------------------------------------------------------------
# @description Pack this box's box-only state into ONE tar.zst and upload it to
# @description the env's box state bucket (iac 056, owner t1 d80ed72c: a nightly
# @description copy, 30-day retention, restored on a new box by
# @description do_spl_box_state_restore).
# @description
# @description What goes in (BOX_STATE_SOURCES overrides the list):
# @description   - the agent user's ~/.claude/projects (transcripts + memory)
# @description   - the spool root ($SPOOL_ROOT, default /var/spool-hub)
# @description   - the csi-spl state dirs: /var/csi/csi-spl (less graft/, a
# @description     rebuilt index, and backups/, the DB dumps that have their
# @description     own buckets 045/046) and $HOME/.local/state/csi-spl
# @description What never goes in: ~/.gcp, ~/.ssh, key files, tokens, .env
# @description files, the tenants store, NetVisor / bank credential files and
# @description any 0600 file under a home's dot-dirs not on the allow-list
# @description (owner rule csitea fc0119cd msg 072a9990: keys and secrets stay
# @description on the box); box-state-pack.sh holds the one list. After the pack a scan of the archive REFUSES the upload
# @description (exit 3) if any member name is excluded or any member holds key
# @description material: the scan, not the pack's filter, is the verdict.
# @description
# @description Each source is read as its OWNER (sudo -n -u <owner> when that
# @description is another user): the agent user's transcript dirs are 0700.
# @description The object: <box>/<YYYY-MM-DD>/<box>-<YYYYMMDDTHHMMSSZ>.tar.zst.
# @description The upload runs as the env's project SA impersonating the
# @description write-only box writer SA (056: objectCreator only, no key).
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): pack and scan, upload nothing
# @param BOX (optional) - the box name; default SPOOL_BOX_TAG, BOX_TAG,
# @param   SPOOL_BOX_TAG in $SPOOL_ROOT/box.env, else hostname -s
# @param BOX_STATE_SOURCES (optional) - space-separated dirs to pack
# @param BOX_STATE_SKIP (optional) - space-separated absolute paths left out
# @param BOX_STATE_HOMES (optional) - home dirs (globs allowed) for the 0600 rule;
# @param   default the getent passwd homes of this user, the agent user and root
# @param BOX_STATE_ALLOW_0600 (optional) - path globs of 0600 files that may go,
# @param   default "*/.claude/projects/*" (the transcripts, key-filtered)
# @param BOX_STATE_KEEP (optional) - a path: keep the archive there (tests, drills)
# @example ENV=prd ./run -a do_spl_box_state_backup
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_box_state_backup
#------------------------------------------------------------------------------
do_spl_box_state_backup() {
  spl_require_cloud_env || return 1
  local dry=1 drc
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_require_bin tar find || return 1
  spl_box_state_tools zstd || return 1

  local box stamp day obj work arch size rc=0
  box="$(spl_box_state_box)" || return 1
  stamp="${BOX_STATE_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { do_log "FATAL BOX_STATE_STAMP must be YYYYMMDDTHHMMSSZ, got: '$stamp'"; return 1; }
  day="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}"
  obj="$(spl_box_state_object "$box" "$stamp")"

  do_spl_cloud_cnf || return 1
  local bucket writer
  bucket="$(spl_box_state_cnf state_bucket_name)" || return 1
  writer="$(spl_box_state_cnf writer_sa_account_id)" || return 1
  writer="$writer@$SPL_PROJECT.iam.gserviceaccount.com"

  # the 0600 rule's homes, for the pack and the scan alike: the passwd homes
  # of this user, the agent user and root (a satellite keeps them under
  # /mnt/data/home, so no /home/* guess)
  BOX_STATE_HOMES="${BOX_STATE_HOMES:-$(spl_box_state_homes)}"
  export BOX_STATE_HOMES
  work="$(umask 077 && mktemp -d)" || return 1
  arch="$work/${obj##*/}"
  spl_box_state_pack "$arch" "$work" || { rm -rf "$work"; return 1; }
  if ! spl_box_state_scan "$arch"; then
    rm -rf "$work"
    do_log "FATAL $ENV: the archive holds an excluded path or key material (HIT lines above): upload REFUSED, nothing left this box"
    return 3
  fi
  size="$(stat -c %s "$arch")"
  [[ -z "${BOX_STATE_KEEP:-}" ]] || install -m 600 "$arch" "$BOX_STATE_KEEP" || { rm -rf "$work"; return 1; }

  if (( dry )); then
    do_log "OK $ENV DRY_RUN: $box state packed and scanned clean ($size bytes, $day); would upload gs://$bucket/$obj as $writer. DRY_RUN=0 uploads it."
    rm -rf "$work"; return 0
  fi
  do_require_bin gcloud curl jq python3 || { rm -rf "$work"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || { rm -rf "$work"; return 1; }
  do_gcp_require_live_account "$GCP_ACCOUNT" || { rm -rf "$work"; return 1; }
  spl_box_state_put "$arch" "$bucket" "$obj" "$writer" "$size" "$work" || rc=$?
  rm -rf "$work"
  (( rc == 0 )) || return 1
  do_log "OK $ENV: $box state -> gs://$bucket/$obj ($size bytes)"
}

# spl_box_state_put <file> <bucket> <object> <writer SA> <size> <work dir>
# -> one upload AS THE WRITER through the JSON API, create-only
# (ifGenerationMatch=0). Not `gcloud storage cp`: it also GETs the object,
# and the writer holds objectCreator only (403 on storage.objects.get,
# measured 2026-10-10 on the first prd run). The size GCS reports is the
# verdict. The token is the writer's, about an hour, and goes to curl in a
# 0600 header file in the work dir: never on a command line or in a log.
spl_box_state_put() {
  local f="$1" bucket="$2" obj="$3" writer="$4" size="$5" work="$6" tok name got
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" --impersonate-service-account="$writer" 2>"$work/tok.err")"
  [[ -n "$tok" ]] || { do_log "FATAL $ENV: no token as $writer: $(tail -n 1 "$work/tok.err")"; return 1; }
  ( umask 077 && printf 'Authorization: Bearer %s\n' "$tok" >"$work/auth.h" ) || return 1
  tok=""
  name="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$obj")"
  curl -sS --fail-with-body -X POST -H @"$work/auth.h" -H 'Content-Type: application/zstd' -T "$f" \
    -o "$work/put.json" "https://storage.googleapis.com/upload/storage/v1/b/$bucket/o?uploadType=media&ifGenerationMatch=0&name=$name" 2>"$work/put.err" ||
    { do_log "FATAL $ENV: cannot upload gs://$bucket/$obj as $writer: $(tail -n 2 "$work/put.err" | tr '\n' ' ') $(jq -r '.error.message // empty' "$work/put.json" 2>/dev/null)"; return 1; }
  got="$(jq -r '.size // ""' "$work/put.json" 2>/dev/null)"
  [[ "$got" == "$size" ]] || { do_log "FATAL $ENV: gs://$bucket/$obj reports size '${got:-none}', the archive is $size bytes"; return 1; }
}

# spl_box_state_object <box> <stamp> -> the object name; the restore picks by
# its <box>/<YYYY-MM-DD>/ prefix
spl_box_state_object() {
  local box="$1" stamp="$2"
  printf '%s/%s-%s-%s/%s-%s.tar.zst' "$box" "${stamp:0:4}" "${stamp:4:2}" "${stamp:6:2}" "$box" "$stamp"
}

# spl_box_state_box -> this box's name: BOX, SPOOL_BOX_TAG, BOX_TAG, box.env,
# hostname -s; refused unless [a-z0-9][a-z0-9-]*
spl_box_state_box() {
  local b="${BOX:-${SPOOL_BOX_TAG:-${BOX_TAG:-}}}"
  [[ -n "$b" ]] || b="$(sed -n 's/^SPOOL_BOX_TAG=//p' "${SPOOL_ROOT:-/var/spool-hub}/box.env" 2>/dev/null | sed -n 1p)"
  [[ -n "$b" ]] || b="$(hostname -s 2>/dev/null)"
  b="${b,,}"
  [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { do_log "FATAL BOX must be [a-z0-9][a-z0-9-]* (<= 40 chars), got: '$b'" >&2; return 1; }
  printf '%s' "$b"
}

# spl_box_state_cnf <key> -> env.steps."056-gcs-box-state".<key> of $SPL_CNF,
# or a refusal: never a guessed name
spl_box_state_cnf() {
  local v
  v="$(yq -r ".env.steps.\"056-gcs-box-state\".$1 // \"\"" "$SPL_CNF")"
  [[ -n "$v" && "$v" != null ]] || { do_log "FATAL cnf env.steps.\"056-gcs-box-state\".$1 is empty for $ENV" >&2; return 1; }
  printf '%s' "$v"
}

# spl_box_state_agent -> the agent user: SPOOL_AGENT_USER, else box.env
spl_box_state_agent() {
  printf '%s' "${SPOOL_AGENT_USER:-$(sed -n 's/^SPOOL_AGENT_USER=//p' "${SPOOL_ROOT:-/var/spool-hub}/box.env" 2>/dev/null | sed -n 1p)}"
}

# spl_box_state_homes -> the passwd home dirs of this user, the agent user and
# root, space-separated, each once
spl_box_state_homes() {
  local u h out=""
  for u in "$(id -un)" "$(spl_box_state_agent)" root; do
    [[ -n "$u" ]] || continue
    h="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$h" && " $out " != *" $h "* ]] && out+="${out:+ }$h"
  done
  printf '%s' "$out"
}

# spl_box_state_sources -> one "<dir><TAB><user to read it as, or empty>" per
# line: BOX_STATE_SOURCES (no user), else the defaults
spl_box_state_sources() {
  if [[ -n "${BOX_STATE_SOURCES:-}" ]]; then tr ' ' '\n' <<<"$BOX_STATE_SOURCES" | sed '/^$/d; s/$/\t/'; return 0; fi
  local agent home
  agent="$(spl_box_state_agent)"
  [[ -n "$agent" ]] && home="$(getent passwd "$agent" | cut -d: -f6)"
  [[ -n "${home:-}" ]] && printf '%s\t%s\n' "$home/.claude/projects" "$agent"
  printf '%s\t\n' "${SPOOL_ROOT:-/var/spool-hub}" "${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}" "$HOME/.local/state/csi-spl"
}

# spl_box_state_hidden <path> -> 0 when <path> may exist but this user cannot
# see it: its nearest existing ancestor is not readable and searchable. 1 when
# it is simply not there.
spl_box_state_hidden() {
  local p="$1"
  while [[ ! -e "$p" && "$p" != / ]]; do p="$(dirname "$p")"; done
  [[ "$p" != "$1" && ! ( -r "$p" && -x "$p" ) ]]
}

# spl_box_state_reader <dir> <hint user> -> the user to pack <dir> as, or 1
# with a FATAL: a source no one we can be can read never packs as empty
spl_box_state_reader() {
  local src="$1" hint="$2" me owner
  me="$(id -un)"
  if [[ -d "$src" && -r "$src" && -x "$src" ]]; then
    owner="$(stat -c %U "$src")"
    [[ "$owner" == "$me" ]] && { printf '%s' "$me"; return 0; }
    sudo -n -u "$owner" true 2>/dev/null && { printf '%s' "$owner"; return 0; }
    do_log "WARN $src belongs to $owner and sudo -n -u $owner is refused: packed as $me (its unreadable files are dropped)" >&2
    printf '%s' "$me"; return 0
  fi
  if [[ -n "$hint" && "$hint" != "$me" ]] && sudo -n -u "$hint" test -d "$src" 2>/dev/null; then
    sudo -n -u "$hint" test -r "$src" -a -x "$src" && { printf '%s' "$hint"; return 0; }
  fi
  if [[ -d "$src" ]] || spl_box_state_hidden "$src"; then
    do_log "FATAL $src is unreadable as $me${hint:+ and as $hint (sudo -n -u $hint)}: refusing a backup without it" >&2
    return 2
  fi
  return 1
}

# spl_box_state_pack <archive> <work dir> -> one tar.zst of every existing
# source, each read as its owner; the DROP lines are counted, not printed
# one by one (a name can say more than it should)
spl_box_state_pack() {
  local arch="$1" work="$2" pack src hint owner me i=0 n drops skip rrc unreadable=0
  pack="$PROJ_PATH/src/bash/scripts/box-state-pack.sh"
  me="$(id -un)"
  skip="${BOX_STATE_SKIP-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/graft ${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/backups}"
  local -a skips=()
  read -r -a skips <<<"$skip"
  : >"$work/all.tar"
  while IFS=$'\t' read -r src hint; do
    owner="$(spl_box_state_reader "$src" "$hint")"; rrc=$?
    if (( rrc == 1 )); then do_log "INFO $src is not on this box: skipped"; continue; fi
    if (( rrc )); then unreadable=$((unreadable + 1)); continue; fi
    i=$((i + 1))
    if [[ "$owner" == "$me" ]]; then
      bash "$pack" tar "$src" "${skips[@]}" >"$work/part$i.tar" 2>"$work/drop$i"
    else
      # shellcheck disable=SC2024 # the redirect is OURS on purpose: the owner reads, this user writes the part
      sudo -n -u "$owner" env BOX_STATE_HOMES="${BOX_STATE_HOMES:-}" \
        BOX_STATE_ALLOW_0600="${BOX_STATE_ALLOW_0600:-*/.claude/projects/*}" bash "$pack" tar "$src" "${skips[@]}" >"$work/part$i.tar" 2>"$work/drop$i"
    fi
    [[ -s "$work/part$i.tar" ]] || { do_log "INFO $src: nothing to pack"; continue; }
    if [[ -s "$work/all.tar" ]]; then
      tar -Af "$work/all.tar" "$work/part$i.tar" || { do_log "FATAL cannot append $src to the archive"; return 1; }
      rm -f "$work/part$i.tar"
    else
      mv -f "$work/part$i.tar" "$work/all.tar"
    fi
    n="$(tar -tf "$work/all.tar" 2>/dev/null | wc -l)"
    drops="$(awk '{print $NF}' "$work/drop$i" | sort | uniq -c | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')"
    do_log "INFO packed $src as $owner (archive now $n entries)${drops:+; dropped: $drops}"
  done < <(spl_box_state_sources)
  (( unreadable == 0 )) || { do_log "FATAL $unreadable source(s) unreadable (above): nothing packed is uploaded"; return 1; }
  [[ -s "$work/all.tar" ]] || { do_log "FATAL nothing to pack: no source dir exists on this box"; return 1; }
  zstd -q -T0 -10 -o "$arch" "$work/all.tar" || { do_log "FATAL zstd failed"; return 1; }
  rm -f "$work/all.tar"
}

# spl_box_state_scan <archive> -> 0 clean; else the HIT lines and 1
spl_box_state_scan() {
  local out rc=0
  out="$(bash "$PROJ_PATH/src/bash/scripts/box-state-pack.sh" scan "$1")" || rc=$?
  (( rc == 0 )) && return 0
  [[ -n "$out" ]] && sed -n '1,20s/^/  /p' <<<"$out"
  return 1
}

# spl_box_state_tools <bin>... -> refuses, naming each missing one. Not
# do_require_bin: that list is what the satellite's verify must install, and
# these two join it when the satellite runs the backup (its own lane).
spl_box_state_tools() {
  local b miss=""
  for b in "$@"; do command -v "$b" >/dev/null 2>&1 || miss+=" $b"; done
  [[ -z "$miss" ]] || { do_log "FATAL missing tool(s):$miss"; return 1; }
}
