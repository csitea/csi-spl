// CLE-77887 (owner, t1 topic 9417ccf3: "also on mobile the language switcher
// is too narrow in the personal preferences"): in Settings -> Language on a
// phone, the preferred-language combobox fills the settings column and its
// field shows the longest language name of all locales untruncated; the Save
// button takes its own row. Desktop keeps the bounded field.
//   W   360 / 390 / 430, light + dark: the combobox is the full width of the
//       section column (within 1 px)
//   T   the text box is at least as wide as the widest "<flag> <name>" any
//       locale shows (measured in the input's own font)
//   S   Save sits below the field, on the column's left edge
//   D   1440: the field stays bounded (<= 20rem) with Save beside it
//   O   the open list is as wide as the field and cuts no language name
//   N   no sideways scroll at any size
// CONTROL: the locale list is read from the open options (>= 19 rows), so a
// list that never rendered cannot make "longest name" trivially short.
//
//   node tests/e2e/settings-lang-width.test.mjs
//   BASE_URL=<generated bundle> OUT=/tmp/shots node tests/e2e/settings-lang-width.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

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
const DESKTOP = { name: '1440', width: 1440, height: 900 }

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

  const load = async (vp) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + '/settings/language', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=settings-preferred-locale]', { visible: true, timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(600)
  }
  const setTheme = (theme) => p.evaluate((t) => localStorage.setItem('spool.test.theme', t), theme)
  const shot = async (name) => { if (OUT) await p.screenshot({ path: `${OUT}/settings-lang-width-${name}.png` }) }

  /* the "<flag> <name>" of every locale, read once from the open list */
  await load(PHONES[1])
  await p.click('[data-test=settings-preferred-locale-button]')
  await p.waitForSelector('[data-test=settings-preferred-locale-options] .locale-cbx__name', { timeout: NAV_TIMEOUT })
  const labels = await p.$$eval('[data-test=settings-preferred-locale-options] .locale-cbx__option', (rows) =>
    rows.map((r) => `${r.querySelector('.locale-cbx__flag')?.textContent || ''} ${r.querySelector('.locale-cbx__name')?.textContent || ''}`))
  ok('L0 CONTROL: every locale is listed', labels.length >= 19, { n: labels.length })
  await p.keyboard.press('Escape')

  const measure = () => p.evaluate((labels) => {
    const input = document.querySelector('[data-test=settings-preferred-locale]')
    const cbx = document.querySelector('[data-test=settings-preferred-locale-wrap]')
    const save = document.querySelector('[data-test=settings-preferred-locale-save]')
    const col = document.querySelector('[data-test=language-setting]')
    const cs = getComputedStyle(input)
    const ctx = document.createElement('canvas').getContext('2d')
    ctx.font = cs.font
    const widest = Math.max(...labels.map((l) => ctx.measureText(l).width))
    const textBox = input.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
    const r = (el) => el.getBoundingClientRect()
    return {
      cbxW: Math.round(r(cbx).width), colW: Math.round(r(col).width),
      textBox: Math.round(textBox), widest: Math.ceil(widest),
      saveBelow: r(save).top >= r(cbx).bottom - 1,
      saveLeft: Math.abs(r(save).left - r(col).left) <= 1,
      over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      remPx: parseFloat(getComputedStyle(document.documentElement).fontSize),
    }
  }, labels)

  /* the open list: every name shown whole (no ellipsis) */
  const openList = async () => {
    await p.click('[data-test=settings-preferred-locale-button]')
    await p.waitForSelector('[data-test=settings-preferred-locale-options] .locale-cbx__name', { timeout: NAV_TIMEOUT })
    await sleep(200)
    return p.evaluate(() => {
      const list = document.querySelector('[data-test=settings-preferred-locale-options]')
      const names = [...list.querySelectorAll('.locale-cbx__name')]
      return {
        n: names.length,
        listW: Math.round(list.getBoundingClientRect().width),
        cut: names.filter((el) => el.scrollWidth > el.clientWidth + 1).map((el) => el.textContent),
      }
    })
  }

  for (const theme of ['light', 'dark']) {
    for (const vp of PHONES) {
      await setTheme(theme)
      await load(vp)
      const m = await measure()
      const tag = `${vp.name} ${theme}`
      ok(`W ${tag}: the combobox fills the settings column`, Math.abs(m.cbxW - m.colW) <= 1, m)
      ok(`T ${tag}: the field fits the longest language name`, m.textBox >= m.widest, { textBox: m.textBox, widest: m.widest })
      ok(`S ${tag}: Save sits below the field`, m.saveBelow && m.saveLeft)
      ok(`N ${tag}: no sideways scroll`, m.over <= 0, { over: m.over })
      await shot(`${vp.name}-${theme}`)
      const o = await openList()
      ok(`O ${tag}: the open list is as wide as the field, no name cut`, o.n >= 19 && o.cut.length === 0 && o.listW >= m.cbxW - 1, o)
      await shot(`${vp.name}-${theme}-open`)
      await p.keyboard.press('Escape')
    }
  }

  await setTheme('light')
  await load(DESKTOP)
  const d = await measure()
  ok('D1 1440: the field stays bounded', d.cbxW <= 20 * d.remPx + 1, d)
  ok('D2 1440: Save is beside the field', !d.saveBelow)
  ok('D3 1440: the field fits the longest language name', d.textBox >= d.widest, { textBox: d.textBox, widest: d.widest })
  await shot('1440-light')
  const od = await openList()
  ok('D4 1440: the open list cuts no name', od.n >= 19 && od.cut.length === 0, od)

  ok('no page errors', errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
