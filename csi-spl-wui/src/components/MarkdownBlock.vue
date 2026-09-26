<!-- Rendered markdown between the start and stop marker (SPL-73): a fence
     tagged md / markdown (isMarkdownLang, code-blocks.mjs).

     markdown.mjs turns the source into an allow-listed tree of plain nodes;
     this renders that tree with h(), never v-html, so nothing in a body can
     become markup. The engine is a lazy chunk: the first render (and the
     server's) is the source as plain text, which is also what stays when the
     chunk fails to load. Tables scroll inside the block, never the page.
     Show source flips to the text as written (spec 040 FR-MD-004). -->
<template>
  <div class="md-block" data-testid="md-block" :data-rendered="tree ? 'true' : 'false'">
    <button
      type="button"
      class="md-block__toggle"
      data-testid="md-block-toggle"
      :aria-pressed="showSource"
      @click.stop="showSource = !showSource"
    >{{ showSource ? t('markdown.show_rendered') : t('markdown.show_source') }}</button>
    <MdNodes v-if="tree && !showSource" :nodes="tree" />
    <p v-else class="md-src" dir="auto">{{ text }}</p>
  </div>
</template>

<script setup lang="ts">
import { h, type FunctionalComponent, type VNodeChild } from 'vue'
import { linkAttrs } from '~/utils/link-target.mjs'
import type { MdNode } from '~/utils/markdown.mjs'

const props = defineProps<{ text: string }>()
const { t } = useI18n({ useScope: 'global' })
const showSource = ref(false)

const tree = shallowRef<MdNode[] | null>(null)
let tags: Set<string> = new Set()
/* only the newest render may write; an older one that resolves late is dropped */
let seq = 0

watch(
  () => props.text,
  async (src) => {
    const mine = ++seq
    tree.value = null
    if (!import.meta.client) return
    try {
      const { markdownTree, TAGS } = await import('~/utils/markdown.mjs')
      if (mine !== seq) return
      tags = TAGS
      tree.value = markdownTree(src)
    } catch {
      /* the source stays readable */
    }
  },
  { immediate: true },
)


/* a link opens and the row under it does not also open its topic, select,
   or start an edit (the same rule as MessageBody's links) */
const stop = (e: Event) => e.stopPropagation()

function node(n: MdNode): VNodeChild {
  if (typeof n === 'string') return n
  const kids = n.children.map(node)
  // the tree is allow-listed already; the check here keeps it that way
  if (!tags.has(n.tag)) return kids
  if (n.tag === 'a') {
    return h('a', {
      class: 'msg-link',
      href: n.attrs.href,
      title: n.attrs.title,
      ...linkAttrs(n.attrs.href),
      onClick: stop,
      onDblclick: stop,
      onKeydown: (e: KeyboardEvent) => { if (e.key === 'Enter') e.stopPropagation() },
    }, kids)
  }
  if (n.tag === 'table') return h('div', { class: 'md-table' }, [h('table', null, kids)])
  const attrs: Record<string, string> = {}
  for (const k of ['start', 'data-align', 'data-lang']) if (n.attrs[k]) attrs[k] = n.attrs[k]
  return h(n.tag, attrs, kids)
}

const MdNodes: FunctionalComponent<{ nodes: MdNode[] }> = (p) => p.nodes.map(node)
MdNodes.props = ['nodes']
</script>

<style scoped>
.md-block {
  min-width: 0;
  max-width: 100%;
  overflow-wrap: anywhere;
  line-height: 1.45;
}
.md-src {
  margin: 0;
  white-space: pre-wrap;
}
.md-block__toggle {
  float: inline-end;
  margin: 0 0 0.25em 0.5em;
  font-size: 0.75rem;
  padding: 0.1em 0.4em;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-muted);
  cursor: pointer;
}
.md-block__toggle:hover { color: var(--color-fg); }
.md-block :deep(p),
.md-block :deep(ul),
.md-block :deep(ol),
.md-block :deep(blockquote),
.md-block :deep(pre),
.md-block :deep(.md-table),
.md-block :deep(h1),
.md-block :deep(h2),
.md-block :deep(h3),
.md-block :deep(h4),
.md-block :deep(h5),
.md-block :deep(h6) {
  margin: 0 0 0.4em;
}
.md-block > :deep(:last-child) { margin-bottom: 0; }
/* a table or quote never slides under the floated toggle */
.md-block :deep(.md-table),
.md-block :deep(pre),
.md-block :deep(blockquote) { clear: both; }
.md-block :deep(h1),
.md-block :deep(h2),
.md-block :deep(h3),
.md-block :deep(h4),
.md-block :deep(h5),
.md-block :deep(h6) {
  color: var(--color-heading);
  font-weight: 600;
  line-height: 1.25;
}
/* a card is a glance: headings step up gently from the body size */
.md-block :deep(h1) { font-size: 1.3em; }
.md-block :deep(h2) { font-size: 1.2em; }
.md-block :deep(h3) { font-size: 1.1em; }
.md-block :deep(h4),
.md-block :deep(h5),
.md-block :deep(h6) { font-size: 1em; }
.md-block :deep(ul),
.md-block :deep(ol) { padding-left: 1.5em; }
.md-block :deep(li + li) { margin-top: 0.15em; }
.md-block :deep(blockquote) {
  padding-left: 0.75em;
  border-left: 3px solid var(--color-border-strong);
  color: var(--color-muted);
}
.md-block :deep(hr) {
  border: 0;
  border-top: 1px solid var(--color-border);
  margin: 0.5em 0;
}
.md-block :deep(code) {
  font-family: var(--font-mono);
  font-size: 0.9em;
  background: var(--color-bg-2);
  padding: 1px 4px;
  border-radius: var(--radius-sm);
}
.md-block :deep(pre) {
  background: var(--color-bg-2);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 0.5em 0.75em;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.md-block :deep(pre code) { background: none; padding: 0; }
.md-block :deep(.md-table) {
  max-width: 100%;
  overflow-x: auto;
}
.md-block :deep(table) {
  border-collapse: collapse;
  font-size: 0.95em;
}
.md-block :deep(th),
.md-block :deep(td) {
  border: 1px solid var(--color-border);
  padding: 0.25em 0.6em;
  text-align: left;
  vertical-align: top;
  overflow-wrap: normal;
}
.md-block :deep(th) { background: var(--color-bg-2); font-weight: 600; }
.md-block :deep([data-align="center"]) { text-align: center; }
.md-block :deep([data-align="right"]) { text-align: right; }
.md-block :deep(.msg-link) {
  color: var(--color-accent);
  text-decoration: underline;
  text-underline-offset: 2px;
  unicode-bidi: isolate;
}
.md-block :deep(.msg-link:hover) { color: var(--color-accent-pressed); }
</style>
