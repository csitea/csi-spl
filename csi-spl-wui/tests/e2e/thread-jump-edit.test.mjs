// SPL-5315 (owner, t1 ce99fef5): "The \"Scroll to the bottom\" or \"Scroll to
// the top\" button is obsolete in editing mode of a message because it gets
// in the way of the save button." The phone thread arrow (thread-jump.test)
// hides while a message in that thread is open for editing, and comes back
// when the edit ends, by Cancel or by Save.
//
//   node tests/e2e/thread-jump-edit.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/thread-jump-edit.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* a topic of the mock tenant (utils/mock-data.mjs) */
const TOPIC = '11111111-1111-4111-8111-111111111111'
const PHONE = { name: '390', width: 390, height: 844, isMobile: true, hasTouch: true }
const N = 24
/* the newest row is the viewer's own, so it is at the top and may be edited */
const MINE = `jump-edit-${N - 1}`
const ROW = `[data-test=topic-section] article.msg[data-msg-id="${MINE}"]`
const BOX = `${ROW} [data-test=msg-edit-box]`
const SAVE = `${ROW} [data-test=msg-edit-save]`
const CANCEL = `${ROW} [data-test=msg-edit-cancel]`

const fails = []
const ok = (name, pass, ev) => {
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) fails.push(name)
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* N replies in a mock topic, the newest the viewer's own. They ride the
   mock's extra-messages hook, so its 4 s refresh keeps them (a row set on
   the channel store is replaced by that refresh, and the open editor with it). */
function replies(n, topic, mine) {
  const rows = []
  for (let i = 0; i < n; i++) {
    const id = `jump-edit-${i}`
    const ts = new Date(Date.UTC(2026, 10, 1, 0, 0, i)).toISOString()
    rows.push({
      v: 1, msg_id: id, task_id: id, parent_task_id: topic, is_parent: 0, ts,
      from: id === mine ? 'HUM-1' : 'HUM-7', from_box: 'box-wui', to: '@channel', to_box: 'box-wui',
      kind: 'note', channel: 'lobby', body: 'a long reply line\nsecond line\nthird line\nfourth line', files: [],
    })
  }
  return rows
}

/* the arrow, the Save button and whether the arrow sits on Save */
function readState(ROW, SAVE) {
  const b = document.querySelector('[data-test=topic-section] [data-testid=thread-jump]')
  const save = document.querySelector(SAVE)
  const box = document.querySelector(`${ROW} [data-test=msg-edit-box]`)
  const r = b ? b.getBoundingClientRect() : null
  const sr = save ? save.getBoundingClientRect() : null
  const overlap = Boolean(r && sr && r.left < sr.right && sr.left < r.right && r.top < sr.bottom && sr.top < r.bottom)
  return {
    jump: document.querySelectorAll('[data-testid=thread-jump]').length,
    end: b ? b.getAttribute('data-end') : '',
    editing: Boolean(box),
    body: (document.querySelector(`${ROW} .msg-body`)?.textContent || '').trim().slice(0, 40),
    overlap,
  }
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument((rows) => {
    try {
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
      localStorage.setItem('spool.mock.session', JSON.stringify({
        hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
      }))
    } catch { /* first document */ }
  }, replies(N, TOPIC, MINE))
  await setPageViewport(p, PHONE)
  await p.goto(`${server.base}/channel/lobby?topic=${TOPIC}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, PHONE)
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await sleep(300)
  /* a second viewport apply can reload the document; wait until it is back */
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  await sleep(400)
  await p.waitForSelector(ROW, { timeout: NAV_TIMEOUT })

  const read = () => p.evaluate(readState, ROW, SAVE)
  const until = async (want, ms = 4000) => {
    const t0 = Date.now()
    let v = await read()
    while (!want(v) && Date.now() - t0 < ms) { await sleep(100); v = await read() }
    return v
  }
  const openEditor = async () => {
    await p.evaluate((ROW) => document.querySelector(ROW)?.focus(), ROW)
    await p.keyboard.press('e')
    await p.waitForSelector(BOX, { timeout: 5000 })
  }

  let st = await until((v) => v.jump === 1)
  ok('390 px long thread: the arrow is shown before any edit', st.jump === 1 && !st.editing, st)

  await openEditor()
  st = await until((v) => v.editing && v.jump === 0)
  ok('a message open for editing hides the arrow (it no longer covers Save)', st.editing && st.jump === 0 && !st.overlap, st)

  await p.click(CANCEL)
  st = await until((v) => !v.editing && v.jump === 1)
  ok('Cancel ends the edit and the arrow returns', !st.editing && st.jump === 1, st)

  await openEditor()
  st = await until((v) => v.editing && v.jump === 0)
  ok('editing again hides it again', st.editing && st.jump === 0, st)
  await p.focus(BOX)
  await p.keyboard.type(' edited')
  await p.click(SAVE)
  st = await until((v) => !v.editing && v.jump === 1, 6000)
  ok('Save ends the edit and the arrow returns', !st.editing && st.jump === 1, st)

  ok('no page error', errors.length === 0, errors.slice(0, 3))
} catch (e) {
  ok('the proof ran to the end', false, String(e).slice(0, 300))
} finally {
  await browser.close()
  await server.stop()
}
console.log(fails.length ? `\n${fails.length} failed` : '\nthread-jump-edit e2e passed')
process.exit(fails.length ? 1 : 0)
