// 047 B5 / option A (SPL-1161) live proof: a paid tenant whose own host is not
// provisioned yet. Before this, the sign-in return and the signed-in boot hop
// sent the buyer to https://<tenant>.<fqdn>/, which is NXDOMAIN until workflow
// 40 maps it (CLE-35094, dev n=2). Now:
//   1. /login?tenant=<T> on the apex stays on the apex (the form is usable)
//   2. native sign-in with the buyer's address
//   3. the page says "your address <T>.<fqdn> is being prepared" and stays on
//      the apex (no navigation into the unmapped host)
//
//   SITE=https://dev.<domain> API=https://dev.api.<domain> TENANT=<paid tenant, host not mapped> \
//     EMAIL=<the checkout email> PW_FILE=<0600 file> OUT=<dir> [REGISTER=1] [CHROME_PATH=...] \
//     node tests/e2e/paid-host-pending-live.proof.mjs
//
// REGISTER=1 (dev only: the hub answers a debug verify token there) first makes
// the native account for EMAIL with a random password written to PW_FILE (0600).
// The password is never printed. Exit 0 = every step PASS.
import { randomBytes } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const SITE = need('SITE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = need('TENANT')
const email = need('EMAIL')
const PW_FILE = need('PW_FILE')
const siteHost = new URL(SITE).hostname
const want = `${TENANT}.${siteHost}`
mkdirSync(OUT, { recursive: true })
const res = { site: SITE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

async function post(path, body) {
  const r = await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' }, body: JSON.stringify(body) })
  let j = null
  try { j = await r.json() } catch { /* not json */ }
  return { status: r.status, body: j }
}

if (process.env.REGISTER === '1') {
  if (existsSync(PW_FILE)) { console.error('FATAL PW_FILE exists: REGISTER=1 makes a NEW account'); process.exit(2) }
  const pw = randomBytes(18).toString('base64url')
  const reg = await post('/api/v1/auth/register', { email, password: pw, name: 'B5 proof' })
  const tok = reg.body?.debug_token || ''
  const ver = tok ? await post('/api/v1/auth/email/verify', { token: tok, password: pw }) : { status: 0 }
  step('account registered + verified (dev debug token)', reg.status < 300 && !!tok && ver.status < 300, { register: reg.status, verify: ver.status })
  writeFileSync(PW_FILE, pw + '\n', { mode: 0o600 })
}
const pw = readFileSync(PW_FILE, 'utf8').trim()

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const p = await browser.newPage()
  const visited = []
  p.on('framenavigated', (f) => { if (f === p.mainFrame()) visited.push(f.url()) })

  // 1. the sign-in return with ?tenant= stays on the apex
  await p.goto(`${SITE}/login?tenant=${TENANT}`, { waitUntil: 'networkidle2' })
  await sleep(4000)
  step('1 /login?tenant=<T> stays on the apex (no hop into the unmapped host)',
    new URL(p.url()).hostname === siteHost && !visited.some((u) => u.includes(want)), { url: p.url() })

  // 2. native sign-in on the apex
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 20000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')

  // 3. "being prepared", on the apex
  const el = await p.waitForSelector('[data-test=tenant-host-preparing]', { visible: true, timeout: 45000 }).catch(() => null)
  const shown = el ? await p.$eval('[data-test=tenant-host-preparing]', (e) => ({ host: e.getAttribute('data-host'), text: e.textContent.trim() })) : null
  step('2 signed in: "your address <T>.<fqdn> is being prepared"', !!shown && shown.host === want, shown || {})
  await sleep(3000)
  step('3 still on the apex, never navigated to the unmapped host',
    new URL(p.url()).hostname === siteHost && !visited.some((u) => u.includes(want)), { url: p.url(), visited })
  await p.screenshot({ path: `${OUT}/paid-host-pending.png` })
} finally {
  await browser.close()
}
res.ok = res.steps.every((s) => s.ok)
writeFileSync(`${OUT}/paid-host-pending.json`, JSON.stringify(res, null, 1))
console.log(res.ok ? 'paid-host-pending: all PASS' : 'paid-host-pending: FAILED')
process.exit(res.ok ? 0 : 1)
