<!-- Spec 113 T006, print (D-Q2 = standard print CSS), Qto's print-doc: one
     subtree read (a branch, or the whole document) rendered here, under body,
     and the browser's own print. The numbered contents come first, then a
     page break, then the document. While the page prints, html carries
     ws-doc-printing and the print stylesheet hides everything else; on
     screen this block is never shown. -->
<template>
  <Teleport to="body">
    <article v-if="items.length" class="ws-doc-print" data-test="ws-doc-print">
      <h1 class="ws-doc-print__doc">{{ title }}</h1>
      <ol class="ws-doc-print__toc" data-test="ws-doc-print-toc">
        <li
          v-for="it in items"
          :key="it.id"
          data-test="ws-doc-print-toc-item"
          :style="{ '--ws-print-depth': it.depth - base }"
        >
          <span class="ws-doc-print__num">{{ it.outline }}</span> {{ it.title }}
        </li>
      </ol>
      <div class="ws-doc-print__break" data-test="ws-doc-print-break" />
      <section
        v-for="it in items"
        :key="it.id"
        class="ws-doc-print__item"
        data-test="ws-doc-print-item"
      >
        <p class="ws-doc-print__head" role="heading" :aria-level="Math.min(6, it.depth - base + 2)">
          <span class="ws-doc-print__num">{{ it.outline }}</span> {{ it.title }}
        </p>
        <p v-if="it.body" class="ws-doc-print__body">{{ it.body }}</p>
        <pre v-if="typeof it.attrs?.src === 'string' && it.attrs.src" class="ws-doc-print__src">{{ it.attrs.src }}</pre>
      </section>
    </article>
  </Teleport>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { DocItem } from './-doctree-api'

const props = defineProps<{ title: string, items: DocItem[] }>()
const base = computed(() => Math.min(...props.items.map((it) => it.depth)))
</script>

<style>
.ws-doc-print { display: none; }
@media print {
  @page { margin: 1.6cm; size: A4; }
  html.ws-doc-printing body > *:not(.ws-doc-print) { display: none !important; }
  html.ws-doc-printing .ws-doc-print { display: block; color: black; background: white; font: 11pt/1.45 serif; }
  .ws-doc-print__doc { font-size: 18pt; margin: 0 0 12pt; }
  .ws-doc-print__toc { list-style: none; margin: 0; padding: 0; }
  .ws-doc-print__toc li { margin-inline-start: calc(var(--ws-print-depth, 0) * 12pt); line-height: 1.5; }
  .ws-doc-print__break { break-after: page; }
  .ws-doc-print__item { break-inside: avoid-page; }
  .ws-doc-print__head { font-weight: 700; margin: 10pt 0 3pt; }
  .ws-doc-print__num { font-variant-numeric: tabular-nums; }
  .ws-doc-print__body { margin: 0 0 6pt; white-space: pre-wrap; }
  .ws-doc-print__src { margin: 0 0 6pt; padding: 6pt; border: 1px solid currentColor; font: 9pt/1.4 monospace; white-space: pre-wrap; }
}
</style>
