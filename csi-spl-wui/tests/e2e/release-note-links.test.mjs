// Release-note links in a message are internal links (owner, t1 topic
// a1bce52e: "Every release note link or whatever should become an internal
// link. The host name should not be seen, and it should have a small
// preview").
//
// A lane post carries the dev AND the prd URL of one sha. Both read
// `release: <8 hex>` with no host, both point at this page's /releases/<sha>,
// one preview card shows the note, and at 390 px a finger tap opens the note
// in this tab even when the phone drops the click. The other env's host is
// dev.<page host> here (the page runs on localhost, the dev link on
// dev.localhost), the shape of dev.<base> next to the prd apex.
//
// Run: node tests/e2e/release-note-links.test.mjs
//      BASE_URL=<generated mock bundle> node tests/e2e/release-note-links.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PEER = 'CLE-07@box-a'
const DM_TASK = 'fe510000-0000-4000-8000-0000000000b7'
/* the mock tenant's first release note (release-notes-api.mjs mockNote(0)) */
const SHA = '00000001'.repeat(5)
const LABEL = 'release: ' + SHA.slice(0, 8)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function rows(base) {
  const u = new URL(base)
  const dev = `${u.protocol}//dev.${u.host}/releases/${SHA}`
  const prd = `${u.protocol}//${u.host}/releases/${SHA}`
  const body = `c-450 released\n\n- dev ${dev}\n- prd ${prd}\n`
  const baseRow = { v: 1, files: [], kind: 'result', is_parent: 1, parent_task_id: null, channel: null }
  return [
    { ...baseRow, msg_id: 'fe520000-0000-4000-8000-0000000000b7', task_id: DM_TASK, from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', body, ts: '2026-12-31T23:59:00Z' },
  ]
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

const look = (p, sha) => p.evaluate((want) => {
  const links = [...document.querySelectorAll('a.msg-link')]
    .filter((a) => /releases/.test((a.getAttribute('href') || '') + (a.textContent || '')))
    .map((a) => ({
      text: (a.textContent || '').trim(),
      href: a.getAttribute('href') || '',
      target: a.getAttribute('target') || '',
    }))
  const card = document.querySelector(`[data-test=link-preview][data-id="release:${want}"]`)
  return {
    links,
    card: card ? {
      kind: card.getAttribute('data-kind') || '',
      title: card.querySelector('[data-test=link-preview-title]')?.textContent || '',
      text: (card.textContent || '').trim(),
    } : null,
  }
}, sha)

async function waitFor(p, pred, ms = 20000) {
  const start = Date.now()
  let last = null
  while (Date.now() - start < ms) {
    last = await look(p, SHA).catch(() => null)
    if (last && pred(last)) return last
    await sleep(200)
  }
  return last
}

/** A pixel of the first release link the finger would land on. */
async function linkPoint(p) {
  for (let i = 0; i < 10; i++) {
    const pt = await p.evaluate(() => {
      /* the phone shows one pane: try every release link, keep the one on screen */
      const list = [...document.querySelectorAll('a.msg-link')].filter((el) => /releases/.test(el.getAttribute('href') || ''))
      for (const a of list) {
        if (!a.getClientRects().length) continue
        a.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' })
        for (const r of a.getClientRects()) {
          for (let y = Math.ceil(r.top) + 1; y < r.bottom; y += 2) {
            for (let x = Math.ceil(r.left) + 1; x < r.right; x += 2) {
              const at = document.elementFromPoint(x, y)
              if (at && at.closest && at.closest('a.msg-link') === a) return { x: Math.round(x), y: Math.round(y) }
            }
          }
        }
      }
      return null
    })
    if (pt) return pt
    await sleep(150)
  }
  return null
}

async function touchTap(p, x, y) {
  const cdp = await p.createCDPSession()
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] })
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach()
}

const srv = await startServer()
/* the page host must have a dev.<host> sibling: an IP has none */
const base = srv.base.replace('://127.0.0.1', '://localhost')
const browser = await launch()
try {
  for (const [label, vp] of [['1440px', { width: 1440, height: 900 }], ['390px', { width: 390, height: 844, isMobile: true, hasTouch: true }]]) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport(vp)
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
    await p.evaluateOnNewDocument((extra) => {
      try {
        localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
        localStorage.setItem('spool.mock.session', JSON.stringify({
          hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1',
        }))
        localStorage.setItem('spool-card-clip-thread', 'full')
        localStorage.setItem('spool-card-clip', 'full')
      } catch { /* private mode */ }
      window.__opens = []
      window.open = (url) => {
        window.__opens.push(String(url))
        return { closed: false, opener: null }
      }
    }, rows(base))
    let shell = false
    for (let attempt = 0; attempt < 2 && !shell; attempt++) {
      await p.goto(`${base}/dm/${encodeURIComponent(PEER)}?topic=${DM_TASK}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : 120000 }).then(() => true, () => false)
    }
    ok(`${label} the shell is up`, shell, errors.slice(0, 3))
    if (!shell) { await p.close(); continue }

    const s = await waitFor(p, (x) => x.links.length >= 2 && x.links.every((a) => a.text === LABEL) && x.card, 45000)
    const links = (s && s.links) || []
    if (!(links.length >= 2 && s.card)) console.log('  SNAP', label, JSON.stringify(s))
    ok(`${label} the dev and the prd release URL are both on the card`, links.length >= 2, links)
    ok(`${label} both read ${LABEL}, no host`, links.length >= 2 && links.every((a) => a.text === LABEL && !/localhost|https?:/.test(a.text)), links)
    ok(`${label} both point at this page's /releases/<sha>, same tab`, links.length >= 2 && links.every((a) => a.href === `/releases/${SHA}` && !a.target), links)
    ok(`${label} one release preview card with the note's title`, !!(s && s.card && s.card.kind === 'release' && /^mock change 1:/.test(s.card.title)), s && s.card)
    ok(`${label} the card shows no host`, !!(s && s.card && !/localhost/.test(s.card.text)), s && s.card)

    if (label === '390px') {
      /* the phone drops the click on a link in a card: cancel every click */
      await p.evaluate(() => {
        window.addEventListener('click', (e) => { e.preventDefault(); e.stopImmediatePropagation() }, true)
      })
      const pt = await linkPoint(p)
      ok('390px the finger lands on the release link', !!pt, pt)
      if (pt) await touchTap(p, pt.x, pt.y)
      const start = Date.now()
      let at = { path: '', opens: [], dialog: false }
      while (Date.now() - start < 10000) {
        at = await p.evaluate(() => ({
          path: location.pathname,
          opens: window.__opens || [],
          dialog: !!document.querySelector('[data-test=releases-page]'),
        }))
        if (at.path === `/releases/${SHA}` && at.dialog) break
        await sleep(150)
      }
      ok('390px the tap opens the note in this tab', at.path === `/releases/${SHA}` && at.dialog, at)
      ok('390px the tap opens no new tab', !!pt && at.opens.length === 0, at.opens)
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nrelease-note-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log('FAILED:', failed.map((f) => f.name).join('; '))
  process.exit(1)
}
