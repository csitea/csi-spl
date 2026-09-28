// /lobby's two first reads, started when the session says 'in'
// instead of when the page mounts.
//
// Between the session answer and the page's first read the frame renders,
// and its chunks load in waves: ~150 ms on the box link, ~950 ms on slow 4G
// and ~1.2 s on a phone on slow 4G (prd e2e, n=5). The reads do not need the
// page, only the session and the lobby id (cnf, baked into the build). So a
// plugin starts them at session 'in' (startLobbyWarm) and the page takes them
// (takeLobbyWarm) instead of asking again.
//
// No message may be lost in between: from the moment the reads start until
// the page takes them, every live frame is buffered, and the page admits the
// buffer once its own reads are in (the store merges by msg_id, so a frame
// that the read also carries is not doubled). Taking stops the buffer; the
// page's store has subscribed by then (open() subscribes before it awaits).
// A warm read is taken ONCE, only for the same lobby id, and only while
// fresh; otherwise the page reads as before.

let warm = null

/** Is this the lobby route, in the default locale or a prefixed one? */
export function isLobbyPath(path) {
  return /^\/(?:[a-z]{2}\/)?lobby\/?$/.test(String(path || ''))
}

/**
 * Start the reads once per page load. `room` and `topics` are thunks that
 * return promises; `onMessage` registers a live-frame handler and returns
 * its off().
 */
export function startLobbyWarm({ id, room, topics, onMessage, now = Date.now, maxFrames = 500 }) {
  if (warm || !id) return warm
  const frames = []
  const off = onMessage((m) => { if (frames.length < maxFrames) frames.push(m) })
  const r = room()
  const t = topics()
  // the page handles a failure: it reads again (room) or shows the error
  r.catch(() => {})
  t.catch(() => {})
  warm = { id: String(id), at: now(), room: r, topics: t, frames, off }
  return warm
}

/** The warm reads for `id`, once; null when there are none or they are stale. */
export function takeLobbyWarm(id, { now = Date.now, maxAgeMs = 15000 } = {}) {
  const w = warm
  warm = null
  if (!w) return null
  w.off()
  if (w.id !== String(id) || now() - w.at > maxAgeMs) return null
  return w
}

/** The buffered frames the lobby shows: its room task and its channel. */
export function lobbyFrames(w, id) {
  if (!w) return []
  return w.frames.filter((m) => m && (m.task_id === id || m.channel === 'lobby'))
}

/** Test seam. */
export function resetLobbyWarm() {
  if (warm) warm.off()
  warm = null
}
