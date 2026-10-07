// t1 ccaee528 live proof against a deployed WUI + hub, signed in as an
// invited test member: the account menu's "Change picture" uploads a png
// through the file picker, the avatar shows exactly those bytes, a reload
// still does (the hub serves it), the same at 390 px, then "Remove picture"
// puts the member back as it was. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/own-picture-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { deflateSync, crc32 } from 'node:zlib'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const results = []
function step(name, ok, ev) {
  results.push({ name, ok, ev })
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

/** A 64 x 64 png in four coloured quarters (as tests/e2e/own-picture.test.mjs). */
function png() {
  const chunk = (type, data) => {
    const len = Buffer.alloc(4)
    len.writeUInt32BE(data.length)
    const td = Buffer.concat([Buffer.from(type), data])
    const crc = Buffer.alloc(4)
    crc.writeUInt32BE(crc32(td) >>> 0)
    return Buffer.concat([len, td, crc])
  }
  const n = 64
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(n, 0)
  ihdr.writeUInt32BE(n, 4)
  ihdr.set([8, 2, 0, 0, 0], 8)
  const rows = []
  for (let y = 0; y < n; y++) {
    const row = [0]
    for (let x = 0; x < n; x++) {
      const q = (y < n / 2 ? 0 : 2) + (x < n / 2 ? 0 : 1)
      row.push(...[[230, 80, 60], [60, 160, 230], [250, 200, 40], [70, 190, 110]][q])
    }
    rows.push(Buffer.from(row))
  }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))])
}

const bytes = png()
const want = 'data:image/png;base64,' + bytes.toString('base64')
const file = join(OUT, 'upload.png')
writeFileSync(file, bytes)

const pic = (p) => p.evaluate(() => document.querySelector('[data-test=user-menu-trigger] img[data-test=user-menu-picture]')?.getAttribute('src') || '')
const openMenu = async (p) => {
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-change-picture]', { visible: true, timeout: 15000 })
  await sleep(400)
}
const ready = async (p) => {
  await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 })
  await sleep(2500)
}
async function remove(p) {
  await openMenu(p)
  await p.click('[data-test=user-menu-remove-picture]')
  await p.waitForFunction(() => !document.querySelector('[data-test=user-menu-trigger] img[data-test=user-menu-picture]'), { timeout: 15000 }).catch(() => null)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let code = 0
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => null)
  step('build.json', !!build, build)
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('sign-in failed')
  await ready(p)
  const before = await pic(p)
  /* an upload left by an earlier failed run is removed first */
  if (before === want) await remove(p)
  const start = await pic(p)

  await openMenu(p)
  await p.screenshot({ path: `${OUT}/menu-1440.png` })
  const [chooser] = await Promise.all([p.waitForFileChooser({ timeout: 10000 }), p.click('[data-test=user-menu-change-picture]')])
  await chooser.accept([file])
  const shown = await p.waitForFunction((w) => document.querySelector('[data-test=user-menu-trigger] img[data-test=user-menu-picture]')?.getAttribute('src') === w, { timeout: 20000 }, want).then(() => true, () => false)
  const err = await p.$eval('[data-test=user-menu-picture-error]', (e) => e.textContent.trim()).catch(() => '')
  step('Change picture: the hub took it, the avatar shows exactly the upload', shown && !err, { err })
  await openMenu(p)
  await p.screenshot({ path: `${OUT}/changed-1440.png` })

  await p.reload({ waitUntil: 'networkidle2' })
  await ready(p)
  step('after a reload the hub serves the upload', (await pic(p)) === want)

  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.reload({ waitUntil: 'networkidle2' })
  await ready(p)
  step('390 px: the avatar is the upload', (await pic(p)) === want)
  await openMenu(p)
  await p.screenshot({ path: `${OUT}/changed-390.png` })
  step('390 px: Change and Remove picture are in the sheet',
    await p.$eval('[data-test=user-menu-remove-picture]', (e) => e.getBoundingClientRect().height >= 44).catch(() => false))
  await p.click('[data-test=user-menu-scrim]').catch(() => null)
  await sleep(300)

  await remove(p)
  await p.reload({ waitUntil: 'networkidle2' })
  await ready(p)
  const end = await pic(p)
  step('Remove picture: back to what it was, also after a reload', end !== want && end === start, { start: start.slice(0, 30), end: end.slice(0, 30) })
  await p.screenshot({ path: `${OUT}/removed-390.png` })
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify({ base: BASE, at: new Date().toISOString(), steps: results }, null, 2))
const failed = results.filter((r) => !r.ok)
console.log(`\nown-picture-live: ${results.length - failed.length}/${results.length} PASS`)
process.exit(code || (failed.length ? 1 : 0))
