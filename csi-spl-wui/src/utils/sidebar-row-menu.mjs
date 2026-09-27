import { storageGetJson, storageSetJson } from './prefs.mjs'

/**
 * Items in the left-pane row menu. The icon rail (the tab switcher) is not a
 * row. A row with unread notes offers Mark as read; every row can open and
 * copy its link. A person or a bot also offers Block, Mute, Pin and Remove
 * from list (this browser's DM list only, for everyone). Remove (the tenant
 * membership) is only there when an admin (or the tenant owner) is signed in.
 *
 * @param {boolean} unread
 * A topic row (SPL-986, specs/041 §3.5) ends with the card menu's own
 * Archive then Delete, each only once the hub said the viewer may.
 *
 * @param {{ person?: boolean, admin?: boolean, blocked?: boolean, muted?: boolean, pinned?: boolean, channel?: boolean, properties?: boolean, deletable?: boolean, topicArchive?: boolean, topicDelete?: boolean }} [opts]
 */
/** @returns {{ id: string, icon: 'open' | 'copy' | 'check' | 'ban' | 'user-check' | 'bell' | 'bell-off' | 'pin' | 'x' | 'trash' | 'settings' | 'archive' | 'delete', labelKey: string }[]} */
export function rowMenuItems(unread, opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const items = [
    { id: 'open', icon: 'open', labelKey: 'sidebar.row_menu.open' },
    { id: 'copy', icon: 'copy', labelKey: 'sidebar.row_menu.copy_link' },
  ]
  if (unread) items.push({ id: 'read', icon: 'check', labelKey: 'sidebar.row_menu.mark_read' })
  if (o.channel) {
    items.push({
      id: 'mute',
      icon: o.muted ? 'bell' : 'bell-off',
      labelKey: o.muted ? 'sidebar.row_menu.unmute' : 'sidebar.row_menu.mute',
    })
    if (o.properties) items.push({ id: 'properties', icon: 'settings', labelKey: 'sidebar.row_menu.properties' })
    /* SPL-72: its creator only (canDeleteChannel); opens a confirm, never deletes at once */
    if (o.deletable) items.push({ id: 'delete', icon: 'trash', labelKey: 'sidebar.row_menu.delete_channel' })
  }
  if (o.person) {
    items.push({
      id: 'block',
      icon: o.blocked ? 'user-check' : 'ban',
      labelKey: o.blocked ? 'sidebar.row_menu.unblock' : 'sidebar.row_menu.block',
    })
    items.push({
      id: 'mute',
      icon: o.muted ? 'bell' : 'bell-off',
      labelKey: o.muted ? 'sidebar.row_menu.unmute' : 'sidebar.row_menu.mute',
    })
    items.push({
      id: 'pin',
      icon: 'pin',
      labelKey: o.pinned ? 'sidebar.row_menu.unpin' : 'sidebar.row_menu.pin',
    })
    items.push({ id: 'hide', icon: 'x', labelKey: 'sidebar.row_menu.hide' })
    if (o.admin) items.push({ id: 'remove', icon: 'trash', labelKey: 'sidebar.row_menu.remove' })
  }
  /* the same entries, icons and words as a card's menu (utils/msg-menu.mjs) */
  if (o.topicArchive) items.push({ id: 'archive', icon: 'archive', labelKey: 'feed.msg_menu.archive' })
  if (o.topicDelete) items.push({ id: 'delete-topic', icon: 'delete', labelKey: 'feed.msg_menu.delete' })
  return items
}

/**
 * Remove is DELETE /v1/members, gated by members.invite, which only the role
 * `admin` holds (owner 2026-09-25: "so only the admin will be able to add
 * users to the tenant"; the tenant owner biz_owner lost it). The permission
 * list decides; without one, only the role `admin`. A missing /view/me answer
 * stays closed: this item must not appear for everyone.
 */
export function rowMenuAdmin(me) {
  if (!me || typeof me !== 'object') return false
  if (Array.isArray(me.permissions)) return me.permissions.includes('members.invite')
  return me.role === 'admin'
}

/**
 * "Remove from list" on a DM row (owner 2026-09-25): hides the peer from THIS
 * browser's DM list. Nothing is sent to the hub; the peer stays a member and
 * can still write. The mark is the peer's last DM moment as the hub stamped it
 * when the row was hidden ('' = no DM yet), so a newer DM either way brings the
 * row back - compared hub clock to hub clock, never to this device's clock.
 */
export const HIDDEN_PEERS_KEY = 'spool.hidden-dm-peers'

/** @returns {Record<string, string>} label -> last DM moment at hide time */
export function loadHiddenPeers(store) {
  const raw = storageGetJson(HIDDEN_PEERS_KEY, {}, store)
  /** @type {Record<string, string>} */
  const out = {}
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out
  for (const [label, at] of Object.entries(raw)) {
    if (label && typeof at === 'string') out[label] = at
  }
  return out
}

/**
 * @param {Record<string, string>} map
 * @param {Storage | { getItem: Function, setItem: Function }} [store]
 * @returns {Record<string, string>}
 */
export function saveHiddenPeers(map, store) {
  const clean = { ...(map || {}) }
  storageSetJson(HIDDEN_PEERS_KEY, clean, store)
  return clean
}

/** @param {Record<string, string>} map @param {string} label @param {string} [lastDm] */
export function hidePeer(map, label, lastDm = '') {
  const key = String(label || '')
  if (!key) return { ...(map || {}) }
  return { ...(map || {}), [key]: String(lastDm || '') }
}

/** True while the row stays out of the list: hidden, and no newer DM since. */
export function peerHidden(map, label, lastDm = '') {
  const key = String(label || '')
  if (!map || !Object.prototype.hasOwnProperty.call(map, key)) return false
  const mark = String(map[key] || '')
  const now = String(lastDm || '')
  if (!now) return true
  if (!mark) return false
  const a = Date.parse(now)
  const b = Date.parse(mark)
  return Number.isNaN(a) || Number.isNaN(b) ? !(now > mark) : !(a > b)
}

/**
 * Pinned labels come first, in the order given (index 0 is the top).
 * Every other row keeps the order it arrived in.
 * @template T
 * @param {T[]} rows
 * @param {string[]} pins
 * @param {(row: T) => string} [keyOf]
 * @returns {T[]}
 */
export function pinRows(rows, pins, keyOf) {
  const order = Array.isArray(pins) ? pins.map((l) => String(l)) : []
  const rank = new Map()
  order.forEach((label, i) => { if (label && !rank.has(label)) rank.set(label, i) })
  const labelOf = typeof keyOf === 'function'
    ? keyOf
    : (row) => String((row && row.label) || '')
  const pinned = []
  const rest = []
  for (const row of rows || []) {
    if (rank.has(labelOf(row))) pinned.push(row)
    else rest.push(row)
  }
  pinned.sort((a, b) => rank.get(labelOf(a)) - rank.get(labelOf(b)))
  return pinned.concat(rest)
}

/**
 * Move keys[from] so it is inserted before the original index `to`.
 * `to === keys.length` appends. A no-op move returns a copy.
 * @param {string[]} keys
 * @param {number} from
 * @param {number} to
 * @returns {string[]}
 */
export function moveKey(keys, from, to) {
  const list = (Array.isArray(keys) ? keys : []).map((k) => String(k))
  if (!Number.isInteger(from) || from < 0 || from >= list.length) return list
  if (!Number.isInteger(to) || to < 0) return list
  const next = list.slice()
  const [item] = next.splice(from, 1)
  let dest = to > from ? to - 1 : to
  if (dest < 0) dest = 0
  if (dest > next.length) dest = next.length
  next.splice(dest, 0, item)
  return next
}

/**
 * Index to insert before, given row rectangles and a pointer Y.
 * Past the last midpoint, the index is rects.length (append).
 * @param {{ top: number, bottom: number }[]} rects
 * @param {number} y
 */
export function dropIndex(rects, y) {
  const list = Array.isArray(rects) ? rects : []
  for (let i = 0; i < list.length; i++) {
    const top = Number(list[i] && list[i].top) || 0
    const bottom = Number(list[i] && list[i].bottom) || 0
    if (y < (top + bottom) / 2) return i
  }
  return list.length
}
