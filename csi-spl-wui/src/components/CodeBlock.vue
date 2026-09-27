<!-- One ``` block inside a message card (013 FR-016).

     A card is a glance. Past PREVIEW_LIMIT (code-view.mjs: 20 lines / 1200
     chars) the snippet shows its head and says how much is left; the rest is
     in the dialog. Nothing here scrolls sideways — long lines wrap, with a
     hanging indent on the continuations (CodeLines.vue).

     Two ways to the full source, as the owner asked: the small ICON control
     in the head (always there, for any block) and, when the preview is cut,
     an explicit labelled button under it. Both open the same UiDialog. -->
<template>
  <figure
    class="code-block"
    :aria-label="lang ? t('code.block_label_lang', { lang }) : t('code.block_label')"
  >
    <figcaption class="code-head">
      <span v-if="lang" class="code-lang">{{ lang }}</span>
      <span v-if="preview.truncated" class="code-cut" data-testid="code-cut">{{
        t('code.showing_lines', { shown: preview.shownLines, total: preview.totalLines })
      }}</span>
      <button
        type="button"
        class="code-icon"
        data-testid="code-open"
        :title="t('code.open_full')"
        :aria-label="t('code.open_full')"
        @click="dialogOpen = true"
      >
        <UiIcon name="open" :size="15" />
      </button>
      <button
        type="button"
        class="code-icon"
        data-testid="code-copy"
        :title="copied ? t('code.copied') : t('code.copy')"
        :aria-label="copied ? t('code.copied') : t('code.copy')"
        @click="copy(text, 'block')"
      >
        <UiIcon :name="copied ? 'check' : 'copy'" :size="15" />
      </button>
    </figcaption>

    <CodeLines :lines="lines" :lang="lang" wrap />

    <button
      v-if="preview.truncated"
      type="button"
      class="code-expand"
      data-testid="code-expand"
      @click="dialogOpen = true"
    >
      <UiIcon name="open" :size="14" />
      <span>{{ t('code.show_all', { n: preview.hiddenLines }) }}</span>
    </button>

    <UiDialog v-model:open="dialogOpen" :title="dialogTitle" size="lg">
      <CodeViewer :text="text" :lang="lang" />
    </UiDialog>

    <span class="sr-only" aria-live="polite">{{ copied ? t('code.copied') : '' }}</span>
  </figure>
</template>

<script setup lang="ts">
import { previewOf } from '~/utils/code-view.mjs'

const props = defineProps<{ text: string; lang: string }>()
const { t } = useI18n({ useScope: 'global' })

const dialogOpen = ref(false)
const preview = computed(() => previewOf(props.text))
const previewText = computed(() => preview.value.text)
const lang = computed(() => props.lang)

/* the CARD highlights only the preview; the dialog highlights the whole
   source, and only once it is actually opened */
const { lines } = useCodeLines(previewText, lang)

const dialogTitle = computed(() =>
  props.lang ? t('code.block_label_lang', { lang: props.lang }) : t('code.block_label'),
)

const { copied: copiedId, copy } = useCopyText()
const copied = computed(() => copiedId.value === 'block')
</script>

<style scoped>
.code-block {
  margin: 4px 0;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-bg-2);
  max-width: 100%;
  min-width: 0;
  overflow: hidden;
}
.code-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 2px 4px 0 10px;
  min-width: 0;
}
.code-lang {
  font-family: var(--font-mono);
  font-size: 0.6875rem;
  color: var(--color-muted);
  overflow-wrap: anywhere;
  min-width: 0;
}
.code-cut {
  font-size: 0.6875rem;
  color: var(--color-muted);
  margin-inline-start: auto;
  overflow-wrap: anywhere;
  min-width: 0;
}
/* with no cut marker the icons still sit at the end of the row */
.code-lang + .code-icon,
.code-head > .code-icon:first-child { margin-inline-start: auto; }
.code-cut + .code-icon { margin-inline-start: 0; }
.code-icon {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: none;
  min-width: 28px;
  min-height: 28px;
  padding: 0;
  background: transparent;
  border: 1px solid transparent;
  border-radius: var(--radius-sm);
  color: var(--color-muted);
  cursor: pointer;
}
.code-icon:hover,
.code-icon:focus-visible {
  color: var(--color-fg);
  border-color: var(--color-border);
}
.code-expand {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  width: 100%;
  min-height: 30px;
  padding: 4px 10px;
  border: 0;
  border-top: 1px solid var(--color-border);
  background: var(--color-bg-3);
  color: var(--color-accent);
  font-size: 0.75rem;
  cursor: pointer;
  min-width: 0;
}
.code-expand span { overflow-wrap: anywhere; min-width: 0; }
.code-expand:hover,
.code-expand:focus-visible { background: var(--color-surface-hover); }
/* SPL-991 phone: Open and Copy are 44 px targets, drawn with their border
   (a finger never hovers to reveal it); the head keeps its height by
   letting the bigger boxes overlap its padding */
@media (max-width: 820px) {
  .code-icon {
    min-width: var(--tap);
    min-height: var(--tap);
    margin-block: -8px;
    color: var(--color-fg);
    border-color: var(--color-border);
  }
  .code-head { padding-block: 8px 4px; }
  .code-expand { min-height: var(--tap); font-size: 0.875rem; }
}
</style>
