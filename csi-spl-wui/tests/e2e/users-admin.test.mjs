// The admin's Users page, proved in a REAL browser (owner
// 2026-09-25): "the admin role owning user should see besides direct
// messages channels, topics and flow the users" ... "to be able to CRUD
// users" ... "each of the users should be listed and when clicking on it
// ... the user edit form should appear".
//
// Against the mock bundle (the mock plays an admin, tenant-users.mjs): the
// Users icon is on the rail; it opens /users; a click on a row opens the
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
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the entry, last: flow, then the Event log (owner: "button
  // after the flow icon"), then Archive (SPL-983, the default order), then
  // Users, which is never reorderable and always last (SPL-979)
  const rail = await p.$$eval('.sidebar-rail [role=tab]', (els) => els.map((e) => e.getAttribute('data-testid')))
  ok('1 the rail shows Users last, after Flow, Archive and the Event log', rail.at(-1) === 'sidebar-tab-users' && rail.indexOf('sidebar-tab-flow') === rail.length - 4 && rail.indexOf('sidebar-tab-archive') === rail.length - 3 && rail.indexOf('sidebar-tab-events') === rail.length - 2, rail)
  await p.click('[data-testid=sidebar-tab-users]')
  await p.waitForSelector('[data-test=users-page] [data-test=users-row]', { visible: true, timeout: NAV_TIMEOUT })
  ok('2 Users opens /users', new URL(p.url()).pathname.endsWith('/users'), p.url())
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
