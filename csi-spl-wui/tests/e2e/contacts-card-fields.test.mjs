// Spec 154 B17 (C48): the contact's picture and its five fields, in a real
// browser on the mock bundle. spool.mock.contacts holds the list and
// spool.mock.contact_photos the pictures' bytes (utils/contacts-client.mjs);
// every document is served with the deployed policy img-src 'self' data:
// (render-wui-firebase-json.sh), so a blob: picture is a CSP violation here.
//   C48-1 a row with a picture shows it as a data: URL, drawn
//   C48-2 a row with no picture keeps the icon and asks nothing
//   C48-3 the card shows the picture, company, job title, birthday, notes;
//         the picture is read once for the page (the cache per sha256)
//   C48-4 the in_only line shows only on a contact cut on its way in
//   C48-5 Edit saves the four new fields; a bad birthday is refused, named
//   C48-6 no CSP violation; CONTROL: a blob: img on the same page IS one
// Red control: contactPhoto returning a blob: URL fails C48-1 and C48-6.
// The import of a file (preview, then import) is contacts-import.test.mjs.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/contacts-card-fields.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const CSP = "img-src 'self' data:"
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const docs = []
/* each document with the deployed img-src, the rest untouched */
async function serveWithCsp(p) {
  /* a service worker answers a reload from its cache, past this header */
  await p.setBypassServiceWorker(true)
  await p.setRequestInterception(true)
  p.on('request', async (req) => {
    if (req.resourceType() !== 'document') return void req.continue()
    try {
      const res = await fetch(req.url())
      const headers = Object.fromEntries([...res.headers].filter(([k]) => !/^(content-encoding|content-length|transfer-encoding)$/i.test(k)))
      await req.respond({ status: res.status, headers: { ...headers, 'content-security-policy': CSP }, body: Buffer.from(await res.arrayBuffer()) })
      docs.push([req.url(), res.status])
    } catch (e) {
      docs.push([req.url(), String(e)])
      await req.continue().catch(() => {})
    }
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const READER = { role: 'regular_user', permissions: [], contacts: true }
/* a 1x1 PNG */
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
const SHA = 'b'.repeat(64)
const base = { google: true, member_id: null, email: null, phone: null, company: '', job_title: '', birthday: null, notes: '', in_only: false, photo: null }
const withPic = { ...base, contact_id: 'k-pic', first_name: 'Paula', last_name: 'Picture', photo: SHA, company: 'Example Oy', job_title: 'Engineer', birthday: '--05-31', notes: 'Met at the fair.\nCall in May.' }
const plain = { ...base, contact_id: 'k-plain', first_name: 'Quinn', last_name: 'Plain' }
const cut = { ...base, contact_id: 'k-cut', first_name: 'Rory', last_name: 'Cut', in_only: true, notes: 'x'.repeat(8000) }

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  p.on('console', (m) => { if (/Refused to load|Content Security Policy/i.test(m.text())) errors.push('console: ' + m.text()) })
  await serveWithCsp(p)
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`))
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* opaque origin on the very first document */ }
  })
  const load = async (path) => {
    await setPageViewport(p, DESKTOP)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, DESKTOP)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT }).catch(() => null)
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(300)
  }
  const waitShown = (sel) => p.waitForSelector(sel, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const text = (sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
  const reads = () => p.evaluate(() => globalThis.SPOOL_MOCK_CONTACT_PHOTO_READS || 0)
  const img = (sel) => p.$eval(sel, (e) => ({ src: e.getAttribute('src').slice(0, 30), drawn: e.complete && e.naturalWidth > 0 })).catch(() => null)
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` }) }

  await load('/people')
  await p.evaluate((me, list, photos) => {
    localStorage.setItem('spool.mock.me', JSON.stringify(me))
    localStorage.setItem('spool.mock.contacts', JSON.stringify(list))
    localStorage.setItem('spool.mock.contact_photos', JSON.stringify(photos))
    localStorage.removeItem('spool.people.filter')
  }, READER, [withPic, plain, cut], { 'k-pic': PNG })
  await load('/people')
  await waitShown('[data-test=people-contact-row]')

  /* C48-1, C48-2: the rows */
  const rowPic = `[data-test=people-contact-row][data-key="k-pic"] [data-test=people-contact-photo]`
  await waitShown(rowPic)
  const pic = await img(rowPic)
  ok('C48-1 the row with a picture shows it as a data: URL, drawn', Boolean(pic) && pic.src.startsWith('data:image/png;base64,') && pic.drawn, pic)
  const bare = await p.$$eval('[data-test=people-contact-row]:not([data-key="k-pic"]) [data-test=people-contact-photo]', (l) => l.length)
  ok('C48-2 the rows with no picture keep the icon, and only one picture is read', bare === 0 && (await reads()) === 1, { bare, reads: await reads() })
  await shot('rows-1440')

  /* C48-3: the card, reached in the page, so the picture's cache holds */
  await p.click('[data-test=people-contact-row][data-key="k-pic"]')
  await waitShown('[data-test=contact-card]')
  await waitShown('[data-test=contact-photo]')
  const card = {
    photo: await img('[data-test=contact-photo]'),
    company: await text('[data-test=contact-company]'),
    job: await text('[data-test=contact-job_title]'),
    birthday: await text('[data-test=contact-birthday]'),
    notes: await p.$eval('[data-test=contact-notes]', (e) => e.innerText).catch(() => ''),
    reads: await reads(),
  }
  ok('C48-3 the card shows the picture (data:), company, job title, birthday and notes', Boolean(card.photo?.src.startsWith('data:image/png')) && card.company === 'Example Oy' && card.job === 'Engineer' && card.birthday === '--05-31' && card.notes === 'Met at the fair.\nCall in May.', card)
  ok('C48-3b the card asked no second read of the same picture', card.reads === 1, { reads: card.reads })
  ok('C48-4 no in_only line on a contact that syncs back', !(await p.$('[data-test=contact-in-only]')))
  await shot('card-1440')

  /* C48-5: edit the four */
  await p.click('[data-test=contact-edit]')
  await waitShown('[data-test=contact-form]')
  const set = async (key, value) => {
    await p.$eval(`[data-test=contact-input-${key}]`, (e) => { e.value = '' })
    await p.type(`[data-test=contact-input-${key}]`, value)
  }
  await set('birthday', '31.05.1990')
  await p.click('[data-test=contact-save]')
  await waitShown('[data-test=contact-error]')
  ok('C48-5a a birthday that is no date is refused, and the form says so', (await text('[data-test=contact-error]')) === 'The birthday is not a date.', { said: await text('[data-test=contact-error]') })
  await set('birthday', '1990-05-31')
  await set('company', 'Other Ab')
  await set('job_title', 'Lead')
  await set('notes', 'One line')
  await p.click('[data-test=contact-save]')
  await waitShown('[data-test=contact-card]')
  const saved = { company: await text('[data-test=contact-company]'), job: await text('[data-test=contact-job_title]'), birthday: await text('[data-test=contact-birthday]'), notes: await text('[data-test=contact-notes]') }
  ok('C48-5b Edit saves company, job title, birthday and notes', saved.company === 'Other Ab' && saved.job === 'Lead' && saved.birthday === '1990-05-31' && saved.notes === 'One line', saved)

  /* C48-4: the cut one */
  await p.click('[data-test=people-contact-row][data-key="k-cut"]')
  await waitShown('[data-test=contact-in-only]')
  ok('C48-4b the in_only line shows on a contact cut on its way in', (await text('[data-test=contact-in-only]')) === 'Too long to sync back; edit it in Google.')
  ok('C48-4c a contact with no picture shows none on its card', !(await p.$('[data-test=contact-photo]')))

  /* C48-6 */
  const seen = await p.evaluate(() => window.__csp.slice())
  ok('C48-6 no CSP violation on the rows and the card', seen.length === 0 && !errors.some((e) => e.startsWith('console:')), seen.slice(0, 3))
  const control = await p.evaluate(async () => {
    const url = URL.createObjectURL(new Blob([Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='), (c) => c.charCodeAt(0))], { type: 'image/png' }))
    const el = Object.assign(document.createElement('img'), { src: url })
    document.body.append(el)
    await new Promise((r) => setTimeout(r, 500))
    el.remove()
    return window.__csp.filter((v) => v.startsWith('img-src')).length
  })
  ok('C48-6 CONTROL: a blob: picture on the same page is a CSP violation', control >= 1, { control, documents: docs.length })

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e) && !e.startsWith('console:'))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
