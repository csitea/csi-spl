// The live store's `filtered` computed (stores/live.ts) re-evaluated after a
// new message (CLE-35075): a ref wraps every row in a deep proxy, a
// shallowRef hands the computed the raw rows. The tree decides which one
// the store uses; the computed is the store's own expression.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { computed, ref, shallowRef } from 'vue'
import { bench, src, SRC } from './lib/bench.mjs'

const { newestFirst, matchesSearch, mergeById } = await src('utils/feed.mjs')
const shallow = /const messages = shallowRef</.test(readFileSync(join(SRC, 'stores/live.ts'), 'utf8'))

function rows(n) {
  return Array.from({ length: n }, (_, i) => ({
    msg_id: 'm' + i, task_id: 't', from: 'CLE-1', body: 'body ' + i, ts: '2026-09-28T10:' + String(i % 60).padStart(2, '0') + ':00Z',
    files: [{ name: 'a.txt', bytes: 3 }], reactions: [{ emoji: '👍', count: 1, by: ['HUM-1'] }],
  }))
}

for (const n of [300, 1000]) {
  const messages = shallow ? shallowRef(rows(n)) : ref(rows(n))
  const search = ref('')
  const filtered = computed(() => newestFirst(messages.value.filter((m) => matchesSearch(m, search.value))))
  let i = 0
  bench(`feed-rows rows=${n} shallow=${shallow} (one live message, then the list)`, () => {
    messages.value = mergeById(messages.value, [{ msg_id: 'live' + i++, task_id: 't', ts: '2026-09-28T11:00:00Z', body: 'x' }]).rows
    return filtered.value.length
  })
}
