<!-- Spec 107 5.3 / Q7 = B (T019): what time is booked against. Recent topics,
     issues (by key or title) and channels, with one search box over all
     three. Emits `pick` with the hours target (t:<task_id> for a topic or an
     issue's topic, ch:<channel>) and a label to show. No dialog of its own:
     the header timer puts it in one, and T014's "+ Add" can put it in its
     own. Loaded only with its host (027). -->
<template>
  <div ref="root" class="hours-picker" data-test="hours-target-picker" @keydown="onListKey">
    <input
      v-model="query"
      class="hours-picker__filter"
      type="search"
      data-autofocus
      data-test="hours-picker-filter"
      autocomplete="off"
      :placeholder="t('hours_timer.picker_filter')"
      :aria-label="t('hours_timer.picker_filter')"
      @keydown.enter.prevent="pickFirst"
    >
    <p v-if="loading && !groups.length" class="muted hours-picker__empty">{{ t('common.loading') }}</p>
    <p v-else-if="!groups.length" class="muted hours-picker__empty" data-test="hours-picker-empty">{{ t('hours_timer.picker_empty') }}</p>
    <div v-for="g in groups" :key="g.kind" class="hours-picker__group">
      <h3 class="hours-picker__head">{{ t(`hours_timer.picker_${g.kind}`) }}</h3>
      <ul class="hours-picker__list">
        <li v-for="row in g.rows" :key="row.target">
          <button
            type="button"
            class="hours-picker__row"
            data-test="hours-picker-row"
            :data-target="row.target"
            :data-kind="g.kind"
            @click="emit('pick', { target: row.target, label: row.label })"
          >
            <span v-if="row.badge" class="hours-picker__badge">{{ row.badge }}</span>
            <span class="hours-picker__label">{{ row.title }}</span>
            <span v-if="row.hint" class="muted hours-picker__hint">{{ row.hint }}</span>
          </button>
        </li>
      </ul>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useChannelStore } from '~/stores/channel'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { Issue } from '~/utils/issues.mjs'

type Row = { target: string, label: string, title: string, badge: string, hint: string, last: string }
type Group = { kind: 'topics' | 'issues' | 'channels', rows: Row[] }

const emit = defineEmits<{ pick: [{ target: string, label: string }] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const channel = useChannelStore()
const root = ref<HTMLElement | null>(null)
const query = ref('')
const loading = ref(true)
const topics = ref<{ task_id: string, channel?: string | null, subject?: string, last_ts?: string }[]>([])
const issues = ref<Issue[]>([])

/* recent first; with no query the list stays short */
const RECENT = 8

const groups = computed<Group[]>(() => {
  const q = query.value.trim().toLowerCase()
  const hit = (...s: string[]) => !q || s.some((x) => x.toLowerCase().includes(q))
  const issueTasks = new Set(issues.value.map((i) => i.task_id).filter(Boolean))
  const topicRows = topics.value
    .filter((tp) => tp.task_id && !issueTasks.has(tp.task_id))
    .map((tp): Row => {
      const title = String(tp.subject || '').trim() || tp.task_id
      return { target: `t:${tp.task_id}`, label: title, title, badge: '', hint: tp.channel ? `#${tp.channel}` : '', last: String(tp.last_ts || '') }
    })
    .filter((r) => hit(r.title, r.hint))
    .sort((a, b) => b.last.localeCompare(a.last))
  const issueRows = issues.value
    .filter((i) => i.task_id && i.status !== 'done' && !i.canceled_at)
    .map((i): Row => ({ target: `t:${i.task_id}`, label: `${i.key} ${i.title}`.trim(), title: i.title, badge: i.key, hint: '', last: i.updated_at || i.created_at }))
    .filter((r) => hit(r.badge, r.title))
    .sort((a, b) => b.last.localeCompare(a.last))
  const channelRows = channel.channels
    .map((c): Row => ({ target: `ch:${c.channel_id}`, label: `#${c.name}`, title: c.name, badge: '#', hint: '', last: String(c.last_ts || '') }))
    .filter((r) => hit(r.title))
    .sort((a, b) => b.last.localeCompare(a.last))
  const cut = (rows: Row[]) => (q ? rows : rows.slice(0, RECENT))
  const out: Group[] = [
    { kind: 'topics', rows: cut(topicRows) },
    { kind: 'issues', rows: cut(issueRows) },
    { kind: 'channels', rows: cut(channelRows) },
  ]
  return out.filter((g) => g.rows.length)
})

async function load() {
  loading.value = true
  const [tp, is] = await Promise.allSettled([
    withSessionRetry(api, () => api.listTopics({ limit: 50 })),
    withSessionRetry(api, () => api.listIssues()),
  ])
  if (tp.status === 'fulfilled') topics.value = tp.value.topics
  if (is.status === 'fulfilled') issues.value = is.value.issues || []
  loading.value = false
}
onMounted(() => {
  void load()
  root.value?.querySelector<HTMLInputElement>('[data-test=hours-picker-filter]')?.focus()
})

function pickFirst() {
  const first = groups.value[0]?.rows[0]
  if (first) emit('pick', { target: first.target, label: first.label })
}

/* Arrows move between the filter and the rows */
function onListKey(ev: KeyboardEvent) {
  if (ev.key !== 'ArrowDown' && ev.key !== 'ArrowUp') return
  const box = root.value
  if (!box) return
  const list = [...box.querySelectorAll<HTMLButtonElement>('[data-test=hours-picker-row]')]
  if (!list.length) return
  const at = list.findIndex((el) => el === document.activeElement)
  ev.preventDefault()
  if (ev.key === 'ArrowDown') {
    list[at < 0 ? 0 : Math.min(list.length - 1, at + 1)].focus()
    return
  }
  if (at <= 0) box.querySelector<HTMLElement>('[data-test=hours-picker-filter]')?.focus()
  else list[at - 1].focus()
}
</script>

<style scoped>
.hours-picker { display: flex; flex-direction: column; gap: 0.5rem; min-height: 0; min-width: 0; }
.hours-picker__filter {
  width: 100%;
  min-height: 44px;
  box-sizing: border-box;
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
}
.hours-picker__empty { margin: 0.5rem 0; }
.hours-picker__head { margin: 0.5rem 0 0.25rem; font-size: 0.75rem; font-weight: 600; color: var(--color-muted); text-transform: uppercase; letter-spacing: 0.04em; }
.hours-picker__list { list-style: none; margin: 0; padding: 0; }
.hours-picker__row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: 100%;
  min-height: 44px;
  box-sizing: border-box;
  padding: 0.25rem 0.75rem;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.hours-picker__row:hover,
.hours-picker__row:focus-visible { background: var(--color-surface-hover); }
.hours-picker__badge { flex: none; color: var(--color-muted); font-variant-numeric: tabular-nums; }
.hours-picker__label { min-width: 0; flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hours-picker__hint { flex: none; max-width: 40%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.75rem; }
</style>
