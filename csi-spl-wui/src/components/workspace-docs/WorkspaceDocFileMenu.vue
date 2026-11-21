<!-- SPL-6083 (owner HUM-10, t1 60bf4e56, msgs ce88082a and 55440858): the
     Qto doc view's one header menu. The page draws it right of the doc
     view's contents toggle (#wsdocs-head-tools) in both views, so the
     Outline / Grid switch, which left the header, is always one click away.
     The button shows the three bars the contents toggle used to show
     ("the icon changed with the current icon for the table of contents").
     The page owns the entries: one more (PDF export, msg 06a6925f) is one
     more PointMenuItem. Was WorkspaceDocView's file menu (SPL-3233): a key
     (Escape) or a choice gives the focus back to the button. -->
<template>
  <div class="wsdoc-filemenu">
    <button
      ref="btn"
      type="button"
      class="wsdoc-filemenu__btn"
      data-test="ws-doc-file-btn"
      aria-haspopup="menu"
      :aria-expanded="at ? 'true' : 'false'"
      :aria-label="t('ws_doctree.doc_menu.label')"
      :title="t('ws_doctree.doc_menu.label')"
      @click="openMenu"
      @keydown.esc="onKey"
      @keydown.down="onKey"
    >
      <UiIcon name="menu" :size="16" />
    </button>
    <UiPointMenu
      :open="Boolean(at)"
      :x="at?.x ?? 0"
      :y="at?.y ?? 0"
      :items="items"
      :label="t('ws_doctree.doc_menu.label')"
      block="wsdoc-file-menu"
      testid="ws-doc-file-menu"
      data-test="ws-doc-file-menu"
      wide
      @close="at = null"
      @escape="btn?.focus()"
      @choose="choose"
    />
  </div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue'
import UiPointMenu, { type PointMenuItem } from '~/components/UiPointMenu.vue'

defineProps<{ items: PointMenuItem[] }>()
const emit = defineEmits<{ choose: [id: string] }>()
const { t } = useI18n({ useScope: 'global' })

const btn = ref<HTMLButtonElement | null>(null)
const at = ref<{ x: number, y: number } | null>(null)
/* a click on the open menu's button: its pointerdown already closed the
   menu (a press outside it, usePointMenu), so that click must not open it
   again. A window capture listener runs before usePointMenu's document one. */
let pressOnBtn = false
function notePress(e: PointerEvent) {
  pressOnBtn = Boolean(btn.value && e.target instanceof Node && btn.value.contains(e.target))
}
watch(at, (m, was) => {
  if (m && !was) window.addEventListener('pointerdown', notePress, true)
  else if (!m) window.removeEventListener('pointerdown', notePress, true)
})
function openMenu(e: MouseEvent) {
  const reclick = pressOnBtn && e.detail > 0
  pressOnBtn = false
  if (reclick) return
  const r = btn.value?.getBoundingClientRect()
  at.value = { x: r ? r.right : 0, y: r ? r.bottom : 0 }
}
/* a phone's sheet leaves the focus on the button: Escape closes it there, ArrowDown steps into it */
function onKey(e: KeyboardEvent) {
  if (!at.value) return
  e.preventDefault()
  if (e.key === 'Escape') at.value = null
  else document.querySelector<HTMLElement>('[data-test=ws-doc-file-menu] [role=menuitem]')?.focus()
}
function choose(id: string) {
  emit('choose', id)
  btn.value?.focus()
}
onBeforeUnmount(() => window.removeEventListener('pointerdown', notePress, true))
</script>

<style scoped>
.wsdoc-filemenu { display: flex; flex: 0 0 auto; }
/* WorkspaceDocView's header tool (.wsdoc__bar--head .wsdoc__tool): a plain 44 px tap */
.wsdoc-filemenu__btn {
  appearance: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  box-sizing: border-box;
  width: var(--tap);
  height: var(--tap);
  padding: 0;
  margin: 0;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  cursor: pointer;
  line-height: 0;
}
.wsdoc-filemenu__btn:hover { background: var(--color-surface-hover); border-color: var(--color-border); }
</style>
