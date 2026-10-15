// SPL-2048: Utility functions for Monitoring -> Costs.

/**
 * Format money from micros.
 * @param {number} micros
 * @param {string} currency
 * @returns {string}
 */
export function formatMoney(micros, currency) {
  const value = micros / 1_000_000
  return new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(value)
}

/**
 * Format percentage.
 * @param {number} pct
 * @returns {string}
 */
export function formatPercentage(pct) {
  return `${Math.round(pct)}%`
}

/**
 * Group pie slices, combining parts ≤ 1% into "other".
 * @param {Array<{ source: string, project_or_vendor: string, kind: string, pct: number }>} parts
 * @param {Function} t - i18n function
 * @returns {Array<{ label: string, percentage: number, value: number }>}
 */
export function groupPieSlices(parts, t) {
  if (!parts || parts.length === 0) return []
  
  const total = parts.reduce((sum, part) => sum + part.pct, 0)
  const filtered = parts.filter(part => part.pct > 1)
  const otherPct = total - filtered.reduce((sum, part) => sum + part.pct, 0)
  
  const slices = filtered.map(part => ({
    label: `${part.source}: ${part.project_or_vendor} (${part.kind})`,
    percentage: Math.round(part.pct),
    value: part.pct
  }))
  
  if (otherPct > 0) {
    slices.push({
      label: t('monitoring.costs.pie.other'),
      percentage: Math.round(otherPct),
      value: otherPct
    })
  }
  
  return slices
}