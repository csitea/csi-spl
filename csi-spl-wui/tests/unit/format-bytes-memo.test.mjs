// CLE-35075: formatBytes reuses one Intl.NumberFormat per locale + digits.
// It is pure, so the cached formatter must print exactly what a fresh one does.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { formatBytes } from '../../src/utils/channel-feed.mjs'

describe('formatBytes with a cached formatter', () => {
  it('matches a fresh Intl.NumberFormat for every locale, unit and repeat', () => {
    for (const locale of ['en', 'fi', 'de', 'bg', 'he', 'ar']) {
      for (const n of [0, 1, 1023, 1024, 2048, 1536000, 10 * 1024 * 1024]) {
        const digits = n < 1024 ? 0 : 1
        const x = n < 1024 ? n : n < 1024 * 1024 ? n / 1024 : n / (1024 * 1024)
        const unit = n < 1024 ? 'B' : n < 1024 * 1024 ? 'KiB' : 'MiB'
        const want = `${new Intl.NumberFormat(locale, { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(x)} ${unit}`
        assert.equal(formatBytes(n, locale), want)
        assert.equal(formatBytes(n, locale), want, 'second call, cached formatter')
      }
    }
  })
  it('a bad locale still falls back to toFixed, every time', () => {
    assert.equal(formatBytes(2048, 'not a locale!!'), '2.0 KiB')
    assert.equal(formatBytes(2048, 'not a locale!!'), '2.0 KiB')
    assert.equal(formatBytes(2048), '2.0 KiB')
  })
})
