<!-- SPL-983 (specs/041 §3.1): the Archive. Every archived topic card of the
     tenant this member may read (GET /v1/view/archived), newest archived
     first. Each row opens its topic, and carries Unarchive and - for its
     author, the tenant owner or an admin - Delete. The left-rail entry that
     opens this page is SPL-979's (CLE-35017). -->
<template>
  <div class="feed-col" data-test="archive-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="archive-title">
        <UiIcon name="archive" :size="18" />
        <span>{{ t('archive.title') }}</span>
      </h2>
    </header>
    <div class="feed-body">
      <p class="muted archive-hint">{{ t('archive.hint') }}</p>
      <p v-if="loadError" class="archive-error" role="alert" data-test="archive-error">{{ t(loadError) }}</p>
      <p v-else-if="loading" class="muted" data-test="archive-loading">{{ t('common.loading') }}</p>
      <p v-else-if="!rows.length" class="muted" data-test="archive-empty">{{ t('archive.empty') }}</p>
      <ul v-else class="archive-list" data-test="archive-list">
        <li v-for="r in rows" :key="r.msg_id" class="archive-row" data-test="archive-row" :data-msg-id="r.msg_id">
          <NuxtLink class="archive-row__open" :to="openPath(r)" data-test="archive-open">
            <span class="archive-row__title">{{ r.title || r.msg_id }}</span>
            <span class="archive-row__meta muted">
              <span v-if="r.channel" dir="ltr">#{{ r.channel }}</span>
              <HumanName :id="r.from" :box="r.from_box" />
              <span>{{ t('feed.replies', { n: r.replies }, r.replies) }}</span>
              <span dir="ltr">{{ t('archive.archived_at', { when: isoDateTime(r.archived_at) }) }}</span>
            </span>
          </NuxtLink>
          <div class="archive-row__actions">
            <button
              type="button"
              class="btn ghost archive-row__btn"
              data-test="archive-unarchive"
              :disabled="busy === r.msg_id"
              @click="unarchive(r.msg_id)"
            >
              <UiIcon name="unarchive" :size="16" />
              <span>{{ t('archive.unarchive') }}</span>
            </button>
            <button
              v-if="r.can_delete"
              type="button"
              class="btn ghost archive-row__btn archive-row__btn--danger"
              data-test="archive-delete"
              :disabled="busy === r.msg_id"
              @click="deleting = r.msg_id"
            >
              <UiIcon name="delete" :size="16" />
              <span>{{ t('archive.delete') }}</span>
            </button>
          </div>
          <p v-if="rowError[r.msg_id]" class="archive-error" role="alert">{{ t(rowError[r.msg_id]) }}</p>
        </li>
      </ul>
      <button v-if="next && !loading" type="button" class="btn ghost" data-test="archive-load-more" @click="load(true)">
        {{ t('feed.load_more') }}
      </button>
    </div>
    <LazyTopicDeleteDialog
      v-if="deleting"
      :open="Boolean(deleting)"
      :msg-id="deleting"
      @update:open="(v: boolean) => { if (!v) deleting = '' }"
      @deleted="onDeleted"
    />
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { archivedRow, topicErrorKey, topicFrameDrops, withoutCards } from '~/utils/topic-archive.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

type Row = ReturnType<typeof archivedRow>

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const live = useLive()
const localePath = useLocalePath()
const rows = ref<Row[]>([])
const next = ref<string | null>(null)
const loading = ref(false)
const loadError = ref('')
const busy = ref('')
const deleting = ref('')
const rowError = ref<Record<string, string>>({})

useHead({ title: () => t('archive.title') })

async function load(more = false) {
  loading.value = true
  loadError.value = ''
  try {
    /* The first read of a fresh page can go out before the session door is
       armed (a 401): withSessionRetry arms it and reads again, as every view does. */
    const page = await withSessionRetry(api, () => api.listArchived({ before: more ? next.value || undefined : undefined }))
    const got = page.cards.map(archivedRow)
    rows.value = more ? [...rows.value, ...got.filter((r) => !rows.value.some((o) => o.msg_id === r.msg_id))] : got
    next.value = page.next
  } catch {
    loadError.value = 'archive.load_failed'
  } finally {
    loading.value = false
  }
}

/** A lobby card's topic is its own thread (task_id = its msg_id). */
function openPath(r: Row) {
  const task = r.task_id && r.task_id !== live.lobbyTaskId.value ? r.task_id : r.msg_id
  return localePath(`/t/${task}`)
}

async function unarchive(id: string) {
  busy.value = id
  rowError.value = { ...rowError.value, [id]: '' }
  try {
    await api.archiveTopic(id, false)
    rows.value = withoutCards(rows.value, [id])
  } catch (e) {
    rowError.value = { ...rowError.value, [id]: topicErrorKey(e, 'archive') }
  } finally {
    busy.value = ''
  }
}

function onDeleted(out: { msg_ids: string[] }) {
  rows.value = withoutCards(rows.value, [deleting.value, ...out.msg_ids])
  deleting.value = ''
}

let offTopic = () => {}
onMounted(() => {
  live.ensure()
  void load()
  /* Another tab archived (reload to get its row), unarchived or deleted one. */
  offTopic = live.onTopic((f) => {
    if (f.type === 'topic_archived' && f.archived === true) void load()
    else if (f.type === 'topic_archived') rows.value = withoutCards(rows.value, [String(f.msg_id || '')])
    else rows.value = withoutCards(rows.value, topicFrameDrops(f))
  })
})
onUnmounted(() => offTopic())
</script>

<style scoped>
.archive-title { display: inline-flex; align-items: center; gap: 8px; margin: 0; }
.archive-hint { margin: 0 0 0.75rem; overflow-wrap: anywhere; }
.archive-error { margin: 0.25rem 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
.archive-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.archive-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  min-width: 0;
}
.archive-row__open {
  flex: 1 1 16rem;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
  color: var(--color-fg);
  text-decoration: none;
}
.archive-row__title { font-weight: 600; overflow-wrap: anywhere; }
.archive-row__meta { display: flex; flex-wrap: wrap; gap: 4px 10px; font-size: 0.8125rem; min-width: 0; }
.archive-row__actions { display: flex; gap: 6px; flex-wrap: wrap; }
.archive-row__btn { display: inline-flex; align-items: center; gap: 6px; }
.archive-row__btn--danger { color: var(--color-danger); border-color: var(--color-danger); }
/* SPL-993: touch screens get 44 px buttons; a phone gives the row's actions
   their own full-width line under the title. */
@media (max-width: 820px) {
  .archive-row__btn { min-height: var(--tap, 44px); }
}
@media (max-width: 600px) {
  .archive-row__open { flex-basis: 100%; }
  .archive-row__actions { flex-basis: 100%; }
  .archive-row__btn { flex: 1 1 0; justify-content: center; }
}
</style>
