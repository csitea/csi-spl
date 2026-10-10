<!-- Spec 113 T006: /workspace/docs, the workspace documents (an outline and a
     grid over one tree). The route record lives in the entry chunk, so this
     page is a shell: the body, both views and print load on demand, and the
     entry's record names one chunk and no stylesheet (the initial-chunk
     budget, spec 9g: an initial JS delta over 100 B fails). The body is the
     file tree and the page (WorkspaceDocsLayout, t1 efde25bb). -->
<template>
  <WorkspaceDocsLayout />
</template>

<script setup lang="ts">
import { defineAsyncComponent } from 'vue'

const WorkspaceDocsLayout = defineAsyncComponent(() => import('~/components/workspace-docs/WorkspaceDocsLayout.vue'))
</script>
