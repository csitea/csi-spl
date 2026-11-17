// Spec 025 section 13 (SPL-5706): an invited person is an inactive member of
// the workspace at once, and a channel's Properties can add one. Owner HUM-10,
// t1 028ac340: "Once invited, the members of a workspace must become actual
// members of the workspace but just be inactive." and "even being inactive,
// it should be possible ... to add them in the properties of a channel".
//
// The mock bundle answers one open invite (newcomer@example.com, masked as
// n…@example.com in t1, invited-members-client.mjs). This test checks:
//   1. the People panel lists it after the members, tagged "inactive";
//   2. a fresh channel's Properties offers it as "<label> · inactive", and Add
//      puts it in the channel's list as invited (the 0231 pending row).
// Pre-change neither row exists, so both waits time out and the test fails.
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
// the mock's one open invite: its address, or its masked form in t1
const LABELS = ['newcomer@example.com', 'n…@example.com']

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

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* 1. People: the open invite follows the members, tagged inactive. */
  await click(page, '[data-testid=sidebar-tab-people]')
  const listed = Boolean(await page.waitForSelector('[data-test=people-invited-row]', { visible: true, timeout: 10000 }).catch(() => null))
  const row = listed ? await text(page, '[data-test=people-invited-row]') : ''
  ok('People lists the invited person as an inactive member', listed && LABELS.some((l) => row.includes(l)) && /inactive/.test(row), { row })
  const after = await page.evaluate(() => {
    const inv = document.querySelector('[data-test=people-invited-rows]')
    const members = [...document.querySelectorAll('[data-testid=sidebar-panel-people] a.nav-item')]
    if (!inv || !members.length) return null
    // eslint-disable-next-line no-bitwise
    return Boolean(members[members.length - 1].compareDocumentPosition(inv) & Node.DOCUMENT_POSITION_FOLLOWING)
  })
  ok('...after the active members', after === true, { after })
  const oneLine = await page.evaluate(() => {
    const e = document.querySelector('[data-test=people-invited-row] .people-invited__label')
    if (!e) return null
    return { h: Math.round(e.getBoundingClientRect().height), lh: parseFloat(getComputedStyle(e).lineHeight) || 20 }
  })
  ok('...its address on one line, never broken mid-word', Boolean(oneLine) && oneLine.h < 2 * oneLine.lh, oneLine)
  await shot(page, 'people-inactive-member')

  /* 2. A fresh channel's Properties offers the inactive member, and Add makes
     it a pending (invited) member of the channel. */
  const made = await page.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    if (!ch) return ''
    const r = await ch.createChannel(name)
    return String(r?.channel_id || '')
  }, CHANNEL)
  ok('a channel is created to open Properties on', Boolean(made), { made })
  await click(page, '[data-testid=sidebar-tab-channels]')
  await sleep(400)
  const menu = made ? await click(page, `[data-testid=sidebar-row-menu][data-menu-id="ch:${made}"]`) : false
  await sleep(300)
  const props = await click(page, '[data-testid=sidebar-row-menu-properties]')
  const picker = Boolean(await page.waitForSelector('[data-testid=channel-people-picker]', { timeout: 10000 }).catch(() => null))
  ok('Properties opens on People', menu && props && picker, { menu, props, picker })

  await page.click('[data-testid=channel-people-search-button]').catch(() => {})
  const opt = await page.waitForSelector('[data-testid^=channel-invite-pick-inactive-]', { timeout: 5000 }).catch(() => null)
  const optText = opt ? await opt.evaluate((e) => e.textContent.replace(/\s+/g, ' ').trim()) : ''
  ok('the picker offers the invited person as "<label> · inactive"', Boolean(opt) && LABELS.some((l) => optText.includes(`${l} · inactive`)), { optText })
  await shot(page, 'channel-properties-inactive-pick')
  if (opt) {
    const key = await opt.evaluate((e) => e.getAttribute('data-testid').replace('channel-invite-pick-inactive-', ''))
    await opt.click()
    await sleep(200)
    await page.click('[data-testid=channel-people-add]')
    const sel = `[data-testid="channel-invited-${key}"]`
    const added = Boolean(await page.waitForSelector(sel, { timeout: 10000 }).catch(() => null))
    const rowText = added ? await page.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()) : ''
    const err = await page.$eval('[data-testid=channel-invite-error]', (e) => e.textContent.trim()).catch(() => '')
    ok('Add lists the inactive member in the channel as invited', added && LABELS.some((l) => rowText.includes(l)) && /invited/.test(rowText), { key, rowText, err })
    await shot(page, 'channel-properties-inactive-added')
    await page.click('[data-testid=channel-people-search-button]').catch(() => {})
    await sleep(300)
    const again = await page.$(`[data-testid="channel-invite-pick-inactive-${key}"]`)
    ok('...and it is no longer offered', !again)
  }
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ninvited-inactive-member: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
