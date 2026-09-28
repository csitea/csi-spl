#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: render csi-spl-wui/firebase.json from cnf for a deploy. Site id,
#          Cloud Run service id and region come from the env yaml — never a
#          hostname literal in this script (domain-single-source).
#
#          The Content-Security-Policy is built from the GENERATED bundle
#          (spec 017 FR-SEC-005, T013/T014): run it after `nuxt generate`.
#
# Usage:
#   ENV=dev ./render-wui-firebase-json.sh
#   ENV=prd OUT=/path/to/firebase.json PUBLIC_DIR=/path/.output/public ./render-wui-firebase-json.sh
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
FQDN=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["env"]["dns"]["fqdn"])' "$CNF")
[[ -n "$FQDN" ]] || { echo "FATAL env.dns.fqdn is empty in $CNF" >&2; exit 1; }
OUT="${OUT:-$ROOT/csi-spl-wui/firebase.json}"
# the generated bundle the CSP hashes are taken from (never guessed)
PUBLIC_DIR="${PUBLIC_DIR:-$ROOT/csi-spl-wui/.output/public}"
[[ -f "$PUBLIC_DIR/200.html" ]] || { echo "FATAL no generated bundle at $PUBLIC_DIR (200.html missing) — run nuxt generate first; the CSP hashes come from it" >&2; exit 1; }

# Spec 007 §3 (T072): the WUI is served same-origin THROUGH the 031 load
# balancer (<fqdn>, <tenant>.<fqdn>), which sends /v1/*, /api/*, /healthz and
# /version to the hub before Firebase ever sees them. The run rewrites below
# therefore only act on the bare <site>.web.app host (and 010 T016 keeps the
# auth one). connect-src admits the tenant hosts: a page on <fqdn> reads and
# opens its WebSocket on <tenant>.<fqdn> (NUXT_PUBLIC_API_BASE).
python3 - "$OUT" "$SITE_ID" "$SERVICE" "$REGION" "$FQDN" "$CNF" "$PUBLIC_DIR" <<'PY'
import base64, glob, hashlib, json, os, re, sys
out, site_id, service, region, fqdn, cnf, public_dir = sys.argv[1:8]

# ── Content-Security-Policy (spec 017 FR-SEC-005, T013/T014) ─────────────────
# This header is the ONLY CSP a browser sees in a deployed env: the WUI is
# static files on Firebase Hosting, so nuxt.config.ts routeRules never run.
#
# script-src / style-src: 'self' plus the sha256 of every inline block the
# generated bundle contains, and nothing else. No nonce is possible (no server
# in the response path), and a hash list works here where csi-rel could not
# use one: the spool WUI prerenders a handful of shells whose only executable
# inline script is Nuxt's `window.__NUXT__.config` (measured on `nuxt
# generate` 2026-09-19: one 997-byte script, identical in all 4 html files).
# Its bytes change with runtimeConfig (env, tenant, version, build id), which
# is why the hashes are taken from THIS build and never written down.
# Scripts with a non-JavaScript type (`application/json` payload / unhead data
# blocks) are not executed, so they need no hash. <style> blocks are Vue SFC
# styles Nuxt inlines into the prerendered html; they are hashed the same way.
JS_TYPES = {"", "module", "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript"}
SCRIPT_RE = re.compile(r"<script\b([^>]*)>(.*?)</script>", re.S | re.I)
STYLE_RE = re.compile(r"<style\b[^>]*>(.*?)</style>", re.S | re.I)
TYPE_RE = re.compile(r"""\btype\s*=\s*["']?([^"'\s>]+)""", re.I)
SRC_RE = re.compile(r"\bsrc\s*=", re.I)


def sha(text):
    return "'sha256-" + base64.b64encode(hashlib.sha256(text.encode("utf-8")).digest()).decode() + "'"


script_hashes, style_hashes, pages = set(), set(), 0
for path in sorted(glob.glob(os.path.join(public_dir, "**", "*.html"), recursive=True)):
    pages += 1
    html = open(path, encoding="utf-8").read()
    for attrs, body in SCRIPT_RE.findall(html):
        if SRC_RE.search(attrs):
            continue
        t = TYPE_RE.search(attrs)
        if (t.group(1).lower() if t else "") in JS_TYPES:
            script_hashes.add(sha(body))
    for body in STYLE_RE.findall(html):
        style_hashes.add(sha(body))
    # Attributes a hash can never allow: an inline event handler (on*=) or a
    # style="" attribute would be blocked in the browser, so refuse here
    # instead of shipping a page that logs violations.
    markup = STYLE_RE.sub("", SCRIPT_RE.sub("", html))
    bad = re.search(r"<[a-zA-Z][^>]*?\s(on[a-z]+|style)\s*=", markup)
    if bad:
        sys.exit("FATAL " + path + ": inline " + bad.group(1) + "= attribute; the CSP has no 'unsafe-inline' to allow it — fix the page")
if not pages:
    sys.exit("FATAL no html under " + public_dir)

# connect-src: 'self' plus the hub hosts from cnf, each over https and wss.
#   * the api host: env.dns.api_fqdn (the 032 Cloud Run domain mapping, no
#     LB), plus any 031 extra_host_labels as <label>.<BASE_DOMAIN>.
#     dev.api.<domain> is OUTSIDE *.dev.<domain>, so each is listed on its own.
#     A missing api_fqdn is fatal: without it the WUI cannot reach auth.
#   * the tenant hosts <tenant>.<fqdn>: only what env.dns.mapped_tenants
#     enumerates (each one has its own domain mapping). Empty = none: since
#     spec 026 the WUI talks to the one api host (NUXT_PUBLIC_API_BASE =
#     https://<api_fqdn>), so the old *.<fqdn> fallback only widened where an
#     injected script could post (CLE-34987) — never a wildcard.
# Never a bare scheme (`https:` would admit every host and make it a no-op).
env = json.load(open(cnf))["env"]
base = env["dns"]["BASE_DOMAIN"]
steps = env.get("steps", {})
api_fqdn = env["dns"].get("api_fqdn", "")
if not api_fqdn:
    sys.exit("FATAL env.dns.api_fqdn is empty in " + cnf + ": connect-src would omit the hub api host")
labels = list(steps.get("031-gcp-hub-ingress", {}).get("extra_host_labels", []) or [])
hosts = [api_fqdn] + [l + "." + base for l in labels if l]
tenants = env["dns"].get("mapped_tenants")
hosts += [t + "." + fqdn for t in (tenants or [])]
connect = ["'self'"]
for h in dict.fromkeys(hosts):
    connect += ["https://" + h, "wss://" + h]

# The card step (006 T021w): the card vendor's SDK, its iframes and its API,
# ONLY as cnf env.payment.wui_csp lists them for this env ({script, frame,
# connect}: absolute https origins, no path; a wildcard only as the leftmost
# label under a named domain, e.g. https://*.<vendor-domain>). Empty = no card
# rail on this env's WUI, and the policy is exactly what it was without it.
card = (env.get("payment") or {}).get("wui_csp") or {}
ORIGIN_RE = re.compile(r"^https://(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
def card_sources(kind):
    out = []
    for o in card.get(kind) or []:
        if not isinstance(o, str) or not ORIGIN_RE.match(o):
            sys.exit("FATAL env.payment.wui_csp." + kind + " entry " + repr(o) + " is not an absolute https origin (no bare wildcard, scheme or path)")
        out.append(o)
    return list(dict.fromkeys(out))
card_script, card_frame, card_connect = card_sources("script"), card_sources("frame"), card_sources("connect")
connect += card_connect

csp = "; ".join([
    "default-src 'self'",
    " ".join(["script-src 'self'"] + sorted(script_hashes) + card_script),
    " ".join(["style-src 'self'"] + sorted(style_hashes)),
    "img-src 'self' data:",
    "font-src 'self' data:",
    "connect-src " + " ".join(connect),
    " ".join(["frame-src 'self'"] + card_frame),
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
])
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
            "value": csp,
          },
          {"key": "X-Robots-Tag", "value": "noindex, nofollow"},
          {"key": "Cache-Control", "value": "public, max-age=0, must-revalidate"},
        ],
      },
      # Unhashed static media (logo, login wallpapers, icons, the manifest):
      # under `**` alone every reload revalidated each one, a full round trip
      # for a 304 (CLE-35076, prd /login warm reload: 7 of 10 round trips).
      # One hour fresh, then served from cache while it revalidates in the
      # background: a replaced picture shows within the hour. Before the
      # _nuxt rule, so a hashed /_nuxt/ image keeps `immutable` (the later
      # matching rule wins).
      {
        "source": "**/*.@(avif|webp|png|jpg|jpeg|gif|svg|ico|woff2|webmanifest)",
        "headers": [{"key": "Cache-Control", "value": "public, max-age=3600, stale-while-revalidate=86400"}],
      },
      {
        "source": "**/_nuxt/**",
        "headers": [{"key": "Cache-Control", "value": "public, max-age=31536000, immutable"}],
      },
      # Nuxt's app manifest pointer names the CURRENT build under a fixed
      # URL, so it must never be `immutable` like the rest of /_nuxt/.
      {
        "source": "/_nuxt/builds/latest.json",
        "headers": [{"key": "Cache-Control", "value": "public, max-age=0, must-revalidate"}],
      },
    ],
    "rewrites": [
      {"source": "/healthz", "run": {"serviceId": service, "region": region}},
      {"source": "/version", "run": {"serviceId": service, "region": region}},
      {"source": "/v1/**", "run": {"serviceId": service, "region": region}},
      # spec 010 auth-v1 §1: social sign-in is same-origin under /api/v1/auth/
      {"source": "/api/v1/auth/**", "run": {"serviceId": service, "region": region}},
      # spec 006 checkout-v1 §1 (the bare prefix for POST /api/v1/checkout)
      {"source": "/api/v1/checkout", "run": {"serviceId": service, "region": region}},
      {"source": "/api/v1/checkout/**", "run": {"serviceId": service, "region": region}},
      {"source": "**", "destination": "/200.html"},
    ],
  }
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(out)
PY
