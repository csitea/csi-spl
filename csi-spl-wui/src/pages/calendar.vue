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
      <SectionClose side="end" />
    </header>
    <div class="calendar-body">
      <CalendarYearStrip class="calendar-body__strip"
        :focus="focus"
        :today="today"
        @pick="show"
      />
      <div class="calendar-body__main">
        <CalendarMainView :focus="focus" :today="today" @move="show" />
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

/* spec 106 T011: a phone (<= 820 px) gets CalendarPhone, everyone */
const stack = useMobileStack()
const phone = computed(() => stack.isMobile.value)

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
</style>
