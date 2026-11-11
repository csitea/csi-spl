// Spec 154 B17 slice a: the CSV import dialog, in a real browser, on the mock
// bundle. SPL-5279: its entry is on the Add contact form, reached by the
// People panel's round + (ADD). Fixtures are FirstName LastName and example.com.
//   C48  pick a file, see the preview (nothing written), import, the rows appear
//        in the panel; no CSP violation
//   C47  the dialog is in no first-paint chunk of 200.html, and loads on opening
//   R    an unknown file shows the refusal; the same file is not half imported
//   P    390x664: the dialog has no sideways scroll, its buttons can be tapped
// CONTROL: C47-1 needs the marker to be found in the chunk the opening loads, so
// a marker that matches nothing cannot pass "absent". C48-2 is the preview's
// twin of C48-5: the same list read before and after the Import click.
// Red control: a static import of the dialog in ChannelSidebar.vue fails C47-2.
// Red control (SPL-5279): the old panel button back beside the + fails C48-0.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/contacts-import.test.mjs
import { createRequire } from 'node:module'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const MARKER = 'contacts-import-file'
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const PHONE = { name: '390', width: 390, height: 664 }
const ME = { role: 'regular_user', permissions: [], contacts: true }
const OFF = { role: 'regular_user', permissions: [], contacts: false }
const GOOD = [
  'first_name,last_name,email,phone,google_resource',
  'FirstName,LastName,first.last@example.com,,',
  'FirstName,LastName,second.last@example.com,,',
  ',,not-an-address,,',
].join('\n')

const dir = mkdtempSync(join(tmpdir(), 'contacts-import-'))
const goodFile = join(dir, 'good.csv')
const badFile = join(dir, 'bad.csv')
writeFileSync(goodFile, GOOD)
writeFileSync(badFile, 'a,b\n1,2\n')
const phoneFile = join(dir, 'phone.csv')
writeFileSync(phoneFile, 'first_name,last_name,email,phone,google_resource\n,,,+1 555 010 0001,\n')
const goneFile = join(dir, 'gone.csv')
writeFileSync(goneFile, GOOD)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  const csp = []
  const chunks = new Map()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  p.on('console', (m) => { if (/Content Security Policy/i.test(m.text())) csp.push(m.text()) })
  p.on('response', async (r) => {
    if (!/\.js(\?|$)/.test(r.url())) return
    try { chunks.set(r.url(), await r.text()) } catch { /* a redirect or a closed page */ }
  })
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* opaque origin on the very first document */ }
  })

  const load = async (vp, path) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT }).catch(() => null)
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(500)
  }
  const seed = (me, list) => p.evaluate((m, l) => {
    localStorage.setItem('spool.mock.me', JSON.stringify(m))
    localStorage.setItem('spool.mock.contacts', JSON.stringify(l))
  }, me, list)
  const stored = () => p.evaluate(() => JSON.parse(localStorage.getItem('spool.mock.contacts') || '[]').length)
  const shown = (sel) => p.evaluate((s) => {
    const e = document.querySelector(s)
    return Boolean(e && e.getBoundingClientRect().width > 0)
  }, sel)
  const waitShown = (sel) => p.waitForSelector(sel, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const text = (sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` }) }
  const rowNames = () => p.$$eval('[data-test=people-contact-row] .label', (l) => l.map((e) => e.textContent.trim()))
  const OPEN = '[data-testid=people-import-contacts]'
  const ADD = '[data-testid=people-add-contact]'
  /* the + opens the empty form; Import from file sits on it */
  const toForm = async () => { await waitShown(ADD); await p.click(ADD); return waitShown(OPEN) }
  const FILE = `[data-test=${MARKER}]`
  const pick = async (path) => { await (await p.$(FILE)).uploadFile(path) }
  const firstPaint = () => p.evaluate(async () => {
    const html = await (await fetch('/200.html')).text()
    return [...html.matchAll(/(?:src|href)="([^"]+\.js)"/g)].map((m) => m[1])
  })
  const hasMarker = async (urls) => {
    const out = []
    for (const u of urls) {
      const body = await p.evaluate(async (x) => (await fetch(x)).text(), u)
      if (body.includes(MARKER)) out.push(u)
    }
    return out
  }

  /* the switch off: no entry */
  await load(DESKTOP, '/people')
  await seed(OFF, [])
  await load(DESKTOP, '/people')
  ok('C24f contacts false: no + and no Import from file', await shown('[data-testid=sidebar-panel-people]') && !(await shown(ADD)) && !(await shown(OPEN)))

  /* C47 + C48 */
  await seed(ME, [])
  await load(DESKTOP, '/people')
  const before = new Set(chunks.keys())
  const initial = await firstPaint()
  ok('C47-0 200.html names first-paint chunks', initial.length > 0, { n: initial.length })
  ok('C48-0 the panel has the + and no Import button of its own', await waitShown(ADD) && !(await shown(OPEN)))
  ok('C48-1 the + opens the form, Import from file on it', await toForm() && await shown('[data-test=contact-form]'), { said: await text(OPEN) })
  await p.click(OPEN)
  ok('C48-1b the dialog opens', await waitShown(FILE))
  await sleep(300)
  const loaded = [...chunks.entries()].filter(([u, b]) => !before.has(u) && b.includes(MARKER)).map(([u]) => u)
  ok('C47-1 CONTROL: the opening loads a chunk holding the dialog', loaded.length > 0, { n: loaded.length })
  const carriers = await hasMarker(initial)
  ok('C47-2 no first-paint chunk holds the dialog', carriers.length === 0, carriers)
  ok('C48-1c nothing to import yet: Import is off', await p.$eval('[data-test=contacts-import-start]', (b) => b.disabled))

  await pick(badFile)
  ok('R-1 an unknown file shows the refusal', await waitShown('[data-test=contacts-import-error]'), { said: await text('[data-test=contacts-import-error]') })
  ok('R-2 a refused file writes nothing', (await stored()) === 0)

  await pick(goodFile)
  ok('C48-3 the preview counts', await waitShown('[data-test=contacts-import-would-add]') && (await text('[data-test=contacts-import-would-add]')) === '2', { add: await text('[data-test=contacts-import-would-add]') })
  ok('C48-3b the refusal is gone', !(await shown('[data-test=contacts-import-error]')))
  const skippedLine = await text('[data-test=contacts-import-skipped] li')
  ok('C48-3c a skipped row: its line and reason, no value', /^Line 4: /.test(skippedLine) && !skippedLine.includes('not-an-address'), { said: skippedLine })
  ok('C48-2 the preview wrote nothing', (await stored()) === 0)
  await shot('import-preview-1440')

  await p.click('[data-test=contacts-import-start]')
  ok('C48-4 the result counts', await waitShown('[data-test=contacts-import-added]') && (await text('[data-test=contacts-import-added]')) === '2', { added: await text('[data-test=contacts-import-added]') })
  ok('C48-5 the import wrote the good rows', (await stored()) === 2, { n: await stored() })
  await sleep(300)
  ok('C48-6 the panel lists them, no reload', JSON.stringify(await rowNames()) === JSON.stringify(['FirstName LastName', 'FirstName LastName']), await rowNames())
  await p.click('[data-test=contacts-import-close]')
  await sleep(200)
  ok('C48-7 Close closes it', !(await shown('[data-test=contacts-import]')))
  await p.click(OPEN)
  await waitShown(FILE)
  ok('C48-8 a new opening starts empty', !(await shown('[data-test=contacts-import-counts]')))
  await pick(goodFile)
  await waitShown('[data-test=contacts-import-counts]')
  ok('C48-9 the same file again: 0 to add, Import off', (await text('[data-test=contacts-import-would-add]')) === '0' && await p.$eval('[data-test=contacts-import-start]', (b) => b.disabled))

  /* a held number: one row, one already there */
  await seed(ME, [{ contact_id: 'k-phone', first_name: '', last_name: '', email: null, phone: '15550100001', google: false, member_id: null }])
  await load(DESKTOP, '/people')
  await p.click('[data-testid=sidebar-tab-people]')
  await toForm()
  await p.click(OPEN)
  await waitShown(FILE)
  await pick(phoneFile)
  await waitShown('[data-test=contacts-import-already-there]')
  ok('C48-11 a phone-only row is counted once', (await text('[data-test=contacts-import-already-there]')) === '1', { n: await text('[data-test=contacts-import-already-there]') })

  /* a failed import: the picker is empty, so the same file can be picked again */
  await p.click('[data-test=contacts-import-close]')
  await sleep(200)
  await p.click(OPEN)
  await waitShown(FILE)
  await pick(goneFile)
  await waitShown('[data-test=contacts-import-would-add]')
  writeFileSync(goneFile, GOOD + '\n')
  await p.click('[data-test=contacts-import-start]')
  ok('C48-12 a failed import says so', await waitShown('[data-test=contacts-import-error]'))
  ok('C48-13 and the picker is empty for the retry', (await p.$eval(FILE, (i) => i.files.length)) === 0)

  /* phone */
  await seed(ME, [])
  await load(PHONE, '/people')
  await p.click('[data-testid=sidebar-tab-people]')
  await toForm()
  ok('P-1 390 the entry can be tapped', (await p.$eval(OPEN, (b) => b.getBoundingClientRect().height)) >= 44)
  await p.click(OPEN)
  await waitShown(FILE)
  await pick(goodFile)
  await waitShown('[data-test=contacts-import-counts]')
  ok('P-2 390 no sideways scroll', await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth && [...document.querySelectorAll('[data-test=contacts-import] *')].every((e) => e.getBoundingClientRect().right <= window.innerWidth + 1)))
  ok('P-3 390 both buttons >= 44 px tall', (await p.$$eval('[data-test=contacts-import] .btn', (l) => l.filter((b) => b.getBoundingClientRect().height < 44).length)) === 0)
  await shot('import-preview-390x664')

  ok('C48-10 no CSP violation', csp.length === 0, csp.slice(0, 2))
  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
  rmSync(dir, { recursive: true, force: true })
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
