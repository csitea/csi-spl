<!-- spec 097 T014 (G11, spec 5 "event pop-over", 5.1.9): a click on a stored
     event shows what it is - title, time, location, description - with Edit
     and Duplicate. Edit opens CalendarEventDialog on the event; Duplicate
     opens it as a NEW event filled from this one (a copy saves with POST, the
     source is untouched). A small UiDialog, desktop only since spec 106
     T011 (a phone has CalendarPhonePeek). 097 T016 adds guests and
     Yes / Maybe / No here. specs/112 WUI-2: a synced event (`source_key`)
     has no Edit; its "change it in the repo" link is `roadmap_url` as given.
     Copy link (t1 9dec05c3) copies the link that opens this event. -->
<template>
  <UiDialog :open="open" :title="event?.title || ''" size="sm" @update:open="emit('update:open', $event)">
    <div v-if="event" class="cal-pop" data-test="calendar-event-popover" :data-id="event.id">
      <p class="cal-pop__when" data-test="calendar-popover-when" dir="ltr">
        <span v-if="event.color" class="cal-pop__dot" :style="{ background: `var(--cal-color-${event.color})` }" aria-hidden="true" />
        {{ when }}
      </p>
      <p v-if="event.location" class="cal-pop__line" data-test="calendar-popover-location">
        <UiIcon name="pin" :size="16" /><span>{{ event.location }}</span>
      </p>
      <p v-if="event.description" class="cal-pop__desc muted" data-test="calendar-popover-description">{{ event.description }}</p>
      <p v-if="synced" class="cal-pop__line" data-test="calendar-popover-synced">
        <NuxtLink v-if="roadmapHref" :to="roadmapHref" data-test="calendar-popover-repo" @click="emit('update:open', false)">{{ t('calendar_event.synced_link') }}</NuxtLink>
        <span v-else class="muted">{{ t('calendar_event.synced_link') }}</span>
      </p>
    </div>
    <template #footer>
      <div class="cal-pop__actions">
        <span v-if="copied" class="cal-pop__copied muted" role="status" data-test="calendar-popover-copied" :data-key="copied">{{ t(copied) }}</span>
        <button type="button" class="btn ghost" data-test="calendar-popover-copy-link" @click="copyLink(event)">
          <UiIcon name="copy" :size="16" />{{ t('calendar_event.copy_link') }}
        </button>
        <button type="button" class="btn ghost" data-test="calendar-popover-duplicate" @click="emit('duplicate', event!)">{{ t('calendar_event.duplicate') }}</button>
        <button v-if="!synced" type="button" class="btn" data-test="calendar-popover-edit" @click="emit('edit', event!)">{{ t('calendar_event.edit') }}</button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calAddDays } from '~/utils/calendar-year.mjs'
import { isoClock, isoDate, isoDateTime } from '~/utils/date-iso.mjs'
import { calRoadmapHref, calSynced } from '~/utils/calendar-event-form.mjs'
import { useCalendarEventLink } from '~/composables/useCalendarEventLink'

const props = defineProps<{ open: boolean, event: CalendarItem | null }>()
const emit = defineEmits<{ 'update:open': [boolean], edit: [CalendarItem], duplicate: [CalendarItem] }>()
const { t } = useI18n({ useScope: 'global' })
const synced = computed(() => calSynced(props.event))
const roadmapHref = computed(() => calRoadmapHref(props.event))
const { copied, copyLink } = useCalendarEventLink()

/* the viewer's wall time, like the grid: "YYYY-MM-DD HH:MM–HH:MM", a later
   end day in full; an all-day event its UTC day(s) */
const when = computed(() => {
  const ev = props.event
  if (!ev) return ''
  if (ev.all_day) {
    const a = ev.starts_at.slice(0, 10)
    const b = calAddDays(ev.ends_at.slice(0, 10), -1)
    return b > a ? `${a} – ${b}` : a
  }
  const end = isoDate(ev.ends_at) === isoDate(ev.starts_at) ? isoClock(ev.ends_at) : isoDateTime(ev.ends_at)
  return `${isoDateTime(ev.starts_at)}–${end}`
})
</script>

<style scoped>
.cal-pop { display: flex; flex-direction: column; gap: 8px; padding: 0 16px 8px; min-width: 0; }
.cal-pop p { margin: 0; overflow-wrap: anywhere; }
.cal-pop__when { display: flex; align-items: center; gap: 8px; }
.cal-pop__dot { flex: 0 0 auto; width: 12px; height: 12px; border-radius: 50%; }
.cal-pop__line { display: flex; align-items: center; gap: 8px; }
.cal-pop__desc { white-space: pre-wrap; max-height: 12em; overflow: auto; }
.cal-pop__actions { display: flex; justify-content: flex-end; align-items: center; gap: 8px; flex-wrap: wrap; width: 100%; }
.cal-pop__actions .btn { display: inline-flex; align-items: center; gap: 6px; }
.cal-pop__copied { margin-inline-end: auto; }
</style>
