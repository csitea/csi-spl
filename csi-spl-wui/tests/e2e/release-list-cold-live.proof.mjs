// Live proof (c-834 finding, v6.6.5 99bfa1691, dev, n=4): a release note link
// opened cold, /releases/<sha> in a fresh tab of a signed-in browser, showed
// the note, but "Back to the list" said "Could not load the release notes":
// GET /v1/release-notes/<sha> answered 200, GET /v1/release-notes?limit=30
// answered 401. The dialog read the list during setup, before the session
// probe had armed the client's `session` door, so the list read went out
// without the sign-in cookie.
//
// Per viewport (1440x900 desktop, 390x844 phone), signed in, cold:
//   1 /releases/<sha> shows that note
//   2 "Back to the list" shows release rows, no error line
//   3 the list read (/v1/release-notes?limit=30) answered 2xx in the end
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [SHA=<40-hex>] [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/release-list-cold-live.proof.mjs
//
// SHA defaults to the sha the WUI's build.json carries. The password is read
// from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const build = await (await fetch(BASE + '/build.json')).json()
  res.build = build
  const sha = String(process.env.SHA || build.sha || build.commit || '').toLowerCase()
  if (!/^[0-9a-f]{7,40}$/.test(sha)) throw new Error(`no sha to open (build.json: ${JSON.stringify(build)})`)
  res.sha = sha
  const ctx = await browser.createBrowserContext()
  const login = await ctx.newPage()
  await login.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await login.waitForSelector('[data-test=native-auth-email]')
  await login.type('[data-test=native-auth-email]', email)
  await login.type('[data-test=native-auth-password]', pw)
  await login.click('[data-test=native-auth-submit]')
  const trig = await login.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: login.url() })
  await login.close()
  for (const [w, h, tag] of [[1440, 900, 'desktop'], [390, 844, 'phone']]) {
    // a new tab: the cold load a pasted link or a link opened in a new tab makes
    const p = await ctx.newPage()
    await p.setViewport({ width: w, height: h })
    const reads = []
    p.on('response', (r) => {
      const u = new URL(r.url())
      if (u.pathname.startsWith('/v1/release-notes')) reads.push({ path: u.pathname + u.search, status: r.status() })
    })
    await p.goto(BASE + '/releases/' + sha, { waitUntil: 'networkidle2' })
    const noteEl = await p.waitForSelector('[data-test=release-note]', { visible: true, timeout: 20000 }).catch(() => null)
    const noteSha = noteEl ? await noteEl.evaluate((e) => e.getAttribute('data-sha')) : ''
    step(`${tag} ${w}: /releases/<sha> shows that note`, String(noteSha).startsWith(sha), { noteSha })
    const back = await p.$('[data-test=release-note-back]')
    if (back) await back.click()
    await p.waitForSelector('[data-test=release-row]', { visible: true, timeout: 15000 }).catch(() => null)
    await sleep(500)
    const rows = await p.$$eval('[data-test=release-row]', (els) => els.length)
    const err = await p.$eval('[data-test=release-notes]', (e) => e.textContent || '').catch(() => '')
    step(`${tag} ${w}: Back to the list shows the rows`, !!back && rows > 0 && !/could not load/i.test(err), { back: !!back, rows })
    const list = reads.filter((r) => /^\/v1\/release-notes\?/.test(r.path))
    step(`${tag} ${w}: the list read answered 2xx`, list.some((r) => r.status >= 200 && r.status < 300), { reads })
    await p.screenshot({ path: `${OUT}/back-to-list-${tag}.png` })
    await p.close()
  }
} catch (e) {
  step('proof ran', false, { error: String(e && e.message) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
