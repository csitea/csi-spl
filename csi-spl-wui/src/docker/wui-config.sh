#!/bin/sh
# The web container's start (spec 072 A3): write /srv/config.json from this
# container's env, then run Caddy. The bundle is built once with no env
# values; the page reads them from /config.json at boot
# (src/utils/runtime-config.mjs), so a domain or tenant change is a restart,
# not `docker compose up --build`.
#
#   SPOOL_PUBLIC_URL      the page origin as the browser sees it; "" = the
#                         page's own origin (the hub is behind the same Caddy)
#   SPOOL_TENANT          the tenant sign-in binds (default main)
#   SPOOL_LOBBY_TASK_ID   the #lobby topic id (the hub's welcome still wins)
#   SPOOL_ENV_NAME        a name shown in the signed-out bar ("" = none)
#   SPOOL_REPO_WEB_URL, SPOOL_REPO_CLONE_URL, SPOOL_REPO_COMMIT_PATH,
#   SPOOL_REPO_HELP_PATH  the source repository's url pieces (cnf
#                         env.wui.repo_*); "" = those links are hidden
#
# WUI_CONFIG_OUT overrides the target (the test writes to a temp dir).
# Pure POSIX sh: the caddy image has no bash and no jq.
set -eu

out="${WUI_CONFIG_OUT:-/srv/config.json}"

# A value that would break the JSON (a quote, a backslash, a control char) is
# refused by name rather than escaped: none of these values has a reason to
# carry one.
json_value() {
  name="$1" value="$2"
  case "$value" in
    *[\"\\]* | *[[:cntrl:]]*)
      echo "wui-config: $name holds a quote, backslash or control character: refused" >&2
      return 1 ;;
  esac
  printf '"%s"' "$value"
}

# the page origin: http(s)://host[:port], no path; trailing slashes dropped
url="${SPOOL_PUBLIC_URL:-}"
while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
case "$url" in
  "" | http://* | https://*) ;;
  *) echo "wui-config: SPOOL_PUBLIC_URL='$url' is not an http(s) URL" >&2; exit 1 ;;
esac
site=""
case "$url" in https://*) site="$url" ;; esac

api=$(json_value SPOOL_PUBLIC_URL "$url")
site=$(json_value SPOOL_PUBLIC_URL "$site")
tenant=$(json_value SPOOL_TENANT "${SPOOL_TENANT:-main}")
lobby=$(json_value SPOOL_LOBBY_TASK_ID "${SPOOL_LOBBY_TASK_ID:-}")
envname=$(json_value SPOOL_ENV_NAME "${SPOOL_ENV_NAME:-}")
repoweb=$(json_value SPOOL_REPO_WEB_URL "${SPOOL_REPO_WEB_URL:-}")
repoclone=$(json_value SPOOL_REPO_CLONE_URL "${SPOOL_REPO_CLONE_URL:-}")
repocommit=$(json_value SPOOL_REPO_COMMIT_PATH "${SPOOL_REPO_COMMIT_PATH:-}")
repohelp=$(json_value SPOOL_REPO_HELP_PATH "${SPOOL_REPO_HELP_PATH:-}")

tmp="$out.tmp.$$"
printf '{"apiBase":%s,"authBase":"","siteUrl":%s,"tenant":%s,"lobbyTaskId":%s,"envName":%s,"repoWebUrl":%s,"repoCloneUrl":%s,"repoCommitPath":%s,"repoHelpPath":%s}\n' \
  "$api" "$site" "$tenant" "$lobby" "$envname" "$repoweb" "$repoclone" "$repocommit" "$repohelp" >"$tmp"
mv -f "$tmp" "$out"
echo "wui-config: wrote $out: $(cat "$out")"

[ "$#" -gt 0 ] || exit 0
exec "$@"
