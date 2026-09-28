// CLE-35075 (perf lane P2, epic SPL-1093) - the post-deploy smoke every P2
// improvement is held to: against a DEPLOYED WUI, signed out then signed in,
// load / and /login in turn for DURATION_S (default 180 s) and fail on any
// page error, console error, failed request (status >= 400 other than the
// signed-out session probe's 401) or an untranslated i18n key on screen.
// Also: /bg/login must render Bulgarian (runtime-only vue-i18n, SPL-1097),
// and it counts GET /api/v1/auth/providers per /login load (SPL-1110).
// WRITES NOTHING.
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [DURATION_S=180] [USER_DATA_DIR=<dir>] [CHROME_PATH=...]
//     node tests/e2e/p2-smoke-live.proof.mjs
// The password is never printed.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const DURATION_S = Number(process.env.DURATION_S || 180)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, checks: [], loads: [] }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: Boolean(pass), ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
/* a dotted catalogue key left on screen, e.g. "feed.load_more" */
const RAW_KEY = /\b(?:feed|auth|login|sidebar|topic|settings|native_auth|social_auth|issues|search|omnibox|common|errors?)\.[a-z0-9_]+(?:\.[a-z0-9_]+)*\b/

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

function watch(p) {
  const seen = { errors: [], failed: [], providers: 0 }
  p.on('pageerror', (e) => seen.errors.push('pageerror: ' + String(e && e.message || e).slice(0, 200)))
  /* Chrome also logs every HTTP error status as "Failed to load resource";
     the response listener below judges those (the signed-out 401 is expected) */
  p.on('console', (m) => {
    if (m.type() === 'error' && !m.text().startsWith('Failed to load resource')) seen.errors.push('console: ' + m.text().slice(0, 200))
  })
  p.on('response', (r) => {
    const u = r.url()
    if (u.includes('/api/v1/auth/providers') && r.request().method() === 'GET') seen.providers++
    const signedOutProbe = r.status() === 401 && u.includes('/api/v1/auth/session')
    if (r.status() >= 400 && !signedOutProbe) seen.failed.push(`${r.status()} ${u.slice(0, 160)}`)
  })
  p.on('requestfailed', (r) => {
    const why = (r.failure() && r.failure().errorText) || ''
    /* a navigation away aborts what the old page had in flight */
    if (why !== 'net::ERR_ABORTED') seen.failed.push(`failed ${why} ${r.url().slice(0, 160)}`)
  })
  return seen
}

async function visit(p, seen, path, ready) {
  const e0 = seen.errors.length
  const f0 = seen.failed.length
  const pr0 = seen.providers
  const t0 = Date.now()
  await p.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector(ready, { timeout: 30000 })
  const text = await p.evaluate(() => document.body.innerText)
  const raw = RAW_KEY.exec(text)
  const row = {
    path, ms: Date.now() - t0,
    errors: seen.errors.slice(e0), failed: seen.failed.slice(f0),
    providers: seen.providers - pr0, raw_key: raw ? raw[0] : '',
  }
  res.loads.push(row)
  return { row, text }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  ...(process.env.USER_DATA_DIR ? { userDataDir: process.env.USER_DATA_DIR } : {}),
})
let code = 0
try {
  /* signed out: a fresh context, en and bg */
  const anon = await browser.createBrowserContext()
  const a = await anon.newPage()
  const aw = watch(a)
  const en = await visit(a, aw, '/login?tenant=' + TENANT, '.login-card')
  const bg = await visit(a, aw, '/bg/login?tenant=' + TENANT, '.login-card')
  ok('signed out /login renders, no error, no raw key', !en.row.errors.length && !en.row.failed.length && !en.row.raw_key, en.row)
  ok('/bg/login renders Bulgarian (Cyrillic, not the English text)', /[Ѐ-ӿ]/.test(bg.text) && bg.text !== en.text && !bg.row.raw_key, { raw_key: bg.row.raw_key, sample: bg.text.slice(0, 80) })
  ok('/login reads GET /auth/providers (count per load)', en.row.providers >= 1, { providers: en.row.providers })
  await anon.close()

  /* signed in (reuses USER_DATA_DIR's session when present) */
  const p = await browser.newPage()
  const w = watch(p)
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  if (await p.$('[data-test=native-auth-email]')) {
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.keyboard.press('Enter')
  } else {
    /* already signed in (USER_DATA_DIR): /login shows "Continue", it never redirects */
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2', timeout: 60000 })
  }
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  const t0 = Date.now()
  let n = 0
  while (Date.now() - t0 < DURATION_S * 1000) {
    await visit(p, w, '/', '.sidebar')
    await visit(p, w, '/login', 'body')
    n++
  }
  const bad = res.loads.slice(3).filter((r) => r.errors.length || r.failed.length || r.raw_key)
  ok(`signed in: / and /login for ${DURATION_S} s (${n} rounds) with no error, failed request or raw key`, bad.length === 0, bad.slice(0, 5))
  const ms = res.loads.slice(3).filter((r) => r.path === '/').map((r) => r.ms).sort((x, y) => x - y)
  res.root_ms = { n: ms.length, p50: ms[Math.floor(ms.length / 2)], p95: ms[Math.floor(ms.length * 0.95)] }
  console.log(`  / load ms n=${ms.length} p50=${res.root_ms.p50} p95=${res.root_ms.p95}`)
} catch (e) {
  ok('harness', false, String(e && e.message || e))
  /* what the page showed when it gave up */
  for (const pg of await browser.pages().catch(() => [])) {
    const at = await pg.evaluate(() => location.href).catch(() => '')
    res.stuck_at = at
    await pg.screenshot({ path: join(OUT, 'stuck.png') }).catch(() => {})
  }
} finally {
  await browser.close()
  if (res.checks.some((c) => !c.ok)) code = 1
  writeFileSync(join(OUT, 'p2-smoke.json'), JSON.stringify(res, null, 2))
  console.log(code ? 'p2-smoke: FAIL' : 'p2-smoke: PASS')
  process.exit(code)
}
