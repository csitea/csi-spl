<!-- Internal link previews (owner, prd t1 topic e1f8f797): under a message
     that links a topic or a message of this workspace, a small Slack-like
     card per link - what it is, its title (first 100 characters), up to
     three lines of what it says, who wrote it and when. The whole card opens
     the link, the same way the link itself does (same tab, the router).
     MessageBody loads this component lazily, only when the reader's own
     "Link previews" setting is on and the body holds such a link. The cards
     come from the hub as the reader (POST /v1/view/previews, one batch for
     every body on screen); an object the reader may not read has no card,
     so its link stays a plain link. -->
<template>
  <div v-if="cards.length" class="link-previews" data-test="link-previews">
    <a
      v-for="c in cards"
      :key="c.id"
      class="link-preview"
      :href="hrefOf(c.href)"
      draggable="false"
      data-test="link-preview"
      :data-kind="c.kind"
      :data-id="c.id"
      @pointerdown="onPointerDown"
      @pointerup="onPointerUp($event, c.href)"
      @pointercancel="onPointerCancel"
      @click.stop="onLink($event, c.href)"
      @dblclick.stop
      @keydown.enter.stop
    >
      <span class="link-preview__kind">{{ t(c.kind === 'topic' ? 'link_preview.topic' : 'link_preview.message') }}<template v-if="c.archived"> · {{ t('archive.badge') }}</template></span>
      <span class="link-preview__title" data-test="link-preview-title">{{ c.title || '…' }}</span>
      <span v-if="c.excerpt" class="link-preview__excerpt" data-test="link-preview-excerpt">{{ c.excerpt }}</span>
      <span class="link-preview__meta">
        <span v-if="c.from" class="link-preview__from">{{ shownPerson(c.from, '', people.names.value) }}</span>
        <time v-if="c.ts" class="link-preview__ts" :datetime="c.ts" :title="formatIsoTs(c.ts)">{{ formatMsgListTs(c.ts) }}</time>
      </span>
    </a>
  </div>
</template>

<script lang="ts">
import { ref } from 'vue'
import { createPreviewLookup } from '~/utils/link-preview-lookup.mjs'

/* one lookup per tab: every body on screen shares its batches and its cache */
const version = ref(0)
let lookup: ReturnType<typeof createPreviewLookup> | null = null
</script>

<script setup lang="ts">
import { formatIsoTs, formatMsgListTs, shownPerson } from '~/utils/channel-feed.mjs'
import { linkOpen, messageLinkClick, messageLinkPointerCancel, messageLinkPointerDown, messageLinkPointerUp } from '~/utils/link-target.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { useSpoolApi } from '~/composables/useSpoolApi'

type Card = { id: string, href: string, kind: string, title: string, excerpt: string, from: string, ts: string, archived: boolean }
/* previewLinks is a lazy client method (spool-client-lazy.mjs, view-v1 section 4.7) */
type PreviewApi = { previewLinks(ids: string[]): Promise<unknown> }

const props = defineProps<{ refs: { id: string, href: string }[] }>()
const { t } = useI18n({ useScope: 'global' })
const people = useHumanNames()
const router = useRouter()
const api = useSpoolApi() as unknown as PreviewApi

if (!lookup) {
  lookup = createPreviewLookup({
    fetchPreviews: (ids) => api.previewLinks(ids),
    onChange: () => { version.value += 1 },
  })
}
const tab = lookup

watch(() => props.refs.map((r) => r.id).join(','), () => {
  if (import.meta.client) tab.want(props.refs.map((r) => r.id))
}, { immediate: true })

const cards = computed<Card[]>(() => {
  void version.value
  const out: Card[] = []
  for (const r of props.refs) {
    const h = tab.get(r.id) as Record<string, unknown> | null
    if (!h) continue
    out.push({
      id: r.id,
      href: r.href,
      kind: String(h.kind || ''),
      title: String(h.title || ''),
      excerpt: String(h.excerpt || ''),
      from: String(h.from || ''),
      ts: String(h.ts || ''),
      archived: h.archived === true,
    })
  }
  return out
})

/* the link's own rules (MessageRuns.vue): canonical href, same tab, router */
function hrefOf(href: string): string {
  const open = linkOpen(href, window.location.origin)
  return open && open.internal ? open.href : href
}
function openBlank(url: string) {
  const w = window.open(url, '_blank', 'noopener,noreferrer')
  if (w) w.opener = null
  return Boolean(w)
}
function onPointerDown(e: PointerEvent) { messageLinkPointerDown(e) }
function onPointerCancel(e: PointerEvent) { messageLinkPointerCancel(e) }
function onPointerUp(e: PointerEvent, href: string) {
  messageLinkPointerUp(e, href, window.location.href, (path) => { void router.push(path) }, openBlank)
}
function onLink(e: MouseEvent, href: string) {
  messageLinkClick(e, href, window.location.href, (path) => { void router.push(path) })
}
</script>

<style scoped>
.link-previews {
  display: grid;
  gap: 6px;
  margin-top: 6px;
  min-width: 0;
  max-width: 100%;
}
.link-preview {
  display: grid;
  gap: 2px;
  min-width: 0;
  max-width: 36rem;
  padding: 6px 10px;
  border-inline-start: 3px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: inherit;
  text-decoration: none;
  touch-action: manipulation;
  -webkit-user-drag: none;
}
.link-preview:hover,
.link-preview:focus-visible { border-inline-start-color: var(--color-accent); }
.link-preview__kind {
  font-size: 0.6875rem;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--color-muted);
}
.link-preview__title {
  font-weight: 600;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.link-preview__excerpt {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 3;
  line-clamp: 3;
  overflow: hidden;
  white-space: pre-line;
  overflow-wrap: anywhere;
  font-size: 0.8125rem;
}
.link-preview__meta {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  font-size: 0.75rem;
  color: var(--color-muted);
}
</style>
