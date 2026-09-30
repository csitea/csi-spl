<!-- 714c7028: the confirm behind dragging a topic card onto another topic. A
     merge folds the WHOLE source topic (opener + every reply + thread) into the
     target, ordered by the original timestamps, and the source topic then
     disappears - so, unlike a plain move, it asks first. The message count is
     read from the hub (topicSize), not guessed from the screen. Loaded lazily
     (LazyMergeConfirmDialog): needed only once a topic is dropped on a topic. -->
<template>
  <UiConfirm
    :open="Boolean(ask)"
    :title="title"
    testid="merge-confirm"
    :confirm-label="t('feed.merge.confirm')"
    :busy-label="t('feed.merge.busy')"
    :busy="busy"
    :disabled="count === null"
    :error="error"
    @update:open="onOpen"
    @confirm="confirm"
  >
    <p data-testid="merge-confirm-body" :data-count="count ?? ''">
      {{ count === null ? t('common.loading') : t('feed.merge.body') }}
    </p>
  </UiConfirm>
</template>

<script setup lang="ts">
import { useMove } from '~/composables/useMove'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { moveErrorKey } from '~/utils/move-apply.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

const { t } = useI18n({ useScope: 'global' })
const move = useMove()
const api = useSpoolApi()
const ask = computed(() => move.mergeAsk.value)
const busy = ref(false)
const error = ref('')
const count = ref<number | null>(null)

const target = computed(() => String(ask.value?.targetTitle || '').trim() || t('feed.merge.the_topic'))
const title = computed(() => {
  const n = count.value
  if (!n) return t('feed.merge.title', { target: target.value })
  return n === 1 ? t('feed.merge.title_one', { target: target.value }) : t('feed.merge.title_n', { n, target: target.value })
})

async function load(msgId: string) {
  error.value = ''
  count.value = null
  try {
    const size = await withSessionRetry(api, () => api.topicSize(msgId))
    // The whole topic moves: the card plus its replies.
    count.value = Math.max(1, (Math.max(0, Number(size?.replies) || 0)) + 1)
  } catch (e) {
    error.value = t(moveErrorKey(e))
    count.value = 1
  }
}

watch(ask, (a) => { if (a) void load(a.msgId) }, { immediate: true })

function onOpen(open: boolean) {
  if (!open && !busy.value) move.cancelMerge()
}

function confirm() {
  if (busy.value || !ask.value) return
  // confirmMerge clears mergeAsk (so the dialog closes) and runs the merge; the
  // result and its Undo land in the move toast.
  void move.confirmMerge()
}
</script>
