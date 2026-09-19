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
    :aria-label="pane === 'sidebar' ? t('pane.resize_sidebar') : t('pane.resize_thread')"
    :title="t('pane.resize_hint')"
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

const { t } = useI18n({ useScope: 'global' })

const dragging = ref(false)
const moved = ref(false)
const startX = ref(0)
const startW = ref(0)

function onDown(e: PointerEvent) {
  if (e.button !== 0) return
  // Do not preventDefault here: a prevented pointerdown swallows dblclick,
  // which is the reset gesture. touch-action: none already stops scroll.
  dragging.value = true
  moved.value = false
  startX.value = e.clientX
  startW.value = props.value
  ;(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId)
}

function onMove(e: PointerEvent) {
  if (!dragging.value) return
  if (!moved.value && Math.abs(e.clientX - startX.value) < 3) return
  if (!moved.value) {
    moved.value = true
    document.documentElement.classList.add('pane-dragging')
  }
  emit('input', pointerDelta(props.pane, startW.value, startX.value, e.clientX))
}

const lastTapAt = ref(0)

function onUp(e: PointerEvent) {
  if (!dragging.value) return
  const wasMove = moved.value
  dragging.value = false
  document.documentElement.classList.remove('pane-dragging')
  try {
    ;(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId)
  } catch {
    /* already released */
  }
  // Two taps without a drag = reset. Native dblclick is also wired; some
  // drivers (headless Chrome clickCount:2) never fire it after pointer capture.
  if (wasMove) {
    lastTapAt.value = 0
    return
  }
  const now = typeof performance !== 'undefined' ? performance.now() : Date.now()
  if (now - lastTapAt.value < 400) {
    lastTapAt.value = 0
    emit('reset')
    return
  }
  lastTapAt.value = now
}

function onKey(e: KeyboardEvent) {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return
  e.preventDefault()
  emit('input', applySeparatorKey(props.pane, e.key, props.value, props.min, props.max))
}
</script>
