// SPL-976 follow-up: the default text-field mode is Enter sends.
//
// Owner, 2026-09-27 (topic a4bc52dc): "change the default to the 'normal'
// one you described, but keep the behaviour of the already set settings".
// So a person who never picked (submit_key null) gets Enter sends and
// Shift+Enter adds a line, and a person with an explicit ctrl-enter keeps
// Enter adds a line and Ctrl+Enter sends.
//
// In the mock tenant the session is adopted through the pinia store, once
// with no submit_key and once with 'ctrl-enter'. For each:
//   - the lobby composer: Enter, then Shift+Enter or Ctrl+Enter, read back
//     from the textarea (emptied = sent, a trailing newline = a new line)
//   - Settings -> Behaviour -> Text fields: the checked radio is the
//     effective mode
// Runs at 1440 (desktop), 820 and 360 (touch).
//
// Run:
//   node tests/e2e/submit-key-default.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/submit-key-default.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const TA = 'form.omnibox--global textarea'

/** Sign in as a member; `key` undefined = never picked (the claim is absent). */
const signIn = (p, key) => p.evaluate((key) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  const c = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (key !== undefined) c.submit_key = key
  session.adopt(c)
  return true
}, key)

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

/** Type `text` into an empty composer, press the chord, read the box back. */
async function chord(p, text, mod) {
  await p.$eval(TA, (el) => { el.focus(); el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(TA, text)
  if (mod) await p.keyboard.down(mod)
  await p.keyboard.press('Enter')
  if (mod) await p.keyboard.up(mod)
  await sleep(300)
  return p.$eval(TA, (el) => el.value)
}

async function checkedMode(p) {
  await p.waitForSelector('[data-test=submit-key-setting]', { timeout: 10000 })
  return p.$eval('[data-test=submit-key-setting]', (el) => el.querySelector('input[type=radio]:checked')?.value ?? null)
}

async function run(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  for (const [who, key] of [['fresh user (never picked)', undefined], ['explicit ctrl-enter', 'ctrl-enter']]) {
    const tag = `${width}px ${who}`
    await p.goto(`${base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
    if (!(await signIn(p, key))) throw new Error('no session store')
    await p.waitForSelector(TA, { visible: true, timeout: NAV })
    await sleep(300)
    const text = `spl-976 ${width}`
    if (key === undefined) {
      const shift = await chord(p, text, 'Shift')
      check(`${tag}: Shift+Enter adds a line`, shift === text + '\n', { value: shift })
      const bare = await chord(p, text, null)
      check(`${tag}: a bare Enter sends (the box empties)`, bare === '', { value: bare })
    } else {
      const bare = await chord(p, text, null)
      check(`${tag}: a bare Enter adds a line, sends nothing (kept)`, bare === text + '\n', { value: bare })
      const ctrl = await chord(p, text, 'Control')
      check(`${tag}: Ctrl+Enter sends (the box empties)`, ctrl === '', { value: ctrl })
    }
    await go(p, '/settings/behaviour')
    const mode = await checkedMode(p)
    check(`${tag}: Settings -> Behaviour shows the effective mode`, mode === (key ?? 'enter'), { mode })
  }
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [360, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nsubmit-key-default: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
