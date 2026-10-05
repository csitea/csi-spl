<!-- SPL-983, specs/041 §3.2: the confirm behind a topic card's Delete. The
     title names the reply count (read from the hub, not guessed from the
     screen), then one call deletes the card and every child. Archive is the
     reversible way out and is offered right there (SPL-1001). Loaded lazily
     (LazyTopicDeleteDialog): it is needed only after the item is picked. -->
<template>
  <UiConfirm
    :open="open"
    :title="title"
    testid="topic-delete"
    :confirm-label="t('feed.topic_delete.confirm')"
    :busy-label="t('feed.topic_delete.busy')"
    :busy="busy"
    :error="error"
    @update:open="emit('update:open', $event)"
    @confirm="confirm"
  >
    <p data-testid="topic-delete-count" :data-replies="replies ?? ''">
      {{ replies === null ? t('common.loading') : t('feed.topic_delete.body') }}
    </p>
    <p v-if="archivable && canArchive" class="topic-delete__archive">
      {{ t('feed.topic_delete.archive_hint') }}
      <button type="button" class="topic-delete__archive-link" data-testid="topic-delete-archive" :disabled="busy" @click="archive">
        {{ t('feed.topic_delete.archive') }}
      </button>
    </p>
  </UiConfirm>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { topicErrorKey } from '~/utils/topic-archive.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { createLatest } from '~/utils/latest-only.mjs'

const props = withDefaults(
  defineProps<{
    open: boolean
    msgId: string
    /** false where the topic is archived already (the Archive page) */
    archivable?: boolean
  }>(),
  { archivable: true },
)
const emit = defineEmits<{ 'update:open': [boolean], deleted: [{ msg_ids: string[], task_ids: string[] }] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const archiveUndo = useArchiveUndo()
const busy = ref(false)
const error = ref('')
const replies = ref<number | null>(null)
const canArchive = ref(false)

const title = computed(() => {
  const n = replies.value
  if (!n) return t('feed.topic_delete.title')
  return n === 1 ? t('feed.topic_delete.title_one') : t('feed.topic_delete.title_n', { n })
})

/* The dialog can re-open for another topic while the last size read is in
   flight: only the newest read may write the count and the Archive link. */
const latest = createLatest()
async function load() {
  const mine = latest.next()
  error.value = ''
  replies.value = null
  canArchive.value = false
  try {
    const size = await withSessionRetry(api, () => api.topicSize(props.msgId))
    if (!latest.isLatest(mine)) return
    replies.value = Math.max(0, Number(size?.replies) || 0)
    canArchive.value = size?.can_archive !== false
  } catch (e) {
    if (!latest.isLatest(mine)) return
    error.value = t(topicErrorKey(e))
  }
}

watch(() => [props.open, props.msgId], ([open]) => { if (open) void load() })
onMounted(() => { if (props.open) void load() })

/* The reply count is COSMETIC — it only shapes the title. Delete never needs
   it (deleteTopic acts on msgId alone), so the button is NOT disabled while
   the count loads. It used to be gated on the count being null, and on prd
   latency that made the primary action briefly disabled — which also drops it
   from UiDialog's focus trap, so a keyboard user could not Tab to it or
   activate it with Enter / Space (owner, prd t1 topic b6a7db19). */
async function confirm() {
  if (!props.msgId || busy.value) return
  busy.value = true
  error.value = ''
  try {
    const out = await api.deleteTopic(props.msgId)
    emit('update:open', false)
    emit('deleted', { msg_ids: out?.msg_ids || [props.msgId], task_ids: out?.task_ids || [] })
  } catch (e) {
    error.value = t(topicErrorKey(e))
  } finally {
    busy.value = false
  }
}

/* Archive leaves every feed as a delete does, so the caller's `deleted`
   handler is the right one; only the hub keeps the rows (Archive page). */
async function archive() {
  if (!props.msgId || busy.value) return
  busy.value = true
  error.value = ''
  try {
    await api.archiveTopic(props.msgId, true)
    emit('update:open', false)
    emit('deleted', { msg_ids: [props.msgId], task_ids: [] })
    /* SPL-1264: offer Undo (the same endpoint, archived=false) for 0.7 s */
    archiveUndo.offerUndo(props.msgId)
  } catch (e) {
    error.value = t(topicErrorKey(e, 'archive'))
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.topic-delete__archive { color: var(--color-muted); }
.topic-delete__archive-link {
  padding: 0;
  background: none;
  border: 0;
  color: var(--color-accent);
  font: inherit;
  text-decoration: underline;
  cursor: pointer;
}
.topic-delete__archive-link:disabled { opacity: 0.6; cursor: default; }
</style>
