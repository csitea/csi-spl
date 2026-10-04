// A topic id written in a message opens that topic, on a phone and on a desktop.
// The unknown uuid in the same body is the control: it stays plain text.
//
// Run: node tests/e2e/id-links.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const FROM = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TO = 'abababab-abab-4bab-8bab-abababababab'
const REPLY = '33333333-3333-4333-8333-333333333333'
const UNKNOWN = '00000000-0000-4000-8000-000000000099'
const BODY = `topic ${TO}\nnot an id ${UNKNOWN}`

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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

const state = (p) => p.evaluate((to, unknown) => {
  const sh = document.querySelector('.spool-shell')
  const vis = (s) => {
    const e = document.querySelector(s)
    if (!e) return false
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0
  }
  const links = [...document.querySelectorAll('a.msg-link')].map((a) => ({
    text: a.textContent || '',
    href: a.getAttribute('href') || '',
  }))
  return {
    level: sh ? sh.getAttribute('data-mobile-level') : null,
    page: vis('.spool-main [data-test=topic-root]'),
    pane: vis('.spool-shell > .topic'),
    path: location.pathname + location.search,
    topicLinked: links.some((a) => a.text === to && a.href.includes('/t/' + to)),
    unknownLinked: links.some((a) => a.text.includes(unknown)),
  }
}, TO, UNKNOWN)

async function openIdPost(p, base) {
  await p.goto(`${base}/channel/lobby?topic=${FROM}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell')
  await sleep(1500)
  await p.evaluate((id, body) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    ch.messages = ch.messages.map((m) => (m.msg_id === id ? { ...m, body } : m))
  }, REPLY, BODY)
  await p.waitForSelector(`a.msg-link[href*="/t/${TO}"]`, { visible: true, timeout: 10000 })
}

const srv = await startServer()
const browser = await launch()
try {
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await openIdPost(phone, srv.base)
  let s = await state(phone)
  ok('390px the topic id is a link and the unknown id is not', s.topicLinked && !s.unknownLinked && s.pane, s)

  await phone.tap(`a.msg-link[href*="/t/${TO}"]`)
  await sleep(1500)
  s = await state(phone)
  ok('390px a tap on the topic id opens that topic', s.path.startsWith(`/t/${TO}`) && s.page, s)
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1440, height: 900 })
  await openIdPost(desk, srv.base)
  s = await state(desk)
  ok('1440px the topic id is a link and the unknown id is not', s.topicLinked && !s.unknownLinked, s)

  await desk.click(`a.msg-link[href*="/t/${TO}"]`)
  await sleep(1500)
  s = await state(desk)
  ok('1440px a click on the topic id opens that topic', s.path.startsWith(`/t/${TO}`) && s.page, s)
  await desk.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nid-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
