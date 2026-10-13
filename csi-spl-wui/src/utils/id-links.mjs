/**
 * Ids written in a message become links at render time (HUM-10, topic
 * cd357c76). The front layer decides the kind from the rows the WUI already
 * holds — a channel topic, a direct-message topic, or a message — and never
 * asks the hub once per id. An id that matches nothing there stays text.
 *
 * A channel topic opens that channel with the card selected and the thread
 * in the right pane. A reply keeps that address and adds the message id, so
 * the reply stays in the right pane. A direct message opens its own list.
 * An archived row, or a direct message with no other end, opens /m/<id>,
 * which finds its place (HUM-10 t1 36ea84a6: no link opens the Topics view;
 * an archived one says where it went). A caller that passes labels gets the kind word in front of the link.
 *
 * A full uuid is a topic when that task is known, otherwise a message when
 * that msg_id is known. A bare 8-hex token stays text (SPL-1693, owner t1
 * ae38a1a6: an internal object is written type:id). Anything else (a longer
 * hex run, an unknown uuid) stays text.
 *
 * `msg:<uuid>` and `topic:<uuid>` (csi-spl-doc/doc/help/how-to-post.md) link
 * to that row on its workspace's host: the apex for the apex tenant, else
 * https://<tenant>.<site host> (tenant-host.mjs). A row's workspace is its
 * tenant_id, else the tenant of the page that loaded it. No workspace, no
 * link: the token stays text, no host is guessed.
 *
 * Code fences, inline code and an existing link are not rewritten. The
 * catalog is empty until a plugin registers one, so a direct parseBody call
 * in a unit test is unchanged.
 */
import { parentSection, parentSectionHref } from './parent-section.mjs'
import { registerIdLinks } from './id-link-gate.mjs'
import { tenantOrigin } from './tenant-host.mjs'

const UUID_SRC = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
const UUID_RE = new RegExp(`(?<![0-9a-fA-F-])${UUID_SRC}(?![0-9a-fA-F-])`, 'g')
/* msg:<uuid> / topic:<uuid>, the written form of an internal object */
const TYPED_RE = new RegExp(`(?<![0-9A-Za-z_:/-])(msg|topic):(${UUID_SRC})(?![0-9a-fA-F-])`, 'gi')
const UUID_TEST = new RegExp(`^${UUID_SRC}$`, 'i')
const HAS_HEX = /[0-9a-fA-F]{8}/
const MD_LANG = /^(?:md|markdown)$/i

/* closed fences, inline code, markdown links, and bare urls. An id inside
   any of these is already code or already a link. */
const PROTECT_RE = /```[\s\S]*?```|`{1,2}[^`\n]+`{1,2}|\[[^\]\n]+\]\([^)\n]+\)|https?:\/\/[^\s<>)\]]+|www\.[^\s<>)\]]+/gi

const EMPTY = Object.freeze({
  empty: true,
  topicsById: new Map(),
  topicsByPrefix: new Map(),
  messagesById: new Map(),
  messagesByPrefix: new Map(),
})

let provider = () => EMPTY

/** The render path reads this. Tests and the plugin set it; null clears it. */
export function setIdCatalogProvider(fn) {
  provider = typeof fn === 'function' ? fn : () => EMPTY
}

export function resetIdCatalogProvider() {
  provider = () => EMPTY
}

/** The catalog for this render, or the empty one when nothing is registered. */
export function activeIdIndex() {
  try {
    const idx = provider()
    if (idx && idx.topicsById instanceof Map && idx.messagesById instanceof Map) return idx
  } catch { /* a render must still show the text */ }
  return EMPTY
}

function norm(v) {
  return String(v || '').trim().toLowerCase()
}

function pathOf(pathFor, path) {
  const out = typeof pathFor === 'function' ? pathFor(path) : path
  return String(out || path)
}

function channelOf(row) {
  return String((row && row.channel) || '').trim().replace(/^#/, '')
}

/** The origin of a row's workspace host, '' when the row has none. */
function originOf(row, host) {
  const t = String((row && row.tenant_id) || host.tenant || '').trim().toLowerCase()
  return t && host.siteUrl ? tenantOrigin(t, host.siteUrl, host.apexTenant) : ''
}

function archivedOf(row) {
  return Boolean(row && (row.archived_at || row.archived === true))
}

/** The other end of a DM, as the sidebar labels a peer. */
function peerOf(row, self) {
  const m = row || {}
  const me = String(self || '')
  const meId = me.split('@')[0]
  for (const [id, box] of [[m.from, m.from_box], [m.to, m.to_box]]) {
    const i = String(id || '')
    if (!i || i.startsWith('@') || /^ALL-0$/i.test(i)) continue
    if (i === me || i === meId) continue
    return box ? `${i}@${box}` : i
  }
  const list = Array.isArray(m.participants) ? m.participants : []
  for (const p of list) {
    const s = String(p || '')
    const id = s.split('@')[0]
    if (!s || s.startsWith('@') || id === me || id === meId || s === me) continue
    return s
  }
  if (m.kind === 'dm' && m.where) return String(m.where)
  return ''
}

function topicHref(info, pathFor) {
  /* An archived topic has left the channel list: /m/<task> says so. */
  if (info.archived) return pathOf(pathFor, '/m/' + encodeURIComponent(info.taskId))
  if (!info.channel && info.peer) {
    return pathOf(pathFor, '/dm/' + encodeURIComponent(info.peer)) + '?topic=' + encodeURIComponent(info.taskId)
  }
  if (info.channel) {
    return pathOf(pathFor, '/channel/' + encodeURIComponent(info.channel)) + '?topic=' + encodeURIComponent(info.taskId)
  }
  return pathOf(pathFor, '/m/' + encodeURIComponent(info.taskId))
}

function placeLess(row, pathFor) {
  const id = norm(row.msg_id)
  return UUID_TEST.test(id) ? pathOf(pathFor, '/m/' + encodeURIComponent(id)) : ''
}

function messageHref(row, self, pathFor) {
  /* An archived reply is not in the channel list: /m/<id> says so. */
  if (row.archived) return placeLess(row, pathFor)
  const section = parentSection(row, { self })
  if (section && section.path && section.kind !== 'issue') return parentSectionHref(section, pathFor)
  return placeLess(row, pathFor)
}

function pushPrefix(map, prefix, rec) {
  const list = map.get(prefix)
  if (list) list.push(rec)
  else map.set(prefix, [rec])
}

/**
 * Index the topics and messages the reader can already see.
 * `pathFor` is the locale-aware path (identity when omitted).
 * `labels` is the translated kind words. Omit it and the link text is the id alone.
 * `tenant` is the page's workspace, `siteUrl` / `apexTenant` the env's apex and
 * its tenant: a typed token links on the row's workspace host only with them.
 * @param {{ topics?: unknown[], messages?: unknown[], self?: string, pathFor?: (path: string) => string, labels?: Record<string, string>, tenant?: string, siteUrl?: string, apexTenant?: string }} [input]
 */
export function indexCatalog(input = {}) {
  const src = input && typeof input === 'object' ? input : {}
  const self = String(src.self || '')
  const pathFor = src.pathFor
  const host = { tenant: String(src.tenant || ''), siteUrl: String(src.siteUrl || ''), apexTenant: String(src.apexTenant || '') }
  const topicRows = new Map()
  const messageRows = new Map()

  function addTopic(id, row) {
    const key = norm(id)
    if (!UUID_TEST.test(key)) return
    const prev = topicRows.get(key) || { taskId: key, channel: '', peer: '', archived: false, origin: '' }
    const channel = prev.channel || channelOf(row)
    topicRows.set(key, {
      taskId: key,
      origin: prev.origin || originOf(row, host),
      channel,
      peer: channel ? '' : (prev.peer || peerOf(row, self)),
      archived: Boolean(prev.archived || archivedOf(row)),
    })
  }

  function addMessage(row) {
    const key = norm(row && row.msg_id)
    if (!UUID_TEST.test(key)) return
    const prev = messageRows.get(key) || {}
    messageRows.set(key, {
      msg_id: key,
      task_id: prev.task_id || row.task_id || '',
      parent_task_id: prev.parent_task_id || row.parent_task_id || null,
      channel: prev.channel || row.channel || null,
      from: prev.from || row.from || '',
      from_box: prev.from_box || row.from_box || '',
      to: prev.to || row.to || '',
      to_box: prev.to_box || row.to_box || '',
      archived: Boolean(prev.archived || archivedOf(row)),
      origin: prev.origin || originOf(row, host),
    })
    addTopic(row.parent_task_id || row.task_id, row)
  }

  for (const t of src.topics || []) addTopic(t && t.task_id, t)
  for (const m of src.messages || []) {
    if (m && m.msg_id) addMessage(m)
    else addTopic(m && m.task_id, m)
  }

  if (topicRows.size === 0 && messageRows.size === 0) return EMPTY

  const topicsById = new Map()
  const topicsByPrefix = new Map()
  const messagesById = new Map()
  const messagesByPrefix = new Map()
  const labels = src.labels && typeof src.labels === 'object' ? src.labels : null
  for (const info of topicRows.values()) {
    const rec = {
      href: topicHref(info, pathFor),
      label: info.peer && !info.channel ? 'direct-message' : 'topic',
      archived: Boolean(info.archived),
      origin: info.origin,
    }
    topicsById.set(info.taskId, rec)
    pushPrefix(topicsByPrefix, info.taskId.slice(0, 8), rec)
  }
  for (const [id, row] of messageRows) {
    const parent = topicRows.get(norm(row.parent_task_id || row.task_id))
    const archived = Boolean(row.archived || (parent && parent.archived))
    const href = messageHref({ ...row, archived }, self, pathFor)
    if (!href) continue
    const rec = {
      href,
      label: row.channel ? 'channel-message' : 'direct-message',
      archived,
      origin: row.origin,
    }
    messagesById.set(id, rec)
    pushPrefix(messagesByPrefix, id.slice(0, 8), rec)
  }
  return { empty: false, topicsById, topicsByPrefix, messagesById, messagesByPrefix, labels }
}

/**
 * What one token is, or null.
 * A full uuid prefers the topic. A bare 8-hex token is never resolved: the
 * prefix maps only keep a known one from becoming a commit link.
 */
export function resolveId(token, index) {
  if (!index || index.empty) return null
  const raw = String(token || '')
  const key = raw.toLowerCase()
  if (UUID_TEST.test(key)) {
    const topic = index.topicsById.get(key)
    if (topic) return { kind: 'topic', href: topic.href, label: topic.label, archived: topic.archived }
    const msg = index.messagesById.get(key)
    if (msg) return { kind: 'message', href: msg.href, label: msg.label, archived: msg.archived }
    return null
  }
  return null
}

/** msg:<uuid> / topic:<uuid>: the row's page on its workspace host, or null. */
export function resolveTyped(type, id, index) {
  if (!index || index.empty) return null
  const key = norm(id)
  const rec = String(type).toLowerCase() === 'topic' ? index.topicsById.get(key) : index.messagesById.get(key)
  if (!rec || !rec.origin) return null
  return { href: rec.origin + rec.href }
}

function findHits(text, index) {
  const hits = []
  TYPED_RE.lastIndex = 0
  for (const m of text.matchAll(TYPED_RE)) {
    const hit = resolveTyped(m[1], m[2], index)
    /* the type word is part of the link, and never gets a kind word */
    if (hit) hits.push({ start: m.index, end: m.index + m[0].length, href: hit.href, typed: true })
  }
  UUID_RE.lastIndex = 0
  for (const m of text.matchAll(UUID_RE)) {
    const start = m.index
    const end = start + m[0].length
    /* a typed token is linked whole, or stays text whole */
    if (text.slice(Math.max(0, start - 6), start).match(/(?:msg|topic):$/i)) continue
    const hit = resolveId(m[0], index)
    if (!hit) continue
    hits.push({ start, end, href: hit.href, label: hit.label, archived: hit.archived })
  }
  hits.sort((a, b) => a.start - b.start)
  return hits
}

function kindPrefix(hit, index) {
  const labels = index && index.labels
  if (hit.typed || !labels || typeof labels !== 'object') return ''
  const name = String(labels[hit.label] || '')
  if (!name) return ''
  const arch = hit.archived && labels.archived ? ' (' + String(labels.archived) + ')' : ''
  return name + arch + ': '
}

function pushText(parts, text) {
  if (!text) return
  const prev = parts[parts.length - 1]
  if (prev && prev.type === 'text') prev.text += text
  else parts.push({ type: 'text', text })
}

/** Text parts and link parts. An unknown id stays one text part. */
export function linkifyText(text, index) {
  const s = String(text ?? '')
  if (!index || index.empty || !HAS_HEX.test(s)) return [{ type: 'text', text: s }]
  const hits = findHits(s, index)
  if (!hits.length) return [{ type: 'text', text: s }]
  const parts = []
  let last = 0
  for (const h of hits) {
    pushText(parts, s.slice(last, h.start) + kindPrefix(h, index))
    parts.push({ type: 'link', text: s.slice(h.start, h.end), href: h.href })
    last = h.end
  }
  pushText(parts, s.slice(last))
  return parts
}

function protectRanges(s) {
  const ranges = []
  PROTECT_RE.lastIndex = 0
  for (const m of s.matchAll(PROTECT_RE)) ranges.push([m.index, m.index + m[0].length])
  const openAt = s.lastIndexOf('```')
  if (openAt >= 0 && !ranges.some(([a, b]) => openAt >= a && openAt < b)) ranges.push([openAt, s.length])
  return ranges
}

function covered(hit, ranges) {
  return ranges.some(([a, b]) => hit.start >= a && hit.end <= b)
}

/**
 * The same text, with a known id written as a markdown link. Code, an
 * existing link and a bare url are left as written.
 */
export function linkifyMarkdown(src, index) {
  const s = String(src ?? '')
  if (!index || index.empty || !HAS_HEX.test(s)) return s
  const ranges = protectRanges(s)
  const hits = findHits(s, index).filter((h) => !covered(h, ranges))
  if (!hits.length) return s
  let out = ''
  let last = 0
  for (const h of hits) {
    out += s.slice(last, h.start)
    out += kindPrefix(h, index)
    out += '[' + s.slice(h.start, h.end) + '](' + h.href + ')'
    last = h.end
  }
  return out + s.slice(last)
}

function linkifyParts(parts, index) {
  const out = []
  for (const p of parts || []) {
    if (!p || p.type === 'link' || p.type === 'inline' || p.type === 'mention') {
      out.push(p)
      continue
    }
    if ((p.type === 'text' || p.type === 'strong' || p.type === 'em') && typeof p.text === 'string') {
      const bits = linkifyText(p.text, index)
      if (bits.length === 1 && bits[0].type === 'text') out.push(p)
      else for (const b of bits) out.push(b.type === 'link' ? b : { ...p, text: b.text })
      continue
    }
    out.push(p)
  }
  return out
}

/** A parseBody tree, with ids in text linked and code left alone. */
export function linkifyBlocks(blocks, index) {
  if (!index || index.empty || !Array.isArray(blocks)) return blocks
  return blocks.map((b) => {
    if (!b || b.type === 'code') {
      if (b && b.type === 'code' && MD_LANG.test(String(b.lang || ''))) {
        const text = linkifyMarkdown(b.text, index)
        return text === b.text ? b : { ...b, text }
      }
      return b
    }
    if (Array.isArray(b.parts)) return { ...b, parts: linkifyParts(b.parts, index) }
    if (Array.isArray(b.items)) {
      return { ...b, items: b.items.map((it) => ({ ...it, parts: linkifyParts(it.parts, index) })) }
    }
    return b
  })
}

registerIdLinks({ activeIdIndex, linkifyBlocks, linkifyMarkdown })
