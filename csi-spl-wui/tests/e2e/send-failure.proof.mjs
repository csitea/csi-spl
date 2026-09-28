// a send that does not land must keep the text, say so, and offer
// a retry. On 2026-09-21 it did none of the three: the owner's message left
// no row in the hub's `messages` table and no trace in the browser.
//
// The failure is driven where it actually happens — the Omnibox's registered
// send target in the running page — so this exercises MessageComposer's
// clear-on-emit, TopBar's catch, the restore, the error line and the Retry
// button as one path. The transport is not stubbed out of the picture: the
// SAME script then drives a `token: 'closed'` rejection, which is the exact
// shape live-ws rejects with when the socket goes away under a pending frame.
//
//   BASE=https://dev.<domain> OUT=/var/tmp/CLE-3433-proof \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/send-failure.proof.mjs
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const TEXT = 'CLE-3433 proof: this text must survive a failed send'

mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
let failed = 0
const step = (name, ok, ev = {}) => {
  if (!ok) failed++
  res.steps.push({ name, ok, ...ev })
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
const rejections = []
try {
  const page = await browser.newPage()
  await page.setViewport({ width: 1440, height: 900 })
  /* an unhandled rejection is the defect itself, so it is measured, not ignored */
  page.on('pageerror', (e) => rejections.push(String(e).slice(0, 200)))
  await page.goto(BASE + '/', { waitUntil: 'networkidle2', timeout: 30000 })
  await page.waitForSelector('[data-test=top-bar-omnibox] textarea', { timeout: 15000 })

  /* register a send target that fails the way live-ws does, so the Omnibox
     has somewhere to send and we control the outcome */
  const install = async (token) => page.evaluate((tok) => {
    const app = document.querySelector('#__nuxt')?.__vue_app__ || document.body.__vue_app__
    const store = app?.config?.globalProperties?.$pinia?._s?.get('omnibox')
    if (!store) return false
    window.__sent = []
    store.target = {
      placeholder: () => 'proof target',
      busy: () => false,
      send: async (text) => {
        window.__sent.push(text)
        if (tok) throw Object.assign(new Error('driven ' + tok), { token: tok })
      },
    }
    return true
  }, token)

  const type = async (body) => {
    await page.click('[data-test=top-bar-omnibox] textarea')
    await page.evaluate(() => {
      const ta = document.querySelector('[data-test=top-bar-omnibox] textarea')
      ta.value = ''
      ta.dispatchEvent(new Event('input', { bubbles: true }))
    })
    await page.type('[data-test=top-bar-omnibox] textarea', body)
    await page.keyboard.down('Control')
    await page.keyboard.press('Enter')
    await page.keyboard.up('Control')
    await new Promise((r) => setTimeout(r, 600))
  }
  const read = () => page.evaluate(() => {
    const ta = document.querySelector('[data-test=top-bar-omnibox] textarea')
    const err = document.querySelector('[data-test=omnibox-send-error-message]')
    const retry = document.querySelector('[data-test=omnibox-send-retry]')
    return {
      text: ta ? ta.value : null,
      error: err ? err.innerText.trim() : null,
      retry: Boolean(retry),
      sent: (window.__sent || []).slice(),
    }
  })

  step('a send target is registered', await install('closed'))

  await type(TEXT)
  let m = await read()
  step('a dropped socket: the text is BACK in the box, with a reason and a Retry',
    m.text === TEXT && Boolean(m.error) && m.retry && m.sent.length === 1, m)
  await page.screenshot({ path: `${OUT}/send-failed-closed.png` })

  /* the defect was silence: a rejection nobody caught */
  step('the failure produced NO unhandled rejection', rejections.length === 0, { rejections })

  /* Retry sends the same text again - the human never retypes it */
  await page.click('[data-test=omnibox-send-retry]')
  await new Promise((r) => setTimeout(r, 600))
  m = await read()
  step('Retry re-sends the same text', m.sent.length === 2 && m.sent[1] === TEXT, m)

  /* and a send that SUCCEEDS still clears the box and leaves no error */
  await install('')
  await type('a send that works')
  m = await read()
  step('a successful send clears the box and shows no error',
    m.text === '' && !m.error && m.sent.length === 1, m)
  await page.screenshot({ path: `${OUT}/send-ok.png` })
  await page.close()
} catch (e) {
  step('proof threw', false, { err: String((e && e.stack) || e) })
} finally {
  await browser.close().catch(() => {})
}
res.failed = failed
writeFileSync(`${OUT}/send-failure.json`, JSON.stringify(res, null, 2))
console.log(failed === 0 ? `ALL PASS (${res.steps.length} steps)` : `${failed} FAIL of ${res.steps.length}`)
process.exit(failed === 0 ? 0 : 1)
