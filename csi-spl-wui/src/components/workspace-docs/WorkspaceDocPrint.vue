<!-- Spec 113 T006, print branch (D-Q2 = standard print CSS): one subtree
     read rendered here, under body, and the browser's own print. While the
     page prints, html carries ws-doc-printing and the print stylesheet hides
     everything else; on screen this block is never shown. -->
<template>
  <Teleport to="body">
    <article v-if="items.length" class="ws-doc-print" data-test="ws-doc-print">
      <h1 class="ws-doc-print__doc">{{ title }}</h1>
      <section
        v-for="it in items"
        :key="it.id"
        class="ws-doc-print__item"
        data-test="ws-doc-print-item"
        :style="{ '--ws-print-depth': it.depth - base }"
      >
        <p class="ws-doc-print__head" role="heading" :aria-level="Math.min(6, it.depth - base + 2)">
          <span class="ws-doc-print__num">{{ it.outline }}</span> {{ it.title }}
        </p>
        <p v-if="it.body" class="ws-doc-print__body">{{ it.body }}</p>
      </section>
    </article>
  </Teleport>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { DocItem } from './-doctree-api'

const props = defineProps<{ title: string, items: DocItem[] }>()
const base = computed(() => props.items[0]?.depth ?? 0)
</script>

<style>
.ws-doc-print { display: none; }
@media print {
  html.ws-doc-printing body > *:not(.ws-doc-print) { display: none !important; }
  html.ws-doc-printing .ws-doc-print { display: block; color: black; background: white; font: 11pt/1.45 serif; }
  .ws-doc-print__doc { font-size: 18pt; margin: 0 0 12pt; }
  .ws-doc-print__item { margin-inline-start: calc(var(--ws-print-depth, 0) * 14pt); break-inside: avoid-page; }
  .ws-doc-print__head { font-weight: 700; margin: 10pt 0 3pt; }
  .ws-doc-print__num { font-variant-numeric: tabular-nums; }
  .ws-doc-print__body { margin: 0 0 6pt; white-space: pre-wrap; }
}
</style>
