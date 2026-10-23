/*
 * CalendarPhone's events (r19-07): GET /v1/calendar/events for the shown
 * range, the two neighbours prefetched; a newer settle aborts the older
 * fetches. A calendar change here or in another tab drops the cache.
 */
import type { Ref } from 'vue'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'
import { hubJsonHeaders } from '~/utils/hub-headers'
import { CALENDAR_CHANGED_EVENT } from '~/utils/calendar-reminders.mjs'
import { calPhoneRange, calPhoneStep } from '~/utils/calendar-phone-nav.mjs'
import { calLoadWindow } from '~/utils/calendar-year.mjs'

type View = 'month' | 'week' | 'day'
type Api = ReturnType<typeof useSpoolApi>

type EventsOpts = {
  api: Api
  view: Ref<View>
  shownDay: Ref<string>
  today: () => string
}
type FetchCtx = { api: Api, today: () => string, cache: Map<string, CalendarItem[]> }

async function fetchRange(c: FetchCtx, r: { from: string, to: string }, signal: AbortSignal): Promise<CalendarItem[]> {
  const { api, cache } = c
  const key = `${r.from}/${r.to}`
  const hit = cache.get(key)
  if (hit) return hit
  /* a day wider than the range's UTC midnights: a timed event is drawn on
     the viewer's day, so local Monday 00:30 at +03 is Sunday 21:30Z */
  const { start, end } = calLoadWindow(r.from, r.to) || { start: '', end: '' }
  let body: { events?: CalendarItem[] }
  if (api.mock) {
    const { mockCalendarEvents, mockWithIssueDeadlines } = await import('~/utils/calendar-mock.mjs')
    /* SPL-2034: the mock workspace's issue deadlines, as the hub's */
    const rows = await api.listIssues().then((r) => r.issues, () => [])
    body = mockWithIssueDeadlines(mockCalendarEvents(start, end, c.today()), rows)
  } else {
    const q = new URLSearchParams({ start, end })
    const res = await fetch(`${api.base}/v1/calendar/events?${q}`, { credentials: api.credentials, headers: hubJsonHeaders(api.token), signal })
    if (!res.ok) throw new Error('calendar events ' + res.status)
    body = await res.json()
  }
  const list = Array.isArray(body?.events) ? body.events : []
  if (!signal.aborted) cache.set(key, list)
  return list
}

export function useCalendarPhoneEvents(o: EventsOpts) {
  const { view, shownDay } = o
  const items = shallowRef<CalendarItem[]>([])
  const state = ref<'loading' | 'ready' | 'failed'>('loading')
  /* per mount: a module-level cache would outlive the page */
  const cache = new Map<string, CalendarItem[]>()
  const ctx: FetchCtx = { api: o.api, today: o.today, cache }
  let ctl: AbortController | null = null

  async function settle() {
    ctl?.abort()
    const mine = new AbortController()
    ctl = mine
    const timer = setTimeout(() => mine.abort(), DOC_READ_TIMEOUT_MS)
    const day = shownDay.value
    const v = view.value
    const r = calPhoneRange(v, day)
    if (!r) return
    state.value = cache.has(`${r.from}/${r.to}`) ? state.value : 'loading'
    try {
      const list = await fetchRange(ctx, r, mine.signal)
      if (mine.signal.aborted) return
      items.value = list
      state.value = 'ready'
      for (const dir of [1, -1]) {
        const n = calPhoneRange(v, calPhoneStep(v, day, dir))
        if (n && !mine.signal.aborted) await fetchRange(ctx, n, mine.signal).catch(() => [])
      }
    } catch {
      if (mine.signal.aborted) return
      items.value = []
      state.value = 'failed'
    } finally {
      clearTimeout(timer)
    }
  }
  watch([view, shownDay], () => { void settle() })

  function onChanged() {
    cache.clear()
    void settle()
  }
  onMounted(() => {
    void settle()
    window.addEventListener(CALENDAR_CHANGED_EVENT, onChanged)
    /* SPL-2034: a deadline saved in another tab shows on return */
    window.addEventListener('focus', onChanged)
  })
  onBeforeUnmount(() => {
    ctl?.abort()
    window.removeEventListener(CALENDAR_CHANGED_EVENT, onChanged)
    window.removeEventListener('focus', onChanged)
  })

  return { items, state }
}
