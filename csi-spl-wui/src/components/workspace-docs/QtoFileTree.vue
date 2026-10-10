<!-- Owner HUM-10 (t1 efde25bb): the Docs (Qto) left panel is a VS Code-like
     file tree of the workspace documents, not the channel list. Each
     document is a top row; opened, it shows its sections (the spec 113
     nested-set tree, read with one subtree call per document) as nested
     rows, a section with sections under it expanding and collapsing. The
     open document is highlighted and opens expanded; a click (or Enter)
     on a document opens it, on a section opens its document at that
     section. The rows are drawn by the shared UiFileTree. -->
<template>
  <nav class="qto-tree" data-test="qto-file-tree" :aria-label="t('ws_doctree.title')">
    <h3 class="qto-tree__title">{{ t('ws_doctree.title') }}</h3>
    <UiFileTree :rows="rows" :label="t('ws_doctree.title')" @toggle="toggle" @select="select" />
  </nav>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import UiFileTree, { type FileTreeRow } from '~/components/UiFileTree.vue'
import type { DocHead, DocItem, DocTreeClient } from './-doctree-api'

const props = defineProps<{ docs: DocHead[], active: string, rev: number, client: DocTreeClient }>()
const emit = defineEmits<{ open: [doc: string, item: string] }>()
const { t } = useI18n({ useScope: 'global' })

/* row keys: d:<doc> for a document, i:<doc>:<item> for a section */
const docKey = (doc: string) => 'd:' + doc
const itemKey = (doc: string, item: string) => `i:${doc}:${item}`

const opened = ref<Set<string>>(new Set())
/* each loaded document's items grouped by parent, in outline order */
const kids = ref<Record<string, Map<string, DocItem[]>>>({})
const activeItem = ref('')

async function load(doc: string) {
  try {
    const r = await props.client.subtree(doc)
    const m = new Map<string, DocItem[]>()
    for (const it of r.items) {
      if (!it.parent) continue
      const list = m.get(it.parent) || []
      list.push(it)
      m.set(it.parent, list)
    }
    for (const list of m.values()) list.sort((a, b) => a.ord - b.ord)
    kids.value = { ...kids.value, [doc]: m }
  } catch { /* the document row stays, without sections */ }
}

function setOpen(key: string, on: boolean) {
  const s = new Set(opened.value)
  if (on) s.add(key)
  else s.delete(key)
  opened.value = s
}

const rows = computed<FileTreeRow[]>(() => {
  const out: FileTreeRow[] = []
  const walk = (doc: string, m: Map<string, DocItem[]>, parent: string, depth: number) => {
    for (const it of m.get(parent) || []) {
      const key = itemKey(doc, it.id)
      const sub = (m.get(it.id) || []).length > 0
      const open = sub && opened.value.has(key)
      /* an empty title reads as the document view's placeholder (Heading 1.1) */
      const name = it.title.trim() || t('ws_doctree.heading_placeholder', { n: it.outline })
      out.push({ key, depth, name, title: it.title.trim() ? `${it.outline} ${name}` : name, icon: sub ? 'folder' : 'list', kind: 'section', expandable: sub, open, active: doc === props.active && it.id === activeItem.value })
      if (open) walk(doc, m, it.id, depth + 1)
    }
  }
  for (const d of props.docs) {
    const key = docKey(d.id)
    const m = kids.value[d.id]
    const open = opened.value.has(key)
    out.push({ key, depth: 0, name: d.title || t('ws_doctree.default_doc_title'), icon: 'file-text', kind: 'doc', expandable: !m || (m.get(d.root) || []).length > 0, open, active: d.id === props.active && !activeItem.value })
    if (open && m) walk(d.id, m, d.root, 1)
  }
  return out
})

function toggle(key: string) {
  const on = !opened.value.has(key)
  setOpen(key, on)
  if (on && key.startsWith('d:') && !kids.value[key.slice(2)]) void load(key.slice(2))
}

function select(key: string) {
  if (key.startsWith('d:')) {
    const doc = key.slice(2)
    activeItem.value = ''
    if (!opened.value.has(key)) toggle(key)
    emit('open', doc, '')
    return
  }
  const [, doc, item] = key.split(':')
  activeItem.value = item
  if (opened.value.has(key) === false && rows.value.find((r) => r.key === key)?.expandable) setOpen(key, true)
  emit('open', doc, item)
}

/* the open document opens expanded; another document clears the section mark */
watch(() => props.active, (doc, was) => {
  if (doc !== was && was) activeItem.value = ''
  if (!doc) return
  if (!opened.value.has(docKey(doc))) setOpen(docKey(doc), true)
  if (!kids.value[doc]) void load(doc)
}, { immediate: true })

/* an edit in the open document (its rev moved on): read its sections again, once the edits settle */
let timer: ReturnType<typeof setTimeout> | undefined
watch(() => props.rev, () => {
  clearTimeout(timer)
  if (props.active) timer = setTimeout(() => { void load(props.active) }, 400)
})
onBeforeUnmount(() => clearTimeout(timer))
</script>

<style scoped>
.qto-tree { padding: 8px 4px; text-align: start; }
.qto-tree__title {
  margin: 0 0 4px;
  padding-inline-start: 8px;
  font-size: 0.8125rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--color-muted);
}
</style>
