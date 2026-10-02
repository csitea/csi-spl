// Live proof for owner t1 ae24a0ef (CLE-77969): on a deployed WUI, the
// FOCUSED message box draws ONE ring and it is the white field's own outer
// edge - desktop 1440x900 and phone 390x844, dark and light. Read-only: it
// signs in, focuses the box and types nothing.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] node tests/e2e/omnibox-focus-ring-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { readFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} must be set`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/$/, '')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const TAG = process.env.TAG || new URL(BASE).hostname.split('.')[0]
mkdirSync(OUT, { recursive: true })

const results = []
const step = (name, pass, ev) => {
  results.push(pass)
  console.log(`  ${pass ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  const mod = await import(pathToFileURL(require.resolve('puppeteer-core')).href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
}

function measure(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    const field = f && f.querySelector('.omnibox-field')
    const ta = f && f.querySelector('textarea')
    if (!field || !ta) return null
    ta.focus()
    const probe = document.createElement('span')
    probe.style.color = 'var(--focus-ring)'
    document.body.appendChild(probe)
    const focusColor = getComputedStyle(probe).color
    probe.remove()
    const px = (v) => parseFloat(v) || 0
    const box = (r) => ({ l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) })
    const edges = []
    for (const [name, el] of [['field', field], ['textarea', ta]]) {
      const cs = getComputedStyle(el)
      const r = el.getBoundingClientRect()
      if (cs.outlineStyle !== 'none' && px(cs.outlineWidth) > 0 && cs.outlineColor === focusColor) {
        const o = px(cs.outlineOffset) + px(cs.outlineWidth)
        edges.push({ el: name, kind: 'outline', box: box({ left: r.left - o, top: r.top - o, right: r.right + o, bottom: r.bottom + o }) })
      }
      if (['Top', 'Right', 'Bottom', 'Left'].every((s) => px(cs[`border${s}Width`]) > 0 && cs[`border${s}Color`] === focusColor)) {
        edges.push({ el: name, kind: 'border', w: px(cs.borderTopWidth), box: box(r) })
      }
    }
    return { active: document.activeElement === ta, white: box(field.getBoundingClientRect()), edges, clip: field.getBoundingClientRect().toJSON() }
  })
}

const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent('/lobby')}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signed = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('signed in', signed, { url: p.url() })
  const build = await p.evaluate(() => fetch('/build.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null))
  console.log('  build.json ' + JSON.stringify(build))
  if (signed) {
    for (const theme of ['dark', 'light']) {
      for (const vp of [{ width: 1440, height: 900 }, { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }]) {
        const tag = `${TAG} ${vp.width} ${theme}`
        await p.evaluate((th) => { try { localStorage.setItem('spool-theme', th) } catch { /* private */ } }, theme)
        await p.setViewport(vp)
        await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
        await p.waitForSelector('form.composer.omnibox--global .omnibox-field', { timeout: 30000 }).catch(() => null)
        await new Promise((r) => setTimeout(r, 1500))
        const m = await measure(p)
        await new Promise((r) => setTimeout(r, 300))
        const file = join(OUT, `omnibox-focus-ring-${TAG}-${vp.width}-${theme}.png`)
        await p.screenshot({ path: file })
        const e = m ? m.edges : []
        step(`${tag} ONE ring, the field's own border, its outer box = the white field's outer box`,
          Boolean(m && m.active && e.length === 1 && e[0].el === 'field' && e[0].kind === 'border' && e[0].w <= 3 && ['l', 't', 'r', 'b'].every((k) => e[0].box[k] === m.white[k])),
          m && { active: m.active, edges: e, white: m.white, shot: file })
      }
    }
  }
} finally {
  await browser.close()
}
const failed = results.filter((x) => !x).length
console.log(failed ? `FAIL: ${failed}/${results.length}` : `${results.length}/${results.length} steps passed`)
process.exit(failed ? 1 : 0)
