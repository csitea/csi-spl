<!-- SPL-1264 (CLE-77809): the one snackbar the app shows at the bottom centre
     after a reversible action - "<what> · Undo". It grew out of the move /
     merge undo toast (714c7028); MoveUndoToast and ArchiveUndoToast are thin
     adapters that feed it their text, their Undo target and their own testid.

     `duration` is the auto-dismiss window in ms. When it is > 0 the snackbar
     dismisses itself after that long, but it HOLDS while the pointer is over it
     or focus is inside it, so a slow click on Undo still lands (owner asked for
     a very short 0.7 s; the hold is what keeps that usable). `duration` 0 (the
     default) hands timing to the caller.

     CLE-77871 (owner, topic f20c6052: "the snack bar should work on mobile as
     well"): a phone has no hover, so 0.7 s was gone before a thumb reached
     Undo. On a touch UI the window is at least UNDO_TOUCH_MIN_MS and holds
     while a finger is on it (utils/undo-timer.mjs); hover is a MOUSE pointer
     only (a tap's emulated mouseenter would hold it forever). On a phone it
     sits above the composer dock, the keyboard and the safe-area inset, and
     Undo / close are 44 px targets. Move now passes its 8 s here too.

     Owner, t1 topic e3e9ca61 (on a phone): "the position of the snack bar on
     mobile should not be at the bottom but it should be on the top", and
     "whenever I click somewhere else, the snack bar ... should disappear".
     On a phone or touch UI it sits at the TOP, under the safe-area inset
     (never over the composer dock), and a tap anywhere outside it dismisses
     it (utils/outside-tap.mjs). The desktop keeps the bottom centre. -->
<template>
  <div
    ref="rootEl"
    class="undo-snackbar"
    role="status"
    aria-live="polite"
    aria-atomic="true"
    :data-testid="testid"
    :data-id="dataId === undefined ? undefined : String(dataId)"
    @pointerenter="onPointerEnter"
    @pointerleave="onPointerLeave"
    @pointerdown="onPointerDown"
    @pointerup="onPointerUp"
    @pointercancel="onPointerUp"
    @focusin="clock.hold('focus')"
    @focusout="clock.release('focus')"
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
import { createUndoTimer, isTouchUi } from '~/utils/undo-timer.mjs'
import { isPhoneOrTouch, onOutsideTap } from '~/utils/outside-tap.mjs'

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

/* full window on each (re)arm: 0.7 s is short, so restarting after a hover
   leave is friendlier than resuming a few ms that were left. The touch read
   happens on mount (client only: the shell mounts this in <ClientOnly>). */
const clock = createUndoTimer({
  duration: props.duration,
  undo: props.showUndo,
  touch: isTouchUi(),
  onExpire: () => emit('dismiss'),
})
const isMouse = (ev: PointerEvent) => ev.pointerType === 'mouse'
function onPointerEnter(ev: PointerEvent) { if (isMouse(ev)) clock.hold('hover') }
function onPointerLeave(ev: PointerEvent) { if (isMouse(ev)) clock.release('hover') }
function onPointerDown(ev: PointerEvent) {
  if (isMouse(ev)) return
  clock.touched()
  clock.hold('touch')
}
function onPointerUp(ev: PointerEvent) { if (!isMouse(ev)) clock.release('touch') }

/* e3e9ca61: on a phone a tap outside closes it; never a trap */
const rootEl = ref<HTMLElement | null>(null)
let offOutside: (() => void) | null = null

onMounted(() => {
  clock.arm()
  if (isPhoneOrTouch()) offOutside = onOutsideTap(document, () => [rootEl.value], () => emit('dismiss'))
})
onBeforeUnmount(() => {
  clock.stop()
  offOutside?.()
})
</script>

<style scoped>
.undo-snackbar {
  position: fixed;
  left: 50%;
  /* CLE-77871: above the phone's composer dock + keyboard (0 on a desktop)
     and the home-indicator inset */
  bottom: calc(1rem + max(calc(var(--composer-dock-h, 0px) + var(--kb-inset, 0px)), env(safe-area-inset-bottom, 0px)));
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
/* CLE-77871: a thumb, not a cursor - 44 px targets (--tap) */
@media (max-width: 820px), (pointer: coarse) {
  /* e3e9ca61: at the TOP on a phone, under the notch / status bar */
  .undo-snackbar {
    top: calc(0.5rem + env(safe-area-inset-top, 0px));
    bottom: auto;
    gap: 0.25rem;
    padding-block: 0.25rem;
  }
  .undo-snackbar__undo,
  .undo-snackbar__close { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
