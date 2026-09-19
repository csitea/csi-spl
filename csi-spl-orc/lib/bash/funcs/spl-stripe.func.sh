#!/bin/bash
#------------------------------------------------------------------------------
# Shared by the payment actions (spec 006 T022): do_spl_payment_secret_seed
# and do_spl_provision_stripe_endpoints. Owner key files follow csi-rel's
# layout, as $HOME/.stripe/.<org>/.<app>/stripe-<env>.env. Values never reach
# argv, stdout or a log: they live in 0600 files under a 0700 scratch dir.
#------------------------------------------------------------------------------

# spl_stripe_key_dir <org> <app> -> sets SPL_STRIPE_KEY_DIR and
# SPL_STRIPE_SHARED (1 when the keys are another app's). STRIPE_KEY_APP=<app>
# reads that app's files in place ($HOME/.stripe/.<org>/.<app>/, e.g. rel =
# csi-rel's account; no key file is copied) and is refused without
# STRIPE_SHARED_ACCOUNT_OK=1, the owner's explicit go. Default: our own app.
spl_stripe_key_dir() {
  local org="$1" app="$2" key_app="${STRIPE_KEY_APP:-$2}"
  [[ "$key_app" =~ ^[a-z]{3}$ ]] || { do_log "FATAL STRIPE_KEY_APP '$key_app' is not a 3-letter app code"; return 1; }
  SPL_STRIPE_KEY_DIR="$HOME/.stripe/.$org/.$key_app" SPL_STRIPE_SHARED=0
  if [[ "$key_app" != "$app" ]]; then
    [[ "${STRIPE_SHARED_ACCOUNT_OK:-0}" == 1 ]] ||
      { do_log "FATAL STRIPE_KEY_APP=$key_app is another app's Stripe account: needs the owner's go (STRIPE_SHARED_ACCOUNT_OK=1)"; return 1; }
    SPL_STRIPE_SHARED=1
    do_log "WARN using $org-$key_app's Stripe account keys from $SPL_STRIPE_KEY_DIR (STRIPE_SHARED_ACCOUNT_OK=1)"
  fi
}

# spl_stripe_owner_file <path> -> refuses a missing file or one group/other
# can touch (0600; csi-rel's own files are 0700, which is as private)
spl_stripe_owner_file() {
  [[ -s "$1" ]] || { do_log "FATAL no owner key file at $1 (0600)"; return 1; }
  (( (8#$(stat -c %a "$1") & 8#077) == 0 )) || { do_log "FATAL $1 must be owner-only (mode 0600)"; return 1; }
}

# spl_stripe_env_get <file> <NAME> -> the value of NAME=... (export, quotes
# and CR stripped). The file is PARSED, never sourced.
spl_stripe_env_get() {
  local line v=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"; line="${line#export }"
    [[ "$line" == "$2="* ]] || continue
    v="${line#"$2"=}"; v="${v#[\"\']}"; v="${v%[\"\']}"
  done <"$1"
  printf '%s' "$v"
}

# spl_stripe_load_secret_key <envf> <out-file> <env> -> writes the checked
# secret key to <out-file> (0600) and sets SPL_STRIPE_MODE. csi-rel's layout:
# the dedicated key file .<env>-stripe-secret-key next to <envf> wins; the
# STRIPE_SECRET_KEY of <envf> is the fallback (csi-rel keeps that one EMPTY on
# prd, so no accidental run pushes the live key).
# dev takes test keys only, prd live keys only (csi-rel's rule). Shared-account
# guard: the same key in another app's dir ($HOME/.stripe/.<org>/.*/) is
# refused unless STRIPE_SHARED_ACCOUNT_OK=1 (the owner's explicit go).
spl_stripe_load_secret_key() {
  local envf="$1" out="$2" env_name="$3" want=test
  [[ "$env_name" == prd ]] && want=live
  local kf
  kf="$(dirname "$envf")/.$env_name-stripe-secret-key"
  if [[ -s "$kf" ]]; then
    spl_stripe_owner_file "$kf" || return 1
    (umask 077 && tr -d '\r\n' <"$kf" >"$out") || return 1
    envf="$kf"
  else
    spl_stripe_owner_file "$envf" || return 1
    (umask 077 && spl_stripe_env_get "$envf" STRIPE_SECRET_KEY >"$out") || return 1
  fi
  SPL_STRIPE_MODE=""
  case "$(head -c 8 "$out")" in
    sk_test_|rk_test_) SPL_STRIPE_MODE=test ;;
    sk_live_|rk_live_) SPL_STRIPE_MODE=live ;;
  esac
  [[ -n "$SPL_STRIPE_MODE" && "$(wc -c <"$out")" -gt 8 ]] ||
    { do_log "FATAL STRIPE_SECRET_KEY in $envf is unset or not sk_/rk_ test|live shaped"; return 1; }
  [[ "$SPL_STRIPE_MODE" == "$want" ]] ||
    { do_log "FATAL $env_name takes a $want-mode secret key; $envf holds a $SPL_STRIPE_MODE-mode one"; return 1; }

  local sdir org_dir sha other shared=""
  sdir="$(dirname "$envf")" org_dir="$(dirname "$(dirname "$envf")")"
  sha="$(sha256sum <"$out" | cut -d' ' -f1)"
  shopt -s nullglob
  for other in "$org_dir"/.*/stripe-*.env; do
    [[ "$(dirname "$other")" == "$sdir" || ! -r "$other" ]] && continue
    [[ "$(spl_stripe_env_get "$other" STRIPE_SECRET_KEY | sha256sum | cut -d' ' -f1)" == "$sha" ]] && shared="$other"
  done
  shopt -u nullglob
  if [[ -n "$shared" ]]; then
    [[ "${STRIPE_SHARED_ACCOUNT_OK:-0}" == 1 ]] ||
      { do_log "FATAL the secret key in $envf is the one in $shared: another app's Stripe account needs the owner's go (STRIPE_SHARED_ACCOUNT_OK=1)"; return 1; }
    do_log "WARN the secret key is shared with $shared (STRIPE_SHARED_ACCOUNT_OK=1)"
  fi
}

# spl_secret_put <slot> <value-file> <dry 0|1> -> adds <value-file> as a new
# version of <slot> only when it differs from the latest (sha256), then
# verifies it. Needs SPL_PROJECT and a pinned GCP_ACCOUNT. The value goes on
# stdin (--data-file=-).
spl_secret_put() {
  local slot="$1" f="$2" dry="$3" want have
  gcloud secrets describe "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { do_log "ERROR no slot $slot in $SPL_PROJECT (030 creates it)"; return 1; }
  want="$(sha256sum <"$f" | cut -d' ' -f1)"
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  if [[ "$have" == "$want" ]]; then
    do_log "INFO $slot already holds this value: nothing to add"
    return 0
  fi
  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN would add a version to $slot in $SPL_PROJECT"
    return 0
  fi
  gcloud secrets versions add "$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- <"$f" >/dev/null 2>&1 ||
    { do_log "ERROR could not add a version to $slot"; return 1; }
  have="$(gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [[ "$have" == "$want" ]] || { do_log "ERROR $slot latest version does not match its source (sha256)"; return 1; }
  do_log "INFO $slot: version added and verified by sha256 (value not logged)"
}
