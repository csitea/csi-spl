#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve a CLOUD env's (dev / prd) settings for the owner-gated
# @description cloud actions and export them as SPL_* variables. The values
# @description come from the effective cnf (csi-spl-iac's do_spl_merged_cnf:
# @description all.env.yaml deep-merged under <env>.env.yaml, plus derived
# @description env.dns.fqdn and env.hub.image.ref); nothing here restates one.
# @description The ONE place the cloud actions read names from, so the IDs a
# @description dry run prints are the IDs a real run touches.
# @description No GCP call is made here.
# @param ENV - required: dev or prd
# @param PROJ_PATH / APP_PATH - set by run.sh
# @param SPL_STATE_DIR (optional) - default: $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=dev do_spl_cloud_cnf && echo "$SPL_IMAGE_REF"
#------------------------------------------------------------------------------
# spl_require_cloud_env [value]: the cloud envs are dev and prd only (the
# first check of every owner-gated cloud action). Checks value, default
# $ENV; logs FATAL and returns 1 otherwise. The one copy of the rule (SPL-1038).
spl_require_cloud_env() {
  local e="${1-${ENV:-}}"
  [[ "$e" == dev || "$e" == prd ]] || { do_log "FATAL ENV must be dev or prd, got: '$e'"; return 1; }
}

do_spl_cloud_cnf() {
  spl_require_cloud_env || return 1
  local proj_base
  proj_base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
  [[ "$proj_base" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH (expected <org>-<app>-orc)"; return 1; }
  SPL_ORG_APP="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  local cnf_dir="$APP_PATH/$SPL_ORG_APP-cnf/$SPL_ORG_APP"
  local iac_lib="$APP_PATH/$SPL_ORG_APP-iac/lib/bash/funcs"
  [[ -f "$iac_lib/spl-merged-cnf.func.sh" ]] || { do_log "FATAL missing $iac_lib/spl-merged-cnf.func.sh"; return 1; }
  # shellcheck disable=SC1091
  source "$iac_lib/spl-merged-cnf.func.sh"
  # shellcheck disable=SC1091
  source "$iac_lib/gcp-require-live-account.func.sh"

  SPL_STATE_DIR="${SPL_STATE_DIR:-$HOME/.local/share/$SPL_ORG_APP/cloud/$ENV}"
  mkdir -p "$SPL_STATE_DIR" && chmod 700 "$SPL_STATE_DIR" || return 1
  # The merge is CACHED, content-addressed (2026-09-25): the cache file's name
  # carries a hash of the two cnf files and of the merge code, so an unchanged
  # cnf is merged once. Measured on the reply path that day: the merge plus a
  # yq per value was ~1.1 s of a 7 s reply, on every call, for a result that
  # had not changed since the last one. SPL_CNF_CACHE=0 forces a fresh merge.
  #
  # SPL_CNF itself stays $SPL_STATE_DIR/<env>.env.yaml and is now REPLACED by a
  # rename, never rewritten in place: that one path is shared by every
  # concurrent action (the orc state-dir race), and a rename means a reader
  # sees a whole file. The cache is only ever copied FROM, so a caller that
  # edits its SPL_CNF (a test's `yq -i`) cannot poison the next action.
  local key cache tmp
  key="$(cat "$cnf_dir/all.env.yaml" "$cnf_dir/$ENV.env.yaml" "$iac_lib/spl-merged-cnf.func.sh" 2>/dev/null | sha256sum)" ||
    { do_log "FATAL cannot hash the $ENV cnf ($cnf_dir)"; return 1; }
  cache="$SPL_STATE_DIR/cnf/$ENV.${key:0:16}.env.yaml"
  if [[ ! -s "$cache" || "${SPL_CNF_CACHE:-1}" == 0 ]]; then
    mkdir -p "$SPL_STATE_DIR/cnf" || return 1
    tmp="$cache.tmp.$$"
    do_spl_merged_cnf "$cnf_dir" "$ENV" "$tmp" && mv -f "$tmp" "$cache" ||
      { rm -f "$tmp"; do_log "FATAL cannot merge the $ENV cnf"; return 1; }
    # A day-old merge of an older cnf is nobody's any more.
    find "$SPL_STATE_DIR/cnf" -maxdepth 1 -name "$ENV.*.env.yaml" -mmin +1440 -delete 2>/dev/null || true
  fi
  SPL_CNF="$SPL_STATE_DIR/$ENV.env.yaml"
  tmp="$SPL_CNF.tmp.$$"
  cp "$cache" "$tmp" && mv -f "$tmp" "$SPL_CNF" || { rm -f "$tmp"; do_log "FATAL cannot write $SPL_CNF"; return 1; }

  # Every value in ONE yq call: a yq process per value was ~50 ms each.
  local -a vals=()
  mapfile -t vals < <(yq -r '[.env.gcp.gcp_project, .env.gcp.gcp_region, .env.dns.fqdn, .env.hub.image.ref,
      .env.hub.image.sql_src, .env.hub.env.SPOOL_HUB_MIGRATIONS_DIR,
      .env.steps."040-cloud-sql-postgres".instance_name, .env.steps."040-cloud-sql-postgres".database_name,
      .env.hub.db_user, .env.hub.secret_env.SPOOL_HUB_DB_DSN, .env.hub.db_owner_user,
      .env.hub.db_owner_dsn_secret, .env.hub.cloud_sql_proxy_image] | .[] | (. // "")' "$SPL_CNF")
  [[ ${#vals[@]} -eq 13 ]] || { do_log "FATAL cannot read the $ENV values out of $SPL_CNF (got ${#vals[@]} of 13)"; return 1; }
  SPL_PROJECT="${vals[0]}"
  SPL_REGION="${vals[1]}"
  SPL_FQDN="${vals[2]}"
  SPL_IMAGE_REF="${vals[3]}"
  # cnf hub.image.tag is the FLOOR (= .version); the tag a deploy ships is the
  # release version CI mints for its commit (do_release_version), handed in as
  # SPL_HUB_IMAGE_TAG. SPL_IMAGE_CNF_REF keeps the cnf reference for readers
  # that compare against the floor (do_check_hub_deploy, the regress check).
  SPL_IMAGE_CNF_REF="$SPL_IMAGE_REF"
  if [[ -n "${SPL_HUB_IMAGE_TAG:-}" ]]; then
    [[ "$SPL_HUB_IMAGE_TAG" =~ ^[0-9]\.[0-9]\.[0-9]$ ]] ||
      { do_log "FATAL SPL_HUB_IMAGE_TAG must be an odometer version (d.d.d), got: '$SPL_HUB_IMAGE_TAG'"; return 1; }
    SPL_IMAGE_REF="${SPL_IMAGE_REF%:*}:$SPL_HUB_IMAGE_TAG"
  fi
  SPL_IMAGE_SQL_SRC="$APP_PATH/${vals[4]}"
  SPL_MIGRATIONS_DIR="${vals[5]}"
  SPL_SQL_INSTANCE="${vals[6]}"
  SPL_DB_NAME="${vals[7]}"
  SPL_DB_USER="${vals[8]}"
  SPL_DSN_SECRET="${vals[9]}"
  # 017 T029: the schema owner's login and its own, never-injected DSN slot
  SPL_DB_OWNER_USER="${vals[10]}"
  SPL_OWNER_DSN_SECRET="${vals[11]}"
  SPL_SQL_PROXY_IMAGE="${vals[12]}"
  SPL_SQL_CONN="$SPL_PROJECT:$SPL_REGION:$SPL_SQL_INSTANCE"
  SPL_REGISTRY_HOST="${SPL_IMAGE_REF%%/*}"
  SPL_DB_ROLES_SQL="$APP_PATH/$SPL_ORG_APP-rdb/src/sql/postgres/spool-hub-roles"

  local v
  for v in SPL_PROJECT SPL_REGION SPL_FQDN SPL_IMAGE_REF SPL_MIGRATIONS_DIR SPL_SQL_INSTANCE SPL_DB_NAME \
           SPL_DB_USER SPL_DSN_SECRET SPL_DB_OWNER_USER SPL_OWNER_DSN_SECRET SPL_SQL_PROXY_IMAGE; do
    [[ -n "${!v}" && "${!v}" != null ]] || { do_log "FATAL $v is empty: check $ENV.env.yaml / all.env.yaml"; return 1; }
  done
  [[ "$SPL_DB_USER" != "$SPL_DB_OWNER_USER" && "$SPL_DSN_SECRET" != "$SPL_OWNER_DSN_SECRET" ]] ||
    { do_log "FATAL cnf hub.db_user / db_owner_user (and their secrets) must differ (017 T029)"; return 1; }
  [[ "$SPL_PROJECT" == "$SPL_ORG_APP-$ENV" ]] || { do_log "FATAL cnf gcp_project=$SPL_PROJECT, the convention says $SPL_ORG_APP-$ENV; refusing"; return 1; }
  export SPL_ORG_APP SPL_STATE_DIR SPL_CNF SPL_PROJECT SPL_REGION SPL_FQDN SPL_IMAGE_REF SPL_IMAGE_CNF_REF SPL_IMAGE_SQL_SRC \
    SPL_MIGRATIONS_DIR SPL_SQL_INSTANCE SPL_DB_NAME SPL_DB_USER SPL_DSN_SECRET SPL_SQL_CONN SPL_REGISTRY_HOST \
    SPL_SQL_PROXY_IMAGE SPL_DB_OWNER_USER SPL_OWNER_DSN_SECRET SPL_DB_ROLES_SQL
}

# do_spl_desk_cnf: the desk actions' resolver (specs/047 W4). It sets
# SPL_HUB_URL (the hub a desk box talks to), SPL_WUI_URL (where a human opens
# a DM), SPL_STATE_DIR and SPL_ORG_APP.
#   ENV=dev|prd   the estate: do_spl_cloud_cnf, hub https://<env.dns.api_fqdn>
#   ENV=self      a self-hosted hub (the root docker-compose.yml, or any other
#                 spool hub): NO cnf and no cloud. SPOOL_HUB_URL is the hub;
#                 the first run saves it as <state>/hub-url, later runs read it
#                 back, and a different SPOOL_HUB_URL is refused (the box key
#                 is pinned at the saved hub). State: <data>/<org>-<app>/cloud/self
do_spl_desk_cnf() {
  if [[ "${ENV:-}" != self ]]; then
    do_spl_cloud_cnf || return 1
    SPL_HUB_URL="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
    [[ "$SPL_HUB_URL" != https:// ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
    SPL_WUI_URL="https://$SPL_FQDN"
    export SPL_HUB_URL SPL_WUI_URL
    return 0
  fi
  local proj_base
  proj_base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
  [[ "$proj_base" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH (expected <org>-<app>-orc)"; return 1; }
  SPL_ORG_APP="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  SPL_STATE_DIR="${SPL_STATE_DIR:-$HOME/.local/share/$SPL_ORG_APP/cloud/self}"
  mkdir -p "$SPL_STATE_DIR" && chmod 700 "$SPL_STATE_DIR" || return 1
  local saved="" want="${SPOOL_HUB_URL:-}"
  [[ -s "$SPL_STATE_DIR/hub-url" ]] && saved="$(head -n 1 "$SPL_STATE_DIR/hub-url")"
  want="${want%/}"
  if [[ -z "$want" ]]; then
    [[ -n "$saved" ]] || { do_log "FATAL ENV=self needs SPOOL_HUB_URL (the self-hosted hub, e.g. https://chat.example.org or http://localhost:8080); none is saved in $SPL_STATE_DIR/hub-url yet"; return 1; }
    want="$saved"
  fi
  [[ "$want" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] ||
    { do_log "FATAL SPOOL_HUB_URL must be http(s)://<host>[:<port>] with no path, got: '$want'"; return 1; }
  if [[ -n "$saved" && "$saved" != "$want" ]]; then
    do_log "FATAL this self-hosted desk is seated at $saved, not $want: its box keys are pinned there. Use that hub, or another SPL_STATE_DIR for a second one"
    return 1
  fi
  [[ -n "$saved" ]] || printf '%s\n' "$want" >"$SPL_STATE_DIR/hub-url" || return 1
  SPL_HUB_URL="$want"
  SPL_WUI_URL="$want"
  SPL_FQDN="${want#*://}"; SPL_FQDN="${SPL_FQDN%%:*}"
  SPL_CNF="$SPL_STATE_DIR/self.env.yaml"
  # the few readers of $SPL_CNF on the desk path find the hub here too
  printf 'env:\n  name: self\n  dns:\n    fqdn: "%s"\n' "$SPL_FQDN" >"$SPL_CNF" || return 1
  export SPL_ORG_APP SPL_STATE_DIR SPL_CNF SPL_FQDN SPL_HUB_URL SPL_WUI_URL
}

# spl_root_key_to_file <ROOT_KEY_JSON> <out>: the tenant root private key out
# of ROOT_KEY_JSON into <out> (a 0600 scratch file the caller removes). It
# takes the create JSON (field root_private_key) that do_spl_tenant_create and
# the checkout claim write, or a bare base64 key file such as the compose
# stack's tenant-root.key (specs/047 W4). Never prints the key.
spl_root_key_to_file() {
  python3 - "$1" "$2" <<'EOF_PY' 2>/dev/null
import base64, json, sys
raw = open(sys.argv[1]).read().strip()
try:
    key = json.loads(raw)["root_private_key"].strip()
except (ValueError, KeyError, TypeError, AttributeError):
    key = raw  # a bare key file: it must BE a key, not any text
    if len(base64.b64decode(key, validate=True)) != 64:
        sys.exit(1)
if not key:
    sys.exit(1)
open(sys.argv[2], "w").write(key + "\n")
EOF_PY
}

# spl_require_tenant_slug <tenant> -> 0 when <tenant> is a tenant slug
# ([a-z0-9][a-z0-9-]{0,31}); otherwise logs the FATAL every action printed
# when it carried this check inline, and returns 1.
spl_require_tenant_slug() {
  [[ "${1-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '${1-}'"; return 1; }
}

# spl_cnf_api_fqdn <var> -> sets <var> to env.dns.api_fqdn of $SPL_CNF; when
# the cnf has none, logs the FATAL the actions printed inline and returns 1.
spl_cnf_api_fqdn() {
  local _fqdn
  _fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  printf -v "$1" '%s' "$_fqdn"
}

# spl_psql_mark <psql output> <tag> -> the value of the first "<tag> | <value>"
# line a guarded psql script printed (the text after its last "| "); 1 when no
# such line. The channel/member ops print their refusals this way because psql
# 18 ignores the code of "\quit 1".
spl_psql_mark() {
  local line
  line="$(grep -m 1 "^$2 | " <<<"$1")" || return 1
  printf '%s\n' "${line##*| }"
}

# spl_dry_run -> 0 when DRY_RUN is 1 (the default), 1 when 0; fails otherwise
spl_dry_run() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d"; return 2; }
  [[ "$d" == 1 ]]
}

# spl_host_spool -> the host `spool` CLI in the state dir (local only), built
# only when this tree has something NEWER to put there; sets SPL_SPOOL to it.
#
# It used to run build.sh on EVERY call (2026-09-25, measured on the desk reply
# path: ~2.2 s of it, n=3). build.sh stamps -X main.builtAt with the current
# second, so the link flags differ on every call and Go re-links the 57 MB
# binary each time. And it overwrote $SPL_STATE_DIR/bin/spool - the file the
# running box-desk sidecar was started from - with whatever tree the action
# ran in: from a checkout 40 commits behind, a silent DOWNGRADE for the next
# sidecar restart. The live prd binary read vcs.revision=773c26d that day.
#
# So (spl_host_spool_verdict): keep the binary when it was built from this
# tree's HEAD with a clean module; build when the tree is newer; and REFUSE -
# keep the binary, log why - when the tree is older than the binary. The build
# goes to a private tmp and is renamed into place, so a sidecar that execs the
# path meanwhile gets the old file or the new one, never half of one.
# SPL_SPOOL_REBUILD=1 builds regardless (and may downgrade: the operator asked).
spl_host_spool() {
  local build="$APP_PATH/$SPL_ORG_APP-api/src/bash/build.sh" verdict why tmp head
  SPL_SPOOL="$SPL_STATE_DIR/bin/spool"
  verdict="$(spl_host_spool_verdict "$SPL_SPOOL")"
  why="${verdict#* }"; verdict="${verdict%% *}"
  case "$verdict" in
    keep) return 0 ;;
    refuse) do_log "WARN keeping $SPL_SPOOL: $why (SPL_SPOOL_REBUILD=1 overrides)"; return 0 ;;
  esac
  mkdir -p "$SPL_STATE_DIR/bin" || return 1
  tmp="$SPL_SPOOL.build.$$"
  bash "$build" "$tmp" >/dev/null && mv -f "$tmp" "$SPL_SPOOL" ||
    { rm -f "$tmp"; do_log "FATAL spool build failed ($build)"; return 1; }
  head="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)"
  printf '%s %s\n' "${head:-unknown}" "$(spl_host_spool_tree_state)" >"$SPL_SPOOL.src" 2>/dev/null || true
}

# The Go module's paths, relative to $APP_PATH: what the binary is built from.
spl_host_spool_paths() {
  printf '%s\n' "$SPL_ORG_APP-api/src/go/spool-hub-api" "$SPL_ORG_APP-api/src/bash/build.sh" .version
}

# spl_host_spool_inputs_unchanged <from> <to> -> 0 when no build input of the
# spool binary (spl_host_spool_paths) differs between the two commits.
spl_host_spool_inputs_unchanged() {
  local -a paths=()
  mapfile -t paths < <(spl_host_spool_paths)
  git -C "$APP_PATH" diff --quiet "$1" "$2" -- "${paths[@]}" 2>/dev/null
}

# clean | dirty: whether the module's paths differ from HEAD in this tree.
# Scoped to the module on purpose - the shared checkout is routinely dirty in
# unrelated files, and that is no reason to rebuild.
spl_host_spool_tree_state() {
  local -a paths=()
  mapfile -t paths < <(spl_host_spool_paths)
  if [[ -n "$(git -C "$APP_PATH" status --porcelain -- "${paths[@]}" 2>/dev/null)" ]]; then
    echo dirty
  else
    echo clean
  fi
}

# spl_host_spool_bin_rev <bin> -> "<commit> <vcs.modified>" of a spool binary,
# read from the build info Go embeds in it: build.sh's -X main.commit=<sha>
# (in the recorded -ldflags), else Go's own vcs.revision. `spool version`
# prints neither. <vcs.modified> is "unknown" when Go did not stamp vcs, which
# it does not in a git worktree. Empty when the binary carries no commit.
spl_host_spool_bin_rev() {
  local sel
  sel="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/csi-spl-api/src/bash/use-go-toolchain.sh"
  if [[ -f "$sel" ]]; then
    # shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
    source "$sel"
    spl_export_go_path || true
  fi
  go version -m "$1" 2>/dev/null | awk '
    $1 == "build" && match($0, /main\.commit=[0-9a-f]+/) { c = substr($0, RSTART + 12, RLENGTH - 12) }
    $2 ~ /^vcs\.revision=/ { sub(/^vcs\.revision=/, "", $2); r = $2 }
    $2 ~ /^vcs\.modified=/ { sub(/^vcs\.modified=/, "", $2); m = $2 }
    END { if (c == "") c = r; if (c != "") print c, (m == "" ? "unknown" : m) }'
}

# spl_host_spool_verdict <bin> -> "build|keep|refuse <why>"
spl_host_spool_verdict() {
  local bin="$1" head state rev mod stamp
  [[ "${SPL_SPOOL_REBUILD:-0}" == 1 ]] && { echo "build SPL_SPOOL_REBUILD=1"; return 0; }
  [[ -x "$bin" ]] || { echo "build no binary yet"; return 0; }
  head="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)"
  [[ -n "$head" ]] || { echo "build $APP_PATH is not a git tree"; return 0; }
  read -r rev mod < <(spl_host_spool_bin_rev "$bin") || true
  [[ -n "${rev:-}" ]] || { echo "build the binary carries no vcs.revision"; return 0; }
  if [[ "$rev" == "$head" ]]; then
    state="$(spl_host_spool_tree_state)"
    [[ "$state" == clean ]] || { echo "build the module is modified in $APP_PATH"; return 0; }
    # Same commit and a clean module: current, if it was built CLEAN. Ours
    # say so in the .src stamp; a binary from a wholly clean tree says so too.
    stamp="$(cat "$bin.src" 2>/dev/null)"
    if [[ "$stamp" == "$head clean" || "$mod" == false ]]; then
      echo "keep built from $head"; return 0
    fi
    echo "build built from $head with local changes"; return 0
  fi
  if ! git -C "$APP_PATH" cat-file -e "$rev^{commit}" 2>/dev/null; then
    echo "refuse it was built from ${rev:0:12}, a commit this tree does not know, so it cannot be shown to be older than ${head:0:12}"
    return 0
  fi
  if git -C "$APP_PATH" merge-base --is-ancestor "$rev" "$head" 2>/dev/null; then
    # Newer commits that touch none of the build inputs make the same binary,
    # so it is kept (CLE-35076). Rebuilding on ANY newer commit restarted
    # every desk sidecar - dropping its hub socket - after each docs or WUI
    # push: 422 restarts on the prd desk cron and 80 on dev by 11:05Z
    # 2026-09-28. Only for a binary built clean, from a clean module.
    if spl_host_spool_inputs_unchanged "$rev" "$head" && [[ "$(spl_host_spool_tree_state)" == clean ]] &&
      [[ "$(cat "$bin.src" 2>/dev/null)" == "$rev clean" || "$mod" == false ]]; then
      echo "keep built from ${rev:0:12}: no build input changed up to ${head:0:12}"; return 0
    fi
    echo "build the tree (${head:0:12}) is newer than the binary (${rev:0:12})"; return 0
  fi
  if git -C "$APP_PATH" merge-base --is-ancestor "$head" "$rev" 2>/dev/null; then
    echo "refuse it was built from ${rev:0:12}, NEWER than this tree's ${head:0:12} ($APP_PATH): a rebuild here would downgrade it"
    return 0
  fi
  # Diverged: the newer commit wins, by commit time.
  if (( $(git -C "$APP_PATH" show -s --format=%ct "$head") >= $(git -C "$APP_PATH" show -s --format=%ct "$rev") )); then
    echo "build the tree (${head:0:12}) diverged from the binary (${rev:0:12}) and is newer"
  else
    echo "refuse it was built from ${rev:0:12}, which diverged from this tree's ${head:0:12} and is newer"
  fi
}

# spl_read_dsn -> prints the latest version of the DSN secret. The value is
# never logged; the caller keeps it in a local.
spl_read_dsn() {
  gcloud secrets versions access latest --secret="$SPL_DSN_SECRET" --project="$SPL_PROJECT" \
    --account="$GCP_ACCOUNT" 2>/dev/null
}

# spl_proxy_dsn <cloud dsn> <port> -> the same login through the local proxy.
# The cloud DSN is the one 040 documents and 030 runs:
#   postgres://<user>:<pw>@/<db>?host=/cloudsql/<connection_name>
spl_proxy_dsn() {
  local re='^postgres(ql)?://([^@/]+)@/([^?]+)[?]host=/cloudsql/[^&]+$'
  [[ "$1" =~ $re ]] || return 1
  printf 'postgres://%s@127.0.0.1:%s/%s?sslmode=disable' "${BASH_REMATCH[2]}" "$2" "${BASH_REMATCH[3]}"
}

# spl_sql_proxy_start -> the Cloud SQL Auth Proxy on 127.0.0.1:$SPL_PROXY_PORT
# (default 55499) for $SPL_SQL_CONN, as $GCP_ACCOUNT. The access token goes
# through the environment (CSQL_PROXY_TOKEN), never argv. A cloud-sql-proxy
# binary on PATH wins; otherwise the cnf image runs in docker on the host net.
# Stop it with spl_sql_proxy_stop.
spl_sql_proxy_start() {
  SPL_PROXY_PORT="${SPL_PROXY_PORT:-55499}"
  _SPL_PROXY_PID="" _SPL_PROXY_CON=""
  if (exec 3<>"/dev/tcp/127.0.0.1/$SPL_PROXY_PORT") 2>/dev/null; then
    do_log "FATAL 127.0.0.1:$SPL_PROXY_PORT is already in use (set SPL_PROXY_PORT)"; return 1
  fi
  CSQL_PROXY_TOKEN="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$CSQL_PROXY_TOKEN" ]] || { do_log "FATAL no access token for $GCP_ACCOUNT"; return 1; }
  export CSQL_PROXY_TOKEN
  if command -v cloud-sql-proxy >/dev/null; then
    cloud-sql-proxy --address 127.0.0.1 --port "$SPL_PROXY_PORT" "$SPL_SQL_CONN" >"$SPL_STATE_DIR/sql-proxy.log" 2>&1 &
    _SPL_PROXY_PID=$!
  else
    _SPL_PROXY_CON="$SPL_ORG_APP-$ENV-sql-proxy-$$"
    docker run -d --rm --name "$_SPL_PROXY_CON" --network host -e CSQL_PROXY_TOKEN "$SPL_SQL_PROXY_IMAGE" \
      --address 127.0.0.1 --port "$SPL_PROXY_PORT" "$SPL_SQL_CONN" >/dev/null ||
      { unset CSQL_PROXY_TOKEN; do_log "FATAL could not start $SPL_SQL_PROXY_IMAGE"; return 1; }
  fi
  unset CSQL_PROXY_TOKEN
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$SPL_PROXY_PORT") 2>/dev/null && { do_log "INFO Cloud SQL proxy up: 127.0.0.1:$SPL_PROXY_PORT -> $SPL_SQL_CONN"; return 0; }
    sleep 0.5
  done
  do_log "FATAL the Cloud SQL proxy did not listen on 127.0.0.1:$SPL_PROXY_PORT"
  spl_sql_proxy_stop; return 1
}

spl_sql_proxy_stop() {
  [[ -n "${_SPL_PROXY_PID:-}" ]] && { kill "$_SPL_PROXY_PID" 2>/dev/null || true; }
  [[ -n "${_SPL_PROXY_CON:-}" ]] && { docker stop "$_SPL_PROXY_CON" >/dev/null 2>&1 || true; }
  _SPL_PROXY_PID="" _SPL_PROXY_CON=""
  return 0
}

# spl_pg_env <dsn> <cmd> [args] -> runs <cmd> with the DSN's login in PG* env
# vars (PGUSER, PGPASSWORD, PGHOST, PGPORT, PGDATABASE), so a password never
# sits in a psql argv that `ps` shows. For the local proxy DSN of spl_proxy_dsn.
spl_pg_env() {
  local parts
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$1")" || return 1
  shift
  local -a f
  mapfile -t f <<<"$parts"
  PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}" \
    PGSSLMODE=disable PGCONNECT_TIMEOUT=15 "$@"
}

# spl_via_proxy <cmd> [args] -> as the pinned $GCP_ACCOUNT (do_gcp_pin_account:
# the env's project SA), runs <cmd> with SPL_PROXY_DSN set to the hub DB's
# login through a local Cloud SQL proxy, then stops the proxy. The DSN lives in
# the environment of <cmd> only, never argv or a log.
spl_via_proxy() {
  local cloud_dsn dsn rc=0
  cloud_dsn="$(spl_read_dsn)"
  [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; return 1; }
  spl_sql_proxy_start || return 1
  dsn="$(spl_proxy_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the DSN in $SPL_DSN_SECRET is not postgres://<user>:<pw>@/<db>?host=/cloudsql/<conn>"; return 1; }
  SPL_PROXY_DSN="$dsn" "$@" || rc=$?
  spl_sql_proxy_stop
  return $rc
}

# The 025 system role ids (hub internal/rbac RoleIDs, rdb 0021 + 0039), for
# messages and @param lines; the hub DB (rbac_roles FK) is the authority.
SPL_ROLE_IDS='biz_owner|product_owner|admin|developer|tester|pure_agent|biz_customer|regular_user'

# spl_role_id <role>: prints the 025 role id (legacy owner|member mapped),
# or fails on a malformed id. Existence is the hub DB's call (rbac_roles FK).
spl_role_id() {
  local r="$1"
  case "$r" in owner) r=biz_owner ;; member) r=developer ;; esac
  [[ "$r" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || return 1
  printf '%s' "$r"
}
