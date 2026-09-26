// SPL-959 live proof of tenant hosts against a deployed env (owner option B):
// the apex is the apex tenant, <tenant>.<fqdn> is that tenant, and ONE sign-in
// (native, on the apex) serves every host of the env. Each read is judged by
// the hub's own answer on the api host, made from the page (so the browser's
// Origin is the page host, as for every WUI call).
//
//   SITE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member> PW_FILE=<0600 file> \
//     MEMBER_TENANT=<a 2nd tenant the member is in> FOREIGN_TENANT=<a tenant it is not in> \
//     OUT=<dir> [APEX_TENANT=t1] [OLD_TOPIC=<uuid of a MEMBER_TENANT topic>] [CHROME_PATH=...] \
//     node tests/e2e/tenant-hosts-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const SITE = need('SITE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const MEMBER = need('MEMBER_TENANT')
const FOREIGN = need('FOREIGN_TENANT')
const APEX = process.env.APEX_TENANT || 't1'
const OLD_TOPIC = process.env.OLD_TOPIC || ''
const siteHost = new URL(SITE).hostname
const host = (t) => (t === APEX ? SITE : `https://${t}.${siteHost}`)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { site: SITE, api: API, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
/** GET <API><path> from the page, with the cookie: the hub sees the page's Origin. */
async function hubGet(p, path) {
  for (let i = 0; ; i++) {
    try {
      return await p.evaluate(async (url) => {
        const r = await fetch(url, { credentials: 'include', cache: 'no-store' })
        let body = null
        try { body = await r.json() } catch { /* not json */ }
        return { status: r.status, body }
      }, API + path)
    } catch (e) {
      /* the WUI may still be moving (a signed-out page goes to /login, a host hop) */
      if (i >= 4 || !/context was destroyed|detached/i.test(String(e))) throw e
      await sleep(1500)
    }
  }
}
const who = (b) => (b && Array.isArray(b.boxes) ? b.boxes.length : null)
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  for (const t of [APEX, MEMBER, FOREIGN]) {
    try { res[`build_${t}`] = await (await fetch(host(t) + '/build.json')).json() } catch (e) { res[`build_${t}`] = String(e) }
  }
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })

  // 0. CONTROL: signed out, the tenant host serves the WUI but the hub gives no data.
  await p.goto(host(MEMBER) + '/lobby', { waitUntil: 'networkidle2' })
  const anon = await hubGet(p, '/v1/view/roster')
  step(`signed out on ${MEMBER}'s host: the WUI loads, the hub gives no data`, anon.status === 401, { url: p.url(), status: anon.status })

  // 1. ONE native sign-in, on the apex.
  await p.goto(SITE + '/login?redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in on the apex', !!trig, { url: p.url() })
  await sleep(1500)
  const sApex = await hubGet(p, '/api/v1/auth/session')
  const rApex = await hubGet(p, '/v1/view/roster')
  step(`the apex is ${APEX}`, new URL(p.url()).origin === SITE && sApex.body?.active_tenant === APEX && rApex.status === 200,
    { url: p.url(), active_tenant: sApex.body?.active_tenant, roster: rApex.status, boxes: who(rApex.body) })
  await p.screenshot({ path: `${OUT}/apex.png` })

  // 2. Same browser, the member tenant's host: no second sign-in, that tenant's data.
  await p.goto(host(MEMBER) + '/lobby', { waitUntil: 'networkidle2' })
  const trig2 = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  const sMem = await hubGet(p, '/api/v1/auth/session')
  const rMem = await hubGet(p, '/v1/view/roster')
  step(`${MEMBER}'s host: signed in with no new sign-in, reads ${MEMBER}`, !!trig2 && sMem.body?.active_tenant === MEMBER && rMem.status === 200,
    { url: p.url(), active_tenant: sMem.body?.active_tenant, roster: rMem.status, boxes: who(rMem.body) })
  await p.screenshot({ path: `${OUT}/member-host.png` })

  // 3. Back on the apex: still the apex tenant (the host, not the last visit, decides).
  await p.goto(SITE + '/lobby', { waitUntil: 'networkidle2' })
  const sBack = await hubGet(p, '/api/v1/auth/session')
  step(`back on the apex: ${APEX} again`, sBack.body?.active_tenant === APEX, { active_tenant: sBack.body?.active_tenant })

  // 4. A tenant the member is NOT in: "not a member", and the hub refuses every read.
  await p.goto(host(FOREIGN) + '/issues', { waitUntil: 'networkidle2' })
  const nm = await p.waitForSelector('[data-test=tenant-not-member]', { timeout: 20000 }).catch(() => null)
  const rFor = await hubGet(p, '/v1/view/roster')
  const iFor = await hubGet(p, '/v1/view/issues')
  step(`${FOREIGN}'s host: "not a member", 403 not_member, no data`, !!nm && rFor.status === 403 && rFor.body?.error === 'not_member' && iFor.status !== 200,
    { url: p.url(), notice: nm ? await nm.evaluate((e) => e.textContent.trim()) : '', roster: rFor.status, error: rFor.body?.error, issues: iFor.status })
  await p.screenshot({ path: `${OUT}/foreign-host.png` })

  // 5. The apex forwards ?tenant=<t> (the sign-in return / an invite link).
  await p.goto(SITE + '/lobby?tenant=' + MEMBER, { waitUntil: 'networkidle2' })
  await p.waitForFunction((h) => location.origin === h, { timeout: 15000 }, host(MEMBER)).catch(() => null)
  step(`apex ?tenant=${MEMBER} lands on ${MEMBER}'s host`, new URL(p.url()).origin === host(MEMBER) && !new URL(p.url()).searchParams.has('tenant'), { url: p.url() })

  // 6. The switcher changes host, same path.
  await p.goto(SITE + '/lobby', { waitUntil: 'networkidle2' })
  const sel = await p.waitForSelector('[data-testid=tenant-switcher-select]', { timeout: 20000 }).catch(() => null)
  if (sel) {
    await Promise.all([p.waitForNavigation({ timeout: 20000 }).catch(() => null), p.select('[data-testid=tenant-switcher-select]', MEMBER)])
    await sleep(1000)
  }
  step(`the switcher goes to ${MEMBER}'s host, same path`, !!sel && new URL(p.url()).origin === host(MEMBER) && new URL(p.url()).pathname.endsWith('/lobby'), { url: p.url() })

  // 7. An old apex link to a topic of the member tenant lands on its host.
  if (OLD_TOPIC) {
    await p.goto(SITE + '/t/' + OLD_TOPIC, { waitUntil: 'networkidle2' })
    await p.waitForFunction((h) => location.origin === h, { timeout: 20000 }, host(MEMBER)).catch(() => null)
    step(`old apex link /t/<${MEMBER} topic> lands on ${MEMBER}'s host`, p.url() === host(MEMBER) + '/t/' + OLD_TOPIC, { url: p.url() })
  }
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; builds ${[APEX, MEMBER, FOREIGN].map((t) => res[`build_${t}`]?.commit).join(' ')}`)
process.exit(bad ? 1 : 0)
