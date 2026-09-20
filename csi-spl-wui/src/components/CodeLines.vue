<!-- Source code as rows of tokens (013 FR-016).

     ONE row per source line, and every token is `{{ text }}` — Vue text
     interpolation, never `v-html`. That is the whole security story: the
     highlighter hands over `{ text, cls }` pairs (utils/highlighter.mjs), the
     class comes from the grammar and the text from the message, and the two
     can never swap roles. A `<script>` in a body is eight characters here,
     exactly as it is in an unhighlighted block.

     NO HORIZONTAL SCROLL (owner 2026-09-19). Rows soft-wrap by default and
     wrapped continuations carry a hanging indent, which is the wrapped-line
     marker: the first visual row of a line starts at the left edge, every
     continuation of it is inset. `wrap=false` is the deliberate opt-out
     inside the dialog, where the reader asked for long lines and the DIALOG
     BODY - never the page - is what scrolls.

     The colours are our own palette tokens, so the theme follows
     `data-theme` light/dark for free and no third-party stylesheet is
     loaded or injected (CSP: nothing needs 'unsafe-inline'). -->
<template>
  <pre
    class="code-lines"
    :class="{ 'no-wrap': !wrap, numbered }"
    :data-lang="lang || undefined"
    :tabindex="scrollable ? 0 : undefined"
  ><code><span
    v-for="(line, i) in lines"
    :key="i"
    class="code-line"
  ><span
    v-if="numbered"
    class="code-ln"
    aria-hidden="true"
  >{{ firstLine + i }}</span><span class="code-src"><span
    v-for="(tok, j) in line"
    :key="j"
    :class="tok.cls"
  >{{ tok.text }}</span></span></span></code></pre>
</template>

<script setup lang="ts">
type Token = { text: string; cls: string }

withDefaults(
  defineProps<{
    /** one array of tokens per source line (utils/code-view.mjs tokensToLines) */
    lines: Token[][]
    /** soft-wrap long lines instead of scrolling sideways */
    wrap?: boolean
    numbered?: boolean
    /** the number on the first row (a preview always starts at 1) */
    firstLine?: number
    lang?: string
    /** the block itself may scroll (dialog, wrap off) — then it is focusable */
    scrollable?: boolean
  }>(),
  { wrap: true, numbered: false, firstLine: 1, lang: '', scrollable: false },
)
</script>

<style scoped>
.code-lines {
  margin: 0;
  padding: 4px 10px 8px;
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: 1.5;
  tab-size: 4;
  /* the rows carry the whitespace rules; the box itself must never be the
     thing that scrolls the page sideways */
  white-space: normal;
  max-width: 100%;
  min-width: 0;
  overflow-x: hidden;
}
.code-lines.no-wrap { overflow-x: auto; }
.code-lines:focus-visible { outline: 2px solid var(--color-accent); outline-offset: -2px; }
.code-lines code {
  font-family: inherit;
  font-size: inherit;
  background: none;
  padding: 0;
  display: block;
  min-width: 0;
}
.code-line {
  display: flex;
  gap: 10px;
  /* an empty source line is still a line */
  min-height: 1.5em;
}
.code-ln {
  flex: none;
  width: 3.5ch;
  text-align: right;
  color: var(--color-muted);
  user-select: none;
  -webkit-user-select: none;
}
.code-src {
  flex: 1 1 auto;
  min-width: 0;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  /* the wrapped-line marker: continuations are inset, the first row is not */
  padding-inline-start: 2ch;
  text-indent: -2ch;
}
.no-wrap .code-src {
  white-space: pre;
  overflow-wrap: normal;
  padding-inline-start: 0;
  text-indent: 0;
}

/* ── token theme, from the palette tokens only (light + dark for free) ── */
.code-src :deep(.hljs-comment),
.code-src :deep(.hljs-quote) {
  color: var(--color-muted);
  font-style: italic;
}
.code-src :deep(.hljs-keyword),
.code-src :deep(.hljs-selector-tag),
.code-src :deep(.hljs-literal),
.code-src :deep(.hljs-type),
.code-src :deep(.hljs-built_in),
.code-src :deep(.hljs-doctag),
.code-src :deep(.hljs-keyword.hljs-meta) { color: var(--color-accent-2); }
.code-src :deep(.hljs-string),
.code-src :deep(.hljs-regexp),
.code-src :deep(.hljs-char),
.code-src :deep(.hljs-addition) { color: var(--color-ok); }
.code-src :deep(.hljs-number),
.code-src :deep(.hljs-symbol),
.code-src :deep(.hljs-bullet),
.code-src :deep(.hljs-link) { color: var(--color-warn); }
.code-src :deep(.hljs-title),
.code-src :deep(.hljs-name),
.code-src :deep(.hljs-section),
.code-src :deep(.hljs-attr),
.code-src :deep(.hljs-attribute),
.code-src :deep(.hljs-selector-id),
.code-src :deep(.hljs-selector-class),
.code-src :deep(.hljs-template-variable),
.code-src :deep(.hljs-variable) { color: var(--color-accent); }
.code-src :deep(.hljs-meta),
.code-src :deep(.hljs-comment .hljs-doctag) { color: var(--color-muted); }
.code-src :deep(.hljs-deletion) { color: var(--color-danger); }
.code-src :deep(.hljs-emphasis) { font-style: italic; }
.code-src :deep(.hljs-strong),
.code-src :deep(.hljs-title.class_),
.code-src :deep(.hljs-title.function_) { font-weight: 600; }
</style>
