#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Create the Docs GitHub App (spec 075 §9.1, T00) with GitHub's
# @description manifest flow: the owner clicks Create once, this action does the
# @description rest. A local listener on 127.0.0.1:<GH_APP_PORT> serves "/", a
# @description page that POSTs the manifest to GitHub's new-App form, and
# @description "/callback", where GitHub sends the one-time code. The code is
# @description exchanged at once (POST /app-manifests/<code>/conversions, valid
# @description 1 h) for the App id, slug and private key. The key is written to
# @description $HOME/.github/.<ORG>/<slug>.pem (0600) and then put into the
# @description Secret Manager slot of every env in GH_APP_ENVS, each as that
# @description env's project SA (do_spl_gh_app_key_put). Prints only the App id,
# @description slug, key path, secret names and the Install link: the key, the
# @description webhook secret and the client secret never reach stdout or a log.
# @description Manifest: Contents read+write, Metadata read, no webhook, no
# @description events, installable only on the repo's own account.
# @description DRY_RUN=1 (default): print the manifest and the link, no listener.
# @param GH_APP_REPO (optional) - <owner>/<repo>, default: the origin remote
# @param GH_APP_NAME (optional) - default: BASE_DOMAIN's first label + " Docs"
# @param GH_APP_PORT (optional) - listener port on 127.0.0.1 (default 3979)
# @param GH_APP_WAIT (optional) - seconds to wait for the click (default 3600)
# @param GH_APP_CODE (optional) - a code the owner pasted back: no listener
# @param GH_APP_ENVS (optional) - envs to put the key into (default "dev prd")
# @param GH_APP_KEY_DIR (optional) - default $HOME/.github/.<ORG>
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_gh_app_manifest
# @example DRY_RUN=0 ./run -a do_spl_gh_app_manifest
#------------------------------------------------------------------------------
do_spl_gh_app_manifest() {
  local dry="${DRY_RUN:-1}" port="${GH_APP_PORT:-3979}" wait_s="${GH_APP_WAIT:-3600}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$port" =~ ^[1-9][0-9]{2,4}$ && "$wait_s" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL GH_APP_PORT / GH_APP_WAIT must be positive integers"; return 2; }
  do_require_bin gh jq python3 yq || return 1
  do_resolve_oap ORG && do_resolve_oap APP || return 1
  local repo name home
  repo="$(_sga_repo)"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { do_log "FATAL no GitHub repo: set GH_APP_REPO=<owner>/<repo>"; return 1; }
  home="$(_sga_base_domain)" || return 1
  name="${GH_APP_NAME:-$(_sga_default_name "$home")}"
  local tmp; tmp="$(umask 077 && mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; trap - RETURN" RETURN
  _sga_manifest "$name" "https://$home" "http://127.0.0.1:$port/callback" >"$tmp/manifest.json"
  local form; form="$(_sga_form_url "$repo")" || return 1
  do_log "INFO $repo: App \"$name\", Contents write + Metadata read, no webhook, this account only"
  if [[ "$dry" == 1 ]]; then
    jq . "$tmp/manifest.json"
    do_log "OK DRY_RUN would serve http://127.0.0.1:$port/ (posts to $form) and wait ${wait_s}s for the code. Re-run with DRY_RUN=0."
    return 0
  fi
  local code="${GH_APP_CODE:-}"
  if [[ -z "$code" ]]; then
    do_log "OPEN http://127.0.0.1:$port/ in a browser on this box (one click: Create GitHub App)"
    _sga_listen "$port" "$form" "$tmp/manifest.json" "$tmp/code" "$wait_s" || return 1
    code="$(cat "$tmp/code")"
  fi
  [[ "$code" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL the code is not a manifest code"; return 1; }
  _sga_exchange_and_store "$repo" "$code" "$tmp"
}

# <repo> <code> <tmp> - exchange the code, write the key file, put it per env
_sga_exchange_and_store() {
  local repo="$1" code="$2" tmp="$3" conv="$3/conv.json"
  (umask 077 && gh api -X POST "/app-manifests/$code/conversions" >"$conv" 2>"$tmp/conv.err") ||
    { do_log "FATAL the code exchange failed: $(head -c 300 "$tmp/conv.err")"; return 1; }
  local id slug
  id="$(jq -r '.id // empty' "$conv")"; slug="$(jq -r '.slug // empty' "$conv")"
  [[ "$id" =~ ^[0-9]+$ && "$slug" =~ ^[a-z0-9-]+$ ]] || { do_log "FATAL the exchange returned no App id / slug"; return 1; }
  local dir="${GH_APP_KEY_DIR:-$HOME/.github/.$ORG}" key
  key="$dir/$slug.pem"
  [[ ! -e "$key" ]] || { do_log "FATAL $key exists: refusing to overwrite a key"; return 1; }
  mkdir -p "$dir" && (umask 077 && jq -j '.pem // empty' "$conv" >"$key") && chmod 0600 "$key" ||
    { do_log "FATAL could not write $key"; return 1; }
  [[ -s "$key" ]] || { rm -f "$key"; do_log "FATAL the exchange returned no private key"; return 1; }
  do_log "OK GitHub App created: id=$id slug=$slug (key at $key, 0600)"
  do_log "INFO permissions $(jq -c '.permissions // {}' "$conv") events $(jq -c '.events // []' "$conv")"
  rm -f "$conv"
  local e rc=0
  for e in ${GH_APP_ENVS:-dev prd}; do
    ( export ENV="$e"; unset PROJ_ID SPL_PROJECT GCP_PROJECT GCP_ACCOUNT ACCOUNT
      DRY_RUN=0 KEY_FILE="$key" do_spl_gh_app_key_put ) || rc=1
  done
  do_log "OK next, the owner's 2nd click: $(_sga_install_url "$repo" "$slug")"
  do_log "OK then: GH_APP_SLUG=$slug DRY_RUN=0 ./run -a do_spl_gh_app_bypass"
  return $rc
}

_sga_repo() {
  if [[ -n "${GH_APP_REPO:-}" ]]; then printf '%s\n' "$GH_APP_REPO"; return 0; fi
  local url; url="$(git -C "$APP_PATH" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}

_sga_base_domain() {
  local d
  d="$(yq -r '.env.dns.BASE_DOMAIN // ""' "$APP_PATH/$ORG-$APP-cnf/$ORG-$APP/all.env.yaml" 2>/dev/null)"
  [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]+$ ]] || { do_log "FATAL no env.dns.BASE_DOMAIN in the cnf"; return 1; }
  printf '%s\n' "$d"
}

# <base domain> -> its first label title-cased + " Docs" (a-b.c -> "A B Docs")
_sga_default_name() {
  local w out="" label="${1%%.*}"
  for w in ${label//-/ }; do out+="${w^} "; done
  printf '%sDocs\n' "$out"
}

# <name> <homepage> <redirect url> -> the App manifest JSON
_sga_manifest() {
  jq -n --arg n "$1" --arg u "$2" --arg r "$3" '{
    name: $n, url: $u, redirect_url: $r, public: false,
    default_permissions: {contents: "write", metadata: "read"},
    default_events: []
  }'
}

# <repo> -> GitHub's new-App form for the repo's owner (an org or a user)
_sga_form_url() {
  local owner="${1%%/*}" type
  type="$(gh api "users/$owner" --jq .type 2>/dev/null)" || { do_log "FATAL cannot read GitHub account $owner"; return 1; }
  case "$type" in
    Organization) printf 'https://github.com/organizations/%s/settings/apps/new\n' "$owner" ;;
    User) printf 'https://github.com/settings/apps/new\n' ;;
    *) do_log "FATAL $owner is neither an organisation nor a user: '$type'"; return 1 ;;
  esac
}

# <repo> <slug> -> the install link with the account and the repo preselected
_sga_install_url() {
  local ids
  ids="$(gh api "repos/$1" --jq '"\(.owner.id) \(.id)"' 2>/dev/null)" || ids=""
  if [[ "$ids" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    printf 'https://github.com/apps/%s/installations/new/permissions?suggested_target_id=%s&repository_ids[]=%s\n' \
      "$2" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf 'https://github.com/apps/%s/installations/new\n' "$2"
  fi
}

# <port> <form url> <manifest file> <code out file> <wait seconds>
# Serves the auto-submitting form and takes the code back on /callback (the
# state must match). Exits 0 once the code is written, 1 on timeout.
_sga_listen() {
  python3 -I -c '
import html, http.server, os, secrets, sys, time, urllib.parse
port, form, mfile, out, wait = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
manifest = open(mfile).read()
state = secrets.token_urlsafe(24)
done = []
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/":
            act = html.escape(form + "?state=" + state)
            self.send(200, "<!doctype html><meta charset=utf-8><title>Create the GitHub App</title>"
                f"<form id=f method=post action=\"{act}\"><input type=hidden name=manifest value=\"{html.escape(manifest)}\">"
                "<button>Continue to GitHub</button></form><script>document.getElementById(\"f\").submit()</script>")
        elif u.path == "/callback" and q.get("state") == [state] and len(q.get("code", [])) == 1:
            fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.write(fd, q["code"][0].encode()); os.close(fd)
            done.append(1)
            self.send(200, "<!doctype html><meta charset=utf-8><title>App created</title><p>GitHub App created. You can close this tab.")
        elif u.path == "/callback":
            self.send(400, "<!doctype html><meta charset=utf-8><title>Refused</title><p>Wrong or missing state.")
        else:
            self.send(404, "")
s = http.server.HTTPServer(("127.0.0.1", port), H)
s.timeout = 5
end = time.time() + wait
while not done and time.time() < end:
    s.handle_request()
sys.exit(0 if done else 1)
' "$@" || { do_log "FATAL no code arrived on 127.0.0.1:$1 within $5 s (or the port is taken)"; return 1; }
}
