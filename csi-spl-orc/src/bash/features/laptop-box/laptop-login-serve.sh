#!/usr/bin/env bash
#------------------------------------------------------------------------------
# laptop-login-serve.sh - the ONLY thing a laptop box's key may run on the
# fleet box it pulls its Claude login from (SPL-6680, spec 037 "Laptop box";
# owner answer Q1 = PUL: "the laptop pulls sat's login over ssh, read-only").
# do_spl_laptop_box_login_grant installs it root-owned, with a root-owned copy
# of agent-login-cred.sh next to it, and names it in the key's
# authorized_keys line: restrict,command="LAPTOP_SERVE_FILES='<files>' bash
# <this file>". sshd then runs it for every connection of that key, whatever
# the laptop asked; the ask is in SSH_ORIGINAL_COMMAND: "<op> <file> [jq]".
# Served: the READ ops of agent-login-cred.sh only (fstat, fget, facct,
# facctget), on the files of LAPTOP_SERVE_FILES only (the cnf's claude login
# files); anything else is refused, exit 2, before any file is touched.
# Env (tests): LAPTOP_SERVE_HELPER (default agent-login-cred.sh next to this).
#------------------------------------------------------------------------------
set -uo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
helper="${LAPTOP_SERVE_HELPER:-$here/agent-login-cred.sh}"
read -r -a a <<<"${SSH_ORIGINAL_COMMAND:-}"
op="${a[0]:-}" f="${a[1]:-}" jq="${a[2]:-}"
refuse() { echo "refused: $1" >&2; exit 2; }
(( ${#a[@]} <= 3 )) || refuse "too many words"
case "$op" in fstat|fget|facct|facctget) ;; *) refuse "op '$op' is not served (read ops only)" ;; esac
[[ " ${LAPTOP_SERVE_FILES:-} " == *" $f "* && -n "$f" ]] || refuse "file is not served"
[[ -z "$jq" || ( "$op" == fstat && "$jq" =~ ^\.[A-Za-z0-9_.]+$ ) ]] || refuse "bad jq path"
exec bash "$helper" "$op" "$f" ${jq:+"$jq"}
