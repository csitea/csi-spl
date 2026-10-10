<!-- Spec 113 T006, print (D-Q2 = standard print CSS), Qto's print-doc: one
     subtree read (a branch, or the whole document) rendered here, under body,
     and the browser's own print. The numbered contents come first, then a
     page break, then the document. While the page prints, html carries
     ws-doc-printing and the print stylesheet hides everything else; on
     screen this block is never shown. A paragraph's pictures and the section
     image print with their "Figure N:" captions (t1 46d9c236), their sources
     resolved by the page before it prints. -->
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
        <div v-if="it.body" class="ws-doc-print__body">
          <template v-for="(r, i) in runsOf(it)" :key="i">
            <span v-if="r.kind === 'text'">{{ r.text }}</span>
            <figure v-else class="ws-doc-print__fig" data-test="ws-doc-print-pic">
              <img v-if="srcs[r.path]" :src="srcs[r.path]" :alt="r.caption">
              <figcaption>{{ t('ws_doctree.figure', { n: r.n }) }} {{ r.caption }}</figcaption>
            </figure>
          </template>
        </div>
        <pre v-if="typeof it.attrs?.src === 'string' && it.attrs.src" class="ws-doc-print__src">{{ it.attrs.src }}</pre>
        <figure v-if="imgOf(it)" class="ws-doc-print__fig" data-test="ws-doc-print-img">
          <img v-if="srcs[imgOf(it)]" :src="srcs[imgOf(it)]" :alt="nameOf(it)">
          <figcaption>{{ t('ws_doctree.figure', { n: figs.get(it.id)?.image ?? 0 }) }} {{ nameOf(it) }}</figcaption>
        </figure>
      </section>
    </article>
  </Teleport>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import type { DocItem } from './-doctree-api'
import { figureNumbers, picRuns } from './-doc-pics'

/* doc: whose picture tokens count; srcs: an image's hub path -> the URL the <img> shows */
const props = defineProps<{ title: string, items: DocItem[], doc: string, srcs: Record<string, string> }>()
const { t } = useI18n({ useScope: 'global' })
const base = computed(() => Math.min(...props.items.map((it) => it.depth)))
const figs = computed(() => figureNumbers(props.items, props.doc))
const imgOf = (it: DocItem) => (typeof it.attrs?.img_http_path === 'string' ? it.attrs.img_http_path : '')
const nameOf = (it: DocItem) => (typeof it.attrs?.img_name === 'string' ? it.attrs.img_name : '')

/** the paragraph as text runs and its numbered pictures */
function runsOf(it: DocItem) {
  let n = figs.value.get(it.id)?.first ?? 1
  return picRuns(it.body, props.doc).map((r) => (r.kind === 'pic' ? { ...r, n: n++ } : r))
}
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
  .ws-doc-print__fig { margin: 6pt 0; break-inside: avoid; }
  .ws-doc-print__fig img { display: block; max-width: 100%; height: auto; }
  .ws-doc-print__fig figcaption { font-size: 9pt; font-weight: 700; margin-top: 2pt; }
  .ws-doc-print__src { margin: 0 0 6pt; padding: 6pt; border: 1px solid currentColor; font: 9pt/1.4 monospace; white-space: pre-wrap; }
}
</style>
