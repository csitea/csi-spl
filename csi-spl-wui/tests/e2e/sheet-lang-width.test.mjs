// CLE-77892 (owner, t1 topic 9417ccf3, reopened: "This still looks quite
// narrow on my phone"): in the AVATAR bottom sheet the Language control was a
// right-aligned "🇬🇧 En" stub beside a separate ▾ button. Now it fills the row
// after the label (or its own full-width line), shows the longest language
// name whole, and the whole box is one tap target.
//   W   360 / 390 / 430, light + dark: the control ends on the row's content
//       edge and starts right after the label (or on the row's start edge
//       when it wrapped to its own line)
//   T   the text box is at least as wide as the widest "<flag> <name>" any
//       locale shows (measured in the input's own font)
//   B   one tap target: the ▾ button covers the whole control, and the point
//       on the flag hits it
//   O   a tap on the flag opens the list; it is as wide as the control and
//       cuts no language name
//   H   the Theme picker in the same sheet cuts no theme name
//   N   no sideways scroll at any size
//   D   1440 (spec 109 FR-008: the control left the top bar for the avatar
//       dropdown): it stays inside the 272 px dropdown and its open list cuts
//       no name
// CONTROL: the locale list is read from the open options (>= 19 rows), so a
// list that never rendered cannot make "longest name" trivially short.
//
//   node tests/e2e/sheet-lang-width.test.mjs
//   BASE_URL=<generated bundle> OUT=/tmp/shots node tests/e2e/sheet-lang-width.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const PHONES = [
  { name: '360', width: 360, height: 780 },
  { name: '390', width: 390, height: 844 },
  { name: '430', width: 430, height: 932 },
]
const SHEET = '[data-test=user-menu-prefs] [data-test=lang-switcher]'

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      const theme = localStorage.getItem('spool.test.theme')
      if (theme) localStorage.setItem('spool-theme', theme)
    } catch { /* opaque origin on the very first document */ }
  })

  const load = async (vp, touch) => {
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: touch, hasTouch: touch })
    await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=user-menu-trigger]', { visible: true, timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(400)
  }
  const openSheet = async () => {
    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector(`${SHEET} [data-test=lang-switcher-input]`, { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
  }
  const setTheme = (theme) => p.evaluate((t) => localStorage.setItem('spool.test.theme', t), theme)
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/sheet-lang-width-${name}.png` }) }

  /* the "<flag> <name>" of every locale, read once from the open list */
  await load(PHONES[1], true)
  await openSheet()
  await p.click(`${SHEET} [data-test=lang-switcher-button]`)
  await p.waitForSelector(`${SHEET} [data-test=lang-switcher-options] .lang-switcher__name`, { timeout: NAV_TIMEOUT })
  const labels = await p.$$eval(`${SHEET} [data-test=lang-switcher-options] .lang-switcher__option`, (rows) =>
    rows.map((r) => `${r.querySelector('.lang-switcher__flag')?.textContent || ''} ${r.querySelector('.lang-switcher__name')?.textContent || ''}`))
  ok('L0 CONTROL: every locale is listed', labels.length >= 19, { n: labels.length })
  await p.keyboard.press('Escape')

  const measure = (root) => p.evaluate((root, labels) => {
    const row = document.querySelector('[data-test=user-menu-language]')
    const label = row.querySelector('.user-menu__pref-label')
    const ctrl = document.querySelector(`${root} .lang-switcher__control`)
    const input = document.querySelector(`${root} [data-test=lang-switcher-input]`)
    const btn = document.querySelector(`${root} [data-test=lang-switcher-button]`)
    const cs = getComputedStyle(input)
    const rs = getComputedStyle(row)
    const ctx = document.createElement('canvas').getContext('2d')
    ctx.font = cs.font
    const widest = Math.max(...labels.map((l) => ctx.measureText(l).width))
    const r = (el) => el.getBoundingClientRect()
    const rowL = r(row).left + parseFloat(rs.paddingLeft)
    const rowR = r(row).right - parseFloat(rs.paddingRight)
    const c = r(ctrl)
    const b = r(btn)
    const flagX = c.left + 18
    const flagY = c.top + c.height / 2
    const hit = document.elementFromPoint(flagX, flagY)
    const sameLine = Math.abs((c.top + c.bottom) / 2 - (r(label).top + r(label).bottom) / 2) < 4
    return {
      ctrlL: Math.round(c.left), ctrlR: Math.round(c.right), ctrlW: Math.round(c.width), ctrlH: Math.round(c.height),
      rowL: Math.round(rowL), rowR: Math.round(rowR), labelR: Math.round(r(label).right), sameLine,
      textBox: Math.round(input.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)),
      widest: Math.ceil(widest),
      btnCovers: Math.abs(b.left - c.left) <= 2 && Math.abs(b.right - c.right) <= 2,
      flagHitsButton: !!hit && (hit === btn || btn.contains(hit)),
      over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    }
  }, root, labels)

  const openList = async (root, at) => {
    if (at) await p.mouse.click(at.x, at.y)
    else await p.click(`${root} [data-test=lang-switcher-button]`)
    await p.waitForSelector(`${root} [data-test=lang-switcher-options] .lang-switcher__name`, { timeout: 5000 }).catch(() => {})
    await sleep(250)
    return p.evaluate((root) => {
      const list = document.querySelector(`${root} [data-test=lang-switcher-options]`)
      if (!list) return { n: 0, listW: 0, cut: [] }
      const names = [...list.querySelectorAll('.lang-switcher__name')]
      return {
        n: names.length,
        listW: Math.round(list.getBoundingClientRect().width),
        cut: names.filter((el) => el.scrollWidth > el.clientWidth + 1).map((el) => el.textContent),
      }
    }, root)
  }

  for (const theme of ['light', 'dark']) {
    for (const vp of PHONES) {
      await setTheme(theme)
      await load(vp, true)
      await openSheet()
      const m = await measure(SHEET)
      const tag = `${vp.name} ${theme}`
      const spans = Math.abs(m.ctrlR - m.rowR) <= 1 && (m.sameLine ? m.ctrlL - m.labelR <= 13 : Math.abs(m.ctrlL - m.rowL) <= 1)
      ok(`W ${tag}: the control spans the row after the label`, spans, m)
      ok(`T ${tag}: the field fits the longest language name`, m.textBox >= m.widest, { textBox: m.textBox, widest: m.widest })
      ok(`B ${tag}: one tap target - the button covers the box, the flag hits it`, m.btnCovers && m.flagHitsButton && m.ctrlH >= 44, m)
      ok(`N ${tag}: no sideways scroll`, m.over <= 0, { over: m.over })
      await shot(`${vp.name}-${theme}`)
      const o = await openList(SHEET, { x: m.ctrlL + 18, y: (await p.$eval(`${SHEET} .lang-switcher__control`, (el) => { const r = el.getBoundingClientRect(); return r.top + r.height / 2 })) })
      ok(`O ${tag}: a tap on the flag opens the list, as wide as the control, no name cut`, o.n >= 19 && o.cut.length === 0 && o.listW >= m.ctrlW - 1, o)
      await shot(`${vp.name}-${theme}-open`)
      await p.keyboard.press('Escape')
      await sleep(150)
      await p.click('[data-test=user-menu-prefs] [data-test=theme-picker]')
      await sleep(300)
      const th = await p.evaluate(() => {
        const names = [...document.querySelectorAll('[data-test=user-menu-prefs] .theme-picker__name')]
        const list = document.querySelector('[data-test=user-menu-prefs] .theme-picker__list')
        const r = list?.getBoundingClientRect()
        return {
          n: names.length,
          cut: names.filter((el) => el.scrollWidth > el.clientWidth + 1).map((el) => el.textContent),
          inView: !!r && r.left >= 0 && r.right <= window.innerWidth,
        }
      })
      ok(`H ${tag}: the Theme list in the sheet cuts no name`, th.n >= 2 && th.cut.length === 0 && th.inView, th)
      await p.keyboard.press('Escape')
    }
  }

  await setTheme('light')
  await load({ name: '1440', width: 1440, height: 900 }, false)
  await openSheet()
  const d = await p.evaluate((root) => {
    const c = document.querySelector(`${root} .lang-switcher__control`)?.getBoundingClientRect()
    const panel = document.querySelector('[data-test=user-menu-panel]')?.getBoundingClientRect()
    return { w: c ? Math.round(c.width) : -1, l: Math.round(c?.left ?? -1), r: Math.round(c?.right ?? -1), pl: Math.round(panel?.left ?? 0), pr: Math.round(panel?.right ?? 0) }
  }, SHEET)
  ok('D1 1440: the dropdown language control stays inside the dropdown', d.w > 0 && d.l >= d.pl && d.r <= d.pr, d)
  const od = await openList(SHEET)
  ok('D2 1440: its open list cuts no name', od.n >= 19 && od.cut.length === 0, od)

  ok('no page errors', errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
