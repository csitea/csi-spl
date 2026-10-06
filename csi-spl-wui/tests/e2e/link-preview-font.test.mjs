// t1 b58ce5fe (owner, c2f470d8): "ALL of the fonts in the 3rd panel are
// smaller, which is wrong - only the fonts of the preview from links should be
// smaller"; earlier: "the regular font on the preview could be 20% smaller
// than the regular fonts".
//
// Computed sizes on the bundle at 1440 (the middle panel and the open topic
// pane both on screen), at the default font level (3: 18px root) and at
// level 5 (22px root):
//   - a message body in the open topic pane equals one in the middle panel,
//     0.875rem (15.75px at the default root): the pane is never shrunk
//   - a message author in the pane equals one in the middle panel
//   - every link preview card's title and excerpt, in either panel, is 0.8 of
//     that body (12.6px at the default root)
//
// Run: node tests/e2e/link-preview-font.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PEER = 'CLE-07@box-a'
const FAR_TOPIC = 'fb000000-0000-4000-8000-00000000000a'
const DM_TASK = 'fe000000-0000-4000-8000-00000000000d'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const near = (a, b) => Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) < 0.05

const base = { v: 1, files: [], kind: 'note', is_parent: 1, parent_task_id: null }
const extra = [
  { ...base, msg_id: 'fb100000-0000-4000-8000-00000000000a', task_id: FAR_TOPIC, channel: 'feedback', from: 'HUM-2', from_box: 'box-wui', to: '@channel', to_box: 'box-wui', body: 'Release plan for the link previews\nstep one: the hub\nstep two: the cards', ts: '2026-09-10T08:00:00Z' },
  { ...base, msg_id: 'fe100000-0000-4000-8000-00000000000d', task_id: DM_TASK, channel: null, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body: `the plan is [here](/t/${FAR_TOPIC})`, ts: '2026-12-31T23:59:00Z' },
]

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

/* computed px: the first match inside the open topic pane (.topic) and outside it */
const measure = (p) => p.evaluate(() => {
  const px = (el) => (el ? parseFloat(getComputedStyle(el).fontSize) : NaN)
  const inPane = (el) => !!el.closest('.topic')
  const first = (sel, pane) => [...document.querySelectorAll(sel)].find((el) => inPane(el) === pane) || null
  return {
    root: parseFloat(getComputedStyle(document.documentElement).fontSize),
    paneBody: px(first('.msg-body', true)),
    middleBody: px(first('.msg-body', false)),
    paneAuthor: px(first('.msg-author', true)),
    middleAuthor: px(first('.msg-author', false)),
    paneTitle: px(document.querySelector('.topic .topic-heading__title')),
    cards: [...document.querySelectorAll('[data-test=link-preview]')].map((c) => ({
      pane: inPane(c),
      title: px(c.querySelector('[data-test=link-preview-title]')),
      excerpt: px(c.querySelector('[data-test=link-preview-excerpt]')),
    })),
  }
})

async function sizesAt(browser, srvBase, level) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.evaluateOnNewDocument((rows, lvl) => {
    try {
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
      localStorage.setItem('spool.mock.session', JSON.stringify({
        hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
      }))
      if (lvl) localStorage.setItem('spool-font-size', String(lvl))
    } catch { /* private mode */ }
  }, extra, level)
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(`${srvBase}/dm/${encodeURIComponent(PEER)}?topic=${DM_TASK}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) throw new Error('no shell: ' + p.url())
  const start = Date.now()
  let m
  while (Date.now() - start < 20000) {
    m = await measure(p).catch(() => m)
    if (m && m.cards.some((c) => c.pane) && m.cards.some((c) => !c.pane)
      && Number.isFinite(m.paneBody) && Number.isFinite(m.middleBody)) break
    await sleep(200)
  }
  await p.close()
  return m
}

const srv = await startServer()
const browser = await launch()
try {
  for (const [label, level, root] of [['default level', null, 18], ['level 5', 5, 22]]) {
    const m = await sizesAt(browser, srv.base, level)
    console.log(`  ${label} px: ${JSON.stringify(m)}`)
    const body = root * 0.875
    ok(`${label}: the root is ${root}px`, !!m && near(m.root, root), m && m.root)
    ok(`${label}: a middle panel message body is 0.875rem (${body}px)`, !!m && near(m.middleBody, body), m && m.middleBody)
    ok(`${label}: an open topic pane message body equals the middle panel's`, !!m && near(m.paneBody, m.middleBody), m && [m.paneBody, m.middleBody])
    ok(`${label}: an open topic pane message author equals the middle panel's`, !!m && near(m.paneAuthor, m.middleAuthor), m && [m.paneAuthor, m.middleAuthor])
    ok(`${label}: link preview cards show in both panels`, !!m && m.cards.some((c) => c.pane) && m.cards.some((c) => !c.pane), m && m.cards)
    ok(`${label}: every card title and excerpt is 0.8 of the body (${+(body * 0.8).toFixed(3)}px)`,
      !!m && m.cards.length > 0 && m.cards.every((c) => near(c.title, body * 0.8) && near(c.excerpt, body * 0.8)), m && m.cards)
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nlink-preview-font: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log('FAILED:', failed.map((f) => f.name).join('; '))
  process.exit(1)
}
