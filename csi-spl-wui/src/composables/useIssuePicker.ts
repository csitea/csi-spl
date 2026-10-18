import type { ComputedRef, Ref } from 'vue'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { ISSUE_STATUSES, type EpicSummary, type Issue, type IssueLabel } from '~/utils/issues.mjs'
import { ISSUE_LEVELS, ISSUE_PRIORITIES, applyLabelFrame, levelKey, statusHintKey, statusLabel } from '~/utils/issues-view.mjs'
import type { IssuePickerMenu, IssueSave, IssuesApi } from '~/composables/issuesPageTypes'

/**
 * The page's one picker (status, priority, assignee, label, epic, level and
 * the level moves), for a row, the open issue, the new-issue draft or every
 * checked row. Moved out of pages/issues.vue (r13-06).
 */
export type IssueDraft = {
  title: string, description: string, status: string, priority: number,
  assignee: string, labels: string[], deadlineLocal: string,
  epic: string, kind: 'issue' | 'epic' | 'feature', discussions: string[],
}
export type IssuePickerOpts = {
  api: IssuesApi
  t: (key: string) => string
  phone: ComputedRef<boolean>
  issues: Ref<Issue[]>
  labels: Ref<IssueLabel[]>
  epics: Ref<EpicSummary[]>
  detail: Ref<Issue | null>
  creating: Ref<boolean>
  draft: IssueDraft
  cursorKey: Ref<string>
  busy: Ref<boolean>
  saveError: Ref<string>
  failKey: (e: unknown) => string
  save: IssueSave
  runBulkPatch: (kind: string, value: string) => Promise<void>
}

export function useIssuePicker(o: IssuePickerOpts) {
  const menu = ref<IssuePickerMenu | null>(null)
  const menuIndex = ref(0)
  const menuPos = ref({ top: 80, left: 80 })
  const labelName = ref('')
  const menuOptions = computed(() => pickerOptions(o, menu.value))
  const menuStyle = computed(() => ({ top: `${menuPos.value.top}px`, left: `${menuPos.value.left}px` }))
  function openMenu(kind: string, issue: Issue, ev?: Event) {
    if (issue?.key && issue.key !== 'draft') o.cursorKey.value = issue.key
    const el = ev && (ev.currentTarget as HTMLElement)
    const r = el && el.getBoundingClientRect ? el.getBoundingClientRect() : null
    /* open aligned under the trigger; the real right-edge clamp runs once the
       menu has a measured width (CLE-77806: the property panel sits near the
       viewport's right edge, so a fixed guess over-shifted the picker there). */
    menuPos.value = {
      top: r ? r.bottom + 4 : 120,
      left: Math.max(8, r ? r.left : 80),
    }
    menu.value = { kind, key: issue?.key || '' }
    menuIndex.value = 0
    labelName.value = ''
    void nextTick(clampMenuIntoView)
  }
  /* keep the open picker inside the viewport by its actual width, shifting left
     only when it would truly overflow the right edge (a phone sheet is full-width
     via CSS, so its inline left is ignored - nothing to clamp). */
  function clampMenuIntoView() {
    if (o.phone.value) return
    const el = document.querySelector('[data-test=issues-menu]') as HTMLElement | null
    if (!el) return
    const w = el.getBoundingClientRect().width
    const maxLeft = window.innerWidth - 8 - w
    if (menuPos.value.left > maxLeft) menuPos.value.left = Math.max(8, maxLeft)
  }
  const s = { menu, menuIndex, menuPos, labelName }
  const moves = useLevelMoves(o, openMenu)
  const apply = usePickerApply(o, s, moves.moveLevel)
  return { ...s, menuOptions, menuStyle, openMenu, clampMenuIntoView, ...moves, ...apply }
}

function pickerOptions(o: IssuePickerOpts, menu: IssuePickerMenu | null) {
  const kind = menu?.kind || ''
  const hint = ''
  if (kind === 'status') return ISSUE_STATUSES.map((s) => ({ value: s, label: statusLabel(s), hint: o.t(statusHintKey(s)) }))
  if (kind === 'priority') return ISSUE_PRIORITIES.map((n) => ({ value: String(n), label: String(n), hint }))
  if (kind === 'label') return o.labels.value.filter((l) => l.id !== 'epic').map((l) => ({ value: l.id, label: l.name, hint }))
  if (kind === 'epic') return [{ value: '', label: o.t('issues.no_epic'), hint }, ...o.epics.value.map((e) => ({ value: e.key, label: `${e.key} ${e.title}`, hint }))]
  if (kind === 'level') return ISSUE_LEVELS.map((n) => ({ value: String(n), label: `${n} ${o.t(levelKey(n))}`, hint }))
  /* SPL-972 level moves: to 2 under which epic / feature, to 3 under which issue */
  if (kind === 'move-epic') return o.epics.value.filter((e) => e.key !== menu?.key).map((e) => ({ value: e.key, label: `${e.key} ${e.title}`, hint }))
  if (kind === 'move-parent') return levelTwoParents(o.issues.value, menu?.key || '').map((i) => ({ value: i.key, label: `${i.key} ${i.title}`, hint }))
  return []
}

/* level-2 issues an issue can go under (SPL-972): same epic first, never itself */
function levelTwoParents(issues: Issue[], key: string) {
  const me = issues.find((i) => i.key === key)
  const twos = issues.filter((i) => i.level === 2 && i.key !== key)
  const same = me?.epic ? twos.filter((i) => i.epic === me.epic) : []
  return same.length ? same : twos
}

/*
 * owner, topic e0f6f074: "add the dropboxes for the level column as well".
 * The level is the tree's (SPL-949), so a new level MOVES the issue:
 *   -> 1  it becomes a feature at the top (kind feature, no parent)
 *   -> 2  from 3: straight under its epic; from 1: pick the epic / feature
 *   -> 3  pick the level-2 issue it goes under
 * The hub still judges the tree (an epic with issues cannot drop a level) and
 * its refusal is shown; the box snaps back to the real level either way.
 */
function useLevelMoves(o: IssuePickerOpts, openMenu: (kind: string, issue: Issue, ev?: Event) => void) {
  function onRowLevel(issue: Issue, ev: Event) {
    const sel = ev.target as HTMLSelectElement
    const want = Number(sel.value)
    sel.value = String(issue.level)
    moveLevel(issue, want, ev)
  }
  function moveLevel(issue: Issue, want: number, ev?: Event) {
    if (!want || want === issue.level) return
    if (want === 1) { void o.save(issue.key, { kind: 'feature' }); return }
    if (want === 2 && issue.level === 3 && issue.epic) { void o.save(issue.key, { parent: issue.epic }); return }
    openMenu(want === 2 ? 'move-epic' : 'move-parent', issue, ev)
  }
  return { onRowLevel, moveLevel }
}

type PickerState = { menu: Ref<IssuePickerMenu | null>, labelName: Ref<string> }

function applyToDraft(draft: IssueDraft, kind: string, value: string) {
  if (kind === 'status') draft.status = value
  else if (kind === 'priority') draft.priority = Number(value)
  else if (kind === 'assign') draft.assignee = value
  else if (kind === 'epic') draft.epic = value
  else if (kind === 'label') {
    draft.labels = draft.labels.includes(value) ? draft.labels.filter((x) => x !== value) : [...draft.labels, value]
  }
}

function pickBody(kind: string, value: string, issue: Issue): Record<string, unknown> {
  const body: Record<string, unknown> = {}
  if (kind === 'status') body.status = value
  else if (kind === 'priority') body.priority = Number(value)
  else if (kind === 'assign') body.assignee = value
  else if (kind === 'epic') body.parent = value /* issues-v1: parent is the epic; an older hub knows only parent */
  else if (kind === 'move-epic') { body.kind = 'issue'; body.parent = value }
  else if (kind === 'move-parent') { if (issue.level === 1) body.kind = 'issue'; body.parent = value }
  else if (kind === 'label') {
    body.labels = issue.labels.includes(value) ? issue.labels.filter((x) => x !== value) : [...issue.labels, value]
  }
  return body
}

function usePickerApply(o: IssuePickerOpts, s: PickerState, moveLevel: (issue: Issue, want: number) => void) {
  async function applyMenu(value: string) {
    const kind = s.menu.value?.kind || ''
    if (!kind) return
    if (s.menu.value?.bulk) { s.menu.value = null; await o.runBulkPatch(kind, value); return }
    if (o.creating.value) {
      applyToDraft(o.draft, kind, value)
      if (kind !== 'label') s.menu.value = null
      return
    }
    /* the row the menu was opened on, not whichever issue the detail shows */
    const issue = o.issues.value.find((i) => i.key === s.menu.value?.key) || o.detail.value
    if (!issue || !issue.key) return
    /* SPL-992: the phone's level sheet moves like the sheet's level box; a move
       that needs a parent opens the next sheet */
    if (kind === 'level') { s.menu.value = null; moveLevel(issue, Number(value)); return }
    await o.save(issue.key, pickBody(kind, value, issue))
    if (kind !== 'label') s.menu.value = null
  }
  /* SPL-1633: the labels the open picker's issue holds - the picker marks them,
     and a pick on a marked one takes it off (applyMenu toggles) */
  function menuLabels(): string[] {
    if (o.creating.value) return o.draft.labels
    const key = s.menu.value?.key
    const issue = (key && o.issues.value.find((i) => i.key === key)) || o.detail.value
    return issue?.labels || []
  }
  function labelSet(id: string) {
    return menuLabels().includes(id)
  }
  /* Backspace in the empty Label name box takes the last label off the issue */
  function onLabelNameBackspace(ev: KeyboardEvent) {
    if (s.labelName.value) return
    ev.preventDefault()
    const set = menuLabels()
    const last = set[set.length - 1]
    if (last) void applyMenu(last)
  }
  async function addLabel() {
    const name = s.labelName.value.trim()
    if (!name) return
    o.busy.value = true
    o.saveError.value = ''
    try {
      const data = await withSessionRetry(o.api, () => o.api.createIssueLabel({ name }))
      o.labels.value = applyLabelFrame(o.labels.value, { type: 'issue_label', label: data.label })
      s.labelName.value = ''
      await applyMenu(data.label.id)
    } catch (e) {
      o.saveError.value = o.failKey(e)
    } finally {
      o.busy.value = false
    }
  }
  return { applyMenu, labelSet, onLabelNameBackspace, addLabel }
}
