<template>
  <template v-for="(p, j) in parts" :key="j">
    <code v-if="p.type === 'inline'" class="code-inline">{{ p.text }}</code>
    <strong v-else-if="p.type === 'strong'">{{ p.text }}</strong>
    <em v-else-if="p.type === 'em'">{{ p.text }}</em>
    <span v-else-if="p.type === 'mention'" class="mention" :title="mentionDisplay(p.text, people.names.value).title || undefined">{{ mentionDisplay(p.text, people.names.value).text }}</span>
    <a
      v-else-if="p.type === 'link'"
      class="msg-link"
      :href="p.href"
      :target="openOf(p.href).target"
      :rel="openOf(p.href).rel"
      @click.stop="onLink($event, p.href)"
      @dblclick.stop
      @keydown.enter.stop
    >{{ p.text }}</a>
    <template v-else>{{ p.text }}</template>
  </template>
</template>

<script setup lang="ts">
import { mentionDisplay } from '~/utils/channel-feed.mjs'
import { followSameTabLink, linkOpen } from '~/utils/link-target.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

/* One run of a message body. Text interpolation only: a wiki region never
   becomes HTML, same rule as the rest of the body.
   Internal links (relative, or the same origin) stay in this tab and the
   router moves the SPA. Everything else is a new tab with no opener
   (link-target.mjs). A click, double-click or Enter on the link does not
   also open the row's topic. */
defineProps<{ parts: { type: string, text: string, href?: string }[] }>()
const people = useHumanNames()
const requestURL = useRequestURL()
const router = useRouter()

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

function onLink(e: MouseEvent, href?: string) {
  if (!href) return
  followSameTabLink(e, href, hrefNow(), (path) => { void router.push(path) })
}
</script>

<style scoped>
.msg-link {
  color: var(--color-accent);
  text-decoration: underline;
  text-underline-offset: 2px;
  overflow-wrap: anywhere;
  unicode-bidi: isolate;
}
.msg-link:hover { color: var(--color-accent-pressed); }
.code-inline {
  font-family: var(--font-mono);
  background: var(--color-bg-2);
  padding: 1px 4px;
  border-radius: var(--radius-sm);
  font-size: 0.75rem;
  white-space: pre-wrap;
}
em { font-style: italic; }
</style>
