<template>
  <div class="feed-col">
    <header class="feed-header">
      <h2>{{ tr('nav.threads') }}</h2>
      <span class="muted">{{ tr('pages.index.subtitle') }}</span>
    </header>
    <div ref="listTop" class="feed-body">
      <div class="new-pill-wrap">
        <button v-if="pill" class="btn new-pill" type="button" :aria-label="tr('feed.new_pill_label')" data-testid="new-pill" @click="jump">
          ↑ {{ tr('feed.new_pill', { n: pill }) }}
        </button>
      </div>
      <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
      <ViewTokenForm v-if="viewer.needsToken" :detail="viewer.doorDetail" @saved="viewer.loadThreads()" />
      <!-- CLE-3433: "No threads yet." is the right words for a MEMBER with
           an empty list and the wrong ones for a visitor who is simply not
           signed in - it reads as an app with nothing in it. The view-door
           branch above still wins, so an anonymous reader holding a token
           is unaffected. -->
      <SignedOutNotice v-else-if="signedOut && !viewer.loading && !viewer.error && viewer.threads.length === 0" />
      <p v-else-if="!viewer.loading && !viewer.error && viewer.threads.length === 0" class="muted">
        {{ tr('pages.index.empty') }}
      </p>
      <a
        v-for="t in viewer.threads"
        :key="t.task_id"
        class="thread-row"
        :data-key="t.task_id"
        :data-ts="t.last_ts || undefined"
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
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isSignedOutVisitor, shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'

const viewer = useViewerStore()
const session = useSessionStore()
const api = useSpoolApi()
/* CLE-3433: a settled signed-out probe, so the notice never flashes at a human mid-probe */
const signedOut = computed(() => isSignedOutVisitor(session.state, api.mock))
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
/* W5 (GRK-3377): `/` opened the hub socket while signed out - viewer.follow()
   calls live.ensure(), which constructs and connects a client, and the hub
   answers the upgrade 401, so a signed-out visitor got 4 attempts plus backoff
   (measured on both apexes, tree e52e250). The read and the follow now wait for
   a member session, on the same predicate as the rest of the shell; a sign-in
   flips the same store, so a human who signs in gets both with no reload. */
let listStarted = false
watch(() => api.mock || String(session.state) === 'in', (ready) => {
  if (!ready || listStarted) return
  listStarted = true
  /* the mock tenant has no door and no socket: it reads at once and follows
     nothing (viewer.follow() returns early there) */
  void viewer.loadThreads().then(() => {
    if (shouldOpenHubSocket(session.state, api.mock)) viewer.follow()
  })
}, { immediate: true })
onUnmounted(() => viewer.unfollow())
</script>
