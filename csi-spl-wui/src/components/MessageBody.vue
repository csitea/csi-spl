<template>
  <div class="msg-body">
    <template v-for="(b, i) in blocks" :key="i">
      <MarkdownBlock v-if="b.type === 'code' && isMarkdownLang(b.lang)" :text="b.text" />
      <CodeBlock v-else-if="b.type === 'code'" :text="b.text" :lang="b.lang" />
      <h2 v-else-if="b.type === 'heading' && b.level === 1" class="msg-h"><MessageRuns :parts="b.parts" /></h2>
      <h3 v-else-if="b.type === 'heading' && b.level === 2" class="msg-h"><MessageRuns :parts="b.parts" /></h3>
      <h4 v-else-if="b.type === 'heading'" class="msg-h"><MessageRuns :parts="b.parts" /></h4>
      <ul v-else-if="b.type === 'list' && !b.ordered" class="msg-list">
        <li v-for="(item, k) in b.items" :key="k"><MessageRuns :parts="item.parts" /></li>
      </ul>
      <ol v-else-if="b.type === 'list'" class="msg-list">
        <li v-for="(item, k) in b.items" :key="k"><MessageRuns :parts="item.parts" /></li>
      </ol>
      <blockquote v-else-if="b.type === 'quote'" class="msg-quote"><MessageRuns :parts="b.parts" /></blockquote>
      <p v-else class="msg-para"><MessageRuns :parts="b.parts" /></p>
    </template>
  </div>
</template>

<script setup lang="ts">
import { parseBody } from '~/utils/code-blocks.mjs'
import { isMarkdownLang } from '~/utils/markdown.mjs'
import MessageRuns from '~/components/MessageRuns.vue'

/* Slack-style ``` blocks and `inline code`; every string is text-interpolated,
   never markup. A fenced block is CodeBlock.vue (preview, highlighting, the
   open control and the dialog); inline spans stay here, where they belong.
   A link part (CLE-3494) is http, https or mailto only (parseBody's rule);
   its click, double-click and Enter stop here, so the link opens and the row
   under it does not also open its topic, select, or start an edit. */
const props = defineProps<{ body: string }>()
const blocks = computed(() => parseBody(props.body))
</script>

<style scoped>
.msg-para {
  margin: 0;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
/* CodeBlock's root carries this scope id too, so the gap after a block stays */
.msg-para + .msg-para,
.code-block + .msg-para,
.msg-h + .msg-para,
.msg-list + .msg-para,
.msg-quote + .msg-para { margin-top: 4px; }
.msg-h {
  margin: 8px 0 2px;
  font-size: 1rem;
  line-height: 1.3;
  overflow-wrap: anywhere;
}
h3.msg-h { font-size: 0.9375rem; }
h4.msg-h { font-size: 0.875rem; }
.msg-list {
  margin: 4px 0;
  padding-inline-start: 1.25em;
  min-width: 0;
  max-width: 100%;
}
.msg-quote {
  margin: 4px 0;
  padding-inline-start: 8px;
  border-inline-start: 2px solid var(--color-border);
  overflow-wrap: anywhere;
}
</style>
