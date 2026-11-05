// SPL-4897 (spec 155 2.6; owner HUM-10, prd t1 topic 2f4311d9, msg c6bf6b39:
// "Remove tje archive buton, the archive section should be used for that"),
// on the mock bundle at 1440 px and at 390 px:
//   - a note archived from the open note shows in the Archive section's Notes
//     part, beside the note that was archived already (mock-note-4)
//   - its row carries the priority beside the title at 1440 px, not at 390 px
//   - a click on an archived row opens the note in place, on the Archive page
//   - Unarchive takes it off the Archive and puts it back in Notes
// CONTROL: on the bundle of the parent commit (no Notes part in archive.vue)
// the check "the Archive lists ..." FAILS.
//
// Run:
//   node tests/e2e/archive-notes.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/archive-notes.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const noteRows = (p) => p.$$eval('[data-test=notes-row]', (els) => els.map((e) => e.getAttribute('data-note-id')))
const archivedRows = (p) => p.$$eval('[data-test=archive-note-row]', (els) => els.map((e) => e.getAttribute('data-note-id')))
const waitDetail = (p, id) => p.waitForSelector(`[data-test=note-detail][data-note-id="${id}"][data-state=ready]`, { visible: true, timeout: 15000 }).then(() => true, () => false)
const waitGone = (p) => p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).then(() => true, () => false)
const waitFor = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 15000 }).then(() => true, () => false)
const onPath = (p, want) => p.evaluate(() => location.pathname).then((at) => at.replace(/\/+$/, '').endsWith(want))
const chipShown = (p, id) => p.$eval(`[data-test=archive-note-row][data-note-id="${id}"] [data-test=archive-note-priority]`, (e) => getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0).catch(() => false)

async function closeDetail(p, touch) {
  if (touch) await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  else await p.keyboard.press('Escape')
  return waitGone(p)
}

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  check(`${tag}: Notes lists the notes that are not archived`, !(await noteRows(p)).includes('mock-note-4'), await noteRows(p))
  await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
  await waitDetail(p, 'mock-note-2')
  await p.click('[data-test=note-archive]')
  check(`${tag}: Archive in the open note closes it`, await waitGone(p))
  check(`${tag}: and the note leaves Notes`, !(await noteRows(p)).includes('mock-note-2'), await noteRows(p))

  await go(p, '/archive')
  await waitFor(p, '[data-test=archive-page]')
  await waitFor(p, '[data-test=archive-note-row]')
  const got = await archivedRows(p)
  check(`${tag}: the Archive lists the archived notes, newest archived first`, JSON.stringify(got) === JSON.stringify(['mock-note-2', 'mock-note-4']), got)
  check(`${tag}: the topics part is still there`, Boolean(await p.$('[data-test=archive-list], [data-test=archive-empty]')))
  if (touch) check(`${tag}: no priority chip on a phone`, !(await chipShown(p, 'mock-note-4')))
  else check(`${tag}: the priority chip beside the title`, await chipShown(p, 'mock-note-4'))
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))

  await p.click('[data-test=archive-note-row][data-note-id="mock-note-4"] [data-test=archive-note-open]')
  check(`${tag}: a click opens the archived note`, await waitDetail(p, 'mock-note-4'))
  check(`${tag}: on the Archive page`, await onPath(p, '/archive'))
  check(`${tag}: closing it stays on the Archive`, (await closeDetail(p, touch)) && (await onPath(p, '/archive')))

  await p.click('[data-test=archive-note-row][data-note-id="mock-note-2"] [data-test=archive-note-unarchive]')
  const off = await p.waitForFunction(() => !document.querySelector('[data-test=archive-note-row][data-note-id="mock-note-2"]'), { timeout: 10000 }).then(() => true, () => false)
  check(`${tag}: Unarchive takes it off the Archive`, off, await archivedRows(p))
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  check(`${tag}: and it is back in Notes`, (await noteRows(p)).includes('mock-note-2'), await noteRows(p))
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [390, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\narchive-notes: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
