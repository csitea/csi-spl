// SPL-1133 (owner, prd t1 topic 9e0379a6): "a User Setting to put the X's for
// closing the modal dialogs etc. either Windows style, i.e. top right, or Mac
// style, i.e. top left" - then "use the Mac style as the default". In a real
// browser, mock tenant; the hub's GET /session and PUT preferences are
// answered here from one stored value, so a reload proves the pref survives:
//   D   control, never picked: <html data-close-buttons="mac">, the dialog X
//       and the thread pane X sit before their titles (top left), 1440
//   S   Settings -> Behaviour "Windows style" sends {"close_buttons":"windows"}
//   W   after a reload the claim is still windows: every X after its title
//       (top right) at 1440, the phone sheet's X right of its heading at 390
//   K   keyboard: the X is in the DOM where it is drawn (first Tab stop in
//       Mac, last in Windows) and closing gives focus back to the opener
//   P   phone 390: the full-screen dialog keeps Back at the top left and
//       shows no X, in both modes
//   M   back to Mac style: the sheet X is left of its heading again
//   R   a non-card dialog closing by `open` (the issue delete confirm) is
//       gone one macrotask after Cancel - no transition frames
//       (issues-crud-modal D1 read it once, CI 36451966904)
//
//   node tests/e2e/close-buttons.test.mjs
//   BASE_URL=<generated bundle> OUT=/tmp/shots node tests/e2e/close-buttons.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const PHONE = { name: '390', width: 390, height: 844 }

/* the one stored value the fake hub keeps (undefined = never picked) */
let stored
const puts = []

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // specs/054: the mock is signed-OUT by default and its GET /session no longer
  // rides the network (auth-client.mjs), so the `session` stub below only serves
  // a real BASE_URL. In the mock bundle we opt into a signed-in owner through
  // localStorage; the stored close_buttons rides a control key so a reload's
  // probe reads the persisted pref (load() keeps it in sync with `stored`).
  await p.evaluateOnNewDocument(() => {
    try {
      const cb = localStorage.getItem('spool.mock.close_buttons')
      localStorage.setItem('spool.mock.session', JSON.stringify({
        hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
        close_buttons: cb === null || cb === 'null' ? null : cb,
      }))
    } catch { /* opaque origin on the very first document */ }
  })
  const cors = { 'access-control-allow-origin': new URL(server.base).origin, 'access-control-allow-credentials': 'true' }
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const u = req.url()
    if (req.method() === 'PUT' && u.includes('/api/v1/auth/preferences')) {
      const body = JSON.parse(req.postData() || '{}')
      puts.push(body)
      if ('close_buttons' in body) stored = body.close_buttons
      return req.respond({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(body) })
    }
    if (req.method() === 'GET' && u.includes('/api/v1/auth/session')) {
      const claims = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', close_buttons: stored ?? null }
      return req.respond({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(claims) })
    }
    return req.continue()
  })

  const load = async (vp, path) => {
    await setPageViewport(p, vp)
    // keep the opt-in mock session's close_buttons in step with the fake hub's
    // stored value, so the next document's probe reads the persisted pref
    // (same-origin localStorage survives the navigation; no-ops on about:blank).
    await p.evaluate((cb) => localStorage.setItem('spool.mock.close_buttons', cb === null ? 'null' : cb), stored ?? null).catch(() => {})
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(600)
  }
  const rootMode = () => p.evaluate(() => document.documentElement.getAttribute('data-close-buttons'))
  const shot = (name) => (OUT ? p.screenshot({ path: `${OUT}/close-buttons-${name}.png` }) : null)

  /* where one header's X sits against its title, and in which Tab order */
  const geometry = (head, title, x) => p.evaluate((head, title, x) => {
    const h = document.querySelector(head)
    const xs = h ? [...h.querySelectorAll(x)] : []
    const tEl = h?.querySelector(title)
    if (!h || !tEl || xs.length !== 1) return { found: false, xs: xs.length }
    const hr = h.getBoundingClientRect()
    const xr = xs[0].getBoundingClientRect()
    const tr = tEl.getBoundingClientRect()
    const visible = xr.width > 0 && getComputedStyle(xs[0]).display !== 'none'
    return {
      found: true,
      visible,
      side: xs[0].getAttribute('data-close-side'),
      /* the X's centre in the left or the right half of its header */
      left: xr.left + xr.width / 2 < hr.left + hr.width / 2,
      beforeTitle: xr.right <= tr.left + 1,
      afterTitle: xr.left >= tr.right - 1,
      /* document order = Tab order */
      domFirst: Boolean(xs[0].compareDocumentPosition(tEl) & Node.DOCUMENT_POSITION_FOLLOWING),
    }
  }, head, title, x)

  const openLogo = async () => {
    await p.click('[data-test=top-bar-logo]')
    await p.waitForSelector('[data-testid=ui-dialog]', { visible: true, timeout: 5000 })
    await sleep(300)
  }
  const closeDialogByX = async () => {
    await p.click('[data-testid=ui-dialog-close]')
    await p.waitForFunction(() => !document.querySelector('[data-testid=ui-dialog]'), { timeout: 5000 })
    await sleep(200)
    return p.evaluate(() => document.activeElement?.getAttribute('data-test'))
  }
  const firstTabStop = () => p.evaluate(() => {
    const panel = document.querySelector('[data-testid=ui-dialog]')
    const sel = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'
    const all = [...panel.querySelectorAll(sel)].filter((el) => el.offsetParent !== null)
    /* the header row's own Tab stops: the X leads it (Mac) or ends it (Windows);
       the body's controls (links, buttons) always come after the header */
    const head = [...panel.querySelector('.ui-dialog__head').querySelectorAll(sel)].filter((el) => el.offsetParent !== null)
    return { first: all[0]?.getAttribute('data-testid'), headLast: head[head.length - 1]?.getAttribute('data-testid') }
  })
  const openThread = async () => {
    const r = await p.evaluate((id) => {
      const topic = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')
      if (!topic) return 'no-store'
      topic.openTopic(id)
      return 'ok'
    }, TASK)
    await p.waitForSelector('[data-test=topic-section] header', { visible: true, timeout: 5000 }).catch(() => {})
    await sleep(500)
    return r
  }
  const DIALOG = ['[data-testid=ui-dialog] .ui-dialog__head', '.ui-dialog__title', '[data-testid=ui-dialog-close]']
  const THREAD = ['[data-test=topic-section] header', '[data-test=topic-heading]', '[data-test=topic-pane-close]']
  const SHEET = ['[data-test=issues-filter-sheet] .issues-sheet__h', 'h3', '[data-test=issues-filter-sheet-close]']

  /* D: never picked = Mac style */
  await load(DESKTOP, '/channel/lobby')
  ok('D0 never picked: <html data-close-buttons="mac">', (await rootMode()) === 'mac', await rootMode())
  await openLogo()
  let g = await geometry(...DIALOG)
  ok('D1 1440 dialog: the X is top left, before the title', g.found && g.visible && g.left && g.beforeTitle && g.side === 'start', g)
  ok('K1 Mac: the X is the dialog\'s first Tab stop', (await firstTabStop()).first === 'ui-dialog-close', await firstTabStop())
  await shot('1440-mac-dialog')
  ok('K2 Mac: closing by the X gives focus back to the opener', (await closeDialogByX()) === 'top-bar-logo')
  ok('D2 open thread pane', (await openThread()) === 'ok')
  g = await geometry(...THREAD)
  ok('D3 1440 thread pane: the X is top left, before the title', g.found && g.visible && g.left && g.beforeTitle, g)
  await shot('1440-mac-thread')

  /* R: close timing. The issue delete confirm stays mounted and closes by
     `open` going false - the Transition leave path. Click Cancel in the page
     and look one macrotask later, before any animation frame can run. */
  await load(DESKTOP, '/issues')
  await p.waitForSelector('[data-test=issues-new]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', 'close timing row')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: 5000 })
  await p.hover('[data-test=issues-row]')
  await p.click('[data-test=issues-row] [data-test=issues-row-delete]')
  await p.waitForSelector('[data-testid=issues-delete-cancel]', { visible: true, timeout: 5000 })
  await sleep(300)
  const confirmStill = await p.evaluate(() => new Promise((resolve) => {
    document.querySelector('[data-testid=issues-delete-cancel]').click()
    setTimeout(() => resolve(Boolean(document.querySelector('[data-testid=ui-dialog]'))), 0)
  }))
  ok('R1 a confirm (size sm, no transition) is gone one macrotask after Cancel', confirmStill === false, { confirmStill })

  /* S: switch in Settings -> Behaviour */
  await load(DESKTOP, '/settings/behaviour')
  await p.waitForSelector('[data-test=close_buttons-windows]', { timeout: 10000 })
  const macChecked = await p.$eval('[data-test=close_buttons-mac]', (el) => el.checked)
  ok('S0 the Mac radio is the checked default', macChecked)
  await p.click('[data-test=close_buttons-windows]')
  await sleep(500)
  ok('S1 the switch is sent to the hub as {"close_buttons":"windows"} alone', puts.some((b) => b.close_buttons === 'windows' && Object.keys(b).length === 1), puts)
  ok('S2 the root follows at once', (await rootMode()) === 'windows', await rootMode())

  /* W: the pref survives a reload */
  await load(DESKTOP, '/channel/lobby')
  ok('W0 after a reload: <html data-close-buttons="windows">', (await rootMode()) === 'windows', await rootMode())
  await openLogo()
  g = await geometry(...DIALOG)
  ok('W1 1440 dialog: the X is top right, after the title', g.found && g.visible && !g.left && g.afterTitle && !g.domFirst && g.side === 'end', g)
  ok('K3 Windows: the X is the header\'s last Tab stop, after the title', (await firstTabStop()).headLast === 'ui-dialog-close', await firstTabStop())
  await shot('1440-windows-dialog')
  ok('K4 Windows: closing by the X gives focus back to the opener', (await closeDialogByX()) === 'top-bar-logo')
  await openThread()
  g = await geometry(...THREAD)
  ok('W2 1440 thread pane: the X is top right, after the title', g.found && g.visible && !g.left && g.afterTitle, g)
  await shot('1440-windows-thread')

  /* P + W at 390 */
  await load(PHONE, '/issues')
  await openLogo()
  const phoneHead = await p.evaluate(() => {
    const back = document.querySelector('[data-testid=ui-dialog-back]').getBoundingClientRect()
    const x = document.querySelector('[data-testid=ui-dialog-close]')
    return { backLeft: back.left < 60 && back.width > 0, xShown: Boolean(x && x.getBoundingClientRect().width > 0) }
  })
  ok('P1 390 Windows: the full-screen dialog keeps Back top left, no X', phoneHead.backLeft && !phoneHead.xShown, phoneHead)
  await p.click('[data-testid=ui-dialog-back]')
  await sleep(300)
  await p.click('[data-test=issues-filters-open]')
  await p.waitForSelector('[data-test=issues-filter-sheet]', { visible: true, timeout: 5000 })
  await sleep(300)
  g = await geometry(...SHEET)
  ok('W3 390 filter sheet: the X is right of its heading', g.found && g.visible && !g.left && g.afterTitle, g)
  await shot('390-windows-sheet')
  await p.click('[data-test=issues-filter-sheet-close]')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-filter-sheet]'), { timeout: 5000 })
  ok('W4 390 the sheet X closes it', true)

  /* M: back to Mac style (at 390, through Settings) */
  await load(PHONE, '/settings/behaviour')
  await p.waitForSelector('[data-test=close_buttons-mac]', { timeout: 10000 })
  await p.click('[data-test=close_buttons-mac]')
  await sleep(500)
  ok('M0 back to {"close_buttons":"mac"}', stored === 'mac', puts)
  await load(PHONE, '/issues')
  await openLogo()
  const phoneMac = await p.evaluate(() => {
    const back = document.querySelector('[data-testid=ui-dialog-back]').getBoundingClientRect()
    const x = document.querySelector('[data-testid=ui-dialog-close]')
    return { backLeft: back.left < 60 && back.width > 0, xShown: Boolean(x && x.getBoundingClientRect().width > 0) }
  })
  ok('P2 390 Mac: Back stays top left, no X', phoneMac.backLeft && !phoneMac.xShown, phoneMac)
  await p.click('[data-testid=ui-dialog-back]')
  await sleep(300)
  await p.click('[data-test=issues-filters-open]')
  await p.waitForSelector('[data-test=issues-filter-sheet]', { visible: true, timeout: 5000 })
  await sleep(300)
  g = await geometry(...SHEET)
  ok('M1 390 filter sheet: the X is left of its heading', g.found && g.visible && g.left && g.beforeTitle && g.domFirst, g)
  await shot('390-mac-sheet')

  ok('no page errors', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nclose-buttons: ${results.length - failed.length}/${results.length} OK`)
process.exit(failed.length ? 1 : 0)
