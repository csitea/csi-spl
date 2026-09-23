/**
 * Items in the left-pane row menu. The icon rail (the tab switcher) is not a
 * row. A row with unread notes offers Mark as read; every row can open and
 * copy its link. A person or a bot also offers Block and Mute. Remove is
 * only there when an admin (or the tenant owner) is signed in.
 *
 * @param {boolean} unread
 * @param {{ person?: boolean, admin?: boolean, blocked?: boolean, muted?: boolean }} [opts]
 */
export function rowMenuItems(unread, opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const items = [
    { id: 'open', labelKey: 'sidebar.row_menu.open' },
    { id: 'copy', labelKey: 'sidebar.row_menu.copy_link' },
  ]
  if (unread) items.push({ id: 'read', labelKey: 'sidebar.row_menu.mark_read' })
  if (o.person) {
    items.push({
      id: 'block',
      labelKey: o.blocked ? 'sidebar.row_menu.unblock' : 'sidebar.row_menu.block',
    })
    items.push({
      id: 'mute',
      labelKey: o.muted ? 'sidebar.row_menu.unmute' : 'sidebar.row_menu.mute',
    })
    if (o.admin) items.push({ id: 'remove', labelKey: 'sidebar.row_menu.remove' })
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
