// The admin's Users page, proved in a REAL browser (owner
// 2026-09-25): "the admin role owning user should see besides direct
// messages channels, topics and flow the users" ... "to be able to CRUD
// users" ... "each of the users should be listed and when clicking on it
// ... the user edit form should appear".
//
// Against the mock bundle (the mock plays an admin, tenant-users.mjs): owner
// 2026-09-28 (topic bea3a4e6), no Users icon on the rail - the users CRUD
// opens from the settings gear at the foot of the rail (Settings -> Members),
// and an old /users link lands there; a click on a row opens the
// edit pane with THAT user's data on USER_PANE_SIDE; change role, remove
// (confirmed), invite, revoke (confirmed) each land in the list; your own
// row cannot be removed. The non-admin half (no entry, hub 403) is the
// unit test tenant-users.test.mjs plus hub TestMembersAdminAPI.
//
// Plant the defect and watch it go red (the proof cancels the remove
// confirmation, so the row stays):
//   PROVE_RED=no-remove pnpm run test:e2e:users
//
// Run:
//   pnpm run test:e2e:users
//   BASE_URL=<generated bundle> pnpm run test:e2e:users     # what CI does
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

const rowKeys = (p) => p.$$eval('[data-test=users-row]', (els) => els.map((e) => e.getAttribute('data-key')))
const rowRole = (p, key) => p.$eval(`[data-test=users-row][data-key="${key}"] [data-test=users-row-role]`, (e) => e.textContent.trim()).catch(() => '')
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
const row = (key) => `[data-test=users-row][data-key="${key}"]`

async function confirm(p, yes) {
  await p.waitForSelector('[data-test=users-confirm-ok]', { visible: true, timeout: 5000 })
  await p.click(yes ? '[data-test=users-confirm-ok]' : '[data-test=users-confirm-cancel]')
  await sleep(500)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // specs/054 (CLE-77781): the mock is signed-OUT by default and its /session no
  // longer rides the network. Opt into a signed-in admin (HUM-1 is the mock's
  // admin viewer) exactly as act-as.test.mjs does — set the localStorage session
  // on the real origin, then reload — else the rail, the tenant-settings gear and
  // the Members list never render and every step below fails at the empty rail.
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the entry (owner 2026-09-28): no Users icon; the settings gear at the
  // foot of the rail opens Settings -> Members, the users CRUD
  const rail = await p.$$eval('.sidebar-rail [role=tab]', (els) => els.map((e) => e.getAttribute('data-testid')))
  const gear = await p.$eval('.sidebar-rail [data-testid=tenant-settings-open]', (e) => {
    const r = e.getBoundingClientRect()
    const tabs = [...document.querySelectorAll('.sidebar-rail [role=tab]')].map((t) => t.getBoundingClientRect().bottom)
    return { top: Math.round(r.top), belowTabs: tabs.every((b) => b <= r.top + 1), vhGap: Math.round(window.innerHeight - r.bottom) }
  }).catch(() => null)
  ok('1 the rail has no Users icon; the settings gear sits at its foot, under every tab', !rail.includes('sidebar-tab-users') && rail.includes('sidebar-tab-flow') && Boolean(gear && gear.belowTabs && gear.vhGap < 80), { rail, gear })
  await p.click('.sidebar-rail [data-testid=tenant-settings-open]')
  await p.waitForSelector('[data-test=users-page] [data-test=users-row]', { visible: true, timeout: NAV_TIMEOUT })
  ok('2 the gear opens Settings -> Members, the users list', new URL(p.url()).pathname.endsWith('/tenant-settings/members'), p.url())
  await p.goto(server.base + '/users', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => location.pathname.endsWith('/tenant-settings/members'), { timeout: 10000 }).catch(() => null)
  await p.waitForSelector('[data-test=users-page] [data-test=users-row]', { visible: true, timeout: NAV_TIMEOUT })
  ok('2b an old /users link lands on Settings -> Members', new URL(p.url()).pathname.endsWith('/tenant-settings/members'), p.url())
  const keys = await rowKeys(p)
  ok('3 one row per member and per pending invite', keys.includes('m:HUM-1') && keys.includes('m:HUM-3') && keys.includes('i:pending@example.com'), keys)
  ok('4 no pane before a click', !(await p.$('[data-test=users-pane]')))

  // 2. click a row -> that user's edit form, beside the list
  await p.click(row('m:HUM-3'))
  await p.waitForSelector('[data-test=users-pane]', { visible: true, timeout: 5000 })
  const email = await text(p, '[data-test=users-pane-email]')
  ok('5 the pane shows the clicked user', email === 'dev1@example.com' && (await text(p, '[data-test=users-pane-id]')) === 'HUM-3', { email })
  const side = await p.evaluate(() => {
    const list = document.querySelector('.users-col').getBoundingClientRect()
    const pane = document.querySelector('[data-test=users-pane]').getBoundingClientRect()
    const cls = document.querySelector('[data-test=users-page]').className
    return { cls, paneRight: pane.left >= list.right - 1, paneLeft: pane.right <= list.left + 1 }
  })
  const wantRight = side.cls.includes('users-page--pane-right')
  ok('6 the pane opens on USER_PANE_SIDE', wantRight ? side.paneRight : side.paneLeft, side)

  // 3. change role
  await p.select('[data-test=users-pane-role]', 'tester')
  await p.click('[data-test=users-pane-save-role]')
  await sleep(500)
  ok('7 change role lands in the list', /tester/i.test(await rowRole(p, 'm:HUM-3')), await rowRole(p, 'm:HUM-3'))

  // 4. remove, confirmed
  await p.click('[data-test=users-pane-remove]')
  await confirm(p, RED !== 'no-remove')
  ok('8 remove (after the confirmation) takes the row out', !(await rowKeys(p)).includes('m:HUM-3'))

  // 5. your own row cannot be removed
  await p.click(row('m:HUM-1'))
  await sleep(300)
  const selfRemove = await p.$eval('[data-test=users-pane-remove]', (b) => b.disabled).catch(() => null)
  ok('9 your own row: remove is disabled', selfRemove === true && Boolean(await p.$('[data-test=users-pane-locked]')))

  // 6. invite
  await p.click('[data-test=users-invite-open]')
  await p.waitForSelector('[data-test=users-invite-form]', { visible: true, timeout: 5000 })
  await p.type('[data-test=users-invite-email]', 'E2E-Invitee@example.com')
  await p.select('[data-test=users-invite-role]', 'regular_user')
  await p.click('[data-test=users-invite-send]')
  await p.waitForSelector(row('i:e2e-invitee@example.com'), { visible: true, timeout: 5000 }).catch(() => null)
  ok('10 invite adds a pending row with its role', /regular/i.test(await rowRole(p, 'i:e2e-invitee@example.com')), await rowKeys(p))
  const notice = await text(p, '[data-test=users-pane-notice]')
  ok('10b the pane moves to the new invite and keeps the notice', notice.includes('e2e-invitee@example.com') && (await text(p, '[data-test=users-pane-email]')) === 'e2e-invitee@example.com', { notice })
  // 047 W13: the invite's sign-in link, for when no mail arrived
  const link = await p.$eval('[data-test=users-pane-copy-link]', (e) => e.getAttribute('data-link')).catch(() => '')
  await browser.defaultBrowserContext().overridePermissions(server.base, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  await p.click('[data-test=users-pane-copy-link]').catch(() => null)
  await sleep(200)
  const clip = await p.evaluate(() => navigator.clipboard.readText()).catch((e) => 'ERR ' + e)
  // SPL-1231: the link also carries the invitee's address as login_hint
  ok('10c Copy invite link copies <origin>/login?tenant=<the tenant>&login_hint=<the invitee>', /^http:\/\/127\.0\.0\.1:\d+\/login\?tenant=[a-z0-9-]+&login_hint=e2e-invitee%40example\.com$/.test(link) && clip === link &&
    /copied/i.test(await text(p, '[data-test=users-pane-copy-link]')), { link, clip })

  // 6b. CLE-77780: the create never mails (no mail without a click). An unmailed
  // invite shows "Send the invite email"; clicking it sends the mail and the
  // button becomes "Resend" (distinct actions, both explicit).
  await p.click(row('i:e2e-invitee@example.com'))
  await p.waitForSelector('[data-test=users-pane-send-mail]', { visible: true, timeout: 5000 })
  await p.click('[data-test=users-pane-send-mail]')
  await sleep(300)
  const sentNotice = await text(p, '[data-test=users-pane-notice]')
  ok('10d Send the invite email mails it and the button turns into Resend',
    /sent/i.test(sentNotice) && Boolean(await p.$('[data-test=users-pane-resend]')) && !(await p.$('[data-test=users-pane-send-mail]')),
    { sentNotice })

  // 7. revoke, confirmed
  await p.click(row('i:e2e-invitee@example.com'))
  await p.waitForSelector('[data-test=users-pane-revoke]', { visible: true, timeout: 5000 })
  await p.click('[data-test=users-pane-revoke]')
  await confirm(p, true)
  ok('11 revoke (after the confirmation) takes the invite out', !(await rowKeys(p)).includes('i:e2e-invitee@example.com'))
  ok('12 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
