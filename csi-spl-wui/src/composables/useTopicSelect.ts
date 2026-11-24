/*
 * Spec 186 7.1.6 (row M3; owner HUM-10, t1 032d8010, msgs 5fdfff6c,
 * 656b2576 and 4b3833e7): the select phase, built once for every bulk
 * action on topics (owner addendum ae2caeb2: Multicast, spec 186 M11, and
 * spec 153's Set priority, 8.3).
 *
 * Ticks (a click, a shift-click run, `x` on the focused card, Esc clears),
 * the page box and Gmail's "Select all N matching", Select by title, and the
 * bar's action list. The selection lives in stores/topicSelect.ts; the tick
 * rules are the issues list's (utils/issues-bulk.ts).
 *
 * Select by title sends the lines as typed in one `topic_select` frame
 * (7.1.2); the hub resolves them. The WUI never evaluates a pattern (4.2):
 * it adds exactly the task ids the answer names.
 */
import { computed, getCurrentScope, nextTick, onScopeDispose, watch } from 'vue'
import { TOPIC_SELECT_DEFAULT_ACTION, uniquePicks, useTopicSelectStore, type TopicPick, type TopicSelectAction } from '~/stores/topicSelect'
import { runBulk } from '~/utils/issues-bulk'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'

/** A `topic_selected` answer (7.1.2). */
export type TopicSelectAnswer = { req_id?: string, ok?: boolean, error?: string, detail?: string, topics?: TopicPick[] }

/** What Select by title did: topics added, none matched, or the bad line and why. */
export type PatternOutcome = { added: number, none: boolean, bad: { line: string, reason: string } | null, error: string }

/** Pages of "Select all N matching" at most (the issues list's bound). */
const MATCH_PAGES_MAX = 100

/**
 * The pattern field's lines exactly as typed: the hub trims, drops empty
 * lines, compiles and matches (4.2). Only the empty lines after the last
 * one go, so each line keeps the number the hub's answer names.
 */
function patternLines(text: string): string[] {
  const lines = String(text ?? '').split('\n')
  while (lines.length && lines[lines.length - 1] === '') lines.pop()
  return lines
}

/** The hub's `topic_select_bad_pattern` detail ("line N: <pattern>: <why>") as the line and the reason. */
function badPatternOf(detail: string): { line: string, reason: string } {
  const m = /^line (\d+): ([\s\S]*)$/.exec(String(detail || ''))
  return m ? { line: m[1]!, reason: m[2]! } : { line: '?', reason: String(detail || '') }
}

/**
 * An answer to Select by title: dropped (null) unless it answers the newest
 * frame sent; a refusal adds nothing and names the line; otherwise the
 * answer's topics, each once.
 */
function readSelectAnswer(newest: string, ans: TopicSelectAnswer | null | undefined): { topics: TopicPick[], bad: PatternOutcome['bad'], error: string } | null {
  if (!ans || !newest || ans.req_id !== newest) return null
  if (!ans.ok) {
    const bad = ans.error === 'topic_select_bad_pattern' ? badPatternOf(String(ans.detail || '')) : null
    return { topics: [], bad, error: bad ? '' : String(ans.detail || ans.error || 'error') }
  }
  return { topics: uniquePicks(Array.isArray(ans.topics) ? ans.topics : []), bad: null, error: '' }
}

function newReqId(): string {
  const c = globalThis.crypto as Crypto | undefined
  if (c && typeof c.randomUUID === 'function') return c.randomUUID()
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`
}

/** A key pressed in a field, or in an open dialog or menu, is not the list's. */
function keyIsElsewhere(ev: KeyboardEvent): boolean {
  const el = ev.target as HTMLElement | null
  return Boolean(el?.closest?.('input:not([type="checkbox"]), textarea, select, [contenteditable="true"], [role="dialog"], [role="menu"]'))
}

/** The reader's workspace: a mock switch re-points the claims, a live one reloads the page. */
function useWorkspaceSync(store: ReturnType<typeof useTopicSelectStore>) {
  const session = useSessionStore()
  const api = useSpoolApi()
  watch(() => String(session.claims?.t || api.tenant || ''), (id) => store.setWorkspace(id), { immediate: true })
}

function useSelectByTitle(store: ReturnType<typeof useTopicSelectStore>) {
  const api = useSpoolApi() as unknown as { topicSelect: (frame: Record<string, unknown>) => Promise<TopicSelectAnswer>, canTopicSelect?: () => boolean }
  /** Select by title is offered only where the client can send topic_select (never a field that always fails, R7 W1) */
  const byTitleOn = Boolean(api.canTopicSelect?.())
  /** the action the frame names: the first registered button's, else Multicast (7.1.6) */
  const action = () => store.actions[0]?.id || TOPIC_SELECT_DEFAULT_ACTION
  /** one `topic_select` with the lines as typed; adds exactly the answer's task ids (a newer frame drops this answer) */
  async function selectByTitle(text: string): Promise<PatternOutcome | null> {
    const patterns = patternLines(text)
    if (!patterns.length) return null
    const req_id = newReqId()
    store.lastReq = req_id
    let ans: TopicSelectAnswer
    try {
      ans = await api.topicSelect({ req_id, action: action(), task_ids: [], patterns })
    } catch (e) {
      if (store.lastReq !== req_id) return null
      return { added: 0, none: false, bad: null, error: String((e as { token?: string })?.token || (e as Error)?.message || 'error') }
    }
    const read = readSelectAnswer(store.lastReq, ans)
    if (!read) return null
    const before = store.count
    store.add(read.topics)
    return { added: store.count - before, none: !read.bad && !read.error && read.topics.length === 0, bad: read.bad, error: read.error }
  }
  return { selectByTitle, byTitleOn }
}

function useSelectRun(store: ReturnType<typeof useTopicSelectStore>) {
  /** a bar button: its action runs on the selection; a finished one (run -> true) empties it */
  async function runAction(a: TopicSelectAction) {
    if (store.busy || !store.count) return
    store.busy = true
    try {
      if ((await a.run([...store.picks])) === true) store.clear()
    } finally {
      store.busy = false
    }
  }
  /** an action's per-topic calls, as on issues: a few at once, a progress line, a result naming what failed */
  async function runEach(fn: (p: TopicPick) => Promise<unknown>) {
    const picks = [...store.picks]
    const by = new Map(picks.map((p) => [p.task_id, p]))
    store.result = null
    store.progress = { done: 0, total: picks.length }
    try {
      const out = await runBulk(picks.map((p) => p.task_id), (id) => fn(by.get(id)!), { onProgress: (done, total) => { store.progress = { done, total } } })
      store.result = { done: out.done.length, total: picks.length, failed: out.failed.map((f) => by.get(f.key)?.title || f.key) }
      return out
    } finally {
      store.progress = null
    }
  }
  return { runAction, runEach }
}

function useSelectPage(store: ReturnType<typeof useTopicSelectStore>) {
  /** more topics match than the page holds: Gmail's line under a page-wide tick */
  const canMatchAll = computed(() => store.page === 'all' && Boolean(store.matcher?.more()))
  /** "Select all N matching": the page's pages to the end, then every topic shown, under the page's own filter */
  async function selectAllMatching() {
    const m = store.matcher
    if (!m || store.matching) return
    store.matching = true
    try {
      for (let i = 0; i < MATCH_PAGES_MAX && m.more(); i++) await m.load()
      await nextTick()
      store.add(store.shown)
      store.allMatching = !m.more()
    } finally {
      store.matching = false
    }
  }
  /** Esc empties the selection (as on issues), unless a field, dialog or menu has the key */
  function onKey(ev: KeyboardEvent) {
    if (ev.key !== 'Escape' || !store.active || ev.defaultPrevented || keyIsElsewhere(ev)) return
    store.clear()
  }
  return { canMatchAll, selectAllMatching, onKey }
}

/** The select phase: the shared selection, its page tools, Select by title and the action list. */
export function useTopicSelect() {
  const store = useTopicSelectStore()
  useWorkspaceSync(store)
  /** a bulk action joins the bar while the caller's scope lives */
  function registerAction(a: TopicSelectAction): () => void {
    const off = store.register(a)
    if (getCurrentScope()) onScopeDispose(off)
    return off
  }
  return { store, registerAction, ...useSelectByTitle(store), ...useSelectRun(store), ...useSelectPage(store) }
}

/**
 * One topic card's part (MessageCard): its box, a shift-click run, `x`, and
 * on a phone a tap that toggles instead of opening the topic while the
 * selection is not empty (4.6, H4). `on` = the card may be ticked.
 */
export function useCardTopicSelect(o: { on: () => boolean, msg: () => { task_id?: string | null, channel?: string | null }, title: () => string, phone: () => boolean }) {
  const store = useTopicSelectStore()
  const pick = (): TopicPick => ({ task_id: String(o.msg().task_id || ''), channel: String(o.msg().channel || ''), title: o.title() })
  const ticked = computed(() => o.on() && store.has(String(o.msg().task_id || '')))
  /** the selection is not empty: every tickable card shows its box, a phone tap toggles, the swipes rest */
  const selecting = computed(() => o.on() && store.active)
  function toggle(ev?: MouseEvent | KeyboardEvent | null, on?: boolean) {
    if (!o.on()) return
    const want = typeof on === 'boolean' ? on : !ticked.value
    if (ev?.shiftKey) store.range(pick(), want)
    else store.toggle(pick(), want)
  }
  /** `x` on the focused card ticks it (as on issues) */
  function onKey(ev: KeyboardEvent): boolean {
    if (!o.on() || ev.key !== 'x' || ev.ctrlKey || ev.metaKey || ev.altKey || keyIsElsewhere(ev)) return false
    ev.preventDefault()
    toggle(null)
    return true
  }
  /** a phone tap on the card while selecting: toggles, the topic does not open */
  function onTap(ev: MouseEvent): boolean {
    if (!selecting.value || !(o.phone() || (ev as PointerEvent).pointerType === 'touch')) return false
    const el = ev.target as HTMLElement | null
    if (el?.closest?.('a, button, input, textarea, select')) return false
    ev.preventDefault()
    ev.stopPropagation()
    toggle(ev)
    return true
  }
  return { ticked, selecting, toggle, onKey, onTap }
}
