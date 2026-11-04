// csi-spl-wui/src/utils/topic-moved.mjs
//
// Spec 169 row T7h (SPL-4781): an old /t/<uuid> link of a topic whose channel
// moved to another workspace. For 30 days (Q2) the hub answers its read with
// 404 `topic_moved` and the topic's new link in `moved_to`
// (channel_move.go topicMovedAnswer, `https://<DST_HOST>/t/<uuid>`); then
// with no link. The /t/ page follows that link. The link names a workspace
// and a topic, never the channel (case C8), and nothing here adds one.

const TOPIC_PATH_RE = /^\/t\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Where the reader goes for the hub's `moved_to`, or null: only a topic link
 * (`/t/<uuid>`, no query, no hash), over https or on this page's own origin,
 * so a stray value can never send the reader anywhere else.
 * @param {unknown} movedTo the hub's `moved_to`
 * @param {string} origin this page's `location.origin`
 * @returns {{ href: string, path: string, sameOrigin: boolean } | null}
 */
export function movedTopicTarget(movedTo, origin) {
  if (typeof movedTo !== 'string' || !movedTo) return null
  let u
  try {
    u = new URL(movedTo, origin)
  } catch {
    return null
  }
  const sameOrigin = u.origin === origin
  if (u.protocol !== 'https:' && !sameOrigin) return null
  if (u.username || u.password || u.search || u.hash || !TOPIC_PATH_RE.test(u.pathname)) return null
  return { href: u.href, path: u.pathname, sameOrigin }
}
