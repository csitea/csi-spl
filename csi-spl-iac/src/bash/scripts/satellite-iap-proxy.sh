#!/usr/bin/env bash
#------------------------------------------------------------------------------
# satellite-iap-proxy.sh <project> <zone> <instance> <port>
#
# The ssh ProxyCommand of the satellite (spec 057): opens an IAP tunnel to
# <instance>:<port> on stdin/stdout, AS the project's SA from its key
# ($HOME/.gcp/.csi/key-<project>.json, or SATELLITE_SA_KEY), activated in a
# throwaway CLOUDSDK_CONFIG: the shared ~/.config/gcloud is never written and
# the owner account is never used (owner rule 2026-09-19).
#------------------------------------------------------------------------------
set -uo pipefail
proj=${1:?project} zone=${2:?zone} inst=${3:?instance} port=${4:-22}
key="${SATELLITE_SA_KEY:-$HOME/.gcp/.csi/key-${proj}.json}"
[[ -r "$key" ]] || { echo "satellite-iap-proxy: no SA key $key" >&2; exit 1; }
CLOUDSDK_CONFIG=$(mktemp -d) || exit 1
export CLOUDSDK_CONFIG
trap 'rm -rf "$CLOUDSDK_CONFIG"' EXIT
gcloud auth activate-service-account --key-file="$key" --quiet >/dev/null 2>&1 \
  || { echo "satellite-iap-proxy: cannot activate $key" >&2; exit 1; }
account=$(jq -r .client_email "$key")
gcloud compute start-iap-tunnel "$inst" "$port" --listen-on-stdin \
  --zone="$zone" --project="$proj" --account="$account" --verbosity=warning
