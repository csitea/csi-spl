// QTO Doc Divider Drag Test
// 
// Verifies that the QTO doc view's tree | doc divider is draggable, persists its width,
// and is clamped at min/max widths. Tests at 1440px (desktop) and 390px (phone).
// 
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e qto-doc-divider
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* Get the width of the tree pane */
const treeWidth = async (p) => {
  return await p.evaluate(() => {
    const el = document.querySelector('#qto-file-tree')
    if (!el) return null
    const r = el.getBoundingClientRect()
    return Math.round(r.width)
  })
}

/* Drag the divider to a new position */
const dragDivider = async (p, xOffset) => {
  const divider = await p.waitForSelector('[data-testid=pane-divider-docs]', { visible: true, timeout: NAV_TIMEOUT })
  const box = await divider.boundingBox()
  if (!box) throw new Error('Divider not found or not visible')
  
  await p.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await p.mouse.down()
  await p.mouse.move(box.x + box.width / 2 + xOffset, box.y + box.height / 2, { steps: 5 })
  await p.mouse.up()
}

/* Check if the divider is visible */
const dividerVisible = async (p) => {
  return await p.evaluate(() => {
    const el = document.querySelector('[data-testid=pane-divider-docs]')
    if (!el) return false
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none'
  })
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme} (desktop)`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=ws-docs-layout]', { timeout: NAV_TIMEOUT })
    await sleep(500)

    /* Verify the divider is visible and draggable */
    ok(`${theme}: divider is visible`, await dividerVisible(p))
    const initialWidth = await treeWidth(p)
    ok(`${theme}: initial tree width is within bounds`, initialWidth >= 200 && initialWidth <= 500, initialWidth)

    /* Drag the divider to the right */
    await dragDivider(p, 50)
    await sleep(300)
    const draggedWidth = await treeWidth(p)
    ok(`${theme}: tree width increases after drag`, draggedWidth > initialWidth, { initialWidth, draggedWidth })

    /* Drag the divider to the left */
    await dragDivider(p, -100)
    await sleep(300)
    const draggedLeftWidth = await treeWidth(p)
    ok(`${theme}: tree width decreases after drag`, draggedLeftWidth < draggedWidth, { draggedWidth, draggedLeftWidth })

    /* Verify clamping at min width */
    await dragDivider(p, -500)
    await sleep(300)
    const minWidth = await treeWidth(p)
    ok(`${theme}: tree width is clamped at min`, minWidth >= 200, minWidth)

    /* Verify clamping at max width */
    await dragDivider(p, 500)
    await sleep(300)
    const maxWidth = await treeWidth(p)
    ok(`${theme}: tree width is clamped at max`, maxWidth <= 500, maxWidth)

    /* Reload and verify width persistence */
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=ws-docs-layout]', { timeout: NAV_TIMEOUT })
    await sleep(500)
    const persistedWidth = await treeWidth(p)
    ok(`${theme}: tree width persists after reload`, Math.abs(persistedWidth - maxWidth) <= 2, { maxWidth, persistedWidth })
    await p.close()
  }

  for (const theme of ['light', 'dark']) {
    console.log(`-- 390x844 ${theme} (phone)`)
    const vp = { width: 390, height: 844 }
    const p = await browser.newPage()
    await setPageViewport(p, vp)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=ws-docs-layout]', { timeout: NAV_TIMEOUT })
    await sleep(500)

    /* Verify the divider is not visible on a phone */
    ok(`${theme}: divider is not visible on phone`, !(await dividerVisible(p)))
    ok(`${theme}: tree is not visible on phone`, !(await p.evaluate(() => {
      const el = document.querySelector('#qto-file-tree')
      if (!el) return false
      const r = el.getBoundingClientRect()
      return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none'
    })))
    await p.close()
  }

  /* Red control: break the drag and verify the test fails */
  console.log('-- Red control: break the drag and verify the test fails')
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=ws-docs-layout]', { timeout: NAV_TIMEOUT })
  await sleep(500)

  /* Break the drag by unbinding the pointerdown event */
  await p.evaluate(() => {
    const divider = document.querySelector('[data-testid=pane-divider-docs]')
    if (divider) divider.replaceWith(divider.cloneNode(true))
  })
  await sleep(300)

  const initialWidth = await treeWidth(p)
  await dragDivider(p, 50)
  await sleep(300)
  const draggedWidth = await treeWidth(p)
  ok(`Red control: drag does not change tree width`, draggedWidth === initialWidth, { initialWidth, draggedWidth })
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)