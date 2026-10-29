<!-- Spec 162 B7 (E5; owner HUM-10, t1 cfaa3dce, msg 9d250f31: "it should be
     possible to mass filter and select events ... likewise the issues
     listing"). With one row or more checked on Monitoring -> Events this bar
     takes the head actions' place: the page box (all / some / none of the
     rows shown), the count, Delete selected and Clear selection. The page
     owns the selection and the delete; this only draws them. Loaded lazily:
     nothing renders it until a row is checked. -->
<template>
  <div class="events-bulk" role="toolbar" :aria-label="t('events.bulk_label')" data-test="events-bulk-bar" :data-count="count">
    <input
      ref="boxEl"
      type="checkbox"
      class="events-bulk__box"
      data-test="events-bulk-page"
      :checked="pageState === 'all'"
      :aria-label="t('events.select_page')"
      :title="t('events.select_page')"
      @click="emit('toggle-page')"
    >
    <span class="events-bulk__n" data-test="events-bulk-count" aria-live="polite">{{ t('events.selected_count', { n: count }) }}</span>
    <button
      type="button"
      class="btn events-bulk__btn events-bulk__btn--danger"
      data-test="events-bulk-delete"
      :disabled="busy"
      aria-haspopup="dialog"
      @click="emit('delete')"
    >
      <UiIcon name="delete" :size="16" />
      <span>{{ t('events.delete_selected') }}</span>
    </button>
    <button
      type="button"
      class="btn ghost events-bulk__btn"
      data-test="events-bulk-clear"
      :disabled="busy"
      @click="emit('clear')"
    >
      <UiIcon name="x" :size="16" />
      <span>{{ t('events.clear_selection') }}</span>
    </button>
  </div>
</template>

<script setup lang="ts">
const props = defineProps<{
  count: number
  /** the page box: 'none' | 'some' | 'all' of the rows shown */
  pageState: string
  busy?: boolean
}>()
const emit = defineEmits<{
  (e: 'toggle-page' | 'delete' | 'clear'): void
}>()
const { t } = useI18n({ useScope: 'global' })

/* some rows shown are checked: the page box shows the dash */
const boxEl = ref<HTMLInputElement | null>(null)
watchEffect(() => { if (boxEl.value) boxEl.value.indeterminate = props.pageState === 'some' })
</script>

<style scoped>
.events-bulk {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.events-bulk__box {
  width: 18px;
  height: 18px;
  margin: 0;
  flex: 0 0 auto;
  accent-color: var(--color-accent);
  cursor: pointer;
}
.events-bulk__n { flex: 0 0 auto; font-weight: 600; white-space: nowrap; }
.events-bulk__btn { display: inline-flex; align-items: center; gap: 6px; flex: 0 0 auto; }
.events-bulk__btn--danger:hover,
.events-bulk__btn--danger:focus-visible { color: var(--color-danger); }
/* the phone's bar (usePhone, <= 820px): tap targets */
@media (max-width: 820px) {
  .events-bulk { padding: 0 12px 8px; }
  .events-bulk__btn { min-height: var(--tap, 44px); }
}
</style>
