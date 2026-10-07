<!-- spec 089 T007: the Calendar section. One sheet like Issues (spec 2.1):
     the left rail stays (the sidebar keeps the icon rail only, ChannelSidebar
     calendarRailOnly), the channel / topic / thread panes are closed, and the
     page is two columns - the year strip (CalendarYearStrip, 36 mini-months)
     and the main view. The main view loads as its own chunk on route entry
     (defineAsyncComponent); T008 builds the Day / Week / Month grid there.
     The shown day lives in the URL (?d=YYYY-MM-DD, UTC), so a link or a
     reload keeps the week.
     T009, phone (<= 820 px, spec 2.2): one column. The year strip is a sheet
     over the main view behind the header's calendar button - a picked day
     closes it, Back closes it (useMobileStack overlay) - and the main view
     opens on the Day view.
     spec 106 T004: at <= 820 px with the phone shell on, CalendarPhone (its
     own lazy chunk) is the whole page instead; above 820 px nothing changes.
     It stays opt-in per browser until T011 retires the T009 branch above. -->
<template>
  <div class="feed-col calendar-page" data-test="calendar-page">
    <CalendarPhone v-if="phoneShell" :focus="focus" :today="today" @move="show" />
    <template v-else>
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="calendar-heading">{{ t('calendar.title') }}</h2>
      <span class="calendar-spacer" />
      <button
        type="button"
        class="btn ghost calendar-strip-open"
        data-test="calendar-strip-open"
        :aria-label="t('calendar.year_strip')"
        :aria-expanded="stripOpen ? 'true' : 'false'"
        :title="t('calendar.year_strip')"
        @click="stripOpen = !stripOpen"
      >
        <UiIcon name="calendar" :size="18" />
        <span dir="ltr">{{ focus.slice(0, 7) }}</span>
      </button>
      <SectionClose side="end" />
    </header>
    <div class="calendar-body">
      <CalendarYearStrip v-if="!phone || stripOpen"
        class="calendar-body__strip"
        :class="{ 'calendar-body__strip--sheet': phone }"
        :focus="focus"
        :today="today"
        @pick="pickDay"
        @keydown.esc="stripOpen = false"
      />
      <div class="calendar-body__main">
        <CalendarMainView :focus="focus" :today="today" :phone="phone" @move="show" />
      </div>
    </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { calDayMs, calIsoDay } from '~/utils/calendar-year.mjs'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { useMobileStack } from '~/composables/useMobileStack'
import { mobileOverlayOf } from '~/utils/mobile-stack.mjs'

/* the main view is its own chunk, fetched on route entry (spec 3, AC-02) */
const CalendarMainView = defineAsyncComponent(() => import('~/components/CalendarMainView.vue'))
/* spec 106 T004 (FR-001, FR-012): the phone calendar, a chunk of its own */
const CalendarPhone = defineAsyncComponent(() => import('~/components/CalendarPhone.vue'))

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()

const today = calIsoDay(Date.now())
const focus = computed(() => {
  const d = String(route.query.d || '')
  return Number.isNaN(calDayMs(d)) ? today : d
})

/* T009: on a phone the strip is a sheet, the top level while open - Back
   (chevron, swipe, browser) closes it and the page stays */
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)
const stripOpen = ref(false)
stack.overlay(() => phone.value && stripOpen.value, () => { stripOpen.value = false })
watch(phone, (v) => { if (!v) stripOpen.value = false })
/* spec 106 T004: the phone shell is on in a browser whose localStorage
   'spool-calendar-phone' is '1' (the e2e and the T005..T010 lanes), off
   otherwise, so the phone keeps the T009 calendar while the views are
   placeholders; T011 turns it on for everyone and drops this switch */
const PHONE_SHELL_KEY = 'spool-calendar-phone'
const phoneShellOn = ref(false)
onMounted(() => {
  try { phoneShellOn.value = window.localStorage.getItem(PHONE_SHELL_KEY) === '1' } catch { /* storage off: T009's calendar */ }
})
const phoneShell = computed(() => phone.value && phoneShellOn.value)
/* closing the sheet steps back over its history entry; the day is written
   once that entry is gone, or the router follows the step back onto the
   entry under it and drops the day again */
async function pickDay(iso: string) {
  const sheet = phone.value && stripOpen.value
  stripOpen.value = false
  if (sheet) await sheetEntryGone()
  await show(iso)
}
function sheetEntryGone() {
  const until = Date.now() + 1000
  return new Promise<void>((resolve) => {
    const tick = () => (mobileOverlayOf(window.history.state) === null || Date.now() > until ? resolve() : setTimeout(tick, 16))
    tick()
  })
}

/* a day picked in the strip, or the main view's Today / previous / next */
async function show(iso: string) {
  if (Number.isNaN(calDayMs(iso)) || iso === focus.value) return
  await router.replace({ query: { ...route.query, d: iso === today ? undefined : iso } })
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
.calendar-body__strip { min-height: 0; }
.calendar-body__main {
  min-width: 0;
  min-height: 0;
  overflow: auto;
}
.calendar-strip-open { display: none; }
/* T009 (spec 2.2): one column; the strip a sheet over the main view, clear
   of the bottom composer dock; the main view keeps its own scroller */
@media (max-width: 820px) {
  .calendar-strip-open {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-height: var(--tap);
    min-width: var(--tap);
  }
  .calendar-body {
    position: relative;
    grid-template-columns: minmax(0, 1fr);
  }
  .calendar-body__strip--sheet {
    position: absolute;
    inset: 0;
    z-index: 5;
    padding-bottom: var(--composer-dock-h, 0px);
    background: var(--color-bg);
    border-inline-end: 0;
  }
  .calendar-body__main { display: flex; overflow: hidden; }
}
</style>
