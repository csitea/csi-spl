<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>{{ tr('nav.threads') }}</h2>
      <span class="muted">{{ tr('pages.index.subtitle') }}</span>
    </header>
    <div ref="listTop" class="feed-body">
      <button v-if="pill" class="btn new-pill" type="button" :aria-label="tr('feed.new_pill_label')" data-testid="new-pill" @click="jump">
        ↑ {{ tr('feed.new_pill', { n: pill }) }}
      </button>
      <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
      <ViewTokenForm v-if="viewer.needsToken" :detail="viewer.doorDetail" @saved="viewer.loadThreads()" />
      <p v-else-if="!viewer.loading && !viewer.error && viewer.threads.length === 0" class="muted">
        {{ tr('pages.index.empty') }}
      </p>
      <a
        v-for="t in viewer.threads"
        :key="t.task_id"
        class="thread-row"
        :data-key="t.task_id"
        :href="localePath('/t/' + t.task_id)"
        @click.exact.prevent="pane.open(t.task_id)"
      >
        <div class="msg-meta">
          <span class="msg-author">{{ t.participants.join(', ') || t.task_id }}</span>
          <KindBadge v-for="k in Object.keys(t.kinds)" :key="k" :kind="k" />
          <span class="msg-time">{{ formatTs(t.last_ts, locale) }}</span>
        </div>
        <div class="thread-subject">{{ t.subject }}</div>
        <small class="muted">{{ tr('pages.index.messages', { n: t.count }, t.count) }}</small>
      </a>
      <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">{{ tr('pages.index.older') }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useViewerStore } from '~/stores/viewer'
import { useLiveFeed } from '~/stores/live'
import { formatTs } from '~/utils/channel-feed.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useScrollAnchor } from '~/composables/useScrollAnchor'

const viewer = useViewerStore()
/* `tr`, not `t`: the thread rows below are iterated as `t` */
const { t: tr, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
/* 013 US3: a click opens the thread in the right pane; the link still works for new tabs */
const pane = useLiveFeed('pane')
/* deep link: /?thread=<task_id> opens the right pane. `/` is prerendered, so
   the query only exists once hydration settles (useSettledQuery). */
const thread = useSettledQuery('thread')
onMounted(() => {
  watch(thread.value, (id) => {
    if (/^[0-9a-f-]{36}$/i.test(id)) void pane.open(id)
  }, { immediate: true })
})
/* 013 US7: newest activity on top, live over the socket; a reader scrolled down keeps their place */
const listTop = ref<HTMLElement | null>(null)
const { pill, jump } = useScrollAnchor(listTop, () => viewer.threads.map((r) => r.task_id))
onMounted(async () => {
  await viewer.loadThreads()
  viewer.follow()
})
onUnmounted(() => viewer.unfollow())
</script>
