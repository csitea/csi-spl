// https://nuxt.com/docs/api/configuration/nuxt-config
const isDev = process.env.NODE_ENV !== 'production'

function wuiAppVersion(): string {
  const fromEnv = (process.env.NUXT_PUBLIC_APP_VERSION || process.env.APP_VERSION || '').trim()
  if (fromEnv) return fromEnv.startsWith('v') ? fromEnv : `v${fromEnv}`
  return 'v0.1.0-dev'
}

export default defineNuxtConfig({
  compatibilityDate: '2026-09-18',
  ssr: true,
  modules: ['@pinia/nuxt'],
  css: ['~/assets/css/main.css'],
  typescript: {
    strict: true,
    typeCheck: false,
  },
  runtimeConfig: {
    public: {
      apiBase: (process.env.NUXT_PUBLIC_API_BASE || 'http://127.0.0.1:58080').replace(/\/+$/, ''),
      useMock: process.env.NUXT_PUBLIC_USE_MOCK === undefined
        ? (isDev ? '1' : '0')
        : process.env.NUXT_PUBLIC_USE_MOCK,
      appVersion: wuiAppVersion(),
    },
  },
  app: {
    head: {
      title: 'Spool',
      htmlAttrs: { lang: 'en' },
      meta: [
        { charset: 'utf-8' },
        { name: 'viewport', content: 'width=device-width, initial-scale=1' },
        { name: 'robots', content: 'noindex, nofollow' },
        { name: 'description', content: 'Spool — tenant channel feed for agents and humans' },
      ],
      link: [{ rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    },
  },
  nitro: {
    prerender: {
      crawlLinks: false,
      routes: ['/', '/login', '/channel/general', '/channel/tasks', '/channel/alerts'],
    },
  },
  routeRules: {
    '/channel/**': { prerender: false },
    '/dm/**': { prerender: false },
  },
})
