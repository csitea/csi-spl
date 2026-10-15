/**
 * Spec 118 T005 (sections 5.2, 6.3, 8.1): the person's hours across every
 * workspace for one window, from GET /v1/me/realm/hours, for the /me/hours
 * view (T006). Today's running timers (6.3, this device's localStorage, the
 * hub never sees them) are redrawn every minute by hoursWithTimers, without a
 * read. The D3 limit warning (amber at 90 %, red past 100 %) is computed
 * here from actual and the person's limit; it is never sent or stored.
 */
import type { Ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { browserTimeZone } from '~/utils/date-iso.mjs'
import type { PersonalDay, Totals } from '~/utils/hours-across'
import { hoursDayIn, hoursLimitInEffect, hoursLimitLevel, hoursSum, hoursWithTimers } from '~/utils/hours-across.mjs'
import { loadRealmHours } from '~/utils/realm-hours-api.mjs'

type RealmBody = Awaited<ReturnType<typeof loadRealmHours>>

/** how often the running timers are redrawn */
const TICK_MS = 60_000

/**
 * @param range the from..to asked (both '' = the person's current week)
 * @param timers workspace id -> RFC 3339 start of its running timer
 */
export function useRealmHours(range: () => { from: string, to: string }, timers: Ref<Record<string, string>>) {
  const api = useSpoolApi()
  const body = shallowRef<RealmBody | null>(null)
  const state = ref<'idle' | 'loading' | 'ready' | 'failed'>('idle')
  const now = ref(Date.now())
  const tz = computed(() => body.value?.tz || 'UTC')
  const today = computed(() => hoursDayIn(now.value, tz.value))
  let seq = 0
  let ctl: AbortController | null = null
  let tick: ReturnType<typeof setInterval> | null = null

  /** the days with today's timers drawn as provisional spans */
  const days = computed<PersonalDay[]>(() => {
    const got = (body.value?.days || []) as PersonalDay[]
    const running = timers.value || {}
    if (!Object.keys(running).length) return got
    const has = got.some((d) => d.day === today.value)
    const { from = '', to = '' } = body.value || {}
    if (!has && !(from <= today.value && today.value <= to)) return got
    const list = has ? got : [...got, emptyDay(today.value)].sort((a, b) => a.day.localeCompare(b.day))
    return list.map((d) => (d.day === today.value ? hoursWithTimers(d, running, tz.value, now.value) : d))
  })
  const totals = computed<Totals>(() => hoursSum(days.value))
  const todayDay = computed(() => days.value.find((d) => d.day === today.value) || null)

  /** the provisional spans of today, one per running timer */
  const provisional = computed(() => {
    const out: { workspace: string, start: string, end: string }[] = []
    for (const [ws, sh] of Object.entries(todayDay.value?.workspaces || {})) {
      for (const s of sh.spans) if (s.provisional) out.push({ workspace: ws, start: s.start, end: s.end })
    }
    return out
  })

  const limit = computed(() => hoursLimitInEffect(body.value?.limits || [], today.value))
  /** D3: today's actual against the day limit, the window's against the week limit */
  const dayWarning = computed(() => hoursLimitLevel(todayDay.value?.actual || 0, limit.value?.day_minutes))
  const weekWarning = computed(() => hoursLimitLevel(totals.value.actual, limit.value?.week_minutes))

  async function load() {
    const { from, to } = range()
    const mine = ++seq
    ctl?.abort()
    ctl = new AbortController()
    state.value = 'loading'
    try {
      const got = await loadRealmHours(api, { from, to, tz: browserTimeZone() }, ctl.signal)
      if (mine !== seq) return
      body.value = got
      state.value = 'ready'
    } catch {
      if (mine !== seq) return
      state.value = 'failed'
    }
  }

  watch(() => { const w = range(); return `${w.from}|${w.to}` }, () => { void load() })
  onMounted(() => {
    void load()
    tick = setInterval(() => { now.value = Date.now() }, TICK_MS)
  })
  onBeforeUnmount(() => {
    ctl?.abort()
    if (tick) clearInterval(tick)
  })

  return { body, state, tz, today, days, totals, todayDay, provisional, limit, dayWarning, weekWarning, load }
}

function emptyDay(day: string): PersonalDay {
  return {
    day, reported: 0, open: 0, actual: 0, overlap: 0, unplaced: 0, data_error_minutes: 0,
    approx: false, incomplete: false, unavailable: [], overlap_intervals: [], workspaces: {},
  }
}
