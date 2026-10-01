// CLE-77819 (owner 2026-09-30, csitea #spool-hub topic 85597e91): a REGULAR
// member archives her own topic and undoes it; under a workspace policy that
// does not let her, the menu has no Archive on someone else's topic.
// "Who can archive topics" is a per-workspace setting (everyone - the
// default - | admins | starter). Runs against the lde mock; the opt-in
// localStorage `spool.mock.archive_policy` makes the mock answer
// /v1/view/me like the hub does for a plain developer in such a workspace.
//
//   1  starter: her own new topic -> Archive -> "Archived · Undo" -> Undo
//      brings it back
//   2  starter: someone else's topic (#alerts, by GRK-03) -> no Archive,
//      no Delete
//   3  CONTROL everyone (the default): the same card offers Archive
//   4  admins: even her own topic offers no Archive
//
// Run:
//   node tests/e2e/topic-archive-policy.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-archive-policy.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'cle-77819-a'
const OTHER = '66666666-6666-4666-8666-666666666666' // #alerts card by GRK-03 (mock-data)
if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=archive-toast-text]')?.textContent.trim() || '')
const hasToast = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=archive-toast]')))

/** Open a middle card's ⋯ menu and return its item testids. */
async function openMenu(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}

/** Seed a channel and one own topic card, return its ids. */
const seed = (p) => p.evaluate(async ({ A }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send('CLE-77819 my own topic', undefined, undefined, undefined, 1)
  return { one: { msg_id: one.msg_id, task_id: one.task_id } }
}, { A })

/** Click the Archive item in an already-open menu. */
const clickArchive = (p) => p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())

/** Open a page with the workspace archive policy set (the access store reads /v1/view/me once per page life). */
async function withPolicy(p, policy, path) {
  /* signed in (since specs/054 the mock is signed out unless an e2e opts in),
     so the access store reads the mock /v1/view/me */
  await p.evaluate((v) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', v)
  }, policy)
  await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(800)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  /* warm a throwaway page: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* ---- 1. starter: her own topic -> Archive -> Undo ---------------------- */
  await withPolicy(p, 'starter', '/channel/alerts')
  const seeded = await seed(p)
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 10000 })
  await sleep(400)
  const own = await openMenu(p, midCard(seeded.one.msg_id))
  ok('1 starter: her own topic offers Archive', own.includes('msg-menu-archive'), own)
  await clickArchive(p)
  ok('1 the archived topic leaves the feed', await until(p, (sel) => !document.querySelector(sel), midCard(seeded.one.msg_id)))
  await p.waitForSelector('[data-testid=archive-toast]', { timeout: 5000 }).catch(() => {})
  const t1 = await toastText(p)
  ok('1 the snackbar says "Archived" and offers Undo', t1 === 'Archived' && Boolean(await p.$('[data-testid=archive-toast-undo]')), t1)
  await shot(p, '1-archived')
  await p.click('[data-testid=archive-toast-undo]')
  ok('1 Undo brings her topic back', await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(seeded.one.msg_id)))

  /* ---- 2. starter: someone else's topic has no Archive ------------------- */
  await withPolicy(p, 'starter', '/channel/alerts')
  await p.waitForSelector(midCard(OTHER), { timeout: 10000 })
  const other = await openMenu(p, midCard(OTHER))
  ok('2 starter: someone else\'s topic offers no Archive and no Delete', other.length > 0 && !other.includes('msg-menu-archive') && !other.includes('msg-menu-delete-topic'), other)
  await shot(p, '2-other-no-archive')
  await p.keyboard.press('Escape')

  /* ---- 3. CONTROL everyone (default): the same card offers Archive -------- */
  await withPolicy(p, 'everyone', '/channel/alerts')
  await p.waitForSelector(midCard(OTHER), { timeout: 10000 })
  const every = await openMenu(p, midCard(OTHER))
  ok('3 CONTROL everyone: someone else\'s topic offers Archive (but not Delete)', every.includes('msg-menu-archive') && !every.includes('msg-menu-delete-topic'), every)
  await p.keyboard.press('Escape')

  /* ---- 4. admins: not even her own topic -------------------------------- */
  await withPolicy(p, 'admins', '/channel/alerts')
  const seeded2 = await seed(p)
  await p.waitForSelector(midCard(seeded2.one.msg_id), { timeout: 10000 })
  await sleep(400)
  const adm = await openMenu(p, midCard(seeded2.one.msg_id))
  ok('4 admins: a plain member\'s own topic offers no Archive', adm.length > 0 && !adm.includes('msg-menu-archive'), adm)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-archive-policy: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
