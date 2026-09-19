<template>
  <div
    class="pane-divider"
    :data-pane="pane"
    :data-dragging="dragging ? '1' : undefined"
    :data-testid="'pane-divider-' + pane"
    role="separator"
    aria-orientation="vertical"
    :aria-valuenow="Math.round(value)"
    :aria-valuemin="Math.round(min)"
    :aria-valuemax="Math.round(max)"
    :aria-label="pane === 'sidebar' ? 'Resize channel sidebar' : 'Resize thread pane'"
    title="Drag to resize. Double-click to reset."
    tabindex="0"
    @pointerdown="onDown"
    @pointermove="onMove"
    @pointerup="onUp"
    @pointercancel="onUp"
    @keydown="onKey"
    @dblclick.prevent="emit('reset')"
  ></div>
</template>

<script setup lang="ts">
import { applySeparatorKey, pointerDelta } from '~/utils/pane-widths.mjs'

const props = defineProps<{
  pane: 'sidebar' | 'thread'
  value: number
  min: number
  max: number
}>()

const emit = defineEmits<{
  input: [n: number]
  reset: []
}>()

const dragging = ref(false)
const startX = ref(0)
const startW = ref(0)

function onDown(e: PointerEvent) {
  if (e.button !== 0) return
  e.preventDefault()
  dragging.value = true
  startX.value = e.clientX
  startW.value = props.value
  ;(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId)
  document.documentElement.classList.add('pane-dragging')
}

function onMove(e: PointerEvent) {
  if (!dragging.value) return
  emit('input', pointerDelta(props.pane, startW.value, startX.value, e.clientX))
}

function onUp(e: PointerEvent) {
  if (!dragging.value) return
  dragging.value = false
  document.documentElement.classList.remove('pane-dragging')
  try {
    ;(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId)
  } catch {
    /* already released */
  }
}

function onKey(e: KeyboardEvent) {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return
  e.preventDefault()
  emit('input', applySeparatorKey(props.pane, e.key, props.value, props.min, props.max))
}
</script>
