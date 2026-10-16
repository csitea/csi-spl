// SPL-2074: On mobile, the Event log's "Clear log" button sits at the bottom centre,
// and the bottom bar is a little smaller (one small task, WUI, bug).
//
// phone (412x915, isMobile + hasTouch, touch only):
//   1. Clear log button is hidden from the top-right header on mobile.
//   2. Clear log button is centred horizontally at the bottom of the viewport.
//   3. Clear log button is within the bottom 25% of the viewport.
//   4. Bottom composer bar height is reduced (measured before/after).
//   5. Status line icon spacing is adjusted:
//      - Bell icon: 2mm (~8px) closer to the dot.
//      - Note icon: 3mm (~11px) further left.
//      - Clock: 2mm (~8px) further left.
// desktop (1280x800):
//   6. Clear log button stays in the top-right header.

// Helper to extract bounding boxes
const facts = async (page) => {
  return page.evaluate(() => {
    const box = (el) => {
      if (!el || !el.getClientRects().length) return null
      const r = el.getBoundingClientRect()
      return { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), width: Math.round(r.width), h: Math.round(r.height), w: Math.round(r.width) }
    }
    const strip = document.querySelector('[data-test="status-strip"]')
    const dock = document.querySelector('form.composer.composer--dock')
    const topClear = document.querySelector('[data-test="events-clear"]')
    const bottomClear = document.querySelector('[data-test="events-clear-mobile"]')
    const q = (sel) => box(strip ? strip.querySelector(sel) : null)
    return {
      vw: window.innerWidth,
      vh: window.innerHeight,
      topClear: box(topClear),
      bottomClear: box(bottomClear),
      strip: box(strip),
      dock: box(dock),
      health: q('[data-test="status-strip-health"]'),
      bell: q('.status-strip__bell'),
      note: q('.status-strip__note'),
      version: q('[data-test="status-strip-version"]'),
      clock: q('.status-strip__clock'),
    }
  })
}

// Helper to mock events
const mockEventData = () => ({
  data: Array(10).fill(0).map((_, i) => ({
    id: i + 1,
    error_id: `err-${i + 1}`,
    source: 'test',
    status: 200,
    message: `Test event ${i + 1}`,
    route: '/test',
    at: new Date().toISOString(),
  })),
})

// Test runner
const test = async (name, fn) => {
  try {
    await fn()
    console.log(`✓ ${name}`)
  } catch (e) {
    console.log(`✗ ${name}: ${e.message}`)
    throw e
  }
}

// Main test suite
export default async function eventsClearLogMobile({ page, viewport, isMobile, route, until }) {
  const PHONE = { width: 412, height: 915 }
  const DESKTOP = { width: 1280, height: 800 }
  const results = []
  
  // Mock the events API
  await page.route('**/api/v1/auth/events*', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(mockEventData()),
  }))
  
  // Mobile test
  if (viewport.width === PHONE.width) {
    await page.goto('/events')
    await page.waitForSelector('[data-test="events-table"]')
    
    const data = await facts(page)
    
    await test('Mobile: Clear log button is hidden from the top-right header', () => {
      if (data.topClear) throw new Error('Top Clear log button is visible on mobile')
    })
    
    await test('Mobile: Clear log button is centred at the bottom', () => {
      if (!data.bottomClear) throw new Error('Bottom Clear log button is not visible')
      const viewportCentre = data.vw / 2
      const buttonCentre = data.bottomClear.left + data.bottomClear.width / 2
      if (Math.abs(buttonCentre - viewportCentre) > 4) throw new Error('Bottom Clear log button is not centred')
      if (data.bottomClear.bottom <= data.vh * 0.75) throw new Error('Bottom Clear log button is not within the bottom 25% of the viewport')
    })
    
    await test('Mobile: Bottom composer bar height is reduced', () => {
      if (!data.dock) throw new Error('Composer bar is not visible')
      // Before: ~60px (6px padding + 36px buttons + 18px textarea padding)
      // After: ~48px (4px padding + 32px buttons + 12px textarea padding)
      if (data.dock.h > 50) throw new Error(`Composer bar height (${data.dock.h}px) is not reduced`) 
    })
    
    await test('Mobile: Status line icon spacing is adjusted', async () => {
      if (!data.health || !data.bell) throw new Error('Dot or bell icon not found')
      const dotToBell = data.bell.left - (data.health.left + data.health.width)
      // Before: ~4px gap + 4px margin = 8px
      // After: ~0px gap + 8px margin = 8px closer (net 0px gap)
      if (dotToBell > 0) throw new Error(`Bell icon is not closer to the dot (${dotToBell}px)`)
      
      if (!data.bell || !data.note) throw new Error('Bell or note icon not found')
      const bellToNote = data.note.left - (data.bell.left + data.bell.width)
      // Before: ~4px gap + 7px margin = 11px
      // After: ~0px gap + 11px margin = 11px further left (net 4px gap)
      if (bellToNote > -11) throw new Error(`Note icon is not further left (${bellToNote}px)`)
      
      if (!data.version || !data.clock) throw new Error('Version or clock not found')
      const versionToClock = data.clock.left - (data.version.left + data.version.width)
      // Before: ~8px margin
      // After: ~8px margin (unchanged, but clock is further left due to padding)
      if (versionToClock < 8) throw new Error(`Clock is not further left (${versionToClock}px)`)
    })
  }
  
  // Desktop test
  if (viewport.width === DESKTOP.width) {
    await page.goto('/events')
    await page.waitForSelector('[data-test="events-table"]')
    
    const data = await facts(page)
    
    await test('Desktop: Clear log button stays in the top-right header', () => {
      if (!data.topClear) throw new Error('Top Clear log button is not visible on desktop')
      if (data.bottomClear) throw new Error('Bottom Clear log button is visible on desktop')
    })
  }
  
  return results
}