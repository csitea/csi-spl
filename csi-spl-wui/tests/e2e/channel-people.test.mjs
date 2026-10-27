// SPL-1233 control: channel Properties -> People loads on first open, and a
// person can be invited. This is the gate-run (mock bundle) counterpart of the
// live channel-people-live.proof.mjs, which the CI e2e job cannot run (it needs
// a deployed site / credentials).
//
// The regression: SPL-1204 gated <ChannelPropertiesDialog> behind v-if in the
// sidebar so it now MOUNTS already-open (openProperties sets channel_id and open
// in the same tick). The member load lived in watch(() => props.open) with no
// immediate, so the false->true transition happened before the watcher existed:
// People sat on "Loading…" forever and nobody could be invited. A source grep
// cannot see a mount-timing bug; only the browser can. This test opens
// Properties through the real row menu and fails today on the pre-fix code
// (channel-people-picker never renders), passes once the load is immediate.
//
// Run:
//   node tests/e2e/channel-people.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/channel-people.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = 'spl-1233-people'
// The mock roster (src/utils/mock-data.mjs): HUM-1 is the viewer/creator; the
// others are tenant members a fresh channel can invite.
const INVITEE = 'HUM-2'
// spec 025 section 11: an address nobody in the mock workspace holds.
const NEWCOMER = 'newcomer@example.com'

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

const srv = await startServer()
const browser = await launch()
try {
  const page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* A fresh channel: HUM-1 owns it and is its only member, so the People tab
     has both a member to see and candidates to invite. */
  const made = await page.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const ch = pinia?._s.get('channel')
    if (!ch) return ''
    const row = await ch.createChannel(name)
    return String(row?.channel_id || '')
  }, CHANNEL)
  ok('a channel is created to open Properties on', Boolean(made), { made })

  await click(page, '[data-testid=sidebar-tab-channels]')
  await sleep(400)
  const menuOpened = made ? await click(page, `[data-testid=sidebar-row-menu][data-menu-id="ch:${made}"]`) : false
  await sleep(300)
  const picked = await click(page, '[data-testid=sidebar-row-menu-properties]')
  const dialogOpen = Boolean(await page.waitForSelector('[data-testid=channel-properties]', { timeout: 10000 }).catch(() => null))
  ok('Properties opens from the channel row menu', menuOpened && picked && dialogOpen, { menuOpened, picked, dialogOpen })

  /* THE CONTROL: the People tab must LOAD. Pre-fix it stays on "Loading…" and
     the picker never renders, so this wait times out and the test fails. */
  const peopleLoaded = Boolean(await page.waitForSelector('[data-testid=channel-people-picker]', { timeout: 10000 }).catch(() => null))
  ok('People loads on first open (not stuck on Loading — SPL-1233)', peopleLoaded)

  /* The current member (the creator, HUM-1) is listed. */
  const seesSelf = await page.evaluate(() => {
    const ul = document.querySelector('[data-testid=channel-invite-members]')
    return ul ? [...ul.querySelectorAll('li')].length > 0 : false
  })
  ok('the People tab lists the current member(s)', seesSelf)

  /* t1 1d657ae8: the dialog hugs its rows (no fixed or doubled min-height):
     at most 10% of the screen is left under the last row, and it is centred. */
  const fit = await page.evaluate(() => {
    const panel = document.querySelector('[data-testid=ui-dialog]')
    const people = document.querySelector('[data-testid=channel-people]')
    if (!panel || !people) return null
    const rows = [...people.children].filter((e) => e.getBoundingClientRect().height > 0)
    const last = Math.max(...rows.map((e) => e.getBoundingClientRect().bottom))
    const box = panel.getBoundingClientRect()
    return {
      minHeight: panel.style.minHeight,
      gap: Math.round(box.bottom - last),
      top: Math.round(box.top),
      under: Math.round(innerHeight - box.bottom),
      vh: innerHeight,
    }
  })
  ok('the dialog hugs its rows: no min-height, <= 10% empty under the last row, centred',
    Boolean(fit) && fit.minHeight === '' && fit.gap <= fit.vh * 0.1 && Math.abs(fit.top - fit.under) <= 2, fit)

  /* ...so an open search list is an overlay: all of it on screen and on top,
     not clipped by the dialog body. */
  const listShown = (sel) => page.evaluate((sel) => {
    const list = document.querySelector(sel)
    if (!list) return null
    const r = list.getBoundingClientRect()
    const x = r.left + r.width / 2
    const top = document.elementFromPoint(x, r.top + 3)
    const bottom = document.elementFromPoint(x, r.bottom - 3)
    return {
      onScreen: r.top >= 0 && r.bottom <= innerHeight && r.height > 0,
      topVisible: list.contains(top),
      bottomVisible: list.contains(bottom),
    }
  }, sel)
  const fully = (v) => Boolean(v) && v.onScreen && v.topVisible && v.bottomVisible
  await page.click('[data-testid=channel-agent-search-button]').catch(() => {})
  await sleep(300)
  const agentList = await listShown('[data-testid=channel-agent-options]')
  ok('the agent search list is shown whole, over the dialog', fully(agentList), agentList)
  await page.keyboard.press('Escape')
  await sleep(200)

  /* SPL-3717 (lessons-learnt row 8): an agent's badge reads the roster
     store's presence, the source of every other dot, and stays live while
     the dialog is open. Pre-fix it read only the members answer of the
     moment Properties opened, so a box whose agents answered said "box
     offline" (the mock's answer has no online flag: no badge at all). */
  const badge = (id) => page.evaluate((id) => {
    const e = [...document.querySelectorAll(`[data-testid=channel-agent-state-${id}]`)].find((x) => x.getBoundingClientRect().width > 0)
    return e ? e.textContent.trim() : ''
  }, id)
  const frame = (peer, status) => page.evaluate((peer, status) => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    pinia?._s.get('roster')?.applyFrame({ type: 'presence', peer, status })
  }, peer, status)
  await page.click('[data-testid=channel-agent-search-button]').catch(() => {})
  const agentPickable = Boolean(await page.waitForSelector('[data-testid=channel-agent-invite-GRK-03]', { timeout: 5000 }).catch(() => null))
  if (agentPickable) {
    await page.click('[data-testid=channel-agent-invite-GRK-03]')
    await sleep(200)
    await page.click('[data-testid=channel-agent-add]')
    await page.waitForSelector('[data-testid=channel-agent-GRK-03]', { timeout: 10000 }).catch(() => null)
  }
  await sleep(200)
  const onOpen = await badge('GRK-03')
  ok('an agent of an online box reads online, from the roster presence', agentPickable && onOpen === 'online', { agentPickable, onOpen })
  await frame('GRK-03@box-a', 'offline')
  await frame('CLE-07@box-a', 'offline')
  await sleep(200)
  const wentOff = await badge('GRK-03')
  ok('a presence frame takes the badge to "box offline" while the dialog is open', wentOff === 'box offline', { wentOff })
  await frame('GRK-03@box-a', 'online')
  await sleep(200)
  const back = await badge('GRK-03')
  ok('...and the next frame brings it back online', back === 'online', { back })

  /* Invite one: open the dropdown, pick the candidate, Add, and it joins.
     Native page.click (trusted events + auto-scroll) is what headlessui's
     Combobox needs — a synthetic .click() on the option does not select. */
  await page.click('[data-testid=channel-people-search-button]').catch(() => {})
  await sleep(300)
  const pickable = Boolean(await page.waitForSelector(`[data-testid=channel-invite-pick-${INVITEE}]`, { timeout: 5000 }).catch(() => null))
  ok(`a tenant member (${INVITEE}) is offered to invite`, pickable)
  const peopleList = await listShown('[data-testid=channel-people-options]')
  ok('the people search list is shown whole, over the dialog', fully(peopleList), peopleList)
  if (pickable) {
    await page.click(`[data-testid=channel-invite-pick-${INVITEE}]`)
    await sleep(200)
    await page.click('[data-testid=channel-people-add]')
    const joined = Boolean(await page.waitForSelector(`[data-testid=channel-member-remove-${INVITEE}]`, { timeout: 10000 }).catch(() => null))
    const err = await page.$eval('[data-testid=channel-invite-error]', (e) => e.textContent.trim()).catch(() => '')
    ok(`${INVITEE} becomes a member after Add`, joined, { err })
  }

  /* spec 025 section 11 (SPL-3686, owner t1 b602f8b4): a person who has not
     joined the workspace is added by typing their address. The picker offers
     "Invite <address>", Add puts it in the list as invited, and the minus
     takes the pending add back. Pre-fix the typed address matched nothing
     ("No matches") and there was no way to add it. */
  const row = `[data-testid="channel-invited-${NEWCOMER}"]`
  await page.click('[data-testid=channel-people-search]', { clickCount: 3 }).catch(() => {})
  await page.type('[data-testid=channel-people-search]', NEWCOMER)
  const offered = Boolean(await page.waitForSelector('[data-testid=channel-invite-pick-email]', { timeout: 5000 }).catch(() => null))
  ok('a typed address is offered as "Invite <address>"', offered)
  if (offered) {
    await page.click('[data-testid=channel-invite-pick-email]')
    await sleep(200)
    await page.click('[data-testid=channel-people-add]')
    const listed = Boolean(await page.waitForSelector(row, { timeout: 10000 }).catch(() => null))
    const text = listed ? await page.$eval(row, (e) => e.textContent.replace(/\s+/g, ' ').trim()) : ''
    const err = await page.$eval('[data-testid=channel-invite-error]', (e) => e.textContent.trim()).catch(() => '')
    ok('the address is listed as invited after Add', listed && text.includes(NEWCOMER) && /invited/.test(text), { text, err })
    await page.click(`[data-testid="channel-invited-remove-${NEWCOMER}"]`).catch(() => {})
    const gone = await page.waitForSelector(row, { hidden: true, timeout: 10000 }).then(() => true).catch(() => false)
    ok('the minus takes the pending add back', gone)
  }
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-people: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
