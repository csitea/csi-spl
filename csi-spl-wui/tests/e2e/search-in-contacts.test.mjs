// SPL-5175, spec 154 C11b: `/s in:contacts <word>` in the Omnibox reaches the
// search whole, the left list shows the reader's own contact, and the hit
// opens its card. Mock tenant, real browser.
// CONTROL: a word no contact holds and in:#contacts (the channel) list none.
// Red control: before SPL-5175 step 2 fails, SEARCH_GROUPS had no contacts.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/search-in-contacts.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const BOX = '[data-test=top-bar-omnibox] textarea'
const HIT = '[data-testid=sidebar-panel-search] [data-testid=left-list][data-mode=search] [data-testid=left-entry][data-type=contacts]'
const CONTACT = { contact_id: 'k-1', first_name: 'FirstName', last_name: 'LastName', email: 'first.last@example.com', phone: null, google: false, member_id: null }

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const server = await startServer()
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: { width: 1440, height: 900 },
  args: CHROME_LAUNCH_ARGS,
})
try {
  const errors = []
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument((c) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.me', JSON.stringify({ role: 'regular_user', permissions: [], contacts: true }))
      localStorage.setItem('spool.mock.contacts', JSON.stringify([c]))
    } catch { /* opaque origin on the very first document */ }
  }, CONTACT)
  const search = async (line) => {
    await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    await p.click(BOX)
    await p.type(BOX, line)
    await p.$eval('[data-test=omnibox-search]', (el) => el.click())
    await sleep(800)
    return { q: new URL(p.url()).searchParams.get('q'), hits: (await p.$$(HIT)).length }
  }

  let r = await search('/s in:contacts first')
  ok('1 the /s line reaches the search whole', r.q === 'in:contacts first', r)
  ok('2 the reader\'s contact is listed', r.hits === 1, r)
  const label = await p.$eval(HIT, (e) => e.textContent).catch(() => '')
  ok('3 the hit names the contact and its email', label.includes('FirstName LastName') && label.includes('first.last@example.com'), { label })
  await p.$eval(HIT, (e) => e.click()).catch(() => null)
  await sleep(800)
  ok('4 the hit opens the contact\'s card', new URL(p.url()).pathname.endsWith('/people/contact/k-1'), { url: p.url() })
  r = await search('/s in:contacts nomatchword')
  ok('5 CONTROL: a word no contact holds lists none', r.hits === 0 && r.q === 'in:contacts nomatchword', r)
  r = await search('/s in:#contacts first')
  ok('6 CONTROL: in:#contacts is the channel, no contact', r.hits === 0, r)
  ok('7 no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((x) => !x.ok).length
console.log(`search-in-contacts: ${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
