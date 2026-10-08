// spec 097 T017 (G13, spec 4.8 and 5.1.4): Undo after a delete, and the trash.
//
// AC-07 (UI): delete an event, then Undo: it is back with the same id. The
//        toast reads "Event deleted · Undo" and goes away by itself after 10 s.
//        The calendar menu opens the trash; Restore brings the event back.
// Phone: spec 106 T011 retired 089 T009's phone calendar this checked; the
//        phone's delete + Undo is calendar-phone-peek.test.mjs (AC-05).
// The mock workspace keeps its writes in localStorage (src/utils/calendar-mock.mjs);
// the seeded Release (today 09:00, made by the viewer HUM-1) is the event.
//
// Control: before T017 a delete shows no [data-testid=calendar-undo], the bar
// has no [data-test=calendar-menu], and the deleted event is gone for good,
// so every check below FAILS.
//
// Run:
//   pnpm run test:e2e calendar-undo
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-undo
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

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
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-undo-${name}.png`) })
}

const RELEASE = '00000000-0000-4000-8000-000000000101'
const DIALOG = '[data-test=calendar-event-form]'
const TOAST = '[data-testid=calendar-undo]'
const part = (name) => `[data-testid=calendar-undo-${name}]`
const ITEM = `[data-test=calendar-item][data-id="${RELEASE}"]`

/* each viewport starts from the seeded mock: its own browser context */
async function open(browser, vp) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await setPageViewport(p, vp)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: NAV_TIMEOUT }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { ctx, p }
}
const seen = (p, sel, want = true) => p.waitForFunction((s, w) => Boolean(document.querySelector(s)) === w, { timeout: 12000 }, sel, want).then(() => true, () => false)

async function deleteRelease(p) {
  await p.evaluate((s) => document.querySelector(s)?.click(), ITEM)
  /* 097 T014: a click shows the pop-over; its Edit opens the dialog */
  const edit = await p.waitForSelector('[data-test=calendar-popover-edit]', { visible: true, timeout: 4000 }).catch(() => null)
  if (edit) await edit.click()
  if (!(await seen(p, DIALOG))) return false
  await p.click('[data-test=calendar-event-delete]')
  await p.click('[data-test=calendar-event-delete]')
  return (await seen(p, DIALOG, false)) && (await seen(p, ITEM, false))
}

async function trashRestore(p, vp) {
  await p.click('[data-test=calendar-menu]')
  ok(`${vp}: the calendar menu opens`, await seen(p, '[data-testid=calendar-menu-panel]'))
  await p.click('[data-testid=calendar-menu-panel-trash]')
  ok(`${vp}: the menu's Trash lists the deleted event`, await seen(p, `[data-test=calendar-trash-item][data-id="${RELEASE}"]`))
  const fit = await p.evaluate(() => {
    const d = document.querySelector('[data-testid=ui-dialog]')?.getBoundingClientRect()
    const b = document.querySelector('[data-test=calendar-trash-restore]')?.getBoundingClientRect()
    return { w: d ? Math.round(d.width) : 0, iw: window.innerWidth, restoreH: b ? Math.round(b.height) : 0 }
  })
  await shot(p, `trash-${vp}`)
  await p.click(`[data-test=calendar-trash-item][data-id="${RELEASE}"] [data-test=calendar-trash-restore]`)
  ok(`${vp}: Restore empties the trash`, await seen(p, '[data-test=calendar-trash-empty]'))
  await p.keyboard.press('Escape')
  ok(`${vp}: the restored event is back in the week, same id`, await seen(p, ITEM))
  return fit
}

const server = await startServer()
const browser = await launch()
try {
  console.log('-- 1440x900')
  {
    const { ctx, p } = await open(browser, { width: 1440, height: 900 })
    ok('the seeded Release is on screen', await seen(p, ITEM))
    ok('delete removes it from the week', await deleteRelease(p))
    ok('the Undo toast shows', await seen(p, TOAST))
    const text = await p.$eval(part('text'), (el) => el.textContent).catch(() => '')
    ok('it reads "Event deleted"', text === 'Event deleted', text)
    await shot(p, 'toast-1440')
    await p.click(part('undo'))
    ok('AC-07: Undo brings it back with the same id', await seen(p, ITEM))
    ok('the toast closes after Undo', await seen(p, TOAST, false))

    ok('delete again', await deleteRelease(p))
    ok('the toast shows again', await seen(p, TOAST))
    await p.mouse.move(1, 1)
    await new Promise((r) => setTimeout(r, 9000))
    ok('it is still there at 9 s', Boolean(await p.$(TOAST)))
    ok('it goes away by itself after 10 s', await seen(p, TOAST, false))
    ok('the event stays deleted', !(await p.$(ITEM)))
    const fit = await trashRestore(p, '1440')
    ok('the desktop trash is a dialog, not the full width', fit.w > 0 && fit.w < fit.iw, fit)
    await ctx.close()
  }

} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-undo: ${failed} FAILED` : `calendar-undo: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
