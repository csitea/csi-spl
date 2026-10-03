// perf round 4 W6, proved in a REAL browser: closed / phone-hidden UI is
// rendered on demand. The theme list exists only while the picker is open
// (v-if, was v-show), and the top bar's language switcher is not mounted on
// a phone (was display:none there), so its async chunk is not imported
// either - the avatar menu's sheet still offers both. 1440x900 and 390x844.
// CONTROL: the desktop top bar keeps its language switcher, and opening the
// picker still lists every theme with the current one focused.
//
// Run:
//   pnpm run test:e2e hidden-ui-on-demand
//   BASE_URL=<generated bundle> pnpm run test:e2e hidden-ui-on-demand   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const LIST = '[data-test=theme-picker-list]'

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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The picker inside `scope`: its list count, the option focused, html[data-theme]. */
function pickerFacts(page, scope) {
  return page.evaluate((sel, list) => {
    const root = document.querySelector(sel)
    const lists = root ? root.querySelectorAll(list).length : -1
    const btn = root?.querySelector('[data-test=theme-picker]')
    const focused = document.activeElement?.getAttribute('data-theme-id') ?? null
    return {
      lists,
      options: root ? root.querySelectorAll('[role=option]').length : -1,
      expanded: btn?.getAttribute('aria-expanded') ?? null,
      controls: btn?.getAttribute('aria-controls') ?? null,
      focused,
      theme: document.documentElement.getAttribute('data-theme'),
    }
  }, scope, LIST)
}

/* the mock bundle starts signed out; the avatar menu needs a session */
const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const langCssLoaded = (page) => page.evaluate(() =>
  performance.getEntriesByType('resource').some((e) => /\/LanguageSwitcher\.[^/]*\.css$/.test(e.name)))

/** Open the picker in `scope` with ArrowDown, then pick the other theme with the keyboard. */
async function exercisePicker(p, tag, scope) {
  const closed = await pickerFacts(p, scope)
  ok(`${tag}: the closed picker renders no list`, closed.lists === 0 && closed.expanded === 'false' && closed.controls === null, closed)
  await p.focus(`${scope} [data-test=theme-picker]`)
  await p.keyboard.press('ArrowDown')
  await p.waitForSelector(`${scope} ${LIST}`, { timeout: 5000 })
  await p.waitForFunction((t) => document.activeElement?.getAttribute('data-theme-id') === t, { timeout: 5000 }, closed.theme)
  const opened = await pickerFacts(p, scope)
  ok(`${tag}: ArrowDown renders the list, focus on the current theme`,
    opened.lists === 1 && opened.options >= 5 && opened.focused === closed.theme && opened.expanded === 'true' && Boolean(opened.controls), opened)
  await p.keyboard.press('Escape')
  const escaped = await pickerFacts(p, scope)
  ok(`${tag}: Escape removes the list again`, escaped.lists === 0, escaped)
  /* the list is rendered fresh on every open: a second open still focuses and picks */
  await p.keyboard.press('ArrowDown')
  await p.waitForSelector(`${scope} ${LIST}`, { timeout: 5000 })
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('Enter')
  await p.waitForFunction((t) => document.documentElement.getAttribute('data-theme') !== t, { timeout: 5000 }, closed.theme)
  const chosen = await pickerFacts(p, scope)
  ok(`${tag}: re-open + ArrowDown + Enter applies the next theme and closes`, chosen.lists === 0 && chosen.theme !== closed.theme, chosen)
}

const server = await startServer()
const browser = await launch()
try {
  /* desktop: the top bar's own picker and language switcher */
  {
    const size = { width: 1440, height: 900 }
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await setPageViewport(p, size)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await p.waitForSelector('[data-test=top-bar] [data-test=lang-switcher]', { visible: true, timeout: NAV_TIMEOUT })
    ok('1440: CONTROL the top bar keeps its language switcher', true)
    await exercisePicker(p, '1440 top bar', '[data-test=top-bar-start]')
    ok('1440: no page error', errors.length === 0, errors)
    await p.close()
  }
  /* phone: nothing language-related in the bar; the avatar sheet has both */
  {
    const size = { width: 390, height: 844 }
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await setPageViewport(p, size)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    if (!(await signIn(p))) throw new Error('no session store')
    await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: NAV_TIMEOUT })
    const bar = await p.evaluate((list) => ({
      lang: document.querySelectorAll('.top-bar__lang, [data-test=top-bar] [data-test=lang-switcher]').length,
      lists: document.querySelectorAll(list).length,
    }), LIST)
    ok('390: the top bar mounts no language switcher and no theme list', bar.lang === 0 && bar.lists === 0, bar)
    ok('390: the language switcher chunk is not loaded before it is asked for', !(await langCssLoaded(p)))
    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector('[data-test=user-menu-language] [data-test=lang-switcher]', { visible: true, timeout: 10000 })
    ok('390: the avatar sheet offers the language switcher', true)
    ok('390: opening the sheet loads it', await langCssLoaded(p))
    await exercisePicker(p, '390 avatar sheet', '[data-test=user-menu-theme]')
    ok('390: no page error', errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
