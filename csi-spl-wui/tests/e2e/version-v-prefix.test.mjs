// The version a person reads carries one leading v (owner, t1 990f2d9a):
// the sidebar footer and the release log show v<digits>.<digits>.<digits>.
//
// A deploy sets NUXT_PUBLIC_APP_VERSION to the bare semver (1.2.4). Nuxt
// uses that raw string as public.appVersion, so the footer, the logo and
// the document meta read "1.2.4" until displayVersion prefixes them. The
// release log's version cells (the list and the open note) are the same
// shape. Internal keys stay put: data-version is the release key, and the
// row link is still /releases/<sha>.
//
// The 1.2.4 below reaches only a `nuxi dev` this file starts itself. Under
// BASE_URL (CI serves the bundle wui-generate built) the version is baked
// in at build time from .version, so the expectation is that bundle's own
// public.appVersion, shown with one leading v (c-379: a fixed v1.2.4 read
// v1.1.3 on every CI run).
//
// Run:
//   pnpm run test:e2e version-v-prefix
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { displayVersion } from '../../src/utils/display-version.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

process.env.NUXT_PUBLIC_APP_VERSION = '1.2.4'
process.env.NUXT_PUBLIC_USE_MOCK = '1'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const VER = /^v[0-9]+\.[0-9]+\.[0-9]+$/
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 8000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  const failedReqs = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  p.on('requestfailed', (req) => {
    if (failedReqs.length < 6) failedReqs.push(req.url().slice(0, 120) + ' ' + (req.failure()?.errorText || ''))
  })
  await p.setViewport({ width: 1280, height: 800 })
  /* the version card (and its Release notes button) renders only once a
     commit is known. Same stub the release-notes e2e uses. */
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname === '/build.json') {
      return req.respond({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ commit: '0123456789abcdef0123456789abcdef01234567', built_at: '2026-10-03T10:30:00Z', run: '1', version: '1.2.4' }),
      })
    }
    req.continue()
  })
  await p.goto(server.base + '/lobby', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  /* the first hit compiles the client bundle; a dropped script leaves the
     prerender ("Loading Spool…"). Reload until the footer is actually there. */
  let hydrated = false
  for (let i = 0; i < 8 && !hydrated; i++) {
    hydrated = await until(p, () => Boolean(document.querySelector('[data-test=app-version], article.msg')), null, 15000)
    if (!hydrated) await p.reload({ waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT }).catch(() => {})
  }
  hydrated = await until(p, () => Boolean(document.querySelector('[data-test=app-version]')), null, 20000)
  if (!hydrated) {
    const info = await p.evaluate(() => ({
      url: location.href,
      text: (document.body && document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 400),
    })).catch((e) => ({ eval: String(e) }))
    console.log('PAGE', JSON.stringify({ info, errors: errors.slice(0, 4), failedReqs }))
  }
  ok('the shell hydrated and the footer is in the document', hydrated, failedReqs.slice(0, 3))
  if (!hydrated) throw new Error('footer never mounted')
  /* the raw version this bundle carries: the env above when this file
     started nuxi dev, the build-time value under BASE_URL */
  const raw = server.started
    ? process.env.NUXT_PUBLIC_APP_VERSION
    : await p.evaluate(() => String(document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$config?.public?.appVersion ?? ''))
  const want = displayVersion(raw)
  ok('the bundle carries a semver version', VER.test(want), { raw, want })
  /* read the stamp before sign-in: adopt() can navigate, and the footer is
     already on the signed-out shell */
  const foot = await p.$eval('[data-test=app-version] .vs-ver', (el) => el.textContent.trim())
  ok('footer shows v<digits>.<digits>.<digits>', foot === want && VER.test(foot), { foot, want })
  const meta = await p.$eval('meta[name=version]', (el) => el.getAttribute('content') || '')
  ok('the document version meta shows the same v prefix', meta === want, { meta, want })

  await p.click('[data-test=top-bar-logo]')
  await p.waitForSelector('[data-testid=logo-dialog-version] code', { timeout: 5000 })
  const logo = await p.$eval('[data-testid=logo-dialog-version] code', (el) => el.textContent.trim())
  ok('the logo dialog shows the same v prefix', logo === want, { logo, want })
  await p.keyboard.press('Escape')
  await until(p, () => !document.querySelector('[data-testid=logo-dialog]'), null, 3000)

  await signIn(p)
  await sleep(500)
  await p.waitForSelector('[data-test=app-version-wrap]', { timeout: 15000 })
  await p.click('[data-test=app-version-wrap]')
  const opened = await until(p, () => {
    const b = document.querySelector('[data-test=app-version-notes]')
    return Boolean(b && getComputedStyle(b.closest('[data-test=app-version-card]')).visibility === 'visible')
  }, null, 3000)
  ok('the version card opens', opened)
  if (opened) await p.click('[data-test=app-version-notes]')
  const listed = await until(p, () => document.querySelectorAll('[data-test=release-version]').length > 0, null, 10000)
  const log = await p.evaluate(() => {
    const vers = [...document.querySelectorAll('[data-test=release-version]')]
    return vers.slice(0, 5).map((v) => ({
      key: v.getAttribute('data-version') || '',
      name: v.querySelector('.rn-ver__name')?.textContent.trim() || '',
      cell: v.querySelector('[data-test=release-row] .rn-table__ver')?.textContent.trim() || '',
      href: v.querySelector('[data-test=release-row-title]')?.getAttribute('href') || '',
    }))
  })
  const verOk = listed && log.length > 0 && log.every((row) => VER.test(row.name) && VER.test(row.cell))
  ok('the release log list shows v<digits>.<digits>.<digits>', verOk, log.slice(0, 2))
  const keysOk = log.length > 0 && log.every((row) => row.key === row.name && row.href.includes('/releases/'))
  ok('data-version and /releases/<ref> stay the release key', keysOk, log[0])

  const sha = log[0] && (log[0].href.split('/releases/')[1] || '')
  if (sha) {
    await p.click(`[data-test=release-row-title][data-sha="${sha}"]`)
    await until(p, () => Boolean(document.querySelector('[data-test=release-note-version]')), null, 3000)
  }
  const noteVer = await p.$eval('[data-test=release-note-version]', (el) => el.textContent.trim()).catch(() => '')
  ok('the open release note shows v<digits>.<digits>.<digits>', VER.test(noteVer), { noteVer })
  ok('no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nversion-v-prefix: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
