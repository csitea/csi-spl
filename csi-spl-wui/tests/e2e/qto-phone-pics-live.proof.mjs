// c-820 live proof of Qto pictures on the phone (owner HUM-10, t1 46d9c236
// msg 3c943bd0: "If this is not implemented on mobile, do it on mobile as
// well."). Signs in through the WUI form on a 390x844 touch viewport, makes a
// throwaway document from the + (the modal), taps the 1.1 and 1.1.1
// paragraphs, taps Insert picture and chooses a png each time, then records:
// the control's height (44 px on a touch screen), the hub tokens, "Figure 1"
// and "Figure 2" read inline with their captions. Screenshots: phone-pics-edit
// (a picture just inserted, its caption selected in the text) and
// phone-pics-read (both figures read). The document is deleted again unless
// KEEP=1. Writes to the workspace: run it in a TEST tenant only (prd: e2e).
//
//   BASE=https://<host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [KEEP=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/qto-phone-pics-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
mkdirSync(OUT, { recursive: true })
const png = join(OUT, 'qto-phone-pic.png')
writeFileSync(png, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAKAAAABaCAIAAACwpMoFAAAA60lEQVR42u3RMQ0AIAwAMOQgAhHcKEEON0qmBB1cU7EmddD2Ti+l7yilCRYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxYsWLBgwYIFCxacweOuUmLMUgQLFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULFixYsGDBggULTh9G/atCMtzSagAAAABJRU5ErkJggg==', 'base64'))
const puppeteer = await loadPuppeteer()
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const STEP = 20000
const row = (n) => `[data-test=ws-doc-row][data-outline="${n}"]`
const text = (n) => `${row(n)} [data-test=ws-doc-text]`
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let hub = null
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await (await browser.createBrowserContext()).newPage()
  /* the doctree calls' base and auth header, for the clean-up DELETE */
  p.on('request', (r) => {
    const m = r.url().match(/^(.*)\/v1\/workspace\/doctree(?:[/?]|$)/)
    if (m) hub = { base: m[1], auth: r.headers().authorization || '' }
  })
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/workspace/docs'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.tap('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.startsWith('/login'), { timeout: 30000 }).catch(() => null)
  step('native sign-in', !p.url().includes('/login'), { url: p.url() })
  if (!p.url().includes('/workspace/docs')) await p.goto(BASE + '/workspace/docs', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=ws-docs-new]', { visible: true, timeout: STEP })
  const title = `c-820 phone pictures ${Date.now()}`
  await p.tap('[data-test=ws-docs-new]')
  await p.waitForSelector('[data-test=ws-docs-new-title]', { visible: true, timeout: STEP })
  await p.type('[data-test=ws-docs-new-title]', title)
  await p.tap('[data-test=ws-docs-create]')
  await p.waitForFunction((t) => document.querySelector('[data-test=ws-doc-doctitle]')?.textContent?.trim() === t, { timeout: STEP }, title).catch(() => null)
  await p.waitForSelector(text('1.1.1'), { timeout: STEP }).catch(() => null)
  res.doc = await p.$eval('[data-test=ws-docs-select]', (e) => e.value).catch(() => '')
  step('a new document opens with sections 1.1 and 1.1.1', Boolean(res.doc && await p.$(text('1.1.1'))), { title, doc: res.doc })

  /* every picture loaded and the layout still: a tap lands where it was aimed */
  const settled = async () => {
    await p.waitForFunction(() => [...document.querySelectorAll('[data-test=ws-doc-pic-img]')].every((i) => i.complete), { timeout: STEP }).catch(() => null)
    await sleep(800)
  }
  const insert = async (n, caption, shot) => {
    await settled()
    await p.$eval(text(n), (e) => e.scrollIntoView({ block: 'center' }))
    await sleep(300)
    await p.tap(text(n))
    await p.waitForFunction((s) => document.activeElement === document.querySelector(s), { timeout: STEP }, text(n)).catch(() => null)
    await p.keyboard.type(`Text of section ${n}, then a picture:`)
    const btn = await p.waitForSelector(`${row(n)} [data-test=ws-doc-insert-pic]`, { visible: true, timeout: STEP }).catch(() => null)
    const tool = btn ? await btn.evaluate((b) => {
      const r = b.getBoundingClientRect()
      const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
      return { h: Math.round(r.height), inView: r.top >= 0 && r.bottom <= innerHeight, onTop: Boolean(top && b.contains(top)) }
    }) : null
    const [fc] = await Promise.all([p.waitForFileChooser({ timeout: STEP }).catch(() => null), p.tap(`${row(n)} [data-test=ws-doc-insert-pic]`).catch(() => null)])
    if (fc) await fc.accept([png])
    await p.waitForFunction((s) => {
      const el = document.querySelector(s)
      return el === document.activeElement && el.selectionEnd > el.selectionStart
    }, { timeout: STEP }, text(n)).catch(() => null)
    await p.keyboard.type(caption)
    if (shot) await p.screenshot({ path: `${OUT}/phone-pics-edit.png` })
    await p.evaluate(() => document.activeElement?.blur())
    await p.waitForSelector(`${row(n)} [data-test=ws-doc-para]`, { timeout: STEP }).catch(() => null)
    step(`${n}: Insert picture shows on screen, uncovered, a 44 px tap; the picker opens`, Boolean(tool && tool.h >= 44 && tool.inView && tool.onTop && fc), { tool, chooser: Boolean(fc) })
  }
  await insert('1.1', 'Phone picture one', false)
  await insert('1.1.1', 'Phone picture two', true)
  await p.waitForFunction(() => [...document.querySelectorAll('[data-test=ws-doc-pic-img]')].filter((i) => i.naturalWidth > 0).length === 2, { timeout: STEP }).catch(() => null)
  await settled()
  const read = await p.evaluate(() => ({
    imgs: [...document.querySelectorAll('[data-test=ws-doc-pic-img]')].map((i) => ({ w: i.naturalWidth, fits: i.getBoundingClientRect().right <= innerWidth })),
    nums: [...document.querySelectorAll('[data-test=ws-doc-pic] [data-test=ws-doc-fig-num]')].map((e) => e.textContent.trim()),
    caps: [...document.querySelectorAll('[data-test=ws-doc-pic-caption]')].map((e) => e.value),
    capH: [...document.querySelectorAll('[data-test=ws-doc-pic-caption]')].map((e) => Math.round(e.getBoundingClientRect().height)),
  }))
  await p.$eval(row('1.1'), (e) => e.scrollIntoView({ block: 'start' }))
  await sleep(300)
  await p.screenshot({ path: `${OUT}/phone-pics-read.png` })
  step('read: both pictures inline as Figure 1 and Figure 2 with their captions, 44 px caption taps',
    read.imgs.length === 2 && read.imgs.every((i) => i.w > 0 && i.fits) && read.nums.join() === 'Figure 1:,Figure 2:'
    && read.caps.join() === 'Phone picture one,Phone picture two' && read.capH.every((h) => h >= 44), read)

  if (process.env.KEEP !== '1' && res.doc && hub) {
    const del = await p.evaluate(async (h, d) => {
      const headers = h.auth ? { authorization: h.auth } : {}
      const sub = await (await fetch(`${h.base}/v1/workspace/doctree/${d}/subtree`, { headers, credentials: 'include' })).json().catch(() => ({}))
      const r = await fetch(`${h.base}/v1/workspace/doctree/${d}?rev=${sub.rev}`, { method: 'DELETE', headers, credentials: 'include' })
      return r.status
    }, hub, res.doc)
    step('the proof document is deleted again', del >= 200 && del < 300, { status: del })
  }
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(res.steps.length && res.steps.every((s) => s.ok) ? 0 : 1)
