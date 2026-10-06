// Spec 096 (manual status) live proof against a deployed WUI + hub, signed
// in as an invited test member: native sign-in, Set a status from the
// reader's own row (Busy, a note, 30 minutes), the ring on the own dot and
// its words, a fresh tab gets it from the hub (roster read / welcome frames),
// then Clear status - ring gone, a fresh tab has none. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/human-status-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const NOTE = 'Status proof (spec 096)'
mkdirSync(OUT, { recursive: true })

const results = []
function step(name, ok, ev) {
  results.push({ name, ok, ev })
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

const selfDot = (p) => p.evaluate(() => {
  const d = document.querySelector('[data-test=self-status-dot]')
  return d ? { ring: d.getAttribute('data-status') || '', title: d.getAttribute('title') || '' } : null
})

/** the reader's own status as the human-status store holds it; with
    `reload`, from a fresh tab, so it came from the hub (roster read or the
    welcome's status frames), not from the picker's own write */
const storeStatus = async (p, reload = false) => {
  if (reload) {
    await p.reload({ waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: 30000 })
    await p.click('[data-testid=sidebar-tab-dm]')
    await sleep(3000)
  }
  return p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const id = pinia._s.get('roster').self?.id
    const map = pinia._s.get('human-status')?.statusByPeer || {}
    /* a JSON copy: a reactive proxy crosses the page boundary as {} */
    return JSON.parse(JSON.stringify({ id, status: map[id] || null }))
  })
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let code = 0
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('sign-in failed')
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: 30000 })
  await p.click('[data-testid=sidebar-tab-dm]')
  await p.waitForSelector('[data-testid=status-open]', { timeout: 30000 })
  await sleep(1500)

  /* a status left by an earlier failed run is cleared first */
  const before = await storeStatus(p)
  if (before.status) {
    await p.click('[data-testid=status-open]')
    await p.waitForSelector('[data-testid=status-clear]', { visible: true, timeout: 20000 })
    await p.click('[data-testid=status-clear]')
    await sleep(1500)
  }

  await p.click('[data-testid=status-open]')
  await p.waitForSelector('[data-testid=status-picker]', { visible: true, timeout: 20000 })
  await p.click('[data-testid=status-state-busy]')
  await p.type('[data-testid=status-note]', NOTE)
  await p.select('[data-testid=status-until]', '30m')
  await p.screenshot({ path: `${OUT}/picker.png` })
  await p.click('[data-testid=status-save]')
  const closed = await p.waitForSelector('[data-testid=status-picker]', { hidden: true, timeout: 15000 }).then(() => true, () => false)
  const err = await p.$eval('[data-testid=status-error]', (e) => e.textContent.trim()).catch(() => '')
  step('Save: the hub took it (picker closed, no error)', closed && !err, { err })
  await sleep(1000)
  const set = await selfDot(p)
  step('own dot: amber ring, words with the note and the end time', set?.ring === 'busy' && set.title.includes(`Busy until`) && set.title.includes(NOTE), set)
  await p.screenshot({ path: `${OUT}/status-set.png` })

  const hub = await storeStatus(p, true)
  step('a fresh tab gets it from the hub', hub.status && hub.status.state === 'busy' && hub.status.note === NOTE && !!hub.status.until, hub)

  await p.waitForFunction(() => document.querySelector('[data-test=self-status-dot]')?.getAttribute('data-status') === 'busy', { timeout: 20000 }).catch(() => null)
  const again = await selfDot(p)
  step('after a reload: still Busy', again?.ring === 'busy', again)
  await p.screenshot({ path: `${OUT}/status-after-reload.png` })

  await p.click('[data-testid=status-open]')
  await p.waitForSelector('[data-testid=status-clear]', { visible: true, timeout: 20000 })
  await p.click('[data-testid=status-clear]')
  await p.waitForSelector('[data-testid=status-picker]', { hidden: true, timeout: 15000 }).catch(() => null)
  await sleep(1000)
  const gone = await selfDot(p)
  const hub2 = await storeStatus(p, true)
  step('Clear status: ring gone, a fresh tab has none', gone?.ring === '' && !hub2.status, { gone, hub: hub2.status })
  await p.screenshot({ path: `${OUT}/status-cleared.png` })
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify(results, null, 2))
const failed = results.filter((r) => !r.ok)
console.log(`\nhuman-status-live: ${results.length - failed.length}/${results.length} PASS`)
process.exit(code || (failed.length ? 1 : 0))
