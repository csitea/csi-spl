<!-- Spec 143 2.2 T023 (SPL-2787): the Releases tab's filter bar. The range
     pills (Today, 7 days, 30 days, 90 days; one is always on), the kind and
     area pills (any number on; none = all), and the search box. Each change
     is an update:<field> event; the search waits RELEASE_SEARCH_DEBOUNCE_MS
     after the last key so one word is one read, not one per letter. -->
<template>
  <div class="rf-bar" role="group" :aria-label="t('reporting.releases.filters_label')" data-test="releases-filters">
    <div class="rf-row" role="group" :aria-label="t('reporting.releases.range_label')" data-test="releases-range">
      <button
        v-for="r in RELEASE_RANGES"
        :key="r"
        type="button"
        class="rf-pill"
        :class="{ 'rf-pill--on': range === r }"
        :aria-pressed="range === r ? 'true' : 'false'"
        :data-test="'releases-range-' + r"
        @click="emit('update:range', r)"
      >{{ t('reporting.releases.range_' + r) }}</button>
    </div>
    <div class="rf-row" role="group" :aria-label="t('reporting.releases.kind_label')" data-test="releases-kinds">
      <button
        v-for="k in RELEASE_KINDS"
        :key="k"
        type="button"
        class="rf-pill rf-pill--code"
        :class="{ 'rf-pill--on': kinds.includes(k) }"
        :aria-pressed="kinds.includes(k) ? 'true' : 'false'"
        :data-test="'releases-kind-' + k"
        @click="emit('update:kinds', togglePill(RELEASE_KINDS, kinds, k))"
      >{{ k }}</button>
    </div>
    <div class="rf-row" role="group" :aria-label="t('reporting.releases.area_label')" data-test="releases-areas">
      <button
        v-for="a in RELEASE_AREAS"
        :key="a"
        type="button"
        class="rf-pill rf-pill--code"
        :class="{ 'rf-pill--on': areas.includes(a) }"
        :aria-pressed="areas.includes(a) ? 'true' : 'false'"
        :data-test="'releases-area-' + a"
        @click="emit('update:areas', togglePill(RELEASE_AREAS, areas, a))"
      >{{ a }}</button>
    </div>
    <label class="rf-search">
      <span class="rf-search-label">{{ t('reporting.releases.search_label') }}</span>
      <input
        :value="text"
        type="search"
        maxlength="200"
        :placeholder="t('reporting.releases.search_placeholder')"
        data-test="releases-search"
        @input="onInput"
      >
    </label>
  </div>
</template>

<script setup lang="ts">
import { RELEASE_AREAS, RELEASE_KINDS, RELEASE_RANGES, RELEASE_SEARCH_DEBOUNCE_MS, togglePill } from '~/utils/reporting-releases'

const props = defineProps<{ range: string, kinds: string[], areas: string[], search: string }>()
const emit = defineEmits<{
  'update:range': [range: string]
  'update:kinds': [kinds: string[]]
  'update:areas': [areas: string[]]
  'update:search': [search: string]
}>()
const { t } = useI18n({ useScope: 'global' })

/* the box shows what was typed at once; the parent hears it once typing stops */
const text = ref(props.search)
watch(() => props.search, (v) => { if (v !== text.value) text.value = v })
let timer: ReturnType<typeof setTimeout> | null = null
function onInput(ev: Event) {
  text.value = (ev.target as HTMLInputElement).value
  if (timer) clearTimeout(timer)
  timer = setTimeout(() => {
    timer = null
    emit('update:search', text.value)
  }, RELEASE_SEARCH_DEBOUNCE_MS)
}
onBeforeUnmount(() => { if (timer) clearTimeout(timer) })
</script>

<style scoped>
.rf-bar { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.rf-row { display: flex; flex-wrap: wrap; gap: 6px; }
.rf-pill {
  border: 1px solid var(--color-border); border-radius: var(--radius-pill); background: var(--color-surface);
  color: var(--color-fg); padding: 2px 10px; font: inherit; font-size: 0.8125rem; cursor: pointer; min-height: 28px;
}
.rf-pill:hover { background: var(--color-surface-hover); }
.rf-pill--code { font-family: var(--font-mono, ui-monospace, monospace); }
.rf-pill--on { background: var(--color-accent); border-color: var(--color-accent); color: var(--color-on-accent); }
.rf-search { display: flex; align-items: center; gap: 8px; min-width: 0; }
.rf-search-label { font-size: 0.8125rem; color: var(--color-muted); }
.rf-search input { flex: 1 1 auto; min-width: 0; max-width: 420px; }
</style>
