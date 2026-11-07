// Spec 160 3.5 (SPL-3888, row B5): Monitoring -> File streams in a real
// browser against the mock bundle (monitoring-file-streams.mjs: box-a app
// grows one line per poll, cron, box-b web missing):
//   C39 the page lists every box and, under it, each followed file as a row
//       with its own tail -f button; no view is open before a click;
//   C40 tail -f on one row opens THAT file's lines only, under its row, the
//       open file in the URL; a reload keeps it open, Back the file before;
//   C19 a line the stub appends shows within 2 polls;
//       Pause sends 0 requests in 10 s; Resume shows "N new lines";
//   C20 scrolling up turns Follow off; "Jump to latest" turns it on;
//   C21 a search hit (?seq=) opens the view at that line, Follow off;
//   C18 a developer reaching the URL sees one line, no view.
// Spec 160 3.8 (SPL-4695, row B12), the file globs:
//   C55 an owner sees "Add a file glob" under each box, an operator who is
//       neither owner nor admin does not; the form sends {box_id, key,
//       glob} only; a hub 400 shows its code's sentence; a glob row shows
//       its state (pending until the box reports it) and "N of M matches
//       followed"; Remove asks first, then calls DELETE.
// Spec 160 3.10 (SPL-4979), a file out of the view, at 1440 and 390 px:
//   C64 Remove asks first, Keep keeps the row, Remove moves it to "Removed
//       files" and closes it when open, audited; a refused Put back shows its
//       sentence, the row stays removed; Put back returns it; no sideways scroll.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-file-streams
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const POLL_MS = 3000
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: { width: 1280, height: 800 }, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const BIZ = { role: 'biz_owner', permissions: ['members.invite', 'members.roles', 'tenant.settings'] }
const DEV = { role: 'developer', permissions: ['topics.read', 'notes.send'] }
const EN = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8')).monitoring.file_streams.glob
const text = (p, sel) => p.$eval(sel, (x) => (x.textContent || '').trim()).catch(() => '')
const lastSeq = (p) => p.$$eval('[data-test=fs-line]', (xs) => (xs.length ? Number(xs[xs.length - 1].getAttribute('data-seq')) : 0))
const checked = (p) => p.$eval('[data-test=fs-follow]', (x) => x.checked)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((biz) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Owner', email: 'owner@example.com', t: 'mock' }))
    localStorage.setItem('spool.mock.me', JSON.stringify(biz))
  }, BIZ)

  // C39 the list: every stream of box-a and box-b is a row with a tail -f
  // button, under its box; nothing is open yet
  await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-row]', { visible: true, timeout: 20000 }).catch(() => null)
  const list = await p.evaluate(() => [...document.querySelectorAll('[data-test=fs-group]')].map((g) => ({
    box: g.getAttribute('data-box'),
    rows: [...g.querySelectorAll('[data-test=fs-row]')].map((r) => ({ stream: r.getAttribute('data-stream'), tail: (r.querySelector('[data-test=fs-tail]')?.textContent || '').trim() })),
  })))
  const want = [{ box: 'box-a', streams: ['app', 'cron'] }, { box: 'box-b', streams: ['web'] }]
  const listOk = list.length === 2 && want.every((w, i) => list[i].box === w.box && list[i].rows.map((r) => r.stream).join() === w.streams.join() && list[i].rows.every((r) => r.tail === 'tail -f'))
  ok('C39 every stream of every box is a row with a tail -f button', listOk, list)
  ok('C39 no view is open before a tail -f click', (await p.$$('[data-test=fs-view]')).length === 0)

  // C40 tail -f on cron: one view, under the cron row, cron's lines only
  await p.click('[data-test=fs-row][data-stream=cron] [data-test=fs-tail]')
  await p.waitForSelector('[data-test=fs-line]', { visible: true, timeout: 20000 }).catch(() => null)
  const cron = await p.evaluate(() => ({
    views: document.querySelectorAll('[data-test=fs-view]').length,
    under: Boolean(document.querySelector('[data-test=fs-row][data-stream=cron] [data-test=fs-view]')),
    texts: [...document.querySelectorAll('[data-test=fs-line]')].map((x) => x.textContent || ''),
    search: location.search,
  }))
  const cronOnly = cron.texts.length > 0 && cron.texts.every((x) => x.includes('cron')) && !cron.texts.some((x) => x.includes('app'))
  ok('C40 tail -f shows only that stream\'s lines, one view, under its row', cron.views === 1 && cron.under && cronOnly, { views: cron.views, under: cron.under, n: cron.texts.length, first: cron.texts[0] })
  ok('C40 the open file is in the URL', cron.search.includes('box=box-a') && cron.search.includes('stream=cron'), cron.search)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-row][data-stream=cron] [data-test=fs-line]', { visible: true, timeout: 20000 }).catch(() => null)
  ok('C40 a reload keeps the file open', Boolean(await p.$('[data-test=fs-row][data-stream=cron] [data-test=fs-view]')))

  // tail -f on app: the one view moves there; Back returns to cron
  await p.click('[data-test=fs-row][data-stream=app] [data-test=fs-tail]')
  await p.waitForFunction(() => location.search.includes('stream=app') && document.querySelector('[data-test=fs-row][data-stream=app] [data-test=fs-line]'), { timeout: 20000 }).catch(() => null)
  const switched = await p.evaluate(() => ({ views: document.querySelectorAll('[data-test=fs-view]').length, app: Boolean(document.querySelector('[data-test=fs-row][data-stream=app] [data-test=fs-view]')) }))
  ok('C40 tail -f on another row moves the one view there', switched.views === 1 && switched.app, switched)
  await p.goBack({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForFunction(() => location.search.includes('stream=cron') && document.querySelector('[data-test=fs-row][data-stream=cron] [data-test=fs-view]'), { timeout: 15000 }).catch(() => null)
  ok('C40 Back opens the file before', (await p.evaluate(() => location.search)).includes('stream=cron') && Boolean(await p.$('[data-test=fs-row][data-stream=cron] [data-test=fs-view]')))
  await p.click('[data-test=fs-row][data-stream=app] [data-test=fs-tail]')
  await p.waitForFunction(() => location.search.includes('stream=app'), { timeout: 10000 }).catch(() => null)
  await p.waitForSelector('[data-test=fs-row][data-stream=app] [data-test=fs-line]', { visible: true, timeout: 20000 }).catch(() => null)
  await sleep(500)

  // C19 a line the stub appends shows within 2 polls, Follow on
  const s0 = await lastSeq(p)
  await sleep(2 * POLL_MS + 500)
  const s1 = await lastSeq(p)
  ok('C19 a new line shows within 2 polls, Follow on', s1 > s0 && (await checked(p)), { s0, s1 })

  // C19 Pause: the mock answers in the page (no network to count), and it
  // appends one line per poll, so a poll during 10 s of Pause would add >= 3
  // lines: the view must gain none. Resume: "N new lines".
  await p.click('[data-test=fs-pause]')
  const frozen = await lastSeq(p)
  await sleep(10000)
  const during = await lastSeq(p)
  ok('C19 Pause: no poll in 10 s, the view gains no line', during === frozen, { frozen, during })
  await p.click('[data-test=fs-pause]')
  await p.waitForSelector('[data-test=fs-new]', { visible: true, timeout: 10000 }).catch(() => null)
  const note = await p.$eval('[data-test=fs-new]', (x) => x.textContent || '').catch(() => '')
  ok('C19 Resume shows "N new lines"', /\b[1-9]\d* new lines?\b/.test(note) && (await lastSeq(p)) > frozen, { note })

  // C20 scrolling up turns Follow off; Jump to latest turns it on
  await p.$eval('[data-test=fs-view]', (v) => { v.scrollTop = 0; v.dispatchEvent(new Event('scroll')) })
  await sleep(200)
  const offAfterScroll = !(await checked(p))
  await p.click('[data-test=fs-jump]')
  await sleep(300)
  const bottom = await p.$eval('[data-test=fs-view]', (v) => v.scrollTop + v.clientHeight >= v.scrollHeight - 8)
  ok('C20 scrolling up turns Follow off; Jump to latest turns it on at the bottom', offAfterScroll && (await checked(p)) && bottom, { offAfterScroll, bottom })

  // C21 a search hit opens the view at that line, Follow off
  await p.goto(server.base + '/monitoring/file-streams?box=box-a&stream=app&seq=30', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-line][data-seq="30"]', { visible: true, timeout: 20000 }).catch(() => null)
  const hit = await p.evaluate(() => {
    const v = document.querySelector('[data-test=fs-view]')
    const row = document.querySelector('[data-test=fs-line][data-seq="30"]')
    if (!v || !row) return null
    const a = v.getBoundingClientRect()
    const b = row.getBoundingClientRect()
    return { inView: b.top >= a.top && b.bottom <= a.bottom, hit: row.classList.contains('fs-hit') }
  })
  ok('C21 a hit opens at that line, marked, Follow off', Boolean(hit && hit.inView && hit.hit) && !(await checked(p)), hit)

  // C55 the globs: "Add a file glob" under each box; a reported glob's state and counts, a pending one never "following"
  await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-glob]', { visible: true, timeout: 20000 }).catch(() => null)
  const perBox = await p.evaluate(() => [...document.querySelectorAll('[data-test=fs-group]')].map((g) => [g.getAttribute('data-box'), g.querySelectorAll('[data-test=fs-glob-add]').length]))
  ok('C55 an owner sees "Add a file glob" under each box', perBox.length === 2 && perBox.every(([, n]) => n === 1) && (await text(p, '[data-test=fs-glob-add]')) === EN.add, perBox)
  const rowOf = (key) => p.evaluate((k) => {
    const r = document.querySelector(`[data-test=fs-glob][data-glob="${k}"]`)
    if (!r) return null
    const q = (s) => (r.querySelector(`[data-test=${s}]`)?.textContent || '').trim()
    return { state: r.querySelector('[data-test=fs-glob-state]')?.getAttribute('data-state'), stateText: q('fs-glob-state'), matches: q('fs-glob-matches'), box: r.closest('[data-test=fs-group]')?.getAttribute('data-box') }
  }, key)
  const sys = await rowOf('syslog')
  ok('C55 a reported glob shows its state and "N of M matches followed"', Boolean(sys && sys.box === 'box-a' && sys.state === 'partial' && sys.stateText === EN.state.partial && sys.matches === '5 of 12 matches followed'), sys)
  const web = await rowOf('web-old')
  ok('C55 a glob the box has not reported is pending, with no count and never "following"', Boolean(web && web.state === 'pending' && web.stateText === EN.state.pending && web.matches === '' && web.stateText !== EN.state.following), web)

  // C55 the form: a hub 400 shows its code's sentence and the form stays; a good glob is added, pending
  await p.click('[data-test=fs-group][data-box=box-a] [data-test=fs-glob-add]')
  await p.waitForSelector('[data-test=fs-glob-form]', { visible: true, timeout: 10000 }).catch(() => null)
  const fill = async (key, glob) => {
    /* clear as a person does, with the input event v-model listens to */
    for (const f of ['fs-glob-key', 'fs-glob-glob']) await p.$eval(`[data-test=${f}]`, (x) => { x.value = ''; x.dispatchEvent(new Event('input', { bubbles: true })) })
    await p.type('[data-test=fs-glob-key]', key)
    await p.type('[data-test=fs-glob-glob]', glob)
    await p.click('[data-test=fs-glob-submit]')
  }
  const refusal = async () => {
    await p.waitForSelector('[data-test=fs-glob-error]', { visible: true, timeout: 10000 }).catch(() => null)
    return p.$eval('[data-test=fs-glob-error]', (x) => ({ code: x.getAttribute('data-code'), text: (x.textContent || '').trim() })).catch(() => null)
  }
  await fill('ssh', '/etc/ssh/*')
  const outside = await refusal()
  ok('C55 a hub 400 outside_folders shows its sentence', Boolean(outside && outside.code === 'outside_folders' && outside.text === EN.err.outside_folders), outside)
  await fill('bad', 'var/log/*.log')
  await p.waitForFunction(() => document.querySelector('[data-test=fs-glob-error]')?.getAttribute('data-code') === 'bad_glob', { timeout: 10000 }).catch(() => null)
  const bad = await refusal()
  ok('C55 a hub 400 bad_glob shows its sentence, the form stays', Boolean(bad && bad.code === 'bad_glob' && bad.text === EN.err.bad_glob) && Boolean(await p.$('[data-test=fs-glob-form]')), bad)
  await fill('app-logs', '/var/csi/csi-spl/*.log')
  await p.waitForSelector('[data-test=fs-glob][data-glob=app-logs]', { visible: true, timeout: 10000 }).catch(() => null)
  const added = await rowOf('app-logs')
  ok('C55 a good glob is added under its box, pending, the form closed', Boolean(added && added.box === 'box-a' && added.state === 'pending' && added.stateText === EN.state.pending) && !(await p.$('[data-test=fs-glob-form]')), added)
  const posts = await p.evaluate(() => (globalThis.SPOOL_MOCK_FS_GLOB_POSTS || []).map((s) => JSON.parse(s)))
  const shapeOk = posts.length === 3 && posts.every((b) => Object.keys(b).sort().join() === 'box_id,glob,key' && b.box_id === 'box-a')
  ok('C55 the form sends {box_id, key, glob} only', shapeOk && posts[2].key === 'app-logs' && posts[2].glob === '/var/csi/csi-spl/*.log', posts)

  // C55 Remove asks first (Keep leaves it), then Remove calls DELETE: the row goes, the audit's newest row is the remove
  const sel = '[data-test=fs-glob][data-glob=app-logs]'
  await p.click(`${sel} [data-test=fs-glob-remove]`).catch(() => null)
  await p.waitForSelector(`${sel} [data-test=fs-glob-confirm]`, { visible: true, timeout: 10000 }).catch(() => null)
  const asked = Boolean(await p.$(`${sel} [data-test=fs-glob-confirm]`)) && Boolean(await p.$(sel))
  await p.click(`${sel} [data-test=fs-glob-remove-no]`).catch(() => null)
  await sleep(300)
  const kept = Boolean(await p.$(sel)) && !(await p.$(`${sel} [data-test=fs-glob-confirm]`))
  await p.click(`${sel} [data-test=fs-glob-remove]`).catch(() => null)
  await p.waitForSelector(`${sel} [data-test=fs-glob-remove-yes]`, { visible: true, timeout: 10000 }).catch(() => null)
  await p.click(`${sel} [data-test=fs-glob-remove-yes]`).catch(() => null)
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 10000 }, sel).catch(() => null)
  const gone = !(await p.$(sel))
  const top = await p.$eval('[data-test=fs-audit-row]', (x) => ({ action: x.getAttribute('data-action'), text: x.textContent || '' })).catch(() => null)
  ok('C55 Remove asks first, Keep keeps it; Remove then deletes it, audited', asked && kept && gone && Boolean(top && top.action === 'remove' && top.text.includes('app-logs')), { asked, kept, gone, top })

  // C64 a file out of the view, at both widths (a reload is a fresh mock)
  const FILE = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8')).monitoring.file_streams.file
  for (const [width, height] of [[1440, 900], [390, 844]]) {
    await p.setViewport({ width, height })
    await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const row = '[data-test=fs-row][data-stream=cron]'
    const gone = '[data-test=fs-removed-row][data-stream=cron]'
    await p.waitForSelector(row, { visible: true, timeout: 20000 }).catch(() => null)
    await p.click(`${row} [data-test=fs-tail]`).catch(() => null)
    await p.waitForSelector(`${row} [data-test=fs-view]`, { visible: true, timeout: 10000 }).catch(() => null)
    await p.click(`${row} [data-test=fs-remove]`).catch(() => null)
    await p.waitForSelector(`${row} [data-test=fs-remove-confirm]`, { visible: true, timeout: 10000 }).catch(() => null)
    const askedFile = (await text(p, `${row} [data-test=fs-remove-confirm] span`)) === FILE.remove_ask.replace('{key}', 'cron')
    const notYet = !(await p.$(gone))
    await p.click(`${row} [data-test=fs-remove-no]`).catch(() => null)
    await sleep(300)
    const keptFile = Boolean(await p.$(row)) && !(await p.$(`${row} [data-test=fs-remove-confirm]`))
    ok(`C64 ${width}px: Remove asks first, Keep keeps the row`, askedFile && notYet && keptFile)
    await p.click(`${row} [data-test=fs-remove]`).catch(() => null)
    await p.waitForSelector(`${row} [data-test=fs-remove-yes]`, { visible: true, timeout: 10000 }).catch(() => null)
    await p.click(`${row} [data-test=fs-remove-yes]`).catch(() => null)
    await p.waitForSelector(gone, { visible: true, timeout: 10000 }).catch(() => null)
    await p.waitForFunction(() => !location.search.includes('stream='), { timeout: 10000 }).catch(() => null)
    const auditTop = () => p.$eval('[data-test=fs-audit-row]', (x) => x.getAttribute('data-action')).catch(() => '')
    const others = await p.$$eval('[data-test=fs-row]', (xs) => xs.map((x) => x.getAttribute('data-stream')).sort().join())
    ok(`C64 ${width}px: Remove moves it to Removed files, closes it, other rows stay, audited`, Boolean(await p.$(gone)) && !(await p.$(row)) &&
      !(await p.$('[data-test=fs-view]')) && !(await p.evaluate(() => location.search.includes('stream='))) && others === 'app,web' && (await auditTop()) === 'file_remove', { others })
    await p.evaluate(() => { globalThis.SPOOL_MOCK_FS_LOCKED_BOXES = ['box-a'] })
    await p.click(`${gone} [data-test=fs-put-back]`).catch(() => null)
    await p.waitForSelector(`${gone} [data-test=fs-row-error]`, { visible: true, timeout: 10000 }).catch(() => null)
    ok(`C64 ${width}px: a refused Put back shows its sentence, the row stays removed`, (await text(p, `${gone} [data-test=fs-row-error]`)) === FILE.err.box_locked && Boolean(await p.$(gone)) && !(await p.$(row)))
    const sideways = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth)
    ok(`C64 ${width}px: no sideways scroll with the removed list`, sideways <= 0, { sideways })
    await p.evaluate(() => { globalThis.SPOOL_MOCK_FS_LOCKED_BOXES = [] })
    await p.click(`${gone} [data-test=fs-put-back]`).catch(() => null)
    await p.waitForSelector(row, { visible: true, timeout: 10000 }).catch(() => null)
    ok(`C64 ${width}px: Put back returns the row, audited`, Boolean(await p.$(row)) && !(await p.$(gone)) && (await auditTop()) === 'file_restore')
  }
  await p.setViewport({ width: 1280, height: 800 })

  // C18 a developer reaching the URL: one line, no view
  await p.evaluate((dev) => localStorage.setItem('spool.mock.me', JSON.stringify(dev)), DEV)
  await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-forbidden]', { timeout: 15000 }).catch(() => null)
  ok('C18 a developer sees one line and no view', Boolean(await p.$('[data-test=fs-forbidden]')) && !(await p.$('[data-test=fs-view]')))

  // C55 an operator who is neither owner nor admin of the workspace: no glob form
  await p.evaluate(() => localStorage.setItem('spool.mock.fleet_operator', '1'))
  await p.goto(server.base + '/monitoring/file-streams', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=fs-forbidden]', { timeout: 15000 }).catch(() => null)
  await sleep(500)
  ok('C55 an operator who is neither owner nor admin sees no glob form', Boolean(await p.$('[data-test=fs-forbidden]')) && (await p.$$('[data-test=fs-glob-add], [data-test=fs-glob-form], [data-test=fs-globs]')).length === 0)
  await p.evaluate(() => { localStorage.removeItem('spool.mock.me'); localStorage.removeItem('spool.mock.fleet_operator') })

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmonitoring-file-streams: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
