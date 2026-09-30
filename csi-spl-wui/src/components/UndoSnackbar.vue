<!-- SPL-1264 (CLE-77809): the one snackbar the app shows at the bottom centre
     after a reversible action - "<what> · Undo". It grew out of the move /
     merge undo toast (714c7028); MoveUndoToast and ArchiveUndoToast are thin
     adapters that feed it their text, their Undo target and their own testid.

     `duration` is the auto-dismiss window in ms. When it is > 0 the snackbar
     dismisses itself after that long, but it HOLDS while the pointer is over it
     or focus is inside it, so a slow click on Undo still lands (owner asked for
     a very short 0.7 s; the hold is what keeps that usable). `duration` 0 (the
     default) hands timing to the caller - move keeps its own 8 s timer. -->
<template>
  <div
    class="undo-snackbar"
    role="status"
    aria-live="polite"
    :data-testid="testid"
    :data-id="dataId === undefined ? undefined : String(dataId)"
    @mouseenter="hold"
    @mouseleave="release"
    @focusin="hold"
    @focusout="release"
    @keydown.esc.stop.prevent="emit('dismiss')"
  >
    <UiIcon v-if="icon" class="undo-snackbar__icon" :name="icon" :size="18" />
    <p class="undo-snackbar__text" :data-testid="`${testid}-text`">{{ text }}</p>
    <button
      v-if="showUndo"
      type="button"
      class="btn ghost undo-snackbar__undo"
      :data-testid="`${testid}-undo`"
      :disabled="busy"
      @click="emit('undo')"
    >{{ undoLabel }}</button>
    <button
      type="button"
      class="icon-btn undo-snackbar__close"
      :data-testid="`${testid}-close`"
      :aria-label="closeLabel"
      :title="closeLabel"
      @click="emit('dismiss')"
    >
      <UiIcon name="x" :size="16" />
    </button>
  </div>
</template>

<script setup lang="ts">
import type { UiIconName } from '~/utils/uiIcons'

const props = withDefaults(defineProps<{
  text: string
  closeLabel: string
  undoLabel?: string
  showUndo?: boolean
  busy?: boolean
  icon?: UiIconName
  testid?: string
  dataId?: string | number
  duration?: number
}>(), { testid: 'undo-snackbar', showUndo: true, busy: false, duration: 0 })

const emit = defineEmits<{ undo: [], dismiss: [] }>()

let timer: ReturnType<typeof setTimeout> | null = null
function clear() { if (timer) { clearTimeout(timer); timer = null } }
/* full window on each (re)arm: 0.7 s is short, so restarting after a hover
   leave is friendlier than resuming a few ms that were left. */
function arm() { clear(); if (props.duration && props.duration > 0) timer = setTimeout(() => emit('dismiss'), props.duration) }
function hold() { clear() }
function release() { arm() }

onMounted(arm)
onBeforeUnmount(clear)
</script>

<style scoped>
.undo-snackbar {
  position: fixed;
  left: 50%;
  bottom: 1rem;
  transform: translateX(-50%);
  z-index: var(--z-snackbar);
  display: flex;
  align-items: center;
  gap: 0.5rem;
  width: max-content;
  max-width: calc(100vw - 2rem);
  padding: 0.5rem 0.5rem 0.5rem 0.75rem;
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-sm);
  background: var(--color-bg-2, var(--color-surface));
  color: var(--color-fg);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
}
.undo-snackbar__icon { flex: none; color: var(--color-accent); }
.undo-snackbar__text {
  margin: 0;
  min-width: 0;
  font-size: 0.875rem;
  overflow-wrap: anywhere;
}
.undo-snackbar__undo { flex: none; font-weight: 600; color: var(--color-accent); }
.undo-snackbar__close { flex: none; }
</style>
