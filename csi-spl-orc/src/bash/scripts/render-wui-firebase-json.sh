#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: render csi-spl-wui/firebase.json from cnf for a deploy. Site id,
#          Cloud Run service id and region come from the env yaml — never a
#          hostname literal in this script (domain-single-source).
#
# Usage:
#   ENV=dev ./render-wui-firebase-json.sh
#   ENV=prd OUT=/path/to/firebase.json ./render-wui-firebase-json.sh
#------------------------------------------------------------------------------
set -euo pipefail
: "${ENV:?ENV must be set (dev or prd)}"
[[ "$ENV" == dev || "$ENV" == prd ]] || { echo "FATAL ENV must be dev or prd" >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
CNF="$ROOT/csi-spl-cnf/csi-spl/${ENV}.env.json"
[[ -f "$CNF" ]] || { echo "FATAL missing $CNF — run ENV=$ENV ./run -a do_tpl_gen in csi-spl-iac" >&2; exit 1; }

SITE_ID=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["env"]["steps"]["019-firebase-static-site"]["site_id"])' "$CNF")
SERVICE=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["env"]["hub"]["service_name"])' "$CNF")
REGION=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["env"]["gcp"]["gcp_region"])' "$CNF")
OUT="${OUT:-$ROOT/csi-spl-wui/firebase.json}"

python3 - "$OUT" "$SITE_ID" "$SERVICE" "$REGION" <<'PY'
import json, sys
out, site_id, service, region = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
doc = {
  "hosting": {
    "site": site_id,
    "public": ".output/public",
    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
    "cleanUrls": True,
    "trailingSlash": False,
    "headers": [
      {
        "source": "**",
        "headers": [
          {"key": "X-Frame-Options", "value": "DENY"},
          {"key": "X-Content-Type-Options", "value": "nosniff"},
          {"key": "Referrer-Policy", "value": "strict-origin-when-cross-origin"},
          {"key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=()"},
          {"key": "Strict-Transport-Security", "value": "max-age=31536000; includeSubDomains; preload"},
          {
            "key": "Content-Security-Policy",
            "value": "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'",
          },
          {"key": "X-Robots-Tag", "value": "noindex, nofollow"},
          {"key": "Cache-Control", "value": "public, max-age=0, must-revalidate"},
        ],
      },
      {
        "source": "**/_nuxt/**",
        "headers": [{"key": "Cache-Control", "value": "public, max-age=31536000, immutable"}],
      },
    ],
    "rewrites": [
      {"source": "/healthz", "run": {"serviceId": service, "region": region}},
      {"source": "/version", "run": {"serviceId": service, "region": region}},
      {"source": "/v1/**", "run": {"serviceId": service, "region": region}},
      # spec 010 auth-v1 §1: social sign-in is same-origin under /api/v1/auth/
      {"source": "/api/v1/auth/**", "run": {"serviceId": service, "region": region}},
      {"source": "**", "destination": "/200.html"},
    ],
  }
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(out)
PY
