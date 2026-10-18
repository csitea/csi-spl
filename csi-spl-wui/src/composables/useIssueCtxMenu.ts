import type { ComputedRef, Ref } from 'vue'
import type { Router, RouteLocationNormalizedLoaded } from 'vue-router'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { normalizeIssue, type Issue } from '~/utils/issues.mjs'
import { issueShortcutHint, issueShortcutItem } from '~/utils/msg-shortcuts.mjs'
import { aiSubject } from '~/utils/msg-ai-actions.mjs'
import { useAiMenuGroup } from '~/composables/useAiMenuGroup'
import { useMsgShortcutsOn } from '~/composables/useMsgShortcuts'
import { useIssueMenu, type IssueMenuTarget } from '~/composables/useIssueMenu'
import { issueTarget } from '~/composables/useIssueActConfirm'
import type { IssueMenuItem } from '~/components/IssueRowMenu.vue'
import type { IssuesApi } from '~/composables/issuesPageTypes'

/**
 * SPL-1226: the right-click / long-press context menu of a row, a card, the
 * epics sidebar and the title-row button, with its AI actions group and the
 * Shift + letter keys. Moved out of pages/issues.vue (r13-06).
 */
export type IssueCtxMenuOpts = {
  api: IssuesApi
  route: RouteLocationNormalizedLoaded
  router: Router
  issues: Ref<Issue[]>
  subtasks: Ref<Issue[]>
  detail: Ref<Issue | null>
  cursorKey: Ref<string>
  flat: ComputedRef<Issue[]>
  saveError: Ref<string>
  selectedEpic: ComputedRef<IssueMenuTarget | null>
  menuPos: Ref<{ top: number, left: number }>
  copyText: (text: string, key: string) => Promise<unknown>
  choose: (issue: Issue) => void
  openIssueKey: (key: string) => Promise<void>
  openMenu: (kind: string, issue: Issue, ev?: Event) => void
  askAction: (action: 'archive' | 'delete', tg: IssueMenuTarget) => void
  askDelete: (issue: Issue) => void
  loadComments: (issue: Issue | null) => Promise<void>
  sendToDiscussion: (issue: Issue, text: string) => Promise<void>
}

/* HUM-10 (owner, t1 aedca86a, bbc53649): "the same right-click menu as all
   of the others ... Archive, Delete, and Copy Link", plus what the others
   offer that fits an issue: Move (the message menu's) and Open parent.
   Priority and labels stay on the row's cells and the plain P / L keys. */
function menuItemsFor(tg: IssueMenuTarget, fromButton: boolean): IssueMenuItem[] {
  const items: IssueMenuItem[] = []
  /* CLE-77816 (owner, topic 4365c545): Edit is the first item everywhere the
     menu opens - it opens the same issue dialog (epic / feature included). */
  items.push({ id: 'edit', icon: 'edit', labelKey: 'issues_menu.edit' })
  /* from the title-row button the epic is already the open view - no "Open" */
  if (!fromButton) items.push({ id: 'open', icon: 'open', labelKey: 'issues_menu.open' })
  if (!tg.top && tg.parent) items.push({ id: 'parent', icon: 'parent', labelKey: 'issues_menu.open_parent' })
  items.push({ id: 'copy', icon: 'copy', labelKey: 'issues_menu.copy_link' })
  if (!tg.top) {
    items.push({ id: 'status', icon: 'pencil', labelKey: 'issues_menu.status' })
    items.push({ id: 'assign', icon: 'user', labelKey: 'issues_menu.assign' })
    items.push({ id: 'move', icon: 'move', labelKey: 'issues_menu.move' })
  }
  items.push({ id: 'archive', icon: 'archive', labelKey: 'issues_menu.archive' })
  items.push({ id: 'delete', icon: 'delete', labelKey: 'issues_menu.delete', danger: true })
  return items
}

/* the shareable link for a menu target: an epic/feature opens its filtered
   view (?epic=), a plain issue deep-links itself (?issue=) */
function issueLinkFor(tg: IssueMenuTarget): string {
  const q = tg.top ? `?epic=${encodeURIComponent(tg.key)}` : `?issue=${encodeURIComponent(tg.key)}`
  const rel = `/issues${q}`
  if (import.meta.client) { try { return new URL(rel, window.location.origin).href } catch { /* fall through */ } }
  return rel
}

export function useIssueCtxMenu(o: IssueCtxMenuOpts) {
  const { target: ctxTarget, point: ctxPoint, openAt: openCtxMenu, close: closeCtxMenu, editRequest } = useIssueMenu()
  /* owner b82f3853: the same menu opened from the title-row button, not a
     right-click. Then it omits "Open" (the epic is already the view) and it
     right-aligns under the button. */
  const ctxFromButton = ref(false)
  /* the shortcut switch (Settings -> Behaviour), desktop only - the messages' one */
  const keysOn = useMsgShortcutsOn()
  const aiGroup = useIssueAiGroup(o, ctxTarget)
  const ctxItems = computed<IssueMenuItem[]>(() => {
    const tg = ctxTarget.value
    if (!tg) return []
    const items = menuItemsFor(tg, ctxFromButton.value)
    const hinted = keysOn.value ? items.map((it) => ({ ...it, keyHint: issueShortcutHint(it.id) || undefined })) : items
    return aiGroup.items(hinted) as IssueMenuItem[]
  })
  /* owner b82f3853: the title-row actions button opens the same menu, targeting
     the epic/feature the view is filtered to, right-aligned under the button. */
  function openEpicMenu(ev: MouseEvent) {
    const tg = o.selectedEpic.value
    if (!tg) return
    const r = (ev.currentTarget as HTMLElement).getBoundingClientRect()
    ctxFromButton.value = true
    openCtxMenu(tg, Math.max(8, r.right - 176), r.bottom + 4)
  }
  function onCtxClose() {
    /* the phone's "AI actions" entry keeps the sheet open, showing the actions */
    if (aiGroup.keep()) return
    closeCtxMenu()
    ctxFromButton.value = false
  }
  /* CLE-77816 (owner, topic 4365c545): Edit opens the same issue dialog for the
     target - an epic / feature edits like an issue. A held row opens straight
     away; an epic (often not in the kind=issue list) is fetched first, the same
     path openParent uses. */
  async function editTarget(tg: IssueMenuTarget) {
    onCtxClose()
    await o.openIssueKey(tg.key)
  }
  const runIssueItem = useRunIssueItem(o, closeCtxMenu, editTarget)
  function onCtxChoose(id: string) {
    const tg = ctxTarget.value
    if (!tg) return
    const pt = { ...ctxPoint.value }
    if (aiGroup.more(id)) return
    if (id.startsWith('ai-')) { void aiGroup.run(id, tg); return }
    runIssueItem(id, tg, pt)
  }
  /* Shift + `letter` on the row holding the focus, else the selected one (the
     messages' rule): the row's menu item for that key, only when its menu
     offers it (Shift + R opens the menu on the row) */
  function runIssueShortcut(letter: string) {
    const focused = (document.activeElement as HTMLElement | null)?.closest?.<HTMLElement>('[data-test=issues-row], [data-test=issues-card]')
    const key = focused?.getAttribute('data-key') || o.cursorKey.value
    const issue = o.flat.value.find((i) => i.key === key)
    if (!issue) return
    o.cursorKey.value = issue.key
    const tg = issueTarget(issue)
    const row = document.querySelector<HTMLElement>(`[data-test=issues-row][data-key="${CSS.escape(issue.key)}"]`)
    const r = row?.getBoundingClientRect()
    const pt = { x: r ? r.left + 40 : 80, y: r ? r.bottom : 120 }
    if (letter === 'R') { ctxFromButton.value = false; openCtxMenu(tg, pt.x, pt.y); return }
    const id = issueShortcutItem(letter, menuItemsFor(tg, false).map((it) => it.id))
    if (id) runIssueItem(id, tg, pt)
  }
  const details = useDetailButtons(o)
  watch(editRequest, (req) => { if (req) void editTarget(req.target) })
  return { ctxTarget, ctxPoint, ctxItems, keysOn, openCtxMenu, closeCtxMenu, openEpicMenu, onCtxClose, onCtxChoose, runIssueShortcut, ...details }
}

/* t1 b6c742f0 (HUM-10 643c30a8: "add them to every card which has right click
   menu"): the issue / epic menu - rows and the epics sidebar - ends with the
   AI actions group, the card's title and description as the subject
   (utils/msg-ai-actions.mjs aiSubject 'issue'; no "Turn into an issue"). A
   post lands in the issue's discussion. */
function useIssueAiGroup(o: IssueCtxMenuOpts, ctxTarget: Ref<IssueMenuTarget | null>) {
  function heldIssue(key: string): Issue | null {
    return o.issues.value.find((i) => i.key === key) || o.subtasks.value.find((i) => i.key === key) || (o.detail.value?.key === key ? o.detail.value : null)
  }
  const group = useAiMenuGroup(() => {
    const tg = ctxTarget.value
    return tg ? aiSubject('issue', heldIssue(tg.key) || { key: tg.key, kind: tg.kind, title: tg.title }) : null
  })
  const aiLocalePath = useLocalePath()
  async function run(id: string, tg: IssueMenuTarget) {
    o.saveError.value = ''
    try {
      /* P5-06: a held sheet row has no description; the subject needs it */
      const open = o.detail.value?.key === tg.key ? o.detail.value : null
      const issue = open || normalizeIssue((await withSessionRetry(o.api, () => o.api.getIssue(tg.key))).issue)
      if (!issue.task_id) throw new Error('no discussion topic')
      const { runAiAction } = await import('~/utils/msg-ai-run')
      const send = (text: string) => o.sendToDiscussion(issue, text)
      const key = await runAiAction(id, aiSubject('issue', issue), { api: o.api, router: o.router, localePath: aiLocalePath, send })
      if (key) o.saveError.value = key
      else if (o.detail.value?.key === issue.key) await o.loadComments(issue)
    } catch {
      o.saveError.value = 'feed.msg_menu.ai.failed'
    }
  }
  return { items: group.items, keep: group.keep, more: group.more, run }
}

function useRunIssueItem(o: IssueCtxMenuOpts, closeCtxMenu: () => void, editTarget: (tg: IssueMenuTarget) => Promise<void>) {
  return function runIssueItem(id: string, tg: IssueMenuTarget, pt: { x: number, y: number }) {
    if (id === 'edit') { void editTarget(tg); return }
    if (id === 'parent') { closeCtxMenu(); void o.openIssueKey(tg.parent || ''); return }
    if (id === 'copy') { void o.copyText(issueLinkFor(tg), tg.key); return }
    if (id === 'open') {
      if (tg.top) { void o.router.push({ query: { ...o.route.query, epic: tg.key } }); return }
      const issue = o.issues.value.find((i) => i.key === tg.key)
      if (issue) o.choose(issue)
      return
    }
    if (id === 'status' || id === 'assign' || id === 'move') {
      const issue = o.issues.value.find((i) => i.key === tg.key)
      if (!issue) return
      /* Move: an issue picks its epic, a subtask its parent (the level cell's pickers) */
      const kind = id === 'move' ? (issue.level === 3 ? 'move-parent' : 'move-epic') : id
      closeCtxMenu()
      o.openMenu(kind, issue)
      o.menuPos.value = { top: pt.y, left: Math.max(8, Math.min(pt.x, window.innerWidth - 240)) }
      return
    }
    if (id === 'archive' || id === 'delete') o.askAction(id, tg)
  }
}

/* CLE-77854 (owner, topic 643330e5): the open issue's header buttons - the
   actions its ☰ menu held (CLE-77806), aimed at the open issue. Copy link
   copies and confirms; Archive keeps the shared confirm; Delete is the
   single-issue confirm, which refuses while it still has live subtasks. */
function useDetailButtons(o: IssueCtxMenuOpts) {
  function detailCopy() {
    if (o.detail.value) void o.copyText(issueLinkFor(issueTarget(o.detail.value)), o.detail.value.key)
  }
  function detailArchive() {
    if (o.detail.value) o.askAction('archive', issueTarget(o.detail.value))
  }
  function detailDelete() {
    if (o.detail.value) o.askDelete(o.detail.value)
  }
  return { detailCopy, detailArchive, detailDelete }
}

