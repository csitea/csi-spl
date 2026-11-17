// SPL-5736: the live proof's /lobby verdict, checked against the hub's count.
// #lobby rows age out with the hub's channel retention (720h), and the proof
// never posts there (owner answer 5cb37834, SPL-1632: test posts go to the
// hidden #probe), so a lobby nobody posted in for 30 days is legitimately
// empty. The page is judged against what the hub serves the same member:
//   hub >= 1 live row  -> the page must show >= 1 card (a WUI that hides
//                          existing cards fails)
//   hub 0 rows         -> the page must show the empty state: no card, no
//                          error notice, the empty line rendered
//   hub unreadable     -> as before SPL-5736: the page must show >= 1 card
//
// The hub's count is the two reads /lobby itself makes (src/pages/lobby.vue
// openLobby): the room task (GET /v1/view/topics/<LOBBY_TASK>) and the topics
// posted into channel lobby (GET /v1/view/topics?channel=lobby). Counting the
// room task alone read hub:0 on prd while a channel topic showed a card
// (wf30 run 44006585029, cards:1).
//
// SPL-5777 (c-841 review N2: prd hub 2, cards 1 passed): with the hub's card
// count known, the page must show every one of them, not just one. Rows are
// not cards: /lobby makes one card per task_id among the rows with no
// parent_task_id and is_parent != 0 (src/utils/channel-feed-core.mjs
// topicStarterCards), so the room task's many messages are ONE card and a
// reply row is none. Those are the only rows allowed to have no card of their
// own. So a channel topic whose every row is is_parent 0 (replies sent from
// the topics pane, with no starter: prd t1 cd9b0f47, 2026-11-17) has no card,
// by the WUI's rule; the proof reads each listed topic's rows to see that,
// since a channel topic row carries no is_parent. The page shows at most LOBBY_WINDOW cards (channelView's visible),
// so a longer lobby needs that many. More cards than the hub is no failure: a
// live frame can land between the page's read and the hub's.
export const LOBBY_WINDOW = 50

// lobbyVerdict({ hub: { status, rows, cards? }, cards, error, empty })
//   -> { name, ok, ev }   (the step's name, its verdict and its evidence)
export function lobbyVerdict({ hub = { status: 0, rows: -1 }, cards = 0, error = false, empty = false } = {}) {
  const known = hub.status === 200 && Number.isInteger(hub.rows) && hub.rows >= 0
  if (known && hub.rows === 0) {
    return { name: 'empty on the hub, empty state shown', ok: cards === 0 && !error && empty, ev: { hub: 0, cards, error, empty } }
  }
  const want = known && Number.isInteger(hub.cards) && hub.cards >= 0 ? Math.min(hub.cards, LOBBY_WINDOW) : 1
  const ev = known && Number.isInteger(hub.cards) ? { hub: hub.rows, want, cards } : { hub: known ? hub.rows : hub.status, cards }
  return { name: 'shows the lobby cards', ok: cards > 0 && cards >= want, ev }
}

// cardTasks(rows) -> the task_id of each raw hub row that is a card starter
// (no parent_task_id, is_parent != 0); the room's rows share one task_id.
export function cardTasks(rows = []) {
  return (rows || []).filter((m) => m && m.task_id && !m.parent_task_id && m.is_parent !== 0).map((m) => String(m.task_id))
}

// hubLobbyCount(room, topics) -> { status, rows, cards }
//   room   = { status, rows, tasks? }  the room task's messages
//   topics = { status, rows, tasks? }  the topics in channel lobby
//   tasks  = cardTasks(<that read's rows>); cards = the distinct task ids of
//            both reads (a channel topic that is the room task is one card),
//            -1 when either read carries no tasks.
// Either read failing makes the count unreadable (the first non-200 status).
export function hubLobbyCount(room = { status: 0, rows: -1 }, topics = { status: 0, rows: -1 }) {
  for (const r of [room, topics]) {
    if (r.status !== 200 || !Number.isInteger(r.rows) || r.rows < 0) return { status: r.status === 200 ? 0 : r.status, rows: -1, cards: -1 }
  }
  const both = Array.isArray(room.tasks) && Array.isArray(topics.tasks)
  return { status: 200, rows: room.rows + topics.rows, cards: both ? new Set([...room.tasks, ...topics.tasks]).size : -1 }
}
