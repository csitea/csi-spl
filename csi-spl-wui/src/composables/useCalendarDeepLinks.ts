/**
 * The calendar week's deep links (CalendarMainView, r17-04).
 * /calendar?event=<id> (a reminder's Open, 089 T006) opens that event once
 * the shown week holds it; /calendar?d=<day>&issue=<KEY> (SPL-2034) opens that
 * deadline's pop-over, scrolled into view. A link the week lacks says so in
 * the view's notice. The watches are made here, in the view's setup.
 */
import type { Ref, ShallowRef } from 'vue'
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calDeadline, calSynced } from '~/utils/calendar-event-form.mjs'
import { calAddDays } from '~/utils/calendar-year.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'

export type CalendarDeepLinkOptions = {
  items: ShallowRef<CalendarItem[]>
  state: Ref<'loading' | 'ready' | 'failed'>
  weekStart: Ref<string>
  weekEl: Ref<HTMLElement | null>
  peekOpen: Ref<boolean>
  openPeek: (ev: CalendarItem) => void
  openEdit: (ev: CalendarItem) => void
  /** a notice that fades */
  say: (key: string) => void
  /** a notice that stays (no fade) */
  showNotice: (key: string) => void
  /** the view moves to the week of this day */
  move: (iso: string) => void
  api: ReturnType<typeof useSpoolApi>
}

export function useCalendarDeepLinks(o: CalendarDeepLinkOptions) {
  const { items, state, weekStart, weekEl, peekOpen, openPeek, openEdit, say, showNotice, move, api } = o
  const route = useRoute()
  const router = useRouter()

  let askedEvent = ''
  watch([items, state, () => route.query.event], () => {
    const id = String(route.query.event || '')
    if (!id || id === askedEvent) return
    const ev = items.value.find((x) => x.id === id)
    if (!ev) {
      if (state.value === 'ready') void linkMissing(id, String(route.query.d || ''))
      return
    }
    askedEvent = id
    if (calSynced(ev)) openPeek(ev)
    else openEdit(ev)
  })

  /* t1 9dec05c3 part 3: a linked event the shown week lacks. The reader's own
     calendar around ?d= decides (event-link-titles, lazy): not there is
     "not available to you" - never the title. A link with no day (a reminder's
     Open) stays silent, as before. */
  async function linkMissing(id: string, day: string) {
    if (!day) return
    askedEvent = id
    try {
      const { eventSeen } = await import('~/utils/event-link-titles')
      if (await eventSeen(id, day) === false && String(route.query.event || '') === id) say('calendar_event.not_available')
    } catch { /* nothing to say */ }
  }

  /* SPL-2034: closing the pop-over drops issue= (replace). A miss reads the
     issue once (deadlineLinkMiss). */
  let askedIssue = ''
  const issueMiss = shallowRef<{ issue: string, key: string, denied: boolean } | null>(null)
  watch([items, state, () => route.query.issue], () => {
    const key = String(route.query.issue || '')
    if (!key) { askedIssue = ''; return }
    if (key === askedIssue) return
    const ev = items.value.find((x) => calDeadline(x) && x.id === key)
    if (!ev) {
      if (state.value === 'ready') void issueLinkMissing(key)
      return
    }
    askedIssue = key
    openPeek(ev)
    void nextTick(() => weekEl.value?.querySelector<HTMLElement>(`[data-source=issue][data-id="${CSS.escape(key)}"]`)?.scrollIntoView({ block: 'center', inline: 'nearest' }))
  })
  watch(peekOpen, (open) => {
    if (open || !route.query.issue) return
    askedIssue = ''
    void router.replace({ query: { ...route.query, issue: undefined } })
  })
  /* openPeek put this deadline's key in the URL itself */
  function askIssue(key: string) {
    askedIssue = key
  }
  /* Open issue: one history entry, the week left behind without issue= */
  async function openIssue(to: string) {
    askedIssue = ''
    if (route.query.issue) await router.replace({ query: { ...route.query, issue: undefined } })
    peekOpen.value = false
    await router.push(to)
  }
  async function issueLinkMissing(key: string) {
    askedIssue = key
    const { deadlineLinkMiss } = await import('~/utils/issue-calendar-miss.mjs')
    const miss = await deadlineLinkMiss(api, key, weekStart.value, calAddDays(weekStart.value, 7))
    if (String(route.query.issue || '') !== key) return
    if (miss.moveTo) { askedIssue = ''; move(miss.moveTo); return }
    /* it stays (no fade): the week is otherwise blank about the link */
    issueMiss.value = { issue: key, key: miss.notice, denied: miss.denied }
    showNotice(miss.notice)
  }

  return { issueMiss, openIssue, askIssue }
}
