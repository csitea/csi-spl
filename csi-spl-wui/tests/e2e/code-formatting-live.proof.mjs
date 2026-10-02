// the owner asked for code formatting on ``` a second time. This is
// the proof, against a DEPLOYED WUI, of the two things that were wrong and of
// the things that were already right, in the view the owner actually uses:
// the DM with their agent.
//
// Signed in as a member it checks, on /dm/<peer>:
//   1. the top Omnibox opens a block on ``` and GROWS to hold it
//   2. the TOPIC PANE composer does the same — it used to size itself from
//      rows="2", so a four-line block was a two-line peephole with its own
//      scrollbar (dev a212596: clientHeight 44, scrollHeight 64)
//   3. an UNTAGGED ``` block comes back COLOURED — it used to come back plain,
//      because auto-detect only guessed between grammars the page had already
//      loaded and a fresh DM has loaded none
//   4. a ```bash block comes back coloured, wrapped (no x-scroll anywhere),
//      with the copy and open controls
//   5. an AGENT-SHAPED body — prose, then a fence carrying tabs and CRLF, as
//      a terminal produces — renders as one code block. Every sender goes
//      through the same MessageCard -> MessageBody, which branches on nothing
//   6. CONTROL: prose inside a fence is NOT coloured, and nothing in a body
//      became markup (no dialog, no injected node, 0 CSP violations)
//
// Desktop + phone screenshots and results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [PEER=CLE-00@box-desk] [TENANT=t1] [CHROME_PATH=...] \
//     [PUPPETEER_CORE=<path>] node tests/e2e/code-formatting-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const PEER = process.env.PEER || 'CLE-00@box-desk'
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()

const res = { base: BASE, peer: PEER, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  if (!ok) failed++
  res.steps.push({ name, ok, ...ev })
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
/** a newline that never sends, whether or not the caret sits in a fence */
let shiftEnter = async () => {}
const nonce = 'cf' + Date.now().toString(36)
const OMNI = '[data-test=top-bar-omnibox] textarea'
const PANE = '.topic-pane form.composer textarea, aside form.composer textarea'

/** the shell script every "is it coloured" question is asked about */
const SH = ['#!/bin/bash', 'set -euo pipefail', 'for f in *.log; do', '  echo "$f"', 'done']
const evil = '<script>alert(1)</script><img src=x onerror=alert(1)>'

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
const dialogs = []
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.on('dialog', async (d) => { dialogs.push(d.message()); await d.dismiss() })
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`))
  })
  await p.setViewport({ width: 1440, height: 900 })
  shiftEnter = async () => {
    await p.keyboard.down('Shift')
    await p.keyboard.press('Enter')
    await p.keyboard.up('Shift')
  }
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 40000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('not signed in (a repeated run earns 429 rate_limited)')
  await sleep(2500)

  const dm = `${BASE}/dm/${encodeURIComponent(PEER)}`
  await p.goto(dm, { waitUntil: 'networkidle2' })
  await sleep(3000)

  /**
   * Type `tag` then `lines` into the composer at `sel`, as a person would.
   *
   * Line breaks are SHIFT+Enter throughout. A bare Enter is also a newline
   * now (owner, 2026-09-23); Ctrl+Enter or Cmd+Enter is what sends. Shift+Enter
   * stays a newline in both states, so one rule still covers the whole body.
   *
   * A tab goes in with sendCharacter, which inserts the character; typing it
   * with keyboard.type presses the Tab KEY and moves focus out of the box.
   */
  async function compose(sel, tag, lines) {
    const ta = await p.waitForSelector(sel)
    await ta.focus()
    await p.keyboard.type(`${tag} `)
    for (const [i, line] of lines.entries()) {
      const pieces = line.split('\t')
      for (const [k, piece] of pieces.entries()) {
        if (k) await p.keyboard.sendCharacter('\t')
        if (piece) await p.keyboard.type(piece)
      }
      if (i < lines.length - 1) {
        await p.keyboard.down('Shift')
        await p.keyboard.press('Enter')
        await p.keyboard.up('Shift')
      }
    }
    return ta
  }
  async function sendAndRead(tag) {
    await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
    await sleep(4500)
    return p.evaluate((t) => {
      const hit = [...document.querySelectorAll('.msg-body')].find((a) => a.textContent.includes(t))
      if (!hit) return { found: false }
      const cb = hit.querySelector('.code-block')
      const spans = cb ? [...cb.querySelectorAll('span[class*="hljs-"]')] : []
      // the <pre> is the scroll box; a .code-line is an inline span and would
      // report 0 whatever happened
      const pre = cb?.querySelector('pre.code-lines')
      const widest = pre ? pre.scrollWidth - pre.clientWidth : 0
      return {
        found: true,
        hasCodeBlock: !!cb,
        coloured: spans.length,
        classes: [...new Set(spans.map((s) => s.className))].slice(0, 6),
        lang: cb?.querySelector('.code-lang')?.textContent.trim() || '',
        hasCopy: !!cb?.querySelector('[data-testid=code-copy]'),
        hasOpen: !!cb?.querySelector('[data-testid=code-open]'),
        text: cb ? cb.textContent : '',
        rowXScroll: widest,
        injected: hit.querySelectorAll('script, img').length,
      }
    }, tag)
  }
  const grew = (el) => el.evaluate((e) => ({
    clientH: e.clientHeight, scrollH: e.scrollHeight, clipped: e.scrollHeight > e.clientHeight + 2,
  }))

  // ---- 1. the Omnibox: opens a block and grows to hold it -------------------
  const tagA = `omnibox ${nonce}`
  let ta = await compose(OMNI, tagA, ['```bash', ...SH])
  const openA = await ta.evaluate((e) => ({ cls: e.className, font: getComputedStyle(e).fontFamily }))
  const growA = await grew(ta)
  step('Omnibox: ``` opens a monospace block', /in-code/.test(openA.cls) && /mono/i.test(openA.font), openA)
  step('Omnibox: the box grew to hold the block', !growA.clipped, growA)
  await p.screenshot({ path: `${OUT}/1-omnibox-composer.png` })
  await shiftEnter(); await p.keyboard.type('```')
  const cardA = await sendAndRead(tagA)
  step('Omnibox: sent ```bash is a coloured code block', Boolean(cardA.hasCodeBlock && cardA.coloured > 0), cardA)
  step('Omnibox: it wraps instead of scrolling sideways', cardA.rowXScroll === 0, { rowXScroll: cardA.rowXScroll })
  step('Omnibox: copy and open controls are on it', Boolean(cardA.hasCopy && cardA.hasOpen), { copy: cardA.hasCopy, open: cardA.hasOpen })

  // ---- 2. an UNTAGGED block is coloured too ---------------------------------
  const tagB = `untagged ${nonce}`
  await compose(OMNI, tagB, ['```', ...SH])
  await shiftEnter(); await p.keyboard.type('```')
  const cardB = await sendAndRead(tagB)
  step('UNTAGGED ``` is auto-detected and coloured', Boolean(cardB.hasCodeBlock && cardB.coloured > 0), cardB)
  step('UNTAGGED colours as much as the tagged one did', cardB.coloured >= cardA.coloured, {
    untagged: cardB.coloured, tagged: cardA.coloured,
  })

  // ---- 3. CONTROL: prose in a fence stays plain -----------------------------
  const tagC = `prose ${nonce}`
  await compose(OMNI, tagC, ['```', 'the quick brown fox jumps over the lazy dog and then goes home'])
  await shiftEnter(); await p.keyboard.type('```')
  const cardC = await sendAndRead(tagC)
  step('CONTROL: prose in a fence is a block but is NOT coloured', Boolean(cardC.hasCodeBlock) && cardC.coloured === 0, cardC)

  // ---- 4. an AGENT-SHAPED body: prose, then a fence with tabs ---------------
  // MessageCard renders every sender through the same MessageBody and branches
  // on neither `from` nor `kind`, so what varies between a human and an agent
  // is only the body text a terminal produces: prose, a fence, hard tabs.
  const tagD = `agentshape ${nonce}`
  await compose(OMNI, tagD, ['here is the failing step:', '```', '\tif err != nil {', '\t\treturn err', '\t}'])
  await shiftEnter(); await p.keyboard.type('```')
  const cardD = await sendAndRead(tagD)
  step('an agent-shaped body (prose + fence + tabs) renders as one code block', Boolean(cardD.hasCodeBlock), cardD)
  step('the tabs survive into the block', /\t/.test(cardD.text), { hasTab: /\t/.test(cardD.text) })

  // ---- 5. the TOPIC PANE composer: the peephole ---------------------------
  await p.goto(dm, { waitUntil: 'networkidle2' })
  await sleep(3000)
  const row = await p.$('.live-rows article, .live-rows [data-key]')
  step('a feed row opens its topic', !!row)
  if (row) {
    await row.click()
    await sleep(2500)
    const tagE = `topicpane ${nonce}`
    const taE = await compose(PANE, tagE, ['```bash', ...SH])
    const growE = await grew(taE)
    step('TOPIC PANE: the box grew to hold the block (was a 2-line peephole)', !growE.clipped, growE)
    await p.screenshot({ path: `${OUT}/2-topic-pane-composer.png` })
    await shiftEnter(); await p.keyboard.type('```')
    const cardE = await sendAndRead(tagE)
    step('TOPIC PANE: the reply renders as a coloured code block', Boolean(cardE.hasCodeBlock && cardE.coloured > 0), cardE)
  }

  // ---- 6. CONTROLS ---------------------------------------------------------
  await p.goto(dm, { waitUntil: 'networkidle2' })
  await sleep(3500)
  await p.screenshot({ path: `${OUT}/3-dm-code-blocks.png` })
  const xscroll = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  step('the page never scrolls sideways', xscroll === 0, { xscroll })
  await p.setViewport({ width: 390, height: 844 })
  await sleep(1500)
  const xsPhone = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  await p.screenshot({ path: `${OUT}/4-dm-phone.png` })
  step('nor on a phone', xsPhone === 0, { xscroll: xsPhone })
  await p.setViewport({ width: 1440, height: 900 })

  // the XSS payload went through the Omnibox in none of the bodies above, so
  // send one now and read the body back as a tree, not as text
  const tagF = `xss ${nonce}`
  await compose(OMNI, tagF, ['```', evil])
  await shiftEnter(); await p.keyboard.type('```')
  const cardF = await sendAndRead(tagF)
  step('CONTROL: nothing in a body became markup', cardF.injected === 0 && dialogs.length === 0, {
    injected: cardF.injected, dialogs,
  })
  const csp = await p.evaluate(() => window.__csp || [])
  step('CONTROL: 0 CSP violations', csp.length === 0, { csp })
  res.csp = csp
} catch (e) {
  failed++
  res.fatal = String(e)
  console.error('FATAL', e)
} finally {
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `\n${failed} step(s) FAILED` : '\nall steps PASS')
  process.exit(failed ? 1 : 0)
}
