// t1 6e21c7d8 (owner: "This lin does not work on mobile"): a post that links
// another topic ("Moved to the new discussion: https://<host>/t/<id>") is
// read in the open topic pane, which on a phone is level 3 and the ONLY
// panel on screen. A tap on the link must open the linked topic there, and
// Back must return to the post the reader tapped it in. Also: the same link
// on desktop, and the /t/<id> URL typed into a phone's address bar.
// HUM-10 (t1 36ea84a6): a link opens the topic in its channel view, not the
// Topics view; a URL typed into the address bar is no link and keeps /t/.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/phone-topic-link.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the topic the reader is in, and the topic its post links to */
const FROM = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TO = 'abababab-abab-4bab-8bab-abababababab'
/* a reply of FROM whose body becomes the link post */
const REPLY = '33333333-3333-4333-8333-333333333333'

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

/** What the reader sees: the level, which panels show, and the topic on screen. */
const state = (p) => p.evaluate(() => {
  const sh = document.querySelector('.spool-shell')
  const vis = (s) => {
    const e = document.querySelector(s)
    if (!e) return false
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0
  }
  return {
    level: sh ? sh.getAttribute('data-mobile-level') : null,
    main: vis('.spool-shell > .spool-main'),
    pane: vis('.spool-shell > .topic'),
    /* the /t/<id> page's root: visible = the linked topic is on screen */
    page: vis('.spool-main [data-test=topic-root]'),
    link: vis('.spool-shell > .topic a.msg-link'),
    path: location.pathname + location.search,
  }
})

/** Open FROM in the topic pane and turn one of its replies into the link post. */
async function openLinkPost(p, base) {
  await p.goto(`${base}/channel/lobby?topic=${FROM}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell')
  await sleep(1500)
  await p.evaluate((id, body) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    ch.messages = ch.messages.map((m) => (m.msg_id === id ? { ...m, body } : m))
  }, REPLY, `Moved to the new discussion: ${new URL(base).origin}/t/${TO}`)
  await p.waitForSelector('.spool-shell > .topic a.msg-link', { visible: true, timeout: 10000 })
}

const srv = await startServer()
const browser = await launch()
try {
  const width = 390
  const at = `${width}px`
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
  await openLinkPost(phone, srv.base)
  let s = await state(phone)
  ok(`${at} the link post shows in the topic pane, level 3`, s.level === '3' && s.pane && !s.main && s.link, s)

  await phone.tap('.spool-shell > .topic a.msg-link')
  await sleep(1500)
  s = await state(phone)
  ok(`${at} a tap on the topic link opens that topic on screen, in its channel`, s.path.startsWith(`/channel/lobby?topic=${TO}`) && s.level === '3' && s.pane && !s.main, s)

  await phone.goBack()
  await sleep(1500)
  s = await state(phone)
  ok(`${at} Back returns to the post the link was tapped in`, s.path.includes(`topic=${FROM}`) && s.level === '3' && s.pane && !s.main, s)

  await phone.goto(`${srv.base}/t/${TO}`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  s = await state(phone)
  ok(`${at} the /t/ link typed into the address bar opens the topic`, s.page && s.main, s)
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1440, height: 900 })
  await openLinkPost(desk, srv.base)
  await desk.click('.spool-shell > .topic a.msg-link')
  await sleep(1500)
  s = await state(desk)
  ok('1440px desktop: a click on the topic link opens that topic in its channel', s.path.startsWith(`/channel/lobby?topic=${TO}`) && s.pane && s.main, s)
  await desk.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-topic-link: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
