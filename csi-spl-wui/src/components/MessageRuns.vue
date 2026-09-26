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
      target="_blank"
      rel="noopener noreferrer nofollow"
      @click.stop
      @dblclick.stop
      @keydown.enter.stop
    >{{ p.text }}</a>
    <template v-else>{{ p.text }}</template>
  </template>
</template>

<script setup lang="ts">
import { mentionDisplay } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

/* One run of a message body. Text interpolation only: a wiki region never
   becomes HTML, same rule as the rest of the body. */
defineProps<{ parts: { type: string, text: string, href?: string }[] }>()
const people = useHumanNames()
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
