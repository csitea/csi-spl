// SPL-975 live proof against a deployed WUI (owner, topic 467d6325): markdown
// renders WITHOUT a fence, and an issue description is rendered markdown that
// a click or `e` edits and a click elsewhere saves.
//
//  A. /lobby: three messages. (1) unfenced markdown: heading, bold, nested
//     list, GFM table, HTML table, quote, code block, link, a mention and
//     hostile HTML; (2) a plain one-liner; (3) an old-style ```md fence.
//     (1) renders whole (h2, li, 2 tables, pre, blockquote, the mention chip),
//     with no <script>/<img>/<iframe>, no on* / style attribute, raw HTML as
//     text; (2) stays a plain paragraph with no markdown block; (3) keeps its
//     Show source control and its table.
//  B. /issues: create an issue with a markdown description (a new issue's
//     editor is open), then the rendered view shows h2 / table / li; a click
//     opens the editor with the raw text; a click elsewhere saves it (the hub
//     reads the new text) and shows the view again; after a reload it is
//     still there; `e` opens the editor, Esc closes it unchanged.
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> TENANT=<tenant>
//     EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [CHROME_PATH=...]
//     [PUPPETEER_CORE=<path>] node tests/e2e/markdown-unfenced-live.proof.mjs
//
// It refuses to write unless the session's tenant AND the page host's tenant
// are TENANT (the issues-live.proof.mjs guard). The password is read from
// PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const TENANT = need('TENANT')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [], console: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
async function until(fn, ms) {
  const end = Date.now() + ms
  for (;;) {
    const v = await fn().catch(() => null)
    if (v || Date.now() > end) return v
    await sleep(400)
  }
}
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const run = 'u' + Date.now().toString(36)

const unfenced = [
  `## Unfenced proof ${run}`,
  '',
  'Deployed **0.9.3**, see [the doc](https://example.com/docs) and ask @CLE-35016.',
  '',
  '- one',
  '  - nested',
  '- two',
  '',
  '| env | sha |',
  '|-----|----:|',
  '| dev | 1 |',
  '',
  '<table><tr><th>html</th></tr><tr><td onclick="alert(1)" style="color:red">cell<script>alert(1)</script><img src=x onerror=alert(1)></td></tr></table>',
  '',
  '> quoted',
  '',
  '```bash',
  'ls -la',
  '```',
  '',
  'raw <iframe src="https://example.com"></iframe> stays text',
].join('\n')
const oneLiner = `plain one-liner ${run} with **bold** and https://example.com`
const fenced = [`fenced proof ${run}`, '```md', '| a | b |', '|---|---|', '| 1 | 2 |', '```'].join('\n')

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  p.on('dialog', async (d) => { res.console.push('dialog: ' + d.message()); await d.dismiss() })
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    try {
      localStorage.setItem('spool-card-clip-default', 'full')
      sessionStorage.setItem('spool-card-clip-session-msgs', 'full')
    } catch { /* private mode */ }
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`))
  })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  const where = await until(() => p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const g = app && app.config.globalProperties
    const s = g && g.$pinia && g.$pinia.state.value.session
    const pub = (g && g.$config && g.$config.public) || null
    if (!pub || !s || !s.claims) return null
    const hosts = String(pub.tenantHosts || '0') === '1'
    let page = ''
    if (hosts) {
      const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
      const h = location.hostname.toLowerCase()
      page = h === site ? String(pub.tenant || '') : h.endsWith('.' + site) ? h.slice(0, -site.length - 1) : '?'
    }
    return { claim: String(s.claims.t || ''), hosts, page }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}

async function send(p, body) {
  const ta = await p.waitForSelector('form.composer textarea', { timeout: 30000 })
  await ta.focus()
  await ta.evaluate((e, v) => {
    const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set
    set.call(e, v)
    e.dispatchEvent(new Event('input', { bubbles: true }))
  }, body)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
  await sleep(1500)
}

async function card(p, needle) {
  const h = await p.waitForFunction((n) => [...document.querySelectorAll('article.msg')].find((a) => a.textContent.includes(n)), { timeout: 20000 }, needle).catch(() => null)
  return h && h.asElement()
}

const hubIssue = (p, key) => p.evaluate(async (api, k) => {
  const r = await fetch(`${api}/v1/view/issues/${k}`, { credentials: 'include' })
  return r.ok ? (await r.json()).issue : { status_code: r.status }
}, API, key)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await signIn(browser)
  await sleep(2000)

  // A. messages
  await send(p, unfenced)
  await send(p, oneLiner)
  await send(p, fenced)
  const a1 = await card(p, `Unfenced proof ${run}`)
  if (a1) await p.waitForFunction((a) => a.querySelector('.md-block[data-rendered="true"]'), { timeout: 15000 }, a1).catch(() => null)
  const g1 = a1 && await a1.evaluate((a) => {
    const b = a.querySelector('.msg-body')
    const all = [...b.querySelectorAll('*')]
    return {
      h2: b.querySelector('h2')?.textContent || '',
      strong: b.querySelector('strong')?.textContent || '',
      li: b.querySelectorAll('li').length,
      nested: b.querySelectorAll('li ul li').length,
      tables: b.querySelectorAll('table').length,
      htmlTh: [...b.querySelectorAll('th')].map((x) => x.textContent.trim()),
      rightAligned: !!b.querySelector('td[data-align="right"]'),
      pre: !!b.querySelector('pre, .code-block'),
      quote: !!b.querySelector('blockquote'),
      mention: [...b.querySelectorAll('.mention')].map((x) => x.textContent.trim()),
      link: [...b.querySelectorAll('a')].map((x) => x.getAttribute('href')),
      toggle: !!b.querySelector('[data-testid=md-block-toggle]'),
      banned: all.filter((x) => /^(IMG|SCRIPT|IFRAME|OBJECT|EMBED|STYLE)$/i.test(x.tagName)).length,
      onAttrs: all.filter((x) => [...x.attributes].some((at) => /^on/i.test(at.name) || (at.name === 'style' && x.closest('table')))).map((x) => x.tagName),
      rawText: b.textContent.includes('<iframe'),
    }
  })
  step('A1 unfenced markdown renders: h2, bold, nested list, GFM + HTML table, quote, code, link, mention',
    !!g1 && g1.h2.includes(run) && g1.strong === '0.9.3' && g1.li === 3 && g1.nested === 1 && g1.tables === 2 && g1.htmlTh.includes('html') &&
      g1.rightAligned && g1.pre && g1.quote && g1.link.includes('https://example.com/docs') && g1.mention.length === 1 && !g1.toggle, g1 || {})
  step('A1 hostile HTML never becomes markup: no script/img/iframe, no on*/style in the table, raw tag shown as text',
    !!g1 && g1.banned === 0 && g1.onAttrs.length === 0 && g1.rawText, g1 ? { banned: g1.banned, onAttrs: g1.onAttrs, rawText: g1.rawText } : {})
  if (a1) { await a1.evaluate((a) => a.scrollIntoView({ block: 'start' })); await sleep(300); await a1.screenshot({ path: `${OUT}/A1-unfenced.png` }) }

  const a2 = await card(p, `plain one-liner ${run}`)
  const g2 = a2 && await a2.evaluate((a) => ({ md: !!a.querySelector('.md-block'), para: !!a.querySelector('.msg-para'), strong: a.querySelector('.msg-body strong')?.textContent || '', link: !!a.querySelector('.msg-body a') }))
  step('A2 a plain one-liner does not change: a paragraph, bold and link as before, no markdown block', !!g2 && !g2.md && g2.para && g2.strong === 'bold' && g2.link, g2 || {})

  const a3 = await card(p, `fenced proof ${run}`)
  if (a3) await p.waitForFunction((a) => a.querySelector('.md-block[data-rendered="true"]'), { timeout: 15000 }, a3).catch(() => null)
  const g3 = a3 && await a3.evaluate((a) => ({ toggle: !!a.querySelector('[data-testid=md-block-toggle]'), table: !!a.querySelector('.md-block table'), para: a.querySelector('.msg-para')?.textContent || '' }))
  step('A3 an old ```md fence still renders, with its Show source control', !!g3 && g3.toggle && g3.table && g3.para.includes(run), g3 || {})
  step('A no page x-scroll', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })

  // B. issue description
  await p.click('[data-testid=sidebar-tab-issues]')
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: 30000 })
  await sleep(1500)
  const title = `SPL-975 proof ${run}`
  const descr = `## Scope ${run}\n\n- **bold** item\n- second\n\n| k | v |\n|---|---|\n| a | 1 |`
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-detail-title]', { clickCount: 3 })
  await p.type('[data-test=issues-detail-title]', title)
  const newEditor = await p.$('[data-test=issues-detail-body]')
  step('B0 a new issue shows the description editor directly', !!newEditor)
  await newEditor.evaluate((e, v) => {
    const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set
    set.call(e, v)
    e.dispatchEvent(new Event('input', { bubbles: true }))
  }, descr)
  await p.click('[data-test=issues-create]')
  const key = await until(() => p.evaluate((want) => {
    const t = document.querySelector('[data-test=issues-detail-title]')
    const k = document.querySelector('[data-test=issues-detail-key]')
    const creating = !!document.querySelector('[data-test=issues-create]')
    return !creating && t && t.value === want && k && /^[A-Z][A-Z0-9]*-\d+$/.test(k.textContent.trim()) ? k.textContent.trim() : ''
  }, title), 30000)
  step('B1 created, the hub gave it a key', !!key, { key })
  if (!key) throw new Error('no key')
  res.issue = key

  const view = () => p.evaluate(() => {
    const v = document.querySelector('[data-test=issues-detail-rendered]')
    if (!v) return { view: false, editor: !!document.querySelector('[data-test=issues-detail-body]') }
    return {
      view: true,
      rendered: v.querySelector('.md-block')?.dataset.rendered || '',
      h2: v.querySelector('h2')?.textContent || '',
      li: v.querySelectorAll('li').length,
      table: !!v.querySelector('table'),
      strong: v.querySelector('strong')?.textContent || '',
      text: v.textContent,
      editor: !!document.querySelector('[data-test=issues-detail-body]'),
    }
  })
  await until(async () => (await view()).rendered === 'true', 15000)
  const v1 = await view()
  step('B2 the description shows RENDERED markdown (h2, bold list, table), no raw textarea', v1.view && v1.h2 === `Scope ${run}` && v1.li === 2 && v1.table && v1.strong === 'bold' && !v1.editor, v1)
  await p.screenshot({ path: `${OUT}/B2-description-rendered.png` })

  await p.click('[data-test=issues-detail-rendered] li')
  const ed = await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 }).catch(() => null)
  const raw = ed && await ed.evaluate((e) => ({ value: e.value, focused: document.activeElement === e }))
  step('B3 a click opens the editor with the RAW text, focused', !!raw && raw.value === descr && raw.focused, raw || {})
  await p.screenshot({ path: `${OUT}/B3-description-editor.png` })

  const added = `\n\n> edited ${run}`
  await p.keyboard.down('Control'); await p.keyboard.press('End'); await p.keyboard.up('Control')
  await p.keyboard.type(added)
  await p.click('[data-test=issues-detail-key]')
  const back = await until(async () => { const v = await view(); return v.view && v.rendered === 'true' && v.text.includes(`edited ${run}`) ? v : null }, 15000)
  const stored = await until(async () => { const i = await hubIssue(p, key); return i && i.description === descr + added ? i : null }, 15000)
  step('B4 a click elsewhere saves to the hub and shows the rendered view again', !!back && !!stored, { view: !!back, stored: !!stored })
  const err = await p.$('[data-test=issues-description-error]')
  step('B4b no save error shown after a good save', !err)

  await p.goto(BASE + `/issues?issue=${key}`, { waitUntil: 'networkidle2', timeout: 60000 })
  const after = await until(async () => { const v = await view(); return v.view && v.rendered === 'true' && v.text.includes(`edited ${run}`) ? v : null }, 20000)
  step('B5 after a reload the saved description renders (quote included)', !!after && after.h2 === `Scope ${run}`, after || {})
  await p.screenshot({ path: `${OUT}/B5-after-reload.png` })

  await p.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur() })
  await p.keyboard.press('e')
  const byE = await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 }).then(() => true, () => false)
  step('B6 the e shortcut opens the editor', byE)
  await p.keyboard.press('Escape')
  const closed = await until(async () => { const v = await view(); return v.view && !v.editor ? v : null }, 5000)
  step('B7 Esc leaves the editor; nothing changed, the view is back', !!closed)

  await sleep(800)
  const csp = await p.evaluate(() => window.__csp)
  step('CONTROL: no dialog, 0 CSP violations', !res.console.some((c) => c.startsWith('dialog:')) && csp.length === 0, { csp })
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}; issue ${res.issue || '-'}`)
process.exit(bad ? 1 : 0)
