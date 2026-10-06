// c-370 live proof that a signed-in member sees the workspace docs controls
// (owner, t1 199cafc7: "i CANNOT see any edit button"): signs in through the
// WUI form, opens /docs, and records what decides them - GET /v1/view/me
// (does it carry docs.write), GET /v1/workspace/docs/tree.json (status), the
// Workspace docs section's state, and where it sits: ABOVE the repo tree,
// with New doc as a labelled button inside the first screen, at desktop and
// phone widths, then Edit on a workspace doc. Read-only by default: it
// never presses Save or Delete. WRITE=1 (a test tenant only) creates
// proofs/c-370-visible.md through New doc when no doc is listed, checks
// Edit on it, and deletes it again.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [WRITE=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/docs-ws-visible-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const seen = {}
  p.on('response', async (r) => {
    const u = r.url()
    if (r.request().method() !== 'GET') return
    if (/\/v1\/view\/me(\?|$)/.test(u)) {
      const b = await r.json().catch(() => null)
      seen.me = { status: r.status(), role: b?.role ?? null, permissions: b?.permissions ?? null }
    }
    if (/\/v1\/workspace\/docs\/tree\.json/.test(u)) seen.tree = { status: r.status() }
  })
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  for (const [w, h, tag] of [[1280, 800, 'desktop'], [390, 844, 'phone']]) {
    await p.setViewport({ width: w, height: h })
    await p.goto(BASE + '/docs', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=ws-docs][data-state=ready], [data-test=ws-docs][data-state=failed]', { timeout: 20000 }).catch(() => null)
    await sleep(800)
    const st = await p.evaluate(() => {
      const ws = document.querySelector('[data-test=ws-docs]')
      const repo = document.querySelector('[data-test=docs-tree] [data-test=docs-file], [data-test=docs-tree] [data-test=docs-dir]')
      const add = document.querySelector('[data-test=ws-docs-new]')
      const rect = (e) => { if (!e) return null; const r = e.getBoundingClientRect(); return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) } }
      return {
        wsState: ws?.getAttribute('data-state') ?? null,
        wsAboveRepo: !!(ws && repo && (ws.compareDocumentPosition(repo) & Node.DOCUMENT_POSITION_FOLLOWING)),
        add: rect(add),
        addText: add?.textContent?.trim() ?? '',
        vh: window.innerHeight,
      }
    })
    res[tag] = st
    await p.screenshot({ path: `${OUT}/docs-${tag}.png` })
    step(`${tag}: view/me carries docs.write`, !!seen.me && (seen.me.permissions === null || seen.me.permissions.includes('docs.write')), seen.me ?? {})
    step(`${tag}: workspace tree.json answers 200`, seen.tree?.status === 200, seen.tree ?? {})
    step(`${tag}: Workspace docs section ready, above the repo tree`, st.wsState === 'ready' && st.wsAboveRepo, { wsState: st.wsState, wsAboveRepo: st.wsAboveRepo })
    step(`${tag}: New doc is a labelled button in the first screen`,
      !!st.add && st.addText.length > 0 && st.add.y >= 0 && st.add.y + st.add.h <= st.vh && st.add.x >= 0 && st.add.x + st.add.w <= w,
      { add: st.add, addText: st.addText, vh: st.vh })
  }
  // Edit on a workspace doc: open the first one listed (WRITE=1: make one)
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/docs', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=ws-docs][data-state=ready]', { timeout: 20000 }).catch(() => null)
  let first = await p.$('[data-test=ws-docs-file]')
  let made = false
  if (!first && process.env.WRITE === '1') {
    await p.click('[data-test=ws-docs-new]')
    await p.waitForSelector('[data-test=ws-docs-new-path]', { visible: true, timeout: 5000 })
    await p.type('[data-test=ws-docs-new-path]', 'proofs/c-370-visible')
    await p.click('[data-test=ws-docs-new-create]')
    await p.waitForSelector('[data-test=ws-doc-save]', { visible: true, timeout: 15000 })
    await p.click('[data-test=ws-doc-save]')
    first = await p.waitForSelector('[data-test=ws-docs-file][data-path="proofs/c-370-visible.md"]', { timeout: 15000 }).catch(() => null)
    made = !!first
    step('WRITE=1: New doc + Save creates a doc', made)
  }
  if (first) {
    await first.click()
    const edit = await p.waitForSelector('[data-test=ws-doc-edit]', { visible: true, timeout: 15000 }).catch(() => null)
    step('a workspace doc shows Edit', !!edit, { url: p.url() })
    await p.screenshot({ path: `${OUT}/docs-ws-doc.png` })
    if (made) {
      await p.click('[data-test=ws-doc-delete]')
      await p.waitForSelector('[data-testid=ws-doc-delete-confirm-confirm]', { visible: true, timeout: 5000 })
      await p.click('[data-testid=ws-doc-delete-confirm-confirm]')
      await sleep(1500)
      step('WRITE=1: the proof doc is deleted again', !(await p.$('[data-test=ws-docs-file][data-path="proofs/c-370-visible.md"]')))
    }
  } else {
    step('a workspace doc shows Edit', false, { skipped: 'no workspace doc listed (WRITE=1 makes one)' })
  }
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
