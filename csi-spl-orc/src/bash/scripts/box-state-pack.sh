#!/usr/bin/env bash
# box-state-pack.sh - the packing and the key scan of the nightly box state
# backup (do_spl_box_state_backup, owner t1 d80ed72c). The excludes and the
# key patterns live HERE only, so the pack and the scan cannot drift apart.
#
#   box-state-pack.sh tar <src dir> [<skip path>...]
#       a tar stream of <src dir> on stdout, member names absolute minus the
#       leading / (tar's own). On stderr one `DROP <path> <reason>` line per
#       file left out. Left out:
#         path   any .gcp / .ssh / .nano-banana* component, .github/token,
#                .spool-hub/tenants, a file named .env, *.pem *.key *.p12,
#                key-*.json, and every <skip path> (absolute)
#         key    a file holding key or token MATERIAL ($BOX_STATE_KEY_RE):
#                a PEM private key, a root_private_key / private_key_id value,
#                a GitHub, Slack, Anthropic or Google API token. A word such
#                as "private_key" in a transcript is not material.
#       A file this user cannot read is a `DROP <path> unreadable`.
#   box-state-pack.sh scan <archive.tar.zst>
#       exit 0: no member name is excluded and no member holds key material;
#       exit 3: `HIT <member> name|key` per offending member (the member's
#       NAME only: the content is never printed); exit 2: usage or a broken
#       archive.
#   box-state-pack.sh key-re
#       prints the key pattern (the tests plant material against it).
#
# Run by the action as the OWNER of each source dir (sudo -n -u <owner> when
# that is another user), so an agent user's 0700 transcript dirs are read by
# that user and the stream comes back over the pipe.
set -uo pipefail
export LC_ALL=C

# shellcheck disable=SC2089,SC2090 # a grep -E pattern: its quotes and backslashes ARE literal
BOX_STATE_KEY_RE='-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----|root_private_key[\\"]*[[:space:]]*[:=][[:space:]]*[\\"]*[A-Za-z0-9+/_=-]{32,}|private_key_id[\\"]*[[:space:]]*:[[:space:]]*[\\"]*[0-9a-f]{40}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,}|xox[abprs]-[0-9]+-[0-9A-Za-z-]{20,}|sk-ant-[A-Za-z0-9_-]{32,}|AIza[0-9A-Za-z_-]{35}'
# A member name (no leading /) that must never be in the archive.
BOX_STATE_NAME_RE='(^|/)(\.gcp|\.ssh)(/|$)|(^|/)\.nano-banana[^/]*(/|$)|(^|/)\.github/token$|(^|/)\.spool-hub/tenants(/|$)|(^|/)\.env$|\.(pem|key|p12)$|(^|/)key-[^/]*\.json$'
# shellcheck disable=SC2090
export BOX_STATE_KEY_RE BOX_STATE_NAME_RE

usage() { echo "usage: box-state-pack.sh tar <src dir> [<skip path>...] | scan <archive.tar.zst> | key-re" >&2; exit 2; }

# pack_list <src> <skip...> -> NUL-separated readable files, path-filtered; DROP lines on stderr
pack_list() {
  local src="$1" f rel s
  shift
  local -a skips=("$@")
  while IFS= read -r -d '' f; do
    rel="${f#/}"
    for s in "${skips[@]}"; do
      [[ -n "$s" && ( "$f" == "$s" || "$f" == "$s"/* ) ]] && continue 2
    done
    if [[ "$rel" =~ $BOX_STATE_NAME_RE ]]; then echo "DROP $f path" >&2; continue; fi
    [[ -r "$f" ]] || { echo "DROP $f unreadable" >&2; continue; }
    printf '%s\0' "$f"
  done < <(find "$src" \( -type f -o -type l \) -print0 2>/dev/null)
}

# key_filter -> stdin NUL list minus the files holding key material; DROP lines on stderr
key_filter() {
  local all hits f
  all="$(mktemp)" hits="$(mktemp)"
  cat >"$all"
  if [[ -s "$all" ]]; then
    xargs -0 -r grep -lZaE -e "$BOX_STATE_KEY_RE" -- <"$all" >"$hits" 2>/dev/null
  fi
  if [[ -s "$hits" ]]; then
    while IFS= read -r -d '' f; do echo "DROP $f key" >&2; done <"$hits"
    # keep the NUL list order, minus the hits
    python3 -c 'import sys
a=open(sys.argv[1],"rb").read().split(b"\0"); h=set(open(sys.argv[2],"rb").read().split(b"\0"))
sys.stdout.buffer.write(b"".join(x+b"\0" for x in a if x and x not in h))' "$all" "$hits"
  else
    cat "$all"
  fi
  rm -f "$all" "$hits"
}

case "${1:-}" in
  tar)
    [[ $# -ge 2 && -d "$2" ]] || usage
    src="$(cd "$2" && pwd -P)"; shift 2
    pack_list "$src" "$@" | key_filter | tar -cf - --null --no-recursion --ignore-failed-read -T - 2>/dev/null
    ;;
  scan)
    [[ $# -eq 2 && -f "$2" ]] || usage
    names="$(zstd -dcq -- "$2" | tar -tf - 2>/dev/null)" || { echo "FATAL $2 is not a readable tar.zst" >&2; exit 2; }
    rc=0
    while IFS= read -r n; do
      [[ -n "$n" && "$n" =~ $BOX_STATE_NAME_RE ]] && { echo "HIT $n name"; rc=3; }
    done <<<"$names"
    # the whole stream through the key pattern (a tar holds member bytes
    # raw); only on a hit, member by member to NAME it (a fork per member is
    # slow on ~90k files). Only the name is printed, never the bytes.
    # grep -c, not -q: -q quits at the first hit, zstd then dies of SIGPIPE
    # and pipefail turns the hit into a miss
    n="$(zstd -dcq -- "$2" | grep -caE -e "$BOX_STATE_KEY_RE")"
    if [[ "${n:-0}" -gt 0 ]]; then
      rc=3
      keyhits="$(zstd -dcq -- "$2" | tar -xf - --to-command='grep -qaE -e "$BOX_STATE_KEY_RE" && printf "HIT %s key\n" "$TAR_FILENAME"; exit 0' 2>/dev/null)"
      printf '%s\n' "${keyhits:-HIT <stream> key}"
    fi
    exit "$rc"
    ;;
  key-re) printf '%s\n' "$BOX_STATE_KEY_RE" ;;
  *) usage ;;
esac
