<!-- Shared icon (ported from the donor WUI's UiIcon.vue, stroke glyphs only).
     lucide-style 24×24 currentColor stroke, path-only so SSR output is plain
     markup. Decorative — the OWNING button carries :title + :aria-label. -->
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
import { computed } from "vue"

import { UI_ICON_PATHS, type UiIconName, type UiIconPath } from "@/utils/uiIcons"

const props = withDefaults(
  defineProps<{
    name: UiIconName
    size?: number | string
    strokeWidth?: number | string
  }>(),
  { size: 20, strokeWidth: 2 },
)

function resolvePath(p: UiIconPath): { d: string; fill: string; stroke: string } {
  if (typeof p === "string") {
    return { d: p, fill: "none", stroke: "currentColor" }
  }
  return { d: p.d, fill: "currentColor", stroke: "none" }
}

const paths = computed(() => {
  const raw = UI_ICON_PATHS[props.name] as readonly UiIconPath[] | undefined
  return (raw ?? []).map(resolvePath)
})
</script>

<style scoped>
.ui-icon {
  display: block;
  flex: none;
}
</style>
