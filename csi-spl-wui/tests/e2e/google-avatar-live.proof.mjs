// CLE-3406 live proof: the top-right avatar is the person's own Google
// picture, against a DEPLOYED WUI (its real bundle, its real CSP).
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> OUT=<dir> \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/google-avatar-live.proof.mjs
//
// 1. render: the two auth-v1 answers the corner reads (GET /api/v1/auth/session,
//    GET /api/v1/auth/avatar) are served by the browser for a Google session,
//    so the real bundle is shown a Google user with a picture, as a member
//    (hum) and NOT yet a member (no hum). The corner must show exactly that
//    picture (pixel check), with zero CSP violations. CONTROLS: avatar 404 ->
//    initials (not yet a member) / identicon (member), never a picture.
// 2. google: the WUI's Google button leads to accounts.google.com with the
//    profile scope (the picture claim) and this env's callback; stops there.
// The hub half (claim -> stored picture -> route) is proven by the Go tests
// (internal/auth/avatar_own_test.go) and, for a real account, by the owner's
// sign-in plus the hub log / bucket checks in the CLE-3406 report.
// Screenshots + results.json to OUT. Exit 0 = every step PASS.
import { writeFileSync, mkdirSync } from 'node:fs'
import { deflateSync } from 'node:zlib'
import { loadPuppeteer, need } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const AUTH_BASE = need('AUTH_BASE').replace(/\/+$/, '')
const OUT = need('OUT')
mkdirSync(OUT, { recursive: true })

// A solid-colour PNG no default avatar draws, so the pixel check cannot pass by accident.
const PIC_RGB = [0xd9, 0x30, 0x25]
function solidPng(size, [r, g, b]) {
  const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0 })
  const crc = (buf) => { let c = 0xffffffff; for (const x of buf) c = crcTable[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0 }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length)
    const td = Buffer.concat([Buffer.from(type), data])
    const c = Buffer.alloc(4); c.writeUInt32BE(crc(td))
    return Buffer.concat([len, td, c])
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2
  const row = Buffer.concat([Buffer.from([0]), Buffer.from(Array.from({ length: size }, () => [r, g, b]).flat())])
  const raw = Buffer.concat(Array.from({ length: size }, () => row))
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))])
}
const PIC = solidPng(96, PIC_RGB)

const puppeteer = await loadPuppeteer()
const res = { base: BASE, auth_base: AUTH_BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })

const cors = { 'access-control-allow-origin': BASE, 'access-control-allow-credentials': 'true', 'cache-control': 'no-store' }
async function page({ claims, picture }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  const seen = { avatar: [], violations: [] }
  await p.setRequestInterception(true)
  p.on('request', (rq) => {
    const u = rq.url()
    if (u.startsWith(AUTH_BASE + '/api/v1/auth/session')) {
      return rq.respond({ status: 200, headers: cors, contentType: 'application/json', body: JSON.stringify(claims) })
    }
    if (u.startsWith(AUTH_BASE + '/api/v1/auth/avatar')) {
      seen.avatar.push(u.slice(AUTH_BASE.length))
      return picture
        ? rq.respond({ status: 200, headers: cors, contentType: 'image/png', body: PIC })
        : rq.respond({ status: 404, headers: cors, contentType: 'application/json', body: '{"error":"not_found"}' })
    }
    return rq.continue()
  })
  await p.evaluateOnNewDocument(() => {
    window.__csp = []
    document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`))
  })
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  await new Promise((r) => setTimeout(r, 1500))
  const corner = trig
    ? await trig.evaluate(async (b) => {
      const pic = b.querySelector('[data-test=user-menu-picture]')
      const img = b.querySelector('img')
      const out = { picture: !!pic, src: img ? img.getAttribute('src').slice(0, 40) : '', text: b.textContent.trim(), px: null }
      if (pic) {
        await pic.decode().catch(() => {})
        const c = document.createElement('canvas'); c.width = 8; c.height = 8
        const g = c.getContext('2d'); g.drawImage(pic, 0, 0, 8, 8)
        out.px = Array.from(g.getImageData(4, 4, 1, 1).data.slice(0, 3))
      }
      return out
    })
    : null
  seen.violations = await p.evaluate(() => window.__csp)
  return { p, ctx, trig, corner, seen }
}

const near = (a, b) => Array.isArray(a) && a.every((v, i) => Math.abs(v - b[i]) <= 3)
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const now = Math.floor(Date.now() / 1000)
  const google = { v: 1, p: 'google', sub: 'proof-google-sub', email: 'someone@example.com', name: 'FirstName LastName', iat: now, exp: now + 3600 }
  const cases = [
    ['not yet a member (no hum)', { ...google }, true],
    ['member (hum)', { ...google, hum: 'HUM-1', t: 't1' }, true],
    ['CONTROL not yet a member, no picture', { ...google }, false],
    ['CONTROL member, no picture', { ...google, hum: 'HUM-1', t: 't1' }, false],
  ]
  for (const [tag, claims, picture] of cases) {
    const { p, ctx, trig, corner, seen } = await page({ claims, picture })
    const file = `${OUT}/corner-${tag.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}.png`
    if (trig) {
      const box = await trig.boundingBox()
      await p.screenshot({ path: file, clip: { x: Math.max(0, box.x - 240), y: 0, width: Math.min(1280 - Math.max(0, box.x - 240), box.width + 260), height: Math.max(64, box.y + box.height + 12) } })
      await p.screenshot({ path: file.replace(/\.png$/, '-page.png') })
    }
    const asked = seen.avatar.length > 0 && seen.avatar.every((u) => u === `/api/v1/auth/avatar?at=${claims.iat}`)
    const noCsp = seen.violations.length === 0
    if (picture) {
      step(`${tag}: corner shows the Google picture`, !!corner?.picture && corner.src.startsWith('data:image/png;base64,') && near(corner.px, PIC_RGB) && asked && noCsp,
        { corner, avatar_requests: seen.avatar, csp_violations: seen.violations, screenshot: file })
    } else {
      const want = claims.hum ? corner?.src.startsWith('data:image/svg+xml') : corner?.text === 'FL'
      step(`${tag}: no picture -> ${claims.hum ? 'identicon' : 'initials'}`, !!corner && !corner.picture && !!want && asked && noCsp,
        { corner, avatar_requests: seen.avatar, csp_violations: seen.violations, screenshot: file })
    }
    await ctx.close()
  }

  // 2. the real Google leg, up to Google's own page.
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?redirect=%2Flobby', { waitUntil: 'networkidle2' })
  const btn = await p.waitForSelector('a[href*="/api/v1/auth/google/start"]', { timeout: 20000 }).catch(() => null)
  const href = btn ? await btn.evaluate((a) => a.href) : ''
  if (btn) await Promise.all([p.waitForNavigation({ waitUntil: 'networkidle2', timeout: 30000 }).catch(() => null), btn.click()])
  const g = new URL(p.url())
  const scope = g.searchParams.get('scope') || ''
  const cb = g.searchParams.get('redirect_uri') || ''
  await p.screenshot({ path: `${OUT}/google-login-page.png` })
  step('google: the WUI button reaches accounts.google.com asking for the profile (picture) scope', g.hostname === 'accounts.google.com' &&
    scope.split(' ').includes('profile') && cb === BASE + '/api/v1/auth/google/callback' && href.startsWith(AUTH_BASE),
  { start: href.replace(/state=[^&]*/, 'state=…'), landed: g.origin + g.pathname, scope, redirect_uri: cb })
  await ctx.close()
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const failed = res.steps.filter((s) => !s.ok).length
console.log(failed ? `FAILED ${failed}/${res.steps.length}` : `ALL ${res.steps.length} PASS`)
process.exit(failed ? 1 : 0)
