<!-- Spec 112 WUI-1 (5, 9): the roadmap's spec rows, one per spec dir, as
     roadmap.json carries them (do_spl_spec_progress, 5.1). Columns: id,
     title, state, the [x] / [~] / [ ] counts, pct and the last commit day of
     its tasks.md. Spec titles are repo content, shown as authored. At
     <= 820 px (the spec 106 breakpoint) each row is a card, its label beside
     each value. The goal rows and the goals a spec serves are WUI-3's, in
     their own files. Loaded by pages/roadmap.vue as its own chunk. -->
<template>
  <table class="roadmap-table" data-test="roadmap-spec-table">
    <thead>
      <tr>
        <th scope="col">{{ t('roadmap.col_id') }}</th>
        <th scope="col">{{ t('roadmap.col_title') }}</th>
        <th scope="col">{{ t('roadmap.col_state') }}</th>
        <th scope="col" :title="t('roadmap.col_counts_hint')">{{ t('roadmap.col_counts') }}</th>
        <th scope="col">{{ t('roadmap.col_pct') }}</th>
        <th scope="col">{{ t('roadmap.col_changed') }}</th>
      </tr>
    </thead>
    <tbody>
      <tr
        v-for="s in rows"
        :id="roadmapAnchor(s.id)"
        :key="s.id"
        data-test="roadmap-spec-row"
        :data-spec="s.id"
        :data-state="s.state"
        :class="{ 'roadmap-row--focus': focus === roadmapAnchor(s.id) }"
      >
        <td :data-label="t('roadmap.col_id')"><code dir="ltr">{{ s.id.slice(0, 3) }}</code></td>
        <td :data-label="t('roadmap.col_title')" class="roadmap-title" data-test="roadmap-spec-title">{{ s.title || s.id }}</td>
        <td :data-label="t('roadmap.col_state')">
          <span class="roadmap-state" :class="`roadmap-state--${s.state}`" data-test="roadmap-spec-state">{{ t(`roadmap.state.${s.state.replace(/-/g, '_')}`) }}</span>
        </td>
        <td :data-label="t('roadmap.col_counts')" dir="ltr" class="roadmap-num" data-test="roadmap-spec-counts">
          <template v-if="s.state !== 'no-tasks'">{{ s.x }} / {{ s.p }} / {{ s.o }}</template>
        </td>
        <td :data-label="t('roadmap.col_pct')" class="roadmap-num">
          <span v-if="typeof s.pct === 'number'" class="roadmap-pct" data-test="roadmap-spec-pct">
            <span class="roadmap-pct__bar" aria-hidden="true"><span :style="{ width: `${s.pct}%` }" /></span>
            <span dir="ltr">{{ s.pct }}%</span>
          </span>
        </td>
        <td :data-label="t('roadmap.col_changed')" dir="ltr">
          <time v-if="s.tasks_changed" :datetime="s.tasks_changed" data-test="roadmap-spec-changed">{{ dayOf(s.tasks_changed) }}</time>
        </td>
      </tr>
    </tbody>
  </table>
</template>

<script setup lang="ts">
import { isoDate } from '~/utils/date-iso.mjs'
import { roadmapAnchor } from '~/utils/roadmap-rows.mjs'

export interface RoadmapSpec {
  id: string
  title: string
  state: string
  x: number
  p: number
  o: number
  pct: number | null
  tasks_changed: string
}

defineProps<{ rows: RoadmapSpec[], focus?: string }>()

const { t } = useI18n({ useScope: 'global' })
const dayOf = (iso: string) => isoDate(iso) || iso
</script>

<style scoped>
.roadmap-table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.875rem;
}
.roadmap-table th,
.roadmap-table td {
  text-align: start;
  padding: 0.4rem 0.6rem;
  border-bottom: 1px solid var(--color-border);
  overflow-wrap: anywhere;
  vertical-align: top;
}
.roadmap-table th {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.roadmap-table code {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
}
.roadmap-row--focus { background: var(--color-selected); }
.roadmap-num { white-space: nowrap; }
.roadmap-state {
  display: inline-block;
  padding: 0 0.4rem;
  border-radius: var(--radius-pill);
  border: 1px solid var(--color-border);
  font-size: 0.75rem;
  white-space: nowrap;
  justify-self: start;
}
.roadmap-state--done { color: var(--color-ok); border-color: currentColor; }
.roadmap-state--in-progress { color: var(--color-accent); border-color: currentColor; }
.roadmap-state--planned { color: var(--color-warn); border-color: currentColor; }
.roadmap-state--no-boxes,
.roadmap-state--no-tasks { color: var(--color-muted); }
.roadmap-pct {
  display: inline-flex;
  justify-self: start;
  align-items: center;
  gap: 0.4rem;
}
.roadmap-pct__bar {
  display: inline-block;
  width: 4rem;
  height: 0.4rem;
  border-radius: var(--radius-pill);
  background: var(--color-border);
  overflow: hidden;
}
.roadmap-pct__bar > span {
  display: block;
  height: 100%;
  background: var(--color-accent);
}
/* spec 112 9: at <= 820 px (spec 106) each row is a card; the column
   headers stay in the DOM for readers, visually hidden */
@media (max-width: 820px) {
  .roadmap-table,
  .roadmap-table tbody,
  .roadmap-table tr,
  .roadmap-table td { display: block; }
  .roadmap-table thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
  .roadmap-table tr {
    padding: 0.5rem 0.75rem;
    margin-bottom: 0.5rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
  }
  .roadmap-table td {
    display: grid;
    grid-template-columns: 6.5rem minmax(0, 1fr);
    gap: 0.5rem;
    padding: 0.2rem 0;
    border-bottom: 0;
  }
  .roadmap-table td::before {
    content: attr(data-label);
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
}
</style>
