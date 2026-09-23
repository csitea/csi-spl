/**
 * Items in the left-pane row menu. The icon rail (the tab switcher) is not a
 * row. A row with unread notes offers Mark as read; every row can open and
 * copy its link. A person or a bot also offers Block and Mute. Remove is
 * only there when an admin (or the tenant owner) is signed in.
 *
 * @param {boolean} unread
 * @param {{ person?: boolean, admin?: boolean, blocked?: boolean, muted?: boolean, pinned?: boolean }} [opts]
 */
/** @returns {{ id: string, icon: 'open' | 'copy' | 'check' | 'ban' | 'user-check' | 'bell' | 'bell-off' | 'pin' | 'trash', labelKey: string }[]} */
export function rowMenuItems(unread, opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const items = [
    { id: 'open', icon: 'open', labelKey: 'sidebar.row_menu.open' },
    { id: 'copy', icon: 'copy', labelKey: 'sidebar.row_menu.copy_link' },
  ]
  if (unread) items.push({ id: 'read', icon: 'check', labelKey: 'sidebar.row_menu.mark_read' })
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
    if (o.admin) items.push({ id: 'remove', icon: 'trash', labelKey: 'sidebar.row_menu.remove' })
  }
  return items
}

/**
 * Remove is an admin action. The role `admin` and the tenant owner
 * (biz_owner, `tenant_owner`) both hold members.invite. A missing /view/me
 * answer stays closed: this item must not appear for everyone.
 */
export function rowMenuAdmin(me) {
  if (!me || typeof me !== 'object') return false
  return me.role === 'admin' || me.tenantOwner === true
}

/**
 * Pinned labels come first, in the order given (index 0 is the top).
 * Every other row keeps the order it arrived in.
 * @template T
 * @param {T[]} rows
 * @param {string[]} pins
 * @returns {T[]}
 */
export function pinRows(rows, pins) {
  const order = Array.isArray(pins) ? pins.map((l) => String(l)) : []
  const rank = new Map()
  order.forEach((label, i) => { if (label && !rank.has(label)) rank.set(label, i) })
  const labelOf = (row) => String((row && row.label) || '')
  const pinned = []
  const rest = []
  for (const row of rows || []) {
    if (rank.has(labelOf(row))) pinned.push(row)
    else rest.push(row)
  }
  pinned.sort((a, b) => rank.get(labelOf(a)) - rank.get(labelOf(b)))
  return pinned.concat(rest)
}
