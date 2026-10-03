// Live proof (owner, t1 f4e6c677) on a deployed WUI + hub, read-only: the
// Flow tab's number is the theme grey (--color-bg-3), not the red; Channels
// and Direct messages carry the red number = the hub's Flow unread split
// (unread.channels / unread.dms, hub 54d9c616), with no pip beside it. Both
// themes (light, dark) and both widths (desktop, phone). Writes nothing.
//
//   BASE=https://<tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHROME_PATH=...] node tests/e2e/flow-rail-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const label = (n) => (n > 0 ? (n > 99 ? '99+' : String(n)) : '')

/** The rail as the viewer sees it, the hub's unread from the Flow store, and both badge fills. */
function read(p) {
  return p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const flow = pinia?._s?.get('flow')
    const text = (id) => document.querySelector(`[data-testid=sidebar-tab-${id}]`)?.textContent.trim() || ''
    const fill = (sel) => { const e = document.querySelector(sel); return e ? getComputedStyle(e).backgroundColor : '' }
    /* the scoped rule itself, on a probe inside the Flow tab: holds at a 0 count too */
    const tab = document.querySelector('[data-testid=sidebar-tab-flow]')
    const probe = (cls) => {
      if (!tab) return ''
      const s = document.createElement('span')
      for (const a of tab.getAttributeNames()) if (a.startsWith('data-v-')) s.setAttribute(a, '')
      s.className = cls
      tab.appendChild(s)
      const bg = getComputedStyle(s).backgroundColor
      s.remove()
      return bg
    }
    const token = (v) => { const s = document.createElement('span'); s.style.background = `var(${v})`; document.body.appendChild(s); const bg = getComputedStyle(s).backgroundColor; s.remove(); return bg }
    return {
      theme: document.documentElement.getAttribute('data-theme') || '',
      unread: flow?.unread ? { ...flow.unread } : null,
      flow: text('flow-count'), channels: text('channels-count'), dm: text('dm-count'),
      pips: { channels: !!document.querySelector('[data-testid=sidebar-tab-channels-unread]'), dm: !!document.querySelector('[data-testid=sidebar-tab-dm-unread]') },
      fills: { flow: fill('[data-testid=sidebar-tab-flow-count]'), channels: fill('[data-testid=sidebar-tab-channels-count]'), dm: fill('[data-testid=sidebar-tab-dm-count]') },
      neutral: probe('sidebar-tab__count sidebar-tab__count--neutral'), red: probe('sidebar-tab__count'),
      grey: token('--color-bg-3'), danger: token('--color-danger'),
    }
  })
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const inOk = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true).catch(() => false)
  step('native sign-in', inOk, { url: p.url() })
  await p.waitForFunction(() => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s?.get('flow')?.unread, { timeout: 20000 }).catch(() => {})
  await sleep(1500)
  for (const theme of ['light', 'dark']) {
    for (const [w, h, tag] of [[1280, 800, 'desktop'], [390, 844, 'phone']]) {
      await p.setViewport({ width: w, height: h })
      await p.keyboard.press('Escape')
      if (tag === 'phone') {
        /* the phone's level 1: the section strip with its numbers on screen */
        await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/'))
        await sleep(800)
        await p.click('[data-testid=sidebar-tab-dm]').catch(() => {})
      }
      await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
      await sleep(600)
      const f = await read(p)
      const u = f.unread || {}
      step(`${theme} ${tag}: the hub splits the Flow unread (channels + dms = total)`,
        Number.isInteger(u.channels) && Number.isInteger(u.dms) && u.channels + u.dms === u.total, { unread: f.unread })
      step(`${theme} ${tag}: Channels / DM numbers = the hub's unread split, no pip`,
        f.channels === label(u.channels) && f.dm === label(u.dms) && !f.pips.channels && !f.pips.dm,
        { channels: f.channels, dm: f.dm, pips: f.pips })
      step(`${theme} ${tag}: the Flow badge is the theme grey, the rail numbers the red`,
        f.neutral === f.grey && f.red === f.danger && f.neutral !== f.red
        && (!f.flow || f.fills.flow === f.grey) && (!f.dm || f.fills.dm === f.danger) && (!f.channels || f.fills.channels === f.danger),
        { neutral: f.neutral, grey: f.grey, red: f.red, fills: f.fills, flow: f.flow })
      await p.screenshot({ path: `${OUT}/flow-rail-${theme}-${tag}.png` })
    }
  }
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.steps.length}` : `${res.steps.length}/${res.steps.length} PASS`)
process.exit(failed.length ? 1 : 0)
