#!/usr/bin/env bash
# Pack action: providers, metadata names, archive, and sha256. Red controls
# plant a forbidden provider and drop a metadata variable.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
FUNC="$ROOT/csi-spl-iac/src/bash/run/marketplace-pack.func.sh"
MOD="$ROOT/csi-spl-iac/src/terraform/marketplace-spool-vm"
PIN='ghcr.io/csitea/spool-hub:stable-2026-10-12@sha256:ccdee0eb22cdfa6d0f5380dfd4f5f9df4c90634bf0c6f01fc2bf200a0d5347e6'
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run_pack() {
  local src out
  src="$1"
  out="$2"
  mkdir -p "$out"
  bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$1"
    export MARKETPLACE_PACK_SRC="$2"
    export MARKETPLACE_PACK_OUT="$3"
    do_marketplace_pack
  ' bash "$FUNC" "$src" "$out"
}

copy_mod() {
  local dest
  dest="$1"
  mkdir -p "$dest"
  cp "$MOD/main.tf" "$MOD/variables.tf" "$MOD/outputs.tf" "$MOD/versions.tf" \
    "$MOD/metadata.yaml" "$MOD/metadata.display.yaml" "$MOD/marketplace_test.tfvars" \
    "$dest/"
}

if grep -qF "$PIN" "$MOD/variables.tf" && grep -qF 'var.spool_hub_image' "$MOD/main.tf"; then
  pass "hub image pin is the named digest and main.tf references it"
else
  fail "hub image pin"
fi

img_marks=$(grep -c 'ET_GCE_DISK_IMAGE' "$MOD/metadata.display.yaml" || true)
if [[ "$img_marks" == 1 ]]; then
  pass "boot disk image is the only GCE image property"
else
  fail "ET_GCE_DISK_IMAGE count is ${img_marks}"
fi

if awk '
  $0 ~ /- name: / {
    if (cur != "" && req != 1 && (cur == "project_id" || cur == "goog_cm_deployment_name")) miss = 1
    if (cur != "" && req == 1 && cur != "project_id" && cur != "goog_cm_deployment_name") extra = 1
    cur = $3
    req = 0
  }
  $0 ~ /required: true/ { req = 1 }
  END {
    if (cur == "project_id" || cur == "goog_cm_deployment_name") { if (req != 1) miss = 1 }
    else if (req == 1) extra = 1
    if (miss || extra) exit 1
  }
' "$MOD/metadata.yaml"; then
  pass "only project_id and goog_cm_deployment_name are required"
else
  fail "metadata required flags"
fi

if awk '
  /- name: boot_disk_size_gb/ { hit = 1; next }
  hit && /varType:/ { if ($2 != "number") exit 1; found = 1; exit 0 }
  END { if (!found) exit 1 }
' "$MOD/metadata.yaml"; then
  pass "boot_disk_size_gb varType is number"
else
  fail "boot_disk_size_gb varType"
fi

copy_mod "$T/badprov"
printf '\nsource = "hashicorp/local"\n' >>"$T/badprov/versions.tf"
if run_pack "$T/badprov" "$T/out-badprov" >"$T/badprov.out"; then
  fail "RED local provider should fail"
else
  pass "RED provider hashicorp/local"
fi

copy_mod "$T/badmeta"
grep -v -- '- name: project_id' "$MOD/metadata.yaml" >"$T/badmeta/metadata.yaml"
if run_pack "$T/badmeta" "$T/out-badmeta" >"$T/badmeta.out"; then
  fail "RED dropped project_id should fail"
else
  pass "RED metadata missing project_id"
fi

if out=$(run_pack "$MOD" "$T/green"); then
  pass "GREEN pack of the real module"
else
  fail "GREEN pack of the real module"
  printf '%s\n' "$out"
fi
hash=$(printf '%s\n' "$out" | awk '/^[0-9a-f]{64}$/ { h = $0 } END { print h }')
archive="$T/green/marketplace-spool-vm.tar.gz"
if [[ -f "$archive" && -n "$hash" ]]; then
  pass "archive and sha256 printed"
else
  fail "archive or sha256 missing"
fi
if (cd "$T/green" && sha256sum -c marketplace-spool-vm.tar.gz.sha256); then
  pass "sha256sum -c"
else
  fail "sha256sum -c"
fi
listed=$(tar -tzf "$archive" | sort | tr '\n' ' ')
want='main.tf marketplace_test.tfvars metadata.display.yaml metadata.yaml outputs.tf variables.tf versions.tf '
if [[ "$listed" == "$want" ]]; then
  pass "archive holds the seven module files"
else
  fail "archive listing: ${listed}"
fi

[[ "$fails" -eq 0 ]] && printf 'PASS: all %s assertions\n' "$(basename "$0")"
exit "$fails"
