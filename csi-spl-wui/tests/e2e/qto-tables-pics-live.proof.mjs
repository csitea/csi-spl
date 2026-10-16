// c-292 live proof of tables and pictures in a Qto document (SPL-2201, Qto
// gap G6 and the rendered table check of its brief; spec 137 unified-fs.md
// section 7). Signs in through the WUI form, then, with the member's own
// session, builds a throwaway document "(delete me) Qto tables and pictures"
// over the hub's doctree API: one level-1 section per md page (PAGES, the 3
// most table-heavy ones by default), its '## ' sections under it, bodies as
// written; and a "Pictures" section whose text links
// ![..](delete-me.assets/01-architecture.webp), uploaded with PUT
// /{doc}/assets/{path} (the bytes of the repo's system-guide picture).
// Then, on a desktop (1280x900) and a phone (390x844) viewport, it records
// per page: the pipe tables in its md (outside fences) against the <table>
// elements the view rendered and their row counts, and the page's sideways
// scroll; and the picture: loaded, inside the screen, its alt text shown.
// Screenshots: tables-<page>-desktop / -phone (the page's first table),
// picture-desktop / -phone. The document is deleted again unless KEEP=1.
// WRITES one document (and one picture) in the workspace: a TEST tenant only.
//
//   BASE=https://<host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=e2e] [PAGES=<repo-relative md>,...] [KEEP=1] [CHROME_PATH=...] \
//     node tests/e2e/qto-tables-pics-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const REPO = join(dirname(fileURLToPath(import.meta.url)), '../../..')
const PAGES = (process.env.PAGES || 'csi-spl-doc/doc/md/spool-cli-reference.md,csi-spl-doc/doc/md/naming-and-parlance.md,csi-spl-doc/doc/md/guides/devops-guide.md').split(',')
const PIC = 'csi-spl-doc/doc/md/guides/system-guide.assets/01-architecture.webp'
const ASSET = 'delete-me.assets/01-architecture.webp'
mkdirSync(OUT, { recursive: true })

/* a page as sections: its '## ' sections (outside fences) with their text; the
   text before the first one is the page's own body. Its pipe tables: a header
   row followed by a |---| delimiter row, with the rows up to the first line
   that is not a table row. */
const FENCE = /^ {0,3}(`{3,}|~{3,})/
function pageOf(rel) {
  const lines = readFileSync(join(REPO, rel), 'utf8').split('\n')
  const out = { rel, name: basename(rel, '.md'), intro: [], sections: [], tables: [] }
  let fence = '', cur = null
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i]
    const f = l.match(FENCE)
    if (fence) { if (f && f[1][0] === fence[0] && f[1].length >= fence.length) fence = ''; (cur ? cur.body : out.intro).push(l); continue }
    if (f) { fence = f[1]; (cur ? cur.body : out.intro).push(l); continue }
    if (/^# /.test(l) && !cur && !out.sections.length) continue
    const h = l.match(/^## (.*)$/)
    if (h) { cur = { title: h[1].trim(), body: [] }; out.sections.push(cur); continue }
    if (/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(l) && l.includes('|') && i > 0 && lines[i - 1].includes('|')) {
      let rows = 0
      for (let j = i + 1; j < lines.length && lines[j].trim().startsWith('|'); j++) rows++
      out.tables.push(rows)
    }
    ;(cur ? cur.body : out.intro).push(l)
  }
  return out
}

const pages = PAGES.map(pageOf)
const puppeteer = await loadPuppeteer()
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const STEP = 30000
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let hub = null
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => ({}))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.on('request', (r) => {
    const m = r.url().match(/^(.*)\/v1\/workspace\/doctree(?:[/?]|$)/)
    if (m) hub = { base: m[1], auth: r.headers().authorization || '' }
  })
  await p.setViewport({ width: 1280, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/workspace/docs'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.startsWith('/login'), { timeout: STEP }).catch(() => null)
  step('native sign-in', !p.url().includes('/login'), { url: p.url() })
  if (!p.url().includes('/workspace/docs')) await p.goto(BASE + '/workspace/docs', { waitUntil: 'networkidle2' })
  await p.waitForFunction(() => true, { timeout: 1000 })
  for (let i = 0; i < 40 && !hub; i++) await sleep(250)
  step('the docs page called the hub (its base and auth are known)', Boolean(hub), { base: hub?.base })

  /* the document, built over the hub with the member's session */
  const title = `(delete me) Qto tables and pictures ${Date.now()}`
  const pic = readFileSync(join(REPO, PIC)).toString('base64')
  const built = await p.evaluate(async (h, title, pages, asset, pic) => {
    const headers = { 'content-type': 'application/json', ...(h.auth ? { authorization: h.auth } : {}) }
    const api = `${h.base}/v1/workspace/doctree`
    const call = async (method, path, body) => {
      const r = await fetch(api + path, { method, headers, credentials: 'include', body: body ? JSON.stringify(body) : undefined })
      const j = await r.json().catch(() => ({}))
      if (!r.ok) throw new Error(`${method} ${path}: ${r.status} ${JSON.stringify(j)}`)
      return j
    }
    const d = await call('POST', '', { title })
    let rev = d.rev
    const add = async (anchor, t, body) => {
      const r = await call('POST', `/${d.id}/items`, { rev, anchor, where: 'child', title: t, body })
      rev = r.rev
      return r.item
    }
    for (const pg of pages) {
      const top = await add(d.root, pg.name, pg.intro.join('\n').trim() + '\n')
      for (const s of pg.sections) await add(top, s.title, s.body.join('\n').trim() + '\n')
    }
    await add(d.root, 'Pictures', `A picture an md page brought in, its link as written:\n\n![Spool Hub architecture](${asset})\n`)
    const bytes = Uint8Array.from(atob(pic), (c) => c.charCodeAt(0))
    const put = await fetch(`${api}/${d.id}/assets/${asset}`, { method: 'PUT', headers: { 'content-type': 'image/webp', ...(h.auth ? { authorization: h.auth } : {}) }, credentials: 'include', body: bytes })
    return { doc: d.id, put: put.status, putBody: await put.json().catch(() => ({})) }
  }, hub, title, pages.map(({ name, intro, sections }) => ({ name, intro, sections })), ASSET, pic).catch((e) => ({ error: String(e) }))
  res.doc = built.doc
  step('the document is built: each page and its sections, the picture uploaded under its relative path', Boolean(built.doc && built.put === 200), built)

  const view = async (vp, label) => {
    await p.setViewport(vp)
    await p.goto(`${BASE}/workspace/docs?doc=${res.doc}&view=doc`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=ws-doc-md] table', { timeout: STEP }).catch(() => null)
    await p.waitForFunction(() => [...document.querySelectorAll('[data-test=ws-doc-md]')].every((e) => !e.classList.contains('wsdoc__run--plain')), { timeout: STEP }).catch(() => null)
    await sleep(1500)
    for (const pg of pages) {
      const got = await p.evaluate((name) => {
        const rows = [...document.querySelectorAll('[data-test=ws-doc-row]')]
        const i = rows.findIndex((r) => r.querySelector('[data-test=ws-doc-text], h1, h2, h3, h4')?.textContent?.includes(name) || r.textContent.trim().startsWith(name))
        const own = []
        for (let j = i; j >= 0 && j < rows.length; j++) {
          if (j > i && /^\d+$/.test(rows[j].dataset.outline || '') ) break
          own.push(rows[j])
        }
        const tables = own.flatMap((r) => [...r.querySelectorAll('[data-test=ws-doc-md] table')])
        const first = tables[0]
        if (first) first.scrollIntoView({ block: 'start' })
        return {
          found: i >= 0,
          tables: tables.length,
          rows: tables.map((t) => t.querySelectorAll('tbody tr').length),
          wide: tables.filter((t) => t.getBoundingClientRect().width > (t.parentElement?.getBoundingClientRect().width ?? innerWidth) + 1).length,
          pageScrollX: document.documentElement.scrollWidth - innerWidth,
          pipeText: own.filter((r) => /^\s*\|.*\|\s*$/m.test([...r.querySelectorAll('[data-test=ws-doc-md]')].map((m) => m.textContent).join('\n'))).length,
        }
      }, pg.name)
      await sleep(400)
      await p.screenshot({ path: `${OUT}/tables-${pg.name}-${label}.png` })
      const want = pg.tables
      step(`${label}: ${pg.rel}: ${want.length} pipe tables render as ${want.length} <table>, rows as written, no sideways page scroll`,
        got.found && got.tables === want.length && got.rows.join() === want.join() && got.pageScrollX <= 0 && got.pipeText === 0,
        { want: { tables: want.length, rows: want.join() }, got: { ...got, rows: got.rows.join() } })
    }
    await p.waitForFunction(() => [...document.querySelectorAll('[data-test=ws-doc-asset-img]')].some((i) => i.complete && i.naturalWidth > 0), { timeout: STEP }).catch(() => null)
    const img = await p.evaluate(() => {
      const f = document.querySelector('[data-test=ws-doc-asset]')
      const i = f?.querySelector('img')
      if (f) f.scrollIntoView({ block: 'center' })
      const r = i?.getBoundingClientRect()
      return { shown: Boolean(f), w: i?.naturalWidth ?? 0, fits: Boolean(r && r.right <= innerWidth + 1), alt: i?.alt ?? '', caption: f?.querySelector('figcaption')?.textContent?.trim() ?? '' }
    })
    await sleep(400)
    await p.screenshot({ path: `${OUT}/picture-${label}.png` })
    step(`${label}: the picture ![..](${ASSET}) shows, read from the asset route, inside the screen, its alt text under it`,
      img.shown && img.w > 0 && img.fits && img.alt === 'Spool Hub architecture' && img.caption === 'Spool Hub architecture', img)
  }
  if (res.doc) {
    await view({ width: 1280, height: 900 }, 'desktop')
    await view({ width: 390, height: 844, isMobile: true, hasTouch: true }, 'phone')
  }

  if (process.env.KEEP !== '1' && res.doc && hub) {
    const del = await p.evaluate(async (h, d) => {
      const headers = h.auth ? { authorization: h.auth } : {}
      const sub = await (await fetch(`${h.base}/v1/workspace/doctree/${d}/subtree`, { headers, credentials: 'include' })).json().catch(() => ({}))
      const r = await fetch(`${h.base}/v1/workspace/doctree/${d}?rev=${sub.rev}`, { method: 'DELETE', headers, credentials: 'include' })
      return r.status
    }, hub, res.doc)
    step('the proof document is deleted again', del >= 200 && del < 300, { status: del })
  }
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(res.steps.length && res.steps.every((s) => s.ok) ? 0 : 1)
