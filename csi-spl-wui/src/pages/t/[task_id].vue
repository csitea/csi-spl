<template>
  <div
    class="topic-browse"
    data-test="topic-browse"
    :data-phone="stack.isMobile.value ? (phoneThread ? 'thread' : 'list') : undefined"
  >
    <section class="topic-browse__list" data-test="topic-browse-list" :aria-label="t('nav.topics')">
      <header class="feed-header">
        <MobileBack />
        <h2>{{ t('nav.topics') }}</h2>
        <span class="muted">{{ t('pages.index.subtitle') }}</span>
      </header>
      <div ref="listBody" class="feed-body">
        <ViewTokenForm v-if="viewer.needsToken" :detail="viewer.doorDetail" @saved="onDoor" />
        <ErrorNotice v-if="viewer.error" :message="viewer.error" source="viewer" test-id="viewer-error" />
        <p v-else-if="!viewer.needsToken && !viewer.loading && !viewer.error && viewer.topics.length === 0" class="muted">
          {{ t('pages.index.empty') }}
        </p>
        <div
          v-for="row in viewer.topics"
          :key="row.task_id"
          class="topic-row-wrap"
          @contextmenu="onRowContext(row.task_id, $event)"
        >
        <a
          class="topic-row"
          v-if="editTask !== row.task_id"
          :class="{ selected: taskId === row.task_id, 'is-archived': row.archived_at }"
          :aria-current="taskId === row.task_id ? 'true' : undefined"
          :data-key="row.task_id"
          :href="localePath('/t/' + row.task_id)"
          @click.exact.prevent="pick(row.task_id)"
          @keydown="onRowKey(row.task_id, $event)"
        >
          <div class="topic-subject">{{ rowTitle(row.subject) }}</div>
          <ArchivedBadge v-if="row.archived_at" :at="row.archived_at" />
          <small class="muted">{{ t('pages.index.messages', { n: row.count }, row.count) }}</small>
        </a>
        <div
          v-else
          class="topic-row selected"
          :data-key="row.task_id"
        >
          <TopicListEdit
            v-model="editDraft"
            :saving="editSaving"
            :label="t('feed.edit.label')"
            @keydown="onEditKey"
          />
          <p v-if="editError" class="msg-edit-error" role="alert" data-test="topic-list-edit-error">{{ t(editError) }}</p>
        </div>
        <button
          type="button"
          class="icon-btn topic-list-menu"
          data-testid="topic-list-menu"
          :data-menu-id="row.task_id"
          :aria-label="t('feed.msg_menu.label')"
          :title="t('feed.msg_menu.label')"
          :aria-expanded="menuOpen && menuTask === row.task_id ? 'true' : 'false'"
          aria-haspopup="menu"
          @click.stop="onRowMenuButton(row.task_id, $event)"
          @contextmenu.stop.prevent="onRowMenuButton(row.task_id, $event)"
        >
          <UiIcon name="menu" :size="16" />
        </button>
        </div>
        <button v-if="viewer.next" class="btn ghost" type="button" @click="viewer.loadMore()">{{ t('pages.index.older') }}</button>
      </div>
    </section>
    <div class="topic-browse__thread" data-test="topic-browse-thread">
      <TopicPane />
    </div>
    <!-- the channel card's menu (MessageMenu), one at a time, mounted on open -->
    <LazyMessageMenu
      v-if="menuOpen && menuMsg && menuFlags"
      :open="menuOpen"
      :x="menuPoint.x"
      :y="menuPoint.y"
      :editable="menuFlags.editable"
      :parent="menuFlags.parent"
      :topic-archive="menuFlags.topicArchive"
      :topic-delete="menuFlags.topicDelete"
      :move-channel="menuFlags.moveChannel"
      :merge-topic="menuFlags.mergeTopic"
      :locks="menuFlags.locks"
      :ai-msg="menuMsg"
      :ai-fail="onAiFail"
      @close="hideMenu()"
      @escape="focusMenuRow()"
      @open="onMenuOpen"
      @edit="onMenuEdit"
      @copy="onMenuCopy"
      @archive="onMenuArchive"
      @delete-topic="onMenuDelete"
      @move-channel="onMenuMove('channel')"
      @merge-topic="onMenuMove('merge')"
    />
    <p v-if="aiError" class="msg-edit-error" role="alert" data-test="topic-list-ai-error">{{ t(aiError) }}</p>
    <LazyMovePickerDialog
      v-if="movePicker && menuMsg"
      :open="true"
      :mode="movePicker"
      :msg="menuMsg"
      @update:open="(v: boolean) => { if (!v) movePicker = '' }"
    />
    <TopicDeleteDialog
      v-if="deleteOpen && deleteMsgId"
      v-model:open="deleteOpen"
      :msg-id="deleteMsgId"
      @deleted="onTopicDeleted"
    />
  </div>
</template>

<script setup lang="ts">
import { useSubmitKey } from '~/composables/useSubmitKey'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { noteError } from '~/composables/errorJournal.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useMessageMenu } from '~/composables/useMessageMenu'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { useLive } from '~/composables/useLive'
import { useMsgShortcutsOn } from '~/composables/useMsgShortcuts'
import { useChannelStore } from '~/stores/channel'
import { useOmniboxTarget } from '~/stores/omnibox'
import { useTopicStore } from '~/stores/topic'
import { useViewerStore } from '~/stores/viewer'
import { useSessionStore } from '~/stores/session'
import { useAccessStore } from '~/stores/access'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useMobileStack } from '~/composables/useMobileStack'
import { useSidePane } from '~/composables/useSidePane'
import { bumpTopic } from '~/utils/topic-list.mjs'
import { shouldOpenHubSocket } from '~/utils/shell-bootstrap.mjs'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '~/utils/omnibox-topic.mjs'
import { topicOpening } from '~/utils/view-api.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { openingCardId, topicErrorKey } from '~/utils/topic-archive.mjs'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { dmPeerOf } from '~/utils/channel-feed.mjs'
import { topicPaneLink } from '~/utils/msg-menu.mjs'
import { offeredItems, shortcutFor, shortcutItem } from '~/utils/msg-shortcuts.mjs'
import * as msgShortcutsMod from '~/utils/msg-shortcuts.mjs'
import { fenceStateAt } from '~/utils/code-blocks.mjs'
import { beginEdit, commitEdit, editFailureKey, editKeyAction, withDraft, type MsgEditState } from '~/utils/msg-edit.mjs'
import type { TopicMenuLocks } from '~/utils/topic-menu.mjs'
import * as topicMenuMod from '~/utils/topic-menu.mjs'
import type { SpoolMessage } from '~/types/spool'

/* mjs-shims.d.ts is another lane's file, so this export is not declared there. */
type MeLike = { role?: string | null, tenantOwner?: boolean, topicArchivePolicy?: string } | null
type CardMenuOpts = {
  editable: boolean
  parent: boolean
  topicArchive: boolean
  topicDelete: boolean
  moveChannel: boolean
  mergeTopic: boolean
  locks: TopicMenuLocks
}
/* TOPIC_LIST_SHORTCUTS is not declared in mjs-shims.d.ts either */
const TOPIC_LIST_SHORTCUTS = (msgShortcutsMod as unknown as {
  TOPIC_LIST_SHORTCUTS: readonly { key: string, items: readonly string[], labelKey: string }[]
}).TOPIC_LIST_SHORTCUTS
const topicCardMenuOpts = (topicMenuMod as unknown as {
  topicCardMenuOpts: (msg: unknown, viewerId: string, me: MeLike, opts?: { editable?: boolean, lobbyTaskId?: string }) => CardMenuOpts
}).topicCardMenuOpts

const route = useRoute()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })
const { hintFor: sk } = useSubmitKey()
const api = useSpoolApi()
const session = useSessionStore()
const channel = useChannelStore()
const topic = useTopicStore()
const viewer = useViewerStore()
const access = useAccessStore()
const sidePane = useSidePane()
const stack = useMobileStack()
const live = useLive()
const editor = useMessageEdit()
const archiveUndo = useArchiveUndo()
const shortcutsOn = useMsgShortcutsOn()

const taskId = computed(() => String(route.params.task_id || ''))
const shortId = computed(() => taskId.value.slice(0, 8))
/* A deep link opens on the thread. Back (and the thread's X) returns to the list. */
const phoneThread = ref(true)
const listBody = ref<HTMLElement | null>(null)
const sending = ref(false)

/* The channel card's menu, for the row whose opening card we have loaded. */
const menuTask = ref('')
const menuMsg = ref<SpoolMessage | null>(null)
const { open: menuOpen, point: menuPoint, openAt, close: hideMenu } = useMessageMenu(() => menuTask.value)
let menuTicket = 0
const movePicker = ref<'' | 'channel' | 'merge'>('')
const deleteOpen = ref(false)
const deleteMsgId = ref('')
const editTask = ref('')
const editDraft = ref('')
const editError = ref('')
const editSaving = ref(false)
const editState = ref<MsgEditState | null>(null)

const menuFlags = computed(() => {
  const msg = menuMsg.value
  if (!msg) return null
  const me = (access.me ?? null) as MeLike
  return topicCardMenuOpts(msg, editor.viewerId.value, me, {
    editable: editor.canEdit(msg),
    lobbyTaskId: String(live.lobbyTaskId.value || ''),
  })
})

stack.rightPanel(
  () => stack.isMobile.value && phoneThread.value && topic.open,
  () => { phoneThread.value = false },
)

/* The thread's X closes the topic store. On a phone that must reveal the list,
   or the thread column stays the one on screen and is empty. */
watch(() => topic.open, (open, was) => {
  if (was && !open) phoneThread.value = false
})

watch(() => viewer.needsToken, (need) => {
  if (!need) return
  phoneThread.value = false
  topic.close()
})

watch(() => api.mock || String(session.state) === 'in', (on) => { if (on) void access.load() }, { immediate: true })

function rowTitle(subject: string) {
  return topicOpening(subject) || t('topic.title')
}

function openingOf(rows: SpoolMessage[], id: string): SpoolMessage | null {
  const mine = rows.filter((m) => String(m.parent_task_id || m.task_id || '') === id)
  /* A channel card is the topic root. A desc thread page lists replies first,
     and a reply with no is_parent still counts as a card, so take the root
     and read it oldest-first before openingCardId. */
  const roots = mine.filter((m) => !String(m.parent_task_id || '') && String(m.task_id || '') === id)
  const pool = (roots.length ? roots : mine).slice().sort((a, b) => String(a.ts || '').localeCompare(String(b.ts || '')))
  const found = openingCardId(pool, '')
  if (!found) return null
  return pool.find((m) => String(m.msg_id || '') === found) || null
}

/** The same card a channel feed would draw for this topic. */
async function cardOf(id: string): Promise<SpoolMessage | null> {
  const local = openingOf(channel.messages, id)
  if (local) return local
  try {
    const page = await api.getTopic(id, { limit: 30 }) as { messages?: SpoolMessage[] }
    return openingOf(page.messages || [], id)
  } catch {
    return null
  }
}

async function openRowMenu(id: string, x: number, y: number) {
  const ticket = ++menuTicket
  /* The channel card's Edit / Delete follow the viewer id. Mock me() omits
     human_id once an archive policy is set, so the id is live.identity, which
     ensure() fills. Opening before that shows those entries locked. */
  live.ensure()
  if ((api.mock || String(session.state) === 'in') && !access.me) {
    try { await access.load() } catch { /* locks follow whatever me is */ }
  }
  if (ticket !== menuTicket) return
  const msg = await cardOf(id)
  if (ticket !== menuTicket || !msg) return
  menuMsg.value = msg
  menuTask.value = id
  openAt(x, y)
}

/* The row Esc returns to. The menu button is a sibling of the link. */
let menuRow: HTMLElement | null = null
function noteMenuRow(ev: Event) {
  const t = ev.target
  if (!(t instanceof Element)) return
  menuRow = t.closest<HTMLElement>('a.topic-row')
    || t.closest('.topic-row-wrap')?.querySelector<HTMLElement>('a.topic-row')
    || null
}
function focusMenuRow() {
  const to = menuRow
  menuRow = null
  void nextTick(() => to?.focus({ preventScroll: true }))
}

/* A phone long-press stays the browser's. This list has no swipe. The
   button still opens the menu. Desktop right-click opens it here. */
function onRowContext(id: string, ev: MouseEvent) {
  if (stack.isMobile.value) return
  ev.preventDefault()
  noteMenuRow(ev)
  void openRowMenu(id, ev.clientX, ev.clientY)
}

function onRowMenuButton(id: string, ev: MouseEvent) {
  noteMenuRow(ev)
  if (menuOpen.value && menuTask.value === id) {
    hideMenu()
    return
  }
  const btn = ev.currentTarget
  if (!(btn instanceof HTMLElement)) return
  const r = btn.getBoundingClientRect()
  void openRowMenu(id, r.left, r.bottom + 4)
}

function onMenuOpen() {
  const id = menuTask.value
  hideMenu()
  if (id) pick(id)
}

function onMenuEdit() {
  const msg = menuMsg.value
  const id = menuTask.value
  hideMenu()
  if (!msg || !editor.canEdit(msg)) return
  const began = beginEdit(msg)
  if (!began) return
  editTask.value = id
  editState.value = began
  editDraft.value = began.draft
  editError.value = ''
  void nextTick(() => {
    const el = document.querySelector<HTMLTextAreaElement>('[data-testid=topic-list-edit]')
    if (!el) return
    el.focus()
    el.setSelectionRange(el.value.length, el.value.length)
  })
}

function closeEdit() {
  editTask.value = ''
  editState.value = null
  editDraft.value = ''
  editSaving.value = false
}

function onEditKey(ev: KeyboardEvent) {
  if (editSaving.value) {
    if (ev.key === 'Enter' && !ev.shiftKey) ev.preventDefault()
    return
  }
  const el = ev.target
  const caret = el instanceof HTMLTextAreaElement ? (el.selectionStart ?? editDraft.value.length) : editDraft.value.length
  const act = editKeyAction(ev, { inCode: fenceStateAt(editDraft.value, caret).inCode })
  if (act === 'cancel') {
    ev.preventDefault()
    editError.value = ''
    closeEdit()
    return
  }
  if (act !== 'commit') return
  ev.preventDefault()
  void saveEdit()
}

async function saveEdit() {
  const state = withDraft(editState.value, editDraft.value)
  if (!state) return
  const decided = commitEdit(state)
  if (decided.action === 'unchanged') {
    editError.value = ''
    closeEdit()
    return
  }
  if (decided.action === 'empty') {
    editError.value = editFailureKey(decided.error)
    return
  }
  editSaving.value = true
  editError.value = ''
  try {
    const row = await editor.commit(state.msgId, decided.body)
    editor.applyEverywhere(row)
    const id = editTask.value
    viewer.topics = viewer.topics.map((r) => (r.task_id === id ? { ...r, subject: decided.body } : r))
    if (menuMsg.value && String(menuMsg.value.msg_id || '') === state.msgId) menuMsg.value = { ...menuMsg.value, ...row }
    closeEdit()
  } catch (e) {
    editSaving.value = false
    editError.value = editFailureKey(e)
  }
}

/* t1 b6c742f0: the card's AI actions run in MessageMenu; a failure shows here */
const aiError = ref('')
function onAiFail(key: string) {
  aiError.value = key
}

async function onMenuCopy() {
  const msg = menuMsg.value
  const id = menuTask.value
  hideMenu()
  if (!msg || typeof window === 'undefined') return
  const ch = String(msg.channel || '').trim().replace(/^#/, '')
  let path = ''
  if (ch) path = localePath('/channel/' + encodeURIComponent(ch))
  else {
    const peer = dmPeerOf(msg, editor.viewerId.value)
    if (peer) path = localePath('/dm/' + encodeURIComponent(peer))
  }
  const rel = path ? topicPaneLink(msg, { path, query: {}, currentTaskId: '' }) : ''
  const href = rel || localePath('/t/' + id)
  if (href) await writeClipboard(new URL(href, window.location.origin).href)
}

async function archiveRow(msg: SpoolMessage | null, id: string) {
  const cardId = String(msg?.msg_id || '')
  if (!cardId) return false
  try {
    await api.archiveTopic(cardId, true)
    editor.dropEverywhere(cardId)
    viewer.dropTopics([id, cardId])
    archiveUndo.offerUndo(cardId, 'rail')
    return true
  } catch (e) {
    noteError({ source: 'topic-archive', name: 'TopicArchive', message: t(topicErrorKey(e, 'archive')), error: e })
    return false
  }
}

async function onMenuArchive() {
  const msg = menuMsg.value
  const id = menuTask.value
  hideMenu()
  await archiveRow(msg, id)
}

/* HUM-10 (t1 topic 2627084c): Shift + A on a focused row archives that topic,
   as the channel card's key does. shortcutFor applies the same guards (a text
   field, Ctrl / Cmd / Alt, the Settings switch, a phone); the item must be
   one the row's menu offers enabled, so a role the menu locks it for gets
   nothing. The key is taken here, so the feed's window listener leaves it. */
let rowKeyTicket = 0
function onRowKey(id: string, ev: KeyboardEvent) {
  const overlayOpen = menuOpen.value || deleteOpen.value || Boolean(movePicker.value)
  const hit = shortcutFor(ev, { enabled: shortcutsOn.value, overlayOpen })
  if (!hit || hit.type !== 'action' || !TOPIC_LIST_SHORTCUTS.some((s) => s.key === hit.key)) return
  ev.preventDefault()
  void archiveRowByKey(id, ev.currentTarget instanceof HTMLElement ? ev.currentTarget : null)
}

async function archiveRowByKey(id: string, rowEl: HTMLElement | null) {
  const ticket = ++rowKeyTicket
  live.ensure()
  if ((api.mock || String(session.state) === 'in') && !access.me) {
    try { await access.load() } catch { /* the check follows whatever me is */ }
  }
  const msg = await cardOf(id)
  if (ticket !== rowKeyTicket || !msg) return
  const flags = topicCardMenuOpts(msg, editor.viewerId.value, (access.me ?? null) as MeLike, {
    editable: editor.canEdit(msg),
    lobbyTaskId: String(live.lobbyTaskId.value || ''),
  })
  if (shortcutItem('A', offeredItems(flags)) !== 'archive') return
  /* the next row takes the focus, so Shift + A again archives that one */
  const wrap = rowEl?.closest('.topic-row-wrap')
  const next = (wrap?.nextElementSibling || wrap?.previousElementSibling)?.querySelector<HTMLElement>('a.topic-row') || null
  if (await archiveRow(msg, id)) void nextTick(() => next?.focus())
}

function onMenuDelete() {
  const id = String(menuMsg.value?.msg_id || '')
  hideMenu()
  if (!id) return
  deleteMsgId.value = id
  deleteOpen.value = true
}

function onTopicDeleted(out: { msg_ids?: string[], task_ids?: string[] }) {
  const ids = [...(out.msg_ids || []), ...(out.task_ids || []), menuTask.value].filter(Boolean)
  for (const id of out.msg_ids || []) editor.dropEverywhere(id)
  viewer.dropTopics(ids)
}

function onMenuMove(mode: 'channel' | 'merge') {
  hideMenu()
  if (!menuMsg.value) return
  movePicker.value = mode
}

/* TopicPane's mock path reads the channel store, not its own fetch.
   Seed that store from the same read before opening, or the thread is empty. */
async function seedMockThread(id: string) {
  if (!api.mock) return
  const data = await api.getTopic(id, { order: 'desc', limit: 50 }) as { messages?: { msg_id?: string }[] }
  const rows = data.messages || []
  const have = new Set(channel.messages.map((m) => String(m.msg_id || '')))
  const add = rows.filter((m) => m && m.msg_id && !have.has(String(m.msg_id)))
  if (add.length) channel.messages = [...channel.messages, ...(add as typeof channel.messages)]
}

async function showTopic(id: string) {
  await seedMockThread(id)
  if (taskId.value !== id || viewer.needsToken) {
    if (viewer.needsToken) {
      phoneThread.value = false
      topic.close()
    }
    return
  }
  topic.openTopic(id)
}

function pick(id: string) {
  if (viewer.needsToken) return
  phoneThread.value = true
  if (id !== taskId.value) {
    void navigateTo(localePath('/t/' + id))
    return
  }
  if (!topic.open) void showTopic(id)
}

async function onDoor() {
  await viewer.loadTopics()
  const id = taskId.value
  if (!id || viewer.needsToken) return
  phoneThread.value = true
  await showTopic(id)
}

/* The list is showing: the thread is not the line, even if the store is still open. */
function paneVisible() {
  if (stack.isMobile.value && !phoneThread.value) return false
  return topic.open
}

async function onSend(text: string, files?: File[], topicId?: string, channelId?: string) {
  const fresh = startsNewTopic(text)
  const visible = paneVisible()
  const target = omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: topicId || '',
    paneVisible: visible,
    newTopic: fresh,
  })
  sending.value = true
  try {
    const sent = await channel.send(
      text,
      target || undefined,
      files,
      channelId,
      isParentFlag({ paneVisible: visible && !fresh, replyTaskId: target || '' }),
    )
    if (sent) viewer.topics = bumpTopic(viewer.topics, sent as unknown as Record<string, unknown>) as typeof viewer.topics
  } finally {
    sending.value = false
  }
}

function replyTarget() {
  return omniboxReplyTaskId({
    tab: sidePane.current.value,
    selectedTaskId: taskId.value,
    namedTopicId: '',
    paneVisible: paneVisible(),
  })
}

useOmniboxTarget({
  placeholder: () => (stack.isMobile.value ? (replyTarget() ? t('composer.phone_placeholder_reply') : channel.peer ? t('composer.phone_placeholder_dm', { peer: channel.peer }) : t('composer.phone_placeholder_channel', { name: channel.active || shortId.value })) : replyTarget() ? t(sk('topic.reply_placeholder')) : t(sk('search.placeholder_target'), { target: shortId.value })),
  dock: () => ({ reply: Boolean(replyTarget()), target: shortId.value }),
  place: () => (replyTarget() ? `t:${replyTarget()}` : channel.peer ? `dm:${channel.peer}` : `ch:${channel.active || ''}`),
  send: onSend,
  busy: () => sending.value,
})

watch([taskId, () => viewer.topics.length, phoneThread], async () => {
  const id = taskId.value
  if (!id || (stack.isMobile.value && phoneThread.value)) return
  await nextTick()
  const root = listBody.value
  if (!root) return
  const row = root.querySelector(`[data-key="${CSS.escape(id)}"]`)
  if (row) scrollRowToTop(root, row)
})

if (import.meta.client) {
  watch(taskId, async (id, prev) => {
    if (!id) return
    if (prev !== undefined) phoneThread.value = true
    await showTopic(id)
  }, { immediate: true })
}

let listStarted = false
watch(() => api.mock || String(session.state) === 'in', (ready) => {
  if (!ready || listStarted) return
  listStarted = true
  void viewer.loadTopics().then(() => {
    if (shouldOpenHubSocket(session.state, api.mock)) viewer.follow()
  })
}, { immediate: true })

onUnmounted(() => {
  viewer.unfollow()
  /* Closing while the next page still names a topic strips its ?topic=
     (the channel page writes the store back onto its own URL). A page
     with no topic query does not want this pane left open. */
  const cur = useRouter().currentRoute.value
  const path = String(cur.path || '')
  if (/\/t\/[^/]+$/.test(path)) return
  if (cur.query.topic || cur.query.in) return
  topic.close()
})
</script>

<style scoped>
.topic-row-wrap { position: relative; min-width: 0; }
.topic-row-wrap > .topic-row { padding-inline-end: 40px; }
.topic-list-menu {
  position: absolute;
  inset-inline-end: 4px;
  top: 0;
  bottom: 0;
  height: fit-content;
  margin-block: auto;
  z-index: 1;
}
</style>
