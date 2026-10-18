import type { ComputedRef, Ref } from 'vue'
import type { RouteLocationNormalizedLoaded } from 'vue-router'
import type { Issue } from '~/utils/issues.mjs'
import { tabForPath } from '~/utils/sidebar-tabs.mjs'
import { issueShortcutFor } from '~/utils/msg-shortcuts.mjs'
import { useMsgShortcutsHelp } from '~/composables/useMsgShortcuts'
import type { IssuePickerMenu } from '~/composables/issuesPageTypes'

/**
 * The page's keyboard (J / K, the cell cursor, S / P / A / L / E / C / X, the
 * Shift + letter message keys, Esc in its order) and the click outside a
 * pop-up list. Moved out of pages/issues.vue (r13-06).
 */
export type IssueKeysOpts = {
  route: RouteLocationNormalizedLoaded
  pageEl: Ref<HTMLElement | null>
  phone: ComputedRef<boolean>
  modalOpen: ComputedRef<boolean>
  creating: Ref<boolean>
  detail: Ref<Issue | null>
  form: ComputedRef<unknown>
  flat: ComputedRef<Issue[]>
  cursorKey: Ref<string>
  cursorCol: Ref<string>
  deadlineEditKey: Ref<string>
  filtersOpen: Ref<boolean>
  sortOpen: Ref<boolean>
  statusOpen: Ref<boolean>
  selected: Ref<string[]>
  keysOn: Ref<boolean>
  menu: Ref<IssuePickerMenu | null>
  menuIndex: Ref<number>
  menuOptions: ComputedRef<{ value: string }[]>
  descEl: Ref<{ edit: () => Promise<void> } | null>
  applyMenu: (value: string) => Promise<void>
  openMenu: (kind: string, issue: Issue, ev?: Event) => void
  cellEl: (key: string, col: string) => HTMLElement | null
  focusCell: () => void
  stepCol: (delta: number) => void
  editCell: (issue: Issue, col: string) => void
  move: (delta: number) => Promise<void>
  choose: (issue: Issue) => void
  closeDetail: () => void
  startCreate: () => void
  cancelCreate: () => void
  clearSelection: () => void
  toggleFocused: () => void
  runIssueShortcut: (letter: string) => void
  detailOrDraft: () => Issue
}

function typingTarget(el: EventTarget | null) {
  if (!(el instanceof HTMLElement)) return false
  const tag = el.tagName
  /* a row's box keeps the list keys (j / k / x) working, Gmail's way */
  if (tag === 'INPUT' && (el as HTMLInputElement).type === 'checkbox') return false
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable
}
/* SPL-1027: the issue modal is the ONE open dialog and holds the issue */
function issueModal(): HTMLElement | null {
  const open = document.querySelectorAll<HTMLElement>('[aria-modal="true"]')
  return open.length === 1 && open[0].querySelector('[data-test=issues-detail]') ? open[0] : null
}

/* SPL-1027: a picker opened by S / P / A / L sits under its control - the
   modal's field, or the row's cell - never at a fixed corner of the page */
const KEY_ANCHOR: Record<string, [string, string]> = {
  status: ['issues-status', 'status'],
  priority: ['issues-priority', 'priority'],
  assign: ['issues-assignee', 'assignee'],
  label: ['issues-labels', 'label'],
}
function keyAnchor(o: IssueKeysOpts, kind: string, issue: Issue): Event | undefined {
  const [field, col] = KEY_ANCHOR[kind] || ['', '']
  const el = o.modalOpen.value
    ? document.querySelector(`[data-test=issues-detail] [data-test=${field}]`)
    : (!o.phone.value && issue.key && issue.key !== 'draft' ? o.cellEl(issue.key, col) : null)
  return el ? { currentTarget: el } as unknown as Event : undefined
}

/* Esc inside the issue modal: a picker closes first, then a text area is
   left (the description saves on blur, a comment draft stays), and only then
   UiDialog closes the modal. Capture phase: UiDialog's own keydown stops Esc
   before the page sees it. */
function onDocKeyCapture(o: IssueKeysOpts, ev: KeyboardEvent) {
  if (ev.key !== 'Escape' || o.phone.value || !o.modalOpen.value) return
  const modal = issueModal()
  if (!modal) return
  if (o.menu.value) { ev.preventDefault(); ev.stopPropagation(); o.menu.value = null; return }
  const el = ev.target
  if (el instanceof HTMLTextAreaElement && modal.contains(el)) {
    ev.preventDefault()
    ev.stopPropagation()
    el.blur()
    modal.focus() /* focus stays in the dialog, so the next Esc closes it */
  }
}

/* Esc, in its order: the open thing closes first, the issue last */
function onEscape(o: IssueKeysOpts, ev: KeyboardEvent, inModal: boolean, typing: boolean) {
  const menuOpen = Boolean(o.menu.value)
  ev.preventDefault()
  /* focus outside the panel (a click on its padding): UiDialog never saw it */
  if (inModal) { if (menuOpen) o.menu.value = null; else o.closeDetail(); return }
  if (o.deadlineEditKey.value) { o.deadlineEditKey.value = ''; o.focusCell(); return }
  if (o.filtersOpen.value || o.sortOpen.value) { o.filtersOpen.value = false; o.sortOpen.value = false; return }
  if (menuOpen || o.statusOpen.value) { o.menu.value = null; o.statusOpen.value = false; return }
  if (typing) { (ev.target as HTMLElement).blur(); return }
  if (o.selected.value.length) o.clearSelection()
  else if (o.creating.value && !o.phone.value) o.cancelCreate()
  else if (o.cursorCol.value) { o.cursorCol.value = ''; (ev.target as HTMLElement)?.blur?.() }
  else o.closeDetail()
}

function onMenuKey(o: IssueKeysOpts, ev: KeyboardEvent) {
  const key = ev.key
  if (key === 'ArrowDown' || key === 'j' || key === 'J') { o.menuIndex.value = Math.min(o.menuOptions.value.length - 1, o.menuIndex.value + 1); ev.preventDefault(); return }
  if (key === 'ArrowUp' || key === 'k' || key === 'K') { o.menuIndex.value = Math.max(0, o.menuIndex.value - 1); ev.preventDefault(); return }
  if (key === 'Enter') {
    const opt = o.menuOptions.value[o.menuIndex.value]
    if (opt) void o.applyMenu(opt.value)
    ev.preventDefault()
  }
}

function onDocKey(o: IssueKeysOpts, ev: KeyboardEvent) {
  if (tabForPath(o.route.path) !== 'issues') return
  /* the kind menu is teleported to <body>; Enter and Esc are its own */
  if (document.querySelector('.kind-picker')) return
  const inModal = Boolean(document.querySelector('[aria-modal="true"]'))
  if (inModal && !issueModal()) return
  const typing = typingTarget(ev.target)
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return
  if (ev.key === 'Escape') { onEscape(o, ev, inModal, typing); return }
  if (typing) return
  if (o.menu.value) { onMenuKey(o, ev); return }
  const k = ev.key.toLowerCase()
  /* in the issue modal only its own keys: E and the S / P / A / L pickers */
  if (inModal && !['e', 's', 'p', 'a', 'l'].includes(k)) return
  if (document.querySelector('.kind-picker, .point-menu')) return
  /* HUM-10 (owner, t1 aedca86a, d8f61702): on the list, Shift + a letter is
     the message key for the same action on the selected row (Shift + A
     archives); the plain letters stay the sheet's own pickers */
  if (!inModal && !o.creating.value) {
    const sc = issueShortcutFor(ev, { enabled: o.keysOn.value, phone: o.phone.value })
    if (sc?.type === 'help') { useMsgShortcutsHelp().value = true; ev.preventDefault(); return }
    if (sc?.type === 'action') { o.runIssueShortcut(sc.key); ev.preventDefault(); return }
  }
  /* HUM-10 (Gmail): x checks / unchecks the focused row, else the selected one */
  if (k === 'x' && !ev.shiftKey && !inModal && !o.creating.value) { o.toggleFocused(); ev.preventDefault(); return }
  onListKey(o, ev, k)
}

function onListKey(o: IssueKeysOpts, ev: KeyboardEvent, k: string) {
  const key = ev.key
  if (k === 'j' || key === 'ArrowDown') { void o.move(1).then(o.focusCell); ev.preventDefault(); return }
  /* Shift + K is the message kind menu (HUM-10 t1 ffc3b83c), not move-up. */
  if ((k === 'k' && !ev.shiftKey) || key === 'ArrowUp') { void o.move(-1).then(o.focusCell); ev.preventDefault(); return }
  /* SPL-1027: Left / Right move the cell cursor, Enter edits the cell */
  if (!o.phone.value && (key === 'ArrowRight' || key === 'ArrowLeft')) { o.stepCol(key === 'ArrowRight' ? 1 : -1); ev.preventDefault(); return }
  if (key === 'Enter') {
    const issue = o.flat.value.find((i) => i.key === o.cursorKey.value) || o.flat.value[0]
    if (issue && o.cursorCol.value && !o.phone.value) o.editCell(issue, o.cursorCol.value)
    else if (issue) o.choose(issue)
    ev.preventDefault()
    return
  }
  if (k === 'c') { o.startCreate(); ev.preventDefault(); return }
  if (k === 'e' && o.form.value) { void o.descEl.value?.edit(); ev.preventDefault(); return }
  const kind = ({ s: 'status', p: 'priority', a: 'assign', l: 'label' } as Record<string, string>)[k]
  const issue = o.creating.value ? o.detailOrDraft() : (o.detail.value || o.flat.value.find((i) => i.key === o.cursorKey.value) || o.flat.value[0])
  if (kind && issue) { o.openMenu(kind, issue, keyAnchor(o, kind, issue)); ev.preventDefault() }
}

/* owner, topic e0f6f074 (SPL-972): every pop-up list closes on a click outside it */
function onDocPointer(o: IssueKeysOpts, ev: Event) {
  const t = ev.target
  const inside = (sel: string) => {
    const el = o.pageEl.value?.querySelector(sel)
    return Boolean(el && t instanceof Node && el.contains(t))
  }
  /* the menu may ride over the issue modal, teleported out of the page */
  const menuEl = document.querySelector('[data-test=issues-menu]')
  if (o.statusOpen.value && !inside('[data-test=issues-filter-status]')) o.statusOpen.value = false
  if (o.menu.value && !(menuEl && t instanceof Node && menuEl.contains(t))) o.menu.value = null
  if (o.deadlineEditKey.value && !inside('[data-deadline-edit="true"]')) o.deadlineEditKey.value = ''
}

export function useIssueKeys(o: IssueKeysOpts) {
  const key = (ev: KeyboardEvent) => onDocKey(o, ev)
  const capture = (ev: KeyboardEvent) => onDocKeyCapture(o, ev)
  const pointer = (ev: Event) => onDocPointer(o, ev)
  onMounted(() => {
    document.addEventListener('keydown', key)
    document.addEventListener('keydown', capture, true)
    document.addEventListener('pointerdown', pointer)
  })
  onUnmounted(() => {
    document.removeEventListener('keydown', key)
    document.removeEventListener('keydown', capture, true)
    document.removeEventListener('pointerdown', pointer)
  })
}
