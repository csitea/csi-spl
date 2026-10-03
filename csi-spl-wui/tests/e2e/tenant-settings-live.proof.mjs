// SPL-1037 (specs/046) live proof of Tenant settings against a deployed WUI
// + hub, in a TEST tenant (prd `e2e` or dev `t1`): it WRITES the membership
// of MEMBER_EMAIL, and leaves the tenant as it found it.
//
// Session A (ADMIN_EMAIL, an admin or biz_owner of TENANT): the building icon
// is the bottom-left corner; it opens /tenant-settings with Members, Agents,
// Channels and General; Members invites MEMBER_EMAIL as a tester.
// Session B (MEMBER_EMAIL): signs in (the invite admits it) and is the
// CONTROL: no icon, no avatar-menu row, /tenant-settings says it is not
// allowed, and the hub answers 403 on GET /v1/tenant/settings,
// /v1/tenant/channels and /v1/members.
// Session A again: changes the member's role (tester -> developer), then
// removes it (confirmed). Session B: GET /v1/view/me is 403 at once.
//
//   BASE=https://e2e.<domain> API=https://api.<domain> TENANT=e2e \
//   ADMIN_EMAIL=<admin test account> ADMIN_PW_FILE=<0600 file> \
//   MEMBER_EMAIL=<second test account, not in TENANT> MEMBER_PW_FILE=<0600 file> \
//   OUT=<dir> node tests/e2e/tenant-settings-live.proof.mjs
//
// Passwords are read from the files and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = need('TENANT')
const ADMIN = need('ADMIN_EMAIL')
const MEMBER = need('MEMBER_EMAIL').toLowerCase()
const pwOf = (k) => readFileSync(need(k), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
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
/** The hub's answer to GET <API><path> from inside the page (the session cookie rides along). */
const apiGet = (p, path) => p.evaluate(async (url) => {
  const r = await fetch(url, { credentials: 'include', headers: { accept: 'application/json' } })
  let body = null
  try { body = await r.json() } catch { /* not json */ }
  return { status: r.status, error: body && body.error, permission: body && body.permission, human_id: body && body.human_id, role: body && body.role }
}, API + path)
/** The Members row key (m:HUM-n / i:<email>) whose row names `email`, '' when none. */
const rowOf = (p, email, kind) => p.$$eval('[data-test=users-row]', (els, [email, kind]) => {
  const hit = els.find((e) => e.getAttribute('data-key').startsWith(kind + ':') && e.textContent.toLowerCase().includes(email))
  return hit ? hit.getAttribute('data-key') : ''
}, [email, kind])
const roleOf = (p, key) => p.$eval(`[data-test=users-row][data-key="${key}"] [data-test=users-row-role]`, (e) => e.textContent.trim()).catch(() => '')
async function members(p) {
  await p.goto(BASE + '/tenant-settings/members', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=tenant-settings-members] [data-test=users-row]', { visible: true, timeout: 20000 })
}
async function confirm(p) {
  await p.waitForSelector('[data-test=users-confirm-ok]', { visible: true, timeout: 10000 })
  await p.click('[data-test=users-confirm-ok]')
  await sleep(1500)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await fetch(BASE + '/build.json').then((r) => r.json()).catch((e) => ({ error: String(e) }))
  res.version = await fetch(API + '/version').then((r) => r.json()).catch((e) => ({ error: String(e) }))

  // ---- A: the admin opens Tenant settings and invites ----------------------
  const ca = await browser.createBrowserContext()
  const a = await signIn(ca, ADMIN, 'ADMIN_PW_FILE')
  step('A0 admin signs in', a.ok)
  const me = await apiGet(a.p, '/v1/view/me')
  step('A0b admin role in ' + TENANT, me.status === 200 && ['admin', 'biz_owner'].includes(me.role), me)
  const icon = await a.p.waitForSelector('[data-testid=tenant-settings-open]', { visible: true, timeout: 20000 }).catch(() => null)
  const box = icon && await icon.evaluate((e) => { const r = e.getBoundingClientRect(); return { left: Math.round(r.left), bottom: Math.round(r.bottom), vh: innerHeight } })
  step('A1 the Tenant settings icon is the bottom-left corner', Boolean(box) && box.left < 80 && box.vh - box.bottom < 80, box || {})
  await a.p.screenshot({ path: `${OUT}/A1-icon.png` })
  await icon.click()
  await a.p.waitForSelector('[data-test=tenant-settings-nav]', { visible: true, timeout: 20000 })
  const nav = await a.p.$$eval('[data-test=tenant-settings-nav] a', (els) => els.map((e) => e.getAttribute('data-test').replace('tenant-settings-nav-', '')))
  step('A2 the Settings layout: Members, Agents, Vendor split, Channels, General', nav.join() === 'members,agents,split,channels,general', { nav })
  for (const s of ['agents', 'split', 'channels', 'general']) {
    await a.p.click(`[data-test=tenant-settings-nav-${s}]`)
    const ok = await a.p.waitForSelector(`[data-test=tenant-settings-${s}]`, { visible: true, timeout: 20000 }).then(() => true).catch(() => false)
    await sleep(1500)
    const err = await text(a.p, `[data-test=tenant-settings-${s}] .ts-error`)
    step(`A3 ${s} loads from the hub`, ok && !err, { err })
    await a.p.screenshot({ path: `${OUT}/A3-${s}.png` })
  }
  await members(a.p)
  const before = await rowOf(a.p, MEMBER, 'm')
  if (before) step('A4 CONTROL: the member is not in ' + TENANT + ' before the proof', false, { before })
  await a.p.click('[data-test=tenant-settings-members] [data-test=users-invite-open]')
  await a.p.waitForSelector('[data-test=users-invite-form]', { visible: true, timeout: 10000 })
  await a.p.type('[data-test=users-invite-email]', MEMBER)
  await a.p.select('[data-test=users-invite-role]', 'tester')
  await a.p.click('[data-test=users-invite-send]')
  await a.p.waitForFunction(() => !document.querySelector('[data-test=users-invite-form]'), { timeout: 20000 }).catch(() => null)
  await sleep(1000)
  const notice = await text(a.p, '[data-test=users-pane-notice]')
  step('A4 admin invites the member as tester', Boolean(await rowOf(a.p, MEMBER, 'i')), { notice })
  await a.p.screenshot({ path: `${OUT}/A4-invited.png` })

  // ---- B: the member is admitted and is the control -----------------------
  const cb = await browser.createBrowserContext()
  const b = await signIn(cb, MEMBER, 'MEMBER_PW_FILE')
  const bme = await apiGet(b.p, '/v1/view/me')
  step('B0 the member signs in to ' + TENANT + ' as tester (the invite admitted it)', b.ok && bme.status === 200 && bme.role === 'tester', bme)
  await b.p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  await sleep(2500)
  step('B1 CONTROL: no Tenant settings icon for a member', !(await b.p.$('[data-testid=tenant-settings-open]')))
  await b.p.click('[data-test=user-menu-trigger]').catch(() => null)
  await sleep(600)
  step('B2 CONTROL: no Tenant settings row in the avatar menu', !(await b.p.$('[data-test=user-menu-tenant-settings]')))
  for (const [path, perm] of [['/v1/tenant/settings', 'tenant.settings'], ['/v1/tenant/channels', 'tenant.settings'], ['/v1/members', 'members.invite']]) {
    const r = await apiGet(b.p, path)
    step(`B3 CONTROL: GET ${path} is 403 ${perm}`, r.status === 403 && r.permission === perm, r)
  }
  await b.p.goto(BASE + '/tenant-settings', { waitUntil: 'networkidle2' })
  const denied = await b.p.waitForSelector('[data-test=tenant-settings-forbidden]', { timeout: 15000 }).then(() => true).catch(() => false)
  step('B4 CONTROL: /tenant-settings tells a member it is not allowed', denied)
  await b.p.screenshot({ path: `${OUT}/B4-member-denied.png` })

  // ---- A: role change, then removal ----------------------------------------
  await members(a.p)
  const key = await rowOf(a.p, MEMBER, 'm')
  step('A5 the member is listed', Boolean(key), { key })
  await a.p.click(`[data-test=users-row][data-key="${key}"]`)
  await a.p.waitForSelector('[data-test=users-pane-role]', { visible: true, timeout: 10000 })
  await a.p.select('[data-test=users-pane-role]', 'developer')
  await a.p.click('[data-test=users-pane-save-role]')
  await sleep(2000)
  const role = await roleOf(a.p, key)
  const bme2 = await apiGet(b.p, '/v1/view/me')
  step('A6 admin changes the role tester -> developer', /developer/i.test(role) && bme2.role === 'developer', { role, hub: bme2.role })
  await a.p.screenshot({ path: `${OUT}/A6-role.png` })
  await a.p.click('[data-test=users-pane-remove]')
  await confirm(a.p)
  step('A7 admin removes the member (confirmed)', !(await rowOf(a.p, MEMBER, 'm')))
  await a.p.screenshot({ path: `${OUT}/A7-removed.png` })
  const gone = await apiGet(b.p, '/v1/view/me')
  step('B5 the removed member reads nothing at once (403)', gone.status === 403, gone)
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const failed = res.steps.filter((s) => !s.ok)
console.log(failed.length ? `FAIL ${failed.length}/${res.steps.length}` : `PASS ${res.steps.length}/${res.steps.length}`)
process.exit(failed.length ? 1 : 0)
