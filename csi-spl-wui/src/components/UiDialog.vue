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
    <div
      v-if="open"
      class="ui-dialog-backdrop"
      data-testid="ui-dialog-backdrop"
      @mousedown.self="onBackdrop"
    >
      <div
        ref="panelEl"
        class="ui-dialog"
        :class="size"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="titleId"
        data-testid="ui-dialog"
        tabindex="-1"
        @keydown="onKeydown"
      >
        <header class="ui-dialog__head">
          <h2 :id="titleId" class="ui-dialog__title">{{ title }}</h2>
          <div class="ui-dialog__tools"><slot name="tools" /></div>
          <button
            type="button"
            class="ui-dialog__close"
            data-testid="ui-dialog-close"
            :title="t('common.close')"
            :aria-label="t('common.close')"
            @click="close"
          >
            <UiIcon name="x" :size="18" />
          </button>
        </header>
        <div class="ui-dialog__body" data-testid="ui-dialog-body">
          <slot />
        </div>
        <footer v-if="$slots.footer" class="ui-dialog__foot">
          <slot name="footer" />
        </footer>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
const props = withDefaults(
  defineProps<{
    open: boolean
    title: string
    /** `lg` fills most of the viewport (source); `xl` is 90% of it both ways (a picture); `md` is a plain dialog. */
    size?: 'md' | 'lg' | 'xl'
  }>(),
  { size: 'lg' },
)
const emit = defineEmits<{ 'update:open': [boolean] }>()
const { t } = useI18n({ useScope: 'global' })

const titleId = useId()
const panelEl = ref<HTMLElement | null>(null)
const mounted = ref(false)
let returnFocusTo: HTMLElement | null = null

onMounted(() => { mounted.value = true })

function close() {
  emit('update:open', false)
}

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

watch(
  () => props.open,
  async (isOpen) => {
    if (!import.meta.client) return
    if (isOpen) {
      returnFocusTo = document.activeElement as HTMLElement | null
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
      document.documentElement.style.overflow = ''
      returnFocusTo?.focus?.()
      returnFocusTo = null
    }
  },
)

onUnmounted(() => {
  if (import.meta.client) document.documentElement.style.overflow = ''
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
.ui-dialog.lg { max-width: 1100px; height: 100%; }
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
</style>
