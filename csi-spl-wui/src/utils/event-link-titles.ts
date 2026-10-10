// The titles behind calendar event links in messages (t1 9dec05c3, part 2).
// A lazy chunk: loaded the first time a body shows an event link. It reads
// the reader's OWN calendar (GET /v1/calendar/events) around the link's day,
// so the hub's visibility rule decides: an event the reader may not see is
// not in the answer and its chip never shows a title. One read per day.
import { shallowRef } from 'vue'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { hubJsonHeaders } from '~/utils/hub-headers'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { calAddDays, calIsoDay } from '~/utils/calendar-year.mjs'

/** event id -> title, of every event a read returned */
const titles = shallowRef<ReadonlyMap<string, string>>(new Map())
const asked = new Set<string>()

async function readDay(day: string) {
  /* the link's day is the writer's wall day: a day either side covers any zone */
  const start = `${calAddDays(day, -1)}T00:00:00Z`
  const end = `${calAddDays(day, 2)}T00:00:00Z`
  const api = useSpoolApi()
  let events: CalendarItem[] = []
  try {
    if (api.mock) {
      const { mockCalendarEvents } = await import('~/utils/calendar-mock.mjs')
      events = mockCalendarEvents(start, end, calIsoDay(Date.now())).events || []
    } else {
      const q = new URLSearchParams({ start, end })
      const r = await fetch(`${api.base}/v1/calendar/events?${q}`, { credentials: api.credentials, headers: hubJsonHeaders(api.token), signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
      if (!r.ok) return
      const body = await r.json()
      events = Array.isArray(body?.events) ? body.events : []
    }
  } catch {
    return
  }
  const next = new Map(titles.value)
  for (const ev of events) if (ev && ev.id && ev.title) next.set(ev.id, ev.title)
  titles.value = next
}

/** the event's title as the reader's calendar has it; '' while unknown or not visible */
export function eventTitle(id: string, day: string): string {
  if (day && !asked.has(day)) {
    asked.add(day)
    void readDay(day)
  }
  return titles.value.get(id) || ''
}
