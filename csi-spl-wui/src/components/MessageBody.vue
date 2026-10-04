<template>
  <div class="msg-body">
    <MarkdownBlock v-if="mdSource !== null" v-show="mdOn" :text="mdSource" bare @rendered="mdOn = $event" />
    <template v-for="(b, i) in (mdOn ? [] : blocks)" :key="i">
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
    <LinkPreviewsLazy v-if="!noPreviews && previews.length" :refs="previews" />
  </div>
</template>

<script setup lang="ts">
import { isMarkdownLang, looksLikeMarkdown, markdownSource, parseBody } from '~/utils/code-blocks.mjs'
import MessageRuns from '~/components/MessageRuns.vue'
import { LinkPreviewsLazy, useLinkPreviewRefs } from '~/composables/useLinkPreviewRefs'

/* Slack-style ``` blocks and `inline code`; every string is text-interpolated,
   never markup. A fenced block is CodeBlock.vue (preview, highlighting, the
   open control and the dialog); inline spans stay here, where they belong.
   A plain link is http, https or mailto; a wiki markdown link
   may also be relative. Same-origin and relative links stay in this tab
   (link-target.mjs). A click, double-click or Enter on the link stops here,
   so the link opens and the row does not also open its topic, select, or
   start an edit.
   A fence tagged md / markdown is the markdown start/stop marker (SPL-73):
   MarkdownBlock renders it, and loads markdown-it itself, lazily, so
   isMarkdownLang comes from code-blocks.mjs, never from markdown.mjs.
   SPL-975 (owner, 2026-09-26): markdown renders WITHOUT a fence too. A body
   whose text outside ``` blocks holds markdown (looksLikeMarkdown), or any
   body when `markdown` is set (an issue description), renders whole through
   MarkdownBlock's bare mode; until that lazy chunk has rendered, and when it
   fails, the blocks below stay on screen. A plain body never loads it. */
const props = defineProps<{ body: string, markdown?: boolean, noPreviews?: boolean }>()
const blocks = computed(() => parseBody(props.body))
const mdSource = computed(() => (props.markdown || looksLikeMarkdown(props.body) ? markdownSource(props.body) : null))
const mdOn = ref(false)
watch(mdSource, (v) => { if (v === null) mdOn.value = false })

/* Topic e1f8f797: a link to a topic or a message of this workspace gets a
   short preview card under the body (LinkPreviews.vue), unless the reader
   turned "Link previews" off for themselves. The cards load lazily: a body
   with no such link, or a reader with previews off, never loads them. A
   host that draws them itself (MessageCard, under its 5-row clip) passes
   no-previews. */
const previews = useLinkPreviewRefs(() => props.body)
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
.msg-quote + .msg-para,
.md-block + .msg-para,
.msg-para + .md-block,
.code-block + .md-block,
.md-block + .code-block,
.md-block + .md-block { margin-top: 4px; }
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
