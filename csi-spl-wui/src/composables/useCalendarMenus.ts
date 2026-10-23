/*
 * The week view's menus (r19-05, 097 T017 + t1 9dec05c3): Undo after a
 * delete, the ... menu and its trash, and the right-click menu of a stored
 * event (Copy link). Call it once at setup, after useCalendarDrag: a
 * right-click while a drag is active keeps the browser's menu away.
 */
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calStored } from '~/utils/calendar-event-form.mjs'
import { calendarRestore } from '~/utils/calendar-events-api.mjs'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import { useCalendarEventLink } from '~/composables/useCalendarEventLink'

type MenusOpts = {
  api: ReturnType<typeof useSpoolApi>
  today: () => string
  reload: () => void
  say: (key: string) => void
  active: () => boolean
}

export function useCalendarMenus({ api, today, reload, say, active }: MenusOpts) {
  const CAL_UNDO_MS = 10000
  const undoEv = shallowRef<CalendarItem | null>(null)
  const undoBusy = ref(false)
  function onDeleted(ev: CalendarItem) {
    reload()
    undoEv.value = ev
  }
  async function undoDelete() {
    const ev = undoEv.value
    if (!ev || undoBusy.value) return
    undoBusy.value = true
    try {
      await withSessionRetry(api, () => calendarRestore(api, ev.id, today()))
      window.dispatchEvent(new Event(CALENDAR_CHANGED_EVENT))
      reload()
    } catch {
      say('calendar_trash.restore_failed')
    } finally {
      undoBusy.value = false
      undoEv.value = null
    }
  }

  const MENU_ITEMS: PointMenuItem[] = [{ id: 'trash', icon: 'trash', labelKey: 'calendar_trash.title' }]
  const menu = ref<{ x: number, y: number } | null>(null)
  function openMenu(e: MouseEvent) {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect()
    menu.value = menu.value ? null : { x: r.left, y: r.bottom }
  }
  const trashOpen = ref(false)
  const trashMounted = ref(false)
  function onMenu(id: string) {
    menu.value = null
    if (id !== 'trash') return
    trashMounted.value = true
    trashOpen.value = true
  }
  /* t1 9dec05c3: a right-click on a stored event offers Copy link; the
     answer shows as the calendar's notice. A hold that became a drag keeps
     the browser's menu away as before (onContextMenu). */
  const ITEM_MENU_ITEMS: PointMenuItem[] = [{ id: 'copy_link', icon: 'copy', labelKey: 'calendar_event.copy_link' }]
  const itemMenu = shallowRef<{ x: number, y: number, ev: CalendarItem } | null>(null)
  const { copyLink } = useCalendarEventLink()
  function onItemMenu(e: MouseEvent, ev: CalendarItem) {
    if (active()) e.preventDefault()
    if (active() || !calStored(ev)) return
    e.preventDefault()
    itemMenu.value = { x: e.clientX, y: e.clientY, ev }
  }
  async function onItemMenuChoose(id: string) {
    const ev = itemMenu.value?.ev || null
    itemMenu.value = null
    if (id === 'copy_link' && ev) say(await copyLink(ev))
  }
  return {
    CAL_UNDO_MS, undoEv, undoBusy, onDeleted, undoDelete,
    MENU_ITEMS, menu, openMenu, trashOpen, trashMounted, onMenu,
    ITEM_MENU_ITEMS, itemMenu, onItemMenu, onItemMenuChoose,
  }
}
