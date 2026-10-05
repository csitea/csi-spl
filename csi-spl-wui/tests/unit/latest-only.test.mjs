// Refactor round 3, row 8: a slow older read must not overwrite a newer one.
// The five loaders (MergeConfirmDialog, TopicDeleteDialog, PersonActivityDialog,
// ActAsPicker, pages/archive.vue) share utils/latest-only.mjs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createLatest } from '../../src/utils/latest-only.mjs'

/** a fake read the test resolves by hand, in any order */
function deferred() {
  let resolve
  const promise = new Promise((r) => { resolve = r })
  return { promise, resolve }
}

describe('createLatest: only the newest request may write', () => {
  it('two interleaved loads: the slow older one does not win', async () => {
    const latest = createLatest()
    const shown = { value: '' }
    async function load(read) {
      const mine = latest.next()
      const got = await read.promise
      if (!latest.isLatest(mine)) return
      shown.value = got
    }
    const older = deferred()
    const newer = deferred()
    const a = load(older)
    const b = load(newer)
    newer.resolve('new')
    await b
    older.resolve('old')
    await a
    assert.equal(shown.value, 'new')
  })
  it('a token stays latest until the next one, and each tracker counts on its own', () => {
    const one = createLatest()
    const two = createLatest()
    const t1 = one.next()
    assert.equal(one.isLatest(t1), true)
    assert.equal(two.isLatest(t1), false)
    const t2 = one.next()
    assert.equal(one.isLatest(t1), false)
    assert.equal(one.isLatest(t2), true)
  })
})
