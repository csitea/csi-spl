// https://nuxt.com/docs/api/configuration/nuxt-config
//
// Shape follows the donor WUI: srcDir 'src/', '@' alias, CSP and
// security headers as routeRules, long-lived vendor chunks, @nuxtjs/i18n.
// The spool keeps its own runtimeConfig (tenant host template, mock mode,
// lobby task id, poll interval) and the lde auth devProxy (spec 010).
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

// ── Environment detection ─────────────────────────────────────────────────
// nuxt.config.ts is loaded by jiti BEFORE Nuxt injects `import.meta.dev`, so
// NODE_ENV (set by the Nuxt CLI: `nuxt dev` -> development, `nuxt generate`
// -> production) is the only reliable signal at this scope.
const isDev = process.env.NODE_ENV !== "production"

// Single source of truth is csi-spl-wui/.version (bare semver). CI may thread
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

// Template: {tenant} is replaced at runtime. Tenant reads go to the tenant
// host, never api.<fqdn> (003 http-v1, reserved labels).
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
// else. `script-src 'unsafe-inline'` stays: the WUI is static files on a CDN,
// no server mints a per-response nonce, and Nuxt serialises its payload into
// an inline <script>.
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

export default defineNuxtConfig({
  srcDir: "src/",
  compatibilityDate: "2026-09-18",
  devtools: { enabled: isDev },
  ssr: true,

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

  // English only. It earns its place because the donor's shared UI
  // (ErrorNotice, error.vue, SocialAuthButtons, DebugPanel) speaks through
  // t(); a second locale is a new file in i18n/locales, no code change.
  i18n: {
    strategy: "no_prefix",
    defaultLocale: "en",
    locales: [{ code: "en", language: "en-GB", name: "English", file: "en.json" }],
    lazy: true,
    detectBrowserLanguage: false,
    bundle: { optimizeTranslationDirective: false },
  },

  runtimeConfig: {
    public: {
      apiBase,
      authBase,
      tenant: process.env.NUXT_PUBLIC_TENANT || (isDev ? "t1" : ""),
      // #lobby is a well-known task_id (003 wui-live-ws.md / cnf LOBBY_TASK_ID);
      // the hub welcome frame overrides this when it names one.
      lobbyTaskId: process.env.NUXT_PUBLIC_LOBBY_TASK_ID || "",
      useMock: process.env.NUXT_PUBLIC_USE_MOCK === undefined
        ? (isDev ? "1" : "0")
        : process.env.NUXT_PUBLIC_USE_MOCK,
      appVersion: wuiAppVersion(),
      pollMs: process.env.NUXT_PUBLIC_POLL_MS || "4000",
      // Named env of this build (dev / prd); empty or lde = not deployed.
      envName: process.env.NUXT_PUBLIC_ENV_NAME || "",
    },
  },

  app: {
    head: {
      title: "Spool",
      htmlAttrs: { lang: "en" },
      meta: [
        { charset: "utf-8" },
        { name: "viewport", content: "width=device-width, initial-scale=1" },
        { name: "robots", content: "noindex, nofollow" },
        { name: "theme-color", content: "#060912" },
        { name: "description", content: "Spool — tenant channel feed for agents and humans" },
      ],
      link: [{ rel: "icon", type: "image/svg+xml", href: "/favicon.svg" }],
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
      routes: ["/", "/login", "/channel/general", "/channel/tasks", "/channel/alerts"],
    },
  },
})
