<template>
  <template v-for="(p, j) in runs" :key="j">
    <code v-if="p.type === 'inline'" class="code-inline">{{ p.text }}</code>
    <strong v-else-if="p.type === 'strong'">{{ p.text }}</strong>
    <em v-else-if="p.type === 'em'">{{ p.text }}</em>
    <span v-else-if="p.type === 'mention'" class="mention" :title="mentionDisplay(p.text, people.names.value).title || undefined">{{ mentionDisplay(p.text, people.names.value).text }}</span>
    <a
      v-else-if="p.type === 'link'"
      class="msg-link"
      :class="{ 'msg-link--event': linkKind(p) === 'event' }"
      :href="hrefOf(p.href)"
      :title="linkTitle(p)"
      :data-test="linkTitle(p) ? 'app-link' : undefined"
      :data-kind="linkKind(p) || undefined"
      :target="openOf(p.href).target"
      :rel="openOf(p.href).rel"
      draggable="false"
      @pointerdown="onPointerDown"
      @pointerup="onPointerUp($event, p.href)"
      @pointercancel="onPointerCancel"
      @click.stop="onLink($event, p.href)"
      @dblclick.stop
      @keydown.enter.stop
    >{{ linkText(p) }}</a>
    <template v-else>
      <!-- SPL-1009: a member id in plain text ("HUM-10 needs you in ...") reads the name -->
      <!-- CLE-77908: an ISO time with a zone reads in the viewer's zone; the hover keeps it as written -->
      <!-- t1 179ef3f9: a short 10:45Z too, on the day of the message that wrote it (MessageBody `at`) -->
      <template v-for="(tr, i) in bodyTimeRuns(p.text, bodyAt(), labelMod?.withShortTimes)" :key="i"><time v-if="tr.iso" class="msg-time" :datetime="tr.dt || tr.iso" :title="tr.iso" data-test="body-time">{{ tr.text }}</time><template v-else><template v-for="(r, k) in namedRuns(tr.text, people.names.value)" :key="k"><span v-if="r.title" class="person-name" :title="r.title">{{ r.text }}</span><template v-else>{{ r.text }}</template></template></template></template>
    </template>
  </template>
</template>

<script setup lang="ts">
import { mentionDisplay, namedRuns } from '~/utils/channel-feed.mjs'
import { linkOpen, messageLinkClick, messageLinkPointerCancel, messageLinkPointerDown, messageLinkPointerUp } from '~/utils/link-target.mjs'
import { docsLinkHref } from '~/utils/docs.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { appLinkText, useAppLinkLabel } from '~/composables/useAppLinkLabel'
import { BODY_TIME_AT, bodyTimeRuns } from '~/utils/body-times.mjs'

/* One run of a message body. Text interpolation only: a wiki region never
   becomes HTML, same rule as the rest of the body.
   Internal links (relative, or the same origin) stay in this tab and the
   router moves the SPA. Everything else is a new tab with no opener
   (link-target.mjs). A click, double-click or Enter on the link does not
   also open the row's topic.
   SPL-1291: a link to a doc of this repository (cnf repoWebUrl) or a bare
   repo-relative .md path opens our own /docs/<path> (docsLinkHref). */
const props = defineProps<{ parts: { type: string, text: string, href?: string }[] }>()
const people = useHumanNames()
const labelMod = useAppLinkLabel()
/* t1 179ef3f9: the message timestamp (MessageBody) is the day of a short
   10:45Z; withShortTimes arrives with the lazy label chunk */
const bodyAt = inject<() => unknown>(BODY_TIME_AT, () => undefined)
const pub = useRuntimeConfig().public
const requestURL = useRequestURL()
const router = useRouter()
const runs = computed(() => props.parts.map((p) => {
  if (p.type !== 'link' || !p.href) return p
  const doc = docsLinkHref(p.href, pub.repoWebUrl)
  return doc ? { ...p, href: doc } : p
}))

function originNow() {
  if (import.meta.client) return window.location.origin
  return requestURL.origin
}

function hrefNow() {
  if (import.meta.client) return window.location.href
  return requestURL.href
}

function openOf(href?: string): { target?: string, rel?: string } {
  if (!href) return {}
  const open = linkOpen(href, originNow())
  if (!open || open.internal) return {}
  return { target: open.target, rel: open.rel }
}

/* The href the anchor carries: an internal www or http link to this site is
   rewritten to its canonical https product URL (SPL-951 regression), so it
   loads even before any www DNS exists; an external link is left as written. */
function hrefOf(href?: string): string | undefined {
  if (!href) return href
  const open = linkOpen(href, originNow())
  return open && open.internal ? open.href : href
}

/* A bare URL of this app reads as `topic: <8 hex>` (and the workspace in
   front, when it is another one). The chunk is lazy. Until it arrives the
   address stays. An author-written label is not an address, so it stays. */
function labelOf(href?: string, text?: string) {
  const m = labelMod.value
  if (!m || !href || !text || !m.linkTextIsAddress(text)) return null
  return m.appLinkLabel(href, m.appLinkLabelContext(hrefNow(), pub))
}

function linkText(p: { text: string, href?: string }) {
  const l = labelOf(p.href, p.text)
  return l && labelMod.value ? appLinkText(labelMod.value, l) : p.text
}

/* 'event' for a calendar event link (t1 9dec05c3): it reads as a chip */
function linkKind(p: { text: string, href?: string }) {
  const l = labelOf(p.href, p.text)
  return l && labelMod.value?.labelEvent(l) ? 'event' : ''
}

function linkTitle(p: { text: string, href?: string }) {
  return labelOf(p.href, p.text)?.title || undefined
}

/* a phone drops the click on a link inside the card; pointerup still fires
   and opens it. draggable=false keeps the browser from taking the finger as
   a link drag (that cancels the pointer stream, SPL-1034). */
function openBlank(url: string) {
  const w = window.open(url, '_blank', 'noopener,noreferrer')
  if (w) w.opener = null
  return Boolean(w)
}

function onPointerDown(e: PointerEvent) { messageLinkPointerDown(e) }
function onPointerCancel(e: PointerEvent) { messageLinkPointerCancel(e) }
function onPointerUp(e: PointerEvent, href?: string) {
  if (!href || !import.meta.client) return
  messageLinkPointerUp(e, href, hrefNow(), (path) => { void router.push(path) }, openBlank)
}

function onLink(e: MouseEvent, href?: string) {
  if (!href) return
  messageLinkClick(e, href, hrefNow(), (path) => { void router.push(path) })
}
</script>

<style scoped>
.msg-link {
  color: var(--color-accent);
  text-decoration: underline;
  text-underline-offset: 2px;
  overflow-wrap: anywhere;
  unicode-bidi: isolate;
  /* manipulation: the tap is a click, not a double-tap zoom wait */
  touch-action: manipulation;
  -webkit-user-drag: none;
}
.msg-link:hover { color: var(--color-accent-pressed); }
/* t1 9dec05c3: a calendar event link reads as a chip */
.msg-link--event {
  display: inline-block;
  padding: 0 6px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  text-decoration: none;
}
/* .code-inline is global (main.css): the same look in every body */
em { font-style: italic; }
</style>
