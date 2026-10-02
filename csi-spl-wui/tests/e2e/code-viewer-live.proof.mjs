// CLE-3423 live proof of the code viewer against a deployed WUI (013
// FR-016/017/018). Signs in natively, then in the /lobby Omnibox:
//
//   1. sends a LONG python snippet (over the preview cut, under the send
//      limit) and checks the card shows a BOUNDED preview, says how much is
//      hidden, highlights tokens, and does not scroll sideways at 1280 or 390
//   2. opens the full source with the small ICON control, checks the dialog
//      is modal and focus-trapped, holds every line, highlights, copies, and
//      toggles wrap and line numbers
//   3. closes with Escape and checks focus returns to the control
//   4. types a snippet OVER the 3 A4 limit and checks the send is REFUSED
//      with a message naming the limit, the text is kept, and nothing is sent
//   5. CONTROL: an injected <script>/<img onerror> payload inside and outside
//      the block never executes, 0 dialogs, 0 CSP violations
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/code-viewer-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'

import { PREVIEW_LIMIT, SEND_LIMIT } from '../../src/utils/code-view.mjs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), limits: { preview: { ...PREVIEW_LIMIT }, send: { ...SEND_LIMIT } }, steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)

const nonce = 'cv' + Date.now().toString(36)
const evil = '<script>alert(1)</script><img src=x onerror=alert(1)>'

/** A snippet longer than the preview cut but inside the send limit. */
const BIG_LINES = PREVIEW_LIMIT.lines + 25
const bigBody = Array.from({ length: BIG_LINES }, (_, i) =>
  i === 3 ? `    wide = "${'y'.repeat(300)}"  # one very long line` : `    step_${i} = compute(${i})  # ${nonce}`,
)
const bigCode = [`def pipeline():  # ${nonce}`, ...bigBody.slice(1), `    return "${evil}"`].join('\n')
/**
 * Over the limit on BOTH axes, so either half of the check alone would still
 * catch it: SEND_LIMIT.lines + 20 lines, each padded past
 * SEND_LIMIT.chars / SEND_LIMIT.lines characters.
 */
const PAD = Math.ceil(SEND_LIMIT.chars / SEND_LIMIT.lines) + 10
const overCode = Array.from({ length: SEND_LIMIT.lines + 20 }, (_, i) =>
  `line_${i} = ${i}`.padEnd(PAD, '_'),
).join('\n')

/** Type into the focused textarea in one shot; execCommand fires `input`, so v-model follows. */
const insert = (p, text) => p.evaluate((t) => { document.execCommand('insertText', false, t) }, text)

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const dialogs = []
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const ctx = await browser.createBrowserContext()
  await ctx.overridePermissions(BASE, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write'])
  const p = await ctx.newPage()
  p.on('dialog', async (d) => { dialogs.push(d.message()); await d.dismiss() })
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`))
  })
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('not signed in')
  await sleep(2500)

  /* ---- 1. a long snippet: bounded preview, no sideways scroll ---- */
  const ta = await p.waitForSelector('form.composer textarea')
  await ta.focus()
  await insert(p, `viewer proof ${nonce} ${evil}\n\`\`\`python\n${bigCode}\n\`\`\``)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')

  const card = await p.waitForFunction(
    (n) => [...document.querySelectorAll('article.msg')].find((a) => a.textContent.includes(n)),
    { timeout: 20000 }, nonce,
  ).catch(() => null)
  step('the long snippet sends and the card appears', !!card, {})
  if (!card) throw new Error('card not found')
  const el = card.asElement()
  await el.evaluate((a) => a.scrollIntoView({ block: 'center' }))
  await sleep(900)

  const preview = await el.evaluate((a) => {
    const rows = [...a.querySelectorAll('.code-block .code-line')]
    const pre = a.querySelector('.code-block pre')
    return {
      rows: rows.length,
      lang: a.querySelector('.code-lang')?.textContent.trim() || '',
      cut: a.querySelector('[data-testid=code-cut]')?.textContent.trim() || '',
      hasOpenIcon: !!a.querySelector('[data-testid=code-open] svg'),
      hasExpand: !!a.querySelector('[data-testid=code-expand]'),
      tokens: a.querySelectorAll('.code-block .code-src span[class*="hljs-"]').length,
      blockScrolls: pre ? pre.scrollWidth > pre.clientWidth : false,
      paraText: a.querySelector('.msg-para')?.textContent || '',
      imgs: a.querySelectorAll('.msg-body img').length,
      scripts: a.querySelectorAll('.msg-body script').length,
    }
  })
  step('the card shows a BOUNDED preview, not the whole snippet',
    preview.rows > 0 && preview.rows <= PREVIEW_LIMIT.lines && preview.rows < BIG_LINES,
    { rows: preview.rows, previewLimit: PREVIEW_LIMIT.lines, total: BIG_LINES })
  step('it says how much is hidden and offers BOTH an icon open and an explicit button',
    preview.cut.length > 0 && preview.hasOpenIcon && preview.hasExpand, { cut: preview.cut, icon: preview.hasOpenIcon, button: preview.hasExpand })
  step('the snippet is syntax highlighted (python grammar loaded lazily)', preview.lang === 'python' && preview.tokens > 5, { lang: preview.lang, tokens: preview.tokens })
  step('a 300-character line wraps: neither the block nor the page scrolls sideways',
    !preview.blockScrolls && (await xscroll(p)) <= 0, { blockScrolls: preview.blockScrolls, xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/card-preview-desktop.png` })

  await p.setViewport({ width: 390, height: 844 })
  await sleep(700)
  await el.evaluate((a) => a.scrollIntoView({ block: 'center' }))
  step('mobile 390: still no document x-scroll', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/card-preview-mobile.png` })
  await p.setViewport({ width: 1280, height: 800 })
  await sleep(500)

  /* ---- 2. the dialog ---- */
  await el.evaluate((a) => a.scrollIntoView({ block: 'center' }))
  await (await el.$('[data-testid=code-open]')).click()
  await p.waitForSelector('[data-testid=ui-dialog]', { timeout: 10000 })
  await sleep(900)
  const dlg = await p.evaluate(() => {
    const d = document.querySelector('[data-testid=ui-dialog]')
    const rows = [...d.querySelectorAll('.code-line .code-src')]
    return {
      modal: d.getAttribute('aria-modal'),
      labelled: !!document.getElementById(d.getAttribute('aria-labelledby')),
      teleported: d.closest('article.msg') === null,
      focusInside: d.contains(document.activeElement),
      rows: rows.length,
      text: rows.map((r) => r.textContent).join('\n'),
      numbers: d.querySelectorAll('.code-ln').length,
      tokens: d.querySelectorAll('.code-src span[class*="hljs-"]').length,
      bodyScrolls: (() => { const b = d.querySelector('[data-testid=ui-dialog-body]'); return b.scrollHeight > b.clientHeight })(),
      pageLocked: getComputedStyle(document.documentElement).overflow === 'hidden',
    }
  })
  step('the dialog is modal, labelled, teleported out of the card and takes focus',
    dlg.modal === 'true' && dlg.labelled && dlg.teleported && dlg.focusInside, dlg && { modal: dlg.modal, labelled: dlg.labelled, teleported: dlg.teleported, focusInside: dlg.focusInside })
  step('it holds the WHOLE source, with line numbers and highlighting',
    dlg.rows === bigCode.split('\n').length && dlg.text === bigCode && dlg.numbers === dlg.rows && dlg.tokens > 5,
    { rows: dlg.rows, expected: bigCode.split('\n').length, exact: dlg.text === bigCode, numbers: dlg.numbers, tokens: dlg.tokens })
  step('the dialog body scrolls, the page behind it does not', dlg.bodyScrolls && dlg.pageLocked && (await xscroll(p)) <= 0,
    { bodyScrolls: dlg.bodyScrolls, pageLocked: dlg.pageLocked, xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/dialog-full-source.png` })

  // the focus trap: Tab round the end of the dialog stays inside it
  for (let i = 0; i < 12; i++) await p.keyboard.press('Tab')
  const trapped = await p.evaluate(() => document.querySelector('[data-testid=ui-dialog]').contains(document.activeElement))
  step('Tab cannot leave the dialog (focus trap)', trapped, { trapped })

  const beforeWrap = await p.$eval('[data-testid=code-viewer-lines]', (e) => e.className)
  await p.click('[data-testid=code-wrap]')
  await sleep(300)
  const afterWrap = await p.$eval('[data-testid=code-viewer-lines]', (e) => e.className)
  step('the wrap toggle works and the PAGE still does not scroll sideways',
    beforeWrap !== afterWrap && afterWrap.includes('no-wrap') && (await xscroll(p)) <= 0, { beforeWrap, afterWrap, xscroll: await xscroll(p) })
  await p.click('[data-testid=code-wrap]')
  await sleep(200)

  const numsBefore = await p.$$eval('[data-testid=ui-dialog] .code-ln', (n) => n.length)
  await p.click('[data-testid=code-numbers]')
  await sleep(300)
  const numsAfter = await p.$$eval('[data-testid=ui-dialog] .code-ln', (n) => n.length)
  step('the line-number toggle works', numsBefore > 0 && numsAfter === 0, { numsBefore, numsAfter })
  await p.click('[data-testid=code-numbers]')
  await sleep(200)

  await p.click('[data-testid=code-viewer-copy]')
  await sleep(400)
  const clip = await p.evaluate(() => navigator.clipboard.readText())
  step('copy in the dialog puts exactly the source on the clipboard', clip === bigCode, { exact: clip === bigCode, got: clip.length, want: bigCode.length })
  await p.screenshot({ path: `${OUT}/dialog-copied.png` })

  /* ---- 3. Escape closes and focus comes back ---- */
  await p.keyboard.press('Escape')
  await sleep(500)
  const closed = await p.evaluate(() => ({
    gone: !document.querySelector('[data-testid=ui-dialog]'),
    back: document.activeElement?.getAttribute('data-testid') || '',
    unlocked: getComputedStyle(document.documentElement).overflow !== 'hidden',
  }))
  step('Escape closes the dialog, unlocks the page and restores focus to the open control',
    closed.gone && closed.back === 'code-open' && closed.unlocked, closed)

  /* ---- 4. the send-time 3 A4 refusal ---- */
  const ta2 = await p.waitForSelector('form.composer textarea')
  await ta2.focus()
  await insert(p, '```\n' + overCode + '\n```')
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
  await sleep(1200)
  const refused = await p.evaluate(() => {
    const n = document.querySelector('[data-testid=composer-too-big]')
    const t = document.querySelector('form.composer textarea')
    return { shown: !!n, msg: n ? n.textContent.trim() : '', role: n?.getAttribute('role') || '', kept: (t?.value || '').length }
  })
  const sentAnyway = await p.evaluate((n) => [...document.querySelectorAll('article.msg')].filter((a) => a.textContent.includes(n)).length, 'line_0 = 0')
  step('a snippet over 3 A4 is REFUSED at send, with an alert naming the limit',
    refused.shown && refused.role === 'alert' && refused.msg.includes(String(SEND_LIMIT.lines)) && refused.msg.includes(String(SEND_LIMIT.chars)),
    { shown: refused.shown, role: refused.role, msg: refused.msg })
  step('CONTROL: the fixture is over the limit on BOTH axes, so neither half alone carries the pass',
    overCode.split('\n').length > SEND_LIMIT.lines && overCode.length > SEND_LIMIT.chars,
    { lines: overCode.split('\n').length, chars: overCode.length, limit: { ...SEND_LIMIT } })
  step('nothing is sent and the text is kept so it can be attached instead',
    sentAnyway === 0 && refused.kept >= overCode.length, { sent: sentAnyway, kept: refused.kept, typed: overCode.length })
  step('the refusal does not make the page scroll sideways', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/composer-refused.png` })

  /* ---- 5. CONTROL ---- */
  await sleep(800)
  const csp = await p.evaluate(() => window.__csp)
  step('CONTROL: the payload never executes, 0 dialogs, 0 CSP violations',
    dialogs.length === 0 && preview.imgs === 0 && preview.scripts === 0 && preview.paraText.includes('<script>') && csp.length === 0,
    { dialogs, imgs: preview.imgs, scripts: preview.scripts, payloadShownAsText: preview.paraText.includes('<script>'), csp })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
