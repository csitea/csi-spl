<!-- The WUI's ONE modal dialog (013 FR-017).

     Generic on purpose. It owns the behaviour every modal has to get right —
     focus trap, Escape, backdrop click, restored focus, a scrollable body
     that never makes the PAGE scroll, `aria-modal` and a labelled title — and
     it owns no content at all. A content type is whatever is put in the
     default slot; `CodeViewer.vue` is the first, and a file preview later is
     another component in the same slot, with no change here. That is the
     extension point: adding a type must not mean touching the dialog.

     It is deliberately not @headlessui/vue's Dialog (which IS a dependency
     already): that one renders its own overlay markup and its own transition
     stack, and the three things we actually need here are 40 lines. Keeping
     them here keeps the CSP surface (no injected styles) and the token theme
     ours.

     SSR: the panel is teleported to <body> so an ancestor's `overflow` or
     `transform` cannot clip it, and the Teleport is mounted only on the
     client — during SSR the dialog is closed, so there is nothing to render
     and no teleport target to miss. -->
<template>
  <Teleport v-if="mounted" to="body">
    <!-- SPL-1150: only the `card` size fades and scales in and out. Every
         other size is `:css="false"` with no JS hooks, so Vue inserts and
         removes it synchronously, exactly as before the Transition existed
         (a CSS-less NAME would still wait ~2 frames to find no transition,
         and a confirm read right after Delete saw it still there). -->
    <Transition name="ui-dialog-pop" :css="size === 'card'" appear>
    <div
      v-if="open"
      class="ui-dialog-backdrop"
      data-testid="ui-dialog-backdrop"
      @mousedown.self="onBackdrop"
    >
      <div
        ref="panelEl"
        class="ui-dialog"
        :class="[size, { routed }]"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="titleId"
        data-testid="ui-dialog"
        tabindex="-1"
        @keydown="onKeydown"
      >
        <header class="ui-dialog__head">
          <!-- SPL-993: on a phone the dialog is a full screen with a top bar,
               and Back (start edge) closes it; the X is the desktop's. -->
          <button
            type="button"
            class="ui-dialog__back"
            data-testid="ui-dialog-back"
            :title="t('common.close')"
            :aria-label="t('common.close')"
            @click="close"
          >
            <UiIcon name="chevron-left" :size="22" />
          </button>
          <!-- SPL-1133: the X at the chosen corner (Mac = start, the default;
               Windows = end), one shared UiCloseButton; on a phone it hides
               in both modes and Back keeps the start edge -->
          <UiCloseButton side="start" class="ui-dialog__close" data-testid="ui-dialog-close" @click="close" />
          <h2 :id="titleId" class="ui-dialog__title">{{ title }}</h2>
          <div class="ui-dialog__tools"><slot name="tools" /></div>
          <UiCloseButton side="end" class="ui-dialog__close" data-testid="ui-dialog-close" @click="close" />
        </header>
        <div class="ui-dialog__body" data-testid="ui-dialog-body">
          <slot />
        </div>
        <footer v-if="$slots.footer" class="ui-dialog__foot">
          <slot name="footer" />
        </footer>
      </div>
    </div>
    </Transition>
  </Teleport>
</template>

<script setup lang="ts">
const props = withDefaults(
  defineProps<{
    open: boolean
    title: string
    /** `lg` fills most of the viewport (source); `xl` is 90% of it both ways (a picture); `md` is a plain dialog; `sm` is a confirm (UiConfirm, SPL-1001); `card` is a compact, centred card that fades in (the logo, SPL-1150). */
    size?: 'sm' | 'md' | 'lg' | 'xl' | 'card'
    /** CLE-77853: `open` IS the route (Settings, ?settings=): browser Back is the router's, so no overlay history entry of its own, and on a phone it keeps its X instead of the Back chevron. */
    routed?: boolean
  }>(),
  { size: 'lg', routed: false },
)
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n({ useScope: 'global' })

const titleId = useId()
const panelEl = ref<HTMLElement | null>(null)
const mounted = ref(false)
let returnFocusTo: HTMLElement | null = null

onMounted(() => {
  mounted.value = true
  if (props.open) void onOpenChange(true)
})

function close() {
  emit('update:open', false)
}

/* SPL-994: on a phone an open dialog is the top level - browser Back / the
   Android gesture closes it, and the page and level under it stay put */
useMobileStack().overlay(() => props.open, close, { history: !props.routed })

function onBackdrop() {
  close()
}

/** Every element inside the panel a Tab can reach, in document order. */
function focusables(): HTMLElement[] {
  const root = panelEl.value
  if (!root) return []
  const sel = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'
  return [...root.querySelectorAll<HTMLElement>(sel)].filter((el) => el.offsetParent !== null || el === document.activeElement)
}

/* SPL-1234: Escape must close the dialog even when focus is NOT inside the
   panel. onKeydown below is bound to the panel, so it only fires while focus is
   trapped inside it; the owner saw Escape do nothing (the X still worked)
   because focus had left the panel (teleport / async-load timing on open). A
   window listener, live only while open, closes on Escape unless a child
   already handled it: an open @headlessui combobox dropdown swallows its own
   Escape (stopPropagation, so this never sees it), and any child that only
   preventDefaults is respected via ev.defaultPrevented. When focus IS in the
   panel, onKeydown's stopPropagation keeps this from firing too. */
function onWindowKeydown(ev: KeyboardEvent) {
  // Not while an IME composition is being cancelled by Escape, and not when a
  // child (an open dropdown inside) already handled it (headlessui stops
  // propagation so this never sees it; a preventDefault-only child is honoured).
  if (ev.key !== 'Escape' || ev.defaultPrevented || ev.isComposing || !props.open) return
  // Topmost only: every backdrop is teleported to <body>, so the last one in
  // document order is the one on top; a dialog under it must ignore Escape.
  const backdrops = [...document.querySelectorAll('.ui-dialog-backdrop')]
  if (backdrops.length > 1 && backdrops[backdrops.length - 1] !== panelEl.value?.parentElement) return
  ev.preventDefault()
  close()
}

function onKeydown(ev: KeyboardEvent) {
  if (ev.key === 'Escape') {
    ev.preventDefault()
    ev.stopPropagation()
    close()
    return
  }
  if (ev.key !== 'Tab') return
  // the trap: Tab off either end comes back round, so focus can never reach
  // the page behind the backdrop while the dialog is up
  const items = focusables()
  if (items.length === 0) {
    ev.preventDefault()
    panelEl.value?.focus()
    return
  }
  const first = items[0]
  const last = items[items.length - 1]
  const active = document.activeElement as HTMLElement | null
  if (!ev.shiftKey && (active === last || !panelEl.value?.contains(active))) {
    ev.preventDefault()
    first.focus()
  } else if (ev.shiftKey && (active === first || !panelEl.value?.contains(active))) {
    ev.preventDefault()
    last.focus()
  }
}

/* SPL-1001: also on MOUNT when it is already open. Every Lazy<X> confirm is
   mounted by the v-if that opens it, so `open` never CHANGES under a watch
   that is not immediate: no focus (Cancel), no Escape, no scroll lock. */
async function onOpenChange(isOpen: boolean) {
  if (!import.meta.client) return
  if (isOpen) {
    returnFocusTo = document.activeElement as HTMLElement | null
    // SPL-1234: Escape closes wherever focus is (see onWindowKeydown)
    window.addEventListener('keydown', onWindowKeydown)
    // the page must not scroll behind an open dialog (no-x-scroll invariant
    // included: the body keeps its width, only its scrolling stops)
    document.documentElement.style.overflow = 'hidden'
    await nextTick()
    const items = focusables()
    /* Opening a dialog puts focus where the person is meant to WORK. Without
       a nominated target that is items[0], which is the header's Close
       button - fine for a viewer, wrong for a form, where it means the first
       keystroke goes nowhere. Content marks its own field with
       `data-autofocus`; anything without one keeps the old behaviour. */
    const first = items.find((el) => el.hasAttribute('data-autofocus')) ?? items[0]
    ;(first ?? panelEl.value)?.focus()
  } else {
    window.removeEventListener('keydown', onWindowKeydown)
    document.documentElement.style.overflow = ''
    returnFocusTo?.focus?.()
    returnFocusTo = null
  }
}

watch(() => props.open, (isOpen) => { void onOpenChange(isOpen) })

onUnmounted(() => {
  if (!import.meta.client) return
  window.removeEventListener('keydown', onWindowKeydown)
  document.documentElement.style.overflow = ''
  /* a Lazy<X> dialog is unmounted by the same v-if that closes it */
  returnFocusTo?.focus?.()
  returnFocusTo = null
})
</script>

<style scoped>
.ui-dialog-backdrop {
  position: fixed;
  inset: 0;
  z-index: var(--z-modal);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  background: rgb(0 0 0 / 0.55);
  overflow: hidden;
}
.ui-dialog {
  display: flex;
  flex-direction: column;
  width: 100%;
  min-width: 0;
  max-height: 100%;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  box-shadow: 0 16px 48px rgb(0 0 0 / 0.45);
  overflow: hidden;
}
.ui-dialog.md { max-width: 560px; }
/* SPL-1001: a confirm is one surface with the same 24 px inset round the
   title, the sentence and the buttons - no header strip, no footer rule. */
.ui-dialog.sm { max-width: 480px; }
.ui-dialog.sm .ui-dialog__head {
  padding: 16px 12px 8px 24px;
  border-bottom: 0;
  background: transparent;
}
.ui-dialog.sm .ui-dialog__title { font-size: 1.0625rem; line-height: 1.4; }
.ui-dialog.sm .ui-dialog__foot {
  padding: 16px 24px 24px;
  border-top: 0;
  background: transparent;
}
.ui-dialog.lg { max-width: 1100px; height: 100%; }
/* SPL-1150: a compact card - soft radius, a soft two-layer shadow, no
   header strip; its height is its content's */
.ui-dialog.card {
  max-width: 720px;
  border-color: var(--color-border);
  border-radius: var(--radius-lg);
  box-shadow: 0 24px 64px rgb(0 0 0 / 0.32), 0 2px 8px rgb(0 0 0 / 0.16);
}
/* above a phone; at <= 600 px the card is a full screen with its top bar */
@media (min-width: 601px) {
  .ui-dialog.card .ui-dialog__head {
    border-bottom: 0;
    background: transparent;
    padding-block: 10px 0;
  }
  .ui-dialog.card .ui-dialog__title {
    font-size: 0.8125rem;
    font-weight: 600;
    letter-spacing: 0.02em;
    color: var(--color-muted);
  }
}
.ui-dialog-pop-enter-active,
.ui-dialog-pop-leave-active { transition: opacity 160ms ease-out; }
.ui-dialog-pop-enter-active .ui-dialog,
.ui-dialog-pop-leave-active .ui-dialog { transition: transform 180ms cubic-bezier(0.2, 0.8, 0.2, 1), opacity 160ms ease-out; }
.ui-dialog-pop-enter-from,
.ui-dialog-pop-leave-to { opacity: 0; }
.ui-dialog-pop-enter-from .ui-dialog,
.ui-dialog-pop-leave-to .ui-dialog { opacity: 0; transform: translateY(6px) scale(0.96); }
@media (prefers-reduced-motion: reduce) {
  .ui-dialog-pop-enter-active,
  .ui-dialog-pop-leave-active,
  .ui-dialog-pop-enter-active .ui-dialog,
  .ui-dialog-pop-leave-active .ui-dialog { transition: none; }
}
.ui-dialog.xl { width: 90vw; max-width: 90vw; height: 90vh; max-height: 90vh; }
.ui-dialog:focus-visible { outline: 2px solid var(--color-accent); outline-offset: -2px; }
.ui-dialog__head {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  padding: 8px 8px 8px 14px;
  border-bottom: 1px solid var(--color-border);
  background: var(--color-bg-2);
  min-width: 0;
}
.ui-dialog__title {
  margin: 0;
  font-size: 0.875rem;
  font-weight: 600;
  color: var(--color-heading);
  min-width: 0;
  overflow-wrap: anywhere;
}
.ui-dialog__tools {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-inline-start: auto;
  flex-wrap: wrap;
  min-width: 0;
}
.ui-dialog__close {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 32px;
  min-height: 32px;
  padding: 0;
  background: transparent;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  color: var(--color-muted);
  cursor: pointer;
}
.ui-dialog__close:hover,
.ui-dialog__close:focus-visible {
  color: var(--color-fg);
  border-color: var(--color-border);
}
.ui-dialog__body {
  flex: 1 1 auto;
  min-height: 0;
  min-width: 0;
  overflow: auto;
  overscroll-behavior: contain;
}
.ui-dialog__foot {
  flex: none;
  padding: 8px 14px;
  border-top: 1px solid var(--color-border);
  background: var(--color-bg-2);
  min-width: 0;
}
@media (max-width: 640px) {
  .ui-dialog-backdrop { padding: 8px; }
  .ui-dialog { height: 100%; max-height: 100%; border-radius: var(--radius-md); }
}
/* SPL-1133: Mac style (the default) puts the X first - the wider inset
   goes to the title's end instead. Phones (<= 600 px) keep their own bar. */
@media (min-width: 601px) {
  :global(html:not([data-close-buttons="windows"]) .ui-dialog__head) { padding-inline: 8px 14px; }
}
/* SPL-993: the back chevron exists only on a phone. */
.ui-dialog__back { display: none; }
/* SPL-993 (epic SPL-988): at <= 600 px every dialog, whatever its size, is a
   full screen: a top bar (Back + title + the content's tools), the body
   scrolling under it, the footer above the home indicator. */
@media (max-width: 600px) {
  .ui-dialog-backdrop { padding: 0; }
  .ui-dialog,
  .ui-dialog.sm,
  .ui-dialog.md,
  .ui-dialog.lg,
  .ui-dialog.xl,
  .ui-dialog.card {
    width: 100%;
    max-width: 100%;
    height: 100%;
    max-height: 100%;
    border: 0;
    box-shadow: none;
  }
  .ui-dialog__head {
    gap: 4px;
    min-height: 56px;
    padding: max(6px, env(safe-area-inset-top)) 8px 6px 4px;
  }
  .ui-dialog__back {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex: none;
    min-width: var(--tap, 44px);
    min-height: var(--tap, 44px);
    padding: 0;
    background: transparent;
    border: 1px solid transparent;
    border-radius: var(--radius-sm);
    color: var(--color-fg);
    cursor: pointer;
  }
  .ui-dialog__back:focus-visible { border-color: var(--color-border); }
  .ui-dialog__back:dir(rtl) .ui-icon { transform: scaleX(-1); }
  .ui-dialog__close { display: none; }
  /* CLE-77853: a routed dialog (Settings) is a full-screen sheet that keeps
     its X at the chosen corner (SPL-1133); Back is the browser's */
  .ui-dialog.routed .ui-dialog__back { display: none; }
  .ui-dialog.routed .ui-dialog__close { display: inline-flex; }
  .ui-dialog.routed .ui-dialog__head { padding-inline: 8px; }
  .ui-dialog__title {
    flex: 1 1 0;
    font-size: 1rem;
  }
  .ui-dialog__foot { padding-bottom: max(8px, env(safe-area-inset-bottom)); }
  /* a confirm on a phone is the same full screen: the top bar returns */
  .ui-dialog.sm .ui-dialog__head {
    padding: max(6px, env(safe-area-inset-top)) 8px 6px 4px;
    border-bottom: 1px solid var(--color-border);
    background: var(--color-bg-2);
  }
  .ui-dialog.sm .ui-dialog__title { font-size: 1rem; }
  .ui-dialog.sm .ui-dialog__foot { padding: 16px 16px max(16px, env(safe-area-inset-bottom)); }
}
/* Phones and small tablets are touch screens: the X is a 44 px target and
   inputs are >= 16 px, so iOS does not zoom the page on focus. */
@media (max-width: 820px) {
  .ui-dialog__close { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  .ui-dialog__foot :deep(.btn) { min-height: var(--tap, 44px); }
  .ui-dialog__body :deep(input),
  .ui-dialog__body :deep(textarea),
  .ui-dialog__body :deep(select) { font-size: max(16px, 1rem); }
}
</style>
