<!-- SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020):
     what Export to PDF prints. One card, or a topic's title and every card
     shown in its pane, in that order: the author, the time sent, the kind,
     the body rendered as on the card (MessageBody) and the card's pictures at
     the page's full width. Nothing else: no menus, no reactions, no
     composer, no side panels. Mounted by utils/msg-print-run.ts under body
     on the click; never shown on screen, and while html carries msg-printing
     the print stylesheet hides everything but this block. -->
<template>
  <article class="msg-print" data-test="msg-print">
    <h1 v-if="heading" class="msg-print__title" data-test="msg-print-title">{{ heading }}</h1>
    <section
      v-for="m in rows"
      :key="m.msg_id"
      class="msg-print__card"
      data-test="msg-print-card"
      :data-msg-id="m.msg_id"
    >
      <p class="msg-print__head" data-test="msg-print-head">
        <strong>{{ whoOf(m) }}</strong>
        <time :datetime="String(m.ts || '')">{{ formatMsgListTs(String(m.ts || '')) }}</time>
        <span class="msg-print__kind">{{ kindLabel(String(m.kind || 'note')) }}</span>
      </p>
      <MessageBody :body="String(m.body || '')" :at="m.ts" no-previews />
      <template v-for="(f, i) in filesOf(m)" :key="fileKey(f) || i">
        <figure v-if="srcs[fileKey(f)]" class="msg-print__fig" data-test="msg-print-img">
          <img :src="srcs[fileKey(f)]" :alt="f.name">
          <figcaption>{{ f.name }}</figcaption>
        </figure>
        <p v-else class="msg-print__file" data-test="msg-print-file">{{ f.name }}</p>
      </template>
    </section>
  </article>
</template>

<script setup lang="ts">
import MessageBody from '~/components/MessageBody.vue'
import { formatMsgListTs, shownPerson } from '~/utils/channel-feed.mjs'
import { typedByAuthor } from '~/utils/typed-by.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { printFileKey as fileKey } from '~/utils/msg-print'
import type { FileRef, SpoolMessage } from '~/types/spool'

/* srcs: a picture's fileKey -> its verified data: URL; a file without one prints its name */
defineProps<{ rows: SpoolMessage[], heading?: string, srcs: Record<string, string> }>()
const { t, te } = useI18n({ useScope: 'global' })
const people = useHumanNames()
/* the same author and kind words as the card (MessageCard.vue whoOf / kindLabel) */
function whoOf(m: SpoolMessage) {
  const p = typedByAuthor(m) as { id?: string, box?: string } | null
  if (!p?.id) return t('feed.unknown_author')
  return shownPerson(p.id, p.box, people.names.value)
}
const kindLabel = (k: string) => (te('feed.kind.' + k) ? t('feed.kind.' + k) : k)
const filesOf = (m: SpoolMessage) => (Array.isArray(m.files) ? m.files : []) as FileRef[]
</script>

<style>
.msg-print-host { display: none; }
@media print {
  /* a named page: an export's A4 and margins never reach another print of the WUI */
  @page msg-print { margin: 1.6cm; size: A4; }
  html.msg-printing body > *:not(.msg-print-host) { display: none !important; }
  html.msg-printing .msg-print-host { display: block; page: msg-print; }
  /* the page is white in either theme; the theme's heading colour never reaches the print */
  /* the page margin takes the canvas colour of color-scheme, which the dark theme sets on :root[data-theme] */
  html.msg-printing { color-scheme: light !important; }
  html.msg-printing, html.msg-printing body { background: white !important; }
  /* SPL-6023: the screen keeps html and body at the viewport's height with
     overflow hidden (assets/css/base.css; UiDialog's inline overflow on html
     while a dialog is open), which clipped a long export to page 1. The
     print block's only ancestors are html and body, so these let it run on. */
  html.msg-printing, html.msg-printing body {
    overflow: visible !important;
    height: auto !important;
    max-height: none !important;
  }
  .msg-print { color: black; background: white; font: 11pt/1.45 sans-serif; }
  .msg-print__title { color: inherit; font-size: 18pt; margin: 0 0 12pt; }
  .msg-print__card { padding: 8pt 0; border-bottom: 1px solid currentColor; }
  .msg-print__card:last-child { border-bottom: 0; }
  .msg-print__head, .msg-print .msg-body { color: inherit; }
  .msg-print__head { display: flex; flex-wrap: wrap; gap: 8pt; margin: 0 0 4pt; font-size: 9.5pt; }
  .msg-print__kind { text-transform: uppercase; letter-spacing: 0.04em; }
  .msg-print__fig { margin: 6pt 0; break-inside: avoid; }
  .msg-print__fig img { display: block; width: 100%; height: auto; }
  .msg-print__fig figcaption { font-size: 9pt; margin-top: 2pt; }
  .msg-print__file { font-size: 9.5pt; margin: 4pt 0; }
}
</style>
