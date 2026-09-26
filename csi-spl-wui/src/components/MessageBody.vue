<template>
  <div class="msg-body">
    <template v-for="(b, i) in blocks" :key="i">
      <MarkdownBlock v-if="b.type === 'code' && isMarkdownLang(b.lang)" :text="b.text" />
      <CodeBlock v-else-if="b.type === 'code'" :text="b.text" :lang="b.lang" />
      <p v-else class="msg-para">
        <template v-for="(p, j) in b.parts" :key="j">
          <code v-if="p.type === 'inline'" class="code-inline">{{ p.text }}</code>
          <strong v-else-if="p.type === 'strong'">{{ p.text }}</strong>
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
      </p>
    </template>
  </div>
</template>

<script setup lang="ts">
import { parseBody } from '~/utils/code-blocks.mjs'
import { isMarkdownLang } from '~/utils/markdown.mjs'
import { mentionDisplay } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'

/* Slack-style ``` blocks and `inline code`; every string is text-interpolated,
   never markup. A fenced block is CodeBlock.vue (preview, highlighting, the
   open control and the dialog); inline spans stay here, where they belong.
   A link part (CLE-3494) is http, https or mailto only (parseBody's rule);
   its click, double-click and Enter stop here, so the link opens and the row
   under it does not also open its topic, select, or start an edit. */
const props = defineProps<{ body: string }>()
const blocks = computed(() => parseBody(props.body))
/* owner, 2026-09-26: an @human reads as their chosen name; the tag stays in the hover */
const people = useHumanNames()
</script>

<style scoped>
.msg-para {
  margin: 0;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
/* CodeBlock's root carries this scope id too, so the gap after a block stays */
.msg-para + .msg-para,
.code-block + .msg-para { margin-top: 4px; }
.msg-link {
  color: var(--color-accent);
  text-decoration: underline;
  text-underline-offset: 2px;
  overflow-wrap: anywhere;
  /* its text cannot be reordered by bidi controls around it (CLE-34987) */
  unicode-bidi: isolate;
}
.msg-link:hover { color: var(--color-accent-pressed); }
.code-inline {
  font-family: var(--font-mono);
  background: var(--color-bg-2);
  padding: 1px 4px;
  border-radius: var(--radius-sm);
  font-size: 12px;
  white-space: pre-wrap;
}
</style>
