// HUM-10 (t1 58857a17): "what are those 22 users on the sat box ?!" and "we
// need to have a link on the box to show those users", then "three should be
// clear distinguished rules for humans and agents - becuase they are
// fundamentally different" and "in our "spool UI parlae" those are just
// called people , and the rest are called agents".
//
// So a box reads "N people · M agents", on the boxes rail row AND on
// /boxes/<id>, each count its own link to its own list (people with avatars,
// agents with bot icons), and the word "users" is gone from the box UI.
//
// At 1440 px and 390 px (phone), light and dark, for box-a and box-desk:
//   - the rail row shows both counts, each equal to the rows of its list
//   - clicking a rail count opens /boxes/<id> with that list in view
//   - on /boxes/<id> each count equals the rows of its list, and a click
//     on it scrolls its list into view and marks it
//   - no "user" in the rail's boxes panel or the box card
//
// Red on the old code: there was one "N users" span and no count link.
//
// Screenshots for the owner post land in $SHOT_DIR when it is set.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e box-seat-counts
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const count = (p, sel) => p.$$eval(sel, (els) => els.length)
const attrNum = (p, sel) => p.$eval(sel, (e) => Number(e.getAttribute('data-count')))
const textOf = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim())
const hashOf = (p) => p.evaluate(() => location.hash)
/* the list's top edge is in the top half of the screen and it is the marked one */
const listShown = (p, sel) => p.$eval(sel, (el) => {
  const r = el.getBoundingClientRect()
  return r.height > 0 && r.top >= 0 && r.top < window.innerHeight / 2 && el.classList.contains('is-target')
})
const noUsers = (p, sel) => p.evaluate((s) => [...document.querySelectorAll(s)].every((e) => !/\busers?\b/i.test(e.textContent)), sel)
const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)
async function shot(p, name) {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(SHOT_DIR, name + '.png') })
}
async function click(p, sel) {
  await p.waitForSelector(sel, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(sel)
}
const railCounts = (box) => `[data-testid=sidebar-panel-boxes] [data-testid=box-seat-counts][data-box="${box}"]`

/* /boxes/<box>: each count equals its list's rows and opens it */
async function checkCard(p, tag, box) {
  await p.waitForFunction((b) => location.pathname.endsWith('/boxes/' + b), { timeout: NAV_TIMEOUT }, box)
  await p.waitForSelector('[data-test=box-people-count]', { visible: true, timeout: NAV_TIMEOUT })
  const people = await attrNum(p, '[data-test=box-people-count]')
  const agents = await attrNum(p, '[data-test=box-agents-count]')
  ok(`${tag}: ${box} card - people count = its rows`, people === await count(p, '[data-test=box-people-list] [data-test=box-person]'), { people })
  ok(`${tag}: ${box} card - agents count = its rows`, agents === await count(p, '[data-test=box-agents-list] [data-test=box-agent]'), { agents })
  const seated = await textOf(p, '[data-test=box-seated]')
  ok(`${tag}: ${box} card - "N people · M agents"`, seated.includes(String(agents)) && /·/.test(seated), { seated })
  ok(`${tag}: ${box} card - people avatars, agents bot icons`,
    await count(p, '[data-test=box-people-list] [data-test=box-person] .spool-avatar, [data-test=box-people-list] [data-test=box-person] img') >= people
    && await count(p, '[data-test=box-agents-list] [data-test=box-agent] svg') >= agents)
  await click(p, '[data-test=box-agents-count]')
  await p.waitForFunction(() => location.hash === '#box-agents', { timeout: NAV_TIMEOUT })
  await sleep(300)
  ok(`${tag}: ${box} card - the agents count opens the agents list`, await listShown(p, '[data-test=box-agents-list]'), { hash: await hashOf(p) })
  await click(p, '[data-test=box-people-count]')
  await p.waitForFunction(() => location.hash === '#box-people', { timeout: NAV_TIMEOUT })
  await sleep(300)
  ok(`${tag}: ${box} card - the people count opens the people list`, await listShown(p, '[data-test=box-people-list]'), { hash: await hashOf(p) })
  ok(`${tag}: ${box} card - no "users"`, await noUsers(p, '[data-test=box-card]'))
  return { people, agents }
}

const server = await startServer()
const browser = await launch()
try {
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    for (const theme of ['light', 'dark']) {
      const tag = `${w} ${theme}`
      const phone = w < 600
      console.log(`-- ${w}x${h} ${theme}`)
      const vp = { width: w, height: h }
      const p = await browser.newPage()
      await setPageViewport(p, vp)
      await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
      await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
      for (const [box, kind] of [['box-a', 'agents'], ['box-desk', 'people']]) {
        await p.goto(server.base + (phone ? '/' : '/boxes'), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
        await applyViewport(p, vp)
        await p.waitForSelector('[data-testid=sidebar-rail]', { timeout: NAV_TIMEOUT })
        if (phone) {
          await sleep(600)
          await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-boxes]')?.click())
        }
        /* the rail row: two counts, never "users" */
        await p.waitForSelector(railCounts(box), { visible: true, timeout: NAV_TIMEOUT })
        const rail = {
          people: await attrNum(p, railCounts(box) + ' [data-testid=box-people-count]'),
          agents: await attrNum(p, railCounts(box) + ' [data-testid=box-agents-count]'),
        }
        ok(`${tag}: ${box} rail - "N people · M agents"`, /·/.test(await textOf(p, railCounts(box))), rail)
        ok(`${tag}: rail - no "users"`, await noUsers(p, '[data-testid=sidebar-panel-boxes]'))
        if (box === 'box-a') await shot(p, `box-seat-counts-rail-${w}-${theme}`)
        /* a rail count opens its list on the box's card */
        await click(p, `${railCounts(box)} [data-testid=box-${kind}-count]`)
        await p.waitForFunction((k) => location.hash === '#box-' + k, { timeout: NAV_TIMEOUT }, kind)
        await p.waitForSelector(`[data-test=box-${kind}-list]`, { visible: true, timeout: NAV_TIMEOUT })
        await sleep(400)
        ok(`${tag}: ${box} rail - the ${kind} count opens the ${kind} list`, await listShown(p, `[data-test=box-${kind}-list]`))
        const card = await checkCard(p, tag, box)
        ok(`${tag}: ${box} - the rail counts = the card counts`, rail.people === card.people && rail.agents === card.agents, { rail, card })
        ok(`${tag}: ${box} - no horizontal page scroll`, await noXScroll(p))
        await shot(p, `box-seat-counts-${box}-${w}-${theme}`)
      }
      await p.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
