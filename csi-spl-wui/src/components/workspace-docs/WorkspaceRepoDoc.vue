<!-- Spec 137 T023 (§4.1, owner HUM-10 t1 bed3ed0a msg 0e9d17b5: "one
     spool-hub file system"): a repository doc opened from the Qto explorer's
     Repository branch reads here, in the explorer's right pane, as /docs
     renders it (MarkdownBlock, with heading and footnote anchors). A
     relative .md link opens the linked doc here too, so the reader stays in
     the one tree; Open in Docs is the doc on /docs (its edit flow lives
     there). Read only: the repo docs become editable once they are Qto docs
     (spec 137 phase 2). -->
<template>
  <section class="wsrepo" data-test="ws-repo-doc" :data-path="path" :data-state="state" aria-labelledby="ws-repo-path">
    <header class="wsrepo__bar">
      <p id="ws-repo-path" class="wsrepo__path" data-test="ws-repo-path">{{ path }}</p>
      <NuxtLink :to="localePath('/docs/' + path)" class="btn ghost" data-test="ws-repo-open-docs">{{ t('ws_doctree.repo_open_docs') }}</NuxtLink>
    </header>
    <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'missing'" class="muted" role="alert" data-test="ws-repo-missing">{{ t('docs.not_found') }}</p>
    <p v-else-if="state !== 'ready'" class="muted" role="alert" data-test="ws-repo-failed">{{ t('ws_doctree.repo_failed') }}</p>
    <MarkdownBlock v-else :text="text" bare anchors />
  </section>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue'
import MarkdownBlock from '~/components/MarkdownBlock.vue'
import { rewriteDocsLinks } from '~/utils/docs.mjs'
import { docsBody } from '~/utils/public-docs.mjs'
import { useRepoDocs } from './-repo-docs'

const props = defineProps<{ path: string }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const repo = useRepoDocs()
const state = ref<'loading' | 'ready' | 'missing' | 'off' | 'failed'>('loading')
const text = ref('')
/* a relative .md link opens the linked doc in this pane: the explorer's ?repo= */
const here = (p: string) => localePath('/workspace/docs') + '?repo=' + encodeURI(p)
let seq = 0

watch(() => props.path, async (p) => {
  const mine = ++seq
  state.value = 'loading'
  try {
    const md = await repo.read(p)
    if (mine !== seq) return
    if (md === 'off') { state.value = 'off'; return }
    if (md === null) { state.value = 'missing'; return }
    text.value = rewriteDocsLinks(docsBody(md), p, here)
    state.value = 'ready'
  } catch {
    if (mine === seq) state.value = 'failed'
  }
}, { immediate: true })
</script>

<style scoped>
.wsrepo {
  min-width: 0;
  min-height: 0;
  overflow-y: auto;
  padding: 12px 16px 24px;
}
.wsrepo__bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 12px;
}
.wsrepo__path {
  margin: 0;
  min-width: 0;
  overflow-wrap: anywhere;
  color: var(--color-muted);
  font-size: 0.875rem;
}
</style>
