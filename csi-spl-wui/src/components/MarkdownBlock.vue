<template>
  <div class="md-block" data-testid="md-block">
    <button
      type="button"
      class="md-block__toggle"
      data-testid="md-block-toggle"
      :aria-pressed="showSource"
      @click.stop="showSource = !showSource"
    >{{ showSource ? t('markdown.show_rendered') : t('markdown.show_source') }}</button>
    <pre v-if="showSource" class="md-block__source" dir="auto">{{ text }}</pre>
    <!-- eslint-disable-next-line vue/no-v-html -- markdown-it html:false + safe links, see utils/markdown.mjs -->
    <div v-else class="md-block__body" dir="auto" v-html="html" />
  </div>
</template>

<script setup lang="ts">
import { renderMarkdown } from '~/utils/markdown.mjs'

/* spec 039 markdown compatibility: a ```md / ```markdown fence rendered as
   standard markdown (tables, lists, headings ...). Raw HTML stays text. */
const props = defineProps<{ text: string }>()
const { t } = useI18n({ useScope: 'global' })
const showSource = ref(false)
const html = computed(() => renderMarkdown(props.text))
</script>

<style scoped>
.md-block { position: relative; margin: 0.25rem 0; }
.md-block__toggle {
  position: absolute; top: 0; right: 0;
  font-size: 0.75rem; padding: 0.1rem 0.4rem;
  border: 1px solid var(--color-border, #ccc); border-radius: var(--radius-sm);
  background: var(--color-surface, transparent); color: inherit; cursor: pointer; opacity: 0.7;
}
.md-block__toggle:hover, .md-block__toggle:focus-visible { opacity: 1; }
.md-block__source { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; padding-top: 1.5rem; }
.md-block__body { padding-right: 5rem; overflow-wrap: anywhere; }
.md-block__body :deep(table) { border-collapse: collapse; margin: 0.4rem 0; display: block; overflow-x: auto; max-width: 100%; }
.md-block__body :deep(th), .md-block__body :deep(td) { border: 1px solid var(--color-border, #ccc); padding: 0.25rem 0.5rem; text-align: start; }
.md-block__body :deep(th) { font-weight: 600; }
.md-block__body :deep(ul), .md-block__body :deep(ol) { padding-inline-start: 1.4rem; margin: 0.3rem 0; }
.md-block__body :deep(blockquote) { border-inline-start: 3px solid var(--color-border, #ccc); margin: 0.3rem 0; padding-inline-start: 0.6rem; opacity: 0.85; }
.md-block__body :deep(h1), .md-block__body :deep(h2), .md-block__body :deep(h3) { margin: 0.5rem 0 0.25rem; line-height: 1.25; }
.md-block__body :deep(h1) { font-size: 1.3rem; } .md-block__body :deep(h2) { font-size: 1.15rem; } .md-block__body :deep(h3) { font-size: 1.05rem; }
.md-block__body :deep(p) { margin: 0.25rem 0; }
.md-block__body :deep(pre) { white-space: pre-wrap; overflow-wrap: anywhere; padding: 0.4rem; border-radius: var(--radius-sm); background: var(--color-code-bg, rgba(127,127,127,0.12)); }
.md-block__body :deep(code) { font-family: var(--font-mono, monospace); }
.md-block__body :deep(a) { color: var(--color-accent); }
</style>
