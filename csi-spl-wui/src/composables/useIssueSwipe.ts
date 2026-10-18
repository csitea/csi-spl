import type { Ref } from 'vue'
import type { Issue } from '~/utils/issues.mjs'
import { createLongPress } from '~/utils/touch-ui.mjs'
import { SWIPE_SETTLE_MS, createSwipe, swipeInBackZone } from '~/utils/swipe-archive.mjs'
import type { useMobileStack } from '~/composables/useMobileStack'
import { issueTarget } from '~/composables/useIssueActConfirm'
import type { IssueMenuTarget } from '~/composables/useIssueMenu'

/**
 * A row's right-click and long-press, and the phone card's swipes. Moved out
 * of pages/issues.vue (r13-06).
 */
export type IssueSwipeOpts = {
  stack: ReturnType<typeof useMobileStack>
  cursorKey: Ref<string>
  choose: (issue: Issue) => void
  openCtxMenu: (tg: IssueMenuTarget, x: number, y: number) => void
  askAction: (action: 'archive' | 'delete', tg: IssueMenuTarget) => void
}
type SwipeState = { key: string, dx: number, dir: 'archive' | 'hide' | 'menu', armed: boolean, settle: boolean }
type SwipeHeld = { el: HTMLElement | null, issue: Issue | null, timer: ReturnType<typeof setTimeout> | null }

const swipeRtl = () => typeof document !== 'undefined' && document.documentElement.dir === 'rtl'

export function useIssueSwipe(o: IssueSwipeOpts) {
  /* one long-press machine for every row; the row it fired on is remembered on
     pointerdown (createLongPress only reports the point) */
  let pressTarget: IssueMenuTarget | null = null
  const rowPress = createLongPress({ onPress: (x, y) => { if (pressTarget) o.openCtxMenu(pressTarget, x, y) } })
  function onRowContext(issue: Issue, ev: MouseEvent) {
    ev.preventDefault()
    ev.stopPropagation()
    o.openCtxMenu(issueTarget(issue), ev.clientX, ev.clientY)
  }
  function onRowPointerDown(issue: Issue, ev: PointerEvent) { pressTarget = issueTarget(issue); rowPress.down(ev) }
  const swipe = reactive<SwipeState>({ key: '', dx: 0, dir: 'archive', armed: false, settle: false })
  const held: SwipeHeld = { el: null, issue: null, timer: null }
  const cardSwipe = cardSwipeMachine(o, { swipe, held, rowPress })
  /* the click the finger sends when a long-press lifts must not also open the row */
  function onRowActivate(issue: Issue) {
    const swiped = cardSwipe.takeClick()
    if (rowPress.takeClick() || swiped) return
    o.choose(issue)
  }
  function onCardPointerDown(issue: Issue, ev: PointerEvent) {
    held.issue = issue
    held.el = ev.currentTarget as HTMLElement
    cardSwipe.down(ev)
    onRowPointerDown(issue, ev)
  }
  function onCardPointerMove(ev: PointerEvent) {
    cardSwipe.move(ev)
    if (!cardSwipe.swiping) rowPress.move(ev)
  }
  function onCardPointerUp() { cardSwipe.up(); rowPress.up() }
  function onCardPointerCancel() { cardSwipe.cancel(); rowPress.cancel() }
  return { swipe, rowPress, onRowContext, onRowPointerDown, onRowActivate, onCardPointerDown, onCardPointerMove, onCardPointerUp, onCardPointerCancel }
}

/* HUM-10 (owner, t1 aedca86a, f83f73b9): "the same swipes which work for the
   other listings of message cards should work". The phone's issue card takes
   MessageCard's swipe machine (utils/swipe-archive.mjs): LEFT is the menu's
   Archive (its confirm: an issue has no undo), RIGHT opens the card's menu at
   the finger. A right swipe from the Back zone stays the shell's Back. One
   machine for the list; the card it runs on is remembered on pointerdown. */
function cardSwipeMachine(o: IssueSwipeOpts, s: { swipe: SwipeState, held: SwipeHeld, rowPress: ReturnType<typeof createLongPress> }) {
  const { swipe, held } = s
  function swipeTo(dx: number, settle: boolean) {
    if (held.timer) clearTimeout(held.timer)
    held.timer = null
    swipe.settle = settle
    swipe.dx = dx
    if (settle && dx === 0) held.timer = setTimeout(() => { swipe.settle = false; swipe.key = ''; held.timer = null }, SWIPE_SETTLE_MS)
  }
  return createSwipe({
    width: () => held.el?.getBoundingClientRect().width || 0,
    rtl: swipeRtl,
    canLeft: () => Boolean(held.issue),
    canRight: (x) => !(o.stack.level.value > 1 && swipeInBackZone(x, typeof window !== 'undefined' ? window.innerWidth : 0, swipeRtl())),
    onLock: (dir) => {
      s.rowPress.cancel()
      swipe.key = held.issue?.key || ''
      swipe.dir = dir
    },
    onMove: (dx, armed, dir) => {
      if (armed && !swipe.armed && typeof navigator !== 'undefined' && typeof navigator.vibrate === 'function') navigator.vibrate(10)
      swipe.armed = armed
      swipeTo(dir === 'menu' ? dx : -dx, false)
    },
    onCommit: (dir, x, y) => {
      const issue = held.issue
      swipe.armed = false
      swipeTo(0, true)
      if (!issue) return
      o.stack.swipe.claim()
      o.cursorKey.value = issue.key
      if (dir === 'menu') o.openCtxMenu(issueTarget(issue), x, y)
      else o.askAction('archive', issueTarget(issue))
    },
    onCancel: () => {
      swipe.armed = false
      swipeTo(0, true)
    },
  })
}
