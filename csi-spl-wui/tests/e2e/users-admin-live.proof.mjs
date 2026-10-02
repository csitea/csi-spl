// CLE-34969 live proof of the admin's Users page against a deployed WUI + hub
// (dev only: it WRITES memberships of test accounts).
//
// Session A (ADMIN_EMAIL, an admin of TENANT): the Users icon is on the rail;
// the settings gear (rail foot) opens Settings -> Members, which lists the
// members; a click on MEMBER_EMAIL's row opens its edit pane;
// change role (MEMBER's role -> tester -> back); remove MEMBER (confirmed);
// invite MEMBER back with its old role; invite a throwaway THROW_EMAIL, open
// its row, revoke it (confirmed).
// Session B (MEMBER_EMAIL, a non-admin): signs in again (the re-invite admits
// it); CONTROL: no Users icon, and GET <API>/v1/members from the page is 403.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> TENANT=t1 \
//   ADMIN_EMAIL=<admin test account> ADMIN_PW_FILE=<0600 file> \
//   MEMBER_EMAIL=<non-admin test account> MEMBER_PW_FILE=<0600 file> \
//   THROW_EMAIL=<throwaway address> OUT=<dir> \
//     node tests/e2e/users-admin-live.proof.mjs
//
// CONTROL_ONLY=1 runs session B alone and writes nothing (prd: a test
// tenant's non-admin; ADMIN_* and THROW_EMAIL are then not needed).
//
// Passwords are read from the files and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const CONTROL_ONLY = process.env.CONTROL_ONLY === '1'
const ADMIN = CONTROL_ONLY ? '' : need('ADMIN_EMAIL')
const MEMBER = need('MEMBER_EMAIL').toLowerCase()
const THROW = CONTROL_ONLY ? '' : need('THROW_EMAIL').toLowerCase()
const pwOf = (k) => readFileSync(need(k), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const rowSel = (key) => `[data-test=users-row][data-key="${key}"]`
const rowKeys = (p) => p.$$eval('[data-test=users-row]', (els) => els.map((e) => e.getAttribute('data-key')))
const rowRole = (p, key) => p.$eval(`${rowSel(key)} [data-test=users-row-role]`, (e) => e.textContent.trim()).catch(() => '')
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')

async function signIn(ctx, email, pwKey) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pwOf(pwKey))
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true).catch(() => false)
  await sleep(2500)
  return { p, ok }
}
async function confirm(p) {
  await p.waitForSelector('[data-test=users-confirm-ok]', { visible: true, timeout: 10000 })
  await p.click('[data-test=users-confirm-ok]')
  await sleep(1500)
}
/** The hub's answer to GET /v1/members from inside the page (the session cookie rides along). */
const apiStatus = (p) => p.evaluate(async (api) => {
  const r = await fetch(api + '/v1/members', { credentials: 'include', headers: { accept: 'application/json' } })
  let body = null
  try { body = await r.json() } catch { /* not json */ }
  return { status: r.status, error: body && body.error, permission: body && body.permission }
}, API)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  // Metadata only: a node fetch that cannot dial (IPv6 on some boxes) must not stop the proof.
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch((e) => ({ error: String(e) }))
  res.version = await fetch(API + '/version').then((r) => r.json()).catch((e) => ({ error: String(e) }))

  // ---- A: the admin -------------------------------------------------------
  if (!CONTROL_ONLY) {
  const a = await signIn(await browser.createBrowserContext(), ADMIN, 'ADMIN_PW_FILE')
  step('A1 admin signs in', a.ok, { url: a.p.url() })
  const p = a.p
  /* owner 2026-09-28 (topic bea3a4e6): no Users rail icon; the users CRUD
     opens from the settings gear at the foot of the rail (Settings -> Members) */
  step('A2a the rail has no Users icon', !(await p.$('[data-testid=sidebar-tab-users]')))
  const icon = await p.waitForSelector('.sidebar-rail [data-testid=tenant-settings-open]', { timeout: 15000 }).catch(() => null)
  step('A2 admin sees the settings gear at the foot of the rail', Boolean(icon))
  if (icon) {
    await icon.click()
    await p.waitForSelector('[data-test=users-row]', { timeout: 20000 }).catch(() => null)
    const api = await apiStatus(p)
    step('A3 Settings -> Members lists members; GET /v1/members is 200', p.url().endsWith('/tenant-settings/members') && api.status === 200, { url: p.url(), api, rows: (await rowKeys(p)).length })
    await p.screenshot({ path: `${OUT}/a-users-list.png` })
    const memberKey = await p.$$eval('[data-test=users-row]', (els, m) => {
      const hit = els.find((e) => e.getAttribute('data-key').startsWith('m:') && e.textContent.toLowerCase().includes(m))
      return hit ? hit.getAttribute('data-key') : ''
    }, MEMBER)
    const oldRoleText = memberKey ? await rowRole(p, memberKey) : ''
    step('A4 the member is listed', Boolean(memberKey), { memberKey, role: oldRoleText })
    if (memberKey) {
      await p.click(rowSel(memberKey))
      await p.waitForSelector('[data-test=users-pane]', { visible: true, timeout: 10000 })
      const paneEmail = await text(p, '[data-test=users-pane-email]')
      const oldRole = await p.$eval('[data-test=users-pane-role]', (s) => s.value)
      step('A5 a click opens that user\'s edit pane', paneEmail === MEMBER && (await text(p, '[data-test=users-pane-id]')) === memberKey.slice(2), { paneEmail, oldRole })
      await p.screenshot({ path: `${OUT}/a-edit-pane.png` })
      // change role, then back
      await p.select('[data-test=users-pane-role]', 'tester')
      await p.click('[data-test=users-pane-save-role]')
      await sleep(2000)
      const changed = await rowRole(p, memberKey)
      await p.select('[data-test=users-pane-role]', oldRole)
      await p.click('[data-test=users-pane-save-role]')
      await sleep(2000)
      const back = await rowRole(p, memberKey)
      step('A6 change role lands and reverts', /tester/i.test(changed) && back === oldRoleText, { changed, back })
      // remove, confirmed
      await p.click('[data-test=users-pane-remove]')
      await confirm(p)
      step('A7 remove (confirmed) takes the member out', !(await rowKeys(p)).includes(memberKey))
      // invite the member back with its old role
      await p.click('[data-test=users-invite-open]')
      await p.waitForSelector('[data-test=users-invite-form]', { visible: true, timeout: 10000 })
      await p.type('[data-test=users-invite-email]', MEMBER)
      await p.select('[data-test=users-invite-role]', oldRole)
      await p.click('[data-test=users-invite-send]')
      // The member may already hold an older open invite row, so wait for the
      // form to close (the POST answered and the pane moved to the row).
      await p.waitForSelector('[data-test=users-invite-form]', { hidden: true, timeout: 30000 }).catch(() => null)
      const back2 = await p.waitForSelector(`${rowSel('i:' + MEMBER)}[aria-pressed="true"]`, { timeout: 15000 }).then(() => true).catch(() => false)
      step('A8 invite the member back (pending row, notice kept)', back2 && (await text(p, '[data-test=users-pane-notice]')).includes(MEMBER), { notice: await text(p, '[data-test=users-pane-notice]'), error: await text(p, '[data-test=users-pane-error]') })
    }
    // invite + revoke a throwaway address
    await p.click('[data-test=users-invite-open]')
    await p.waitForSelector('[data-test=users-invite-form]', { visible: true, timeout: 10000 })
    await p.type('[data-test=users-invite-email]', THROW)
    await p.select('[data-test=users-invite-role]', 'regular_user')
    await p.click('[data-test=users-invite-send]')
    await p.waitForSelector('[data-test=users-invite-form]', { hidden: true, timeout: 30000 }).catch(() => null)
    const inv = await p.waitForSelector(rowSel('i:' + THROW), { timeout: 15000 }).then(() => true).catch(() => false)
    step('A9 invite a throwaway address (notice names it)', inv && (await text(p, '[data-test=users-pane-notice]')).includes(THROW), { role: await rowRole(p, 'i:' + THROW), notice: await text(p, '[data-test=users-pane-notice]') })
    await p.screenshot({ path: `${OUT}/a-invited.png` })
    if (inv) {
      await p.click(rowSel('i:' + THROW))
      await p.waitForSelector('[data-test=users-pane-revoke]', { visible: true, timeout: 10000 })
      await p.click('[data-test=users-pane-revoke]')
      await confirm(p)
      step('A10 revoke (confirmed) takes the invite out', !(await rowKeys(p)).includes('i:' + THROW))
    }
  }

  }

  // ---- B: the non-admin (CONTROL) ----------------------------------------
  const b = await signIn(await browser.createBrowserContext(), MEMBER, 'MEMBER_PW_FILE')
  step(CONTROL_ONLY ? 'B1 the member signs in' : 'B1 the member signs in again (the re-invite admitted it)', b.ok, { url: b.p.url() })
  if (b.ok) {
    const noIcon = !(await b.p.$('[data-testid=sidebar-tab-users]'))
    const api = await apiStatus(b.p)
    step('B2 CONTROL: a non-admin sees no Users icon', noIcon)
    step('B3 CONTROL: a non-admin gets 403 members.invite from GET /v1/members', api.status === 403 && api.permission === 'members.invite', api)
    await b.p.screenshot({ path: `${OUT}/b-member-sidebar.png` })
  }
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const failed = res.steps.filter((s) => !s.ok)
console.log(failed.length ? `FAIL ${failed.length}/${res.steps.length}` : `PASS ${res.steps.length}/${res.steps.length}`)
process.exit(failed.length ? 1 : 0)
