// Spec 164 row B6 (SPL-5560): a channel's boxes, proved in a REAL browser.
// Owner HUM-10 (t1 021d4921, msg 6b6d092c): "by default any channel should
// run on any box from the cluster , but one should be able to fix only
// certain boxes for a channel".
//
// Against the mock bundle (the mock hub keeps B2's rules,
// tenant-settings-mock.mjs): the channel Properties Settings tab shows
// "Any box (default)" for a new channel; an admin picks "Only these boxes",
// ticks two of the workspace's boxes and saves; a reopen reads them back.
// A default channel (#lobby) shows the hub's refusal and stays on any box,
// never a silent save. Workspace settings -> Channels shows the pinned boxes
// in its Boxes column and "Any box" for an unpinned channel. A member
// without tenant.settings sees the choice read-only, with no Save. The
// client and body half is tests/unit/channel-box-pins.test.mjs.
//
// Run:
//   node tests/e2e/tenant-channel-box-pins.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/tenant-channel-box-pins.test.mjs
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = 'design'
const en = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8'))
const P = en.channels.properties

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** Read until want() holds, or `max` runs out; returns the last read. */
async function until(read, want = Boolean, max = 8000) {
  const end = Date.now() + max
  let v = await read()
  while (!want(v) && Date.now() < end) {
    await sleep(100)
    v = await read()
  }
  return v
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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)
const shown = (p, sel) => p.waitForSelector(sel, { visible: true, timeout: 8000 }).catch(() => null)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')

/* the Boxes choice as the viewer sees it */
const boxesState = (p) => p.evaluate(() => {
  const q = (s) => document.querySelector(`[data-testid=channel-settings] ${s}`)
  const any = q('[data-testid=channel-boxes-any]')
  if (!any) return null
  const ticks = [...document.querySelectorAll('[data-testid=channel-boxes-list] input[type=checkbox]')]
  return {
    any: any.checked,
    disabled: any.disabled,
    choices: ticks.map((b) => b.value),
    ticked: ticks.filter((b) => b.checked).map((b) => b.value),
    save: q('[data-testid=channel-boxes-save]') ? !q('[data-testid=channel-boxes-save]').disabled : null,
    readonly: Boolean(q('[data-testid=channel-boxes-readonly]')),
  }
})

async function signIn(p, me) {
  await p.goto(p.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((me) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    if (me) localStorage.setItem('spool.mock.me', JSON.stringify(me))
  }, me)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await until(() => p.evaluate(() => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel'))))
}

async function createChannel(p, name) {
  return p.evaluate(async (name) => {
    const ch = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel')
    const row = ch ? await ch.createChannel(name) : null
    return String(row?.channel_id || '')
  }, name)
}

/* Properties of a channel, through the real row menu, on its Settings tab */
async function openSettings(p, channelId) {
  await click(p, '[data-testid=sidebar-tab-channels]')
  await shown(p, `[data-testid=sidebar-row-menu][data-menu-id="ch:${channelId}"]`)
  await click(p, `[data-testid=sidebar-row-menu][data-menu-id="ch:${channelId}"]`)
  await shown(p, '[data-testid=sidebar-row-menu-properties]')
  await click(p, '[data-testid=sidebar-row-menu-properties]')
  if (!(await p.waitForSelector('[data-testid=channel-properties]', { timeout: 10000 }).catch(() => null))) return null
  await click(p, '[data-testid=channel-properties-tab-settings]')
  return until(() => boxesState(p))
}

async function closeDialog(p) {
  await click(p, '[data-testid=ui-dialog-close]')
  await until(() => p.evaluate(() => !document.querySelector('[data-testid=channel-properties]')))
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  p.base = server.base
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await signIn(p, null)
  const made = await createChannel(p, CHANNEL)
  ok('1 a channel is created to pin', made === CHANNEL, { made })

  /* ---- 2. a new channel runs on any box ---- */
  const fresh = await openSettings(p, made)
  ok('2 a new channel shows "Any box (default)" and no box list', fresh?.any === true && fresh.choices.length === 0, fresh)
  ok('2b the admin may change it', fresh?.disabled === false && fresh.readonly === false, fresh)
  ok('2c the labels are the catalogue\'s', (await text(p, '[data-testid=channel-boxes] legend')) === P.boxes_label &&
    (await text(p, '[data-testid=channel-settings] label:has([data-testid=channel-boxes-any]) span')) === P.boxes_any)

  /* ---- 3. pin it to two of the workspace's boxes ---- */
  await click(p, '[data-testid=channel-boxes-some]')
  const some = await until(() => boxesState(p), (s) => s && s.choices.length > 0)
  ok('3 "Only these boxes" lists every box pinned to the workspace (GET /v1/pins)', some?.choices.join() === 'box-a,box-b,box-desk', some)
  ok('3b Save waits for a ticked box', some?.save === false, some)
  await click(p, '[data-testid=channel-box-box-a]')
  await click(p, '[data-testid=channel-box-box-desk]')
  await click(p, '[data-testid=channel-boxes-save]')
  const saved = await until(() => text(p, '[data-testid=channel-boxes-saved]'))
  ok('3c Save says the boxes are saved', saved === P.boxes_saved, saved)
  ok('3d no refusal on a private channel', !(await p.$('[data-testid=channel-boxes-error]')))
  await closeDialog(p)

  /* ---- 4. a reopen reads the pins back from the hub ---- */
  const back = await openSettings(p, made)
  ok('4 a reopen reads the channel back pinned to box-a and box-desk', back?.any === false && back.ticked.join() === 'box-a,box-desk', back)
  await closeDialog(p)

  /* ---- 5. a default channel: the hub's refusal, never a silent save ---- */
  await openSettings(p, 'lobby')
  await click(p, '[data-testid=channel-boxes-some]')
  await until(() => boxesState(p), (s) => s && s.choices.length > 0)
  await click(p, '[data-testid=channel-box-box-a]')
  await click(p, '[data-testid=channel-boxes-save]')
  const refused = await until(() => text(p, '[data-testid=channel-boxes-error]'))
  ok('5 #lobby shows the hub refusal (channel_default_unpinnable)', refused === P.boxes_error.channel_default_unpinnable, refused)
  ok('5b and no "saved" line', !(await p.$('[data-testid=channel-boxes-saved]')))
  await closeDialog(p)
  const lobby = await openSettings(p, 'lobby')
  ok('5c #lobby stays on any box', lobby?.any === true, lobby)
  await closeDialog(p)

  /* ---- 6. Workspace settings -> Channels: the Boxes column ---- */
  await click(p, '[data-testid=tenant-settings-open]')
  await shown(p, '[data-test=tenant-settings-nav]')
  await click(p, '[data-test=tenant-settings-nav-channels]')
  await shown(p, '[data-test=tenant-channel-row]')
  const head = await p.$$eval('[data-test=tenant-channels-table] thead th', (ths) => ths.map((t) => t.textContent.trim()))
  ok('6 the Channels table has a Boxes column', head.includes(en.tenant_settings.col_boxes), head)
  const cell = (ch) => text(p, `[data-test=tenant-channel-row][data-channel=${ch}] [data-test=tenant-channel-boxes]`)
  const designBoxes = await until(() => cell(CHANNEL), (v) => v && v !== en.tenant_settings.boxes_any)
  ok('6b the pinned channel lists its boxes', designBoxes === 'box-a, box-desk', designBoxes)
  ok('6c an unpinned channel reads "Any box"', (await cell('lobby')) === en.tenant_settings.boxes_any, await cell('lobby'))
  ok('7 no page errors', errors.length === 0, errors)
  await p.close()

  /* ---- 8. without tenant.settings: read-only, no Save ---- */
  const q = await browser.newPage()
  q.base = server.base
  await signIn(q, { role: 'developer', permissions: ['topics.read', 'notes.send', 'channels.manage'] })
  const mine = await createChannel(q, 'box-pins-ro')
  const ro = await openSettings(q, mine)
  ok('8 a member without tenant.settings sees the choice read-only', ro?.disabled === true && ro.save === null && ro.readonly === true, ro)
  ok('8b and is told who may change it', (await text(q, '[data-testid=channel-boxes-readonly]')) === P.boxes_readonly)
  await q.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntenant-channel-box-pins: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
