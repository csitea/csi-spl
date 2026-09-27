// SPL-1009 (owner, 2026-09-27, prd t1 topic 3aba968b: "but still the humans
// are presented with IDs"): a person is shown by the name they chose, in a
// REAL browser, against the mock bundle.
//
// The mock tenant reads no roster, so this test puts a names map into the
// page's people store (useHumanNames, useState 'spool.human-names'): HUM-2 is
// "Ann Example", HUM-3 and HUM-12 both chose "Bo Example".
//
//   1 the @ list names Ann; Bo Example's two rows carry their ids as a muted
//     suffix (the only way to tell them apart)
//   2 a pick writes "@Ann Example" into the field, not "@HUM-2@box-wui"
//   3 the sent line is STORED with the tag: the card shows "@Ann Example" and
//     the mention's title is the "@HUM-2..." tag (a rename breaks no link)
//   4 a member id written as plain text - the poke DM's "HUM-2 needs you in
//     ..." - reads "Ann Example needs you in ...", the id on hover
//   5 at 360 and 820 px the pick still writes the name
//   6 CONTROL: an agent keeps its id (CLE-07), a nameless member keeps HUM-9
//
// Before SPL-1009, steps 2 and 4 fail (the field held "@HUM-2@box-wui " and
// the poke line read "HUM-2 needs you in") and step 1 has no suffix.
//
// Run:
//   node tests/e2e/names-not-ids.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/names-not-ids.test.mjs     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OMNI = 'form.omnibox--global textarea'
const NAMES = { 'HUM-2': 'Ann Example', 'HUM-3': 'Bo Example', 'HUM-12': 'Bo Example' }

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The people store as useHumanNames reads it (useState key 'spool.human-names'). */
async function setNames(p, names) {
  return p.evaluate((n) => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const nuxt = app && (app.$nuxt || app.config.globalProperties.$nuxt)
    if (!nuxt || !nuxt.payload || !nuxt.payload.state) return false
    nuxt.payload.state['$sspool.human-names'] = n
    return true
  }, names)
}

const listRows = (p) => p.evaluate(() => [...document.querySelectorAll('[data-test=mention-option]')].map((b) => ({
  id: b.getAttribute('data-id'),
  name: b.querySelector('.mention-label')?.textContent.trim() || '',
  suffix: b.querySelector('[data-testid=mention-id-suffix]')?.textContent.trim() || '',
})))
const field = (p) => p.$eval(OMNI, (el) => el.value)
const clear = (p) => p.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
const ctrlEnter = async (p) => { await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control') }

async function typeAndPick(p, frag) {
  await p.click(OMNI)
  await p.keyboard.type(frag)
  await p.waitForSelector('[data-test=mention-list]', { visible: true, timeout: 8000 }).catch(() => null)
  const rows = await listRows(p)
  await p.keyboard.press('Tab')
  await sleep(300)
  return { rows, value: await field(p) }
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(OMNI, { visible: true, timeout: NAV_TIMEOUT })
  ok('0 the names are in the people store', await setNames(p, NAMES))
  const run = Date.now().toString(36)

  // 1 the @ list
  await p.click(OMNI)
  await p.keyboard.type('@Exam')
  await p.waitForSelector('[data-test=mention-list]', { visible: true, timeout: 8000 }).catch(() => null)
  const exam = await listRows(p)
  const bo = exam.filter((r) => r.name === 'Bo Example')
  const annRow = exam.find((r) => r.id === 'HUM-2')
  ok('1 the two members named "Bo Example" carry their ids as a muted suffix; Ann (a name of her own) has none',
    bo.length === 2 && bo.every((r) => r.suffix === r.id) && !!annRow && annRow.name === 'Ann Example' && !annRow.suffix, exam)
  await clear(p)

  // 2 a pick writes the name
  const ann = await typeAndPick(p, `SPL-1009 ${run} for @Ann`)
  ok('2 the @ list names Ann; the pick writes "@Ann Example", no HUM id in the field',
    ann.rows.some((r) => r.id === 'HUM-2' && r.name === 'Ann Example' && !r.suffix) && ann.value.endsWith('@Ann Example ') && !/HUM-/.test(ann.value), ann)

  // 3 stored with the tag, rendered by name
  await ctrlEnter(p)
  const sent = await p.waitForFunction((r) => {
    const card = [...document.querySelectorAll('.msg')].find((m) => m.textContent.includes(`SPL-1009 ${r} for`))
    const men = card && card.querySelector('.mention')
    return men ? { text: men.textContent.trim(), title: men.getAttribute('title') || '' } : null
  }, { timeout: 15000 }, run).then((h) => h.jsonValue(), () => null)
  ok('3 the message stores the tag and shows the name: "@Ann Example", title "@HUM-2..."',
    !!sent && sent.text === '@Ann Example' && /^@HUM-2(@box-wui)?$/.test(sent.title), sent)

  // 4 a member id in plain text (the poke DM line)
  await p.click(OMNI)
  await p.keyboard.type(`HUM-2 needs you in /t/x ${run}: please look (HUM-9, CLE-07)`)
  await ctrlEnter(p)
  const poke = await p.waitForFunction((r) => {
    const card = [...document.querySelectorAll('.msg')].find((m) => m.textContent.includes(`/t/x ${r}`))
    const body = card && card.querySelector('.msg-para, .msg-body')
    const who = card && card.querySelector('.person-name')
    return body ? { text: body.textContent.replace(/\s+/g, ' ').trim(), title: who ? who.getAttribute('title') : '' } : null
  }, { timeout: 15000 }, run).then((h) => h.jsonValue(), () => null)
  ok('4 "HUM-2 needs you in ..." reads "Ann Example needs you in ...", the id on hover',
    !!poke && poke.text.startsWith('Ann Example needs you in') && poke.title === 'HUM-2', poke)
  ok('6 CONTROL: a nameless member (HUM-9) and an agent (CLE-07) keep their ids',
    !!poke && poke.text.includes('(HUM-9, CLE-07)'), poke)

  // 5 narrow viewports: the same pick
  for (const w of [360, 820]) {
    await p.setViewport({ width: w, height: 800, isMobile: w < 800, hasTouch: w < 800 })
    await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector(OMNI, { visible: true, timeout: NAV_TIMEOUT })
    await setNames(p, NAMES)
    const narrow = await typeAndPick(p, '@Ann')
    ok(`5 ${w}px: the pick writes "@Ann Example"`, narrow.value === '@Ann Example ', narrow)
    await clear(p)
  }

  ok('7 no page errors', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`names-not-ids: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
