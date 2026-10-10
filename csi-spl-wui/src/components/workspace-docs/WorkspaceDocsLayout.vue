<!-- Owner HUM-10 (t1 efde25bb): on the Docs (Qto) page the left panel is a
     file tree of the workspace documents instead of the channel list. The
     sidebar keeps its icon rail only (railLinkSection: /workspace/docs is a
     docs section, as /docs is), and this is the two panes: the tree
     (QtoFileTree) left, the page (WorkspaceDocsPage) right, each scrolling
     on its own. At <= 820 px the tree folds above the page behind its
     Documents button and closes once a row opens something. -->
<template>
  <div class="wsdocs-layout" :class="{ 'wsdocs-layout--tree-open': treeOpen }" data-test="ws-docs-layout">
    <button
      type="button"
      class="wsdocs-layout__toggle"
      data-test="qto-file-tree-toggle"
      :aria-expanded="treeOpen ? 'true' : 'false'"
      aria-controls="qto-file-tree"
      @click="treeOpen = !treeOpen"
    >
      <UiIcon name="folder" :size="18" />
      <span>{{ t('ws_doctree.title') }}</span>
    </button>
    <div id="qto-file-tree" class="wsdocs-layout__tree">
      <QtoFileTree
        v-if="page"
        :docs="page.docs"
        :active="page.docId"
        :rev="page.session?.rev.value ?? 0"
        :client="client"
        @open="openFromTree"
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

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const client = useDocTree()
const page = ref<InstanceType<typeof WorkspaceDocsPage> | null>(null)
const treeOpen = ref(false)

/** a tree row: the open document's section scrolls into view; anything else opens through the page */
function openFromTree(doc: string, item: string) {
  const p = page.value
  treeOpen.value = false
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
.wsdocs-layout__toggle { display: none; }
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
  .wsdocs-layout { flex-direction: column; }
  .wsdocs-layout__toggle {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    align-self: flex-start;
    min-height: 44px;
    margin: 6px 12px 0;
    padding: 6px 12px;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-sm, 8px);
    background: none;
    color: var(--color-fg);
    font: inherit;
    cursor: pointer;
  }
  .wsdocs-layout__tree { display: none; flex: none; max-height: 50dvh; border-inline-end: 0; border-bottom: 1px solid var(--color-border); }
  .wsdocs-layout--tree-open .wsdocs-layout__tree { display: block; }
}
</style>
