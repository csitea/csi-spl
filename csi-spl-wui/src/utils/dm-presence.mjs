/**
 * CLE-77862 (HUM-24): what a DM header says about the PEER. The words sit
 * next to the peer's name, not only in the dot's tooltip, so nobody reads the
 * dot as their own status. The hub's presence semantics are unchanged: online
 * is the roster's live set, "last seen" is what view-v1 §4.1 already carries
 * (humans[].last_seen, boxes[].last_hello_at).
 */
import { isoDateTime } from "./date-iso.mjs"

/**
 * @param {{ online: boolean, lastSeen?: string }} p
 * @returns {{ status: 'on' | 'off', key: string, params: Record<string, string> }}
 *   status for the dot, key + params for the i18n text beside the name
 */
export function dmPresence({ online, lastSeen }) {
  if (online) return { status: "on", key: "pages.dm.online", params: {} }
  const when = isoDateTime(lastSeen || "")
  if (when) return { status: "off", key: "pages.dm.last_seen", params: { when } }
  return { status: "off", key: "pages.dm.offline_queued", params: {} }
}
