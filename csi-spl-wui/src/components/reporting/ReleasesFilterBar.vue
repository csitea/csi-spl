<!-- Spec 143 2.2 T023 (SPL-2787): the Releases tab's filter bar. The range
     pills (Today, 7 days, 30 days, 90 days; one is always on), the kind and
     area pills (any number on; none = all), and the search box. The kind and
     area pills are a label cloud (spec 143 2.2.1, SPL-3796): with the counts
     of the range, each pill's size step grows with its commits, the most
     used in the centre; a click still toggles it as a filter. Each change
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
    <div class="rf-row rf-cloud" role="group" :aria-label="t('reporting.releases.kind_label')" data-test="releases-kinds">
      <button
        v-for="(c, i) in kindCloud"
        :key="c.id"
        type="button"
        class="rf-pill rf-pill--code"
        :class="['rf-step-' + c.step, 'rf-drift-' + (i % 3), { 'rf-pill--on': kinds.includes(c.id) }]"
        :aria-pressed="kinds.includes(c.id) ? 'true' : 'false'"
        :data-test="'releases-kind-' + c.id"
        :data-count="c.n"
        @click="emit('update:kinds', togglePill(RELEASE_KINDS, kinds, c.id))"
      >{{ c.id }}<span v-if="kindCounts" class="rf-n">{{ c.n }}</span></button>
    </div>
    <div class="rf-row rf-cloud" role="group" :aria-label="t('reporting.releases.area_label')" data-test="releases-areas">
      <button
        v-for="(c, i) in areaCloud"
        :key="c.id"
        type="button"
        class="rf-pill rf-pill--code"
        :class="['rf-step-' + c.step, 'rf-drift-' + (i % 3), { 'rf-pill--on': areas.includes(c.id) }]"
        :aria-pressed="areas.includes(c.id) ? 'true' : 'false'"
        :data-test="'releases-area-' + c.id"
        :data-count="c.n"
        @click="emit('update:areas', togglePill(RELEASE_AREAS, areas, c.id))"
      >{{ c.id }}<span v-if="areaCounts" class="rf-n">{{ c.n }}</span></button>
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
import { labelCloud, RELEASE_AREAS, RELEASE_KINDS, RELEASE_RANGES, RELEASE_SEARCH_DEBOUNCE_MS, togglePill } from '~/utils/reporting-releases'

const props = defineProps<{
  range: string, kinds: string[], areas: string[], search: string,
  kindCounts?: Record<string, number> | null, areaCounts?: Record<string, number> | null,
}>()
const emit = defineEmits<{
  'update:range': [range: string]
  'update:kinds': [kinds: string[]]
  'update:areas': [areas: string[]]
  'update:search': [search: string]
}>()
const { t } = useI18n({ useScope: 'global' })

/* before the first counts arrive, the pills keep their order at one middle step */
const plain = (all: readonly string[]) => all.map((id) => ({ id, n: 0, step: 2 }))
const kindCloud = computed(() => (props.kindCounts ? labelCloud(RELEASE_KINDS, props.kindCounts) : plain(RELEASE_KINDS)))
const areaCloud = computed(() => (props.areaCounts ? labelCloud(RELEASE_AREAS, props.areaCounts) : plain(RELEASE_AREAS)))

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
/* the label cloud: centred rows, size by class step (no :style, CSP), a small drift up or down */
.rf-cloud { justify-content: center; align-items: center; gap: 6px 10px; padding: 4px 0; }
.rf-cloud .rf-pill { display: inline-flex; align-items: baseline; gap: 4px; line-height: 1.2; }
.rf-n { font-size: 0.6875rem; opacity: 0.7; }
.rf-step-0 { font-size: 0.75rem; color: var(--color-muted); border-style: dashed; }
.rf-step-1 { font-size: 0.8125rem; }
.rf-step-2 { font-size: 0.9375rem; }
.rf-step-3 { font-size: 1.0625rem; padding: 3px 12px; }
.rf-step-4 { font-size: 1.25rem; padding: 4px 14px; }
.rf-step-5 { font-size: 1.5rem; padding: 5px 16px; font-weight: 600; }
.rf-drift-1 { position: relative; top: -5px; }
.rf-drift-2 { position: relative; top: 5px; }
.rf-pill--on, .rf-pill--on:hover { background: var(--color-accent); border-color: var(--color-accent); color: var(--color-on-accent); }
.rf-search { display: flex; align-items: center; gap: 8px; min-width: 0; }
.rf-search-label { font-size: 0.8125rem; color: var(--color-muted); }
.rf-search input { flex: 1 1 auto; min-width: 0; max-width: 420px; }
</style>
