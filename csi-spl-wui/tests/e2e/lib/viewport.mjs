// Viewport proof for the browser e2e harness.
//
// no-x-scroll labels every check with the intended size (390x844 / 1280x800).
// If Chrome never applied that size, innerWidth stays the window default
// (~1560 on some runners) and the suite reports every route as an x-scroll
// failure — a false red. Prove the viewport before measuring: set, read
// innerWidth/innerHeight back, retry once, then FAIL with
// "harness: viewport not applied". Never return page metrics at the wrong size.
//
// Call setPageViewport before navigation (first paint). Call applyViewport
// AFTER the document is up: about:blank has no <meta viewport>, so
// isMobile:true there reports the 980px mobile layout width, not 390.
// Navigation can also drop Emulation.setDeviceMetricsOverride; proving
// after load catches that.
//
// E2E_VIEWPORT_NOOP=1 skips the set call so the guard can be shown to fire.
export const VIEWPORT_NOT_APPLIED = 'harness: viewport not applied'

/** Window large enough for both CI viewports (390x844 and 1280x800). */
export const CHROME_LAUNCH_ARGS = [
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--disable-gpu',
  '--window-size=1280,900',
  '--force-device-scale-factor=1',
]

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export function isViewportHarnessError(err) {
  return String(err?.message || err).includes(VIEWPORT_NOT_APPLIED)
}

function wantOf(vp) {
  return { width: Number(vp.width), height: Number(vp.height) }
}

function puppeteerSpec(vp) {
  const want = wantOf(vp)
  return {
    width: want.width,
    height: want.height,
    deviceScaleFactor: vp.deviceScaleFactor ?? 1,
    isMobile: vp.isMobile ?? want.width < 800,
    hasTouch: vp.hasTouch ?? want.width < 800,
  }
}

function cdpSpec(vp) {
  const want = wantOf(vp)
  return {
    width: want.width,
    height: want.height,
    deviceScaleFactor: 1,
    mobile: vp.mobile ?? want.width < 800,
  }
}

function mismatch(got, want) {
  if (!got || got.width !== want.width || got.height !== want.height) {
    return `${VIEWPORT_NOT_APPLIED} (want ${want.width}x${want.height}, got ${got?.width}x${got?.height})`
  }
  return ''
}

export async function setPageViewport(page, vp) {
  if (process.env.E2E_VIEWPORT_NOOP === '1') return
  await page.setViewport(puppeteerSpec(vp))
}

export async function setPageViewportCdp(cdp, vp) {
  if (process.env.E2E_VIEWPORT_NOOP === '1') return
  await cdp.send('Emulation.setDeviceMetricsOverride', cdpSpec(vp))
}

export async function applyViewport(page, vp) {
  const want = wantOf(vp)
  const read = async () =>
    page.evaluate(() => ({ width: window.innerWidth, height: window.innerHeight }))

  await setPageViewport(page, vp)
  await sleep(50)
  let got = await read()
  if (!mismatch(got, want)) return got
  await setPageViewport(page, vp)
  await sleep(50)
  got = await read()
  const msg = mismatch(got, want)
  if (!msg) return got
  throw new Error(msg)
}

export async function applyViewportCdp(cdp, vp) {
  const want = wantOf(vp)
  const read = async () => {
    const ev = await cdp.send('Runtime.evaluate', {
      expression: '({width: window.innerWidth, height: window.innerHeight})',
      returnByValue: true,
    })
    return ev.result?.value
  }

  await setPageViewportCdp(cdp, vp)
  await sleep(50)
  let got = await read()
  if (!mismatch(got, want)) return got
  await setPageViewportCdp(cdp, vp)
  await sleep(50)
  got = await read()
  const msg = mismatch(got, want)
  if (!msg) return got
  throw new Error(msg)
}
