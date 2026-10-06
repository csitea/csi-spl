// CLE-77891 (HUM-24, csitea topic af0ffb8c): "on some topics the menu has only
// three options, on others more". Every topic card's menu now has the SAME
// entries for every viewer; what the viewer may not do is shown disabled with
// the reason (a tooltip), never hidden. Runs against the lde mock; the opt-in
// localStorage `spool.mock.archive_policy` + `spool.mock.role` make the mock
// answer /v1/view/me like the hub does for a plain developer / an admin.
//
//   1  starter (a member, her own topic): the full menu, nothing disabled
//   2  non-starter (a member, GRK-03's card): the SAME entries; Edit, Move,
//      Merge, Delete disabled with the reason, Archive (policy everyone) usable;
//      a click on a disabled entry does nothing and keeps the menu open
//   3  admin (GRK-03's card): the same entries; only Edit disabled (an agent's
//      message is edited only by its agent)
//   4  starter policy: Archive is disabled on someone else's topic, same shape
//   5  Bulgarian: the reason reads in Bulgarian
//
// Run:
//   node tests/e2e/topic-menu-parity.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-menu-parity.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'cle-77891-a'
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

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`

/** Open a middle card's ⋯ menu and return its item testids. */
async function openMenu(p, sel) {
  /* disabled entries carry ':off', so includes('msg-menu-x') means usable */
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : '')))
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
  const one = await ch.send('CLE-77891 my own topic', undefined, undefined, undefined, 1)
  return { one: { msg_id: one.msg_id, task_id: one.task_id } }
}, { A })


/** Open a page with the workspace archive policy set (the access store reads /v1/view/me once per page life). */
async function withPolicy(p, policy, path, role = 'developer') {
  /* signed in (since specs/054 the mock is signed out unless an e2e opts in),
     so the access store reads the mock /v1/view/me */
  await p.evaluate((v) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', v.policy)
    localStorage.setItem('spool.mock.role', v.role)
  }, { policy, role })
  await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(800)
}

const SHAPE = ['msg-menu-open', 'msg-menu-copy', 'msg-menu-edit', 'msg-menu-move-channel', 'msg-menu-merge-topic', 'msg-menu-archive', 'msg-menu-delete-topic']
/* t1 b6c742f0: a PERSON's card also ends with the AI actions group (never an
   agent's, by the owner's order) - the topic entries are what stays the same */
const bare = (ids) => ids.filter((i) => !i.startsWith('msg-menu-ai-')).map((i) => i.replace(/:off$/, ''))
const offs = (ids) => ids.filter((i) => i.endsWith(':off')).map((i) => i.replace(/:off$/, ''))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const why = (p, id) => p.evaluate((id) => document.querySelector(`[data-testid=msg-menu-${id}]`)?.getAttribute('title') || '', id)

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

  /* ---- 1. starter: her own topic, the full menu -------------------------- */
  await withPolicy(p, 'everyone', '/channel/alerts')
  const seeded = await seed(p)
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 10000 })
  await sleep(400)
  const own = await openMenu(p, midCard(seeded.one.msg_id))
  ok('1 starter: the full topic menu', same(bare(own), SHAPE), own)
  ok('1 starter: nothing disabled', offs(own).length === 0, own)
  await shot(p, '1-starter')
  await p.keyboard.press('Escape')

  /* ---- 2. non-starter: the same entries, the locked ones disabled -------- */
  await withPolicy(p, 'everyone', '/channel/alerts')
  await p.waitForSelector(midCard(OTHER), { timeout: 10000 })
  const other = await openMenu(p, midCard(OTHER))
  ok('2 non-starter: the SAME entries as the starter', same(bare(other), SHAPE), other)
  ok('2 non-starter: Edit, Move, Merge, Delete disabled; Archive usable', same(offs(other), ['msg-menu-edit', 'msg-menu-move-channel', 'msg-menu-merge-topic', 'msg-menu-delete-topic']), other)
  const t2 = await why(p, 'delete-topic')
  ok('2 the disabled Delete says why', /starter/i.test(t2) && /admin/i.test(t2), t2)
  ok('2 the disabled Move says why', /move this topic/i.test(await why(p, 'move-channel')))
  await shot(p, '2-non-starter')
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-delete-topic]')?.click())
  await sleep(400)
  const after = await p.evaluate(() => ({
    menu: Boolean(document.querySelector('[data-testid=msg-menu]')),
    dialog: Boolean(document.querySelector('[data-testid=topic-delete-confirm]')),
  }))
  ok('2 a click on a disabled entry does nothing; the menu stays open', after.menu && !after.dialog, after)
  await p.keyboard.press('Escape')

  /* ---- 3. admin: the same entries, only Edit locked (an agent's card) ---- */
  await withPolicy(p, 'everyone', '/channel/alerts', 'admin')
  await p.waitForSelector(midCard(OTHER), { timeout: 10000 })
  const adm = await openMenu(p, midCard(OTHER))
  ok('3 admin: the SAME entries', same(bare(adm), SHAPE), adm)
  ok('3 admin: only Edit disabled (an agent\'s message)', same(offs(adm), ['msg-menu-edit']), adm)
  ok('3 the reason names the agent', /agent/i.test(await why(p, 'edit')))
  await p.keyboard.press('Escape')

  /* ---- 4. starter policy: Archive locked on someone else's, same shape --- */
  await withPolicy(p, 'starter', '/channel/alerts')
  await p.waitForSelector(midCard(OTHER), { timeout: 10000 })
  const st = await openMenu(p, midCard(OTHER))
  ok('4 starter policy: the SAME entries', same(bare(st), SHAPE), st)
  ok('4 starter policy: Archive disabled too', offs(st).includes('msg-menu-archive'), st)
  await p.keyboard.press('Escape')

  /* ---- 5. Bulgarian -------------------------------------------------------- */
  await withPolicy(p, 'everyone', '/bg/channel/alerts')
  await p.waitForSelector(midCard(OTHER), { timeout: 10000 })
  const bg = await openMenu(p, midCard(OTHER))
  const t5 = await why(p, 'delete-topic')
  ok('5 Bulgarian: the same entries, the reason in Bulgarian', same(bare(bg), SHAPE) && /започналият темата/.test(t5), { bg, t5 })
  await shot(p, '5-bg')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-menu-parity: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
