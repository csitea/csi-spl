// specs/038 live proof: an AGENT's channel post is shown in the channel feed
// to a signed-in member, as a new topic - the same place a human's post goes.
// Signs one member in, opens /channel/<CHANNEL>, and requires a row carrying
// NEEDLE (a label from the agent's post, e.g. its msg_id prefix or body) and
// the agent id FROM. Screenshot + results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<channel member> PW_FILE=<0600 file> OUT=<dir> \
//     CHANNEL=<slug> NEEDLE=<text of the agent's post> FROM=<agent id> [TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/agent-channel-post-live.proof.mjs
//
// CONTROL: the same page must NOT show CONTROL_NEEDLE (the body of a post the
// hub refused, when given) - a feed that shows everything would pass the
// positive half vacuously. The password is read from PW_FILE and never
// printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const CHANNEL = need('CHANNEL')
const NEEDLE = need('NEEDLE')
const FROM = need('FROM')
const CONTROL = process.env.CONTROL_NEEDLE || ''
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), channel: CHANNEL, steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signed, { url: p.url() })
  if (signed) {
    await new Promise((r) => setTimeout(r, 2500)) // let the session settle before a full navigation
    await p.goto(BASE + '/channel/' + encodeURIComponent(CHANNEL), { waitUntil: 'networkidle2' })
    const shown = await p.waitForFunction((n) => document.body.innerText.includes(n), { timeout: 20000 }, NEEDLE).then(() => true, () => false)
    step(`#${CHANNEL} shows the agent's post`, shown, { needle: NEEDLE })
    const byAgent = await p.evaluate((f) => document.body.innerText.includes(f), FROM)
    step(`…attributed to ${FROM}`, byAgent)
    if (CONTROL) {
      const leaked = await p.evaluate((n) => document.body.innerText.includes(n), CONTROL)
      step('CONTROL the refused post is not in the feed', !leaked, { control: CONTROL })
    }
    await p.screenshot({ path: `${OUT}/agent-channel-post-${CHANNEL}.png` })
  }
} finally {
  await browser.close()
}
res.ok = res.steps.length > 0 && res.steps.every((s) => s.ok)
writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
process.exit(res.ok ? 0 : 1)
