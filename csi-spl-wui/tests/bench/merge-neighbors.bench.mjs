// LiveFeed's per-render merge work (CLE-35075): for every card, the merge
// target above and below it (MessageCard :merge-prev / :merge-next). A thread
// pane holds up to ~1000 rows of ONE task, so this is the worst case.
// A tree without threadNeighbors() runs the old per-row path.
import { bench, src } from './lib/bench.mjs'

const menu = await src('utils/msg-menu.mjs')
const canEdit = () => true

function rows(n, tasks) {
  const out = []
  for (let i = 0; i < n; i++) {
    const s = String(i).padStart(5, '0')
    out.push({ msg_id: 'm' + s, task_id: 't' + (i % tasks), is_parent: 1, ts: '2026-09-28T10:' + s.slice(0, 2) + ':' + s.slice(2, 4) + 'Z' })
  }
  return out
}

function render(list) {
  let hits = 0
  if (menu.threadNeighbors) {
    const index = menu.threadNeighbors(list)
    for (const m of list) {
      for (const which of ['previous', 'next']) {
        if (!canEdit(m)) continue
        const other = menu.neighborIn(index, m, which)
        if (other && canEdit(other) && menu.mergeableSourceIn(index, m, '')) hits++
      }
    }
    return hits
  }
  for (const m of list) {
    for (const which of ['previous', 'next']) {
      const other = menu.threadNeighbor(list, m, which)
      if (!other || !canEdit(m) || !canEdit(other)) continue
      if (menu.mergeableSource(list, m, '')) hits++
    }
  }
  return hits
}

for (const [n, tasks] of [[100, 1], [300, 1], [1000, 1], [300, 30]]) {
  const list = rows(n, tasks)
  bench(`merge-neighbors rows=${n} threads=${tasks}`, () => render(list))
}
