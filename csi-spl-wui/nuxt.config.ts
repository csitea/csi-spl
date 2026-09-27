// https://nuxt.com/docs/api/configuration/nuxt-config
//
// Shape follows the donor WUI: srcDir 'src/', '@' alias, CSP and
// security headers as routeRules, long-lived vendor chunks, @nuxtjs/i18n.
// The spool keeps its own runtimeConfig (tenant host template, mock mode,
// lobby task id) and the lde auth devProxy (spec 010).
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { buildRootLocaleRedirectScript } from "./src/utils/rootLocaleRedirect.mjs"

// ── Environment detection ─────────────────────────────────────────────────
// nuxt.config.ts is loaded by jiti BEFORE Nuxt injects `import.meta.dev`, so
// NODE_ENV (set by the Nuxt CLI: `nuxt dev` -> development, `nuxt generate`
// -> production) is the only reliable signal at this scope.
const isDev = process.env.NODE_ENV !== "production"

// Single source of truth is csi-spl-wui/.version (bare semver). CI may topic
// NUXT_PUBLIC_APP_VERSION=v<version>; lde falls back to the file so the stamp
// is never invented. Shape: vMAJOR.MINOR.PATCH.
function wuiAppVersion(): string {
  const fromEnv = (process.env.NUXT_PUBLIC_APP_VERSION || process.env.APP_VERSION || "").trim()
  if (fromEnv) return fromEnv.startsWith("v") ? fromEnv : ("v" + fromEnv)
  try {
    const raw = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), ".version"),
      "utf8",
    ).trim()
    if (/^[0-9]+\.[0-9]+\.[0-9]+$/.test(raw)) return "v" + raw
  } catch {
    /* missing marker */
  }
  return "v0.1.0-dev"
}

// dev / prd: the api host (https://api.<fqdn>); the hub resolves the tenant
// from identity (specs/026, internal/hub/resolve.go). lde / legacy: a template
// whose {tenant} is replaced at runtime (src/utils/tenant.mjs apiBaseFor).
const apiBase = (process.env.NUXT_PUBLIC_API_BASE || "http://{tenant}.localhost:58080").replace(/\/+$/, "")

/**
 * The hub origin as a CSP source: `{tenant}` becomes `*`, so
 * `https://{tenant}.<fqdn>` admits every tenant host and nothing else.
 * Returns [http(s) source, ws(s) source], or [] for a relative/empty base.
 */
function hubCspSources(base: string): string[] {
  const m = /^(https?):\/\/([^/]+)/i.exec(base)
  if (!m) return []
  const host = m[2].replace("{tenant}", "*")
  const ws = m[1].toLowerCase() === "https" ? "wss" : "ws"
  return [`${m[1].toLowerCase()}://${host}`, `${ws}://${host}`]
}
// The hub's API origin for /api/v1/auth/** (spec 010 auth-v1 §1): the WUI host
// is not the hub host in any deployed env, so sign-in, the session probe and
// the native forms go there cross-origin with credentials. "" = same-origin
// (lde: the devProxy below). A build sets it per env, e.g. https://api.<domain>.
const authBase = (process.env.NUXT_PUBLIC_AUTH_BASE || "").replace(/\/+$/, "")
const HUB_SOURCES = [...new Set([...hubCspSources(apiBase), ...hubCspSources(authBase)])].join(" ")

// ── The lobby task id, from cnf ───────────────────────────────────────────
// wui-live-ws.md §LOBBY_TASK_ID: defined ONCE, in cnf (env.hub.env.
// SPOOL_HUB_LOBBY_TASK_ID); the hub publishes it in `welcome`. The deployed
// build shipped `lobbyTaskId: ""` (CLE-35062), so /lobby could not read a row
// before the socket was up and had said welcome (session -> socket -> welcome
// -> read). So the build reads the same cnf file the deploy job reads, for the
// env it builds (NUXT_PUBLIC_ENV_NAME); NUXT_PUBLIC_LOBBY_TASK_ID still
// overrides, and welcome still wins at runtime.
function cnfLobbyTaskId(): string {
  const fromEnv = (process.env.NUXT_PUBLIC_LOBBY_TASK_ID || "").trim()
  if (fromEnv) return fromEnv
  const env = (process.env.NUXT_PUBLIC_ENV_NAME || "").trim()
  if (!/^[a-z0-9-]+$/.test(env)) return ""
  try {
    const cnf = JSON.parse(readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), "..", "csi-spl-cnf", "csi-spl", `${env}.env.json`),
      "utf8",
    ))
    const id = String(cnf?.env?.hub?.env?.SPOOL_HUB_LOBBY_TASK_ID || "").trim()
    return /^[0-9a-f-]{36}$/i.test(id) ? id : ""
  } catch {
    return ""
  }
}

// ── Preconnect to the hub ─────────────────────────────────────────────────
// Every screen's first read is a credentialed cross-origin call to the API
// host, and it only starts once the app code has run. A preconnect in the
// document opens that connection (DNS + TCP + TLS, three round trips) while
// the JS downloads. `use-credentials` matches the fetches' credentials mode,
// so the warmed connection is the one they use. Absolute https bases only
// (lde's `{tenant}` template and same-origin "" have nothing to warm).
function preconnectLinks(bases: string[]) {
  const origins = new Set<string>()
  for (const b of bases) {
    const m = /^(https:\/\/[^/{}]+)/i.exec(b)
    if (m) origins.add(m[1].toLowerCase())
  }
  return [...origins].map((href) => ({ rel: "preconnect", href, crossorigin: "use-credentials" as const }))
}

// ── Content-Security-Policy ───────────────────────────────────────────────
// These strings apply only when Nitro is the runtime (lde / preview). The WUI
// ships via `nuxt generate` to Firebase Hosting, so in every deployed env the
// authoritative CSP comes from firebase.json's hosting.headers, rendered by
// csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh. KEEP BOTH IN SYNC:
// the prod list below is that script's list with the hub origin taken from
// NUXT_PUBLIC_API_BASE instead of cnf.
//
// Both policies are written out in full rather than composed from a shared
// array: the question asked of a policy is "what does THIS env allow", which
// a literal answers and a .map() does not.
//
// connect-src is the one that matters: the viewer reads, and the live pane
// opens its WebSocket, on the tenant host (<tenant>.<fqdn>), never anywhere
// else. In every DEPLOYED env script-src / style-src carry no 'unsafe-inline'
// (spec 017 FR-SEC-005): the Hosting render hashes the inline <script> and
// <style> blocks of the generated bundle. CSP_PROD below is `nuxt preview`
// only and keeps 'unsafe-inline' — no render step runs there to hash.
// tests/unit/csp-policy.test.mjs pins every other directive to the render.
// The card step's vendor origins (cnf env.payment.wui_csp) exist only in the
// Hosting render: preview has no card rail, so frame-src stays 'self' here.
//
// lde additions over CSP_PROD, and ONLY these: Vite evaluates modules at
// runtime ('unsafe-eval') and runs its HMR client from a blob: Worker; ws:/wss:
// is the HMR socket; localhost/127.0.0.1 are the lde hub and auth-demo;
// frame-src data: is the `nuxt dev` error overlay, which renders the dev
// error/404 page inside a data: URL iframe (without it every lde 404 logs a
// CSP violation instead of showing the error).
const CSP_DEV = [
  "default-src 'self' blob:",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:",
  "worker-src 'self' blob:",
  "frame-src 'self' data:",
  "img-src 'self' data: blob:",
  "style-src 'self' 'unsafe-inline'",
  "font-src 'self' data:",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
  `connect-src 'self' ws: wss: http://localhost:* http://*.localhost:* http://127.0.0.1:* ${HUB_SOURCES}`.trim(),
  "frame-ancestors 'none'",
].join("; ")

const CSP_PROD = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self' data:",
  `connect-src 'self' ${HUB_SOURCES}`.trim(),
  "frame-src 'self'",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "object-src 'none'",
].join("; ")

// ── Long-lived vendor chunks ──────────────────────────────────────────────
// Split the framework out of the app chunks so a spool-only change does not
// invalidate the browser cache of code that changes only on a dependency
// bump.
const VENDOR_CHUNKS: Array<[string, RegExp]> = [
  // Vue core + Router + Pinia runtime. Changes only on a dependency bump.
  ["vendor-vue", /^(?:vue|vue-router|pinia|@vue\/(?:shared|reactivity|runtime-core|runtime-dom))$/],
  // Translation ENGINE only; locale messages keep their own lazy chunk.
  ["vendor-i18n", /^(?:vue-i18n|@intlify\/.+)$/],
]

/** Map a module id to its long-lived vendor chunk, or undefined to let Rollup decide. */
function vendorChunk(id: string): string | undefined {
  if (!id.includes("node_modules")) return undefined
  const tail = id.split("node_modules/").pop() || ""
  const seg = tail.split("/")
  const pkg = seg[0]?.startsWith("@") ? `${seg[0]}/${seg[1]}` : seg[0]
  for (const [chunk, re] of VENDOR_CHUNKS) {
    if (pkg && re.test(pkg)) return chunk
  }
  return undefined
}

// ── i18n locale set ───────────────────────────────────────────────────────
// Shared by the i18n module config and the root redirect script (app.head)
// so the two can never disagree on what ships. Default from cnf
// (env.i18n.default_locale -> NUXT_PUBLIC_DEFAULT_LOCALE). Owner 2026-09-19
// (spec 021 OQ-1): English; the fallback matches when the env is unset.
type SpoolLocaleCode =
  | "bg" | "fi" | "ru" | "en" | "sv" | "he" | "tr" | "mk" | "el"
  | "lt" | "et" | "lv" | "sr" | "ro" | "uk" | "sk" | "pl" | "es" | "nl"
const I18N_LOCALES = [
  { code: "bg", language: "bg-BG", name: "Български", file: "bg.json" },
  { code: "fi", language: "fi-FI", name: "Suomi", file: "fi.json" },
  { code: "ru", language: "ru-RU", name: "Русский", file: "ru.json" },
  { code: "en", language: "en-GB", name: "English", file: "en.json" },
  { code: "sv", language: "sv-SE", name: "Svenska", file: "sv.json" },
  { code: "he", language: "he-IL", name: "עברית", file: "he.json", dir: "rtl" as const },
  { code: "tr", language: "tr-TR", name: "Türkçe", file: "tr.json" },
  { code: "mk", language: "mk-MK", name: "Македонски", file: "mk.json" },
  { code: "el", language: "el-GR", name: "Ελληνικά", file: "el.json" },
  { code: "lt", language: "lt-LT", name: "Lietuvių", file: "lt.json" },
  { code: "et", language: "et-EE", name: "Eesti", file: "et.json" },
  { code: "lv", language: "lv-LV", name: "Latviešu", file: "lv.json" },
  { code: "sr", language: "sr-RS", name: "Srpski", file: "sr.json" },
  { code: "ro", language: "ro-RO", name: "Română", file: "ro.json" },
  { code: "uk", language: "uk-UA", name: "Українська", file: "uk.json" },
  { code: "sk", language: "sk-SK", name: "Slovenčina", file: "sk.json" },
  { code: "pl", language: "pl-PL", name: "Polski", file: "pl.json" },
  { code: "es", language: "es-ES", name: "Español", file: "es.json" },
  { code: "nl", language: "nl-NL", name: "Nederlands", file: "nl.json" },
]
const _envDefaultLocale = (process.env.NUXT_PUBLIC_DEFAULT_LOCALE || "en").trim()
if (!I18N_LOCALES.some((l) => l.code === _envDefaultLocale)) {
  throw new Error(`NUXT_PUBLIC_DEFAULT_LOCALE=${_envDefaultLocale} is not one of the shipped locales`)
}
const DEFAULT_LOCALE = _envDefaultLocale as SpoolLocaleCode
// Locale preference cookie (strictly necessary). Written by
// src/plugins/locale-cookie.client.ts, read by the root redirect script.
const LOCALE_COOKIE = "i18n_redirected"
// Pages prerendered per locale (the rest is the 200.html SPA fallback).
const PRERENDER_PAGES = ["/", "/login"]

export default defineNuxtConfig({
  srcDir: "src/",
  compatibilityDate: "2026-09-18",
  devtools: { enabled: isDev },
  ssr: true,
  // CLE-35062: the painted app-frame outline 200.html shows until the app
  // mounts (every non-prerendered route boots from 200.html); see the file.
  spaLoadingTemplate: "spa-loading-template.html",

  experimental: {
    // CLE-35062: no page uses useAsyncData/useFetch, so every prerendered
    // route's _payload.json is `data: {}` - yet a client-side move to one
    // (/, /login, /channel/general) waited for that fetch before the page's
    // own read started: one more round trip per click (~150-300 ms on 4G).
    // Off = the (empty) payload is inlined in the prerendered document.
    payloadExtraction: false,
  },

  typescript: {
    strict: true,
    typeCheck: false,
    shim: false,
  },

  alias: {
    "@": fileURLToPath(new URL("./src", import.meta.url)),
  },

  css: ["@/assets/css/main.css"],

  modules: ["@nuxtjs/i18n", "@pinia/nuxt"],

  // Donor i18n, copied (spec 021): 19 locales, prefix_except_default, lazy
  // catalogues, browser detection done by the blocking root redirect script
  // (cookie -> Accept-Language -> default) instead of the module, so the
  // prerendered `/` never hydrates with a mismatch.
  i18n: {
    // Absolute base for hreflang alternates; empty = relative links. The WUI
    // is noindex and serves many tenant hosts, so no base is pinned here.
    baseUrl: process.env.NUXT_PUBLIC_SITE_URL || "",
    strategy: "prefix_except_default",
    defaultLocale: DEFAULT_LOCALE,
    locales: I18N_LOCALES,
    lazy: true,
    detectBrowserLanguage: false,
    bundle: { optimizeTranslationDirective: false },
    // Default "absolute" embeds the CI workspace path in shipped
    // __NUXT__.config locales[].files[].path (e.g. /home/runner/work/...).
    experimental: { generatedLocaleFilePathFormat: "off" },
  },

  runtimeConfig: {
    public: {
      apiBase,
      authBase,
      tenant: process.env.NUXT_PUBLIC_TENANT || (isDev ? "t1" : ""),
      // SPL-959 tenant hosts: the apex (https://<fqdn>) is `tenant` above and
      // every other tenant is https://<tenant>.<fqdn> (src/utils/tenant-host.mjs).
      // "1" = on; off (lde, and until cnf turns it on) keeps specs/026 as is.
      siteUrl: process.env.NUXT_PUBLIC_SITE_URL || "",
      tenantHosts: process.env.NUXT_PUBLIC_TENANT_HOSTS || "0",
      // #lobby is a well-known task_id (003 wui-live-ws.md / cnf LOBBY_TASK_ID);
      // the hub welcome frame overrides this when it names one.
      lobbyTaskId: cnfLobbyTaskId(),
      useMock: process.env.NUXT_PUBLIC_USE_MOCK === undefined
        ? (isDev ? "1" : "0")
        : process.env.NUXT_PUBLIC_USE_MOCK,
      appVersion: wuiAppVersion(),
      // SPL-1006: the commit this bundle was built from, so an open tab can
      // tell that /build.json names a newer deploy (plugins/build-watch).
      // GITHUB_SHA is set in every Actions step; empty in lde = watch off.
      buildCommit: (process.env.NUXT_PUBLIC_BUILD_COMMIT || process.env.GITHUB_SHA || "").trim(),
      buildRun: (process.env.NUXT_PUBLIC_BUILD_RUN || process.env.GITHUB_RUN_ID || "").trim(),
      buildAt: process.env.NUXT_PUBLIC_BUILD_COMMIT || process.env.GITHUB_SHA ? new Date().toISOString().replace(/\.\d+Z$/, "Z") : "",
      // Named env of this build (dev / prd); empty or lde = not deployed.
      envName: process.env.NUXT_PUBLIC_ENV_NAME || "",
      // Name of the locale preference cookie (see LOCALE_COOKIE).
      localeCookie: LOCALE_COOKIE,
      defaultLocale: DEFAULT_LOCALE,
    },
  },

  app: {
    head: {
      title: "spool-hub",
      // lang/dir come from useLocaleHead in app.vue.
      script: [
        {
          // Decide the root locale BEFORE any markup is parsed. Only acts on
          // the exact path `/`, never for crawlers, and only when the
          // resolved locale is not the default already in hand.
          innerHTML: buildRootLocaleRedirectScript({
            supported: I18N_LOCALES.map((l) => l.code),
            defaultLocale: DEFAULT_LOCALE,
            cookieKey: LOCALE_COOKIE,
          }),
          tagPosition: "head",
          tagPriority: "critical",
        },
      ],
      meta: [
        { charset: "utf-8" },
        // SPL-990: cover = draw under the notch / status bar (the top bar and
        // the shell pad env(safe-area-inset-*), --top-bar-h carries the top
        // one); resizes-content = the on-screen keyboard shrinks the layout
        // viewport on Android, so the docked composer rides above it.
        { name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content" },
        { name: "robots", content: "noindex, nofollow" },
        { name: "theme-color", content: "#060912" },
        { name: "description", content: "spool-hub — tenant channel feed for agents and humans" },
        // PWA install (public/manifest.webmanifest + public/sw.js): iOS reads
        // these instead of the manifest for a home-screen app.
        { name: "mobile-web-app-capable", content: "yes" },
        { name: "apple-mobile-web-app-capable", content: "yes" },
        { name: "apple-mobile-web-app-title", content: "spool-hub" },
        { name: "apple-mobile-web-app-status-bar-style", content: "black" },
      ],
      link: [
        ...preconnectLinks([apiBase, authBase]),
        { rel: "icon", type: "image/png", sizes: "64x64", href: "/icons/favicon-64.png" },
        { rel: "manifest", href: "/manifest.webmanifest" },
        { rel: "apple-touch-icon", href: "/icons/apple-touch-icon.png" },
      ],
    },
  },

  vite: {
    $client: {
      build: {
        rollupOptions: {
          output: { manualChunks: vendorChunk },
        },
        sourcemap: process.env.NUXT_CLIENT_SOURCEMAP === "true",
      },
    },
    server: {
      // Bind-mounted source in the lde container does not deliver inotify.
      watch: process.env.NUXT_VITE_POLL === "true"
        ? { usePolling: true, interval: 250 }
        : undefined,
    },
  },

  routeRules: {
    "/**": {
      headers: {
        "X-Frame-Options": "DENY",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains; preload",
        "Content-Security-Policy": isDev ? CSP_DEV : CSP_PROD,
        "X-Robots-Tag": "noindex, nofollow",
        "Cache-Control": "public, max-age=0, must-revalidate",
      },
    },
    "/_nuxt/**": {
      headers: { "Cache-Control": "public, max-age=31536000, immutable" },
    },
    "/channel/**": { prerender: false },
    "/dm/**": { prerender: false },
    "/t/**": { prerender: false },
    "/lobby": { prerender: false },
  },

  nitro: {
    // lde: same-origin /api/v1/auth/** like the Hosting rewrite (spec 010 auth-v1 §1),
    // and /api/v1/checkout/** (spec 006 checkout-v1 §1, served from the apex).
    // NUXT_DEV_AUTH_PROXY = the hub origin, e.g. the auth-demo hub. Unset = no proxy.
    devProxy: process.env.NUXT_DEV_AUTH_PROXY
      ? {
          "/api/v1/auth": { target: process.env.NUXT_DEV_AUTH_PROXY.replace(/\/+$/, "") + "/api/v1/auth", changeOrigin: true },
          "/api/v1/checkout": { target: process.env.NUXT_DEV_AUTH_PROXY.replace(/\/+$/, "") + "/api/v1/checkout", changeOrigin: true },
        }
      : {},
    prerender: {
      crawlLinks: false,
      routes: [
        ...PRERENDER_PAGES.flatMap((p) =>
          I18N_LOCALES.map((l) => (l.code === DEFAULT_LOCALE ? p : `/${l.code}${p === "/" ? "" : p}`)),
        ),
        "/channel/general", "/channel/tasks", "/channel/alerts",
      ],
    },
  },
})
