#!/bin/sh
# secret-env.sh NAME... -- CMD [ARG...]: for each NAME whose NAME_FILE is set
# (a Docker secret of the root docker-compose.yml, under /run/secrets), export
# NAME from that file, then exec CMD (SPL-2158, security action 1). The file
# wins over NAME; an unreadable one stops the container, naming the variable
# only, never the value.
#
# The compose file mounts this read-only and runs it in front of the image's
# own entrypoint: SeaweedFS reads only AWS_SECRET_ACCESS_KEY, and a hub image
# older than SPL-2158 reads only the plain env vars. A hub image that carries
# SPL-2158 reads the *_FILE variables itself (internal/secretfile,
# hub-entrypoint.sh file_env); both read the same file, so the value agrees.
set -eu
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  eval "f=\${$1_FILE:-}"
  if [ -n "$f" ]; then
    [ -r "$f" ] || { echo "secret-env: FATAL $1_FILE names a file this container cannot read (.env.example: secret files)" >&2; exit 1; }
    # shellcheck disable=SC2034 # v is read by the eval below
    v="$(cat "$f")"
    eval "$1=\$v"
    export "${1?}"
  fi
  shift
done
[ "${1:-}" = -- ] || { echo "secret-env: FATAL usage: secret-env.sh NAME... -- CMD [ARG...]" >&2; exit 2; }
shift
exec "$@"
