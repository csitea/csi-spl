// P3-14 live proof: the browser router starts with the default locale and
// the URL's locale only, and adds the other locales' routes later
// (src/utils/locale-routes.mjs, plugins/locale-routes.client.ts). Anonymous
// visitor, headless Chrome, against a deployed (or local) WUI:
//   1. a deep link in a non-default locale (/bg/channel/general) resolves and
//      stays in bg (signed out: the login redirect keeps the bg prefix).
//   2. after idle the router holds every locale's routes (count = full set).
//   3. switch bg -> fi through the combobox: /fi/login, lang fi.
//   4. back -> /bg/login (lang bg), forward -> /fi/login (lang fi).
//   5. a fresh tab on /sv/login pushes /nl/login the moment the app mounts,
//      before the idle callback: the guard adds the deferred routes and it
//      lands on /nl/login (routes_before_push says they were deferred).
//
//   BASE=https://dev.<domain> OUT=<dir> [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/locale-routes-lazy.proof.mjs
//
// Exit 0 = every step PASS.
import { writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const path = (p) => new URL(p.url()).pathname
const lang = (p) => p.evaluate(() => document.documentElement.lang)
const routeCount = (p) => p.evaluate(() => document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$router?.getRoutes().length ?? -1)
const until = (p, fn, arg) => p.waitForFunction(fn, { timeout: 20000 }, arg)

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  try { res.build = await (await fetch(BASE + '/build.json')).json() } catch { res.build = null }

  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })

  // 1. deep link in a non-default locale
  await p.goto(BASE + '/bg/channel/general', { waitUntil: 'networkidle2' })
  await until(p, () => !!document.querySelector('#__nuxt')?.__vue_app__)
  await sleep(800)
  step('deep link /bg/channel/general stays in bg', path(p).startsWith('/bg/') && (await lang(p)).startsWith('bg'),
    { path: path(p), lang: await lang(p) })

  // 2. the deferred routes are in after idle
  await until(p, () => (document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$router?.getRoutes().length ?? 0) > 200)
  const full = await routeCount(p)
  step('after idle the router holds every locale', full > 200, { routes: full })

  // 3. switch bg -> fi
  await p.goto(BASE + '/bg/login', { waitUntil: 'networkidle2' })
  await sleep(600)
  const input = await p.waitForSelector('[data-test=lang-switcher-input]', { visible: true, timeout: 20000 })
  await input.click()
  await p.keyboard.type('suo', { delay: 40 })
  await p.waitForSelector('[data-test=lang-item-fi]', { visible: true, timeout: 5000 })
  await Promise.all([until(p, () => document.documentElement.lang.startsWith('fi')), p.click('[data-test=lang-item-fi]')])
  await sleep(400)
  step('switch bg -> fi lands on /fi/login', path(p) === '/fi/login', { path: path(p), lang: await lang(p) })

  // 4. back / forward across the two locales
  await Promise.all([until(p, () => location.pathname === '/bg/login'), p.goBack()])
  await until(p, () => document.documentElement.lang.startsWith('bg'))
  step('back -> /bg/login in bg', path(p) === '/bg/login', { path: path(p), lang: await lang(p) })
  await Promise.all([until(p, () => location.pathname === '/fi/login'), p.goForward()])
  await until(p, () => document.documentElement.lang.startsWith('fi'))
  step('forward -> /fi/login in fi', path(p) === '/fi/login', { path: path(p), lang: await lang(p) })
  await ctx.close()

  // 5. a push into a locale that may not be registered yet
  const ctx2 = await browser.createBrowserContext()
  const q = await ctx2.newPage()
  // push from the first DOM mutation after mount: before the idle callback
  await q.evaluateOnNewDocument(() => {
    const mo = new MutationObserver(() => {
      const r = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$router
      if (!r || window.__pushed) return
      window.__pushed = true
      window.__routesBeforePush = r.getRoutes().length
      mo.disconnect()
      r.push('/nl/login')
    })
    mo.observe(document, { childList: true, subtree: true, attributes: true })
  })
  await q.goto(BASE + '/sv/login', { waitUntil: 'domcontentloaded' })
  await until(q, () => location.pathname === '/nl/login' && document.documentElement.lang.startsWith('nl'))
  const before = await q.evaluate(() => window.__routesBeforePush)
  await sleep(800)
  step('push /sv/login -> /nl/login before idle (guard)', path(q) === '/nl/login' && before < 200,
    { path: path(q), lang: await lang(q), routes_before_push: before })
  await ctx2.close()
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`\n${res.steps.length - bad}/${res.steps.length} steps PASS`)
process.exit(bad ? 1 : 0)
