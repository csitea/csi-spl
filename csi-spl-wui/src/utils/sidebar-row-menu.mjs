/**
 * Items in the left-pane row menu. The icon rail (the tab switcher) is not a
 * row. A row with unread notes offers Mark as read; every row can open and
 * copy its link.
 */
export function rowMenuItems(unread) {
  const items = [
    { id: 'open', labelKey: 'sidebar.row_menu.open' },
    { id: 'copy', labelKey: 'sidebar.row_menu.copy_link' },
  ]
  if (unread) items.push({ id: 'read', labelKey: 'sidebar.row_menu.mark_read' })
  return items
}
