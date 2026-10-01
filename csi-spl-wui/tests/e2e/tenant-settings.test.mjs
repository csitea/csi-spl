// Tenant settings (SPL-1037, specs/046), proved in a REAL browser. Owner
// 2026-09-28: "the UI should behave similarly to how the personal settings
// work, but the icon should be in the bottom-left corner of the screen on
// desktop" ... "a section for users where the admins and the biz_owners of
// the tenant can CRUD users".
//
// Against the mock bundle (the mock plays an admin, tenant-settings.mjs +
// tenant-users.mjs): the building icon is the bottom-left of the screen; it
// opens /tenant-settings, which is the Settings layout with Members, Agents,
// Channels and General; Members invites, disables and removes; Agents edits
// the responder order; Channels flips a no-fallback flag and archives
// (confirmed); General saves the tenant name. On a phone the list of
// sections is level 2 and a section is level 3. The non-admin half (no
// entry, hub 403) is tests/unit/tenant-settings.test.mjs plus hub
// TestTenantSettingsForbidden.
//
// Plant the defect and watch it go red (the proof cancels the archive
// confirmation, so the row stays):
//   PROVE_RED=no-archive node tests/e2e/tenant-settings.test.mjs
//
// Run:
//   pnpm run test:e2e:tenant-settings
//   BASE_URL=<generated bundle> pnpm run test:e2e:tenant-settings
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const attrs = (p, sel, a) => p.$$eval(sel, (els, a) => els.map((e) => e.getAttribute(a)), a)
const path = (p) => new URL(p.url()).pathname

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // specs/054 (CLE-77781): the mock is signed-OUT by default and its /session no
  // longer rides the network. Opt into a signed-in admin (HUM-1 is the mock's
  // admin viewer) exactly as act-as.test.mjs does — set the localStorage session
  // on the real origin, then reload — else the rail and the tenant-settings gear
  // never render and every step below fails at the empty rail.
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the entry: bottom-left of the screen
  await p.waitForSelector('[data-testid=tenant-settings-open]', { visible: true, timeout: NAV_TIMEOUT })
  const box = await p.$eval('[data-testid=tenant-settings-open]', (e) => {
    const r = e.getBoundingClientRect()
    return { left: r.left, bottom: r.bottom, vw: window.innerWidth, vh: window.innerHeight }
  })
  ok('1 the Tenant settings icon sits in the bottom-left corner', box.left < 80 && box.vh - box.bottom < 80, box)
  await p.click('[data-testid=tenant-settings-open]')
  await p.waitForSelector('[data-test=tenant-settings-nav]', { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => location.pathname.endsWith('/tenant-settings/members'), { timeout: 10000 }).catch(() => null)
  ok('2 it opens the first section, Members', path(p).endsWith('/tenant-settings/members'), path(p))
  const nav = await attrs(p, '[data-test=tenant-settings-nav] a', 'data-test')
  ok('3 the Settings layout lists Members, Agents, Channels, General', nav.join() === 'tenant-settings-nav-members,tenant-settings-nav-agents,tenant-settings-nav-channels,tenant-settings-nav-general', nav)

  // 2. Members: the users list and edit pane, embedded
  await p.waitForSelector('[data-test=tenant-settings-members] [data-test=users-row]', { visible: true, timeout: 10000 })
  await p.click('[data-test=tenant-settings-members] [data-test=users-invite-open]')
  await p.type('[data-test=users-invite-email]', 'ts-invitee@example.com')
  await p.select('[data-test=users-invite-role]', 'tester')
  await p.click('[data-test=users-invite-send]')
  await p.waitForSelector('[data-test=users-row][data-key="i:ts-invitee@example.com"]', { visible: true, timeout: 5000 }).catch(() => null)
  ok('4 Members invites', Boolean(await p.$('[data-test=users-row][data-key="i:ts-invitee@example.com"]')))
  ok('4b a pending invite offers Resend', Boolean(await p.$('[data-test=users-pane-resend]')))
  await p.click('[data-test=users-row][data-key="m:HUM-3"]')
  await p.waitForSelector('[data-test=users-pane-suspend]', { visible: true, timeout: 5000 })
  await p.click('[data-test=users-pane-suspend]')
  await p.waitForSelector('[data-test=users-row][data-key="m:HUM-3"] [data-test=users-row-suspended]', { timeout: 5000 }).catch(() => null)
  ok('5 Members disables a member in this tenant', Boolean(await p.$('[data-test=users-row][data-key="m:HUM-3"] [data-test=users-row-suspended]')))
  ok('5b the member pane shows last seen', Boolean(await p.$('[data-test=users-pane-last-seen]')))
  await p.click('[data-test=users-pane-remove]')
  await p.waitForSelector('[data-test=users-confirm-ok]', { visible: true, timeout: 5000 })
  await p.click('[data-test=users-confirm-ok]')
  await sleep(500)
  ok('6 Members removes (after the confirmation)', !(await attrs(p, '[data-test=users-row]', 'data-key')).includes('m:HUM-3'))

  // 3. Agents: seated agents + the responder list
  await p.click('[data-test=tenant-settings-nav-agents]')
  await p.waitForSelector('[data-test=tenant-agent-row]', { visible: true, timeout: 10000 })
  const agents = await attrs(p, '[data-test=tenant-agent-row]', 'data-agent')
  ok('7 Agents lists the seated agents, box-wui humans excluded', agents.includes('CLE-07') && !agents.some((a) => a.startsWith('HUM-')), agents)
  await p.type('[data-test=tenant-responder-input]', 'grk-03')
  await p.click('[data-test=tenant-responder-add]')
  await p.click('[data-test=tenant-responder-row][data-agent="GRK-03"] [data-test=tenant-responder-up]')
  await p.click('[data-test=tenant-responders-save]')
  await p.waitForSelector('[data-test=tenant-responders-notice]', { visible: true, timeout: 5000 }).catch(() => null)
  const order = await attrs(p, '[data-test=tenant-responder-row]', 'data-agent')
  ok('8 Agents adds a responder, moves it up and saves', order.join() === 'GRK-03,CLE-01', order)

  // 4. Channels: no-fallback + archive
  await p.click('[data-test=tenant-settings-nav-channels]')
  await p.waitForSelector('[data-test=tenant-channel-row]', { visible: true, timeout: 10000 })
  const chans = await attrs(p, '[data-test=tenant-channel-row]', 'data-channel')
  ok('9 Channels lists default and private channels', chans.includes('lobby') && chans.includes('secret'), chans)
  ok('9b a default channel offers no Archive', !(await p.$('[data-test=tenant-channel-row][data-channel=lobby] [data-test=tenant-channel-archive]')))
  await p.click('[data-test=tenant-channel-row][data-channel=design] [data-test=tenant-channel-fallback]')
  await sleep(400)
  const flag = await p.$eval('[data-test=tenant-channel-row][data-channel=design] [data-test=tenant-channel-fallback]', (e) => e.checked)
  ok('10 Channels switches fallback off', flag === false)
  await p.click('[data-test=tenant-channel-row][data-channel=design] [data-test=tenant-channel-archive]')
  await p.waitForSelector('[data-test=tenant-channel-archive-ok]', { visible: true, timeout: 5000 })
  await p.click(RED === 'no-archive' ? '[data-test=tenant-channel-archive-cancel]' : '[data-test=tenant-channel-archive-ok]')
  await sleep(500)
  ok('11 Channels archives (after the confirmation)', !(await attrs(p, '[data-test=tenant-channel-row]', 'data-channel')).includes('design'))

  // 5. General: the tenant name
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector('[data-test=tenant-general-name]', { visible: true, timeout: 10000 })
  await p.focus('[data-test=tenant-general-name]')
  await p.$eval('[data-test=tenant-general-name]', (e) => e.select())
  await p.type('[data-test=tenant-general-name]', 'Renamed tenant')
  await p.click('[data-test=tenant-general-save]')
  await p.waitForSelector('[data-test=tenant-general-notice]', { visible: true, timeout: 5000 }).catch(() => null)
  const general = { value: await p.$eval('[data-test=tenant-general-name]', (e) => e.value), notice: await text(p, '[data-test=tenant-general-notice]'), error: await text(p, '[data-test=tenant-general-error]') }
  ok('12 General saves the tenant name', general.value === 'Renamed tenant' && general.notice !== '', general)
  // CLE-77819: General -> "Who can archive topics" (default everyone), saved
  const policy0 = await p.$eval('[data-test=tenant-general-archive-policy]', (e) => ({ value: e.value, options: [...e.options].map((o) => o.value), labels: [...e.options].map((o) => o.textContent.trim()) }))
  await p.select('[data-test=tenant-general-archive-policy]', 'admins')
  await p.click('[data-test=tenant-general-save]')
  await sleep(500)
  const policy1 = { value: await p.$eval('[data-test=tenant-general-archive-policy]', (e) => e.value), error: await text(p, '[data-test=tenant-general-error]') }
  ok('12b General: Who can archive topics defaults to everyone, offers the three, saves admins',
    policy0.value === 'everyone' && policy0.options.join() === 'everyone,admins,starter' && policy0.labels.every((l) => l && !l.startsWith('tenant_settings.')) &&
    policy1.value === 'admins' && policy1.error === '', { policy0, policy1 })

  // 6. phone: the list is level 2, a section level 3
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/tenant-settings', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-settings-nav-general]', { visible: true, timeout: 10000 })
  ok('13 phone: /tenant-settings is the list of sections', path(p).endsWith('/tenant-settings') && !(await p.$('[data-test=tenant-settings-content] [data-test=tenant-settings-general]')))
  await p.click('[data-test=tenant-settings-nav-general]')
  await p.waitForSelector('[data-test=tenant-settings-general]', { visible: true, timeout: 10000 })
  const navHidden = await p.$eval('[data-test=tenant-settings-nav]', (e) => getComputedStyle(e).display === 'none')
  ok('14 phone: a section opens full width, the list hidden', navHidden)
  ok('15 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
