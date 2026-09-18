// https://nuxt.com/docs/api/configuration/nuxt-config
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const isDev = process.env.NODE_ENV !== "production"

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

export default defineNuxtConfig({
  compatibilityDate: "2026-09-18",
  ssr: true,
  modules: ["@pinia/nuxt"],
  css: ["~/assets/css/main.css"],
  typescript: {
    strict: true,
    typeCheck: false,
  },
  runtimeConfig: {
    public: {
      // Template: {tenant} is replaced at runtime. Tenant reads go to the tenant
      // host, never api.<fqdn> (003 http-v1, reserved labels).
      apiBase: (process.env.NUXT_PUBLIC_API_BASE || "http://{tenant}.localhost:58080").replace(/\/+$/, ""),
      tenant: process.env.NUXT_PUBLIC_TENANT || (isDev ? "t1" : ""),
      useMock: process.env.NUXT_PUBLIC_USE_MOCK === undefined
        ? (isDev ? "1" : "0")
        : process.env.NUXT_PUBLIC_USE_MOCK,
      appVersion: wuiAppVersion(),
      pollMs: process.env.NUXT_PUBLIC_POLL_MS || "4000",
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
  nitro: {
    // lde: same-origin /api/v1/auth/** like the Hosting rewrite (spec 010 auth-v1 §1).
    // NUXT_DEV_AUTH_PROXY = the hub origin, e.g. the auth-demo hub. Unset = no proxy.
    devProxy: process.env.NUXT_DEV_AUTH_PROXY
      ? { "/api/v1/auth": { target: process.env.NUXT_DEV_AUTH_PROXY.replace(/\/+$/, "") + "/api/v1/auth", changeOrigin: true } }
      : {},
    prerender: {
      crawlLinks: false,
      routes: ["/", "/login", "/channel/general", "/channel/tasks", "/channel/alerts"],
    },
  },
  routeRules: {
    "/channel/**": { prerender: false },
    "/dm/**": { prerender: false },
    "/t/**": { prerender: false },
  },
})
