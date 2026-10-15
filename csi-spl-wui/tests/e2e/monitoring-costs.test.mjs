// SPL-2048: e2e tests for Monitoring -> Costs.
// Tests rendering in the mock bundle (no login/auth).

// Mock cost data for the current month
const mockCosts = {
  month: '2026-10',
  from: '2026-10-01',
  to: '2026-10-31',
  status: 'so_far',
  scope: 'workspace',
  days: 31,
  days_ended: 15,
  total: { usd_micros: 10000000, eur_micros: 9000000 },
  parts: [
    { source: 'GCP', project_or_vendor: 'csi-spl-dev', kind: 'Compute', origin: 'billing', units: 100, usd_micros: 5000000, eur_micros: 4500000, list_value_micros: 6000000, days: 15, hand: false, pct: 50 },
    { source: 'Tokens', project_or_vendor: 'claude', kind: 'Agent hours', origin: 'usage', units: 200, usd_micros: 3000000, eur_micros: 2700000, list_value_micros: 0, days: 15, hand: false, pct: 30 },
    { source: 'Tokens', project_or_vendor: 'qwen', kind: 'Agent hours', origin: 'usage', units: 100, usd_micros: 2000000, eur_micros: 1800000, list_value_micros: 0, days: 15, hand: false, pct: 20 }
  ],
  coverage: [
    { source: 'GCP', ok: 15, partial: 0, missing: 0, unrecorded: 0, days: 15 },
    { source: 'Tokens', ok: 15, partial: 0, missing: 0, unrecorded: 0, days: 15 }
  ]
}

// Mock empty cost data
const mockEmptyCosts = {
  month: '2026-10',
  from: '2026-10-01',
  to: '2026-10-31',
  status: 'so_far',
  scope: 'workspace',
  days: 31,
  days_ended: 15,
  total: { usd_micros: 0, eur_micros: 0 },
  parts: [],
  coverage: [
    { source: 'GCP', ok: 0, partial: 0, missing: 15, unrecorded: 0, days: 15 }
  ]
}

export default async function testMonitoringCosts(page) {
  // Test 1: tab is visible in the mock bundle
  await page.goto('/monitoring')
  await page.waitForSelector('[data-test="monitoring-tab-costs"]')

  // Test 2: renders table and pie from mock data
  await page.goto('/monitoring/costs')
  await page.waitForSelector('[data-test="monitoring-costs"]')
  await page.waitForSelector('.monitoring-costs-table tbody tr')
  await page.waitForSelector('[data-test="costs-pie-chart"]')

  // Test 3: shows empty state for no data
  await page.route('/v1/tenant/costs?month=2026-10', route => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(mockEmptyCosts)
  }))
  await page.goto('/monitoring/costs')
  await page.waitForSelector('.monitoring-costs-empty')
  const text = await page.textContent('.monitoring-costs-empty')
  if (!text.includes('No cost data yet for GCP')) throw new Error('Empty state text mismatch')
}