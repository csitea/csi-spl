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

# Four values, one python3: re-parsing the same JSON in four separate spawns
# was ~82 ms; one read that prints all four is ~25 ms. Command substitution
# (not process substitution) keeps set -e fail-fast on a missing key. Order
# matches the reads below.
_CNF_VALS=$(python3 - "$CNF" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["env"]
print(e["steps"]["019-firebase-static-site"]["site_id"])
print(e["hub"]["service_name"])
print(e["gcp"]["gcp_region"])
print(e["dns"]["fqdn"])
PY
)
{ IFS= read -r SITE_ID; IFS= read -r SERVICE; IFS= read -r REGION; IFS= read -r FQDN; } <<<"$_CNF_VALS"
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
import base64, glob, hashlib, json, os, re, shutil, sys
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


# ── Root locale at the edge (perf round 4 W10, round-3 P3-28) ──────────────
# Firebase Hosting i18n answers `/` from <root>/<code>_ALL/index.html, picked
# by the firebase-language-override cookie, else by Accept-Language, so a
# non-default browser gets its prerendered `/<code>` page in ONE document
# instead of `/` + a head `location.replace`. Staged here from THIS build:
# every `<code>/index.html` whose <html lang> is <code>, plus the root page
# under its own lang (an "en-US, fi" browser must still get en at `/`). The
# head script (src/utils/rootLocaleRedirect.mjs) renames the URL to `/<code>`
# and keeps the cookie choice above Accept-Language.
I18N_ROOT = "localized-files"
LANG_RE = re.compile(r"""<html\b[^>]*?\slang\s*=\s*["']?([A-Za-z]+)""", re.I)


def page_lang(path):
    m = LANG_RE.search(open(path, encoding="utf-8").read(4096))
    return m.group(1).lower() if m else ""


loc_dir = os.path.join(public_dir, I18N_ROOT)
shutil.rmtree(loc_dir, ignore_errors=True)
localized = {}
for d in sorted(os.listdir(public_dir)):
    src = os.path.join(public_dir, d, "index.html")
    if re.fullmatch(r"[a-z]{2,3}", d) and os.path.isfile(src) and page_lang(src) == d:
        localized[d] = src
root_page = os.path.join(public_dir, "index.html")
root_lang = page_lang(root_page) if os.path.isfile(root_page) else ""
if localized and root_lang and root_lang not in localized:
    localized[root_lang] = root_page
for code, src in localized.items():
    os.makedirs(os.path.join(loc_dir, code + "_ALL"))
    shutil.copyfile(src, os.path.join(loc_dir, code + "_ALL", "index.html"))


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

# ── /blog/** pages (spec 111 T002, 4.2) ─────────────────────────────────────
# CSP is no backstop for the blog: the loop above hashes EVERY inline script
# into script-src, so a <script> that reached a post page would be allowed and
# run on the app origin. So a /blog/** page (and /<lang>/blog/**) may hold only
# the executable inline scripts the app shell (200.html) holds and /_nuxt/
# script files, and - script and style elements aside, entities decoded, as
# sync-blog.mjs --check reads a fragment - no `<script`, `on*=`, or
# javascript: / vbscript: / data: URL anywhere, even as text.
import html as htmllib
BLOG_RE = re.compile(r"(?:[a-z]{2,3}/)?blog(?:/|\.html$)")
BLOG_BANS = [
    (re.compile(r"<\s*script", re.I), "<script"),
    (re.compile(r"\bon[a-z]+\s*=", re.I), "an on*= attribute"),
    (re.compile(r"\b(?:javascript|vbscript)\s*:", re.I), "a javascript: URL"),
    (re.compile(r"\bdata\s*:(?!\s)", re.I), "a data: URL"),
]


def inline_js(page):
    out = []
    for attrs, body in SCRIPT_RE.findall(page):
        t = TYPE_RE.search(attrs)
        if not SRC_RE.search(attrs) and (t.group(1).lower() if t else "") in JS_TYPES:
            out.append(body)
    return out


shell_js = set(inline_js(open(os.path.join(public_dir, "200.html"), encoding="utf-8").read()))
for path in sorted(glob.glob(os.path.join(public_dir, "**", "*.html"), recursive=True)):
    rel = os.path.relpath(path, public_dir).replace(os.sep, "/")
    if not BLOG_RE.match(rel):
        continue
    page = open(path, encoding="utf-8").read()
    if any(body not in shell_js for body in inline_js(page)):
        sys.exit("FATAL " + path + ": a /blog/** page holds an inline <script> the app shell (200.html) does not - refused, its hash would be allowed")
    for attrs, _ in SCRIPT_RE.findall(page):
        m = re.search(r"""\bsrc\s*=\s*["']?([^"'\s>]*)""", attrs, re.I)
        if m and not m.group(1).startswith("/_nuxt/"):
            sys.exit("FATAL " + path + ": a /blog/** page loads a script outside /_nuxt/ - refused")
    text = STYLE_RE.sub("", SCRIPT_RE.sub("", page))
    for _ in range(4):
        text = htmllib.unescape(text)
    text = re.sub(r"[\x00-\x08\x0b-\x1f]", "", text)
    for rx, why in BLOG_BANS:
        if rx.search(text):
            sys.exit("FATAL " + path + ": a /blog/** page holds " + why + " - refused (spec 111 4.2)")

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
# spec 116 T7: the public pages' served X-Robots-Tag (the WUI's
# src/utils/public-seo.mjs is the same list; nuxt generate checks the meta)
seo_index = bool((env.get("wui") or {}).get("seo_index"))
SEO_PUBLIC_SOURCES = ("**/blog", "**/blog/**", "/login", "/*/login", "/help", "/help/**")
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
    **({"i18n": {"root": "/" + I18N_ROOT}} if localized else {}),
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
      # spec 111 3.1 + spec 116 T7: the public pages (the blog, /login, /help)
      # are indexable, every locale copy too, on an env with cnf
      # env.wui.seo_index (prd); elsewhere `**`'s noindex stands. After `**`,
      # so it replaces that rule's noindex for these paths. A header matches
      # the path on any host: the pages' canonical names the apex.
      *[{"source": src, "headers": [{"key": "X-Robots-Tag", "value": "index, follow"}]}
        for src in (SEO_PUBLIC_SOURCES if seo_index else ())],
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
      # CLE-77803: an old tab still on the previous deploy asks for its own
      # build's app manifest (/_nuxt/builds/meta/<old-id>.json). That build's
      # files are gone, so without this the request falls to the SPA catch-all
      # below and gets 200 index HTML; Nuxt then parses HTML as its manifest and
      # logs "Received malformed app manifest" (prd human_events 2026-09-30).
      # Firebase rewrites are first-match-wins and terminal, and a rewrite whose
      # destination file does not exist answers 404 — the clean signal Nuxt reads
      # as "build outdated" so the tab reloads into the live build. The current
      # build's files still serve at the static layer, before any rewrite.
      {"source": "/_nuxt/builds/**", "destination": "/__stale-nuxt-build-404__"},
      {"source": "**", "destination": "/200.html"},
    ],
  }
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(out)
PY
