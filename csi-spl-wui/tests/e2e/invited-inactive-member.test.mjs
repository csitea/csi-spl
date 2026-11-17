// Spec 025 section 13 (SPL-5706): an invited person is an inactive member of
// the workspace at once, and a channel's Properties can add one. Owner HUM-10,
// t1 028ac340: "Once invited, the members of a workspace must become actual
// members of the workspace but just be inactive." and "even being inactive,
// it should be possible ... to add them in the properties of a channel".
//
// The mock bundle answers one open invite (invitee@example.com; in t1, a
// name-only workspace, no label at all, invited-members-client.mjs). This
// test checks, outside t1 and then in t1:
//   1. the People panel lists it after the members, tagged "inactive";
//   2. a fresh channel's Properties offers it as "<label> · inactive", and Add
//      puts it in the channel's list as invited (the 0231 pending row).
// Pre-change neither row exists, so both waits time out and the test fails.
// In t1 (spec 154 section 12.6, SPL-5830; owner HUM-10 msg 10b28abb) the
// label is "Dear future spool-hub user" and no row of the invitee carries an
// "@": neither the address nor a masked i…@example.com. RED control: the mock
// answering the masked address in t1 again fails the t1 checks.
//
// Run:
//   node tests/e2e/invited-inactive-member.test.mjs
//   BASE_URL=<generated bundle> SHOT_DIR=<dir> node tests/e2e/invited-inactive-member.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const CHANNEL = 'spl-5706-inactive'
// the mock's one open invite: its address outside t1, the en words in t1
const ADDRESS = 'invitee@example.com'
const NO_NAME = 'Dear future spool-hub user'

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Click the first VISIBLE match (a phone keeps hidden copies of some panes). */
const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)
const text = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  return e ? e.textContent.replace(/\s+/g, ' ').trim() : ''
}, sel)
const shot = async (p, name) => {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: `${SHOT_DIR}/${name}.png` })
}

/** People, then a fresh channel's Properties, as the page at `query` shows them. */
async function flow(page, { query, label, tag }) {
  await page.goto(`${srv.base}/lobby${query}`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  if (tag === 't1') {
    const adopted = await page.evaluate(() => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      const session = pinia?._s.get('session')
      if (!session) return false
      session.adopt({ hum: 'HUM-1', email: 'admin@example.com', name: 'FirstName LastName', t: 't1' })
      return true
    })
    ok(`[${tag}] the session is in t1`, adopted)
  }
  await sleep(600)
  // in t1 nothing of the invitee's address shows: no "@" in any of its rows
  const clean = (txt) => tag !== 't1' || !txt.includes('@')

  /* 1. People: the open invite follows the members, tagged inactive. */
  await click(page, '[data-testid=sidebar-tab-people]')
  const listed = Boolean(await page.waitForSelector('[data-test=people-invited-row]', { visible: true, timeout: 10000 }).catch(() => null))
  const row = listed ? await text(page, '[data-test=people-invited-row]') : ''
  const rowTitle = listed ? await page.$eval('[data-test=people-invited-row] .people-invited__label', (e) => e.getAttribute('title') || '') : ''
  ok(`[${tag}] People lists the invited person as an inactive member, as "${label}"`, listed && row.includes(label) && /inactive/.test(row) && clean(row) && clean(rowTitle), { row, rowTitle })
  const after = await page.evaluate(() => {
    const inv = document.querySelector('[data-test=people-invited-rows]')
    const members = [...document.querySelectorAll('[data-testid=sidebar-panel-people] a.nav-item')]
    if (!inv || !members.length) return null
    // eslint-disable-next-line no-bitwise
    return Boolean(members[members.length - 1].compareDocumentPosition(inv) & Node.DOCUMENT_POSITION_FOLLOWING)
  })
  ok(`[${tag}] ...after the active members`, after === true, { after })
  const oneLine = await page.evaluate(() => {
    const e = document.querySelector('[data-test=people-invited-row] .people-invited__label')
    if (!e) return null
    return { h: Math.round(e.getBoundingClientRect().height), lh: parseFloat(getComputedStyle(e).lineHeight) || 20 }
  })
  ok(`[${tag}] ...its label on one line, never broken mid-word`, Boolean(oneLine) && oneLine.h < 2 * oneLine.lh, oneLine)
  await shot(page, `people-inactive-member-${tag}`)

  /* 2. A fresh channel's Properties offers the inactive member, and Add makes
     it a pending (invited) member of the channel. */
  const made = await page.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    if (!ch) return ''
    const r = await ch.createChannel(name)
    return String(r?.channel_id || '')
  }, `${CHANNEL}-${tag}`)
  ok(`[${tag}] a channel is created to open Properties on`, Boolean(made), { made })
  await click(page, '[data-testid=sidebar-tab-channels]')
  await sleep(400)
  const menu = made ? await click(page, `[data-testid=sidebar-row-menu][data-menu-id="ch:${made}"]`) : false
  await sleep(300)
  const props = await click(page, '[data-testid=sidebar-row-menu-properties]')
  const picker = Boolean(await page.waitForSelector('[data-testid=channel-people-picker]', { timeout: 10000 }).catch(() => null))
  ok(`[${tag}] Properties opens on People`, menu && props && picker, { menu, props, picker })

  await page.click('[data-testid=channel-people-search-button]').catch(() => {})
  const opt = await page.waitForSelector('[data-testid^=channel-invite-pick-inactive-]', { timeout: 5000 }).catch(() => null)
  const optText = opt ? await opt.evaluate((e) => e.textContent.replace(/\s+/g, ' ').trim()) : ''
  ok(`[${tag}] the picker offers the invited person as "${label} · inactive"`, Boolean(opt) && optText.includes(`${label} · inactive`) && clean(optText), { optText })
  await shot(page, `channel-properties-inactive-pick-${tag}`)
  if (opt) {
    const key = await opt.evaluate((e) => e.getAttribute('data-testid').replace('channel-invite-pick-inactive-', ''))
    ok(`[${tag}] ...keyed by ${tag === 't1' ? 'its invite id, not an address' : 'its address'}`, tag === 't1' ? /^INV-[0-9a-f]{16}$/.test(key) : key === ADDRESS, { key })
    await opt.click()
    await sleep(200)
    await page.click('[data-testid=channel-people-add]')
    const sel = `[data-testid="channel-invited-${key}"]`
    const added = Boolean(await page.waitForSelector(sel, { timeout: 10000 }).catch(() => null))
    const rowText = added ? await page.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()) : ''
    const err = await page.$eval('[data-testid=channel-invite-error]', (e) => e.textContent.trim()).catch(() => '')
    ok(`[${tag}] Add lists the inactive member in the channel as invited`, added && rowText.includes(label) && /invited/.test(rowText) && clean(rowText), { key, rowText, err })
    await shot(page, `channel-properties-inactive-added-${tag}`)
    await page.click('[data-testid=channel-people-search-button]').catch(() => {})
    await sleep(300)
    const again = await page.$(`[data-testid="channel-invite-pick-inactive-${key}"]`)
    ok(`[${tag}] ...and it is no longer offered`, !again)
  }
  if (tag === 't1') {
    const at = await page.evaluate(() => document.body.innerText.includes('…@example.com') || document.body.innerText.includes('invitee@'))
    ok('[t1] the page carries neither the address nor its masked form', !at, { at })
  }
}

const srv = await startServer()
const browser = await launch()
try {
  for (const run of [{ query: '', label: ADDRESS, tag: 'other' }, { query: '?tenant=t1', label: NO_NAME, tag: 't1' }]) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ width: 1440, height: 900 })
    await flow(page, run)
    await page.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ninvited-inactive-member: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
