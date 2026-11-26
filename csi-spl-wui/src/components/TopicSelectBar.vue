<!-- Spec 186 4.1 step 1 item 5 and 7.1.6 (row M3; owner HUM-10, t1 032d8010,
     msg 5fdfff6c: "the same way as ... the archive button on the issues"):
     the selection bar. While topics are ticked it takes a topic list's
     header place, drawn as IssuesBulkBar.vue is: the page box, "n selected"
     ("in k channels" past one), Select by title, the bulk actions in the
     order they registered (Multicast, spec 186 M11; Set priority, spec 153),
     Clear; a progress and a result line the running action fills, and
     Gmail's "Select all N matching" under a page-wide tick. The tick logic is
     utils/issues-bulk.ts, through stores/topicSelect.ts. Esc clears.
     SPL-6613 (owner HUM-10, t1 f7b53cf8, msg 5b8f9db2): the title search
     is a field of the topic list filter (TopicListControl.vue), so the bar
     has no Select by title; the page box ticks the topics listed, and under
     a title filter "Select all N matching" adds the hub's N matches.
     On a channel page the bar starts with the topic list's filter and sort
     (TopicListControl, the header's own), so the list can be filtered by
     title while topics are ticked; a filter change keeps the selection
     (spec 186 4.1 step 1 item 3), and the page box then ticks what is
     listed (SPL-6613, holder GO dc0fa0cb).
     Loaded lazily: nothing renders it until a topic is ticked. -->
<template>
  <header class="feed-header topic-select" role="toolbar" :aria-label="t('topic_select.label')" data-test="topic-select-bar" :data-count="store.count" :data-channels="store.channels">
    <span v-if="channelPage" class="topic-select__list"><LazyTopicListControl /></span>
    <input
      v-if="store.shown.length"
      ref="boxEl"
      type="checkbox"
      class="topic-select__box"
      data-test="topic-select-page"
      :checked="store.page === 'all'"
      :aria-label="t('topic_select.select_page')"
      :title="t('topic_select.select_page')"
      @click="store.togglePage()"
    >
    <span class="topic-select__n" data-test="topic-select-count" aria-live="polite" :title="countText">{{ countText }}</span>
    <span class="topic-select__acts">
      <button
        v-for="a in store.actions"
        :key="a.id"
        type="button"
        class="btn ghost topic-select__btn"
        :data-test="'topic-select-act-' + a.id"
        :disabled="store.busy"
        :aria-label="t(a.labelKey)"
        :title="t(a.labelKey)"
        @click="runAction(a)"
      >
        <UiIcon :name="a.icon" :size="16" />
        <span v-if="!phone" class="topic-select__label">{{ t(a.labelKey) }}</span>
      </button>
    </span>
    <button type="button" class="btn ghost topic-select__btn topic-select__clear" data-test="topic-select-clear" :aria-label="t('topic_select.clear')" :title="t('topic_select.clear')" @click="store.clear()">
      <UiIcon name="x" :size="16" />
      <span v-if="!phone" class="topic-select__label">{{ t('topic_select.clear') }}</span>
    </button>
    <div v-if="canMatchAll || store.progress || store.result" class="topic-select__notes">
      <p v-if="canMatchAll && !store.allMatching" class="topic-select__note muted" data-test="topic-select-matching-line">
        <button type="button" class="topic-select__link" data-test="topic-select-all-matching" :disabled="store.matching || store.busy" @click="selectAllMatching()">
          {{ t('topic_select.select_matching', { total: matchTotal }) }}
        </button>
      </p>
      <p v-if="store.progress" class="topic-select__note muted" role="status" data-test="topic-select-progress">{{ t('issues_bulk.progress', { done: store.progress.done, total: store.progress.total }) }}</p>
      <p v-else-if="store.result" class="topic-select__note" :class="{ 'issues-error': store.result.failed.length }" role="status" data-test="topic-select-result">
        <span>{{ t('issues_bulk.result_ok', { done: store.result.done, total: store.result.total }) }}</span>
        <span v-if="store.result.failed.length">{{ ' ' + t('issues_bulk.result_failed', { count: store.result.failed.length, keys: store.result.failed.join(', ') }) }}</span>
      </p>
    </div>
    <LazyMulticastDialog v-if="multicast.open.value" />
  </header>
</template>

<script setup lang="ts">
import { useTopicSelect } from '~/composables/useTopicSelect'
import { useMulticastAction } from '~/composables/useMulticastSend'

defineProps<{ phone?: boolean }>()
const { t } = useI18n({ useScope: 'global' })
const { store, runAction, canMatchAll, matchTotal, selectAllMatching, onKey } = useTopicSelect()
/* spec 186 M11: Multicast joins the bar's actions (7.1.6); its dialog opens on the selection */
const multicast = useMulticastAction()
/* SPL-6613: a channel's topic list keeps its filter (and the title field) in the bar */
const route = useRoute()
const channelPage = computed(() => /\/channel\/[^/]+\/?$/.test(route.path))
const countText = computed(() => store.channels > 1
  ? `${t('topic_select.count', { count: store.count })} ${t('topic_select.in_channels', { n: store.channels })}`
  : t('topic_select.count', { count: store.count }))

/* some topics shown are ticked: the page box shows the dash */
const boxEl = ref<HTMLInputElement | null>(null)
watchEffect(() => { if (boxEl.value) boxEl.value.indeterminate = store.page === 'some' })
/* Esc clears, as on issues (not from a field, dialog or menu) */
onMounted(() => document.addEventListener('keydown', onKey))
onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKey)
  /* the bar goes (a workspace switch) with the dialog open: close it, so the action settles and busy clears */
  if (multicast.open.value) multicast.close()
})
</script>

<style scoped>
.topic-select { flex-wrap: wrap; gap: 8px; row-gap: 4px; background: var(--color-selected); }
.topic-select__list { display: inline-flex; flex: 0 0 auto; }
.topic-select__box { width: 18px; height: 18px; margin: 0; flex: 0 0 auto; accent-color: var(--color-accent); cursor: pointer; }
.topic-select__n { flex: 0 1 auto; min-width: 0; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.topic-select__acts { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 4px; min-width: 0; }
.topic-select__btn { display: inline-flex; align-items: center; gap: 6px; flex: 0 0 auto; }
.topic-select__clear { margin-inline-start: auto; }
.topic-select__notes { flex: 1 0 100%; display: flex; flex-direction: column; gap: 4px; }
.topic-select__note { margin: 0; font-size: 0.875rem; }
.topic-select__link { padding: 0; border: 0; background: transparent; color: var(--color-accent); font: inherit; text-decoration: underline; cursor: pointer; }
/* a phone: one 44 px row, icon buttons (each name on aria-label and title),
   as the issues list's bar (IssuesBulkBar.vue, SPL-3026) */
@media (max-width: 820px) {
  .topic-select { flex-wrap: wrap; gap: 0; padding: 0 2px; }
  .topic-select__n { flex: 1 1 auto; font-size: 0.8125rem; }
  .topic-select__acts { flex-wrap: nowrap; gap: 0; }
  .topic-select__btn { min-width: var(--tap, 44px); min-height: var(--tap, 44px); justify-content: center; padding: 0; }
  .topic-select__box { width: var(--tap, 44px); height: 18px; }
  .topic-select__notes { padding: 0 10px 6px; }
}
</style>
