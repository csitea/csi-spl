// spec 097 T017 (G13, spec 4.8 and 5.1.4): Undo after a delete, and the trash.
//
// AC-07 (UI): delete an event, then Undo: it is back with the same id. The
//        toast reads "Event deleted · Undo" and goes away by itself after 10 s.
//        The calendar menu opens the trash; Restore brings the event back.
// Phone (360x780 and 390x844, spec 5.1.4): the toast floats >= 8 px above the
//        bottom bar, full width less 8 px margins (374 px at 390); Today,
//        previous and next stay uncovered; Undo is >= 44 px; the trash is a
//        full-width view; no sideways scroll.
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
const noSideways = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)

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

  for (const vp of [{ width: 360, height: 780 }, { width: 390, height: 844 }]) {
    const name = String(vp.width)
    console.log(`-- ${vp.width}x${vp.height}`)
    const { ctx, p } = await open(browser, { ...vp, isMobile: true, hasTouch: true })
    ok(`${name}: the seeded Release is on screen (Day view)`, await seen(p, ITEM))
    ok(`${name}: delete removes it`, await deleteRelease(p))
    ok(`${name}: the Undo toast shows`, await seen(p, TOAST))
    await new Promise((r) => setTimeout(r, 300))
    const g = await p.evaluate((s, u) => {
      const r = (el) => el?.getBoundingClientRect()
      const toast = r(document.querySelector(s))
      const bar = r(document.querySelector('.cal-main__bar'))
      const undo = r(document.querySelector(u))
      const free = ['calendar-today', 'calendar-prev', 'calendar-next'].map((id) => {
        const el = document.querySelector(`[data-test=${id}]`)
        const b = r(el)
        return Boolean(b && el.contains(document.elementFromPoint(b.x + b.width / 2, b.y + b.height / 2)))
      })
      return {
        gap: toast && bar ? Math.round(bar.top - toast.bottom) : null,
        left: toast ? Math.round(toast.left) : null,
        width: toast ? Math.round(toast.width) : null,
        iw: window.innerWidth,
        undoH: undo ? Math.round(undo.height) : 0,
        undoW: undo ? Math.round(undo.width) : 0,
        free,
      }
    }, TOAST, part('undo'))
    ok(`${name}: the toast sits >= 8 px above the bottom bar`, g.gap !== null && g.gap >= 8, g)
    ok(`${name}: it spans the width less 8 px margins`, g.left === 8 && g.width === g.iw - 16, g)
    ok(`${name}: Today, previous and next stay uncovered`, g.free.every(Boolean), g.free)
    ok(`${name}: Undo is a 44 px target`, g.undoH >= 44 && g.undoW >= 44, g)
    ok(`${name}: no sideways scroll with the toast`, await noSideways(p))
    await shot(p, `toast-${name}`)
    await p.tap(part('undo'))
    ok(`${name}: tapping Undo restores it`, await seen(p, ITEM))
    ok(`${name}: the toast closes`, await seen(p, TOAST, false))

    ok(`${name}: delete again for the trash`, await deleteRelease(p))
    await p.$eval(part('close'), (el) => el.click()).catch(() => {})
    const fit = await trashRestore(p, name)
    ok(`${name}: the trash is a full-width view, Restore 44 px`, fit.w >= fit.iw - 1 && fit.restoreH >= 44, fit)
    ok(`${name}: no sideways scroll`, await noSideways(p))
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-undo: ${failed} FAILED` : `calendar-undo: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
