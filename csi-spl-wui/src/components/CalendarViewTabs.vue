<!-- SPL-4060 (owner HUM-10, t1 080e1f77, poll 7c472af4): the desktop
     calendar's vertical tab group, a narrow strip at the grid's left edge
     (Q1). It replaced the page's header bar (msg a62b3dce) and the main
     view's top bar, so it holds what they held: the section close, the
     views Day, 3 days, Week and Month, then Hours (the hours panel, msg
     a0a8fc08), then Today, previous / next and the period title (Q3), and
     the calendar menu (the trash) at the bottom. A view tab opens that view
     on the period holding today (msg 396e95d3). Part of CalendarMainView's
     lazy chunk. -->
<template>
  <nav class="cal-tabs" data-test="calendar-view-tabs" :aria-label="t('calendar.view')">
    <div class="cal-tabs__close">
      <SectionClose side="start" />
      <SectionClose side="end" />
    </div>
    <div class="cal-tabs__list" role="tablist" aria-orientation="vertical" :aria-label="t('calendar.view')" @keydown="onKey">
      <button
        v-for="v in CAL_DESK_VIEWS"
        :key="v"
        type="button"
        role="tab"
        class="cal-tabs__tab"
        :data-test="`calendar-view-${v}`"
        :aria-selected="v === view ? 'true' : 'false'"
        :tabindex="v === view ? 0 : -1"
        @click="emit('view', v)"
      >{{ t(LABELS[v]) }}</button>
    </div>
    <button
      type="button"
      class="cal-tabs__tab cal-tabs__hours"
      data-test="calendar-hours-toggle"
      :aria-pressed="hoursOpen ? 'true' : 'false'"
      @click="emit('hours')"
    >{{ t('hours_cal.panel_title') }}</button>
    <span class="cal-tabs__rule" aria-hidden="true" />
    <button type="button" class="btn ghost cal-tabs__today" data-test="calendar-today" @click="emit('today')">{{ t('calendar.today') }}</button>
    <div class="cal-tabs__step">
      <button type="button" class="icon-btn" data-test="calendar-prev" :aria-label="prevLabel" :title="prevLabel" @click="emit('step', -1)">
        <UiIcon name="chevron-left" :size="18" />
      </button>
      <button type="button" class="icon-btn" data-test="calendar-next" :aria-label="nextLabel" :title="nextLabel" @click="emit('step', 1)">
        <UiIcon name="chevron-right" :size="18" />
      </button>
    </div>
    <h3 class="cal-tabs__range" data-test="calendar-range" aria-live="polite" dir="ltr">
      <span v-for="line in title" :key="line">{{ line }}</span>
    </h3>
    <span class="cal-tabs__spacer" />
    <button
      type="button"
      class="icon-btn cal-tabs__menu"
      data-test="calendar-menu"
      :aria-label="t('calendar_trash.menu')"
      :title="t('calendar_trash.menu')"
      aria-haspopup="menu"
      :aria-expanded="menuOpen ? 'true' : 'false'"
      @click="emit('menu', $event)"
    >
      <UiIcon name="more" :size="18" />
    </button>
  </nav>
</template>

<script setup lang="ts">
import { CAL_DESK_VIEWS } from '~/utils/calendar-desktop-view.mjs'

const props = defineProps<{ view: string, title: string[], hoursOpen: boolean, menuOpen: boolean }>()
const emit = defineEmits<{ view: [v: string], hours: [], today: [], step: [dir: 1 | -1], menu: [e: MouseEvent] }>()

const { t } = useI18n({ useScope: 'global' })
const LABELS: Record<string, string> = {
  day: 'calendar.view_day',
  '3day': 'calendar.view_3day',
  week: 'calendar.view_week',
  month: 'calendar_phone.view_month',
}
const PREV: Record<string, string> = { day: 'calendar.prev_day', '3day': 'calendar.prev_3day', week: 'calendar.prev_week', month: 'calendar_phone.prev_month' }
const NEXT: Record<string, string> = { day: 'calendar.next_day', '3day': 'calendar.next_3day', week: 'calendar.next_week', month: 'calendar_phone.next_month' }
const prevLabel = computed(() => t(PREV[props.view] || PREV.week))
const nextLabel = computed(() => t(NEXT[props.view] || NEXT.week))

/* a tablist is one tab stop: the arrow keys pick the view above / below */
function onKey(e: KeyboardEvent) {
  const dir = e.key === 'ArrowDown' ? 1 : e.key === 'ArrowUp' ? -1 : 0
  if (!dir) return
  e.preventDefault()
  const i = CAL_DESK_VIEWS.indexOf(props.view)
  const next = CAL_DESK_VIEWS[(i + dir + CAL_DESK_VIEWS.length) % CAL_DESK_VIEWS.length]
  emit('view', next)
  void nextTick(() => (e.currentTarget as HTMLElement | null)?.querySelector<HTMLElement>(`[data-test="calendar-view-${next}"]`)?.focus())
}
</script>

<style scoped>
.cal-tabs {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 4px;
  width: 5.5rem;
  flex: 0 0 auto;
  padding: 8px 6px;
  border-inline-end: 1px solid var(--color-border);
  min-height: 0;
  overflow-y: auto;
}
.cal-tabs__close { display: flex; justify-content: center; min-height: 0; }
.cal-tabs__list { display: flex; flex-direction: column; gap: 2px; }
.cal-tabs__tab {
  min-height: 2.25rem;
  padding: 4px 6px;
  border: 0;
  border-inline-start: 3px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.8125rem;
  text-align: start;
  cursor: pointer;
  overflow-wrap: anywhere;
}
.cal-tabs__tab:hover { background: var(--color-surface-hover); }
.cal-tabs__tab:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 1px; }
.cal-tabs__tab[aria-selected='true'],
.cal-tabs__tab[aria-pressed='true'] {
  border-inline-start-color: var(--color-accent);
  background: var(--color-selected);
  font-weight: 600;
}
.cal-tabs__hours { margin-top: 4px; }
.cal-tabs__rule { height: 1px; margin: 6px 0; background: var(--color-border); }
.cal-tabs__today { min-height: 2.25rem; padding: 4px 6px; font-size: 0.8125rem; }
.cal-tabs__step { display: flex; justify-content: space-between; }
.cal-tabs__range {
  display: flex;
  flex-direction: column;
  margin: 2px 0 0;
  font-size: 0.75rem;
  font-weight: 600;
  text-align: center;
  font-variant-numeric: tabular-nums;
}
.cal-tabs__spacer { flex: 1 1 auto; }
.cal-tabs__menu { align-self: center; }
</style>
