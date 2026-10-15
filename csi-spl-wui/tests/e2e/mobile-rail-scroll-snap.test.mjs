// Test for mobile rail scroll-snap behavior (SPL-2044).
// Ensures that only whole icons are shown at rest, and that a swipe stops on a whole icon.
// Tested at 360x800, 390x844, and 412x915.
//
//   BASE_URL=<generated bundle> node tests/e2e/mobile-rail-scroll-snap.test.mjs

import { join } from 'node:path'
import assert from 'node:assert'

const MOBILE_VIEWPORTS = [
  { name: 'small-phone', width: 360, height: 800 },
  { name: 'medium-phone', width: 390, height: 844 },
  { name: 'large-phone', width: 412, height: 915 },
]

async function setupTest(page, width, height) {
  await page.setViewportSize({ width, height })
}

async function runTest() {
  const browser = await import('./lib/browser.mjs')
  const page = await browser.newPage()
  
  for (const { name, width, height } of MOBILE_VIEWPORTS) {
    console.log(`Testing ${name} (${width}x${height})`)
    await setupTest(page, width, height)
    await page.goto(process.env.BASE_URL || 'http://localhost:3000/lobby')
    
    // Wait for the rail to load
    await page.waitForSelector('[data-testid="sidebar-rail"]')
    
    // Get the rail and its items
    const rail = await page.locator('[data-testid="sidebar-rail"]')
    const items = await rail.locator('.sidebar-tab').all()
    
    // Ensure there are items
    assert.ok(items.length > 0)
    
    // Get the rail's bounding box
    const railBox = await rail.boundingBox()
    assert.ok(railBox)
    
    // Scroll the rail by one item width
    const itemBox = await items[0].boundingBox()
    assert.ok(itemBox)
    
    // Scroll horizontally by one item width
    await rail.evaluate((el, scrollBy) => {
      el.scrollBy({ left: scrollBy, behavior: 'smooth' })
    }, itemBox.width)
    
    // Wait for scroll to settle
    await page.waitForTimeout(500)
    
    // Check that the scroll position aligns with an item
    const scrollLeft = await rail.evaluate(el => el.scrollLeft)
    const itemWidth = itemBox.width
    const tolerance = 1 // px
    
    // Ensure scrollLeft is within tolerance of an item boundary
    const isAligned = Math.abs(scrollLeft % itemWidth) < tolerance || Math.abs(scrollLeft % itemWidth - itemWidth) < tolerance
    assert.ok(isAligned, `Scroll position not aligned at ${width}x${height}`)
    
    // Check that no item is partially visible
    for (const item of items) {
      const box = await item.boundingBox()
      if (!box) continue
      
      const isFullyVisible = box.x >= railBox.x && box.x + box.width <= railBox.x + railBox.width
      const isFullyHidden = box.x + box.width <= railBox.x || box.x >= railBox.x + railBox.width
      
      assert.ok(isFullyVisible || isFullyHidden, `Item partially visible at ${width}x${height}`)
    }
  }
  
  // Test rotation (844x390)
  console.log('Testing rotation (844x390)')
  await setupTest(page, 844, 390)
  await page.goto(process.env.BASE_URL || 'http://localhost:3000/lobby')
  
  // Wait for the rail to load
  await page.waitForSelector('[data-testid="sidebar-rail"]')
  
  // Get the rail and its items
  const rail = await page.locator('[data-testid="sidebar-rail"]')
  const items = await rail.locator('.sidebar-tab').all()
  
  // Ensure there are items
  assert.ok(items.length > 0)
  
  // Get the rail's bounding box
  const railBox = await rail.boundingBox()
  assert.ok(railBox)
  
  // Scroll the rail by one item width
  const itemBox = await items[0].boundingBox()
  assert.ok(itemBox)
  
  // Scroll horizontally by one item width
  await rail.evaluate((el, scrollBy) => {
    el.scrollBy({ left: scrollBy, behavior: 'smooth' })
  }, itemBox.width)
  
  // Wait for scroll to settle
  await page.waitForTimeout(500)
  
  // Check that the scroll position aligns with an item
  const scrollLeft = await rail.evaluate(el => el.scrollLeft)
  const itemWidth = itemBox.width
  const tolerance = 1 // px
  
  // Ensure scrollLeft is within tolerance of an item boundary
  const isAligned = Math.abs(scrollLeft % itemWidth) < tolerance || Math.abs(scrollLeft % itemWidth - itemWidth) < tolerance
  assert.ok(isAligned, 'Scroll position not aligned after rotation')
  
  // Check that no item is partially visible
  for (const item of items) {
    const box = await item.boundingBox()
    if (!box) continue
    
    const isFullyVisible = box.x >= railBox.x && box.x + box.width <= railBox.x + railBox.width
    const isFullyHidden = box.x + box.width <= railBox.x || box.x >= railBox.x + railBox.width
    
    assert.ok(isFullyVisible || isFullyHidden, 'Item partially visible after rotation')
  }
  
  await page.close()
  console.log('All tests passed!')
}

runTest().catch(err => {
  console.error('Test failed:', err)
  process.exit(1)
})