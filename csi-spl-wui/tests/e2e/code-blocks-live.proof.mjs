// CLE-3407 live proof of Slack-style ``` code blocks against a deployed WUI:
// native sign-in, then in the /lobby Omnibox type text + inline `code` + an
// XSS payload, type ```js (monospace block, hint), Enter adds lines instead of
// sending, a very long line, the payload again inside the block, ``` closes,
// Ctrl+Enter sends. The sent card must show one code block (label "js", exact
// text, WRAPPED - no x-scroll in the block or the page), the copy button must put exactly
// the code on the clipboard, and the CONTROL: nothing executes (no dialog,
// no <img>/<script> in the body) and 0 CSP violations. Desktop + mobile
// screenshots and results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/code-blocks-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
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
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const nonce = 'cb' + Date.now().toString(36)
const evil = '<script>alert(1)</script><img src=x onerror=alert(1)>'
const long = 'const longLine = "' + 'y'.repeat(400) + '"'
const codeLines = ['function f(a) {', '  if (a) {', '\treturn 1', '  }', '}', '', long, evil]
const expectedCode = codeLines.join('\n')

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const dialogs = []
try {
  const build = await (await fetch(BASE + '/build.json')).json()
  res.build = build
  const ctx = await browser.createBrowserContext()
  await ctx.overridePermissions(BASE, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  const p = await ctx.newPage()
  p.on('dialog', async (d) => { dialogs.push(d.message()); await d.dismiss() })
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`))
  })
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('not signed in')
  await sleep(2500)

  const ta = await p.waitForSelector('form.composer textarea')
  await ta.focus()
  await p.keyboard.type(`code proof ${nonce} \`inline\` ${evil} `)
  await p.keyboard.type('```js')
  const open = await ta.evaluate((e) => ({ cls: e.className, font: getComputedStyle(e).fontFamily }))
  const hint = await p.evaluate(() => document.querySelector('.code-hint')?.textContent.trim() || '')
  step('typing ``` opens a monospace block with a hint', /in-code/.test(open.cls) && /mono/i.test(open.font) && hint.length > 0, { ...open, hint })
  await p.screenshot({ path: `${OUT}/composer-in-block.png` })
  for (const line of codeLines) {
    await p.keyboard.press('Enter')
    // insertText, not key presses: a \t key press would move focus (Tab)
    if (line) await p.keyboard.sendCharacter(line)
  }
  const unsent = await ta.evaluate((e) => e.value)
  step('Enter inside the block adds lines, sends nothing', unsent.split('\n').length === codeLines.length + 1, { lines: unsent.split('\n').length })
  await p.keyboard.press('Enter')
  await p.keyboard.type('```')
  const closed = await ta.evaluate((e) => e.className)
  step('typing ``` again closes the block', !/in-code/.test(closed), { cls: closed })
  await p.screenshot({ path: `${OUT}/composer-closed.png` })
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')

  const card = await p.waitForFunction((n) => [...document.querySelectorAll('article.msg')].find((a) => a.textContent.includes(n)), { timeout: 20000 }, nonce).catch(() => null)
  step('Ctrl+Enter sends; the card appears in the feed', !!card, {})
  if (!card) throw new Error('card not found')
  const el = card.asElement()
  await el.evaluate((a) => a.scrollIntoView({ block: 'center' }))
  await sleep(500)
  const got = await el.evaluate((a) => {
    const blocks = a.querySelectorAll('.code-block')
    const pre = a.querySelector('.code-block pre')
    const cs = pre && getComputedStyle(pre)
    const rows = [...a.querySelectorAll('.code-block .code-line .code-src')]
    return {
      blocks: blocks.length,
      lang: a.querySelector('.code-lang')?.textContent.trim() || '',
      // one row per source line, so the text is the rows joined —
      // `pre.textContent` has no newlines to give any more
      code: rows.map((r) => r.textContent).join('\n'),
      // and the browser's own serialisation (what a user's select+copy gets)
      innerText: pre ? pre.innerText : '',
      whiteSpace: rows[0] && getComputedStyle(rows[0]).whiteSpace,
      font: cs?.fontFamily,
      preScrolls: pre ? pre.scrollWidth > pre.clientWidth : false,
      inline: [...a.querySelectorAll('.msg-para code')].map((c) => c.textContent),
      imgs: a.querySelectorAll('.msg-body img').length,
      scripts: a.querySelectorAll('.msg-body script').length,
      paraText: a.querySelector('.msg-para')?.textContent || '',
    }
  })
  step('one code block, label js, exact text, whitespace kept', got.blocks === 1 && got.lang === 'js' && got.code === expectedCode && got.whiteSpace === 'pre-wrap',
    { blocks: got.blocks, lang: got.lang, exact: got.code === expectedCode, whiteSpace: got.whiteSpace, font: got.font })
  step('select-and-copy still yields the lines (block rows serialise with newlines)', got.innerText.trim() === expectedCode.trim(), { exact: got.innerText.trim() === expectedCode.trim() })
  step('inline `code` styled', got.inline.includes('inline'), { inline: got.inline })
  // (owner 2026-09-19) REVERSES what this step asserted on 4c204d0:
  // a 400-character line now WRAPS, so neither the block nor the page scrolls
  step('the long line wraps: neither the block nor the page scrolls sideways', !got.preScrolls && (await xscroll(p)) <= 0, { preScrolls: got.preScrolls, xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/feed-code-block-desktop.png` })

  const copyBtn = await el.$('[data-testid=code-copy]')
  const before = await copyBtn.evaluate((b) => b.textContent.trim())
  await copyBtn.click()
  await sleep(300)
  const clip = await p.evaluate(() => navigator.clipboard.readText())
  const label = await copyBtn.evaluate((b) => b.textContent.trim())
  // the label is translated (the member's locale), so assert that it flipped
  step('copy button puts exactly the code on the clipboard', clip === expectedCode && label !== before && label.length > 0, { exact: clip === expectedCode, before, label })
  await p.screenshot({ path: `${OUT}/feed-copied.png` })

  await p.setViewport({ width: 390, height: 844 })
  await sleep(700)
  await el.evaluate((a) => a.scrollIntoView({ block: 'center' }))
  step('mobile: no document x-scroll with the block on screen', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/feed-code-block-mobile.png` })

  await sleep(1000)
  const csp = await p.evaluate(() => window.__csp)
  step('CONTROL: payload inside and outside the block never executes, 0 CSP violations',
    dialogs.length === 0 && got.imgs === 0 && got.scripts === 0 && got.paraText.includes('<script>') && csp.length === 0,
    { dialogs, imgs: got.imgs, scripts: got.scripts, payloadShownAsText: got.paraText.includes('<script>'), csp })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
