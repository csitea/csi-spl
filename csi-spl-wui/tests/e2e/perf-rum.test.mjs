// Spec 066 lane L6: the real-user timing measurement points M1..M8, proved in
// a real browser on the mock build, from the batches the page actually sends.
//
// The CI bundle is built with RUM off (perf.rum_enabled is cnf, not the mock's
// business), so this gate turns it on for its own page only: the served HTML's
// runtime config gets perfRum "1" and an api base on the bundle's own origin.
// Everything else is the shipped code path:
//   - the collector loads after onNuxtReady, its batches POST to
//     /v1/perf/samples (answered here 202 {"hub_ms"}, the hub's contract) and
//     the rest leaves in a sendBeacon on pagehide (captured)
//   - the composer types and sends (M6, M6b, M3), a message from someone else
//     arrives through the channel store's live-frame entry (M4, on the clock
//     the first 202 gave), the feed scrolls (M7), the router switches page (M5)
//   - the 30 s flush timer runs in 0.4 s
//
// M8 reconnect_live is NOT here: the mock build never opens a live socket
// (useLive.ensure returns null in mock), so no page of it can reconnect.
// tests/unit/perf-mark.test.mjs drives live-ws.mjs for M8, with its control.
//
// Checks, desktop then phone:
//   every metric but M8 appears in a captured batch: load_rail,
//   load_messages, send_ack, deliver_visible, switch_view (view=channel),
//   type_next_paint, inp, scroll_jank, with the right device; a sample has
//   only the allowed fields, and no batch carries a message id, a task id, an
//   agent id or any text that was typed or received.
//   The phone opens /channel/alerts on the feed, its rail one tap away: no
//   load_rail there (the control), and one on / where the phone opens on it.
//
// Run:
//   BASE_URL=<generated mock bundle> node tests/e2e/perf-rum.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PATH = '/channel/alerts'
const SWITCH_TO = '/lobby'
const TYPED = 'perf-typed-secret-7'
const OTHER = 'perf-other-secret-9'
const FIELDS = new Set(['session_id', 'metric', 'value_ms', 'device', 'outcome', 'build', 'view', 'cache', 'hidden_s', 'net', 'ratio', 'clock_err_ms'])

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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

/** Runs in the page before any of its scripts: beacon capture and a fast flush. */
function pageShims() {
  const T = { beacons: [] }
  window.__perfT = T
  navigator.sendBeacon = (_url, body) => { T.beacons.push(String(body)); return true }
  const st = window.setTimeout.bind(window)
  window.setTimeout = (fn, ms, ...a) => st(fn, ms === 30000 ? 400 : ms, ...a)
}

/**
 * One page in a fresh browser context (a second page of a shared context got
 * the cached, unrewritten HTML: RUM off), RUM turned on in its HTML, batches
 * and beacons captured, signed in for the ingest (the mock has no session).
 */
async function openPage(browser, base, phone, path) {
  const tag = phone ? 'phone' : 'desktop'
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const posts = []
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  if (process.env.E2E_VERBOSE) p.on('console', (m) => console.log(`    [${tag} console] ${m.text().slice(0, 160)}`))
  await p.setRequestInterception(true)
  p.on('request', async (req) => {
    try {
      const url = req.url()
      if (req.isNavigationRequest() && req.resourceType() === 'document' && url.startsWith(base)) {
        const html = await (await fetch(url)).text()
        const body = html.replace(/perfRum:"0"/, 'perfRum:"1"').replace(/apiBase:"[^"]*"/, `apiBase:"${base}"`)
        return req.respond({ status: 200, contentType: 'text/html; charset=utf-8', body })
      }
      if (url === `${base}/v1/perf/samples` && req.method() === 'POST') {
        posts.push(String(req.postData() || ''))
        return req.respond({ status: 202, contentType: 'application/json', body: JSON.stringify({ hub_ms: Date.now() }) })
      }
      return req.continue()
    } catch {
      return req.continue().catch(() => {})
    }
  })
  await p.evaluateOnNewDocument(pageShims)
  if (phone) await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  else await p.setViewport({ width: 1440, height: 900 })
  await p.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').state = 'in'
  })
  return { ctx, p, posts, errors, tag }
}

/** pagehide (the final beacon), then every sample the page sent, and whether every body had the wire shape. */
async function collect(page) {
  await page.p.evaluate(() => window.dispatchEvent(new Event('pagehide')))
  await sleep(300)
  const beacons = await page.p.evaluate(() => window.__perfT.beacons)
  const bodies = [...page.posts, ...beacons]
  const samples = []
  let shapeOk = true
  for (const b of bodies) {
    try {
      const j = JSON.parse(b)
      if (Object.keys(j).some((k) => k !== 'samples' && k !== 'dropped')) shapeOk = false
      for (const s of j.samples || []) samples.push(s)
    } catch { shapeOk = false }
  }
  console.log(`  ${page.tag}: ${page.posts.length} POST + ${beacons.length} beacon, ${samples.length} samples: ${[...new Set(samples.map((s) => s.metric))].join(' ')}`)
  return { bodies, samples, shapeOk }
}

async function run(browser, base, phone) {
  const page = await openPage(browser, base, phone, PATH)
  const { p, errors, tag } = page
  await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(1200)

  /* M6 + M6b: type in the composer; one keydown handler is made slow so an Event Timing entry exists */
  await p.evaluate(() => {
    let slow = true
    document.addEventListener('keydown', () => {
      if (!slow) return
      slow = false
      const t = performance.now()
      while (performance.now() - t < 40) { /* a long task on purpose */ }
    }, true)
  })
  const ta = (await p.$('form.composer.omnibox--global textarea')) ? 'form.composer.omnibox--global textarea' : 'form.composer textarea'
  await p.focus(ta)
  await p.type(ta, TYPED, { delay: 15 })
  /* M3: send it (Enter, or GO when Enter is a newline here) */
  await p.keyboard.press('Enter')
  await sleep(300)
  const stillThere = await p.evaluate((sel) => (document.querySelector(sel) || {}).value || '', ta)
  if (stillThere.includes(TYPED)) {
    const go = await p.$('form.composer [data-testid=send]')
    if (go) await go.click()
  }
  await sleep(800)

  /* M4: a message from someone else arrives live (after the first 202 gave the clock) */
  const delivered = await p.evaluate((other) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    const id = `00000000-0000-4000-8000-${String(Date.now()).slice(-12)}`
    ch.ingestLive({ msg_id: id, task_id: id, channel: 'alerts', from: 'HUM-9', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: other, files: [], is_parent: 1, received_at: new Date(Date.now() - 40).toISOString() })
    return Boolean(ch.lastLive)
  }, OTHER)
  await sleep(600)

  /* M7: a scroll burst in the feed */
  await p.evaluate(async () => {
    const el = document.querySelector('.feed-body')
    if (!el) return
    if (el.scrollHeight <= el.clientHeight + 40) {
      const pad = document.createElement('div')
      pad.style.height = '3000px'
      el.appendChild(pad)
    }
    for (let i = 0; i < 12; i++) {
      el.scrollTop += 60
      await new Promise((r) => requestAnimationFrame(r))
    }
  })
  await sleep(500)

  /* M5: switch to another page (the lobby is a channel) */
  await p.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), SWITCH_TO)
  await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(1200)

  const secrets = await p.evaluate(() => {
    const st = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
    const ids = []
    for (const v of Object.values(st)) {
      for (const m of (v && Array.isArray(v.messages) ? v.messages : [])) ids.push(String(m.msg_id || ''), String(m.task_id || ''))
    }
    return ids.filter((x) => x.length >= 8)
  })
  const { bodies, samples, shapeOk } = await collect(page)
  await page.ctx.close()

  const by = (m) => samples.filter((s) => s.metric === m)
  /* on a phone the feed is the open panel and the rail one tap away: no load_rail then (see railRun) */
  if (phone) ok(`${tag}: no load_rail while the rail never showed during the load`, by('load_rail').length === 0, by('load_rail'))
  for (const m of [...(phone ? [] : ['load_rail']), 'load_messages', 'send_ack', 'deliver_visible', 'type_next_paint', 'inp', 'scroll_jank']) {
    ok(`${tag}: ${m} in a captured batch, device=${tag}`, by(m).length > 0 && by(m).every((s) => s.device === tag), by(m).slice(0, 2))
  }
  const sw = by('switch_view')
  ok(`${tag}: switch_view in a captured batch, view=channel, device=${tag}`, sw.length > 0 && sw.every((s) => s.device === tag) && sw.some((s) => s.view === 'channel'), sw.slice(0, 2))
  const dv = by('deliver_visible')
  ok(`${tag}: the live message reached the feed`, delivered)
  ok(`${tag}: deliver_visible carries its clock error bound`, dv.length > 0 && dv.every((s) => Number.isInteger(s.clock_err_ms) && s.clock_err_ms <= 250), dv)
  const extra = samples.filter((s) => Object.keys(s).some((k) => !FIELDS.has(k)))
  ok(`${tag}: every sample has only the allowed fields; bodies are {samples, dropped}`, shapeOk && extra.length === 0, extra.slice(0, 2))
  const all = bodies.join('\n')
  const leaked = [TYPED, OTHER, 'HUM-', 'alerts', 'lobby', '/channel', ...secrets].filter((x) => all.includes(x))
  ok(`${tag}: no id or text in any batch (${secrets.length} store ids checked)`, leaked.length === 0 && secrets.length > 0, leaked.slice(0, 3))
  ok(`${tag}: no page error`, errors.length === 0, errors.slice(0, 3))
}

/** A phone landing on / opens on the rail: M1 is timed there, with device=phone. */
async function railRun(browser, base) {
  const page = await openPage(browser, base, true, '/')
  await page.p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: NAV_TIMEOUT })
  await sleep(1200)
  const { samples } = await collect(page)
  await page.ctx.close()
  const rail = samples.filter((s) => s.metric === 'load_rail')
  ok('phone on /: load_rail in a captured batch, device=phone, with its cache', rail.length === 1 && rail[0].device === 'phone' && ['cold', 'warm'].includes(rail[0].cache), rail)
  ok('phone on /: no page error', page.errors.length === 0, page.errors.slice(0, 3))
}

const browser = await launch()
const server = await startServer()
try {
  for (const phone of [false, true]) await run(browser, server.base, phone)
  await railRun(browser, server.base)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length) {
  console.error('FAILED:', failed.map((r) => r.name).join(' | '))
  process.exit(1)
}
