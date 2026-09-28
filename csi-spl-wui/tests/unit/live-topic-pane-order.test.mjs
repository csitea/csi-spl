// CLE-35075: LiveTopicPane shows pane.newestFirst as it is for a task-rooted
// topic instead of sorting it again. That is only the same list if the
// store's order is already newestFirst's order: newestFirst of a windowed
// newestFirst is the identity, for any rows (equal times, missing ids).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { newestFirst, windowed, matchesSearch } from '../../src/utils/feed.mjs'

function rows(seed, n) {
  let s = seed
  const rnd = (k) => { s = (s * 1103515245 + 12345) % 2147483648; return s % k }
  return Array.from({ length: n }, () => {
    const r = { msg_id: rnd(8) === 0 ? '' : 'm' + rnd(n), body: 'x' }
    const t = '2026-09-28T10:00:' + String(rnd(15)).padStart(2, '0') + 'Z'
    if (rnd(3) === 0) r.received_at = t
    else r.ts = t
    return r
  })
}

describe('pane order needs no second sort', () => {
  for (const seed of [3, 11, 500]) {
    it(`seed ${seed}: newestFirst(store rows) === store rows`, () => {
      const all = rows(seed, 80)
      for (const visible of [30, 60, 1000]) {
        const store = windowed(newestFirst(all.filter((m) => matchesSearch(m, ''))), visible).rows
        assert.deepEqual(newestFirst(store), store)
      }
    })
  }

  it('LiveTopicPane sorts only the message-rooted list', () => {
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/LiveTopicPane.vue'), 'utf8')
    assert.match(vue, /if \(!messageRooted\.value\) return pane\.newestFirst/)
  })
})
