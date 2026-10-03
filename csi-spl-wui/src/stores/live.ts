import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useMentionPoke } from '~/composables/useMentionPoke'
import { topicWhere } from '~/utils/mention-poke.mjs'
import { usePaneFocus } from '~/stores/pane-focus'
import { matchesSearch, mergeById, newestFirst, pendingRow, rootAndReplies, windowed, withoutMsg } from '~/utils/feed.mjs'
import { catchUp, isDoor, withSessionRetry } from '~/utils/live-follow.mjs'
import { channelView, parseMention } from '~/utils/channel-feed.mjs'
import { emptySendError, isEmptySend, sendWithResend } from '~/utils/send-failure.mjs'
import { uploadWithFreshToken } from '~/utils/upload-retry.mjs'
import { applyEdit } from '~/utils/msg-apply.mjs'
import { applyReactions as patchReactions } from '~/utils/emoji.mjs'
import { archiveStamp } from '~/utils/topic-archive.mjs'
import type { FileRef, SpoolMessage } from '~/types/spool'

import { WINDOW } from '~/utils/feed-window.mjs'
export { WINDOW }
/* loadAll reaches back ~1000 rows whatever the page size. Every other turn
   only reveals rows already held, so a turn is half a hub read. */
const MAX_ALL_ROWS = 1000
const MAX_PAGES = 2 * Math.ceil(MAX_ALL_ROWS / WINDOW)

/**
 * A live feed for one task_id (005 T022, 013 reverse prepend). History from
 * view-v1 §4.4 (paged via next — §4.4 is oldest-first, spec 013 D1), then live
 * WS frames merged in. Rendered newest-first in windows; /search filters.
 * One store per pane: useLiveFeed('main') and useLiveFeed('pane').
 */
function setup(key: 'main' | 'pane') {
  const api = useSpoolApi()
  const live = useLive()
  /* the global i18n instance for the fallback error lines (a hub error keeps its own message) */
  const i18n = useNuxtApp().$i18n
  const { poke } = useMentionPoke()
  const taskId = ref<string | null>(null)
  /* replaced whole on every change (merge / applyEdit / withoutMsg ...), never
     mutated in place, so the rows need no deep proxies (CLE-35075) */
  const messages = shallowRef<SpoolMessage[]>([])
  const error = ref<string | null>(null)
  /** view-v1 §2: the last read hit the view door (401) — pages show the door prompt. */
  const door = ref<{ detail: string } | null>(null)
  const sending = ref(false)
  const loading = ref(false)
  const search = ref('')
  const visible = ref(WINDOW)
  const liveCount = ref(0)
  /** view-v1 §4.4 desc cursor for the next older server window; null = none left. */
  const olderCursor = ref<string | null>(null)
  const loadingOlder = ref(false)
  const lastLive = ref<SpoolMessage | null>(null)
  /** t1 8fb802cd: the open topic's archive stamp ('' = live); the header marks it. */
  const archivedAt = ref('')

  const filtered = computed(() => newestFirst(messages.value.filter((m) => matchesSearch(m, search.value))))
  const view = computed(() => windowed(filtered.value, visible.value))
  const newestFirstRows = computed(() => view.value.rows as SpoolMessage[])
  const hasOlder = computed(() => view.value.hasOlder || Boolean(olderCursor.value))
  /*
   * #lobby pane 2. The room is one task and follow-ups are later messages of
   * that task, usually with no parent_task_id. They are replies: pane 2 keeps
   * the earliest message only. Pane 3 reads the rest of the task.
   */
  const lobbyView = computed(() => channelView(messages.value, { search: search.value, visible: visible.value }))
  const lobbyRows = computed(() => lobbyView.value.rows as SpoolMessage[])
  const lobbyHasOlder = computed(() => lobbyView.value.hasOlder || Boolean(olderCursor.value))
  const topic = computed(() => rootAndReplies(messages.value.filter((m) => matchesSearch(m, search.value))))

  /** By msg_id: new rows are added, a confirmed row replaces our pending one (013 US7). */
  function merge(rows: SpoolMessage[], fromLive = false) {
    const r = mergeById(messages.value, rows)
    const add = r.added as SpoolMessage[]
    if (!add.length && !r.confirmed) return
    messages.value = r.rows as SpoolMessage[]
    if (fromLive && add.length) {
      liveCount.value += add.length
      lastLive.value = add[add.length - 1]
    }
  }

  /**
   * an edited message replaces the row held for its msg_id, in
   * place. It is NOT routed through merge(): mergeById drops a repeat of a
   * row already held as confirmed (feed.mjs line 89), which is why the hub
   * sends `message_edited` as its own frame at all. Nothing re-sorts and
   * nothing counts as "new": FR-ED-009 leaves ts / received_at / cursor
   * untouched, so a typo fix must not ring the new-message pill.
   */
  function applyEdited(row: unknown) {
    messages.value = applyEdit(messages.value, row) as SpoolMessage[]
  }

  /** An emoji was added or removed on a row this feed holds. */
  function applyReactions(update: unknown) {
    messages.value = patchReactions(messages.value, update) as SpoolMessage[]
  }

  /** A deleted message leaves this feed. A msg_id it does not hold is a no-op. */
  function drop(msgId: string) {
    const id = String(msgId || '')
    if (!id || !messages.value.some((m) => m.msg_id === id)) return
    messages.value = withoutMsg(messages.value, id) as SpoolMessage[]
  }

  /** A read failed: the door is a prompt, anything else an error line. 404 = empty topic. */
  function fail(e: unknown, fallback: string) {
    const err = e as { status?: number, message?: string, detail?: string }
    if (isDoor(err)) {
      door.value = { detail: String(err.detail || '') }
      return
    }
    if (err.status !== 404) error.value = err.message || fallback
  }

  /** wui-live-ws §7: after a reconnect, one after=<last cursor> read, deduped by msg_id. */
  async function catchUpAfterReconnect() {
    const id = taskId.value
    if (!id) return
    try {
      const r = await catchUp(api.getTopic, id, messages.value)
      if (taskId.value !== id) return
      if (r) merge(r.rows)
      else await open(id)
    } catch (e) {
      fail(e, i18n.t('feed.error.catch_up_failed'))
    }
  }

  let off: (() => void) | null = null
  let offReconnect: (() => void) | null = null
  let offEdited: (() => void) | null = null
  let offReaction: (() => void) | null = null
  /** `all`: also page to the oldest row (a pinned root needs it); the pane always does.
      `first`: that same newest window, already asked for (utils/lobby-warm);
      a failed one is asked again here. */
  async function open(id: string, opts: { all?: boolean, first?: Promise<{ messages: SpoolMessage[], next: string | null }> } = {}) {
    if (!id) return
    /* the lobby's room task is opened by the page, not by the reader: only the right pane's store moves the reader */
    if (key === 'pane') usePaneFocus().openedTopic()
    const client = live.ensure()
    if (taskId.value && taskId.value !== id && client) client.unsubscribe(taskId.value)
    if (taskId.value !== id) {
      messages.value = []
      archivedAt.value = ''
      visible.value = WINDOW
      search.value = ''
      olderCursor.value = null
    }
    taskId.value = id
    error.value = null
    door.value = null
    if (!off) {
      off = live.onMessage((m) => {
        if (m.task_id === taskId.value) merge([m as unknown as SpoolMessage], true)
      })
    }
    /* another session edited a row this pane is showing */
    if (!offEdited) offEdited = live.onEdited((m) => applyEdited(m))
    if (!offReaction) offReaction = live.onReaction((m) => applyReactions(m))
    if (!offReconnect) offReconnect = live.onReconnected(() => { void catchUpAfterReconnect() })
    // wui-live-ws: subscribe first, then catch up over view-v1
    if (client) client.subscribe(id)
    loading.value = true
    try {
      // 013: newest window first; older windows on Load more (loadOlder)
      const read = () => withSessionRetry(api, () => api.getTopic(id, { order: 'desc', limit: WINDOW }))
      const data = opts.first ? await opts.first.catch(read) : await read()
      merge(data.messages)
      olderCursor.value = data.next
      archivedAt.value = archiveStamp(data)
      if (opts.all || key === 'pane') await loadAll()
    } catch (e) {
      fail(e, i18n.t('feed.error.load_failed'))
    } finally {
      loading.value = false
    }
  }

  /** A message that is not part of the open task, shown in this feed anyway. */
  function admit(rows: SpoolMessage[]) {
    merge(rows || [])
  }

  function close() {
    const client = live.ensure()
    if (taskId.value && client) client.unsubscribe(taskId.value)
    if (offEdited) offEdited()
    offEdited = null
    taskId.value = null
    messages.value = []
    archivedAt.value = ''
  }

  /**
   * Load more was pressed: reveal the next older window. Rows
   * already held are shown first; then the next server window (before=).
   */
  async function loadOlder(which?: 'lobby') {
    const heldMore = which === 'lobby' ? lobbyView.value.hasOlder : view.value.hasOlder
    if (heldMore) {
      visible.value += WINDOW
      return
    }
    if (!olderCursor.value || !taskId.value || loadingOlder.value) return
    loadingOlder.value = true
    try {
      const data = await api.getTopic(taskId.value, { order: 'desc', limit: WINDOW, before: olderCursor.value })
      merge(data.messages)
      olderCursor.value = data.next
      visible.value += WINDOW
    } catch (e) {
      fail(e, i18n.t('feed.error.load_older_failed'))
      olderCursor.value = null
    } finally {
      loadingOlder.value = false
    }
  }

  /** The pinned root of a long topic needs the oldest row: page to the end. */
  async function loadAll() {
    for (let i = 0; i < MAX_PAGES && olderCursor.value; i++) await loadOlder()
  }

  function setSearch(q: string) {
    search.value = q
    visible.value = WINDOW
  }

  /**
   * `opts` is what a MESSAGE-rooted topic needs. Its task_id is the
   * clicked message's msg_id, a task the hub has never seen, so the reply says
   * which task it hangs off (`parentTaskId` -> parent_task_id, hub checkTags:
   * a UUID other than task_id) and which channel it belongs to, and the topic
   * is then reachable from the channel it was started in. Both are omitted for
   * an ordinary reply, which changes nothing about the frame.
   *
   * SPL-964: a send that does not land REJECTS. The caller is the Omnibox
   * (TopBar.onSend), which puts the text back and names the failure; this
   * store used to catch everything, so a reply pending when the socket
   * dropped was lost on the Topics page with the box already empty. A
   * closed socket is resent once with the same frame, as channel.sendLive does.
   */
  async function send(body: string, files: File[] = [], opts: { parentTaskId?: string, channel?: string | null, isParent?: number, pokeChannel?: string } = {}) {
    if (!taskId.value) throw new Error(i18n.t('feed.error.send_failed'))
    let msgId = ''
    sending.value = true
    error.value = null
    try {
      const refs: FileRef[] = []
      for (const f of files) {
        const up = await uploadWithFreshToken(api, live, f) as { file_id: string, sha256: string, bytes: number }
        refs.push({ mode: 'blob', kind: 'file', file_id: up.file_id, sha256: up.sha256, bytes: up.bytes, name: f.name })
      }
      const parsed = parseMention(body)
      const kind = 'note' /* owner 2026-09-26 (topic 1a9a8a84): a person's post is a note; re-type it from the card's kind badge */
      const to = parsed.to === '@channel' ? undefined : parsed.to
      const text = parsed.body
      if (isEmptySend(text, refs)) throw emptySendError()
      const client = live.ensure()
      /* 013 US7 FR-013: shown at once under the msg_id we send; the pushed echo replaces it */
      msgId = crypto.randomUUID()
      const task = taskId.value
      const parent = opts.parentTaskId && opts.parentTaskId !== task ? opts.parentTaskId : undefined
      const channel = opts.channel || undefined
      const parentBit: 0 | 1 = opts.isParent === 0 ? 0 : 1
      merge([pendingRow({ msg_id: msgId, task_id: task, from: live.identity.value, to, kind, body: text, files: refs, channel: channel || null, parent_task_id: parent || null, is_parent: parentBit }) as SpoolMessage])
      if (client) {
        /* specs/058: `@CLE-001@sat …` keeps its box (ambiguous_to_box otherwise) */
        const frame = { task_id: task, kind, body: text, files: refs, to, to_box: to ? parsed.toBox : undefined, msg_id: msgId, parent_task_id: parent, channel, is_parent: parentBit }
        const ack = await sendWithResend(() => client.send(frame)) as { cursor?: string, received_at?: string }
        /* SPL-985 (spec 042 §3): the mention poke. This send names only a
           task, so where it lives (K4) is read from the topic's other rows. */
        const at = channel !== undefined ? { channel } : opts.pokeChannel !== undefined ? { channel: opts.pokeChannel } : topicWhere(messages.value.filter((m) => m.msg_id !== msgId), task)
        void poke({ text: body, addressee: to || '', where: at ? { ...at, taskId: task } : { unknown: true, taskId: task } })
        const own = messages.value.find((m) => m.msg_id === msgId)
        if (own && own.pending && taskId.value === task) {
          merge([{ ...own, pending: false, cursor: ack.cursor, received_at: ack.received_at || own.received_at }])
        }
      } else {
        const own = messages.value.find((m) => m.msg_id === msgId)
        if (own) merge([{ ...own, pending: false }])
      }
    } catch (e) {
      /* the row goes; the text goes back into the Omnibox with the reason */
      if (msgId) messages.value = withoutMsg(messages.value, msgId) as SpoolMessage[]
      throw e
    } finally {
      sending.value = false
    }
  }

  return {
    taskId, messages, newestFirst: newestFirstRows, hasOlder, lobbyRows, lobbyHasOlder, topic, error, door, sending, loading,
    search, liveCount, lastLive, open, close, send, admit, loadOlder, loadAll, setSearch, catchUpAfterReconnect,
    applyEdited, loadingOlder, drop, applyReactions, archivedAt,
  }
}

export function useLiveFeed(key: 'main' | 'pane' = 'main') {
  return defineStore(`live-${key}`, () => setup(key))()
}

/** 005 name kept for callers of the main feed. */
export const useLiveStore = () => useLiveFeed('main')
