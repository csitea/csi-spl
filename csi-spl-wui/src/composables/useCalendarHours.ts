/**
 * Spec 107 v1.2 T011: the member's hours for the days a calendar view shows,
 * from GET /v1/me/hours (one answer per period the range touches). Used only
 * by the calendar's lazy chunks (027). A failed read leaves the lines without
 * totals; the lines themselves still show (every working day, spec 5.1).
 */
import { useSpoolApi } from '~/composables/useSpoolApi'
import { hoursIndex } from '~/utils/hours-calendar.mjs'
import { loadHoursRange, putMyHours } from '~/utils/hours-calendar-api.mjs'
import { hoursRefusalKey } from '~/utils/hours-mine.mjs'

/** the window event a write of hours sends, so every calendar view re-reads */
export const HOURS_CHANGED_EVENT = 'spool:hours-changed'

export type HoursRow = { target: string, state: string, minutes: number, suggested_minutes?: number, delta?: number, note?: string, blocks?: { start: string, end: string }[] }
export type HoursDay = { date: string, today: boolean, closed: boolean, frozen: boolean, open: number, approved: number, total: number, rows: HoursRow[], period: Record<string, any> | null }
export type HoursBody = { tz?: string, today?: string, period?: Record<string, any>, days?: unknown[] }
/** what the Working hours dialog of one day shows (CalendarEventDialog `hours`) */
export type CalHoursEntry = { day: string, data?: HoursDay, body?: HoursBody | null, tz?: string, state?: string }

export function useCalendarHours(range: () => { first: string, last: string }, today: () => string) {
  const api = useSpoolApi()
  const bodies = shallowRef<HoursBody[]>([])
  const state = ref<'idle' | 'loading' | 'ready' | 'failed'>('idle')
  const index = computed(() => hoursIndex(bodies.value) as Map<string, HoursDay>)
  const tz = computed(() => String(bodies.value[0]?.tz || 'UTC'))
  let seq = 0
  let ctl: AbortController | null = null

  async function load() {
    const { first, last } = range()
    if (!first || !last) return
    const mine = ++seq
    ctl?.abort()
    ctl = new AbortController()
    state.value = 'loading'
    try {
      const got = await loadHoursRange(api, first, last, today(), ctl.signal)
      if (mine !== seq) return
      bodies.value = got as HoursBody[]
      state.value = 'ready'
    } catch {
      if (mine !== seq) return
      state.value = 'failed'
    }
  }

  watch(() => { const r = range(); return `${r.first}|${r.last}` }, () => { void load() })
  const onChanged = () => { void load() }
  onMounted(() => {
    void load()
    window.addEventListener(HOURS_CHANGED_EVENT, onChanged)
  })
  onBeforeUnmount(() => {
    ctl?.abort()
    window.removeEventListener(HOURS_CHANGED_EVENT, onChanged)
  })

  /** the dialog's entry for `day`: its row data and the period answer holding it */
  function entryFor(day: string): CalHoursEntry {
    const body = bodies.value.find((b) => Array.isArray(b.days) && b.days.some((d) => (d as { date?: string })?.date === day)) || null
    return { day, data: index.value.get(day), body, tz: tz.value, state: state.value }
  }

  return { bodies, index, state, tz, reload: load, entryFor }
}

/**
 * Spec 107 T013 / T014: the member's writes (PUT /v1/me/hours). One at a
 * time; a refusal is kept as an i18n key (409 frozen, 400 day cap). After a
 * write every calendar view and the panel re-read (HOURS_CHANGED_EVENT); the
 * answer (the period as it now reads) is returned for the caller to show at
 * once.
 */
export function useHoursWrite(today: () => string) {
  const api = useSpoolApi()
  const busy = ref(false)
  const error = ref('')
  async function write(body: { entries?: unknown[], remove?: unknown[], resubmit?: string }): Promise<HoursBody | null> {
    if (busy.value) return null
    busy.value = true
    error.value = ''
    try {
      const out = await putMyHours(api, body, today()) as HoursBody
      window.dispatchEvent(new Event(HOURS_CHANGED_EVENT))
      return out
    } catch (e) {
      error.value = hoursRefusalKey(e)
      return null
    } finally {
      busy.value = false
    }
  }
  return { busy, error, write }
}
