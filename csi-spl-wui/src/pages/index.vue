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
           Delete once the hub said the viewer may (specs/041 §3.5).
           HUM-10 (t1 548c17ae): on a phone a swipe LEFT on the row archives
           the topic (composables/useTopicRowSwipe.ts) -->
      <div
        v-for="t in viewer.topics"
        :key="t.task_id"
        class="topic-row-wrap"
        :class="{
          'topic-row-wrap--swipe': swipeOn,
          'topic-row-wrap--swiping': swipeTask === t.task_id && swipeDx !== 0,
          'topic-row-wrap--swipe-settle': swipeTask === t.task_id && swipeSettle,
        }"
        :style="swipeTask === t.task_id && swipeDx !== 0 ? { '--swipe-dx': `${-swipeDx}px`, '--swipe-w': `${swipeDx}px` } : undefined"
        :data-swipe-archive="swipeOn ? 'true' : undefined"
        @contextmenu.prevent="openTopicMenu(t.task_id)"
        @pointerdown="swipeDown($event, t.task_id)"
        @pointermove="swipeMove"
        @pointerup="swipeUp"
        @pointercancel="swipeCancel"
        @click.capture="swipeSwallowClick"
      >
      <div
        v-if="swipeTask === t.task_id && swipeDx !== 0"
        class="topic-swipe-reveal"
        data-testid="topic-swipe-reveal"
        :data-armed="swipeArmed ? 'true' : undefined"
        aria-hidden="true"
      >
        <UiIcon name="archive" :size="20" />
        <span v-if="swipeArmed" class="topic-swipe-reveal__text">{{ tr('feed.swipe_archive') }}</span>
      </div>
      <a
        class="topic-row"
        :class="{ selected: openedTopicId === t.task_id, 'is-archived': t.archived_at }"
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
          <span v-for="k in Object.keys(t.kinds)" :key="k" class="topic-kind" :data-topic-kind="k" @click.stop.prevent="onKindClick(t, k)">
            <KindBadge :kind="shownKind(t, k)" :msg="badgeMsg(t, k)"
              @pending="onKindPending(t.task_id, $event)"
              @revert="onKindRevert(t.task_id)"
              @applied="onKindApplied(t.task_id, $event)" />
          </span>
          <ArchivedBadge v-if="t.archived_at" :at="t.archived_at" />
          <span class="msg-time">{{ rowTime(t.last_ts) }}</span>
          <!-- spec 079 FR-004: the row wears its own unread, the sidebar Topics row's number -->
          <span v-if="rowOf('t:' + t.task_id)" class="badge-unread" data-testid="topic-row-unread">{{ previewUnread(rowOf('t:' + t.task_id)) }}</span>
        </div>
        <div class="topic-subject">{{ rowTitle(t.subject) }}</div>
        <small class="muted">{{ tr('pages.index.messages', { n: t.count }, t.count) }}</small>
        </div>
      </a>
      <SidebarRowMenu
        :menu-id="'home:' + t.task_id"
        :name="rowTitle(t.subject) || t.task_id"
        :href="localePath('/t/' + t.task_id)"
        :open="rowMenu === t.task_id"
        :topic-archive="topicRowState(t.task_id)?.canArchive"
        :topic-delete="topicRowState(t.task_id)?.canDelete"
        :topic-state="topicRowState(t.task_id)?.state || ''"
        :topic-kind="maySetTopicKind(t)"
        @toggle="rowMenu === t.task_id ? (rowMenu = '') : openTopicMenu(t.task_id)"
        @close="rowMenu = ''"
        @open="pane.open(t.task_id)"
        @kind="openTopicKind(t.task_id)"
        @archive="archiveTopicRow(t.task_id)"
        @delete-topic="askDeleteTopic(t.task_id)"
        @ai-fail="topicAiError = $event"
      />
      </div>
      <p v-if="topicAiError" class="msg-edit-error" role="alert" data-testid="msg-ai-error">{{ tr(topicAiError) }}</p>
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
import { useTopicRowSwipe } from '~/composables/useTopicRowSwipe'
import { namedLine, topicStarter } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useMobileStack } from '~/composables/useMobileStack'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { useLiveFeed } from '~/stores/live'
import { formatMsgListTs, phoneCardTime } from '~/utils/channel-feed.mjs'
import { bumpTopic } from '~/utils/topic-list.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useScrollAnchor } from '~/composables/useScrollAnchor'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { openerMessage, retargetKinds, topicRowKind } from '~/utils/topic-kind.mjs'
import type { SpoolMessage } from '~/types/spool'
import { shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { paneTakesLine } from '~/utils/pane-focus.mjs'
import { rowTitle } from '~/utils/view-api.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { useAccessStore } from '~/stores/access'
import { tenantSettingsVisible } from '~/utils/tenant-settings-nav.mjs'
import { previewUnread } from '~/utils/notify.mjs'
import { useUnread } from '~/composables/useUnread'

const viewer = useViewerStore()
const { rowOf } = useUnread()
const channel = useChannelStore()
const topicStore = useTopicStore()
const session = useSessionStore()
const api = useSpoolApi()
const live = useLive()
const edit = useMessageEdit()
/* W15 (spec 047): the first-run checklist, a lazy chunk loaded only for a
   viewer who may open Tenant settings (an admin or the business owner) */
const FirstRunChecklist = defineAsyncComponent(() => import('~/components/FirstRunChecklist.vue'))
const access = useAccessStore()
watch(() => api.mock || String(session.state) === 'in', (on) => { if (on) void access.load() }, { immediate: true })
const firstRunTenant = computed(() => String(session.claims?.t || api.tenant || ''))
const firstRunCandidate = computed(() => (api.mock || String(session.state) === 'in') && !viewer.loading &&
  !viewer.error && tenantSettingsVisible(access.me, { mock: api.mock }))
/* `tr`, not `t`: the topic rows below are iterated as `t` */
const { t: tr } = useI18n({ useScope: 'global' })
/* spec 082 FR-003: phone and desktop rows alike print the viewer's own
   clock with the list-time rule (phoneCardTime): HH:MM today, `MM-DD HH:MM`
   this year, the full date before. A desktop row used to print HH:MM only,
   so a two-week-old topic read like today. */
const rowTime = (ts: string) => phoneCardTime(formatMsgListTs(ts), ts)
/* SPL-976: the placeholder names the keys of the person's Behaviour setting */
const { hintFor: sk } = useSubmitKey()
const stack = useMobileStack()
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
  /* the open topic takes the line, `@agent <text>` too (owner c3f0f2cf retired SPL-996 B) */
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
  placeholder: () => (stack.isMobile.value && replyTarget() ? tr('composer.phone_placeholder_reply') : replyTarget() ? tr(sk('topic.reply_placeholder')) : tr(sk('search.placeholder_target'), { target: tr('nav.topics') })),
  dock: () => ({ reply: Boolean(replyTarget()), target: tr('nav.topics') }),
  place: () => (replyTarget() ? `t:${replyTarget()}` : channel.peer ? `dm:${channel.peer}` : `ch:${channel.active || ''}`),
  send: onSend,
})

let listStarted = false
watch(() => api.mock || String(session.state) === 'in', (ready) => {
  if (!ready || listStarted) return
  listStarted = true
  /* the mock tenant has no door and no socket: it reads at once and follows
     nothing (viewer.follow() returns early there). ensure() only names the
     mock viewer (HUM-1); it does not open a socket. Without that id the
     author test in canSetKind stays closed and a badge click only opens
     the topic. */
  if (api.mock && import.meta.client) live.ensure()
  void viewer.loadTopics().then(() => {
    if (shouldOpenHubSocket(session.state, api.mock)) viewer.follow()
  })
}, { immediate: true })
onUnmounted(() => viewer.unfollow())
/* owner, 2026-09-26: participants by their chosen names; ids in the hover */
const people = useHumanNames()
/* SPL-986: Archive / Delete on a topic row (composables/useTopicRowActions.ts) */
const rowMenu = ref('')
/* t1 b6c742f0: an AI action picked on a topic row's menu failed */
const topicAiError = ref('')
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
  void ensureOpener(taskId)
}
/* The opener is not on the topic list. One getTopic per row, and only once
   the reader asks (a badge click or the row menu), shared by both. */
type Opener = SpoolMessage | 'none'
const openers = shallowRef<Record<string, Opener>>({})
const pendingKind = ref<Record<string, { from: string, to: string }>>({})
const openerInflight = new Map<string, Promise<SpoolMessage | null>>()

function heldOpener(taskId: string): SpoolMessage | null {
  const held = openers.value[String(taskId || '')]
  return held && held !== 'none' ? held : null
}
function viewerRole(): string | null {
  return access.me?.role ?? null
}
function maySetTopicKind(t: { task_id: string, kinds: Record<string, number> }) {
  return Boolean(topicRowKind(heldOpener(t.task_id), edit.viewerId.value, viewerRole(), t.kinds))
}
function badgeMsg(t: { task_id: string, kinds: Record<string, number> }, k: string) {
  const msg = heldOpener(t.task_id)
  if (!msg || topicRowKind(msg, edit.viewerId.value, viewerRole(), t.kinds) !== k) return null
  return msg
}
function shownKind(t: { task_id: string }, k: string) {
  const p = pendingKind.value[t.task_id]
  return p && p.from === k ? p.to : k
}
async function ensureOpener(taskId: string): Promise<SpoolMessage | null> {
  const task = String(taskId || '')
  if (!task) return null
  if (Object.prototype.hasOwnProperty.call(openers.value, task)) return heldOpener(task)
  const pending = openerInflight.get(task)
  if (pending) return pending
  const run = (async () => {
    try {
      const page = await api.getTopic(task, { limit: 40 }) as { messages?: SpoolMessage[] }
      const msg = openerMessage(page.messages || [], '') as SpoolMessage | null
      openers.value = { ...openers.value, [task]: msg || 'none' }
      return msg
    } catch {
      return null
    } finally {
      openerInflight.delete(task)
    }
  })()
  openerInflight.set(task, run)
  return run
}
function onKindPending(taskId: string, payload: { from: string, to: string }) {
  pendingKind.value = { ...pendingKind.value, [taskId]: payload }
}
function onKindRevert(taskId: string) {
  if (!pendingKind.value[taskId]) return
  const next = { ...pendingKind.value }
  delete next[taskId]
  pendingKind.value = next
}
function onKindApplied(taskId: string, payload: { from: string, to: string }) {
  onKindRevert(taskId)
  const msg = heldOpener(taskId)
  if (msg) openers.value = { ...openers.value, [taskId]: { ...msg, kind: payload.to } }
  viewer.topics = viewer.topics.map((row) => row.task_id !== taskId ? row
    : { ...row, kinds: retargetKinds(row.kinds, payload.from, payload.to) })
}
async function onKindClick(t: { task_id: string, kinds: Record<string, number> }, k: string) {
  await ensureOpener(t.task_id)
  await nextTick()
  const row = listTop.value?.querySelector(`a.topic-row[data-key="${CSS.escape(t.task_id)}"]`)
  const host = row?.querySelector(`[data-topic-kind="${CSS.escape(k)}"]`)
  const btn = host?.querySelector<HTMLElement>('[data-testid="kind-badge-btn"]')
  if (btn && topicRowKind(heldOpener(t.task_id), edit.viewerId.value, viewerRole(), t.kinds) === k) {
    btn.click()
    return
  }
  pane.open(t.task_id)
}
async function openTopicKind(taskId: string) {
  await ensureOpener(taskId)
  await nextTick()
  const btn = listTop.value?.querySelector<HTMLElement>(
    `a.topic-row[data-key="${CSS.escape(taskId)}"] [data-testid="kind-badge-btn"]`)
  btn?.click()
}
/* HUM-10 (owner, t1 548c17ae): a phone swipe LEFT on a row archives its
   topic, through the row menu's own Archive above */
const {
  on: swipeOn,
  task: swipeTask,
  dx: swipeDx,
  armed: swipeArmed,
  settle: swipeSettle,
  down: swipeDown,
  move: swipeMove,
  up: swipeUp,
  cancel: swipeCancel,
  swallowClick: swipeSwallowClick,
} = useTopicRowSwipe({
  allowed: (taskId) => {
    const row = topicRowState(taskId)
    return !row || row.state === 'loading' ? null : row.state === 'ready' && row.canArchive
  },
  prepare: resolveTopicRow,
  archive: archiveTopicRow,
})
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
/* The wrapper is not a box: the badges stay flex items of .msg-meta. */
.topic-kind { display: contents; }
/* HUM-10: the phone row swipe (useTopicRowSwipe), MessageCard's look. pan-y
   leaves the vertical scroll to the browser and gives the horizontal move to
   the row; the row slides by --swipe-dx and the strip, pinned just past the
   end it uncovers (--swipe-w wide), shows the archive icon (accent once past
   the threshold, with "Release to archive"). */
.topic-row-wrap--swipe { touch-action: pan-y; }
.topic-row-wrap--swiping,
.topic-row-wrap--swipe-settle { transform: translateX(var(--swipe-dx, 0px)); }
.topic-row-wrap--swipe-settle { transition: transform 0.18s ease-out; }
:global(html[dir="rtl"]) .topic-row-wrap--swiping,
:global(html[dir="rtl"]) .topic-row-wrap--swipe-settle { transform: translateX(calc(-1 * var(--swipe-dx, 0px))); }
.topic-swipe-reveal {
  position: absolute;
  inset-block: 0;
  inset-inline-end: calc(-1 * var(--swipe-w, 0px));
  width: var(--swipe-w, 0px);
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 6px;
  padding-inline-end: 12px;
  overflow: hidden;
  white-space: nowrap;
  border-radius: var(--radius);
  background: var(--color-selected);
  color: var(--color-muted);
  font-size: 0.8125rem;
  font-weight: 600;
  pointer-events: none;
}
.topic-swipe-reveal[data-armed] { background: var(--color-accent); color: var(--color-on-accent); }
@media (prefers-reduced-motion: reduce) {
  .topic-row-wrap--swipe-settle { transition: none; }
}
</style>
