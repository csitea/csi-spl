// P5-06: the mock hub's list drops `description` like the hub's sheet read;
// get(ref) keeps it. CONTROL: the store row itself still holds the text.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createMockIssues, MOCK_ISSUES_SEED_KEY } from '../../src/utils/issues.mjs'

test('the mock list carries no description, get(ref) does', () => {
  const store = new Map([[MOCK_ISSUES_SEED_KEY, '3']])
  globalThis.localStorage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) }
  try {
    const mock = createMockIssues({ me: 'HUM-1' })
    const rows = mock.list('').issues
    assert.ok(rows.length >= 4, `seeded rows: ${rows.length}`)
    assert.deepEqual(rows.filter((i) => i.description !== '').map((i) => i.key), [])
    assert.equal(mock.get('SPL-2').issue.description, 'mock issue 1 text')
  } finally {
    delete globalThis.localStorage
  }
})
