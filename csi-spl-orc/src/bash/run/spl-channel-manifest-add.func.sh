#!/bin/bash
#------------------------------------------------------------------------------
# @description A seat declares one line of its channel's move manifest (spec
# @description 167 4.2, row B1): a file it wrote outside its worktree (data,
# @description config, binary with an optional build command, secret), a
# @description marker word only this channel's files hold, or a suite it did
# @description not run on its last tree (tests-not-run). The manifest is
# @description box-local, never in git: $SPOOL_ROOT/channel-move/<tenant>-<channel>.manifest,
# @description 0600 in a 0700 dir. A path outside the allowed roots (/opt/<org>,
# @description /var/tmp, /tmp, $SPOOL_ROOT, the agent and box user homes) is
# @description refused; a line already there is not added twice.
# @param CHANNEL (required) - <tenant>/<channel>
# @param MANIFEST_KIND (required) - data, config, binary, secret, marker or tests-not-run
# @param MANIFEST_VALUE (required) - the absolute path; the word (marker); the suite command (tests-not-run)
# @param MANIFEST_BUILD (optional) - binary only: the command that rebuilds it on the target
# @example CHANNEL=t1/general MANIFEST_KIND=data MANIFEST_VALUE=/var/tmp/c-123/report.csv ./run -a do_spl_channel_manifest_add
# @example CHANNEL=t1/general MANIFEST_KIND=tests-not-run MANIFEST_VALUE='bash src/bash/tests/run-all-tests.sh' ./run -a do_spl_channel_manifest_add
#------------------------------------------------------------------------------

# The line to append, or 2 + one line on stderr.
cm_manifest_line() {  # KIND VALUE BUILD
  local kind="$1" v="$2" b="$3"
  [[ " $CM_KINDS_DECLARED " == *" $kind "* ]] ||
    { echo "manifest-add: MANIFEST_KIND must be one of: $CM_KINDS_DECLARED; got '$kind'" >&2; return 2; }
  [[ -n "${v//[[:space:]]/}" && "$v$b" != *$'\n'* && "$v$b" != *$'\t'* && ${#v} -le 1024 && ${#b} -le 1024 ]] ||
    { echo "manifest-add: MANIFEST_VALUE must be one line, no tab, 1..1024 chars" >&2; return 2; }
  case "$kind" in
    marker)
      [[ "$v" =~ ^[A-Za-z0-9._-]{3,64}$ ]] || { echo "manifest-add: a marker is one word of 3..64 [A-Za-z0-9._-]" >&2; return 2; }
      echo "marker $v" ;;
    tests-not-run) echo "tests-not-run $v" ;;
    *)
      [[ "$v" == /* && "$v" != *' '* ]] || { echo "manifest-add: MANIFEST_VALUE must be an absolute path with no space, got '$v'" >&2; return 2; }
      cm_allowed_path "$v" || { echo "manifest-add: REFUSED $v is outside the allowed roots (spec 167 4.2)" >&2; return 2; }
      [ -z "$b" ] || [ "$kind" = binary ] || { echo "manifest-add: MANIFEST_BUILD is for a binary line only" >&2; return 2; }
      echo "$kind $(realpath -m -- "$v")${b:+ $b}" ;;
  esac
}

do_spl_channel_manifest_add() {
  local sa line m
  sa="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents"
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  declare -F spool_env_resolve >/dev/null || . "$sa/lib/spool-env.inc.sh" || return 1
  # shellcheck source=../features/spawn-agents/lib/channel-move.inc.sh
  declare -F cm_manifest_path >/dev/null || . "$sa/lib/channel-move.inc.sh" || return 1
  SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null || return 1
  cm_parse_channel "${CHANNEL:-}" || return 2
  line="$(cm_manifest_line "${MANIFEST_KIND:-}" "${MANIFEST_VALUE:-}" "${MANIFEST_BUILD:-}")" || return 2
  m="$(cm_manifest_path "$CM_TENANT" "$CM_CHANNEL")"
  (
    umask 077
    mkdir -p "$(dirname "$m")" && exec 9>>"$m.lock" || exit 1
    flock -w 10 9 || { echo "manifest-add: the manifest is locked" >&2; exit 1; }
    if [ -f "$m" ] && grep -qxF -- "$line" "$m"; then echo "OK manifest-add: already declared"; exit 0; fi
    printf '%s\n' "$line" >>"$m" && chmod 0600 "$m" || exit 1
    [ "${line%% *}" = secret ] && line="secret (path withheld)"
    echo "OK manifest-add $CM_TENANT/$CM_CHANNEL: $line"
  )
}
