// Phone thread end-jump (owner topic 639b04df). A long reply thread on a
// phone shows one round arrow: at the newest end it points at the oldest
// end, and away from the newest end it points back. Newest-last mirrors the
// direction. A short thread and a desktop width show nothing.
//
//   node tests/e2e/thread-jump.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/thread-jump.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const PHONE = { name: '390', width: 390, height: 844, isMobile: true, hasTouch: true }
const DESKTOP = { name: '1440', width: 1440, height: 900, isMobile: false, hasTouch: false }

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

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({
        hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
      }))
    } catch { /* first document */ }
  })

  const load = async (vp) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await sleep(300)
    /* a second viewport apply can reload the document; wait until it is back */
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(400)
  }

  /* n rows in one topic, then open that topic. body length decides the height. */
  const seed = async (n, body) => {
    let last
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        return await p.evaluate((n, body, task) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const topic = pinia._s.get('topic')
    const rows = []
    for (let i = 0; i < n; i++) {
      const ts = new Date(Date.UTC(2026, 0, 1, 0, 0, i)).toISOString()
      rows.push({
        v: 1, msg_id: `jump-${i}`, task_id: task, parent_task_id: task, ts, received_at: ts,
        from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body, files: [],
      })
    }
    channel.messages = rows
    topic.openTopic(task)
    return n
  }, n, body, TASK)
      } catch (e) {
        last = e
        if (!/context was destroyed|Execution context|navigat/i.test(String(e)) || attempt === 2) throw e
        await sleep(600)
        await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT }).catch(() => {})
      }
    }
    throw last
  }

  const readJump = () => p.evaluate(() => {
    const b = document.querySelector('[data-test=topic-section] [data-testid=thread-jump]')
    const s = document.querySelector('[data-test=topic-section] .feed-body')
    const shell = document.querySelector('.spool-shell')
    if (!s) return { missing: 'scroller', level: shell && shell.getAttribute('data-mobile-level') }
    const r = b ? b.getBoundingClientRect() : null
    const cs = b ? getComputedStyle(b) : null
    const hit = r ? document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) : null
    return {
      n: document.querySelectorAll('[data-testid=thread-jump]').length,
      end: b ? b.getAttribute('data-end') : '',
      dir: b ? b.getAttribute('data-dir') : '',
      label: b ? b.getAttribute('aria-label') : '',
      top: s.scrollTop,
      overflow: s.scrollHeight - s.clientHeight,
      level: shell && shell.getAttribute('data-mobile-level'),
      round: cs ? cs.borderRadius : '',
      fixed: cs ? cs.position : '',
      w: r ? Math.round(r.width) : 0,
      hit: Boolean(b && hit && (hit === b || b.contains(hit))),
    }
  })

  const waitJump = (pred, ms = 4000) => p.waitForFunction(pred, { timeout: ms }).catch(() => null)

  await load(PHONE)
  await seed(1, 'hi')
  await sleep(500)
  let st = await readJump()
  ok('phone short thread: no arrow', st.n === 0 && st.level === '3' && st.overflow <= 80, st)

  await seed(24, 'a long reply line\nsecond line\nthird line\nfourth line')
  const shown = await waitJump(() => {
    const b = document.querySelector('[data-testid=thread-jump]')
    return b && b.getAttribute('data-end') === 'oldest' && b.getAttribute('data-dir') === 'down'
  })
  st = await readJump()
  ok('phone, newest first, at the top: arrow down to the oldest end, round and hittable',
    Boolean(shown) && st.end === 'oldest' && st.dir === 'down' && st.fixed === 'fixed' && st.w >= 44 && st.hit && st.overflow > 80
      && st.label === 'Jump to the oldest messages', st)

  await p.evaluate(() => { document.querySelector('[data-test=topic-section] .feed-body').scrollTop = 900 })
  const away = await waitJump(() => {
    const b = document.querySelector('[data-testid=thread-jump]')
    return b && b.getAttribute('data-end') === 'newest' && b.getAttribute('data-dir') === 'up'
  })
  st = await readJump()
  ok('scrolled away from the newest end: arrow up, back to it',
    Boolean(away) && st.end === 'newest' && st.dir === 'up' && st.label === 'Jump to the newest messages', st)

  await p.click('[data-testid=thread-jump]')
  const back = await waitJump(() => {
    const s = document.querySelector('[data-test=topic-section] .feed-body')
    const b = document.querySelector('[data-testid=thread-jump]')
    return s && s.scrollTop <= 80 && b && b.getAttribute('data-end') === 'oldest'
  })
  st = await readJump()
  ok('tap scrolls smoothly to the newest end and the arrow flips',
    Boolean(back) && st.top <= 80 && st.end === 'oldest' && st.dir === 'down', st)

  /* Changing the emulated phone flag reloads the document, so the thread is
     opened again after the viewport has settled. */
  const longBody = 'a long reply line\nsecond line\nthird line\nfourth line'
  await applyViewport(p, DESKTOP)
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await sleep(500)
  await seed(24, longBody)
  await sleep(700)
  st = await readJump()
  ok('desktop width: a long open thread has no arrow', st.n === 0 && st.overflow > 80, st)

  await applyViewport(p, PHONE)
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await sleep(500)
  await seed(24, longBody)
  await p.waitForFunction(() => document.querySelector('#__nuxt')?.__vue_app__, { timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    pinia._s.get('session').setViewPref('message_order', 'newest-last')
  })
  const last = await waitJump(() => {
    const b = document.querySelector('[data-testid=thread-jump]')
    const s = document.querySelector('[data-test=topic-section] .feed-body')
    if (!b || !s) return false
    const fromBottom = s.scrollHeight - s.scrollTop - s.clientHeight
    return fromBottom <= 80 && b.getAttribute('data-end') === 'oldest' && b.getAttribute('data-dir') === 'up'
  })
  st = await readJump()
  ok('newest last, at the bottom: arrow up to the oldest end',
    Boolean(last) && st.end === 'oldest' && st.dir === 'up', st)

  await p.evaluate(() => { document.querySelector('[data-test=topic-section] .feed-body').scrollTop = 0 })
  const up = await waitJump(() => {
    const b = document.querySelector('[data-testid=thread-jump]')
    return b && b.getAttribute('data-end') === 'newest' && b.getAttribute('data-dir') === 'down'
  })
  st = await readJump()
  ok('newest last, scrolled to the top: arrow down to the newest end',
    Boolean(up) && st.end === 'newest' && st.dir === 'down' && st.top <= 2, st)

  ok('no page error', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}
console.log(fails.length ? `\n${fails.length} failed` : '\nthread-jump e2e passed')
process.exit(fails.length ? 1 : 0)
