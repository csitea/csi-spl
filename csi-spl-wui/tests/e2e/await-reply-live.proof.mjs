// SPL-1994 live proof: on the DEPLOYED bundle, a person's post the hub has
// received shows the spinning hourglass (on the topic row), and it goes away
// once an agent posts in that topic. The rules and the mock checks are
// tests/e2e/await-reply.test.mjs; this proves the served build.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     CHANNEL=<slug with an agent member> [TENANT=t1] [REPLY_CMD=<shell>] \
//     [ANIM=rotate|hourglass|robot|brain] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/await-reply-live.proof.mjs
//
//   0 only with ANIM (SPL-2027): pick it in Settings -> Appearance
//   1 sign in, open /channel/<CHANNEL>, post a new topic (a unique needle)
//   2 its row carries [data-test=await-reply] once the hub has it, spinning
//     (data-state=spin) with the picked animation (rotate when no ANIM):
//     screenshot await-reply-live-1-<anim>.png (+ -zoom, the row at 3x)
//   2b only for rotate (SPL-2043): the row zoomed at 3x three times, 3 s
//     apart (-rotate-1..3.png), each a different drawing
//   3 only with REPLY_CMD: run it with $TASK = the topic's msg_id (an agent's
//     answer into that topic, e.g. do_spl_desk_reply), then the mark is gone:
//     screenshot await-reply-live-2-gone.png. Without it the step is SKIP.
// CONTROL: before the post, the needle's row does not exist (no mark can be
// counted from an older row). The password is read from PW_FILE and never
// printed. Exit 0 = every step PASS (a SKIP is not a FAIL).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const CHANNEL = need('CHANNEL')
const TENANT = process.env.TENANT || 't1'
const REPLY_CMD = process.env.REPLY_CMD || ''
const ANIM = process.env.ANIM || ''
const WANT = ANIM || 'rotate'
/* rotate shows one of its drawings (SPL-2043); a single pick is itself */
const drawsWant = (anim) => (WANT === 'rotate' ? ['hourglass', 'robot', 'brain'].includes(anim) : anim === WANT)
const BOX = 'form.composer.omnibox--global textarea'
/* a plain token: the WUI renders an ISO time in a body as a local date */
const NEEDLE = `await-reply proof ${Date.now().toString(36)}`
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, needle: NEEDLE, steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok === null ? 'SKIP' : ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

/* the needle's topic row and its mark, read from the page */
const rowOf = (p) => p.evaluate((n) => {
  const row = [...document.querySelectorAll('.feed-body article.msg')].find((a) => a.innerText.includes(n))
  if (!row) return null
  const m = row.querySelector('[data-test=await-reply]')
  return { msgId: row.getAttribute('data-msg-id'), mark: m ? { state: m.getAttribute('data-state'), anim: m.getAttribute('data-anim'), role: m.getAttribute('role'), label: m.getAttribute('aria-label') } : null }
}, NEEDLE)

async function waitRow(p, pred, ms) {
  const end = Date.now() + ms
  let r = null
  while (Date.now() < end) {
    r = await rowOf(p)
    if (pred(r)) return r
    await sleep(500)
  }
  return r
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signed, { url: p.url() })
  if (signed) {
    await sleep(2500)
    if (ANIM) {
      await p.goto(`${BASE}/channel/${encodeURIComponent(CHANNEL)}?settings=appearance`, { waitUntil: 'networkidle2', timeout: 60000 })
      const opt = `[data-test=await-anim-setting] [data-test=await-anim-${ANIM}]`
      const shown = await p.waitForSelector(opt, { timeout: 30000 }).then(() => true, () => false)
      if (shown) await p.click(opt)
      const on = shown && await p.evaluate((s) => document.querySelector(s).checked, opt)
      step(`pick ${ANIM} in Settings -> Appearance`, Boolean(on))
      await p.screenshot({ path: join(OUT, `await-reply-live-0-settings-${ANIM}.png`) })
    }
    await p.goto(`${BASE}/channel/${encodeURIComponent(CHANNEL)}`, { waitUntil: 'networkidle2', timeout: 60000 })
    await p.waitForSelector(BOX, { timeout: 30000 })
    step('CONTROL the needle has no row before the post', (await rowOf(p)) === null)
    await p.type(BOX, NEEDLE)
    await p.keyboard.press('Enter')
    const r = await waitRow(p, (x) => x && x.mark, 30000)
    step(`the received post spins the ${WANT} on its topic row`,
      Boolean(r && r.mark && r.mark.state === 'spin' && r.mark.role === 'status' && drawsWant(r.mark.anim)), r || {})
    await p.screenshot({ path: join(OUT, `await-reply-live-1-${WANT}.png`) })
    const row = r && r.msgId && await p.$(`.feed-body article.msg[data-msg-id="${r.msgId}"]`)
    if (row) {
      await p.setViewport({ width: 1440, height: 900, deviceScaleFactor: 3 })
      const b = await row.boundingBox()
      if (b) await p.screenshot({ path: join(OUT, `await-reply-live-1-${WANT}-zoom.png`), clip: { x: b.x, y: b.y, width: b.width, height: Math.min(b.height, 120) } })
      if (b && WANT === 'rotate') {
        /* the drawings follow the wall clock in 3 s slots; a 3x screenshot
           takes over a second, so sample on a fixed schedule from the middle
           of a slot rather than 3 s after the previous shot */
        const t0 = Date.now() + 3000 + 1500 - (Date.now() % 3000)
        const seen = []
        for (let i = 1; i <= 3; i++) {
          await sleep(Math.max(0, t0 + (i - 1) * 3000 - Date.now()))
          seen.push((await rowOf(p))?.mark?.anim || null)
          await p.screenshot({ path: join(OUT, `await-reply-live-1-rotate-${i}.png`), clip: { x: b.x, y: b.y, width: b.width, height: Math.min(b.height, 120) } })
        }
        step('rotate: three shots 3 s apart show three different drawings', new Set(seen).size === 3 && seen.every(drawsWant), { seen })
      }
      await p.setViewport({ width: 1440, height: 900 })
    }
    res.msg_id = r && r.msgId
    if (!REPLY_CMD || !res.msg_id) {
      step('an agent answers and the hourglass goes away', null, { why: REPLY_CMD ? 'no msg_id' : 'no REPLY_CMD' })
    } else {
      execFileSync('bash', ['-c', REPLY_CMD], { env: { ...process.env, TASK: res.msg_id }, stdio: 'inherit' })
      const g = await waitRow(p, (x) => x && !x.mark, 60000)
      step('an agent answers and the hourglass goes away', Boolean(g && !g.mark), g || {})
      await p.screenshot({ path: join(OUT, 'await-reply-live-2-gone.png') })
    }
  }
} finally {
  await browser.close()
}
res.ok = res.steps.length > 0 && res.steps.every((s) => s.ok !== false)
writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
process.exit(res.ok ? 0 : 1)
