<template>
  <div class="feed-col">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ tr('nav.topics') }}</h2>
      <span class="muted">{{ tr('pages.index.subtitle') }}</span>
    </header>
    <div ref="listTop" class="feed-body">
      <div class="new-pill-wrap">
        <button v-if="pill" class="btn new-pill" type="button" :aria-label="tr('feed.new_pill_label')" data-testid="new-pill" @click="jump">
          ↑ {{ tr('feed.new_pill', { n: pill }) }}
        </button>
      </div>
      <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
      <ViewTokenForm v-if="viewer.needsToken" :detail="viewer.doorDetail" @saved="viewer.loadTopics()" />
      <!-- W15 (spec 047): the next 3 steps for whoever may set the tenant up -->
      <FirstRunChecklist v-if="firstRunCandidate" :tenant="firstRunTenant" :topics="viewer.topics.length" />
      <p v-else-if="!viewer.loading && !viewer.error && viewer.topics.length === 0" class="muted">
        {{ tr('pages.index.empty') }}
      </p>
      <!-- SPL-986: each row has the rail's row menu, with the card's Archive /
           Delete once the hub said the viewer may (specs/041 §3.5) -->
      <div
        v-for="t in viewer.topics"
        :key="t.task_id"
        class="topic-row-wrap"
        @contextmenu.prevent="openTopicMenu(t.task_id)"
      >
      <a
        class="topic-row"
        :class="{ selected: openedTopicId === t.task_id }"
        :aria-current="openedTopicId === t.task_id ? 'true' : undefined"
        :data-key="t.task_id"
        :data-ts="t.last_ts || undefined"
        :href="localePath('/t/' + t.task_id)"
        @click.exact.prevent="pane.open(t.task_id)"
      >
        <!-- owner, prd t1 432769d8 (2026-09-26, "the avatars disappear from
             time to time"): this list was the one place a person or agent had
             no picture. The starter's avatar, in the cards' 36 px gutter. -->
        <SpoolAvatar
          v-if="topicStarter(t)"
          class="topic-row__avatar"
          data-test="topic-row-avatar"
          :id="topicStarter(t)!.id"
          :box="topicStarter(t)!.box"
        />
        <span v-else class="topic-row__avatar" aria-hidden="true" />
        <div class="topic-row__main">
        <div class="msg-meta">
          <span class="msg-author" :title="topicPeople(t.participants).title || undefined">{{ topicPeople(t.participants).text || t.task_id }}</span>
          <KindBadge v-for="k in Object.keys(t.kinds)" :key="k" :kind="k" />
          <span class="msg-time">{{ rowTime(t.last_ts) }}</span>
        </div>
        <div class="topic-subject">{{ topicRowTitle(t.subject) }}</div>
        <small class="muted">{{ tr('pages.index.messages', { n: t.count }, t.count) }}</small>
        </div>
      </a>
      <SidebarRowMenu
        :menu-id="'home:' + t.task_id"
        :name="topicRowTitle(t.subject) || t.task_id"
        :href="localePath('/t/' + t.task_id)"
        :open="rowMenu === t.task_id"
        :topic-archive="topicRowState(t.task_id)?.canArchive"
        :topic-delete="topicRowState(t.task_id)?.canDelete"
        :topic-state="topicRowState(t.task_id)?.state || ''"
        @toggle="rowMenu === t.task_id ? (rowMenu = '') : openTopicMenu(t.task_id)"
        @close="rowMenu = ''"
        @open="pane.open(t.task_id)"
        @archive="archiveTopicRow(t.task_id)"
        @delete-topic="askDeleteTopic(t.task_id)"
      />
      </div>
      <LazyTopicDeleteDialog
        v-if="topicDeleteOpen && topicDeleteMsgId"
        v-model:open="topicDeleteOpen"
        :msg-id="topicDeleteMsgId"
        @deleted="onTopicRowDeleted"
      />
      <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">{{ tr('pages.index.older') }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import { useTopicRowActions } from '~/composables/useTopicRowActions'
import { namedLine, topicStarter } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { useLiveFeed } from '~/stores/live'
import { formatMsgListTs, formatTs, phoneCardTime } from '~/utils/channel-feed.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import { bumpTopic } from '~/utils/topic-list.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useScrollAnchor } from '~/composables/useScrollAnchor'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { topicOpening } from '~/utils/view-api.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { useAccessStore } from '~/stores/access'
import { tenantSettingsVisible } from '~/utils/tenant-settings-nav.mjs'

const viewer = useViewerStore()
const channel = useChannelStore()
const topicStore = useTopicStore()
const session = useSessionStore()
const api = useSpoolApi()
/* W15 (spec 047): the first-run checklist, a lazy chunk loaded only for a
   viewer who may open Tenant settings (an admin or the business owner) */
const FirstRunChecklist = defineAsyncComponent(() => import('~/components/FirstRunChecklist.vue'))
const access = useAccessStore()
watch(() => api.mock || String(session.state) === 'in', (on) => { if (on) void access.load() }, { immediate: true })
const firstRunTenant = computed(() => String(session.claims?.t || api.tenant || ''))
const firstRunCandidate = computed(() => (api.mock || String(session.state) === 'in') && !viewer.loading &&
  !viewer.error && tenantSettingsVisible(access.me, { mock: api.mock }))
/* `tr`, not `t`: the topic rows below are iterated as `t` */
const { t: tr, locale } = useI18n({ useScope: 'global' })
/* a phone prints the row's time on the viewer's own clock, only
   HH:MM when it is from today (phoneCardTime, as on every card); desktop
   prints HH:MM, also the viewer's own clock (CLE-77908: it was UTC) */
const mobile = useMobileStack().isMobile
const rowTime = (ts: string) => (mobile.value ? phoneCardTime(formatMsgListTs(ts), ts) : formatTs(ts, locale.value))
/* SPL-976: the placeholder names the keys of the person's Behaviour setting */
const { hintFor: sk } = useSubmitKey()
function topicRowTitle(subject: string) {
  const text = topicOpening(subject)
  return text ? tr('topic.list_title', { text }) : ''
}
function topicPeople(list: readonly string[] | undefined) {
  return namedLine((list || []).join(', '), people.names.value)
}
const localePath = useLocalePath()
/* 013 US3: a click opens the topic in the right pane; the link still works for new tabs */
const pane = useLiveFeed('pane')
const sidePane = useSidePane()
/* The open topic's title row is the selected one. */
const openedTopicId = computed(() => {
  if (pane.taskId) return String(pane.taskId)
  if (topicStore.open && topicStore.parentTaskId) return String(topicStore.parentTaskId)
  return ''
})
/* deep link: /?topic=<task_id> opens the right pane. `/` is prerendered, so
   the query only exists once hydration settles (useSettledQuery). */
const topic = useSettledQuery('topic')
onMounted(() => {
  watch(topic.value, (id) => {
    if (/^[0-9a-f-]{36}$/i.test(id)) void pane.open(id)
  }, { immediate: true })
})
/* 013 US7: newest activity on top, live over the socket; a reader scrolled down keeps their place */
const listTop = ref<HTMLElement | null>(null)
/* Bring the selected topic title to the top of this list. */
watch(openedTopicId, async (id) => {
  if (!id) return
  await nextTick()
  const root = listTop.value
  if (!root) return
  const row = root.querySelector(`[data-key="${CSS.escape(id)}"]`)
  if (row) scrollRowToTop(root, row)
})
const { pill, jump } = useScrollAnchor(listTop, () => viewer.topics.map((r) => r.task_id))
/* W5: `/` opened the hub socket while signed out - viewer.follow()
   calls live.ensure(), which constructs and connects a client, and the hub
   answers the upgrade 401, so a signed-out visitor got 4 attempts plus backoff
   (measured on both apexes, tree e52e250). The read and the follow now wait for
   a member session, on the same predicate as the rest of the shell; a sign-in
   flips the same store, so a human who signs in gets both with no reload. */
/* Topics tab with a selected row: the omnibox replies in that topic.
   `in: <title>` still names the topic. Anything else, or Topics with
   nothing selected, starts a new message. */
/* The open right pane takes the line only while it was the pane selected
   last; a click back in the middle makes the next line a new topic. */
const paneFocus = usePaneFocus()
function paneOpen() {
  return paneTakesLine({ paneOpen: Boolean(topicStore.open || pane.taskId), lastPane: paneFocus.last })
}

async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  /* SPL-996 B: the open topic takes the line; `@someone` first starts a new one */
  const fresh = startsNewTopic(text)
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: pane.taskId || '',
    namedTopicId: topicId || '',
    paneVisible: paneOpen(),
    lastPane: paneFocus.last,
    newTopic: fresh,
  })
  if (target && pane.taskId && target === pane.taskId) {
    const before = pane.messages.length
    await pane.send(text, files || [], { isParent: isParentFlag({ paneVisible: paneOpen() && !fresh, replyTaskId: target }) })
    const last = pane.messages[pane.messages.length - 1]
    if (last && pane.messages.length > before) {
      viewer.topics = bumpTopic(viewer.topics, last as unknown as Record<string, unknown>) as typeof viewer.topics
    }
    return
  }
  const sent = await channel.send(text, target || undefined, files, channelId, isParentFlag({ paneVisible: paneOpen() && !fresh, replyTaskId: target }))
  /* A send with no topic is a new topic of this one message, so the row
     has to appear here itself. The socket echo does not count a second time. */
  if (sent) viewer.topics = bumpTopic(viewer.topics, sent as unknown as Record<string, unknown>) as typeof viewer.topics
  /* SPL-996: that row is the new topic's one place; no second card in the right pane */
}
function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: pane.taskId || '',
    namedTopicId: '',
    paneVisible: paneOpen(),
    lastPane: paneFocus.last,
  })
}
useOmniboxTarget({
  placeholder: () => (replyTarget() ? tr(sk('topic.reply_placeholder')) : tr(sk('search.placeholder_target'), { target: tr('nav.topics') })),
  dock: () => ({ reply: Boolean(replyTarget()), target: tr('nav.topics') }),
  send: onSend,
})

let listStarted = false
watch(() => api.mock || String(session.state) === 'in', (ready) => {
  if (!ready || listStarted) return
  listStarted = true
  /* the mock tenant has no door and no socket: it reads at once and follows
     nothing (viewer.follow() returns early there) */
  void viewer.loadTopics().then(() => {
    if (shouldOpenHubSocket(session.state, api.mock)) viewer.follow()
  })
}, { immediate: true })
onUnmounted(() => viewer.unfollow())
/* owner, 2026-09-26: participants by their chosen names; ids in the hover */
const people = useHumanNames()
/* SPL-986: Archive / Delete on a topic row (composables/useTopicRowActions.ts) */
const rowMenu = ref('')
const {
  stateOf: topicRowState,
  resolve: resolveTopicRow,
  archive: archiveTopicRow,
  deleteOpen: topicDeleteOpen,
  deleteMsgId: topicDeleteMsgId,
  askDelete: askDeleteTopic,
  onDeleted: onTopicRowDeleted,
} = useTopicRowActions()
function openTopicMenu(taskId: string) {
  rowMenu.value = taskId
  void resolveTopicRow(taskId)
}
</script>

<style scoped>
.topic-row-wrap { position: relative; min-width: 0; }
/* the row menu button sits over the row's end */
.topic-row-wrap > .topic-row {
  padding-inline-end: 40px;
  display: grid;
  grid-template-columns: 36px minmax(0, 1fr);
  gap: 0 10px;
  align-items: start;
}
.topic-row__main { min-width: 0; }
</style>
