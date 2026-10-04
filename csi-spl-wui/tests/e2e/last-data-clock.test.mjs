// Last-updated clock in the top bar (owner: the time of the latest data
// the hub returned, HH:mm:ss, visible on every page so a snapshot shows it).
//
//   node tests/e2e/last-data-clock.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/last-data-clock.test.mjs
//   OUT=/var/tmp/g-254-shots node tests/e2e/last-data-clock.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const PAGES = ['/lobby', '/help', '/settings', '/docs']
const WIDTHS = [
  { name: '1440', width: 1440, height: 900, touch: false },
  { name: '390', width: 390, height: 844, touch: true },
]

if (OUT) mkdirSync(OUT, { recursive: true })

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const facts = (p) => p.evaluate(() => {
  const bar = document.querySelector('[data-test=top-bar]')
  const el = bar && bar.querySelector('[data-test=last-data-clock]')
  if (!bar || !el) return null
  const b = bar.getBoundingClientRect()
  const r = el.getBoundingClientRect()
  const cs = getComputedStyle(el)
  const shown = cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  // The phone rule is a calc(), which getPropertyValue returns unparsed.
  const probe = document.createElement('div')
  probe.style.cssText = 'position:absolute;visibility:hidden;height:var(--top-bar-h)'
  document.documentElement.appendChild(probe)
  const expectH = probe.getBoundingClientRect().height
  probe.remove()
  const menu = document.querySelector('[data-test=user-menu-panel]')
  return {
    text: (el.textContent || '').trim(),
    title: el.getAttribute('title') || '',
    at: el.getAttribute('data-at') || '',
    shown,
    barH: Math.round(b.height),
    expectH: Math.round(expectH),
    inside: shown && r.top >= b.top - 1 && r.bottom <= b.bottom + 1 && r.left >= -1 && r.right <= window.innerWidth + 1,
    scroll: document.scrollingElement.scrollWidth <= window.innerWidth + 1,
    menuOpen: Boolean(menu && menu.getClientRects().length),
    tenant: Boolean(document.querySelector('[data-test=top-bar-tenant], [data-testid=tenant-switcher]') && [...document.querySelectorAll('[data-test=top-bar-tenant], [data-testid=tenant-switcher]')].some((n) => n.getClientRects().length)),
  }
})

async function openPage(p, base, path) {
  // domcontentloaded: a Vite dev socket never goes network-idle, and the first
  // visit to a route can restart the dev server (the bar then appears on retry).
  const show = async () => {
    await p.goto(base + path, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    return p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
  }
  if (!await show()) await show()
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await signIn(p)
  const ready = await p.waitForFunction(() => {
    const el = document.querySelector('[data-test=top-bar] [data-test=last-data-clock]')
    return Boolean(el && /^\d{2}:\d{2}:\d{2}$/.test((el.textContent || '').trim()))
  }, { timeout: 20000 }).then(() => true).catch(() => false)
  return ready
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 240)))

  for (const vp of WIDTHS) {
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.touch, hasTouch: vp.touch, deviceScaleFactor: vp.touch ? 2 : 1 })
    for (const path of PAGES) {
      const ready = await openPage(p, server.base, path)
      const f = await facts(p)
      const tag = `${vp.name} ${path}`
      ok(`${tag}: clock is in the top bar`, Boolean(f && f.shown && f.inside && !f.menuOpen), f)
      ok(`${tag}: HH:mm:ss after data`, ready && Boolean(f && /^\d{2}:\d{2}:\d{2}$/.test(f.text)), f && { text: f.text, title: f.title })
      ok(`${tag}: bar height unchanged`, Boolean(f && f.expectH > 0 && Math.abs(f.barH - f.expectH) <= 1), f && { barH: f.barH, expectH: f.expectH })
      ok(`${tag}: no horizontal scroll`, Boolean(f && f.scroll), f && { scroll: f.scroll })
      ok(`${tag}: tooltip names last updated and the date`, Boolean(f && /last updated/i.test(f.title) && /\d{4}-\d{2}-\d{2}/.test(f.title)), f && f.title)
    }
  }

  await p.setViewport({ width: 1440, height: 900 })
  await openPage(p, server.base, '/lobby')
  const local = await p.evaluate(() => {
    const el = document.querySelector('[data-test=last-data-clock]')
    const iso = el?.getAttribute('data-at') || ''
    if (!iso) return { ok: false }
    const d = new Date(iso)
    const pad = (n) => String(n).padStart(2, '0')
    const want = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    return { ok: (el.textContent || '').trim() === want, text: (el.textContent || '').trim(), want }
  })
  ok('the painted time is the local HH:mm:ss of data-at', local.ok, local)

  const refused = await p.evaluate(async () => {
    const read = () => document.querySelector('[data-test=last-data-clock]')?.getAttribute('data-at') || ''
    const before = read()
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const channel = pinia?._s.get('channel')
    let result = 'no-store'
    if (channel) {
      try {
        await channel.deleteChannel('no-such-clock-channel')
        result = 'ok'
      } catch {
        result = 'threw'
      }
    }
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    return { before, after: read(), result }
  })
  ok('a refused request does not move the clock', refused.result === 'threw' && refused.before !== '' && refused.before === refused.after, refused)

  const samples = []
  for (let i = 0; i < 5; i++) {
    const row = await p.evaluate(async () => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      const channel = pinia?._s.get('channel')
      const read = () => document.querySelector('[data-test=last-data-clock]')?.getAttribute('data-at') || ''
      const barH = () => Math.round(document.querySelector('[data-test=top-bar]')?.getBoundingClientRect().height || 0)
      const before = read()
      const h0 = barH()
      const t0 = performance.now()
      await channel.refresh()
      let after = before
      const deadline = performance.now() + 1000
      while (performance.now() < deadline) {
        after = read()
        if (after && after !== before) break
        await new Promise((r) => requestAnimationFrame(r))
      }
      return {
        ms: Math.round((performance.now() - t0) * 10) / 10,
        advanced: Boolean(after && after !== before),
        barHeld: barH() === h0,
      }
    })
    samples.push(row)
    await sleep(8)
  }
  console.log('LAST_DATA_TIMING ' + JSON.stringify(samples))
  ok('five refetches each advance the clock without moving the bar', samples.length === 5 && samples.every((s) => s.advanced && s.barHeld), samples)

  const narrow = await (async () => {
    await p.setViewport({ width: 360, height: 800, isMobile: true, hasTouch: true })
    await openPage(p, server.base, '/lobby')
    return facts(p)
  })()
  ok('360 px: the clock stays in the bar, fully on screen', Boolean(narrow && narrow.shown && narrow.inside && narrow.scroll && /^\d{2}:\d{2}:\d{2}$/.test(narrow.text)), narrow)

  ok('no page errors', errors.length === 0, errors)

  if (OUT) {
    for (const theme of ['dark', 'light']) {
      await p.evaluate((id) => {
        localStorage.setItem('spool-theme', id)
        document.documentElement.setAttribute('data-theme', id)
      }, theme)
      for (const vp of WIDTHS) {
        await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.touch, hasTouch: vp.touch, deviceScaleFactor: vp.touch ? 2 : 1 })
        await openPage(p, server.base, '/lobby')
        await p.evaluate((id) => document.documentElement.setAttribute('data-theme', id), theme)
        await p.screenshot({ path: `${OUT}/lobby-${vp.name}-${theme}.png` })
        const bar = await p.$('[data-test=top-bar]')
        if (bar) await bar.screenshot({ path: `${OUT}/bar-lobby-${vp.name}-${theme}.png` })
      }
      await p.setViewport({ width: 1440, height: 900 })
      for (const path of ['/help', '/settings', '/docs']) {
        await openPage(p, server.base, path)
        await p.evaluate((id) => document.documentElement.setAttribute('data-theme', id), theme)
        const slug = path.replace(/\//g, '') || 'home'
        await p.screenshot({ path: `${OUT}/${slug}-1440-${theme}.png` })
      }
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nlast-data-clock: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
