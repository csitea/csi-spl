/* Copy link on a calendar event (t1 9dec05c3): copies the event's link and
   says so for a moment - "Link copied", or "Could not copy" */
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calEventLink } from '~/utils/calendar-event-link.mjs'
import { writeClipboard } from '~/utils/clipboard.mjs'

export function useCalendarEventLink() {
  /** the i18n key of the last copy's answer, '' once it faded */
  const copied = ref('')
  let timer: ReturnType<typeof setTimeout> | undefined
  async function copyLink(ev: CalendarItem | null): Promise<string> {
    const href = calEventLink(ev, location.origin)
    const key = href && await writeClipboard(href) ? 'calendar_event.link_copied' : 'common.copy_failed'
    copied.value = key
    clearTimeout(timer)
    timer = setTimeout(() => { copied.value = '' }, 3000)
    return key
  }
  onBeforeUnmount(() => clearTimeout(timer))
  return { copied, copyLink }
}
