// Contacts add, open, edit, delete: live proof, signed in, against a deployed WUI.
//
// SPL-4661: "Could not save the contact." although the row was saved. The mock
// bundle's e2e cannot see the hub's real answers, this run can. It makes one
// contact with synthetic values under the signed-in test person and erases it;
// it reads no other row. Never run it with a person's own login.
//
//   BASE=https://dev.<domain> EMAIL=<test person> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/contacts-crud-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

let failed = 0
const step = (name, ok, ev = {}) => {
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ headless: true, executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  const p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const calls = []
  p.on('response', (r) => {
    const u = new URL(r.url())
    const m = r.request().method()
    if (u.pathname.startsWith('/v1/me/contacts') && m !== 'OPTIONS') calls.push(`${m} ${r.status()}`)
  })
  const shown = (sel) => p.waitForSelector(sel, { visible: true, timeout: 20000 }).then(() => true, () => false)
  const text = (sel) => p.$eval(sel, (el) => el.textContent.trim()).catch(() => null)
  const shot = (name) => p.screenshot({ path: `${OUT}/${name}.png` })
  const type = async (key, value) => {
    await p.click(`[data-test=contact-input-${key}]`)
    await p.type(`[data-test=contact-input-${key}]`, value)
  }
  const saved = () => p.$('[data-test=contact-error]').then((e) => !e)

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const in_ = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', in_)
  if (!in_) throw new Error('not signed in')
  console.log('build', await p.evaluate(() => JSON.stringify(globalThis.__BUILD__ || null)))

  await p.goto(`${BASE}/people/contact/new`, { waitUntil: 'networkidle2' })
  step('add: the form opens', await shown('[data-test=contact-form]'))
  await type('first_name', 'FirstName')
  await type('last_name', 'LastName')
  await type('email', 'first.last@example.com')
  await type('phone', '+1 555 010 0000')
  await shot('1-add-form')
  await p.click('[data-test=contact-save]')
  const card = await shown('[data-test=contact-card]')
  step('add: the save opens the card, no error', card && await saved(), { error: await text('[data-test=contact-error]') })
  const url = p.url()
  step('add: the card is the new contact\'s', /\/people\/contact\/[0-9a-f-]{36}$/.test(url))
  await shot('2-added')

  await p.goto(url, { waitUntil: 'networkidle2' })
  step('open: a fresh load shows the details', await shown('[data-test=contact-card]')
    && (await text('[data-test=contact-first-name]')) === 'FirstName'
    && (await text('[data-test=contact-email]')) === 'first.last@example.com')
  await shot('3-opened')

  await p.click('[data-test=contact-edit]')
  await shown('[data-test=contact-form]')
  await type('first_name', 'x')
  await p.$eval('[data-test=contact-input-email]', (el) => { el.focus(); el.select() })
  await p.keyboard.press('Backspace')
  await p.click('[data-test=contact-save]')
  await shown('[data-test=contact-card]')
  step('edit: the card shows the change, no error', await saved() && (await text('[data-test=contact-first-name]')) === 'FirstNamex')
  await p.goto(url, { waitUntil: 'networkidle2' })
  await shown('[data-test=contact-card]')
  step('edit: a fresh load keeps it, the emptied email is cleared', (await text('[data-test=contact-first-name]')) === 'FirstNamex'
    && (await text('[data-test=contact-email]')) === '-')
  await shot('4-edited')

  await p.click('[data-test=contact-delete]')
  await shown('[data-test=contact-delete-ok]')
  await shot('5-delete-confirm')
  await p.click('[data-test=contact-delete-ok]')
  await p.waitForFunction(() => location.pathname.endsWith('/people'), { timeout: 15000 }).catch(() => null)
  await sleep(300)
  step('delete: leaves for the panel', p.url().endsWith('/people'))
  await p.goto(url, { waitUntil: 'networkidle2' })
  step('delete: the card is gone', await shown('[data-test=contact-missing]'))
  await shot('6-deleted')
  console.log('calls', calls.join(', '))
} catch (e) {
  step('ran to the end', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
}
process.exit(failed ? 1 : 0)
