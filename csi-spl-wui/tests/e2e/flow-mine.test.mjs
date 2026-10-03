// Spec 062 (owner, t1 25826b7b): the Flow lists only what concerns me (Mine,
// the default), with a Facebook-like number on the Flow tab, proved in a REAL
// browser against the mock bundle. The mock derives HUM-1's flow from its feed
// (one DM to HUM-1, 7a7a...); in live mode the hub counts (FR-008).
//
//   - before the pane opens, the Flow tab shows the number 1 and the title "(1) ..."
//   - opening the Flow clears the number (Q4) and lists Mine: only 7a7a...
//   - the chips: DM 1, mention / reply 0 (dimmed, no filter); the DM chip filters
//   - All shows today's stream (every message); the choice survives a reload
//   - 1440x900 and 390x844 (the phone's level-1 strip carries the number too)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e flow-mine
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MINE = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const NEWEST = '88888888-8888-4888-8888-888888888888'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const LIST = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const COUNT = '[data-testid=sidebar-tab-flow-count]'

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

function facts(page) {
  return page.evaluate((list, count) => {
    const rows = [...document.querySelectorAll(list + ' [data-testid=left-entry]')]
    const chip = (k) => {
      const el = document.querySelector(`[data-testid=flow-chip-${k}]`)
      return el ? { n: Number(el.getAttribute('data-count')), pressed: el.getAttribute('aria-pressed') } : null
    }
    const c = document.querySelector(count)
    /* owner (t1 f4e6c677): a badge's fill, against the theme's grey and its danger red */
    const fill = (css) => {
      const probe = document.createElement('span')
      probe.style.background = css
      document.body.appendChild(probe)
      const bg = getComputedStyle(probe).backgroundColor
      probe.remove()
      return bg
    }
    const rail = (id) => document.querySelector(`[data-testid=sidebar-tab-${id}-count]`)?.textContent.trim() || ''
    return {
      fill: c ? getComputedStyle(c).backgroundColor : '',
      grey: fill('var(--color-bg-3)'),
      red: fill('var(--color-danger)'),
      dmFill: document.querySelector('[data-testid=sidebar-tab-dm-count]') ? getComputedStyle(document.querySelector('[data-testid=sidebar-tab-dm-count]')).backgroundColor : '',
      rail: { dm: rail('dm'), channels: rail('channels'), channelsPip: Boolean(document.querySelector('[data-testid=sidebar-tab-channels-unread]')) },
      ids: rows.map((e) => e.getAttribute('data-msg-id')),
      count: c ? c.textContent.trim() : '',
      title: document.title,
      mine: document.querySelector('[data-testid=flow-scope-mine]')?.getAttribute('aria-checked') || '',
      all: document.querySelector('[data-testid=flow-scope-all]')?.getAttribute('aria-checked') || '',
      chips: { mention: chip('mention'), reply: chip('reply'), dm: chip('dm') },
    }
  }, LIST, COUNT)
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
    await setPageViewport(p, size)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.evaluate(() => { try { localStorage.removeItem('spool.flow-scope') } catch { /* none */ } })
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)

    /* FR-005: the number before the pane opens */
    const shown = await p.waitForSelector(COUNT, { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
    let f = await facts(p)
    ok(`${tag}: the Flow tab shows the hub's number before the pane opens`, shown && f.count === '1', { count: f.count })
    ok(`${tag}: the tab title leads with it (FR-013)`, f.title.startsWith('(1) '), { title: f.title })
    ok(`${tag}: the Flow number is the theme grey, not the red (t1 f4e6c677)`, f.fill === f.grey && f.fill !== f.red, { fill: f.fill, grey: f.grey, red: f.red })
    ok(`${tag}: Direct messages carries the red number of my new DMs`, f.rail.dm === '1' && f.dmFill === f.red, { rail: f.rail, dmFill: f.dmFill })
    ok(`${tag}: Channels shows no number (nothing new in my discussions) and no pip`, f.rail.channels === '' && !f.rail.channelsPip, f.rail)

    /* Q4: opening the pane clears it; Mine (Q1 default) lists only my event */
    await p.click('[data-testid=sidebar-tab-flow]')
    await p.waitForSelector(`${LIST} [data-testid=left-entry][data-msg-id="${MINE}"]`, { visible: true, timeout: NAV_TIMEOUT })
    await p.waitForFunction((c) => !document.querySelector(c), { timeout: 5000 }, COUNT).catch(() => {})
    f = await facts(p)
    ok(`${tag}: Mine is the default`, f.mine === 'true' && f.all === 'false', { mine: f.mine, all: f.all })
    ok(`${tag}: Mine lists only what concerns me`, f.ids.length === 1 && f.ids[0] === MINE, f.ids)
    ok(`${tag}: opening the Flow clears the number`, f.count === '' && !/^\(\d+\+?\) /.test(f.title), { count: f.count, title: f.title })
    ok(`${tag}: opening the Flow keeps the DM number (it counts unread, not unseen)`, f.rail.dm === '1', f.rail)
    ok(`${tag}: the chips split the unread (DM 1, mention 0, reply 0)`, f.chips.dm?.n === 1 && f.chips.mention?.n === 0 && f.chips.reply?.n === 0, f.chips)

    /* a 0 chip does not filter; the DM chip does, and a second click clears it */
    await p.click('[data-testid=flow-chip-mention]')
    f = await facts(p)
    ok(`${tag}: a 0 chip does not filter`, f.chips.mention?.pressed === 'false' && f.ids.length === 1, f.chips.mention)
    await p.click('[data-testid=flow-chip-dm]')
    await p.waitForFunction(() => document.querySelector('[data-testid=flow-chip-dm]')?.getAttribute('aria-pressed') === 'true', { timeout: 5000 }).catch(() => {})
    f = await facts(p)
    ok(`${tag}: the DM chip filters to DMs`, f.chips.dm?.pressed === 'true' && f.ids.length === 1 && f.ids[0] === MINE, { ids: f.ids, dm: f.chips.dm })
    await p.click('[data-testid=flow-chip-dm]')

    /* FR-012: All is today's stream, and the choice survives a reload */
    await p.click('[data-testid=flow-scope-all]')
    await p.waitForSelector(`${LIST} [data-testid=left-entry][data-msg-id="${NEWEST}"]`, { visible: true, timeout: NAV_TIMEOUT })
    f = await facts(p)
    ok(`${tag}: All lists every message`, f.all === 'true' && f.ids.length > 1 && f.ids[0] === NEWEST, { n: f.ids.length, first: f.ids[0] })
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)
    await p.click('[data-testid=sidebar-tab-flow]')
    await p.waitForSelector('[data-testid=flow-scope-all]', { visible: true, timeout: NAV_TIMEOUT })
    f = await facts(p)
    ok(`${tag}: the All choice is kept in this browser`, f.all === 'true', { all: f.all })

    ok(`${tag}: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
