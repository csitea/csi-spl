<!-- The full source of one snippet (013 FR-017).

     This is the first CONTENT TYPE of UiDialog.vue, and the only thing that
     knows anything about code: the dialog above it holds focus and Escape,
     this holds highlighting, the wrap toggle, line numbers and copy. A file
     preview later is a sibling of this file, not a branch inside it. -->
<template>
  <div class="code-viewer">
    <div class="code-viewer__bar">
      <span class="code-viewer__meta">{{ t('code.size', { lines: size.lines, chars: size.chars }) }}</span>
      <button
        type="button"
        class="code-viewer__toggle"
        data-testid="code-wrap"
        :aria-pressed="wrap"
        @click="wrap = !wrap"
      >{{ t('code.wrap_lines') }}</button>
      <button
        type="button"
        class="code-viewer__toggle"
        data-testid="code-numbers"
        :aria-pressed="numbered"
        @click="numbered = !numbered"
      >{{ t('code.line_numbers') }}</button>
      <button
        type="button"
        class="code-viewer__toggle"
        data-testid="code-viewer-copy"
        :aria-label="copied ? t('code.copied') : t('code.copy')"
        @click="copy(text, 'full')"
      >
        <UiIcon :name="copied ? 'check' : 'copy'" :size="14" />
        <span>{{ copied ? t('code.copied') : t('code.copy') }}</span>
      </button>
    </div>
    <CodeLines
      class="code-viewer__code"
      data-testid="code-viewer-lines"
      :lines="lines"
      :wrap="wrap"
      :numbered="numbered"
      :lang="lang"
      :scrollable="!wrap"
    />
    <span class="sr-only" aria-live="polite">{{ copied ? t('code.copied') : '' }}</span>
  </div>
</template>

<script setup lang="ts">
import { measureCode } from '~/utils/code-view.mjs'

const props = defineProps<{ text: string; lang: string }>()
const { t } = useI18n({ useScope: 'global' })

/* Long lines wrap by default here too — turning it off is the reader's
   explicit choice, and then the CODE BLOCK scrolls, never the page. */
const wrap = ref(true)
const numbered = ref(true)

const text = computed(() => props.text)
const lang = computed(() => props.lang)
const { lines } = useCodeLines(text, lang)
const size = computed(() => measureCode(props.text))

const { copied: copiedId, copy } = useCopyText()
const copied = computed(() => copiedId.value === 'full')
</script>

<style scoped>
.code-viewer {
  display: flex;
  flex-direction: column;
  min-height: 100%;
  min-width: 0;
}
.code-viewer__bar {
  position: sticky;
  top: 0;
  z-index: 1;
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  padding: 6px 12px;
  background: var(--color-bg-2);
  border-bottom: 1px solid var(--color-border);
  min-width: 0;
}
.code-viewer__meta {
  font-size: 11px;
  color: var(--color-muted);
  font-family: var(--font-mono);
  margin-inline-end: auto;
  overflow-wrap: anywhere;
  min-width: 0;
}
.code-viewer__toggle {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  padding: 3px 9px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--color-border);
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.code-viewer__toggle:hover,
.code-viewer__toggle:focus-visible {
  color: var(--color-fg);
  border-color: var(--color-border-strong);
}
.code-viewer__toggle[aria-pressed="true"] {
  color: var(--color-on-accent);
  background: var(--color-accent);
  border-color: var(--color-accent);
}
.code-viewer__code {
  flex: 1 1 auto;
  padding: 8px 12px 16px;
  min-width: 0;
}
</style>
