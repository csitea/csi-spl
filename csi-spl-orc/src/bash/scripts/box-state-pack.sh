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
#         cred   a NetVisor or bank credential file, by name, anywhere
#         0600   a file of mode 0600 under a home's dot-dirs (owner rule
#                csitea fc0119cd msg 072a9990: keys and secrets stay on the
#                box), unless it matches BOX_STATE_ALLOW_0600
#         key    a file holding key or token MATERIAL ($BOX_STATE_KEY_RE):
#                a PEM private key, a root_private_key / private_key_id value,
#                a GitHub, Slack, Anthropic or Google API token. A word such
#                as "private_key" in a transcript is not material.
#       A file this user cannot read is a `DROP <path> unreadable`.
#   box-state-pack.sh scan <archive.tar.zst>
#       exit 0: no member name is excluded and no member holds key material;
#       exit 3: `HIT <member> name|cred|0600|key` per offending member (the member's
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
# A NetVisor or bank credential file, matched on the lower-cased name.
BOX_STATE_CRED_RE='(^|/)[^/]*(netvisor|bank[-_.]?(cred|creds|credentials|auth|api|key|keys|token|tokens|secret|secrets|cert|login))[^/]*$'
# Homes whose dot-dirs may hold no 0600 file (globs, absolute), and the 0600
# files that may go anyway: the agents' transcripts (0600 by Claude Code; their
# key material is caught by the key filter and the scan).
BOX_STATE_HOMES="${BOX_STATE_HOMES:-/home/* /root}"
BOX_STATE_ALLOW_0600="${BOX_STATE_ALLOW_0600:-*/.claude/projects/*}"
# shellcheck disable=SC2090
export BOX_STATE_KEY_RE BOX_STATE_NAME_RE BOX_STATE_CRED_RE BOX_STATE_HOMES BOX_STATE_ALLOW_0600

# secret_0600 <abs path> <mode 3-4 octal digits> -> 0 when the file is a
# 0600 file under a home's dot-dirs and not allow-listed
secret_0600() {
  local f="$1" m="$2" h a
  [[ "${m: -3}" == 600 ]] || return 1
  for h in $BOX_STATE_HOMES; do
    # shellcheck disable=SC2053 # $h is a glob on purpose
    if [[ "$f" == $h/.*/* ]]; then
      for a in $BOX_STATE_ALLOW_0600; do
        # shellcheck disable=SC2053
        [[ "$f" == $a ]] && return 1
      done
      return 0
    fi
  done
  return 1
}

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
    if [[ "${rel,,}" =~ $BOX_STATE_CRED_RE ]]; then echo "DROP $f cred" >&2; continue; fi
    if [[ ! -L "$f" ]] && secret_0600 "$f" "$(stat -c %a "$f")"; then echo "DROP $f 0600" >&2; continue; fi
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
    # tar -i: read past every end-of-archive marker to the end of the
    # stream. Without it tar stops at the first marker, zstd still writes the
    # rest (tar -A leaves a whole record after it), meets a closed pipe, and
    # pipefail calls a good archive unreadable whenever tar wins that race
    # (wf 10 run 38064273382); and a member after a stray marker is never named.
    names="$(zstd -dcq -- "$2" | tar -tvif - --numeric-owner 2>/dev/null)" || { echo "FATAL $2 is not a readable tar.zst" >&2; exit 2; }
    rc=0
    while read -r perm _ _ _ _ n; do
      [[ -n "$n" ]] || continue
      [[ "$perm" == l* ]] && n="${n% -> *}"
      if [[ "$n" =~ $BOX_STATE_NAME_RE ]]; then echo "HIT $n name"; rc=3
      elif [[ "${n,,}" =~ $BOX_STATE_CRED_RE ]]; then echo "HIT $n cred"; rc=3
      elif [[ "$perm" == -rw------- ]] && secret_0600 "/$n" 600; then echo "HIT $n 0600"; rc=3
      fi
    done <<<"$names"
    # the whole stream through the key pattern (a tar holds member bytes
    # raw); only on a hit, member by member to NAME it (a fork per member is
    # slow on ~90k files). Only the name is printed, never the bytes.
    # grep -a: the stream is binary. A match may end grep before zstd has
    # written everything (grep stops at the first match when its output is
    # /dev/null), so zstd dying of a closed pipe after a match is still a HIT.
    # With no match grep read the whole stream: then zstd must have exited 0,
    # else the archive is broken (rc=2) and never reported clean.
    zstd -dcq -- "$2" 2>/dev/null | grep -aE -e "$BOX_STATE_KEY_RE" >/dev/null
    zstat=${PIPESTATUS[0]} gstat=${PIPESTATUS[1]}
    if [[ $gstat -eq 0 ]]; then
      rc=3
      keyhits="$(zstd -dcq -- "$2" | tar -xif - --to-command='grep -qaE -e "$BOX_STATE_KEY_RE" && printf "HIT %s key\n" "$TAR_FILENAME"; exit 0' 2>/dev/null)"
      printf '%s\n' "${keyhits:-HIT <stream> key}"
    elif [[ $gstat -ne 1 || $zstat -ne 0 ]]; then
      echo "FATAL $2 is not a readable tar.zst" >&2
      rc=2
    fi
    exit "$rc"
    ;;
  key-re) printf '%s\n' "$BOX_STATE_KEY_RE" ;;
  *) usage ;;
esac
