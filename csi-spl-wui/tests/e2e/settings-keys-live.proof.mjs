// specs/023 T030 live proof of Settings → Keys against a deployed WUI + hub:
// native sign-in through the WUI form, the user menu's Settings entry lands
// on the GitHub-style page, Keys shows an active key (the default pair is
// generated in the browser on a first visit), both key files download and
// are checked (private = seed||pub and signs for the public key; the POST
// bodies the page sent never carried the private key), a public key made
// here is uploaded through the form and becomes active (fingerprint checked),
// history keeps the replaced key, and mobile has no x-scroll.
// Screenshots, the downloaded PUBLIC files and results.json go to OUT; the
// downloaded private key is checked in memory and deleted, never kept.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/settings-keys-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const DL = join(OUT, 'downloads')
mkdirSync(DL, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const sshBlob = (pub) => {
  const name = Buffer.from('ssh-ed25519')
  const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b }
  return Buffer.concat([u32(name.length), name, u32(pub.length), pub])
}
const fingerprint = (pub) => 'SHA256:' + createHash('sha256').update(sshBlob(pub)).digest('base64').replace(/=+$/, '')
async function waitFile(suffix, ms = 15000) {
  const end = Date.now() + ms
  while (Date.now() < end) {
    const f = readdirSync(DL).find((n) => n.endsWith(suffix) && !n.endsWith('.crdownload'))
    if (f) return join(DL, f)
    await sleep(200)
  }
  return ''
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const posted = []
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  const p = await browser.newPage()
  const cdp = await p.createCDPSession()
  await cdp.send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: DL })
  p.on('request', (r) => { if (r.method() === 'POST' && r.url().includes('/api/v1/auth/keys')) posted.push(r.postData() || '') })
  await p.setViewport({ width: 1280, height: 800 })

  // 1. native sign-in through the WUI form
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url() })
  if (!trig) throw new Error('sign-in failed')

  // 2. user menu → Settings → the GitHub-style page → Keys
  await sleep(1500)
  await trig.click()
  await p.click('[data-test=user-menu-settings]')
  await p.waitForSelector('[data-test=settings-nav]', { timeout: 15000 })
  const nav = await p.evaluate(() => [...document.querySelectorAll('[data-test=settings-nav] a')].map((a) => a.getAttribute('data-test')))
  step('settings: left nav of sections, lands on profile', p.url().includes('/settings/profile') && nav.includes('settings-nav-keys'), { url: p.url(), nav })
  await p.click('[data-test=settings-nav-keys]')
  const act = await p.waitForSelector('[data-test=keys-active]', { timeout: 30000 }).catch(() => null)
  const firstFp = act ? await p.$eval('[data-test=keys-fingerprint]', (e) => e.textContent.trim()) : ''
  const firstPub = act ? await p.$eval('[data-test=keys-public]', (e) => e.textContent.trim()) : ''
  const freshPair = !!(await p.$('[data-test=keys-private]'))
  step('keys: an active key (default pair made in this browser when there was none)', !!act && p.url().includes('/settings/keys'),
    { url: p.url(), fingerprint: firstFp, freshPairInThisPage: freshPair })
  await p.screenshot({ path: `${OUT}/keys-desktop.png`, fullPage: true })

  // 3. downloads: public (pin form), OpenSSH, and the private key when this page made it
  if (!freshPair) {
    // an earlier visit made the active key: make a new pair so the private download can be proven
    await p.click('[data-test=keys-regenerate]')
    await p.waitForSelector('[data-test=keys-private]', { timeout: 30000 })
  }
  const pubNow = await p.$eval('[data-test=keys-public]', (e) => e.textContent.trim())
  await p.click('[data-test=keys-download-public]')
  const pubFile = await waitFile('.pub')
  await p.click('[data-test=keys-download-openssh]')
  const sshFile = await waitFile('.openssh.pub')
  await p.click('[data-test=keys-download-private]')
  const keyFile = await waitFile('.key')
  const pubB = pubFile ? Buffer.from(readFileSync(pubFile, 'utf8').trim(), 'base64') : Buffer.alloc(0)
  const privText = keyFile ? readFileSync(keyFile, 'utf8').trim() : ''
  const privB = Buffer.from(privText, 'base64')
  if (keyFile) rmSync(keyFile)
  let signs = false
  if (privB.length === 64 && pubB.length === 32) {
    const nodePriv = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), privB.subarray(0, 32)]), format: 'der', type: 'pkcs8' })
    const nodePub = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), pubB]), format: 'der', type: 'spki' })
    signs = verify(null, Buffer.from('spool'), nodePub, sign(null, Buffer.from('spool'), nodePriv))
  }
  const sshLine = sshFile ? readFileSync(sshFile, 'utf8').trim() : ''
  step('download public key (.pub = pin form)', pubB.length === 32 && pubB.toString('base64') === pubNow, { file: pubFile.replace(OUT, '<OUT>') })
  step('download OpenSSH public key', sshLine.startsWith('ssh-ed25519 ') && Buffer.from(sshLine.split(' ')[1], 'base64').equals(sshBlob(pubB)),
    { file: sshFile.replace(OUT, '<OUT>'), comment: sshLine.split(' ')[2] || '' })
  step('download private key (.key = spool seed||pub, signs for .pub; deleted after the check)',
    privB.length === 64 && privB.subarray(32).equals(pubB) && signs, { bytes: privB.length, signs })
  step('the private key never left the page (no POST body carried it)', posted.length > 0 && !posted.some((b) => privText && b.includes(privText)),
    { posts: posted.length })

  // 4. upload a new public key made here; it becomes the active key
  const { publicKey } = generateKeyPairSync('ed25519')
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(12)
  const upload = 'ssh-ed25519 ' + sshBlob(raw).toString('base64') + ' proof@spool'
  await p.type('[data-test=keys-upload-text]', upload)
  await p.click('[data-test=keys-upload-submit]')
  await p.waitForSelector('[data-test=keys-notice]', { timeout: 15000 }).catch(() => null)
  await sleep(800)
  const fpAfter = await p.$eval('[data-test=keys-fingerprint]', (e) => e.textContent.trim()).catch(() => '')
  const pubAfter = await p.$eval('[data-test=keys-public]', (e) => e.textContent.trim()).catch(() => '')
  const history = await p.$$eval('[data-test=keys-history] li', (l) => l.map((e) => e.textContent.replace(/\s+/g, ' ').trim())).catch(() => [])
  step('upload a new public key: it is the active key', fpAfter === fingerprint(raw) && pubAfter === raw.toString('base64'),
    { fingerprint: fpAfter, expected: fingerprint(raw) })
  step('history keeps the replaced key', history.length >= 2 && history.some((h) => h.includes(pubNow ? fingerprint(pubB) : '')), { history: history.slice(0, 4) })
  // CONTROL: pasting a private key is refused before anything is sent
  const before = posted.length
  await p.$eval('[data-test=keys-upload-text]', (e) => { e.value = '' })
  await p.type('[data-test=keys-upload-text]', privText || 'x'.repeat(88))
  await p.click('[data-test=keys-upload-submit]')
  await sleep(600)
  const errText = await p.$eval('[data-test=keys-error]', (e) => e.textContent.trim()).catch(() => '')
  step('CONTROL: a pasted private key is refused and never posted', !!errText && posted.length === before, { error: errText })
  await p.$eval('[data-test=keys-upload-text]', (e) => { e.value = ''; e.dispatchEvent(new Event('input')) })
  await p.screenshot({ path: `${OUT}/keys-after-upload.png`, fullPage: true })

  // 5. mobile: the nav collapses above the content, no x-scroll
  await p.setViewport({ width: 390, height: 844 })
  await sleep(600)
  const xs = await xscroll(p)
  step('mobile /settings/keys no x-scroll', xs <= 0, { xscroll: xs })
  await p.screenshot({ path: `${OUT}/keys-mobile.png`, fullPage: true })
  // deep link
  await p.goto(BASE + '/settings/keys', { waitUntil: 'networkidle2' })
  const deep = await p.waitForSelector('[data-test=keys-active]', { timeout: 20000 }).catch(() => null)
  step('deep link /settings/keys', !!deep, { url: p.url() })
} catch (e) {
  step('run', false, { error: String(e && e.message) })
} finally {
  await browser.close()
  for (const f of existsSync(DL) ? readdirSync(DL) : []) if (f.endsWith('.key')) rmSync(join(DL, f))
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
