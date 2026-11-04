// csi-spl-wui/src/utils/topic-moved.mjs
//
// Spec 169 row T7h (SPL-4781): an old /t/<uuid> link of a topic whose channel
// moved to another workspace. For 30 days (Q2) the hub answers its read with
// 404 `topic_moved` and the topic's new link in `moved_to`
// (channel_move.go topicMovedAnswer, `https://<DST_HOST>/t/<uuid>`); then
// with no link. The /t/ page follows that link. The link names a workspace
// and a topic, never the channel (case C8), and nothing here adds one.
//
// R7 N1: another origin is followed only when it is a workspace host of this
// env (the apex or <tenant>.<apex>, tenant-host-core isTenantHostOf), never
// any https host. R7 N4: one hop per navigation - the followed link carries
// MOVED_HOP as its hash, and a page opened with it does not follow again.

import { isTenantHostOf } from './tenant-host-core.mjs'

/** The hash a followed link carries: the page it opens follows no further. */
export const MOVED_HOP = '#moved'

const TOPIC_PATH_RE = /^\/t\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Where the reader goes for the hub's `moved_to`, or null: only a topic link
 * (`/t/<uuid>`, no query, no hash), on this page's own origin or on a
 * workspace host of this env (siteUrl), so a stray value can never send the
 * reader anywhere else. href carries MOVED_HOP.
 * @param {unknown} movedTo the hub's `moved_to`
 * @param {string} origin this page's `location.origin`
 * @param {string} siteUrl this env's apex (runtime config `siteUrl`)
 * @returns {{ href: string, path: string, sameOrigin: boolean } | null}
 */
export function movedTopicTarget(movedTo, origin, siteUrl) {
  if (typeof movedTo !== 'string' || !movedTo) return null
  let u
  try {
    u = new URL(movedTo, origin)
  } catch {
    return null
  }
  const sameOrigin = u.origin === origin
  if (!sameOrigin && !isTenantHostOf(u.href, siteUrl)) return null
  if (u.username || u.password || u.search || u.hash || !TOPIC_PATH_RE.test(u.pathname)) return null
  return { href: u.href + MOVED_HOP, path: u.pathname, sameOrigin }
}
