<!-- SPL-983, specs/041 §3.2: the confirm behind a topic card's Delete. It
     names the reply count FIRST (read from the hub, not guessed from the
     screen), then deletes the card and every child in one call. Loaded
     lazily (LazyTopicDeleteDialog): it is needed only after the item is
     picked. -->
<template>
  <UiDialog :open="open" :title="t('feed.topic_delete.title')" size="md" @update:open="emit('update:open', $event)">
    <p class="topic-delete__count" data-testid="topic-delete-count" :data-replies="replies ?? ''">
      {{ replies === null ? t('common.loading') : t('feed.topic_delete.count', { n: replies }) }}
    </p>
    <p class="topic-delete__body" data-testid="topic-delete-body">{{ t('feed.topic_delete.body') }}</p>
    <p v-if="error" class="topic-delete__error" role="alert" data-testid="topic-delete-error">{{ error }}</p>
    <template #footer>
      <div class="topic-delete__actions">
        <button type="button" class="btn ghost" data-autofocus :disabled="busy" data-testid="topic-delete-cancel" @click="emit('update:open', false)">{{ t('common.cancel') }}</button>
        <button
          type="button"
          class="btn ghost topic-delete__confirm"
          data-testid="topic-delete-confirm"
          :disabled="busy || replies === null"
          @click="confirm"
        >
          <UiIcon name="delete" :size="16" />
          <span>{{ busy ? t('feed.topic_delete.busy') : t('feed.topic_delete.confirm') }}</span>
        </button>
      </div>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { topicErrorKey } from '~/utils/topic-archive.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const props = defineProps<{ open: boolean, msgId: string }>()
const emit = defineEmits<{ 'update:open': [boolean], deleted: [{ msg_ids: string[], task_ids: string[] }] }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const busy = ref(false)
const error = ref('')
const replies = ref<number | null>(null)

async function load() {
  error.value = ''
  replies.value = null
  try {
    const size = await withSessionRetry(api, () => api.topicSize(props.msgId))
    replies.value = Math.max(0, Number(size?.replies) || 0)
  } catch (e) {
    error.value = t(topicErrorKey(e))
  }
}

watch(() => [props.open, props.msgId], ([open]) => { if (open) void load() })
onMounted(() => { if (props.open) void load() })

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
</script>

<style scoped>
.topic-delete__count { margin: 0 0 0.5rem; font-weight: 600; overflow-wrap: anywhere; }
.topic-delete__body { margin: 0; overflow-wrap: anywhere; }
.topic-delete__error { margin: 0.5rem 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
.topic-delete__actions { display: flex; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.topic-delete__confirm {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--color-danger);
  border-color: var(--color-danger);
}
</style>
