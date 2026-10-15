<!-- Spec 123 5 (SPL-2056, owner 45f8cb69: "a pie chart, but a simple table"):
     the Costs tab's pie, inline SVG, no chart library. Imported ONLY by
     pages/monitoring/costs (defineAsyncComponent), so it is that route's
     own chunk (ci_costs_route_gzip_kb), never the shell's. The slices come
     from utils/tenant-costs.mjs costPieSlices; colours are fill attributes
     (CSP: no inline style). -->
<template>
  <figure class="costs-pie" data-test="costs-pie">
    <svg
      class="costs-pie-svg"
      viewBox="0 0 100 100"
      role="img"
      :aria-label="label"
      data-test="costs-pie-svg"
    >
      <path
        v-for="s in slices"
        :key="s.key"
        :d="s.d"
        :fill="s.color"
        class="costs-pie-slice"
        data-test="costs-pie-slice"
        :data-key="s.key"
        :data-pct="s.pct"
      ><title>{{ s.label }}: {{ s.pctText }}</title></path>
    </svg>
    <figcaption class="costs-pie-legend">
      <ul>
        <li v-for="s in slices" :key="s.key" data-test="costs-pie-legend-row">
          <svg class="costs-pie-swatch" viewBox="0 0 10 10" aria-hidden="true"><rect width="10" height="10" :fill="s.color" /></svg>
          <span class="costs-pie-name">{{ s.label }}</span>
          <span class="costs-pie-pct">{{ s.pctText }}</span>
        </li>
      </ul>
    </figcaption>
  </figure>
</template>

<script setup lang="ts">
defineProps<{
  label: string
  slices: { key: string, d: string, color: string, label: string, pctText: string, pct: number }[]
}>()
</script>

<style scoped>
.costs-pie { display: flex; flex-wrap: wrap; align-items: center; gap: 16px; margin: 0; }
.costs-pie-svg { width: 180px; height: 180px; flex: 0 0 auto; }
.costs-pie-slice { stroke: var(--color-bg); stroke-width: 0.6; }
.costs-pie-legend { flex: 1 1 200px; min-width: 0; }
.costs-pie-legend ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.costs-pie-legend li { display: flex; align-items: center; gap: 8px; min-width: 0; }
.costs-pie-swatch { width: 12px; height: 12px; flex: 0 0 auto; }
.costs-pie-name { flex: 1 1 auto; min-width: 0; overflow-wrap: anywhere; }
.costs-pie-pct { flex: 0 0 auto; font-variant-numeric: tabular-nums; }
</style>
