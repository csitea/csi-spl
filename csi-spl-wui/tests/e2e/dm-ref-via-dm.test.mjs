// Spec 067 L7 (rules 3 and 4), proved in a REAL browser at 1440x900 and
// 390x844: a DM that carries `ref_task_id` is headed "about #channel / topic",
// linked to that topic, and a channel reply with `mirror_of` (the copy of a
// person's DM answer) shows a "via DM" marker. Markers only: the header line
// is the moved line's style, the marker the typist's.
//
// Against the mock bundle: two rows are added through the mock's test hook
// (localStorage spool.mock.extra-messages). CONTROLS: the mock DM without a
// ref has no header, and a topic reply without mirror_of has no marker.
//
// Run:
//   pnpm run test:e2e dm-ref-via-dm
//   BASE_URL=<generated bundle> pnpm run test:e2e dm-ref-via-dm     # what CI does
//   SHOT_DIR=/tmp/shots ...                                          # keep the screenshots
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
const PLAIN_REPLY = '33333333-3333-4333-8333-333333333333'
const REF_DM = 'e0670007-0000-4000-8000-000000000001'
const MIRROR = 'e0670007-0000-4000-8000-000000000002'
const DM_PEER = 'GRK-03@box-a'
const EXTRA = [
  { v: 1, msg_id: REF_DM, task_id: 'e0670008-0000-4000-8000-000000000001', ts: '2026-09-18T10:08:00Z',
    from: 'GRK-03', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', kind: 'note', body: 'a question about the scaffold topic',
    files: [], channel: null, parent_task_id: null, ref_task_id: TOPIC },
  { v: 1, msg_id: MIRROR, task_id: TOPIC, ts: '2026-09-18T10:09:00Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'GRK-03', to_box: 'box-a', kind: 'note', body: 'my DM answer, seen in the channel',
    files: [], channel: 'lobby', parent_task_id: TOPIC, is_parent: 0, mirror_of: 'e0670009-0000-4000-8000-000000000001' },
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

/** One card's spec 067 markers: the DM-ref line and the via-DM badge. */
function markersOf(page, id) {
  return page.evaluate((sel) => {
    const row = document.querySelector(sel)
    if (!row) return null
    const shown = (el) => { const r = el ? el.getBoundingClientRect() : null; return Boolean(r && r.width > 0 && r.height > 0) }
    const ref = row.querySelector('[data-testid=msg-dm-ref]')
    const link = ref ? ref.querySelector('a') : null
    const via = row.querySelector('[data-testid=msg-via-dm]')
    return {
      ref: ref ? ref.getAttribute('data-ref-task-id') : null,
      refText: ref ? ref.textContent.trim() : null,
      href: link ? link.getAttribute('href') : null,
      tip: link ? link.getAttribute('title') : null,
      refShown: shown(ref),
      via: via ? via.getAttribute('data-mirror-of') : null,
      viaText: via ? via.textContent.trim() : null,
      viaShown: shown(via),
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
    const open = async (path, id) => {
      await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(card(id), { timeout: NAV_TIMEOUT })
    }
    const shot = async (name) => {
      if (!process.env.SHOT_DIR) return
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, `dm-ref-via-dm-${tag}-${name}.png`) })
    }

    /* rule 3: the DM is headed by its topic, linked to it */
    await open(`/dm/${DM_PEER}`, REF_DM)
    await p.waitForSelector(`${card(REF_DM)} [data-testid=msg-dm-ref]`, { timeout: NAV_TIMEOUT }).catch(() => {})
    const dm = await markersOf(p, REF_DM)
    /* a title over 48 characters is cut like the moved line's; the link's title holds it whole */
    const want = `about #lobby / ${TOPIC_TITLE.slice(0, 47)}…`
    ok(`${tag} DM: headed "${want}"`, Boolean(dm) && dm.ref === TOPIC && dm.refText === want && dm.refShown, dm)
    ok(`${tag} DM: the full title is on hover`, Boolean(dm) && dm.tip === `about #lobby / ${TOPIC_TITLE}`, dm?.tip)
    ok(`${tag} DM: the header links to the topic`, Boolean(dm && dm.href) && dm.href.endsWith(`/t/${TOPIC}`), dm?.href)
    const plain = await markersOf(p, PLAIN_DM)
    ok(`${tag} CONTROL DM: a DM without ref_task_id has no header`, Boolean(plain) && plain.ref === null && plain.refText === null, plain)
    await shot('dm')
    await p.click(`${card(REF_DM)} [data-testid=msg-dm-ref] a`)
    const went = await p.waitForFunction((t) => location.pathname.endsWith(`/t/${t}`), { timeout: NAV_TIMEOUT }, TOPIC)
      .then(() => true).catch(() => false)
    ok(`${tag} DM: the header link opens the topic`, went, await p.evaluate(() => location.pathname))

    /* rule 4: the channel copy of a person's DM answer says "via DM" */
    await open(`/t/${TOPIC}`, MIRROR)
    const mir = await markersOf(p, MIRROR)
    ok(`${tag} topic: the mirror_of reply shows "via DM"`, Boolean(mir) && mir.via === EXTRA[1].mirror_of && mir.viaText === 'via DM' && mir.viaShown, mir)
    const bare = await markersOf(p, PLAIN_REPLY)
    ok(`${tag} CONTROL topic: a reply without mirror_of has no marker`, Boolean(bare) && bare.via === null && bare.ref === null, bare)
    await shot('topic')

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
