<!-- SPL-2048: Inline-SVG pie chart for Monitoring -> Costs.
     Groups parts ≤ 1% into "other". -->
<template>
  <div class="costs-pie-chart" data-test="costs-pie-chart">
    <svg :width="size" :height="size" viewBox="0 0 100 100" class="costs-pie-svg">
      <g transform="translate(50, 50)">
        <path
          v-for="(slice, index) in slices"
          :key="index"
          :d="slice.path"
          :fill="slice.color"
          @mouseover="hoveredSlice = slice"
          @mouseout="hoveredSlice = null"
        />
        <text
          v-if="slices.length === 0"
          x="0"
          y="0"
          text-anchor="middle"
          dominant-baseline="middle"
          class="costs-pie-empty"
        >
          {{ t('monitoring.costs.pie.no_data') }}
        </text>
      </g>
      <g v-if="slices.length > 0" transform="translate(100, 20)">
        <text
          v-for="(slice, index) in slices"
          :key="'label-' + index"
          :y="index * 20"
          text-anchor="start"
          class="costs-pie-label"
        >
          <tspan :fill="slice.color">●</tspan>
          {{ slice.label }} ({{ slice.percentage }}%)
        </text>
      </g>
    </svg>
    <div v-if="hoveredSlice" class="costs-pie-tooltip">
      {{ hoveredSlice.label }}: {{ hoveredSlice.percentage }}%
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { useI18n } from 'vue-i18n'

const { t } = useI18n({ useScope: 'global' })

const props = defineProps<{
  parts: Array<{
    source: string
    project_or_vendor: string
    kind: string
    usd_micros: number
    pct: number
  }>
}>()

const size = 200
const hoveredSlice = ref<any>(null)

// Colors for slices
const colors = [
  '#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f',
  '#edc948', '#b07aa1', '#ff9da7', '#9c755f', '#bab0ac'
]

// Group parts ≤ 1% into "other"
const slices = computed(() => {
  if (!props.parts || props.parts.length === 0) return []
  
  const total = props.parts.reduce((sum, part) => sum + part.pct, 0)
  const filtered = props.parts.filter(part => part.pct > 1)
  const otherPct = total - filtered.reduce((sum, part) => sum + part.pct, 0)
  
  const slices = filtered.map((part, index) => ({
    label: `${part.source}: ${part.project_or_vendor} (${part.kind})`,
    percentage: Math.round(part.pct),
    value: part.pct,
    color: colors[index % colors.length]
  }))
  
  if (otherPct > 0) {
    slices.push({
      label: t('monitoring.costs.pie.other'),
      percentage: Math.round(otherPct),
      value: otherPct,
      color: '#ccc'
    })
  }
  
  // Calculate paths
  let startAngle = 0
  return slices.map(slice => {
    const angle = (slice.value / 100) * 360
    const endAngle = startAngle + angle
    const largeArc = angle > 180 ? 1 : 0
    
    const x1 = 40 * Math.cos((startAngle * Math.PI) / 180)
    const y1 = 40 * Math.sin((startAngle * Math.PI) / 180)
    const x2 = 40 * Math.cos((endAngle * Math.PI) / 180)
    const y2 = 40 * Math.sin((endAngle * Math.PI) / 180)
    
    const path = `
      M 0 0
      L ${x1} ${y1}
      A 40 40 0 ${largeArc} 1 ${x2} ${y2}
      Z
    `
    
    startAngle = endAngle
    return { ...slice, path }
  })
})
</script>

<style scoped>
.costs-pie-chart {
  display: flex;
  align-items: center;
  gap: 2rem;
}

.costs-pie-svg {
  max-width: 100%;
  height: auto;
}

.costs-pie-label {
  font-size: 0.875rem;
  white-space: nowrap;
}

.costs-pie-empty {
  font-size: 0.875rem;
  fill: #666;
}

.costs-pie-tooltip {
  position: absolute;
  background: rgba(0, 0, 0, 0.8);
  color: white;
  padding: 0.5rem;
  border-radius: 4px;
  font-size: 0.875rem;
  pointer-events: none;
}
</style>
