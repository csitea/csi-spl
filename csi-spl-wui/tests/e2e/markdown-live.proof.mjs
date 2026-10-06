// SPL-73 live proof of markdown between the start/stop marker (a fence
// tagged md) against a deployed WUI: native sign-in, send ONE message to
// /lobby that holds plain text with a link OUTSIDE the marker and, inside it,
// a heading, lists, a wide table, links (safe and hostile), an image and raw
// HTML. The card must show the rendered block (h / ul / ol / table), every
// href http/https/mailto with rel noopener noreferrer, no <img>, <script>,
// <iframe> or on* anywhere in the body, the table scrolling inside the block
// and never the page, in all 5 themes and at font levels 1 and 5, on desktop
// and mobile; Show source flips to the text as written; 0 CSP violations and
// no dialog. Screenshots and results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/markdown-live.proof.mjs
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
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)

const THEMES = ['dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']
const nonce = 'md' + Date.now().toString(36)
const wide = Array.from({ length: 12 }, (_, i) => `column-${i}-wide-header`)
const body = [
  `markdown proof ${nonce}, outside the marker: https://example.com stays a link`,
  '```md',
  `## Plan ${nonce}`,
  '',
  '- one **bold**',
  '- two _em_ ~~gone~~ `code`',
  '',
  '1. first',
  '2. second',
  '',
  '| ' + wide.join(' | ') + ' |',
  '|' + wide.map(() => '---').join('|') + '|',
  '| ' + wide.map((_, i) => `cell ${i}`).join(' | ') + ' |',
  '',
  '> a quote',
  '',
  '[safe](https://example.com/docs) [hostile](javascript:alert(1)) [data](data:text/html,x) <mail@example.com>',
  '',
  '![pixel](https://tracker.example/p.gif)',
  '',
  '<script>alert(1)</script><img src=x onerror=alert(1)><iframe src="https://example.com"></iframe>',
  '```',
].join('\n')

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const dialogs = []
try {
  const build = await (await fetch(BASE + '/build.json')).json()
  res.build = build
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.on('dialog', async (d) => { dialogs.push(d.message()); await d.dismiss() })
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    // the full card, so the screenshots show the whole block (card clip)
    try {
      localStorage.setItem('spool-card-clip-default', 'full')
      localStorage.setItem('spool-card-clip-default-thread', 'full')
      sessionStorage.setItem('spool-card-clip-session-msgs', 'full')
      sessionStorage.setItem('spool-card-clip-session-thread', 'full')
    } catch { /* private mode */ }
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

  // the whole body at once: typing ``` would drive the composer's code mode
  const ta = await p.waitForSelector('form.composer textarea')
  await ta.focus()
  await ta.evaluate((e, v) => {
    const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set
    set.call(e, v)
    e.dispatchEvent(new Event('input', { bubbles: true }))
  }, body)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')

  const card = await p.waitForFunction((n) => [...document.querySelectorAll('article.msg')].find((a) => a.textContent.includes(n)), { timeout: 20000 }, nonce).catch(() => null)
  step('Ctrl+Enter sends; the card appears in the feed', !!card, {})
  if (!card) throw new Error('card not found')
  const el = card.asElement()
  await p.waitForFunction((a) => a.querySelector('.md-block[data-rendered="true"]'), { timeout: 15000 }, el).catch(() => null)
  await el.evaluate((a) => a.scrollIntoView({ block: 'start' }))
  await sleep(500)
  const got = await el.evaluate((a) => {
    const b = a.querySelector('.md-block')
    const all = [...a.querySelectorAll('.msg-body *')]
    const wrap = b?.querySelector('.md-table')
    return {
      rendered: b?.dataset.rendered,
      heading: b?.querySelector('h2')?.textContent || '',
      ul: b?.querySelectorAll('ul > li').length || 0,
      ol: b?.querySelectorAll('ol > li').length || 0,
      ths: b?.querySelectorAll('table th').length || 0,
      tds: b?.querySelectorAll('table td').length || 0,
      quote: !!b?.querySelector('blockquote'),
      strong: b?.querySelector('strong')?.textContent || '',
      mdLinks: [...(b?.querySelectorAll('a') || [])].map((x) => ({ href: x.getAttribute('href'), rel: x.rel, target: x.target, text: x.textContent })),
      outsideLink: [...a.querySelectorAll('.msg-para a')].map((x) => x.getAttribute('href')),
      banned: all.filter((x) => /^(IMG|SCRIPT|IFRAME|OBJECT|EMBED|SVG|STYLE)$/i.test(x.tagName)).length,
      onAttrs: all.filter((x) => [...x.attributes].some((at) => /^on/i.test(at.name) || at.name === 'style')).map((x) => x.tagName),
      rawShownAsText: (b?.textContent || '').includes('<script>alert(1)</script>'),
      tableScrollsInside: wrap ? wrap.scrollWidth > wrap.clientWidth && getComputedStyle(wrap).overflowX === 'auto' : false,
      blockWidth: b ? Math.round(b.getBoundingClientRect().width) : 0,
      cardWidth: Math.round(a.getBoundingClientRect().width),
    }
  })
  step('the fence renders as markdown: heading, lists, table, quote, bold',
    got.rendered === 'true' && got.heading.includes(nonce) && got.ul === 2 && got.ol === 2 && got.ths === 12 && got.tds === 12 && got.quote && got.strong === 'bold',
    { rendered: got.rendered, heading: got.heading, ul: got.ul, ol: got.ol, ths: got.ths, tds: got.tds, quote: got.quote })
  const hrefs = got.mdLinks.map((l) => l.href)
  step('links: only http/https/mailto, all rel noopener noreferrer, target _blank; hostile ones are text',
    got.mdLinks.length > 0 && got.mdLinks.every((l) => /^(https?:|mailto:)/.test(l.href) && /noopener/.test(l.rel) && /noreferrer/.test(l.rel) && l.target === '_blank') &&
      hrefs.includes('https://example.com/docs') && hrefs.includes('mailto:mail@example.com'),
    { links: got.mdLinks })
  step('images are not fetched: the picture is a link, no <img>', hrefs.includes('https://tracker.example/p.gif') && got.banned === 0, { banned: got.banned })
  step('raw HTML shows as text; no on*/style attribute anywhere in the body', got.rawShownAsText && got.onAttrs.length === 0, { onAttrs: got.onAttrs })
  step('outside the marker nothing changed: the plain URL is still a link', got.outsideLink.includes('https://example.com'), { outsideLink: got.outsideLink })
  step('the wide table scrolls inside the block; the page does not', got.tableScrollsInside && (await xscroll(p)) <= 0 && got.blockWidth <= got.cardWidth,
    { tableScrollsInside: got.tableScrollsInside, xscroll: await xscroll(p), blockWidth: got.blockWidth, cardWidth: got.cardWidth })

  for (const theme of THEMES) {
    await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
    await sleep(250)
    const c = await el.evaluate((a) => {
      const b = a.querySelector('.md-block')
      const th = b?.querySelector('th')
      const link = b?.querySelector('a')
      return { fg: getComputedStyle(b).color, th: th && getComputedStyle(th).backgroundColor, link: link && getComputedStyle(link).color }
    })
    step(`theme ${theme}: styled from tokens, no page x-scroll`, !!c.th && !!c.link && (await xscroll(p)) <= 0, c)
    await el.evaluate((a) => a.scrollIntoView({ block: 'center' }))
    await el.screenshot({ path: `${OUT}/md-${theme}.png` })
  }
  await p.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'))

  for (const lvl of ['1', '5']) {
    await p.evaluate((n) => document.documentElement.setAttribute('data-font-size', n), lvl)
    await sleep(300)
    const fs = await el.evaluate((a) => parseFloat(getComputedStyle(a.querySelector('.md-block td')).fontSize))
    step(`font level ${lvl}: sizes follow the root, no page x-scroll`, fs > 0 && (await xscroll(p)) <= 0, { tdPx: fs })
    res[`td_px_level_${lvl}`] = fs
    await el.screenshot({ path: `${OUT}/md-font-${lvl}.png` })
  }
  step('font level 5 is larger than level 1', res.td_px_level_5 > res.td_px_level_1, { l1: res.td_px_level_1, l5: res.td_px_level_5 })
  await p.evaluate(() => document.documentElement.removeAttribute('data-font-size'))

  const toggle = await el.$('[data-testid=md-block-toggle]')
  await toggle.click()
  await sleep(300)
  const src = await el.evaluate((a) => ({ src: a.querySelector('.md-block .md-src')?.textContent || '', table: !!a.querySelector('.md-block table') }))
  step('Show source flips to the text as written', src.src.includes('| column-0-wide-header') && !src.table, { table: src.table })
  await el.screenshot({ path: `${OUT}/md-source.png` })
  await toggle.click()
  await sleep(300)

  await p.setViewport({ width: 390, height: 844 })
  await sleep(700)
  await el.evaluate((a) => a.scrollIntoView({ block: 'start' }))
  step('mobile: no document x-scroll with the block on screen', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })
  await p.screenshot({ path: `${OUT}/md-mobile.png` })

  await sleep(1000)
  const csp = await p.evaluate(() => window.__csp)
  step('CONTROL: nothing executes, no dialog, 0 CSP violations', dialogs.length === 0 && csp.length === 0, { dialogs, csp })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
