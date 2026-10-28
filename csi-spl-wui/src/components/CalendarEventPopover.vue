<!-- spec 097 T014 (G11, spec 5 "event pop-over", 5.1.9): a click on a stored
     event shows what it is - title, time, location, description - with Edit
     and Duplicate. Edit opens CalendarEventDialog on the event; Duplicate
     opens it as a NEW event filled from this one (a copy saves with POST, the
     source is untouched). A small UiDialog, desktop only since spec 106
     T011 (a phone has CalendarPhonePeek). 097 T016 adds guests and
     Yes / Maybe / No here. specs/112 WUI-2: a synced event (`source_key`)
     has no Edit; its "change it in the repo" link is `roadmap_url` as given.
     Copy link (t1 9dec05c3) copies the link that opens this event.
     SPL-2034 (design B, t1 edc177bc): an issue deadline opens it read-only -
     key, title, due time (viewer's zone), status, assignee from the hub's
     item - with Open issue (navigates) and Copy link; no Edit, no Duplicate. -->
<template>
  <UiDialog :open="open" :title="deadline ? `${event!.id} ${event!.title}` : event?.title || ''" size="sm" @update:open="emit('update:open', $event)">
    <div v-if="event" class="cal-pop" data-test="calendar-event-popover" :data-id="event.id">
      <p class="cal-pop__when" data-test="calendar-popover-when" dir="ltr">
        <span v-if="event.color" class="cal-pop__dot" :style="{ background: `var(--cal-color-${event.color})` }" aria-hidden="true" />
        {{ when }}
      </p>
      <dl v-if="deadline" class="cal-pop__facts" data-test="calendar-popover-deadline">
        <dt>{{ t('issues.field_status') }}</dt>
        <dd data-test="calendar-popover-status" :data-status="event.status || ''">{{ event.status ? statusLabel(event.status) : '–' }}</dd>
        <dt>{{ t('issues.field_assignee') }}</dt>
        <dd data-test="calendar-popover-assignee">{{ event.assignee || '–' }}</dd>
      </dl>
      <p v-if="event.location" class="cal-pop__line" data-test="calendar-popover-location">
        <UiIcon name="pin" :size="16" /><span>{{ event.location }}</span>
      </p>
      <p v-if="event.description" class="cal-pop__desc muted" data-test="calendar-popover-description">{{ event.description }}</p>
      <p v-if="!deadline" class="cal-pop__line" data-test="calendar-popover-discussion">
        <NuxtLink v-if="topicTo" :to="topicTo" data-test="calendar-popover-discussion-link">{{ t('calendar_event.open_discussion') }}</NuxtLink>
        <span v-else class="muted">{{ t('calendar_event.discussion_empty') }}</span>
      </p>
      <p v-if="!deadline" class="cal-pop__links" data-test="calendar-popover-issues">
        <template v-if="issueLinks.length">
          <NuxtLink v-for="iss in issueLinks" :key="iss.key" :to="iss.to" data-test="calendar-popover-issue">{{ iss.key }}</NuxtLink>
        </template>
        <span v-else class="muted">{{ t('calendar_event.issues_empty') }}</span>
      </p>
      <p v-if="!deadline" data-test="calendar-popover-owner">
        <span dir="ltr">{{ ownerLabel || t('calendar_event.owner_empty') }}</span>
      </p>
      <p v-if="synced" class="cal-pop__line" data-test="calendar-popover-synced">
        <NuxtLink v-if="roadmapHref" :to="roadmapHref" data-test="calendar-popover-repo" @click="emit('update:open', false)">{{ t('calendar_event.synced_link') }}</NuxtLink>
        <span v-else class="muted">{{ t('calendar_event.synced_link') }}</span>
      </p>
    </div>
    <template #footer>
      <div class="cal-pop__actions" :class="{ 'cal-pop__actions--deadline': deadline }">
        <span v-if="copied" class="cal-pop__copied muted" role="status" data-test="calendar-popover-copied" :data-key="copied">{{ t(copied) }}</span>
        <button type="button" class="btn ghost" data-test="calendar-popover-copy-link" @click="copyLink(event)">
          <UiIcon name="copy" :size="16" />{{ t('calendar_event.copy_link') }}
        </button>
        <a v-if="deadline" :href="issueLink" class="btn cal-pop__open" data-test="calendar-popover-open-issue" @click="onOpenIssue">{{ t('calendar_event.open_issue') }}</a>
        <template v-else>
          <button type="button" class="btn ghost" data-test="calendar-popover-duplicate" @click="emit('duplicate', event!)">{{ t('calendar_event.duplicate') }}</button>
          <button v-if="!synced" type="button" class="btn" data-test="calendar-popover-edit" @click="emit('edit', event!)">{{ t('calendar_event.edit') }}</button>
        </template>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import type { CalendarItem } from '~/utils/calendar-mock.mjs'
import { calAddDays } from '~/utils/calendar-year.mjs'
import { isoClock, isoDate, isoDateTime } from '~/utils/date-iso.mjs'
import { calDiscussionRef, calRoadmapHref, calSynced } from '~/utils/calendar-event-form.mjs'
import { useCalendarEventLink } from '~/composables/useCalendarEventLink'
import { issuePageHref } from '~/utils/issue-calendar-link.mjs'
import { statusLabel } from '~/utils/issues-view.mjs'

const props = defineProps<{ open: boolean, event: CalendarItem | null }>()
const emit = defineEmits<{ 'update:open': [boolean], edit: [CalendarItem], duplicate: [CalendarItem], 'open-issue': [to: string] }>()
const { t } = useI18n({ useScope: 'global' })
const synced = computed(() => calSynced(props.event))
const roadmapHref = computed(() => calRoadmapHref(props.event))
const { copied, copyLink } = useCalendarEventLink()
/* SPL-2034: an issue deadline, read only; Open issue goes to the issue */
const deadline = computed(() => props.event?.source === 'issue')
const localePath = useLocalePath()
const router = useRouter()
const issueTo = computed(() => localePath(issuePageHref(props.event?.issue_key || props.event?.id || '')))
const topicTo = computed(() => {
  const id = calDiscussionRef(props.event?.topic_id)
  return id ? localePath('/t/' + id) : ''
})
const issueLinks = computed(() => {
  const keys = Array.isArray(props.event?.issue_keys) ? props.event.issue_keys : []
  return keys.flatMap((key) => {
    const href = issuePageHref(String(key || ''))
    return href ? [{ key: String(key), to: localePath(href) }] : []
  })
})
const ownerLabel = computed(() => String(props.event?.owner_id || '').trim())
/* a real link (a new tab works); a plain click goes through the view, which
   first drops issue= from the calendar's URL so Back returns to the week
   with the pop-over closed */
const issueLink = computed(() => router.resolve(issueTo.value).href)
function onOpenIssue(e: MouseEvent) {
  if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  e.preventDefault()
  emit('open-issue', issueTo.value)
}

/* the viewer's wall time, like the grid: "YYYY-MM-DD HH:MM–HH:MM", a later
   end day in full; an all-day event its UTC day(s) */
const when = computed(() => {
  const ev = props.event
  if (!ev) return ''
  if (ev.source === 'issue') return isoDateTime(ev.starts_at)
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
.cal-pop__links { display: flex; flex-wrap: wrap; gap: 8px; margin: 0; }
.cal-pop__actions { display: flex; justify-content: flex-end; align-items: center; gap: 8px; flex-wrap: wrap; width: 100%; }
.cal-pop__actions .btn { display: inline-flex; align-items: center; gap: 6px; }
.cal-pop__copied { margin-inline-end: auto; }
.cal-pop__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 4px 12px; margin: 0; }
.cal-pop__facts dt { color: var(--color-muted); font-size: 0.875rem; }
.cal-pop__facts dd { margin: 0; overflow-wrap: anywhere; }
.cal-pop__actions--deadline .btn { min-height: 48px; }
.cal-pop__open { text-decoration: none; }
</style>
