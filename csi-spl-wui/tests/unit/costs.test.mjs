// SPL-2048: Unit tests for Monitoring -> Costs.
// Tests money formatting, pie logic, and empty states.

import { describe, it, expect } from 'vitest'
import { formatMoney, formatPercentage, groupPieSlices } from '../../src/pages/monitoring/costs/utils.mjs'

// Mock i18n for tests
const t = (key) => {
  const translations = {
    'monitoring.costs.pie.other': 'Other'
  }
  return translations[key] || key
}

describe('formatMoney', () => {
  it('formats USD from micros', () => {
    expect(formatMoney(1_000_000, 'USD')).toBe('$1.00')
    expect(formatMoney(1_500_000, 'USD')).toBe('$1.50')
    expect(formatMoney(1_000_000_000, 'USD')).toBe('$1,000.00')
  })
  
  it('formats EUR from micros', () => {
    expect(formatMoney(1_000_000, 'EUR')).toBe('€1.00')
    expect(formatMoney(1_500_000, 'EUR')).toBe('€1.50')
  })
})

describe('formatPercentage', () => {
  it('formats percentage', () => {
    expect(formatPercentage(42.5)).toBe('43%')
    expect(formatPercentage(0)).toBe('0%')
  })
})

describe('groupPieSlices', () => {
  it('groups parts ≤ 1% into "other"', () => {
    const parts = [
      { source: 'A', project_or_vendor: 'X', kind: 'Y', usd_micros: 100, pct: 50 },
      { source: 'B', project_or_vendor: 'X', kind: 'Y', usd_micros: 100, pct: 1 },
      { source: 'C', project_or_vendor: 'X', kind: 'Y', usd_micros: 100, pct: 0.5 }
    ]
    const slices = groupPieSlices(parts, t)
    expect(slices.length).toBe(2)
    expect(slices[0].label).toBe('A: X (Y)')
    expect(slices[0].percentage).toBe(50)
    expect(slices[1].label).toBe('Other')
    expect(slices[1].percentage).toBe(2) // 1 + 0.5 rounded
  })
  
  it('returns empty array for no parts', () => {
    expect(groupPieSlices([], t)).toEqual([])
  })
})
