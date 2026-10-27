// SPL-3717: its own module, imported only by the async ChannelPropertiesDialog,
// so it stays out of the initial chunk (channel-members.ts is in it).
import type { AgentRow } from '~/utils/channel-members'

/**
 * SPL-3717 (lessons-learnt row 8): the agent rows with their box's presence
 * from the roster store, the source every other dot in the WUI reads: the
 * socket's presence frames keep it live while the dialog is open, where the
 * members answer is a snapshot of the moment it opened. A box is online when
 * any agent label of it is online or idle (idle = machine online, agent not
 * running: the box is still connected). 'unseated', a box the roster does not
 * list, and no roster at all keep the hub's answer.
 */
export function channelAgentsLive(rows: readonly AgentRow[], live: { roster?: Record<string, readonly string[]>, online?: readonly string[], idle?: readonly string[] } | null | undefined): AgentRow[] {
  const known = (live && live.roster) || {}
  const up = new Set<string>()
  for (const label of [...((live && live.online) || []), ...((live && live.idle) || [])]) {
    const at = String(label).lastIndexOf('@')
    if (at > 0) up.add(String(label).slice(at + 1))
  }
  return rows.map((row) => {
    if (row.state === 'unseated' || !Object.prototype.hasOwnProperty.call(known, row.box)) return row
    const state = up.has(row.box) ? 'online' : 'offline'
    return row.state === state ? row : { ...row, state }
  })
}
