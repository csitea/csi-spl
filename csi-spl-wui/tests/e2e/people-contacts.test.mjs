// Spec 154 B9: contacts inside the People panel, in a real browser, mock tenant
// signed in. localStorage spool.mock.me plays GET /v1/view/me (its contacts
// switch and permissions); spool.mock.contacts holds the list, and
// globalThis.SPOOL_MOCK_CONTACTS_READS counts its reads (utils/contacts-client.mjs).
//   C24  no new rail tab; add a contact, find it, open its card; Message for a
//        member here, no Message for a non-member; Invite with members.invite,
//        hidden without it
//   C24d the filter hides group 3, keeps the tag, survives a reload
//   C24f contacts: false = members only, no filter, no Add button, no read;
//        twin: contacts: true reads the list once
//   P    390x664: no sideways scroll, the tools and the card's buttons fit
// CONTROL: C24f-1 asserts the panel itself is on screen, so a panel that never
// opened cannot pass "no filter"; C24-1 compares the rail with contacts off.
// Red control: on master before B9 C24-2 fails, there is no filter.
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/people-contacts.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
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
const INVITER = { role: 'admin', permissions: ['members.invite'], contacts: true }
const READER = { role: 'regular_user', permissions: [], contacts: true }
const OFF = { role: 'admin', permissions: ['members.invite'], contacts: false }

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      const theme = localStorage.getItem('spool.test.theme')
      if (theme) localStorage.setItem('spool-theme', theme)
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
    localStorage.removeItem('spool.people.filter')
  }, me, list)
  const shown = (sel) => p.evaluate((s) => {
    const e = document.querySelector(s)
    return Boolean(e && e.getBoundingClientRect().width > 0)
  }, sel)
  const waitShown = (sel) => p.waitForSelector(sel, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const text = (sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
  const reads = () => p.evaluate(() => globalThis.SPOOL_MOCK_CONTACTS_READS || 0)
  const railCount = () => p.$$eval('[id^="sidebar-tab-"]', (l) => l.length)
  const rowNames = () => p.$$eval('[data-test=people-contact-row] .label', (l) => l.map((e) => e.textContent.trim()))
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` }) }
  const type = async (test, value) => {
    await p.click(`[data-test=contact-input-${test}]`)
    await p.type(`[data-test=contact-input-${test}]`, value)
  }
  const PANEL = '[data-testid=sidebar-panel-people]'
  const member = (key) => `${PANEL} .nav-item[data-key="${key}"]`
  const stranger = { contact_id: 'k-out', first_name: 'Olive', last_name: 'Outer', email: 'olive.outer@example.com', phone: '+358 40 000 0000', google: false, member_id: null }
  const zed = { contact_id: 'k-zed', first_name: 'Zed', last_name: 'Zeta', email: null, phone: null, google: false, member_id: null }
  const twin = { contact_id: 'k-in', first_name: 'Inner', last_name: 'Person', email: 'inner@example.com', phone: null, google: false, member_id: 'HUM-2' }

  /* C24f: the switch off */
  await load(DESKTOP, '/people')
  await seed(OFF, [stranger])
  await load(DESKTOP, '/people')
  ok('C24f-1 CONTROL: the People panel is on screen, its members listed', await shown(PANEL) && await shown(`${PANEL} .nav-item`))
  ok('C24f-2 contacts false: no filter, no Add button', !(await shown('[data-testid=people-tools]')) && !(await shown('[data-testid=people-add-contact]')))
  ok('C24f-3 contacts false: no contact row', (await rowNames()).length === 0)
  ok('C24f-4 contacts false: the list is never read', (await reads()) === 0, { reads: await reads() })
  const railOff = await railCount()

  /* C24: the switch on */
  await seed(INVITER, [stranger, zed, twin])
  await load(DESKTOP, '/people')
  ok('C24f-5 twin: contacts true reads the list once', (await reads()) === 1, { reads: await reads() })
  ok('C24-1 no new rail tab', railOff > 0 && (await railCount()) === railOff, { off: railOff, on: await railCount() })
  ok('C24-2 the filter and Add contact show', await waitShown('[data-testid=people-filter-workspace]') && await shown('[data-testid=people-add-contact]'))
  await waitShown('[data-test=people-contact-row]')
  ok('C24-3 group 3 lists the others A-Z, the matched contact not twice', JSON.stringify(await rowNames()) === JSON.stringify(['Olive Outer', 'Zed Zeta']), await rowNames())
  ok('C24e the matched member carries the contact tag', await shown(`${member('HUM-2')} [data-testid=people-contact-tag]`))
  ok('C24-4 a member with no contact carries no tag', !(await shown(`${member('HUM-1')} [data-testid=people-contact-tag]`)))
  await shot('panel-1440')

  /* add, find, open */
  await p.click('[data-testid=people-add-contact]')
  ok('C24-5 Add contact opens the empty form', await waitShown('[data-test=contact-form]'))
  await p.click('[data-test=contact-save]')
  ok('C24-6 an empty contact is refused', (await waitShown('[data-test=contact-error]')) && (await text('[data-test=contact-error]')) === 'Enter a name, an email or a phone.', { said: await text('[data-test=contact-error]') })
  await type('first_name', 'Mia')
  await type('last_name', 'Mock')
  await type('email', 'mia.mock@example.com')
  await p.click('[data-test=contact-save]')
  ok('C24-7 saved, its card opens', await waitShown('[data-test=contact-card]') && (await text('[data-test=contact-email]')) === 'mia.mock@example.com')
  await sleep(300)
  ok('C24-8 the panel finds it at its A-Z place', JSON.stringify(await rowNames()) === JSON.stringify(['Mia Mock', 'Olive Outer', 'Zed Zeta']), await rowNames())
  ok('C24-9 the panel re-read after the write, once', (await reads()) === 2, { reads: await reads() })

  /* a non-member: Invite, no Message */
  await p.evaluate(() => [...document.querySelectorAll('[data-test=people-contact-row]')].find((a) => a.textContent.includes('Olive')).click())
  await waitShown('[data-test=contact-card]')
  await p.waitForFunction(() => document.querySelector('[data-test=contact-email]')?.textContent.includes('olive'), { timeout: 5000 }).catch(() => null)
  ok('C24-10 a non-member has no Message', !(await shown('[data-test=contact-message]')))
  ok('C24-11 members.invite shows Invite', await shown('[data-test=contact-invite]'))
  ok('C24-12 the email is a link in the reader\'s app', (await p.$eval('[data-test=contact-email] a', (a) => a.href).catch(() => '')).includes('olive.outer%40example.com'))
  ok('C24-13 the phone is a link', Boolean(await p.$eval('[data-test=contact-phone] a', (a) => a.href).catch(() => '')))
  await shot('card-1440')
  await p.click('[data-test=contact-invite]')
  ok('C24-14 Invite says it went out', (await waitShown('[data-test=contact-said]')) && (await text('[data-test=contact-said]')).includes('olive.outer@example.com'))

  /* a member here: Message, no Invite */
  await load(DESKTOP, '/people/contact/k-in')
  await waitShown('[data-test=contact-card]')
  ok('C24-15 a member here shows Message', await shown('[data-test=contact-message]'))
  ok('C24-16 and never Invite', !(await shown('[data-test=contact-invite]')))
  await p.click('[data-test=contact-message]')
  await p.waitForFunction(() => location.pathname.includes('/dm/'), { timeout: 8000 }).catch(() => null)
  ok('C24-17 Message opens the DM', (await p.evaluate(() => decodeURIComponent(location.pathname))).endsWith('/dm/HUM-2@box-wui'), await p.evaluate(() => location.pathname))

  /* the member card's one line */
  await load(DESKTOP, '/people/HUM-2')
  ok('C24-18 the member card links to the contact', await waitShown('[data-test=person-in-contacts] a') && (await p.$eval('[data-test=person-in-contacts] a', (a) => a.getAttribute('href'))).endsWith('/people/contact/k-in'))
  await load(DESKTOP, '/people/HUM-1')
  await waitShown('[data-test=person-card]')
  ok('C24-19 twin: another member has no such line', !(await shown('[data-test=person-in-contacts]')))

  /* without the permission */
  await seed(READER, [stranger])
  await load(DESKTOP, '/people/contact/k-out')
  await waitShown('[data-test=contact-card]')
  ok('C24-20 without members.invite: no Invite', !(await shown('[data-test=contact-invite]')))
  ok('C24-21 the links stay', await shown('[data-test=contact-email] a'))

  /* edit, delete, an unknown id */
  await seed(INVITER, [stranger, twin])
  await load(DESKTOP, '/people/contact/k-out')
  await waitShown('[data-test=contact-edit]')
  await p.click('[data-test=contact-edit]')
  await waitShown('[data-test=contact-form]')
  await type('first_name', 'x')
  await p.click('[data-test=contact-save]')
  await waitShown('[data-test=contact-card]')
  ok('C24-22 Edit saves', (await text('[data-test=contact-first-name]')) === 'Olivex', { first: await text('[data-test=contact-first-name]') })
  await p.click('[data-test=contact-edit]')
  await waitShown('[data-test=contact-form]')
  await p.$eval('[data-test=contact-input-email]', (el) => { el.focus(); el.select() })
  await p.keyboard.press('Backspace')
  await p.click('[data-test=contact-save]')
  await waitShown('[data-test=contact-card]')
  ok('C24-22b Edit clears an emptied email', (await text('[data-test=contact-email]')) === '-', { email: await text('[data-test=contact-email]') })
  await p.click('[data-test=contact-delete]')
  await waitShown('[data-test=contact-delete-ok]')
  await p.click('[data-test=contact-delete-ok]')
  await p.waitForFunction(() => location.pathname.endsWith('/people'), { timeout: 8000 }).catch(() => null)
  await sleep(300)
  ok('C24-23 Delete leaves the panel', (await rowNames()).length === 0, await rowNames())
  await load(DESKTOP, '/people/contact/nobody')
  ok('C24-24 an unknown id says so', await waitShown('[data-test=contact-missing]'))
  await load(DESKTOP, '/people/contact/k-in')
  await waitShown('[data-test=contact-edit]')
  await p.click('[data-test=contact-edit]')
  await waitShown('[data-test=contact-form]')
  await type('first_name', 'x')
  await p.click('[data-test=contact-save]')
  await waitShown('[data-test=contact-card]')
  ok('C24-24b a member\'s card keeps Message after an edit', await waitShown('[data-test=contact-message]') && !(await shown('[data-test=contact-invite]')))

  /* C24d: the filter */
  await seed(INVITER, [stranger, twin])
  await load(DESKTOP, '/people')
  await waitShown('[data-test=people-contact-row]')
  await p.click('[data-testid=people-filter-workspace]')
  await sleep(200)
  ok('C24d-1 In this workspace: contacts gone', (await rowNames()).length === 0)
  ok('C24d-2 the matched member keeps its tag', await shown(`${member('HUM-2')} [data-testid=people-contact-tag]`))
  await load(DESKTOP, '/people')
  await sleep(200)
  ok('C24d-3 the choice survives a reload', (await p.$eval('[data-testid=people-filter-workspace]', (b) => b.getAttribute('aria-pressed')).catch(() => '')) === 'true' && (await rowNames()).length === 0)
  await p.click('[data-testid=people-filter-all]')
  await waitShown('[data-test=people-contact-row]')
  ok('C24d-4 twin: All shows group 3', (await rowNames()).length === 1, await rowNames())

  /* P: phone */
  const fits = () => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)
  await seed(INVITER, [stranger, zed, twin])
  await load(PHONE, '/people')
  /* a phone deep link lands on the pane: the rail tab opens the list (section-strip-mobile) */
  await p.click('[data-testid=sidebar-tab-people]')
  ok('P-1 390 the tools show', await waitShown('[data-testid=people-tools]'))
  await waitShown('[data-test=people-contact-row]')
  ok('P-2 390 no sideways scroll', await fits())
  ok('P-3 390 the filter is tall enough to tap', (await p.$eval('[data-testid=people-filter-all]', (b) => b.getBoundingClientRect().height)) >= 44)
  await shot('panel-390x664')
  await load(PHONE, '/people/contact/k-out')
  await waitShown('[data-test=contact-card]')
  ok('P-4 390 the card has no sideways scroll', await fits())
  const small = await p.$$eval('[data-test=contact-card] .btn', (l) => l.filter((b) => b.getBoundingClientRect().height < 44).length)
  ok('P-5 390 every card button >= 44 px tall', small === 0, { small })
  await shot('card-390x664')

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
