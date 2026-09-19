<template>
  <aside v-if="pane.taskId" class="thread live-pane" aria-label="Thread">
    <header>
      <strong>Thread <code>{{ pane.taskId.slice(0, 8) }}</code></strong>
      <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;min-width:0">
        <VerbositySelector />
        <NuxtLink class="btn ghost" :to="'/t/' + pane.taskId">Open</NuxtLink>
        <button class="btn ghost" type="button" @click="pane.close()">Close</button>
      </div>
    </header>
    <div class="pinned-root">
      <MessageCard v-if="pane.thread.root" :msg="pane.thread.root" />
      <p v-else-if="!pane.loading" class="muted">Empty thread.</p>
    </div>
    <MessageComposer
      omnibox
      placeholder="Reply — Enter to send · /search to filter"
      :busy="pane.sending"
      @send="onSend"
      @search="pane.setSearch"
    />
    <div class="feed-body">
      <p v-if="pane.error" class="muted">{{ pane.error }}</p>
      <LiveFeed
        label="Replies, newest first"
        :rows="replies"
        :has-older="false"
        :loading="pane.loading"
        :search="pane.search"
        :last-live="pane.lastLive"
        @clear-search="pane.setSearch('')"
      />
    </div>
  </aside>
</template>

<script setup lang="ts">
import { useLiveFeed } from '~/stores/live'
import { useThreadStore } from '~/stores/thread'
import { applyVerbosity } from '~/utils/verbosity.mjs'

/* 013 US3: pinned root (oldest of the task_id), reply Omnibox, newest-first replies, live. */
const pane = useLiveFeed('pane')
const thread = useThreadStore()
const replies = computed(() => applyVerbosity(pane.thread.replies, thread.verbosity))

async function onSend(text: string, _parent?: string, files?: File[]) {
  await pane.send(text, files || [])
}
</script>
