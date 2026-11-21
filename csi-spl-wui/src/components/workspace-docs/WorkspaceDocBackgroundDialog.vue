<!-- SPL-6139 (owner HUM-10, t1 60bf4e56, msg 2dda6b09): the doc view's
     Background… dialog, opened from the page's Document actions menu. A few
     predefined page themes (DOC_BGS in -doc-background.ts), each a swatch;
     a pick applies at once and the dialog stays open to try the next one,
     Done or Escape closes it. UiDialog owns the modal behaviour. -->
<template>
  <UiDialog :open="open" :title="t('ws_doctree.doc_bg.title')" size="sm" @update:open="emit('update:open', $event)">
    <div class="wsdoc-bg-dlg" data-test="ws-doc-bg-dialog">
      <div class="wsdoc-bg-dlg__list" role="radiogroup" :aria-label="t('ws_doctree.doc_bg.title')">
        <button
          v-for="(b, i) in DOC_BGS"
          :key="b.id"
          type="button"
          role="radio"
          class="wsdoc-bg-dlg__opt"
          :aria-checked="b.id === modelValue ? 'true' : 'false'"
          :data-test="'ws-doc-bg-' + b.id"
          :data-autofocus="b.id === modelValue ? '' : undefined"
          :tabindex="b.id === modelValue ? 0 : -1"
          @click="emit('update:modelValue', b.id)"
          @keydown.down.prevent="step(i, 1)"
          @keydown.right.prevent="step(i, 1)"
          @keydown.up.prevent="step(i, -1)"
          @keydown.left.prevent="step(i, -1)"
        >
          <span class="wsdoc-bg-dlg__swatch" :class="'wsdoc-bg-dlg__swatch--' + b.id" aria-hidden="true" />
          <span class="wsdoc-bg-dlg__name">{{ t(b.labelKey) }}</span>
          <UiIcon v-if="b.id === modelValue" name="check" :size="16" />
        </button>
      </div>
      <p class="wsdoc-bg-dlg__note muted">{{ t('ws_doctree.doc_bg.note') }}</p>
      <div class="wsdoc-bg-dlg__actions">
        <button type="button" class="btn" data-test="ws-doc-bg-done" @click="emit('update:open', false)">{{ t('ws_doctree.doc_bg.done') }}</button>
      </div>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { nextTick } from 'vue'
import UiDialog from '~/components/UiDialog.vue'
import { DOC_BGS, type DocBg } from './-doc-background'

defineProps<{ open: boolean, modelValue: DocBg }>()
const emit = defineEmits<{ 'update:open': [boolean], 'update:modelValue': [DocBg] }>()
const { t } = useI18n({ useScope: 'global' })

/* a radio group's arrows move the choice (and so apply it) and the focus */
function step(i: number, by: number) {
  const next = DOC_BGS[(i + by + DOC_BGS.length) % DOC_BGS.length]
  emit('update:modelValue', next.id)
  void nextTick(() => document.querySelector<HTMLElement>(`[data-test=ws-doc-bg-${next.id}]`)?.focus())
}
</script>

<style scoped>
.wsdoc-bg-dlg { display: grid; gap: 10px; padding: 14px; min-width: 0; }
.wsdoc-bg-dlg__list { display: grid; gap: 4px; }
.wsdoc-bg-dlg__opt {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: var(--tap);
  padding: 4px 10px;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.wsdoc-bg-dlg__opt:hover { background: var(--color-surface-hover); border-color: var(--color-border); }
.wsdoc-bg-dlg__opt[aria-checked='true'] { font-weight: 600; border-color: var(--color-border-strong); }
.wsdoc-bg-dlg__name { flex: 1 1 auto; min-width: 0; overflow-wrap: anywhere; }
.wsdoc-bg-dlg__swatch {
  flex-shrink: 0;
  width: 28px;
  height: 20px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--color-border-strong);
}
/* each swatch shows its OWN page colour (DOC_BGS[].swatch), so literals, not
   tokens; a class, never a style attribute (the deployed CSP hashes styles).
   auto is half white, half the dark theme's page: what it does in each */
.wsdoc-bg-dlg__swatch--auto { background: linear-gradient(135deg, #ffffff 50%, #060912 50%); }
.wsdoc-bg-dlg__swatch--white { background: #ffffff; }
.wsdoc-bg-dlg__swatch--paper { background: #f7f0e1; }
.wsdoc-bg-dlg__swatch--grey { background: #eceef1; }
.wsdoc-bg-dlg__swatch--dark { background: #14171c; }
.wsdoc-bg-dlg__note { margin: 0; font-size: 0.8125rem; overflow-wrap: anywhere; }
.wsdoc-bg-dlg__actions { display: flex; justify-content: flex-end; }
</style>
