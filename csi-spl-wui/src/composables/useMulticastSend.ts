/*
 * Spec 186 4.1 step 2, 4.3, 4.4 (row M11; owner HUM-10, t1 032d8010, msgs
 * 5fdfff6c and 4b3833e7): the Multicast action of the select phase.
 *
 * Multicast opens the dialog on the selection. The dialog's check is one
 * `multicast_check` naming exactly the selected task ids (never a pattern,
 * 7.1.2), debounced 300 ms on a text change; an answer to an older req_id is
 * dropped. Send is enabled only when every target is ok (Q9 ALL). Send
 * uploads the files once (Q7 SHR), checks once more with the real text and
 * files, mints one mc_id and sends one ordinary copy per target with its own
 * msg_id (stores/channel.ts sendMulticast). A copy the network failed waits
 * and goes again under the same msg_id; a refused one is listed with Retry
 * under the same msg_id. When every copy is acked the dialog closes and the
 * action reports finished, so the selection empties (7.1.6).
 *
 * The page's composer, its store send and its draft are not used (H5).
 */
import { computed, ref } from 'vue'
import { useChannelStore, type McOutcome, type McSend } from '~/stores/channel'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useTopicSelect } from '~/composables/useTopicSelect'
import type { TopicPick } from '~/stores/topicSelect'
import type { FileRef } from '~/types/spool'

/** One target's line in the dialog: the check's verdict, then the copy's send state. */
export type McLine = TopicPick & { ok: boolean | null, error: string, msg_id: string, state: '' | 'sending' | 'sent' | 'waiting' | 'failed' }
/** A `multicast_checked` answer (7.1.2). */
export type McCheckAnswer = { req_id?: string, ok?: boolean, error?: string, detail?: string, targets?: { task_id: string, channel?: string, title?: string, ok?: boolean, error?: string }[] }
type McApi = { multicastCheck: (frame: Record<string, unknown>) => Promise<McCheckAnswer>, canMulticastCheck?: () => boolean }
type McStore = { sendMulticast: (a: McSend) => Promise<void>, uploadFiles: (files?: unknown[]) => Promise<FileRef[]> }
/** What the Multicast flow needs: the client's check, the store's send, and (tests) the debounce and the id source. */
export type McDeps = { api: McApi, store: McStore, debounceMs?: number, newId?: () => string }

/** The dialog's check runs at most once per this many ms while the text changes (4.1). */
const CHECK_DEBOUNCE_MS = 300

function uuid(): string {
  const c = globalThis.crypto as Crypto | undefined
  if (c && typeof c.randomUUID === 'function') return c.randomUUID()
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`
}

const tokenOf = (e: unknown) => String((e as { token?: string })?.token || (e as Error)?.message || 'error')

function mcState() {
  const lines = ref<McLine[]>([])
  const open = ref(false)
  /* compose: the check gates Send; sending: copies out or waiting for the network; failed: some refused, Retry */
  const phase = ref<'compose' | 'sending' | 'failed'>('compose')
  const checking = ref(false)
  /* a refusal of the whole check (the quota, multicast_none) or the check's own failure */
  const checkError = ref('')
  const checkDetail = ref('')
  const lastReq = ref('')
  /* the text the check reads; once sent, the text kept until every copy is acked */
  const body = ref('')
  const sentText = ref('')
  const count = computed(() => lines.value.length)
  const canSend = computed(() => phase.value === 'compose' && !checking.value && !checkError.value
    && count.value > 0 && lines.value.every((l) => l.ok === true))
  return { lines, open, phase, checking, checkError, checkDetail, lastReq, body, sentText, count, canSend }
}
type McState = ReturnType<typeof mcState>

/** The check's answer on each line; a line it did not reach stays unknown (Send stays off). */
function applyCheck(s: McState, ans: McCheckAnswer) {
  const by = new Map((ans.targets || []).map((t) => [String(t.task_id), t]))
  s.lines.value = s.lines.value.map((l) => {
    const t = by.get(l.task_id)
    if (!t) return { ...l, ok: null, error: '' }
    return { ...l, channel: t.channel || l.channel, title: t.title || l.title, ok: t.ok === true, error: t.ok === true ? '' : String(t.error || 'error') }
  })
  s.checkError.value = ans.ok === true ? '' : String(ans.error || '')
  s.checkDetail.value = ans.ok === true ? '' : String(ans.detail || '')
}

function useMcCheck(s: McState, deps: McDeps, newId: () => string) {
  let timer: ReturnType<typeof setTimeout> | null = null
  const stop = () => { if (timer) clearTimeout(timer); timer = null }
  /** one multicast_check of the lines; true when every target is ok. An older answer is dropped (false). */
  async function check(files: FileRef[] = []): Promise<boolean> {
    stop()
    const req_id = newId()
    s.lastReq.value = req_id
    if (!s.lines.value.length) {
      s.checkError.value = 'multicast_none'
      return false
    }
    s.checking.value = true
    let ans: McCheckAnswer
    try {
      ans = await deps.api.multicastCheck({ req_id, task_ids: s.lines.value.map((l) => l.task_id), files, body: s.body.value })
    } catch (e) {
      if (s.lastReq.value !== req_id) return false
      s.checking.value = false
      s.checkError.value = tokenOf(e)
      return false
    }
    if (!ans || ans.req_id !== s.lastReq.value) return false
    s.checking.value = false
    applyCheck(s, ans)
    return ans.ok === true && s.lines.value.every((l) => l.ok === true)
  }
  /** a change of the text: the check again after the debounce */
  function schedule() {
    stop()
    timer = setTimeout(() => { void check() }, deps.debounceMs ?? CHECK_DEBOUNCE_MS)
  }
  return { check, schedule, stop }
}

function useMcSend(s: McState, deps: McDeps, o: { newId: () => string, check: (f?: FileRef[]) => Promise<boolean>, finish: (ok: boolean) => void }) {
  let refs: FileRef[] | null = null
  let mcId = ''
  const reset = () => { refs = null; mcId = '' }
  /** every copy acked: the dialog closes; none sending and one refused: Retry */
  function settle() {
    if (!s.open.value) return
    const st = s.lines.value.map((l) => l.state)
    if (st.length && st.every((x) => x === 'sent')) return o.finish(true)
    if (st.includes('sending') || st.includes('waiting')) return
    if (st.includes('failed')) s.phase.value = 'failed'
  }
  function onResult(msgId: string, r: McOutcome) {
    const state = r.state === 'refused' ? 'failed' : r.state
    s.lines.value = s.lines.value.map((l) => (l.msg_id === msgId ? { ...l, state, error: state === 'failed' ? String(r.error || 'error') : l.error } : l))
    settle()
  }
  async function dispatch(list: McLine[]) {
    const copies = list.map((l) => ({ task_id: l.task_id, channel: l.channel, msg_id: l.msg_id }))
    await deps.store.sendMulticast({ text: s.sentText.value, files: refs || [], mcId, copies, onResult })
    settle()
  }
  /** Send: files once, the check with the real text and files, then one copy per target */
  async function send(text: string, files?: unknown[]) {
    if (!s.canSend.value) return
    s.phase.value = 'sending'
    s.sentText.value = text
    s.body.value = text
    try {
      refs ??= await deps.store.uploadFiles(files)
    } catch (e) {
      s.phase.value = 'compose'
      s.checkError.value = tokenOf(e)
      return
    }
    if (!(await o.check(refs))) {
      s.phase.value = 'compose'
      return
    }
    mcId ||= o.newId()
    s.lines.value = s.lines.value.map((l) => ({ ...l, msg_id: l.msg_id || o.newId(), state: 'sending', error: '' }))
    await dispatch(s.lines.value)
  }
  /** Retry the refused copies under their own msg_ids and the same mc_id (a stored copy only re-acks) */
  async function retry() {
    if (s.phase.value !== 'failed') return
    s.phase.value = 'sending'
    const again = s.lines.value.filter((l) => l.state === 'failed')
    s.lines.value = s.lines.value.map((l) => (l.state === 'failed' ? { ...l, state: 'sending', error: '' } : l))
    await dispatch(again)
  }
  return { send, retry, reset }
}

/** The Multicast flow on its own deps (the tests inject a stub hub and store). */
export function createMulticast(deps: McDeps) {
  const s = mcState()
  const newId = deps.newId || uuid
  const { check, schedule, stop } = useMcCheck(s, deps, newId)
  let done: ((ok: boolean) => void) | null = null
  function finish(ok: boolean) {
    stop()
    s.open.value = false
    const d = done
    done = null
    d?.(ok)
  }
  const sending = useMcSend(s, deps, { newId, check, finish })
  /** Multicast pressed: the dialog opens on the selection; resolves true when every copy is acked, false when closed */
  function start(selection: TopicPick[]): Promise<boolean> {
    const seen = new Set<string>()
    s.lines.value = selection.filter((p) => p.task_id && !seen.has(p.task_id) && seen.add(p.task_id))
      .map((p) => ({ task_id: p.task_id, channel: p.channel, title: p.title, ok: null, error: '', msg_id: '', state: '' }))
    s.phase.value = 'compose'
    s.checkError.value = ''
    s.checkDetail.value = ''
    s.body.value = ''
    s.sentText.value = ''
    sending.reset()
    s.open.value = true
    const closed = new Promise<boolean>((resolve) => { done = resolve })
    void check()
    return closed
  }
  /** the composer's text changed: the check reads it after the debounce */
  function setBody(text: string) {
    if (s.phase.value !== 'compose' || text === s.body.value) return
    s.body.value = text
    schedule()
  }
  /** a target's cross: off the list, and the check runs again */
  function remove(taskId: string) {
    if (s.phase.value !== 'compose') return Promise.resolve(false)
    s.lines.value = s.lines.value.filter((l) => l.task_id !== taskId)
    return check()
  }
  return { ...s, start, setBody, remove, check, send: sending.send, retry: sending.retry, close: () => finish(false) }
}

let single: ReturnType<typeof createMulticast> | null = null
let canCheck = false

/** The app's one Multicast flow, on the channel store and the spool client. */
export function useMulticastSend() {
  if (!single) {
    const api = useSpoolApi() as unknown as McApi
    canCheck = Boolean(api.canMulticastCheck?.())
    single = createMulticast({ api, store: useChannelStore() as unknown as McStore })
  }
  return single
}

/**
 * The selection bar's Multicast button (7.1.6), registered where the check
 * can run: the mock answers it; live needs the socket's request half, so the
 * button is not offered where Send could never be enabled (as Select by title).
 */
export function useMulticastAction() {
  const mc = useMulticastSend()
  if (canCheck) useTopicSelect().registerAction({ id: 'multicast', icon: 'go', labelKey: 'multicast.action', run: (sel) => mc.start(sel) })
  return mc
}
