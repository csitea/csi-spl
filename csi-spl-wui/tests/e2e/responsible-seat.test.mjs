// Spec 068 L8, proved in a REAL browser: every message card shows its
// responsible seat (`responsible`, <id>@<box>, rdb 0110) in a DM, a channel
// and a topic reply, and a post shows its seat within 5 s. An empty value
// shows nothing: no element, no placeholder, and the header keeps its height.
//
// Against the mock bundle: three rows are added through the mock's test hook
// (localStorage spool.mock.extra-messages), each with a seat; the live post is
// a DM sent to GRK-03@box-a through the channel store, as the composer does,
// and the mock stamps <to>@<to_box> as the hub's insert does. CONTROL: the
// #lobby welcome (HUM-1 to the room) has no seat and so no badge, and the same
// post with and without a seat has the same header height. 1440x900 and 390x844.
//
// Run:
//   pnpm run test:e2e responsible-seat
//   BASE_URL=<generated bundle> pnpm run test:e2e responsible-seat     # what CI does
//   SHOT_DIR=/tmp/shots ...                                             # keep the screenshots
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const LIVE_MS = 5000
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const WELCOME = '11111111-1111-4111-8111-111111111111'
const CHANNEL_ROW = 'e0680001-0000-4000-8000-000000000001'
const REPLY_ROW = 'e0680001-0000-4000-8000-000000000002'
const DM_ROW = 'e0680001-0000-4000-8000-000000000003'
const BARE_ROW = 'e0680001-0000-4000-8000-000000000004'
const DM_PEER = 'GRK-03@box-a'
const EXTRA = [
  { v: 1, msg_id: CHANNEL_ROW, task_id: 'e0680002-0000-4000-8000-000000000001', ts: '2026-09-18T10:08:00Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'c-002', to_box: 'box-a', kind: 'note', body: 'channel post to one agent',
    files: [], channel: 'lobby', parent_task_id: null, responsible: 'c-002@box-a' },
  { v: 1, msg_id: REPLY_ROW, task_id: 'e0680002-0000-4000-8000-000000000002', ts: '2026-09-18T10:09:00Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'CLE-07', to_box: 'box-a', kind: 'note', body: 'topic reply to one agent',
    files: [], channel: 'lobby', parent_task_id: TOPIC, is_parent: 0, responsible: 'CLE-07@box-a' },
  { v: 1, msg_id: DM_ROW, task_id: 'e0680002-0000-4000-8000-000000000003', ts: '2026-09-18T10:10:00Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'GRK-03', to_box: 'box-a', kind: 'note', body: 'dm to one agent',
    files: [], channel: null, parent_task_id: null, responsible: 'GRK-03@box-a' },
  /* the channel post again with no seat yet (the ODs have not run): the header must not move */
  { v: 1, msg_id: BARE_ROW, task_id: 'e0680002-0000-4000-8000-000000000004', ts: '2026-09-18T10:07:30Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'c-002', to_box: 'box-a', kind: 'note', body: 'channel post, no seat yet',
    files: [], channel: 'lobby', parent_task_id: null },
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

/** One card: its seat badge (text, data, tooltip, shown) and its header height. */
function seatOf(page, sel) {
  return page.evaluate((s) => {
    const row = document.querySelector(s)
    if (!row) return null
    const b = row.querySelector('[data-testid=msg-responsible]')
    const r = b ? b.getBoundingClientRect() : null
    const meta = row.querySelector('.msg-meta')
    return {
      seat: b ? b.getAttribute('data-responsible') : null,
      text: b ? b.textContent.trim() : null,
      title: b ? b.getAttribute('title') : null,
      shown: Boolean(r && r.width > 0 && r.height > 0),
      metaH: meta ? Math.round(meta.getBoundingClientRect().height) : null,
    }
  }, sel)
}
const card = (id) => `article.msg[data-msg-id="${id}"]`
const shows = (f, seat) => Boolean(f) && f.seat === seat && f.text.endsWith(seat) && f.title === `Responsible: ${seat}` && f.shown

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
    const open = async (path, id) => {
      await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(card(id), { timeout: NAV_TIMEOUT })
    }
    const shot = async (name) => {
      if (!process.env.SHOT_DIR) return
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, `responsible-seat-${tag}-${name}.png`) })
    }

    /* channel: the post names its seat; the welcome (nobody) shows nothing */
    await open('/lobby', CHANNEL_ROW)
    const ch = await seatOf(p, card(CHANNEL_ROW))
    const none = await seatOf(p, card(WELCOME))
    const bare = await seatOf(p, card(BARE_ROW))
    ok(`${tag} channel: the post shows its seat c-002@box-a`, shows(ch, 'c-002@box-a'), ch)
    ok(`${tag} CONTROL channel: a post to the room has no badge`, Boolean(none) && none.seat === null && none.text === null, none)
    ok(`${tag} CONTROL channel: the same post with no seat yet has no badge`, Boolean(bare) && bare.seat === null && bare.text === null, bare)
    ok(`${tag} channel: the seat does not change the header height`, Boolean(ch && bare) && ch.metaH === bare.metaH, { with: ch?.metaH, without: bare?.metaH })
    await shot('channel')

    /* topic reply */
    await open(`/t/${TOPIC}`, REPLY_ROW)
    const rep = await seatOf(p, card(REPLY_ROW))
    ok(`${tag} topic reply: shows its seat CLE-07@box-a`, shows(rep, 'CLE-07@box-a'), rep)
    await shot('topic')

    /* DM, then a live post in it: the seat within 5 s */
    await open(`/dm/${DM_PEER}`, DM_ROW)
    const dm = await seatOf(p, card(DM_ROW))
    ok(`${tag} DM: shows its seat GRK-03@box-a`, shows(dm, 'GRK-03@box-a'), dm)
    const body = `seat ${tag} ${Date.now().toString(36)}`
    const t0 = Date.now()
    const sent = await p.evaluate(async (text) => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      const chStore = pinia?._s.get('channel')
      if (!chStore) return null
      const row = await chStore.send(text)
      return row ? { msg_id: row.msg_id, responsible: row.responsible || '' } : null
    }, body)
    const live = sent?.msg_id
      ? await p.waitForFunction((s) => document.querySelector(s)?.querySelector('[data-testid=msg-responsible]')?.getAttribute('data-responsible') || null,
        { timeout: LIVE_MS }, card(sent.msg_id)).then((h) => h.jsonValue()).catch(() => null)
      : null
    const ms = Date.now() - t0
    ok(`${tag} live: a DM post shows its seat GRK-03@box-a within ${LIVE_MS} ms`, live === 'GRK-03@box-a' && ms <= LIVE_MS, { sent, live, ms })
    await shot('dm')

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
