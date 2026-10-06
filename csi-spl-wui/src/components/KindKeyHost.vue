<!-- HUM-10 (t1 ffc3b83c): Shift + K opens the kind menu of the selected
     message in every view. A focused message card already does this
     (useMsgShortcuts + KindBadge). This host covers the rows that are not
     cards: a topic row, the flow list, an issue row, and a comment inside
     the issue dialog. Enter or Esc returns the focus to that row. -->
<template>
  <span data-testid="kind-key-host" class="sr-only"></span>
  <KindPicker
    v-if="open"
    :open="open"
    :x="at.x"
    :y="at.y"
    :current="current"
    @close="onClose"
    @choose="setKind"
  />
</template>

<script setup lang="ts">
import type { SpoolMessage } from '~/types/spool'
import { canSetKind } from '~/utils/msg-kind.mjs'
import { openingCardId } from '~/utils/topic-archive.mjs'
import { holdPanel, useMsgShortcutsOn } from '~/composables/useMsgShortcuts'
import { usePhone } from '~/composables/useTouchUi'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useFlowStore } from '~/stores/flow'
import { noteError } from '~/composables/errorJournal.mjs'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const TYPING = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"], [role="textbox"], [role="combobox"]'

const api = useSpoolApi()
const access = useAccessStore()
const edit = useMessageEdit()
const flow = useFlowStore()
const phone = usePhone()
const shortcutsOn = useMsgShortcutsOn()
const { t } = useI18n({ useScope: 'global' })

const open = ref(false)
const current = ref('note')
const at = ref({ x: 0, y: 0 })
let msgId = ''
let back: HTMLElement | null = null
let ticket = 0

function isShiftK(ev: KeyboardEvent) {
  if (ev.repeat || ev.isComposing || ev.ctrlKey || ev.metaKey || ev.altKey || !ev.shiftKey) return false
  return ev.key === 'K' || ev.key === 'k' || ev.code === 'KeyK'
}

function typing(el: Element | null) {
  return Boolean(el?.closest(TYPING))
}

function topicRowOf(active: HTMLElement): HTMLElement | null {
  const direct = active.closest<HTMLElement>('a.topic-row')
  if (direct) return direct
  const side = active.closest('#sidebar-panel-topics')
  if (side) {
    const row = active.closest<HTMLElement>('a.nav-item')
      || side.querySelector<HTMLElement>('a.nav-item[aria-current="true"], a.nav-item.active')
    const id = row?.getAttribute('data-key') || ''
    return row && UUID.test(id) ? row : null
  }
  if (active.closest('.topic-browse__thread, article.msg, [role="dialog"]')) return null
  const list = active.closest<HTMLElement>('.topic-browse__list')
  if (list) {
    return list.querySelector<HTMLElement>('a.topic-row[aria-current="true"], a.topic-row.selected')
      || list.querySelector<HTMLElement>('a.topic-row')
  }
  const main = active.closest('.spool-main')
  if (!main || !main.querySelector('a.topic-row') || main.querySelector('[data-test="issues-heading"]')) return null
  return main.querySelector<HTMLElement>('a.topic-row[aria-current="true"], a.topic-row.selected')
    || main.querySelector<HTMLElement>('a.topic-row')
}

function flowHitOf(active: HTMLElement): { msgId: string, anchor: HTMLElement, back: HTMLElement } | null {
  const list = active.closest<HTMLElement>('[data-testid="left-list"]')
  if (!list || list.getAttribute('data-mode') !== 'flow') return null
  const hit = list.querySelector<HTMLElement>('.side-hit.active, .side-hit[aria-selected="true"]')
  const id = hit?.getAttribute('data-msg-id') || ''
  if (!hit || !id) return null
  return { msgId: id, anchor: hit, back: list }
}

function issueRowOf(active: HTMLElement): HTMLElement | null {
  const direct = active.closest<HTMLElement>('tr.issues-row, .issues-card')
  if (direct) return direct
  if (active.closest('[role="dialog"], article.msg')) return null
  if (!active.closest('.spool-main') || !document.querySelector('[data-test="issues-heading"]')) return null
  return document.querySelector<HTMLElement>('tr.issues-row[data-selected="true"]')
    || document.querySelector<HTMLElement>('.issues-card[data-selected="true"]')
    || document.querySelector<HTMLElement>('tr.issues-row')
    || document.querySelector<HTMLElement>('.issues-card')
}

async function opener(taskId: string): Promise<SpoolMessage | null> {
  try {
    const page = await api.getTopic(taskId, { limit: 40 }) as { messages?: SpoolMessage[] }
    const rows = page.messages || []
    const id = openingCardId(rows, '')
    return rows.find((m) => String(m.msg_id || '') === id) || rows.find((m) => m.msg_id) || null
  } catch {
    return null
  }
}

async function flowMessage(id: string): Promise<SpoolMessage | null> {
  const entry = flow.visible.find((e) => e.msg_id === id || e.key === id)
  const topic = String(entry?.parent_task_id || entry?.task_id || '')
  if (!topic) return null
  try {
    const page = await api.getTopic(topic, { limit: 50 }) as { messages?: SpoolMessage[] }
    return (page.messages || []).find((m) => String(m.msg_id || '') === id) || null
  } catch {
    return null
  }
}

async function issueMessage(key: string): Promise<SpoolMessage | null> {
  try {
    const data = await api.getIssue(key)
    const task = String(data.issue?.task_id || '')
    return task ? opener(task) : null
  } catch {
    return null
  }
}

async function show(anchor: HTMLElement, msg: SpoolMessage, returnTo: HTMLElement, mine: number) {
  if (mine !== ticket) return
  try { await access.load() } catch { /* role stays whatever it was */ }
  if (mine !== ticket) return
  const id = String(msg.msg_id || '')
  if (!id || !canSetKind(msg, edit.viewerId.value, access.me?.role ?? null)) return
  if (open.value) open.value = false
  await nextTick()
  if (mine !== ticket) return
  const r = anchor.getBoundingClientRect()
  back = returnTo
  msgId = id
  current.value = String(msg.kind || 'note')
  at.value = { x: r.left, y: r.bottom + 4 }
  open.value = true
  holdPanel(returnTo)
}

function onKey(ev: KeyboardEvent) {
  if (!isShiftK(ev) || !shortcutsOn.value || phone.value) return
  const active = document.activeElement as HTMLElement | null
  if (!active || typing(active)) return
  if (document.querySelector('.kind-picker, .point-menu, .issues-menu')) return

  const card = active.closest<HTMLElement>('article.msg')
  if (card) {
    /* outside a dialog the card's own shortcut opens the badge */
    if (!card.closest('dialog, [role="dialog"]')) return
    ev.preventDefault()
    ev.stopPropagation()
    holdPanel(card)
    card.querySelector<HTMLElement>('[data-testid="kind-badge-btn"]')?.click()
    return
  }

  const topic = topicRowOf(active)
  if (topic) {
    const id = topic.getAttribute('data-key') || ''
    if (!UUID.test(id)) return
    ev.preventDefault()
    ev.stopPropagation()
    const mine = ++ticket
    void opener(id).then((msg) => { if (msg) void show(topic, msg, topic, mine) })
    return
  }

  const hit = flowHitOf(active)
  if (hit) {
    /* preventDefault only: the list's keep-focus releases on this letter */
    ev.preventDefault()
    const mine = ++ticket
    void flowMessage(hit.msgId).then((msg) => { if (msg) void show(hit.anchor, msg, hit.back, mine) })
    return
  }

  const issue = issueRowOf(active)
  if (!issue) return
  const key = issue.getAttribute('data-key') || ''
  if (!key) return
  ev.preventDefault()
  ev.stopPropagation()
  const mine = ++ticket
  void issueMessage(key).then((msg) => { if (msg) void show(issue, msg, issue, mine) })
}

function onClose() {
  const inMenu = Boolean((document.activeElement as HTMLElement | null)?.closest?.('.kind-picker'))
  open.value = false
  const to = back
  if (!inMenu || !to) return
  void nextTick(() => {
    const a = document.activeElement
    if (a && a !== document.body) return
    if (!to.isConnected) return
    if (!to.matches('a[href], button, input, textarea, select, [tabindex]')) to.setAttribute('tabindex', '-1')
    to.focus({ preventScroll: true })
  })
}

async function setKind(kind: string) {
  const id = msgId
  const next = String(kind || '')
  if (!id || !next || next === current.value) return
  try {
    const row = await api.setMessageKind(id, next)
    edit.applyEverywhere(row)
    current.value = next
  } catch (err) {
    noteError({ source: 'kind-set', message: t('feed.kind_set.failed'), code: (err as { token?: string })?.token, error: err })
  }
}

onMounted(() => window.addEventListener('keydown', onKey, true))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey, true))
</script>
