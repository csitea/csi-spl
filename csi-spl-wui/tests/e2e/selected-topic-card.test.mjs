// t1 b921518d: the selected topic card in the channel list has no left
// bracket bar. It has a 1px border on all four sides, sits 1px up, and
// carries the theme drop shadow. Desktop and phone, dark and light.
// Keyboard focus stays visible. A screenshot of the desktop card is written
// under a per-run temp directory.
//
//   pnpm run test:e2e selected-topic-card
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'
import { applyViewport, setPageViewport, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PATH = '/channel/lobby'
const SHOT_DIR = mkdtempSync(join(tmpdir(), 'selected-topic-card-'))
const WIDTHS = [
  { name: 'desktop', width: 1440, height: 900 },
  { name: 'phone', width: 390, height: 844 },
]
const THEMES = ['dark', 'light']

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function readCard(page) {
  return page.evaluate(() => {
    const selected = document.querySelector('article.msg.selected')
    const other = [...document.querySelectorAll('article.msg')].find((el) => !el.classList.contains('selected'))
    if (!selected) return null
    const probe = document.createElement('div')
    const ringProbe = document.createElement('div')
    ringProbe.style.color = 'var(--focus-ring)'
    document.body.appendChild(ringProbe)
    const ring = getComputedStyle(ringProbe).color
    ringProbe.remove()
    probe.style.border = '1px solid rgba(128, 128, 128, 0.45)'
    probe.style.boxShadow = '0 2px 6px rgba(100, 100, 100, 0.22)'
    document.body.appendChild(probe)
    const want = getComputedStyle(probe)
    const grey = want.borderTopColor
    const shadow = want.boxShadow
    probe.remove()
    const read = (el) => {
      if (!el) return null
      const s = getComputedStyle(el)
      const sides = ['Top', 'Right', 'Bottom', 'Left']
      return {
        border: sides.map((side) => s[`border${side}Width`]),
        color: sides.map((side) => s[`border${side}Color`]),
        shadow: s.boxShadow,
        transform: s.transform,
        outlineWidth: s.outlineWidth,
        outlineStyle: s.outlineStyle,
        outlineColor: s.outlineColor,
        focusVisible: el.matches(':focus-visible'),
      }
    }
    const heading = document.querySelector('.topic-heading__title')
    const label = document.querySelector('.topic-heading__label')
    const hs = heading ? getComputedStyle(heading) : null
    const ls = label ? getComputedStyle(label) : null
    return {
      card: read(selected),
      other: read(other),
      ring,
      grey,
      shadow,
      phone: window.innerWidth <= 820,
      heading: hs ? {
        border: hs.borderTopWidth,
        shadow: hs.boxShadow,
        label: ls ? ls.display : '',
      } : null,
      box: (() => {
        const r = selected.getBoundingClientRect()
        return { x: r.x, y: r.y, width: r.width, height: r.height }
      })(),
    }
  })
}

async function openOnce(page, theme) {
  /* nuxi dev reloads once while it warms up and destroys the context. */
  for (let i = 0; ; i++) {
    try {
      await page.goto(server.base + PATH, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      await page.evaluate((t) => {
        document.documentElement.setAttribute('data-theme', t)
        try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ }
      }, theme)
      await page.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
      await sleep(200)
      await page.$eval('article.msg[data-msg-id]', (el) => el.click())
      await page.waitForSelector('article.msg.selected', { timeout: NAV_TIMEOUT })
      await sleep(200)
      return
    } catch (e) {
      if (i >= 2 || !/context was destroyed|detached|navigation/i.test(String(e))) throw e
    }
  }
}

async function openSelected(page, theme) {
  await page.evaluateOnNewDocument((t) => {
    try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ }
  }, theme)
  await retryOnNetworkChanged(PATH, () => openOnce(page, theme))
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of THEMES) {
    for (const vp of WIDTHS) {
      const tag = `${theme} ${vp.name}`
      const page = watchPage(await browser.newPage(), tag)
      await setPageViewport(page, vp)
      await openSelected(page, theme)
      await applyViewport(page, vp)
      /* On a phone the open topic hides the message list (display:none), so
         the card cannot take keyboard focus and a list transition can hold
         transform:none. Show the list again; the card's own rules are unchanged. */
      if (vp.name === 'phone') {
        await page.addStyleTag({ content: '.spool-shell > .spool-main { display: flex !important; }' })
        await sleep(400)
      }
      const before = await readCard(page)
      const card = before && before.card
      const borderOk = Boolean(card && card.border.every((w) => w === '1px') && card.color.every((c) => c === before.grey && c !== before.ring))
      const noBar = Boolean(card && !/inset/.test(card.shadow) && card.shadow === before.shadow)
      const lifted = Boolean(card && /matrix\(1,\s*0,\s*0,\s*1,\s*0,\s*-1\)/.test(card.transform))
      const plain = Boolean(before && before.other && before.other.border.every((w) => w === '0px'))
      ok(`${tag}: selected card has a 1px soft-grey border on all four sides`, borderOk, card && { border: card.border, color: card.color, grey: before.grey, ring: before.ring })
      ok(`${tag}: selected card has no left bar and a soft grey drop shadow`, noBar, card && { shadow: card.shadow, want: before.shadow })
      ok(`${tag}: selected card is lifted 1px`, lifted, card && { transform: card.transform })
      ok(`${tag}: an unselected card has no border`, plain, before && before.other)

      await page.$eval('article.msg.selected', (el) => el.focus({ focusVisible: true }))
      await sleep(50)
      const focused = await readCard(page)
      const f = focused && focused.card
      const focusOk = Boolean(
        f && f.focusVisible
        && f.outlineStyle !== 'none'
        && parseFloat(f.outlineWidth) > 0
        && parseFloat(f.outlineWidth) <= 3
        && f.outlineColor === focused.ring
        && f.border.every((w) => w === '1px')
        && !/inset/.test(f.shadow),
      )
      ok(`${tag}: keyboard focus stays visible, one colour, at most 3px`, focusOk, f && {
        focusVisible: f.focusVisible,
        outlineWidth: f.outlineWidth,
        outlineStyle: f.outlineStyle,
        outlineColor: f.outlineColor,
        ring: focused.ring,
      })

      if (vp.name === 'phone') {
        const h = before && before.heading
        const phoneOk = Boolean(h && h.label === 'none' && h.border === '1px' && (h.shadow === 'none' || !/inset/.test(h.shadow)))
        ok(`${tag}: phone topic heading keeps its own 1px border and no left bar`, phoneOk, h)
      }

      if (vp.name === 'desktop' && before && before.box && before.box.width > 0) {
        /* the click focused the card, so the ring is up. The shot is the
           resting selected card: grey border and shadow, ring off. */
        await page.evaluate(() => { const a = document.activeElement; if (a && a.blur) a.blur() })
        await sleep(50)
        const rested = await readCard(page)
        const b = (rested && rested.box && rested.box.width > 0) ? rested.box : before.box
        const clip = {
          x: Math.max(0, b.x - 12),
          y: Math.max(0, b.y - 16),
          width: Math.min(b.width + 24, vp.width - Math.max(0, b.x - 12)),
          height: Math.min(b.height + 32, vp.height - Math.max(0, b.y - 16)),
        }
        const shot = join(SHOT_DIR, `${theme}-desktop.png`)
        await page.screenshot({ path: shot, clip })
        console.log(`  SHOT ${shot}`)
      }
      await page.close()
    }
  }
} finally {
  await browser.close().catch(() => {})
  await server.stop()
}

console.log(`SHOT_DIR=${SHOT_DIR}`)
const failed = results.filter((r) => !r.ok)
if (failed.length) {
  console.error(`FAIL ${failed.length} selected-topic-card assertion(s)`)
  process.exit(1)
}
console.log(`PASS selected-topic-card ${results.length}`)
