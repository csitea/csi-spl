<!-- owner HUM-10 (t1 53ab04e7, msg 14b0e604): "the issues listing should
     have checkboxes to perform multiple actions the same way as in gmail".
     With one row or more checked this bar takes the list header's place: the
     page box (all / some / none), the count, the row menu's actions that make
     sense for many (Status, Assignee, Move to, Archive, Delete) and Clear.
     Gmail's notice follows a page-wide check: "All 30 on this page are
     selected. Select all N matching". The page owns the actions and the
     selection; this only draws them. Loaded lazily (the first chunk stays
     as it was): nothing renders it until a row is checked. -->
<template>
  <header class="feed-header issues-bulk" role="toolbar" :aria-label="t('issues_bulk.label')" data-test="issues-bulk-bar" :data-count="count">
    <input
      ref="boxEl"
      type="checkbox"
      class="issues-bulk__box"
      data-test="issues-bulk-page"
      :checked="pageState === 'all'"
      :aria-label="t('issues_bulk.select_page')"
      :title="t('issues_bulk.select_page')"
      @click="emit('toggle-page')"
    >
    <span class="issues-bulk__n" data-test="issues-bulk-count" aria-live="polite">{{ t('issues_bulk.count', { count }) }}</span>
    <span class="issues-bulk__acts">
      <button
        v-for="b in buttons"
        :key="b.id"
        type="button"
        class="btn ghost issues-bulk__btn"
        :class="{ 'issues-bulk__btn--danger': b.danger }"
        :data-test="'issues-bulk-' + b.id"
        :disabled="busy"
        :aria-label="t(b.labelKey)"
        :title="t(b.labelKey)"
        :aria-haspopup="b.menu ? 'listbox' : 'dialog'"
        @click="emit('act', b.id, $event)"
      >
        <UiIcon :name="b.icon" :size="16" />
        <span v-if="!phone" class="issues-bulk__label">{{ t(b.labelKey) }}</span>
      </button>
    </span>
    <button type="button" class="btn ghost issues-bulk__btn issues-bulk__clear" data-test="issues-bulk-clear" :aria-label="t('issues_bulk.clear')" :title="t('issues_bulk.clear')" @click="emit('clear')">
      <UiIcon name="x" :size="16" />
      <span v-if="!phone" class="issues-bulk__label">{{ t('issues_bulk.clear') }}</span>
    </button>
    <p v-if="notice" class="issues-bulk__note muted" data-test="issues-bulk-note">
      <span>{{ notice }}{{ ' ' }}</span>
      <button v-if="canMatchAll && !allMatching" type="button" class="issues-bulk__link" data-test="issues-bulk-all-matching" :disabled="selecting || busy" @click="emit('select-matching')">
        {{ selecting ? t('issues_bulk.selecting') : t('issues_bulk.select_matching', { total }) }}
      </button>
    </p>
    <p v-if="progress" class="issues-bulk__note muted" role="status" data-test="issues-bulk-progress">{{ t('issues_bulk.progress', { done: progress.done, total: progress.total }) }}</p>
    <p v-else-if="result" class="issues-bulk__note" :class="{ 'issues-error': result.failed.length }" role="status" data-test="issues-bulk-result" :data-failed="result.failed.join(',')">
      <span>{{ t('issues_bulk.result_ok', { done: result.done, total: result.total }) }}</span>
      <span v-if="result.failed.length" data-test="issues-bulk-failed">{{ ' ' + t('issues_bulk.result_failed', { count: result.failed.length, keys: result.failed.join(', ') }) }}</span>
    </p>
  </header>
</template>

<script setup lang="ts">
import type { UiIconName } from '@/utils/uiIcons'

export type BulkAction = 'status' | 'assign' | 'move' | 'archive' | 'delete'

const props = defineProps<{
  count: number
  /** the page box: 'none' | 'some' | 'all' of the rows shown */
  pageState: string
  /** rows shown (loaded) and the hub's count for the filters */
  shown: number
  total: number
  /** more rows match than are loaded: Gmail's "Select all N matching" */
  canMatchAll: boolean
  allMatching: boolean
  selecting?: boolean
  busy?: boolean
  phone?: boolean
  progress?: { done: number, total: number } | null
  result?: { done: number, total: number, failed: string[] } | null
}>()
const emit = defineEmits<{
  (e: 'act', id: BulkAction, ev: MouseEvent): void
  (e: 'toggle-page' | 'clear' | 'select-matching'): void
}>()
const { t } = useI18n({ useScope: 'global' })

type BulkButton = { id: BulkAction, icon: UiIconName, labelKey: string, menu?: boolean, danger?: boolean }
/* the row menu's order (IssueRowMenu): Status, Assignee, Move, Archive, Delete */
const buttons: BulkButton[] = [
  { id: 'status', icon: 'pencil', labelKey: 'issues_bulk.status', menu: true },
  { id: 'assign', icon: 'user', labelKey: 'issues_bulk.assign', menu: true },
  { id: 'move', icon: 'move', labelKey: 'issues_bulk.move', menu: true },
  { id: 'archive', icon: 'archive', labelKey: 'issues_bulk.archive' },
  { id: 'delete', icon: 'delete', labelKey: 'issues_bulk.delete', danger: true },
]

/* Gmail's line under a page-wide check */
const notice = computed(() => {
  if (props.allMatching) return t('issues_bulk.all_matching', { count: props.count })
  if (props.pageState === 'all' && props.canMatchAll) return t('issues_bulk.all_page', { count: props.shown })
  return ''
})

/* some rows checked: the page box shows the dash */
const boxEl = ref<HTMLInputElement | null>(null)
watchEffect(() => { if (boxEl.value) boxEl.value.indeterminate = props.pageState === 'some' })
</script>

<style scoped>
.issues-bulk { flex-wrap: wrap; gap: 8px; row-gap: 4px; background: var(--color-selected); }
.issues-bulk__box { width: 18px; height: 18px; margin: 0; flex: 0 0 auto; accent-color: var(--color-accent); cursor: pointer; }
.issues-bulk__n { flex: 0 0 auto; font-weight: 600; white-space: nowrap; }
.issues-bulk__acts { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 4px; min-width: 0; }
.issues-bulk__btn { display: inline-flex; align-items: center; gap: 6px; flex: 0 0 auto; }
.issues-bulk__btn--danger:hover, .issues-bulk__btn--danger:focus-visible { color: var(--color-danger); }
.issues-bulk__clear { margin-inline-start: auto; }
.issues-bulk__note { flex: 1 0 100%; margin: 0; font-size: 0.875rem; }
.issues-bulk__link { padding: 0; margin-inline-start: 6px; border: 0; background: transparent; color: var(--color-accent); font: inherit; text-decoration: underline; cursor: pointer; }
@media (max-width: 820px) {
  .issues-bulk { padding: 6px 12px; }
  .issues-bulk__box { width: var(--tap, 44px); height: 22px; }
  .issues-bulk__btn { min-width: var(--tap, 44px); min-height: var(--tap, 44px); justify-content: center; padding: 0; }
}
</style>
