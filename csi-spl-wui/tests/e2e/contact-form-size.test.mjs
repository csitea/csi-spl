// SPL-5504 (owner, topic 50a68313): the contact form's inputs are 30% taller
// and 35% narrower than before, in a card; on a phone they fill the card.
// Before, measured in Chrome on this mock bundle (origin/master e9ea1ef32,
// 2026-11-14, every cell below equal): input 608 x 21 px at 1440, 346 x 21 at 390.
//   S1  1440 and 1920, new and edit form: input / field width = 0.65 (+-0.01),
//       height 21 x 1.30; at 1440 also the absolute 608 x 0.65
//   S2  Save / Cancel span the input width, the four inputs the same size
//   S3  390, new and edit form: the input fills the card, no sideways scroll
// CONTROL: S0 asserts the form is on screen, so a page that never opened
// cannot pass a size check. Red control: on e9ea1ef32 S1 fails (608 x 21).
//
//   BASE_URL=<generated mock bundle> OUT=<dir> node tests/e2e/contact-form-size.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const BEFORE = { width: 608, height: 21 }
const WANT = { width: BEFORE.width * 0.65, height: BEFORE.height * 1.3 }
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const WIDE = { name: '1920', width: 1920, height: 1080 }
const PHONE = { name: '390', width: 390, height: 664 }
const ME = { role: 'admin', permissions: ['members.invite'], contacts: true }
const OLIVE = { contact_id: 'k-out', first_name: 'Olive', last_name: 'Outer', email: 'olive.outer@example.com', phone: '+358 40 000 0000', google: false, member_id: null }

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument((me, list) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.me', JSON.stringify(me))
      localStorage.setItem('spool.mock.contacts', JSON.stringify(list))
      const theme = localStorage.getItem('spool.test.theme')
      if (theme) localStorage.setItem('spool-theme', theme)
    } catch { /* opaque origin on the very first document */ }
  }, ME, [OLIVE])

  const openForm = async (vp, kind) => {
    await setPageViewport(p, vp)
    await p.goto(server.base + (kind === 'new' ? '/people/contact/new' : '/people/contact/k-out'), { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    if (kind === 'edit') {
      await p.waitForSelector('[data-test=contact-edit]', { visible: true, timeout: 10000 })
      await p.click('[data-test=contact-edit]')
    }
    const shown = await p.waitForSelector('[data-test=contact-form]', { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
    await sleep(300)
    return shown
  }
  const measure = () => p.evaluate(() => {
    const box = (e) => { const b = e.getBoundingClientRect(); return { w: +b.width.toFixed(2), h: +b.height.toFixed(2) } }
    const form = document.querySelector('[data-test=contact-form]')
    const cs = getComputedStyle(form)
    const inner = form.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
    const field = document.querySelector('[data-test=contact-input-first_name]').closest('label').getBoundingClientRect().width
    const inputs = ['first_name', 'last_name', 'email', 'phone'].map((k) => box(document.querySelector(`[data-test=contact-input-${k}]`)))
    const save = document.querySelector('[data-test=contact-save]').getBoundingClientRect()
    const cancel = document.querySelector('[data-test=contact-cancel]').getBoundingClientRect()
    return { inputs, field: +field.toFixed(2), inner: +inner.toFixed(2), actions: +(cancel.right - save.left).toFixed(2), xscroll: document.documentElement.scrollWidth > document.documentElement.clientWidth }
  })
  const near = (a, b, tol) => Math.abs(a - b) <= tol

  for (const kind of ['new', 'edit']) {
    for (const vp of [DESKTOP, WIDE]) {
      ok(`S0 ${kind} CONTROL: the form is on screen at ${vp.name}`, await openForm(vp, kind))
      const d = await measure()
      const i = d.inputs[0]
      const ratio = +(i.w / d.field).toFixed(4)
      ok(`S1 ${kind} ${vp.name}: input / field width is 0.65, height ${WANT.height} px`, near(ratio, 0.65, 0.01) && near(i.h, WANT.height, 0.5), { input: i, field: d.field, ratio })
      if (vp === DESKTOP) ok(`S1 ${kind} 1440: the input is ${WANT.width} px wide (608 x 0.65)`, near(i.w, WANT.width, 1), i)
      ok(`S2 ${kind} ${vp.name}: all four inputs the same size`, d.inputs.every((x) => x.w === i.w && x.h === i.h), d.inputs)
      ok(`S2 ${kind} ${vp.name}: Save / Cancel span the input width`, near(d.actions, i.w, 1), { actions: d.actions, input: i.w })
      if (OUT) await p.screenshot({ path: `${OUT}/contact-form-${kind}-${vp.name}.png` })
    }

    ok(`S0 ${kind} CONTROL: the form is on screen at 390`, await openForm(PHONE, kind))
    const m = await measure()
    ok(`S3 ${kind} 390: the input fills the card, keeps the new height`, near(m.inputs[0].w, m.inner, 1) && near(m.inputs[0].h, WANT.height, 0.5), { input: m.inputs[0], inner: m.inner })
    ok(`S3 ${kind} 390: no sideways scroll`, !m.xscroll)
    if (OUT) await p.screenshot({ path: `${OUT}/contact-form-${kind}-390.png` })
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`contact-form-size: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
