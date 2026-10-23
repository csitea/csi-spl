// SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa): Workspace
// settings -> Agents -> "Who may message each agent". On the mock bundle: a
// seated agent reads "Every member" (decision 2: no list); an admin ticks one
// member and saves, the row says so and keeps it after a reload of the pane;
// unticking every member reads "Nobody" (an empty list is not "everyone");
// "Every member" drops the list again. The hub's refusal of a send is proved
// in the hub tests and live on dev (the mock bundle has no socket).
//
// Control: before SPL-1018 the Agents page has no [data-test=tenant-agent-senders].
//
// Spec 025 box owner lock, row B8 (SPL-3015), the other door on who may
// message an agent: with the mock hook `spool.mock.box-lock` = a lock on
// box-desk owned by someone else, the viewer (another admin) DMs CLE-11 on
// that box: the mock answers 403 box_locked as the hub does (B3) and the
// composer says so, keeping the text. CONTROL: the hook off, the same DM
// sends (and on a build without B8 the refusal reads as the generic line).
// The lock pane on the box's Monitoring card shows an owner the lock and its
// audit; on an unlocked box it takes `spool lock create`'s output, refuses
// another box's, and confirms it into a lock.
//
// Run:
//   pnpm run test:e2e agent-senders
//   BASE_URL=<generated bundle> pnpm run test:e2e agent-senders
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* spec 061 FR-004: the mock ids are legacy; pin the agent-id clock before LEGACY_ID_UNTIL */
const pinAgentIdClock = (p) => p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
const firstRow = '[data-test=tenant-sender-row]'
/* a phone keeps fixed bars at the edges: bring the control to the middle, then tap it */
async function tap(p, sel) {
  const el = await p.waitForSelector(sel, { visible: true, timeout: 5000 })
  await el.evaluate((x) => x.scrollIntoView({ block: 'center' }))
  await el.click()
}
const state = (p) => p.$eval(`${firstRow} [data-test=tenant-sender-state]`, (el) => (el.textContent || '').trim()).catch(() => '')
const waitState = async (p, want) => {
  await p.waitForFunction((sel, w) => (document.querySelector(sel)?.textContent || '').trim() === w, { timeout: 5000 },
    `${firstRow} [data-test=tenant-sender-state]`, want).catch(() => {})
  return state(p)
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const LOCK_KEY = 'spool.mock.box-lock'
const LOCKED_TEXT = "Not sent — this agent's box is locked to its owners, and only they can message its agents. Your text is still here."

/** a page with the mock lock hook set (or cleared) on every navigation */
async function lockPage(lock) {
  const p = await browser.newPage()
  await pinAgentIdClock(p)
  await p.evaluateOnNewDocument((k, v) => {
    try { if (v) localStorage.setItem(k, v); else localStorage.removeItem(k) } catch { /* about:blank */ }
  }, LOCK_KEY, lock ? JSON.stringify(lock) : '')
  await p.setViewport({ width: 1280, height: 900 })
  return p
}

/** DM CLE-11 on box-desk from the omnibox; what the reader sees after */
async function dmLocked(p, text) {
  await p.goto(server.base + '/dm/' + encodeURIComponent('CLE-11@box-desk'), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const ta = 'form.composer.omnibox--global textarea'
  await p.waitForSelector(ta, { timeout: 15000 })
  await p.focus(ta)
  await p.type(ta, text)
  await sleep(150)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await sleep(900)
  return p.evaluate((n) => {
    const el = document.querySelector('[data-test=omnibox-send-error]')
    const box = document.querySelector('form.composer.omnibox--global textarea')
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const msgs = (pinia.state.value.channel && pinia.state.value.channel.messages) || []
    return {
      error: el ? el.querySelector('[data-test=omnibox-send-error-message]')?.textContent.trim() || '' : '',
      box: box ? box.value : '',
      sent: msgs.some((m) => String(m.body || '').includes(n)),
    }
  }, text)
}

const lockCreated = (box, owners) => JSON.stringify({
  signed_body: JSON.stringify({ tenant_id: 'mock', box_id: box, lock_pubkey: 'K', box_pubkey: 'B', owners, peer_boxes: [], hide_posts: true, version: 1 }),
  signature: 'c2ln', box_signature: 'Ym94',
})
const paneState = (p) => p.$eval('[data-test=box-lock]', (el) => el.getAttribute('data-state')).catch(() => '')

async function boxLockCases() {
  console.log('-- box lock (spec 025 B8)')
  /* another admin (the viewer HUM-1) DMs an agent of a box locked to HUM-9 */
  let p = await lockPage({ box: 'box-desk', owners: ['HUM-9'] })
  const refused = await dmLocked(p, 'b8-locked-dm-1')
  ok('another admin\'s DM to a locked box shows the box_locked text', refused.error === LOCKED_TEXT, refused)
  ok('the text stays in the box and nothing looks sent', refused.box === 'b8-locked-dm-1' && !refused.sent, refused)
  /* the same viewer on the locked box's card: the hub hides the lock from a non-owner */
  await p.goto(server.base + '/monitoring/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => ['none', 'locked'].includes(document.querySelector('[data-test=box-lock]')?.getAttribute('data-state') || ''), { timeout: 15000 }).catch(() => {})
  ok('a non-owner reads "no lock you own", never the owners', (await paneState(p)) === 'none' && !(await p.$('[data-test=box-lock-owners]')), await paneState(p))
  await p.close()

  /* CONTROL: the hub refusal off (no hook), the same DM sends */
  p = await lockPage(null)
  const open = await dmLocked(p, 'b8-open-dm-2')
  ok('CONTROL: with no lock the same DM sends, no error', open.sent && !open.error, open)
  await p.close()

  /* the owner's card: the lock, its owners and its audit */
  p = await lockPage({ box: 'box-desk', owners: ['HUM-1'] })
  await p.goto(server.base + '/monitoring/boxes/box-desk', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=box-lock-locked]', { timeout: 15000 }).catch(() => null)
  const owned = await p.evaluate(() => ({
    owners: [...document.querySelectorAll('[data-test=box-lock-owners] [data-key]')].map((el) => el.getAttribute('data-key')),
    audit: document.querySelectorAll('[data-test=box-lock-audit-row]').length,
  }))
  ok('an owner sees the lock, its owners and its audit', (await paneState(p)) === 'locked' && owned.owners.join() === 'HUM-1' && owned.audit === 1, owned)

  /* an unlocked box: the confirm dialog takes the box's create output */
  await p.goto(server.base + '/monitoring/boxes/box-a', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const opener = await p.waitForSelector('[data-test=box-lock-open]', { visible: true, timeout: 15000 }).catch(() => null)
  ok('an unlocked box offers "Lock this box"', Boolean(opener))
  if (opener) {
    await opener.evaluate((x) => x.scrollIntoView({ block: 'center' }))
    await opener.click()
    await p.waitForSelector('[data-test=box-lock-paste]', { visible: true, timeout: 5000 })
    await p.$eval('[data-test=box-lock-paste]', (el, v) => { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })) }, lockCreated('box-desk', ['HUM-1']))
    await sleep(200)
    const other = await p.evaluate(() => ({
      error: document.querySelector('[data-test=box-lock-error]')?.textContent.trim() || '',
      disabled: Boolean(document.querySelector('[data-test=box-lock-confirm-btn]')?.disabled),
    }))
    ok('another box\'s output is refused before it is sent', other.error === 'This output locks another box, not this one.' && other.disabled, other)
    await p.$eval('[data-test=box-lock-paste]', (el, v) => { el.value = v; el.dispatchEvent(new Event('input', { bubbles: true })) }, lockCreated('box-a', ['HUM-1']))
    await sleep(200)
    const preview = await p.$eval('[data-test=box-lock-preview]', (el) => el.textContent.trim()).catch(() => '')
    ok('the dialog names the owners the output locks it to', preview === 'Owners in this lock: HUM-1', preview)
    await p.click('[data-test=box-lock-confirm-btn]')
    await p.waitForSelector('[data-test=box-lock-done]', { timeout: 5000 }).catch(() => null)
    ok('confirmed: the box reads locked', (await paneState(p)) === 'locked' && !(await p.$('[data-test=box-lock-paste]')), await paneState(p))
  }
  const sw = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
  ok('box lock: no sideways scroll', sw)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ name: '1280', width: 1280, height: 900, mobile: false }, { name: '390', width: 390, height: 800, mobile: true }]) {
    console.log(`-- ${vp.name}`)
    const p = await browser.newPage()
    await pinAgentIdClock(p)
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    await p.goto(server.base + '/tenant-settings/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const pane = await p.waitForSelector('[data-test=tenant-agent-senders] ' + firstRow, { timeout: 15000 }).catch(() => null)
    ok('the Agents page carries who may message each agent', Boolean(pane))
    if (!pane) { await p.close(); continue }
    ok('no list reads as every member', (await state(p)) === 'Every member', await state(p))

    await tap(p, `${firstRow} [data-test=tenant-sender-edit]`)
    await p.waitForSelector('[data-test=tenant-sender-form]', { timeout: 5000 })
    await tap(p, '[data-test=tenant-sender-mode-list]')
    const member = await p.waitForSelector('[data-test=tenant-sender-member] input', { timeout: 5000 }).catch(() => null)
    ok('the list offers the workspace members', Boolean(member))
    ok('none ticked says nobody may message it', Boolean(await p.$('[data-test=tenant-sender-none]')))
    if (member) await tap(p, '[data-test=tenant-sender-member] input')
    await tap(p, '[data-test=tenant-sender-save]')
    ok('one member ticked and saved', (await waitState(p, 'Members allowed: 1')) === 'Members allowed: 1', await state(p))

    await tap(p, `${firstRow} [data-test=tenant-sender-edit]`)
    await p.waitForSelector('[data-test=tenant-sender-member] input', { timeout: 5000 })
    const ticked = await p.$$eval('[data-test=tenant-sender-member] input', (xs) => xs.filter((x) => x.checked).length)
    ok('editing again shows the saved member ticked', ticked === 1, ticked)
    await tap(p, '[data-test=tenant-sender-member] input:checked')
    await tap(p, '[data-test=tenant-sender-save]')
    ok('an empty list reads as nobody, not everyone', (await waitState(p, 'Nobody')) === 'Nobody', await state(p))

    await tap(p, `${firstRow} [data-test=tenant-sender-edit]`)
    await p.waitForSelector('[data-test=tenant-sender-mode-all]', { timeout: 5000 })
    await tap(p, '[data-test=tenant-sender-mode-all]')
    await tap(p, '[data-test=tenant-sender-save]')
    ok('every member drops the list', (await waitState(p, 'Every member')) === 'Every member', await state(p))

    const sw = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
    ok('no sideways scroll', sw)
    await p.close()
  }

  /* spec 025 B8: the box_locked refusal, the lock pane and its confirm */
  await boxLockCases()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `agent-senders: ${failed} FAILED` : `agent-senders: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
