// specs/112 WUI-2 (spec 4.1, 4.4): an event the roadmap sync wrote (it has a
// `source_key`) is read-only in the calendar.
//
// Done: a synced event shows no Edit and cannot be dragged or resized; its
//       pop-over has a "change it in the repo" link to `roadmap_url` as the
//       sync wrote it; /calendar?d=<iso>&event=<id> (a roadmap row) opens
//       that pop-over. A member's event beside it keeps Edit and its drag.
// The fixture: the mock workspace (src/utils/calendar-mock.mjs) reads its
// added events from localStorage, so the test stores one synced event there
// (and the mock refuses a PATCH or DELETE of it 409, as the hub does).
//
// Control: a synced fixture event with the Edit button visible turns
// "no Edit" red; before WUI-2 every synced check below FAILS (calEditable
// was true for it: Edit showed, the drag moved it, no repo link).
//
// Run:
//   pnpm run test:e2e calendar-synced
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-synced
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calIsoDay } from '../../src/utils/calendar-year.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-synced-${name}.png`) })
}

const ADDED_KEY = 'spool.mock.calendar-added'
const RELEASE = '00000000-0000-4000-8000-000000000101'
const SYNCED = '00000000-0000-4000-8000-000000000112'
const ROADMAP_URL = '/roadmap?ws=demo&goal=G01#spec-112'
const today = calIsoDay(Date.now())
/* a timed synced event today 13:00-14:00 UTC, beside the seeded Release (09:00) */
const fixture = {
  id: SYNCED, source: 'event', title: 'G01 deadline', description: '', kind: 'goal',
  starts_at: `${today}T13:00:00Z`, ends_at: `${today}T14:00:00Z`, all_day: false, audience: 'internal', mentions: [],
  creator_type: 'system', creator_id: 'roadmap-sync', remind_at: '', topic_id: '', release_version: '', issue_key: '',
  created_at: `${today}T00:00:00Z`, updated_at: `${today}T00:00:00Z`, time_zone: 'UTC', location: '', color: '', reminders: [],
  source_key: 'goal:G01:deadline', roadmap_url: ROADMAP_URL,
}
const ITEM = (id) => `[data-test=calendar-item][data-id="${id}"]`
const POP = '[data-test=calendar-event-popover]'

/* each case starts from the seeded mock plus the fixture: its own browser context */
async function open(browser, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const vp = { width: 1440, height: 900 }
  await setPageViewport(p, vp)
  await p.evaluateOnNewDocument((k, ev) => {
    if (!localStorage.getItem(k)) localStorage.setItem(k, JSON.stringify([ev]))
  }, ADDED_KEY, fixture)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { ctx, p }
}
const seen = (p, sel, want = true) => p.waitForFunction((s, w) => Boolean(document.querySelector(s)) === w, { timeout: 8000 }, sel, want).then(() => true, () => false)
const popover = (p) => p.evaluate((s) => {
  const el = document.querySelector(s)
  const a = document.querySelector('[data-test=calendar-popover-repo]')
  return {
    id: el?.getAttribute('data-id') || '',
    edit: Boolean(document.querySelector('[data-test=calendar-popover-edit]')),
    repo: a?.getAttribute('href') || '',
    text: (a?.textContent || '').trim(),
  }
}, POP)

/* a mouse drag of an item 2 hours down; its data-starts after the drop */
async function dragDown(p, id) {
  const box = await p.$eval(ITEM(id), (el) => { const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + 6 } })
  const hour = await p.$eval(`[data-grid-day="${today}"]`, (el) => el.getBoundingClientRect().height / 24)
  await p.mouse.move(box.x, box.y)
  await p.mouse.down()
  for (let i = 1; i <= 8; i++) await p.mouse.move(box.x, box.y + (hour * 2 * i) / 8)
  await p.mouse.up()
  await new Promise((r) => setTimeout(r, 800))
  return p.$eval(ITEM(id), (el) => el.getAttribute('data-starts')).catch(() => '')
}

const server = await startServer()
const browser = await launch()
try {
  console.log('-- the week: a click on the synced event')
  {
    const { ctx, p } = await open(browser, '/calendar')
    ok('the synced fixture event is in the week, marked synced', await seen(p, `${ITEM(SYNCED)}[data-synced=true]`))
    ok('the member\'s Release beside it is not marked synced', await seen(p, `${ITEM(RELEASE)}:not([data-synced])`))
    ok('the synced event has no resize handle', !(await p.$(`${ITEM(SYNCED)} [data-test=calendar-item-resize]`)))
    await p.click(ITEM(SYNCED))
    ok('a click opens its pop-over', await seen(p, `${POP}[data-id="${SYNCED}"]`))
    const pop = await popover(p)
    ok('no Edit button (control: a visible Edit turns this red)', !pop.edit, pop)
    ok('a "change it in the repo" link to roadmap_url as given', pop.repo === ROADMAP_URL && pop.text === 'Change it in the repo', pop)
    await shot(p, 'popover')
    await p.keyboard.press('Escape')
    await seen(p, POP, false)

    const was = await p.$eval(ITEM(SYNCED), (el) => el.getAttribute('data-starts'))
    const after = await dragDown(p, SYNCED)
    ok('a drag does not move the synced event', after === was, { was, after })
    /* the release lands on the day column, whose click opens a NEW event (as
       after a drag from an issue deadline): never the synced event to edit */
    ok('and opens no edit dialog of it', !(await p.$('[data-test=calendar-event-form][data-mode=edit]')))
    const stored = await p.evaluate((k, id) => (JSON.parse(localStorage.getItem(k) || '[]').find((x) => x.id === id) || {}).starts_at || '', ADDED_KEY, SYNCED)
    ok('the stored fixture is unchanged', stored === fixture.starts_at, stored)

    await p.keyboard.press('Escape')
    await p.click(ITEM(RELEASE))
    await seen(p, POP)
    const mine = await popover(p)
    ok('the member\'s event keeps Edit and has no repo link', mine.edit && !mine.repo, mine)
    await ctx.close()
  }

  console.log('-- a roadmap row: /calendar?d=<iso>&event=<id>')
  {
    const { ctx, p } = await open(browser, `/calendar?d=${today}&event=${SYNCED}`)
    ok('the link opens the synced event\'s pop-over', await seen(p, `${POP}[data-id="${SYNCED}"]`))
    const pop = await popover(p)
    ok('no Edit there either', !pop.edit, pop)
    ok('and no edit dialog', !(await p.$('[data-test=calendar-event-form]')))
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-synced: ${failed} FAILED` : `calendar-synced: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
