<!-- Owner HUM-10 (t1 efde25bb): on the Docs (Qto) page the left panel is a
     file tree of the workspace documents instead of the channel list. The
     sidebar keeps its icon rail only (railLinkSection: /workspace/docs is a
     docs section, as /docs is), and this is the two panes: the tree
     (QtoFileTree) left, the page (WorkspaceDocsPage) right, each scrolling
     on its own. At <= 820 px the tree is not drawn: the page itself is the
     phone's drill-down (WorkspaceDocsPage, t1 8bf89f96). -->
<template>
  <div class="wsdocs-layout" data-test="ws-docs-layout">
    <div id="qto-file-tree" class="wsdocs-layout__tree">
      <QtoFileTree
        v-if="page"
        :docs="page.docs"
        :active="page.docId"
        :rev="page.session?.rev.value ?? 0"
        :client="client"
        @open="openFromTree"
        @renamed="renamedFromTree"
        @deleted="deletedFromTree"
        @new-doc="page.newOpen = true"
        @refresh="page.refreshDocs()"
      />
    </div>
    <WorkspaceDocsPage ref="page" class="wsdocs-layout__page" />
  </div>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import WorkspaceDocsPage from './WorkspaceDocsPage.vue'
import QtoFileTree from './QtoFileTree.vue'
import { useDocTree } from './-doctree-api'

const route = useRoute()
const client = useDocTree()
const page = ref<InstanceType<typeof WorkspaceDocsPage> | null>(null)

/** the tree's Rename: the list (and the open document's title and rev) take the hub's answer */
function renamedFromTree(doc: string, title: string, rev: number) {
  const p = page.value
  if (!p) return
  p.docs = p.docs.map((d) => (d.id === doc ? { ...d, title, rev } : d))
  if (doc === p.docId && p.session) p.session.rev.value = rev
}

/** the tree's Delete: the list drops it; the open document gone, the first one left opens */
function deletedFromTree(doc: string) {
  const p = page.value
  if (!p) return
  p.docs = p.docs.filter((d) => d.id !== doc)
  if (doc === p.docId) void p.pick(p.docs[0]?.id ?? '')
}

/** a tree row: the open document's section scrolls into view; anything else opens through the page */
function openFromTree(doc: string, item: string) {
  const p = page.value
  if (!p) return
  const here = doc === p.docId && route.query.view !== 'grid'
  if (here && item) {
    const id = 'ws-doc-' + item
    document.getElementById(id)?.scrollIntoView({ block: 'start' })
    history.replaceState(history.state, '', '#' + id)
  } else if (item) void p.openAt(doc, item)
  else if (doc !== p.docId || route.query.view === 'grid') void p.pick(doc)
}
</script>

<style scoped>
.wsdocs-layout {
  flex: 1 1 auto;
  display: flex;
  min-width: 0;
  min-height: 0;
  height: 100%;
}
.wsdocs-layout__tree {
  flex: 0 0 260px;
  min-width: 0;
  min-height: 0;
  overflow-x: clip;
  overflow-y: auto;
  border-inline-end: 1px solid var(--color-border);
  background: var(--color-bg);
}
.wsdocs-layout__page { flex: 1 1 auto; }
@media (max-width: 820px) {
  .wsdocs-layout__tree { display: none; }
}
</style>
