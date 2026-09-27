<!-- SPL-991: the dimmed page behind a bottom sheet on a phone. A tap on it
     closes the sheet and reaches nothing underneath (the click would
     otherwise open whatever card sits under the finger). The sheet rule
     itself (`.touch-sheet`) lives here, unscoped, so MessageMenu,
     EmojiPicker and KindPicker share one look. -->
<template>
  <div
    class="touch-sheet-backdrop"
    data-testid="sheet-backdrop"
    aria-hidden="true"
    @pointerdown.stop.prevent="armed = true"
    @click.stop.prevent="onClick"
    @contextmenu.prevent
  />
</template>

<script setup lang="ts">
const emit = defineEmits<{ close: [] }>()
/* Only a tap that STARTED on the backdrop closes. The finger that long-pressed
   a card lifts over the backdrop that just appeared, and the browser sends
   that lift's click here - measured: the sheet opened, then closed on lift. */
const armed = ref(false)
function onClick() {
  if (!armed.value) return
  armed.value = false
  emit('close')
}
</script>

<style>
.touch-sheet-backdrop {
  position: fixed;
  inset: 0;
  z-index: var(--z-overlay);
  background: rgb(0 0 0 / .45);
  touch-action: none;
}
/* :root + doubled class (0,3,0): beats each panel's own scoped popover rule
   (.msg-menu[data-v] = 0,2,0) whatever order the chunks load in */
:root .touch-sheet.touch-sheet {
  position: fixed;
  top: auto;
  left: 0;
  right: 0;
  bottom: var(--kb-inset, 0px);
  visibility: visible;
  z-index: calc(var(--z-overlay) + 1);
  width: 100%;
  min-width: 0;
  max-width: none;
  max-height: min(70dvh, calc(100dvh - var(--kb-inset, 0px) - 48px));
  box-sizing: border-box;
  overflow-y: auto;
  overscroll-behavior: contain;
  border-radius: var(--radius-lg) var(--radius-lg) 0 0;
  border-bottom: 0;
  padding: 8px 8px calc(8px + env(safe-area-inset-bottom, 0px));
  animation: touch-sheet-up .18s ease-out;
}
/* the grab handle: says "this is a sheet" */
:root .touch-sheet.touch-sheet::before {
  content: "";
  display: block;
  width: 36px;
  height: 4px;
  margin: 0 auto 8px;
  border-radius: var(--radius-pill);
  background: var(--color-border-strong, var(--color-border));
}
:root .touch-sheet.touch-sheet [role="menuitem"],
:root .touch-sheet.touch-sheet [role="menuitemradio"] {
  min-height: var(--tap);
  font-size: 1rem;
}
@keyframes touch-sheet-up {
  from { transform: translateY(24px); opacity: .6; }
  to { transform: none; opacity: 1; }
}
@media (prefers-reduced-motion: reduce) {
  :root .touch-sheet.touch-sheet { animation: none; }
}
</style>
