// r19-06: LiveFeed's unread "N new" jump and the landing on open, moved out
// of LiveFeed.vue.
//
// CLE-77804: the button jumps to where the unseen start; it shows only while
// that place is off screen. SPL-2430: on open the feed lands there. The SFC
// keeps `firstNewId` / `newCount` (its rows and divider read them) and passes
// them here as one options object.
import type { ComputedRef, Ref } from 'vue'
import type { SpoolMessage } from '~/types/spool'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { landFeed, rowEl, unreadLandingId } from '~/utils/unread-landing.mjs'

/** the LiveFeed props the unread jump reads */
interface UnreadFeed {
  rows: SpoolMessage[]
  holdScroll?: boolean
  unreadBoundary?: { ts: string, id: string } | null
}

interface UnreadJumpOpts {
  props: UnreadFeed
  root: Ref<HTMLElement | null>
  phone: Ref<boolean>
  newestLast: Ref<boolean>
  /** the rows in DOM (= reading) order */
  shown: ComputedRef<SpoolMessage[]>
  viewerId: ComputedRef<string>
  firstNewId: ComputedRef<string>
  newCount: ComputedRef<number>
  pill: Ref<number>
  /** stops the newest-last bottom glue (useScrollAnchor) */
  hold: () => void
  /** SPL-2146: draws a windowed-out row, then finds it */
  drawRow: <R>(key: string, find: () => R) => Promise<R>
  /** the phone thread arrow's measure (useLiveFeedThreadEnds) */
  measureJump: () => void
}

/* The jump button shows only while the divider is off screen (scrolled away).
   Visibility is measured on scroll with getBoundingClientRect — deliberately
   not an observer (load-more-30 keeps the feed free of auto-load-on-scroll). */
function unreadMeasure(o: UnreadJumpOpts) {
  const { props, root, newestLast, shown, viewerId } = o
  const dividerVisible = ref(false)
  function dividerEl(): HTMLElement | null {
    return root.value?.querySelector<HTMLElement>('[data-testid="new-divider"]') || null
  }
  /* SPL-2430: where the unseen start (unreadLandingId); on screen hides the pill */
  function landingEl(): HTMLElement | null {
    return newestLast.value ? dividerEl() : rowEl(root.value, unreadLandingId(shown.value, props.unreadBoundary, viewerId.value, false))
  }
  function measureDivider() {
    const el = landingEl()
    if (!el) {
      dividerVisible.value = false
      return
    }
    const scroller = el.closest<HTMLElement>('.feed-body')
    if (!scroller) {
      dividerVisible.value = true
      return
    }
    const er = el.getBoundingClientRect()
    const sr = scroller.getBoundingClientRect()
    dividerVisible.value = er.bottom > sr.top && er.top < sr.bottom
  }
  return { dividerVisible, dividerEl, landingEl, measureDivider }
}

/* On open (a new boundary, once the rows are in) land where the unseen start
   (SPL-2430, owner t1 89010926): newest-last the divider, newest-first the
   newest unseen, held while the cards settle (landFeed). Then measure whether
   the divider is on screen for the jump button. */
function unreadLanding(o: UnreadJumpOpts, landingEl: () => HTMLElement | null, measureDivider: () => void) {
  const { props, root, phone, newestLast, firstNewId, hold, measureJump } = o
  /* added and removed on document with capture: the same function both times */
  function onFeedScroll() {
    if (firstNewId.value) measureDivider()
    if (phone.value && props.holdScroll) measureJump()
  }
  let dividerDone = ''
  let stopLanding: (() => void) | null = null
  watch(() => props.unreadBoundary, () => { dividerDone = '' })
  watch(() => [firstNewId.value, props.rows.length] as const, async ([id]) => {
    await nextTick()
    if (id && id !== dividerDone) {
      dividerDone = id
      landUnread()
    }
    measureDivider()
  }, { immediate: true })
  function landUnread() {
    stopLanding?.()
    /* an async pane renders before it is in the page (null): onMounted lands it */
    stopLanding = landFeed(root.value, landingEl, hold, () => newestLast.value)
  }

  onMounted(() => {
    if (typeof document !== 'undefined') document.addEventListener('scroll', onFeedScroll, { capture: true, passive: true })
    if (firstNewId.value && !stopLanding) {
      dividerDone = firstNewId.value
      landUnread()
    }
  })
  onUnmounted(() => {
    stopLanding?.()
    if (typeof document !== 'undefined') document.removeEventListener('scroll', onFeedScroll, { capture: true })
  })
}

export function useLiveFeedUnreadJump(o: UnreadJumpOpts) {
  const { phone, newestLast, newCount, pill, hold, drawRow } = o
  const { dividerVisible, dividerEl, landingEl, measureDivider } = unreadMeasure(o)
  /* CLE-77905 (owner, t1 05e24244, 2026-10-01: "Just remove it for now"): NOT on
     a phone. It was meant to take the reader to the first unread message
     (CLE-77804), but in newest-first the unread sit at the top, so it showed
     "1 new" over the top card while the reader was already there - its jump to
     top 0 moved nothing and the pill kept catching taps. Bring it back on
     phones only once it has a target the reader is not already looking at. */
  const showUnreadJump = computed(() => !phone.value && newCount.value > 0 && !pill.value && !dividerVisible.value)

  async function jumpToUnread() {
    const el = dividerEl() || await drawRow('__new-divider__', dividerEl) /* SPL-2146: maybe not drawn */
    const scroller = el?.closest<HTMLElement>('.feed-body')
    if (!scroller) return
    hold()
    /* newest-last: the unread block starts at the divider, read down from there.
       newest-first: the unread sit at the top of the feed — go up to them. */
    if (newestLast.value && el) scrollRowToTop(scroller, el)
    else scroller.scrollTo({ top: 0, behavior: 'auto' })
  }

  unreadLanding(o, landingEl, measureDivider)
  return { showUnreadJump, jumpToUnread }
}
