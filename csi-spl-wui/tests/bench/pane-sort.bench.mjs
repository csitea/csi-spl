// LiveTopicPane's `messages` per pane update (CLE-35075): the old tree sorted
// pane.newestFirst again; the new one returns it as is (task-rooted topic).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { bench, src, SRC } from './lib/bench.mjs'

const { newestFirst, windowed } = await src('utils/feed.mjs')
const sortsAgain = !/if \(!messageRooted\.value\) return pane\.newestFirst/.test(readFileSync(join(SRC, 'components/LiveTopicPane.vue'), 'utf8'))

for (const n of [100, 1000]) {
  const all = Array.from({ length: n }, (_, i) => ({ msg_id: 'm' + i, ts: '2026-09-28T10:' + String(i % 60).padStart(2, '0') + ':00Z' }))
  const store = windowed(newestFirst(all), n).rows
  bench(`pane-sort rows=${n} sorts_again=${sortsAgain}`, () => (sortsAgain ? newestFirst(store) : store))
}
