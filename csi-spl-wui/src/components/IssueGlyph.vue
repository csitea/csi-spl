<template>
  <svg
    class="ui-icon"
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    :stroke-width="strokeWidth"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
    focusable="false"
    :data-icon="name"
  >
    <path
      v-for="(p, i) in paths"
      :key="i"
      :d="p.d"
      :fill="p.fill"
      :stroke="p.stroke"
    />
  </svg>
</template>

<script setup lang="ts">
import { computed } from 'vue'

type Path = string | { d: string, fill?: boolean }

const PATHS: Record<string, Path[]> = {
  "status-backlog": [
    "M12 4.2a3 3 0 0 1 2.6 1.5",
    "M18.5 9.2a7 7 0 0 1-.2 3.2",
    "M16.2 16.8a7 7 0 0 1-3.2 1.6",
    "M8.2 17.2a7 7 0 0 1-3.4-2.6",
    "M4.6 10.4a7 7 0 0 1 1.4-3.6",
  ],
  "status-todo": ["M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z"],
  "status-progress": [
    "M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z",
    { d: "M12 4a8 8 0 0 1 0 16z", fill: true },
  ],
  "status-review": [
    "M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z",
    "M8.2 12.2 10.6 14.6 15.8 9.4",
  ],
  "status-done": [
    "M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z",
    "M8 12.2 10.8 15 16.2 9.2",
  ],
  "status-canceled": [
    "M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z",
    "M9 9 15 15",
    "M15 9 9 15",
  ],
  "priority-none": ["M5 18h3", "M11 18h3", "M17 18h3"],
  "priority-low": ["M6 14v6"],
  "priority-medium": ["M6 14v6", "M12 10v10"],
  "priority-high": ["M6 14v6", "M12 10v10", "M18 6v14"],
  "priority-urgent": [
    "M5 15v5",
    "M10 11v9",
    "M15 7v13",
    "M19 4v7",
    { d: "M19 15.2a1.2 1.2 0 1 1 0 2.4 1.2 1.2 0 1 1 0-2.4z", fill: true },
  ]
}

const props = withDefaults(defineProps<{
  name: string
  size?: number | string
  strokeWidth?: number | string
}>(), { size: 16, strokeWidth: 2 })

const paths = computed(() => {
  const raw = PATHS[props.name] || []
  return raw.map((p) => typeof p === 'string'
    ? { d: p, fill: 'none', stroke: 'currentColor' }
    : { d: p.d, fill: 'currentColor', stroke: 'none' })
})
</script>

<style scoped>
.ui-icon { display: block; flex: none; }
</style>
