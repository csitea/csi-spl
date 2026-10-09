<!-- spec 089 T007: the Calendar section. One sheet like Issues (spec 2.1):
     the left rail stays (the sidebar keeps the icon rail only, ChannelSidebar
     calendarRailOnly), the channel / topic / thread panes are closed, and the
     page is two columns - the year strip (CalendarYearStrip, 36 mini-months)
     and the main view. The main view loads as its own chunk on route entry
     (defineAsyncComponent); T008 builds the Day / Week / Month grid there.
     The shown day lives in the URL (?d=YYYY-MM-DD, UTC), so a link or a
     reload keeps the week.
     spec 106 T011: at <= 820 px the page is CalendarPhone (its own lazy
     chunk, spec 106 T004) for everyone; above 820 px nothing changes. The
     089 T009 phone branch (the strip as a sheet, the main view's Day / Week
     list) is retired. -->
<template>
  <div class="feed-col calendar-page" data-test="calendar-page">
    <CalendarPhone v-if="phone" :focus="focus" :today="today" @move="show" />
    <template v-else>
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="calendar-heading">{{ t('calendar.title') }}</h2>
      <span class="calendar-spacer" />
      <!-- spec 107 v1.2 T011 (owner R11): the right side's hours tabs, shown or hidden -->
      <button
        type="button"
        class="btn ghost calendar-hours-toggle"
        data-test="calendar-hours-toggle"
        :aria-pressed="hoursPanel ? 'true' : 'false'"
        @click="toggleHours"
      >{{ t('hours_cal.panel_title') }}</button>
      <SectionClose side="end" />
    </header>
    <div class="calendar-body" :class="{ 'calendar-body--hours': hoursPanel }">
      <CalendarYearStrip class="calendar-body__strip"
        :focus="focus"
        :today="today"
        @pick="show"
      />
      <div class="calendar-body__main">
        <CalendarMainView ref="mainView" :focus="focus" :today="today" @move="show" />
      </div>
      <CalendarHoursPanel v-if="hoursPanel" class="calendar-body__hours" :focus="focus" :today="today" closable @open-day="openHoursDay" @close="toggleHours" />
    </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { calDayMs, calIsoDay } from '~/utils/calendar-year.mjs'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { useMobileStack } from '~/composables/useMobileStack'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { signedOutCalendarTarget } from '~/utils/public-calendar.mjs'

/* the main view is its own chunk, fetched on route entry (spec 3, AC-02) */
const CalendarMainView = defineAsyncComponent(() => import('~/components/CalendarMainView.vue'))
/* spec 106 T004 (FR-001, FR-012): the phone calendar, a chunk of its own */
const CalendarPhone = defineAsyncComponent(() => import('~/components/CalendarPhone.vue'))
/* spec 107 v1.2 T011 (owner R11): the hours tabs on the right, a chunk of their own */
const CalendarHoursPanel = defineAsyncComponent(() => import('~/components/CalendarHoursPanel.vue'))

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()

const today = calIsoDay(Date.now())
const focus = computed(() => {
  const d = String(route.query.d || '')
  return Number.isNaN(calDayMs(d)) ? today : d
})

/* spec 106 T011: a phone (<= 820 px) gets CalendarPhone, everyone */
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)

/* a day picked in the strip, or the main view's Today / previous / next */
async function show(iso: string) {
  if (Number.isNaN(calDayMs(iso)) || iso === focus.value) return
  await router.replace({ query: { ...route.query, d: iso === today ? undefined : iso } })
}

/* spec 107 v1.2 T011: the hours panel is open unless the member closed it in
   this browser; a day picked there moves the week and opens its dialog */
const HOURS_PANEL_KEY = 'spool.calendar.hours-panel'
const hoursPanel = ref(true)
onMounted(() => {
  try { hoursPanel.value = localStorage.getItem(HOURS_PANEL_KEY) !== 'off' } catch { /* private mode: open */ }
})
function toggleHours() {
  hoursPanel.value = !hoursPanel.value
  try { localStorage.setItem(HOURS_PANEL_KEY, hoursPanel.value ? 'on' : 'off') } catch { /* kept for this page */ }
}
const mainView = ref<{ openHours: (day: string) => void } | null>(null)
async function openHoursDay(day: string) {
  await show(day)
  mainView.value?.openHours(day)
}

/* spec 2.1: no third pane - a topic panel open beside the channel the reader
   came from closes when the Calendar opens, whichever store holds it */
const topic = useTopicStore()
const livePane = useLiveFeed('pane')
function closeTopicPanel() {
  if (livePane.taskId) livePane.close()
  if (topic.open) topic.close()
}
watch(() => [livePane.taskId, topic.open], closeTopicPanel)
onMounted(closeTopicPanel)

/* HUM-10 t1 ef57739c: signed out, the public calendar (releases and feature
   posts, no tenant entry) instead. A real navigation: while hydrating, the
   workspace shell is pinned under a client one. Here, not in the global
   middleware, so it rides this lazy chunk (ci_initial_gzip_kb). */
const session = useSessionStore()
const spoolApi = useSpoolApi()
const localePath = useLocalePath()
onMounted(() => {
  if (session.state === 'loading') void session.probe()
  watch(() => session.state, (s) => {
    const to = signedOutCalendarTarget(s, spoolApi.mock)
    if (to) window.location.replace(localePath(to))
  }, { immediate: true })
})
useHead(() => ({ title: t('calendar.title') }))
</script>

<style scoped>
.calendar-page { min-height: 0; }
.calendar-spacer { flex: 1 1 auto; }
.calendar-body {
  display: grid;
  grid-template-columns: 240px minmax(0, 1fr);
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
}
.calendar-body--hours { grid-template-columns: 240px minmax(0, 1fr) 300px; }
.calendar-body__strip { min-height: 0; }
.calendar-body__hours {
  min-height: 0;
  overflow: auto;
  border-inline-start: 1px solid var(--border, #8883);
}
.calendar-body__main {
  min-width: 0;
  min-height: 0;
  overflow: auto;
}
</style>
