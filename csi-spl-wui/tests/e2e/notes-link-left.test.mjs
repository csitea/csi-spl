// Spec 155 row B7 (SPL-4330) D4, SPL-4433: a note link into a workspace the
// person left, on the mock bundle.
//
// NoteLinks.vue renders a link whose `left` is true with no anchor and the
// text "Link to a workspace you left" (notes.link_left), its row marked
// data-left="true". The mock notes hold no left link, so the test adds one to
// the note the store's get() answers (an `after` hook on that action, before
// NoteDetail reads it): mock-note-2 then has its url link, a topic link
// with left: true and the same topic link without it. Both topic links name
// this page's workspace (t1): on the mock no other workspace has a host, so a
// link into one opens nothing with or without `left`, and the test could not
// tell the two apart. The twin without `left` proves the link would open.
//
// Cases, at 1440 px and at 390 px:
//   the left row: data-left="true", no <a> in it, the localized "left" text
//   the normal rows: data-left="false", the url row's <a> to
//   https://example.com/1, the twin topic row's <a> to /t/<uuid>
//
// Run:
//   node tests/e2e/notes-link-left.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/notes-link-left.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const LEFT_TEXT = 'Link to a workspace you left'
const TOPIC = '0b7f2c3e-1d2a-4b5c-8d9e-0f1a2b3c4d5e'

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

/* the note get() answers for mock-note-2 gains a link into a left workspace */
const plantLeftLink = (p) => p.evaluate((topic) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  store.$onAction(({ name, args, after }) => {
    if (name !== 'get' || args[0] !== 'mock-note-2') return
    after((got) => {
      const link = { kind: 'topic', workspace_id: 't1', ref: topic, label: '' }
      if (got?.note) got.note.links = [...got.note.links, { ...link, id: 'mock-link-left', left: true }, { ...link, id: 'mock-link-twin', left: false }]
    })
  })
}, TOPIC)

const linkRows = (p) => p.$$eval('[data-test=note-link]', (els) => els.map((e) => {
  const a = e.querySelector('a')
  const text = e.querySelector('[data-test=note-link-open], [data-test=note-link-text]')
  return { kind: e.dataset.kind, left: e.dataset.left, anchors: e.querySelectorAll('a').length, href: a?.getAttribute('href') || '', text: (text?.textContent || '').trim() }
}))

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await browser.newPage()
  await p.setViewport({ width, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  await plantLeftLink(p)
  await p.click('[data-note-id="mock-note-2"] [data-test=notes-open]')
  await p.waitForSelector('[data-test=note-detail][data-note-id="mock-note-2"][data-state=ready]', { visible: true, timeout: 15000 })
  await p.waitForSelector('[data-test=note-link][data-left="true"]', { timeout: 5000 }).catch(() => {})
  const got = await linkRows(p)
  check(`${tag}: the note shows its 3 links`, got.length === 3, got.length)
  const [normal, left, twin] = got
  check(`${tag}: the normal row is not marked left`, normal?.left === 'false', normal)
  check(`${tag}: the normal row keeps its anchor`, normal?.anchors === 1 && normal.href === 'https://example.com/1' && normal.text === 'https://example.com/1', normal)
  check(`${tag}: the left row has data-left="true"`, left?.kind === 'topic' && left.left === 'true', left)
  check(`${tag}: the left row has no <a>`, left?.anchors === 0, left)
  check(`${tag}: the left row reads "${LEFT_TEXT}"`, left?.text === LEFT_TEXT, left)
  check(`${tag}: the same link without left opens /t/<uuid>`, twin?.left === 'false' && twin.anchors === 1 && twin.href.endsWith(`/t/${TOPIC}`) && twin.text === TOPIC.slice(0, 8), twin)
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base, 1440, false)
  await run(browser, server.base, 390, true)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-link-left: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
