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
// lobbyVerdict({ hub: { status, rows }, cards, error, empty })
//   -> { name, ok, ev }   (the step's name, its verdict and its evidence)
export function lobbyVerdict({ hub = { status: 0, rows: -1 }, cards = 0, error = false, empty = false } = {}) {
  const known = hub.status === 200 && Number.isInteger(hub.rows) && hub.rows >= 0
  if (known && hub.rows === 0) {
    return { name: 'empty on the hub, empty state shown', ok: cards === 0 && !error && empty, ev: { hub: 0, cards, error, empty } }
  }
  return { name: 'shows the lobby cards', ok: cards > 0, ev: { hub: known ? hub.rows : hub.status, cards } }
}

// hubLobbyCount(room, topics) -> { status, rows }
//   room   = { status, rows }  the room task's messages
//   topics = { status, rows }  the topics in channel lobby
// Either read failing makes the count unreadable (the first non-200 status).
export function hubLobbyCount(room = { status: 0, rows: -1 }, topics = { status: 0, rows: -1 }) {
  for (const r of [room, topics]) {
    if (r.status !== 200 || !Number.isInteger(r.rows) || r.rows < 0) return { status: r.status === 200 ? 0 : r.status, rows: -1 }
  }
  return { status: 200, rows: room.rows + topics.rows }
}
