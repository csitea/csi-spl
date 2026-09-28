// The channel page's per-render reply counts (CLE-35075): LiveFeed asks
// channel.repliesFor(task) once per card. A tree without topicReplyIndex()
// runs the old per-card topicReplies walk.
import { bench, src } from './lib/bench.mjs'

const feed = await src('utils/channel-feed.mjs')

function held(n, topics) {
  return Array.from({ length: n }, (_, i) => ({
    msg_id: 'm' + i,
    task_id: 't' + (i % topics),
    parent_task_id: i % 11 === 0 ? 't' + ((i + 1) % topics) : null,
    topic_row: i < topics,
    count: 3,
    ts: '2026-09-28T10:00:00Z',
  }))
}

function render(rows, cards) {
  let sum = 0
  if (feed.topicReplyIndex) {
    const index = feed.topicReplyIndex(rows)
    for (const t of cards) sum += feed.topicRepliesIn(index, t, { count: 5, last_ts: '2026-09-28T09:00:00Z' })
    return sum
  }
  for (const t of cards) sum += feed.topicReplies(rows, t, { count: 5, last_ts: '2026-09-28T09:00:00Z' })
  return sum
}

for (const [n, topics] of [[300, 30], [1000, 30], [1000, 100]]) {
  const rows = held(n, topics)
  const cards = Array.from({ length: topics }, (_, i) => 't' + i)
  bench(`reply-counts held=${n} cards=${topics}`, () => render(rows, cards))
}
