/**
 * SPL-985 (spec 042 §3): the mention poke. When a text is stored, the author's
 * browser sends each person or agent it mentions a direct message asking them
 * to act. Node tests import this file; composables/useMentionPoke.ts wraps it.
 */

import { BOX_ID_SRC, PARTICIPANT_ID_SRC } from './agent-id.mjs'
import { mentionedIds } from './notify.mjs'

export const EXCERPT_MAX = 200

/**
 * The ids to poke, in first-mention order (spec 042 K3): each id once, never
 * the author, never the agent the send already addresses, and on an edit
 * never an id the text mentioned before.
 *
 * @param {{ text: string, before?: string, selfId?: string, addressee?: string }} a
 */
export function pokeTargets({ text, before = '', selfId = '', addressee = '' }) {
  const had = new Set(mentionedIds(before))
  const skip = new Set([String(selfId || '').split('@')[0], String(addressee || '').split('@')[0]])
  const out = []
  for (const id of mentionedIds(text)) {
    if (had.has(id) || skip.has(id) || out.includes(id)) continue
    out.push(id)
  }
  return out
}

/**
 * specs/058 (CLE-77932): the box each mentioned id was written with, from the
 * `@<ID>@<box>` tags of the text (the @ picker always writes one). The poke
 * DM carries it as to_box, so `@CLE-001@sat` tells the satellite's CLE-001
 * and not the home box's. The first tag of an id wins; a bare id has none.
 *
 * @param {string} text
 * @returns {Record<string, string>} id -> box
 */
const MENTION_BOX_RE = new RegExp(`(?<![\\w@])@(${PARTICIPANT_ID_SRC})@(${BOX_ID_SRC})\\b`, 'g')

export function mentionBoxes(text) {
  const out = {}
  for (const m of String(text || '').matchAll(MENTION_BOX_RE)) {
    if (!(m[1] in out)) out[m[1]] = m[2]
  }
  return out
}

/** One line, at most EXCERPT_MAX characters; a cut ends in an ellipsis. */
export function pokeExcerpt(text) {
  const line = String(text || '').replace(/\s+/g, ' ').trim()
  if (line.length <= EXCERPT_MAX) return line
  return `${line.slice(0, EXCERPT_MAX - 1).trimEnd()}…`
}

/**
 * The DM body (K1). English on purpose: an agent parses it. The author is
 * named by bare id so the DM does not read as a mention of the author.
 */
export function pokeBody({ author, link, text }) {
  return `${String(author || '').split('@')[0]} needs you in ${link}: "${pokeExcerpt(text)}"`
}

/** Absolute link to a card or reply: the topic page of its task. */
export function cardLink(origin, taskId) {
  return `${String(origin || '').replace(/\/+$/, '')}/t/${encodeURIComponent(String(taskId || ''))}`
}

/** Absolute link to one issue on the issues sheet. */
export function issueLink(origin, key) {
  return `${String(origin || '').replace(/\/+$/, '')}/issues?issue=${encodeURIComponent(String(key || ''))}`
}

function isHuman(id) {
  return /^(HUM|GST)-\d+$/.test(String(id || ''))
}

/**
 * K4: nobody gets an excerpt of what they cannot read.
 * `access` is one of
 *   { kind: 'open' }                                        - a default channel, an issue
 *   { kind: 'dm', ends: string[] }                          - only its two ends read it
 *   { kind: 'channel', humans: string[], agents: string[], responders?: string[] }
 *                                                           - a members-only channel
 *   null                                                    - unknown: refuse everyone
 * Ends, agents and responders may carry `@box`; the comparison is on the id.
 * A tenant responder (CLE-77804) hears every channel it can fall back to, so it
 * is told even when it is not a member of the channel.
 *
 * @returns {{ ok: string[], refused: string[] }}
 */
export function splitByAccess(ids, access) {
  const bare = (x) => String(x || '').split('@')[0]
  const ok = []
  const refused = []
  for (const id of Array.isArray(ids) ? ids : []) {
    let may = false
    if (access && access.kind === 'open') may = true
    else if (access && access.kind === 'dm') may = (access.ends || []).map(bare).includes(id)
    else if (access && access.kind === 'channel') {
      may = isHuman(id)
        ? (access.humans || []).map(bare).includes(id)
        : (access.agents || []).map(bare).includes(id) || (access.responders || []).map(bare).includes(id)
    }
    ;(may ? ok : refused).push(id)
  }
  return { ok, refused }
}

/**
 * CLE-77852 (owner bug t1 e6c13767): an agent SEATED in this workspace (a box
 * agent of the tenant, `seated` = the roster's ids) that is not a member of a
 * members-only channel is still told, by the same DM poke, instead of being
 * refused. Channels stay dispatcher-only: the orchestrator is in none of them
 * and must still answer an @-mention. People and unseated agents keep K4's
 * refusal, and a DM or an unknown place never pokes an outsider.
 *
 * @returns {{ ok: string[], direct: string[], refused: string[] }}
 */
export function splitPokes(ids, access, seated) {
  const { ok, refused } = splitByAccess(ids, access)
  if (!access || access.kind !== 'channel') return { ok, direct: [], refused }
  const seat = new Set((Array.isArray(seated) ? seated : []).map((x) => String(x || '').split('@')[0]))
  const direct = refused.filter((id) => !isHuman(id) && seat.has(id))
  return { ok, direct, refused: refused.filter((id) => !direct.includes(id)) }
}

/**
 * The access of a channel from its member list (GET /v1/channels/{id}/members,
 * spool-client parseMemberList). A default channel is everyone in the tenant.
 */
export function channelAccess(list) {
  if (!list) return null
  if (list.default) return { kind: 'open' }
  return {
    kind: 'channel',
    humans: Array.isArray(list.members) ? list.members.map(String) : [],
    agents: Array.isArray(list.agents) ? list.agents.map((a) => String((a && a.id) || a || '')) : [],
    responders: Array.isArray(list.responders) ? list.responders.map(String) : [],
  }
}

/**
 * Where a topic lives, from the rows the page holds (K4), for a send that
 * names only a task (the lobby and topic panes). One channel -> that channel;
 * a DM row -> its two ends; a lobby row (no channel, to @channel) -> the
 * lobby; rows in two places, or none -> null (tell nobody).
 *
 * @returns {{ channel: string } | { ends: string[] } | null}
 */
export function topicWhere(rows, taskId) {
  const mine = (Array.isArray(rows) ? rows : []).filter((m) => m && m.task_id === taskId)
  if (!mine.length) return null
  const dm = mine.find((m) => !m.channel && m.to && m.to !== '@channel')
  if (dm) return { ends: [String(dm.from || ''), String(dm.to || '')] }
  /* a channel-less broadcast row is a lobby row (older rows carry no channel) */
  const channels = new Set(mine.map((m) => String(m.channel || '') || 'lobby'))
  if (channels.size !== 1) return null
  const only = [...channels][0]
  return { channel: only === 'lobby' ? '' : only }
}
