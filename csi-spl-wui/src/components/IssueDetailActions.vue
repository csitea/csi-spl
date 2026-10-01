<!-- CLE-77854 (owner, topic 643330e5): "convert those right-click menu options
     [to] separate buttons, but at the end of the existing right side
     controls". The open issue's Copy link / Archive / Delete are three icon
     buttons in the dialog header (and the phone's top bar), no ☰ menu. The
     page owns the actions; this only draws the buttons. -->
<template>
  <div class="issue-actions" data-test="issues-detail-actions" role="group" :aria-label="t('issues_menu.label')">
    <button
      v-for="b in buttons"
      :key="b.id"
      type="button"
      class="issue-actions__btn"
      :class="{ 'issue-actions__btn--danger': b.danger, 'issue-actions__btn--tap': tap }"
      :data-test="'issues-detail-' + b.id"
      :data-copied="b.id === 'copy' && copied ? 'true' : undefined"
      :aria-label="t(label(b))"
      :title="t(label(b))"
      @click="emit(b.id)"
    >
      <UiIcon :name="b.id === 'copy' && copied ? 'check' : b.icon" :size="tap ? 20 : 18" />
    </button>
  </div>
</template>

<script setup lang="ts">
import type { UiIconName } from '@/utils/uiIcons'

const props = defineProps<{
  /** the phone's top bar: 44 px tap targets */
  tap?: boolean
  /** the link was just copied: the copy button shows a check and says so */
  copied?: boolean
}>()
const emit = defineEmits<{ (e: 'copy' | 'archive' | 'delete'): void }>()
const { t } = useI18n({ useScope: 'global' })

/* the order the owner's menu had: Copy link, Archive, Delete (the destructive
   one last, nearest the edge) */
type ActionButton = { id: 'copy' | 'archive' | 'delete', icon: UiIconName, labelKey: string, danger?: boolean }
const buttons: ActionButton[] = [
  { id: 'copy', icon: 'copy', labelKey: 'issues_menu.copy_link' },
  { id: 'archive', icon: 'archive', labelKey: 'issues_menu.archive' },
  { id: 'delete', icon: 'delete', labelKey: 'issues_menu.delete', danger: true },
]
function label(b: ActionButton) {
  return b.id === 'copy' && props.copied ? 'common.copied' : b.labelKey
}
</script>

<style scoped>
.issue-actions { display: inline-flex; align-items: center; gap: 2px; flex: 0 0 auto; }
.issue-actions__btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 32px;
  min-height: 32px;
  padding: 0;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.issue-actions__btn:hover, .issue-actions__btn:focus-visible { color: var(--color-fg); border-color: var(--color-border); outline: none; }
.issue-actions__btn--danger:hover, .issue-actions__btn--danger:focus-visible { color: var(--color-danger); }
.issue-actions__btn--tap { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
</style>
