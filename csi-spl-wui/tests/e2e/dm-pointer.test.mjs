// dc6d5e3f (owner, prd t1): "if I tag the agent in a channels topic, it
// means that this msg WILL appear also as a personal msg ... but of course it
// should be treated as a reply in the topic and not a new topic". Proved in a
// REAL browser at 1440x900 and 390x844 against the mock bundle: a #lobby
// reply that tags GRK-03, and GRK-03's line back, show in the DM view of
// GRK-03 as ONE pointer card of their topic, headed "in #lobby / <topic>",
// and its link opens the reply in its topic (/m/<msg_id>), not in the DM.
//
// Two rows are added through the mock's test hook (localStorage
// spool.mock.extra-messages). CONTROLS: a plain DM card carries no pointer
// header; a tag of another agent (CLE-07) is not in GRK-03's DM view.
// Red before dm-pointer.mjs (no card for the tag), n=1 per size.
//
// Run:
//   pnpm run test:e2e dm-pointer
//   BASE_URL=<generated bundle> pnpm run test:e2e dm-pointer     # what CI does
//   SHOT_DIR=/tmp/shots ...                                       # keep the screenshots
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TOPIC_TITLE = 'Review the spool WUI scaffold and keep tests green.'
const PLAIN_DM = '77777777-7777-4777-8777-777777777777'
const TAG = 'dc6d5e3f-0000-4000-8000-000000000001'
const BACK = 'dc6d5e3f-0000-4000-8000-000000000002'
const OTHER = 'dc6d5e3f-0000-4000-8000-000000000003'
const DM_PEER = 'GRK-03@box-a'
const line = (msg_id, ts, from, from_box, to, to_box, body) => ({ v: 1, msg_id, task_id: TOPIC, ts, from, from_box, to, to_box,
  kind: 'note', body, files: [], channel: 'lobby', parent_task_id: TOPIC, is_parent: 0 })
const EXTRA = [
  line(TAG, '2026-09-18T10:08:00Z', 'HUM-1', 'box-wui', 'GRK-03', 'box-a', '@GRK-03 please check the scaffold tests'),
  line(BACK, '2026-09-18T10:09:00Z', 'GRK-03', 'box-a', 'HUM-1', 'box-wui', 'The scaffold tests pass: 42 of 42.'),
  line(OTHER, '2026-09-18T10:10:00Z', 'HUM-1', 'box-wui', 'CLE-07', 'box-a', '@CLE-07 a line for someone else'),
]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

function pointerOf(page, id) {
  return page.evaluate((sel) => {
    const row = document.querySelector(sel)
    if (!row) return null
    const el = row.querySelector('[data-testid=msg-dm-pointer]')
    const link = el ? el.querySelector('a') : null
    const r = el ? el.getBoundingClientRect() : null
    return {
      task: el ? el.getAttribute('data-pointer-task-id') : null,
      text: el ? el.textContent.trim() : null,
      href: link ? link.getAttribute('href') : null,
      tip: link ? link.getAttribute('title') : null,
      shown: Boolean(r && r.width > 0 && r.height > 0),
    }
  }, `article.msg[data-msg-id="${id}"]`)
}
const card = (id) => `article.msg[data-msg-id="${id}"]`

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.evaluateOnNewDocument((extra) => {
      try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra)) } catch { /* about:blank */ }
    }, EXTRA)
    await setPageViewport(p, size)
    await p.goto(server.base + `/dm/${DM_PEER}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await p.waitForSelector(card(PLAIN_DM), { timeout: NAV_TIMEOUT })
    await p.waitForSelector(`${card(TAG)} [data-testid=msg-dm-pointer]`, { timeout: 10000 }).catch(() => {})

    const ptr = await pointerOf(p, TAG)
    const want = `in #lobby / ${TOPIC_TITLE.slice(0, 47)}… (a reply in the topic)`
    ok(`${tag} DM: the tag is a pointer card of its topic`, Boolean(ptr) && ptr.task === TOPIC && ptr.shown, ptr)
    ok(`${tag} DM: headed "${want}"`, Boolean(ptr) && ptr.text === want, ptr?.text)
    ok(`${tag} DM: the full title is on hover`, Boolean(ptr) && ptr.tip === `in #lobby / ${TOPIC_TITLE} (a reply in the topic)`, ptr?.tip)
    ok(`${tag} DM: the link opens the reply itself`, Boolean(ptr && ptr.href) && ptr.href.endsWith(`/m/${TAG}`), ptr?.href)
    const cards = await p.$$eval('article.msg[data-msg-id]', (els) => els.map((e) => e.getAttribute('data-msg-id')))
    ok(`${tag} DM: one card for the topic (the agent's line back is its reply, no second topic)`,
      cards.includes(TAG) && !cards.includes(BACK), cards)
    ok(`${tag} CONTROL: a tag of another agent is not in this DM`, !cards.includes(OTHER), cards)
    const plain = await pointerOf(p, PLAIN_DM)
    ok(`${tag} CONTROL: a plain DM carries no pointer header`, Boolean(plain) && plain.task === null, plain)
    if (process.env.SHOT_DIR) {
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, `dm-pointer-${tag}.png`) })
    }

    if (ptr && ptr.href) {
      await p.click(`${card(TAG)} [data-testid=msg-dm-pointer] a`)
      const went = await p.waitForFunction((t) => !location.pathname.includes('/dm/') && (location.search + location.hash + location.pathname).includes(t),
        { timeout: NAV_TIMEOUT }, TOPIC).then(() => true).catch(() => false)
      ok(`${tag} DM: the pointer opens the reply in its topic, out of the DM`, went, await p.evaluate(() => location.pathname + location.search + location.hash))
    }

    ok(`${tag}: no page error`, errors.length === 0, errors)
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
