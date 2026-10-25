#!/bin/bash
#------------------------------------------------------------------------------
# @description Pack the customer Marketplace VM module into a tar.gz, check its
# @description providers and blueprint metadata, and print the archive path and
# @description sha256. Writes only under MARKETPLACE_PACK_OUT or a new temp dir.
# @param MARKETPLACE_PACK_SRC (optional) - module directory.
# @param MARKETPLACE_PACK_OUT (optional) - output directory.
# @example MARKETPLACE_PACK_OUT=/tmp/out ./run -a do_marketplace_pack
#------------------------------------------------------------------------------

_mkt_pack_src() {
  if [[ -n "${MARKETPLACE_PACK_SRC:-}" ]]; then
    printf '%s\n' "${MARKETPLACE_PACK_SRC}"
    return 0
  fi
  if [[ -n "${APP_PATH:-}" && -d "${APP_PATH}/csi-spl-iac/src/terraform/marketplace-spool-vm" ]]; then
    printf '%s\n' "${APP_PATH}/csi-spl-iac/src/terraform/marketplace-spool-vm"
    return 0
  fi
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
  printf '%s\n' "${here}/csi-spl-iac/src/terraform/marketplace-spool-vm"
}

_mkt_pack_need_files() {
  local src name
  src="$1"
  for name in main.tf variables.tf outputs.tf versions.tf metadata.yaml metadata.display.yaml marketplace_test.tfvars; do
    if [[ ! -f "${src}/${name}" ]]; then
      do_log "FATAL missing ${name} in ${src}"
      return 1
    fi
  done
  return 0
}

_mkt_allow_provider() {
  case "$1" in
    google|google-beta|random|null|time|tls) return 0 ;;
    *) return 1 ;;
  esac
}

_mkt_pack_providers() {
  local src f hits line name seen bad
  src="$1"
  seen=0
  bad=0
  for f in "${src}"/*.tf; do
    [[ -f "$f" ]] || continue
    hits=$(grep -oE 'source[[:space:]]*=[[:space:]]*"hashicorp/[^"]+"' "$f" || true)
    [[ -n "$hits" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      name=$(printf '%s\n' "$line" | sed -E 's/.*"hashicorp\/([^"]+)".*/\1/')
      seen=1
      if ! _mkt_allow_provider "$name"; then
        do_log "FATAL provider not allowed: ${name} in ${f}"
        bad=1
      fi
    done <<<"$hits"
  done
  if [[ "$seen" -eq 0 ]]; then
    do_log "FATAL no terraform provider declaration"
    return 1
  fi
  [[ "$bad" -eq 0 ]] || return 1
  return 0
}

_mkt_pack_header() {
  local file label
  file="$1"
  label="$2"
  if ! grep -q 'apiVersion:[[:space:]]*blueprints.cloud.google.com/v1alpha1' "$file"; then
    do_log "FATAL ${label} apiVersion"
    return 1
  fi
  if ! grep -q 'kind:[[:space:]]*BlueprintMetadata' "$file"; then
    do_log "FATAL ${label} kind"
    return 1
  fi
  if ! grep -q 'config.kubernetes.io/local-config:[[:space:]]*"true"' "$file"; then
    do_log "FATAL ${label} local-config"
    return 1
  fi
  return 0
}

_mkt_pack_listed() {
  local hcl meta kind name
  hcl="$1"
  meta="$2"
  kind="$3"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! grep -qE "^[[:space:]]*- name: ${name}[[:space:]]*$" "$meta"; then
      do_log "FATAL metadata missing ${kind} ${name}"
      return 1
    fi
  done < <(awk -v k="$kind" '$0 ~ "^" k "[[:space:]]+\"" { n = $2; gsub(/"/, "", n); print n }' "$hcl")
  return 0
}

_mkt_pack_pin() {
  local src pin
  src="$1"
  pin='ghcr.io/csitea/spool-hub:stable-2026-10-12@sha256:ccdee0eb22cdfa6d0f5380dfd4f5f9df4c90634bf0c6f01fc2bf200a0d5347e6'
  if ! grep -qF "$pin" "${src}/variables.tf"; then
    do_log "FATAL spool hub image pin missing"
    return 1
  fi
  if ! grep -qF 'var.spool_hub_image' "${src}/main.tf"; then
    do_log "FATAL main.tf does not reference var.spool_hub_image"
    return 1
  fi
  return 0
}

_mkt_pack_schema() {
  local src
  src="$1"
  if ! _mkt_pack_header "${src}/metadata.yaml" metadata; then
    return 1
  fi
  if ! _mkt_pack_header "${src}/metadata.display.yaml" display; then
    return 1
  fi
  if ! _mkt_pack_listed "${src}/variables.tf" "${src}/metadata.yaml" variable; then
    return 1
  fi
  if ! _mkt_pack_listed "${src}/outputs.tf" "${src}/metadata.yaml" output; then
    return 1
  fi
  if ! grep -qF 'xGoogleProperty: ET_GCE_DISK_IMAGE' "${src}/metadata.display.yaml"; then
    do_log "FATAL display metadata missing boot disk image property"
    return 1
  fi
  return 0
}

_mkt_pack_archive() {
  local src out archive hash base
  src="$1"
  if [[ -n "${MARKETPLACE_PACK_OUT:-}" ]]; then
    out="${MARKETPLACE_PACK_OUT}"
    mkdir -p "$out" || return 1
  else
    out=$(mktemp -d)
  fi
  archive="${out}/marketplace-spool-vm.tar.gz"
  tar -C "$src" -czf "$archive" \
    main.tf variables.tf outputs.tf versions.tf \
    metadata.yaml metadata.display.yaml marketplace_test.tfvars || return 1
  hash=$(sha256sum "$archive" | awk '{print $1}')
  if [[ -z "$hash" ]]; then
    do_log "FATAL sha256 failed"
    return 1
  fi
  base=$(basename "$archive")
  printf '%s  %s\n' "$hash" "$base" > "${out}/${base}.sha256"
  do_log "OK pack ${archive}"
  printf '%s\n' "$archive"
  printf '%s\n' "$hash"
  return 0
}

do_marketplace_pack() {
  local src
  src=$(_mkt_pack_src) || return 1
  if ! _mkt_pack_need_files "$src"; then
    return 1
  fi
  if ! _mkt_pack_providers "$src"; then
    return 1
  fi
  if ! _mkt_pack_pin "$src"; then
    return 1
  fi
  if ! _mkt_pack_schema "$src"; then
    return 1
  fi
  if ! _mkt_pack_archive "$src"; then
    return 1
  fi
  return 0
}
