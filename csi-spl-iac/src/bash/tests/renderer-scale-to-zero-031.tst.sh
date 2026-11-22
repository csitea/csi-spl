#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 183 1.2 R1 (owner msg ac761f15: "make sure this is started
#          ad-hoc ... no need to permanently use resources"), the check of row
#          P4. The topic PDF renderer (terraform step 031-cloud-run-pdf)
#          holds nothing while idle:
#            1. its service scales to zero: exactly one min_instance_count,
#               and it is the literal 0 (not a variable a cnf could raise);
#               cpu_idle = true; startup_cpu_boost absent or false;
#            2. nothing in csi-spl-iac/src/terraform keeps it warm: no
#               google_cloud_scheduler_job and no
#               google_monitoring_uptime_check_config block names it, and no
#               rendered tfvars of a step that holds one points at it;
#            3. only the hub may call it (7.1.6): one run.invoker member, the
#               hub's runtime SA, no allUsers / allAuthenticatedUsers;
#            4. the rendered dev and prd tfvars carry the 7.1.6 sizing
#               (concurrency 1, max 2, timeout 120, 1 cpu, 1Gi), and 030
#               passes SPOOL_PDF_URL from cnf hub.pdf.url and, with it,
#               SPOOL_PDF_TIMEOUT from cnf hub.pdf.timeout (spec 183 v0.6
#               7.1.6); neither while the url is "".
#          RED CONTROLS, each on a copy of the step: min_instance_count = 1,
#          cpu_idle = false, startup_cpu_boost = true, a planted scheduler job
#          that pings the renderer, a planted allUsers invoker, a 030 that
#          drops SPOOL_PDF_TIMEOUT or leaves pdf_timeout out of its template
#          hash: every one must fail the check that guards it.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
tmp_dir
TFD="$PROJ_ROOT/src/terraform"
STEP="031-cloud-run-pdf"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

[[ -d "$TFD/$STEP" ]] || { echo "FAIL: no $TFD/$STEP"; exit 1; }

# tf_code <dir>: the step's .tf files with comments dropped (a comment that
# explains R1 must not satisfy or break it)
tf_code() { cat "$1"/*.tf | sed -E 's/[[:space:]]*#.*$//; s|[[:space:]]*//.*$||'; }

# other <key re> <ok value re> < code: true when a line sets the key to
# anything but the ok value (awk, no early-exit pipe under pipefail)
other() { awk -v k="$1" -v ok="$2" '$0 ~ k && $0 !~ ok {f = 1} END {exit !f}'; }

# r1_scale <step dir>: the R1 reasons it breaks, one a line ("" = holds)
r1_scale() {
  local code n
  code="$(tf_code "$1")"
  n="$(grep -cE '^[[:space:]]*min_instance_count[[:space:]]*=' <<<"$code")"
  [[ "$n" == 1 ]] || echo "min_instance_count set $n times (want exactly one)"
  grep -qE '^[[:space:]]*min_instance_count[[:space:]]*=[[:space:]]*0[[:space:]]*$' <<<"$code" ||
    echo "min_instance_count is not the literal 0"
  grep -qE '^[[:space:]]*cpu_idle[[:space:]]*=[[:space:]]*true[[:space:]]*$' <<<"$code" || echo "cpu_idle is not true"
  other '^[[:space:]]*cpu_idle[[:space:]]*=' '=[[:space:]]*true[[:space:]]*$' <<<"$code" && echo "a cpu_idle other than true"
  other '^[[:space:]]*startup_cpu_boost[[:space:]]*=' '=[[:space:]]*false[[:space:]]*$' <<<"$code" &&
    echo "startup_cpu_boost is set to something other than false"
  return 0
}

# warmers <terraform root> <cnf dir>: every scheduler job or uptime check that
# names the renderer, one a line ("" = none). A block names it when its text
# says pdf, renderer or 031; a step that holds such a block also may not get
# a renderer host through its rendered tfvars.
warmers() {
  local root="$1" cnf="$2" f step env
  while IFS= read -r f; do
    awk '/^resource "(google_cloud_scheduler_job|google_monitoring_uptime_check_config)"/ {on=1; hdr=$0; buf=""}
         on {buf = buf "\n" $0}
         on && /^}/ {on=0; if (tolower(buf) ~ /pdf|renderer|031/) print FILENAME ": " hdr}' "$f"
    step="$(basename "$(dirname "$f")")"
    for env in dev prd; do
      [[ -f "$cnf/$env/tf/$step.vars.tfvars" ]] && grep -qiE -- '-pdf[.-]|pdf\.run\.app|/render' "$cnf/$env/tf/$step.vars.tfvars" &&
        echo "$env $step tfvars point a scheduler job or uptime check at the renderer"
    done
  done < <(grep -rlE '^resource "(google_cloud_scheduler_job|google_monitoring_uptime_check_config)"' "$root" --include='*.tf' | sort)
  return 0
}

# invokers <step dir>: the reasons the step's callers are not "the hub only"
invokers() {
  local code
  code="$(tf_code "$1")"
  grep -qE 'allUsers|allAuthenticatedUsers' <<<"$code" && echo "allUsers / allAuthenticatedUsers appears"
  [[ "$(grep -cE '^resource "google_cloud_run_v2_service_iam_(member|binding|policy)"' <<<"$code")" == 1 ]] ||
    echo "not exactly one Cloud Run IAM resource"
  [[ "$(grep -cE '^[[:space:]]*role[[:space:]]*=[[:space:]]*"roles/run.invoker"' <<<"$code")" == 1 ]] || echo "not exactly one run.invoker role"
  grep -qE '^[[:space:]]*member[[:space:]]*=[[:space:]]*"serviceAccount:\$\{var.hub_runtime_sa_account_id\}@\$\{var.gcp_project\}.iam.gserviceaccount.com"' <<<"$code" ||
    echo "the invoker is not the hub's runtime SA"
  grep -qE '^resource "google_(project|service_account)_iam_' <<<"$code" && echo "the renderer's SA gets a role"
  return 0
}

verdict() { # <label> <reasons>
  [[ -z "$2" ]] && pass "$1" || fail "$1: $(tr '\n' ';' <<<"$2")"
}

# hub_env_gaps <030 service .tf>: why 030 does not pass the renderer's url and
# timeout to the hub as 7.1.6 says, one a line ("" = it does)
hub_env_gaps() {
  local f="$1"
  grep -qF 'hub_env = merge(var.environment_variables, var.pdf_url == "" ? {} : { SPOOL_PDF_URL = var.pdf_url, SPOOL_PDF_TIMEOUT = var.pdf_timeout }' "$f" ||
    echo "030 does not merge SPOOL_PDF_URL and SPOOL_PDF_TIMEOUT from var.pdf_url and var.pdf_timeout"
  grep -qE '^[[:space:]]*for_each = local.hub_env$' "$f" || echo "030's container env does not read local.hub_env"
  grep -qE '^[[:space:]]*want_env += local.hub_env$' "$f" || echo "030's revision check does not read local.hub_env"
  grep -qE '^[[:space:]]*pdf_url += var.pdf_url$' "$f" || echo "030's template hash misses var.pdf_url"
  grep -qE '^[[:space:]]*pdf_timeout += var.pdf_timeout$' "$f" || echo "030's template hash misses var.pdf_timeout"
}

# --- 1..3 on the real step -----------------------------------------------------
verdict "1. $STEP scales to zero: min 0 (literal), cpu_idle true, no startup boost" "$(r1_scale "$TFD/$STEP")"
verdict "2. no scheduler job or uptime check in src/terraform keeps the renderer warm" "$(warmers "$TFD" "$CNF")"
verdict "3. only the hub's runtime SA may invoke the renderer" "$(invokers "$TFD/$STEP")"

# --- 4. the rendered sizing and the hub's env line --------------------------------
for env in dev prd; do
  v="$CNF/$env/tf/$STEP.vars.tfvars"
  if [[ ! -f "$v" ]]; then fail "4. $env: no $v (ENV=$env ./run -a do_tpl_gen)"; continue; fi
  got="$(grep -E '^(concurrency|max_instances|timeout_seconds|cpu|memory|service_name|hub_runtime_sa_account_id)[[:space:]]*=' "$v" |
    sed -E 's/[[:space:]]+=[[:space:]]+/=/' | sort | paste -sd' ')"
  want="concurrency=1 cpu=\"1\" hub_runtime_sa_account_id=\"csi-spl-hub-$env\" max_instances=2 memory=\"1Gi\" service_name=\"csi-spl-$env-pdf\" timeout_seconds=120"
  [[ "$got" == "$want" ]] && pass "4. $env 031 tfvars: $want" || fail "4. $env 031 tfvars: got [$got], want [$want]"
  grep -qE '^min_instances' "$v" && fail "4. $env 031 tfvars set a minimum (it is the step's literal 0)" || pass "4. $env 031 tfvars set no minimum"
  url="$(yq -r '.env.hub.pdf.url // ""' "$CNF/$env.env.yaml")"
  [[ -n "$url" && "$url" != null ]] || url="$(yq -r '.env.hub.pdf.url // ""' "$CNF/all.env.yaml")"
  [[ "$url" == null ]] && url=""
  grep -qx "pdf_url                      = \"$url\"" "$CNF/$env/tf/030-cloud-run-hub.vars.tfvars" &&
    pass "4. $env 030 tfvars pdf_url = cnf hub.pdf.url ('$url')" || fail "4. $env 030 tfvars pdf_url is not cnf hub.pdf.url ('$url')"
  tmo="$(yq -r '.env.hub.pdf.timeout // ""' "$CNF/$env.env.yaml")"
  [[ -n "$tmo" && "$tmo" != null ]] || tmo="$(yq -r '.env.hub.pdf.timeout // ""' "$CNF/all.env.yaml")"
  [[ -n "$tmo" && "$tmo" != null ]] || tmo="120s"
  grep -qx "pdf_timeout                  = \"$tmo\"" "$CNF/$env/tf/030-cloud-run-hub.vars.tfvars" &&
    pass "4. $env 030 tfvars pdf_timeout = cnf hub.pdf.timeout ('$tmo')" || fail "4. $env 030 tfvars pdf_timeout is not cnf hub.pdf.timeout ('$tmo')"
done
f030="$TFD/030-cloud-run-hub/04-cloud-run-service.tf"
verdict "4. 030 passes SPOOL_PDF_URL and SPOOL_PDF_TIMEOUT only when pdf_url is set, via local.hub_env, both in its template hash" \
  "$(hub_env_gaps "$f030")"

# --- RED CONTROLS: each planted break is caught ----------------------------------
plant() { # <name> <sed expr> -> a copy of the step with the expr applied
  rm -rf "${T:?}/$1"; mkdir -p "$T/$1"; cp "$TFD/$STEP"/*.tf "$T/$1/"; sed -i -E "$2" "$T/$1"/*.tf
}
plant min1 's/^([[:space:]]*min_instance_count[[:space:]]*=[[:space:]]*)0[[:space:]]*$/\11/'
[[ -n "$(r1_scale "$T/min1")" ]] && pass "CONTROL min_instance_count = 1 is refused" || fail "CONTROL min_instance_count = 1 passed R1"
plant idle 's/^([[:space:]]*cpu_idle[[:space:]]*=[[:space:]]*)true/\1false/'
[[ -n "$(r1_scale "$T/idle")" ]] && pass "CONTROL cpu_idle = false is refused" || fail "CONTROL cpu_idle = false passed R1"
plant boost 's/^([[:space:]]*startup_cpu_boost[[:space:]]*=[[:space:]]*)false/\1true/'
[[ -n "$(r1_scale "$T/boost")" ]] && pass "CONTROL startup_cpu_boost = true is refused" || fail "CONTROL startup_cpu_boost = true passed R1"
plant pub 's/^([[:space:]]*member[[:space:]]*=[[:space:]]*).*$/\1"allUsers"/'
[[ -n "$(invokers "$T/pub")" ]] && pass "CONTROL an allUsers invoker is refused" || fail "CONTROL an allUsers invoker passed"
mkdir -p "$T/tf/099-warm"
cat >"$T/tf/099-warm/01-job.tf" <<'TF'
resource "google_cloud_scheduler_job" "keep_warm" {
  name     = "warm"
  schedule = "*/5 * * * *"
  http_target {
    uri = "https://${var.pdf_host}/render"
  }
}
TF
[[ -n "$(warmers "$T/tf" "$T/no-cnf")" ]] && pass "CONTROL a scheduler job pinging the renderer is refused" ||
  fail "CONTROL a planted keep-warm scheduler job passed"
sed -i 's/pdf_host/hub_host/; s|/render|/healthz|' "$T/tf/099-warm/01-job.tf"
[[ -z "$(warmers "$T/tf" "$T/no-cnf")" ]] && pass "CONTROL a scheduler job on another service is not the renderer's" ||
  fail "CONTROL a job on another service was taken for a renderer warmer"

cp "$f030" "$T/030-no-timeout.tf"
sed -i -E 's/, SPOOL_PDF_TIMEOUT = var\.pdf_timeout//' "$T/030-no-timeout.tf"
[[ -n "$(hub_env_gaps "$T/030-no-timeout.tf")" ]] && pass "CONTROL a 030 that passes no SPOOL_PDF_TIMEOUT is refused" ||
  fail "CONTROL a 030 without SPOOL_PDF_TIMEOUT passed"
cp "$f030" "$T/030-no-hash.tf"
sed -i -E '/^[[:space:]]*pdf_timeout += var\.pdf_timeout$/d' "$T/030-no-hash.tf"
[[ -n "$(hub_env_gaps "$T/030-no-hash.tf")" ]] && pass "CONTROL a 030 whose template hash misses pdf_timeout is refused" ||
  fail "CONTROL a 030 whose template hash misses pdf_timeout passed"

[[ $fails -eq 0 ]] && echo "PASS: all $(basename "$0") assertions" || { echo "FAIL: $fails"; exit 1; }
