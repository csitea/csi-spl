// Spec 130 L2b: remove the Mine/All switch from the Flow WUI (owner Q2).
// The switch is gone at 1440x900 and 390x844 (control: it exists on master).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e flow-remove-mine-all

import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

const require = createRequire(import.meta.url)
const { test } = require('@playwright/test')

const viewports = [
  { width: 1440, height: 900, name: 'desktop' },
  { width: 390, height: 844, name: 'phone' },
]

for (const { width, height, name } of viewports) {
  test(`FlowList removes Mine/All switch (${name})`, async ({ page }) => {
    await applyViewport(page, width, height)
    await page.goto(`${process.env.BASE_URL}/`, { waitUntil: 'networkidle', timeout: NAV_TIMEOUT })
    await page.waitForSelector('[data-testid="flow-head"]', { state: 'visible', timeout: NAV_TIMEOUT })
    
    // The Mine/All switch is gone.
    const mineScope = await page.$('[data-testid="flow-scope-mine"]')
    const allScope = await page.$('[data-testid="flow-scope-all"]')
    test.expect(mineScope).toBeNull()
    test.expect(allScope).toBeNull()
    
    // The chips are always visible (no v-if="flow.mineOn").
    const chips = await page.$('[data-testid="flow-chip-dm"]')
    test.expect(chips).not.toBeNull()
  })
}