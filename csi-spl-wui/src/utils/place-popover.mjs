/**
 * Put a popover inside the viewport.
 * The document must not grow to fit a menu, and a menu must not open past
 * the bottom edge: when there is no room below, it opens upward.
 *
 * `anchor.x` / `anchor.y` is the preferred top-left (viewport pixels).
 * `anchor.flipFrom` is the y the panel's bottom sits on when it opens
 * upward. It defaults to `anchor.y`, so the panel's bottom meets the
 * preferred top (a right-click, or a trigger's bottom edge).
 * `maxWidth` / `maxHeight` are the limits the panel has to apply.
 */
export const POPOVER_MARGIN = 8

function px(v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0
}

export function placePopover(anchor, size, viewport, margin = POPOVER_MARGIN) {
  const m = Math.max(0, px(margin))
  const vw = Math.max(0, px(viewport && viewport.width))
  const vh = Math.max(0, px(viewport && viewport.height))
  const maxWidth = Math.max(0, vw - 2 * m)
  const maxHeight = Math.max(0, vh - 2 * m)
  const w = Math.min(Math.max(0, px(size && size.width)), maxWidth)
  const h = Math.min(Math.max(0, px(size && size.height)), maxHeight)
  let left = px(anchor && anchor.x)
  if (left + w > vw - m) left = vw - m - w
  if (left < m) left = m
  const prefer = px(anchor && anchor.y)
  let top = prefer
  let flipped = false
  if (h > 0 && top + h > vh - m) {
    const flipFrom = anchor && typeof anchor.flipFrom === 'number' && Number.isFinite(anchor.flipFrom)
      ? anchor.flipFrom
      : prefer
    const up = flipFrom - h
    if (up >= m) {
      top = up
      flipped = true
    } else {
      top = m
    }
  }
  if (top < m) top = m
  if (top + h > vh - m) top = Math.max(m, vh - m - h)
  return { left, top, flipped, maxWidth, maxHeight }
}

export function readViewport() {
  if (typeof window === 'undefined') return { width: 0, height: 0 }
  return { width: window.innerWidth, height: window.innerHeight }
}

/**
 * Anchor is the trigger's viewport rect. `align: 'end'` keeps the panel's
 * inline end on the trigger's end. `gap` is the space between them.
 * `lockWidth` pins a percentage-width list (a locale menu) to the width it
 * had before it became position:fixed.
 */
export function applyPopover(el, anchor, viewport, margin = POPOVER_MARGIN) {
  if (!el || el.offsetWidth < 1 || el.offsetHeight < 1) return null
  const width = el.offsetWidth
  const height = el.scrollHeight || el.offsetHeight
  const gap = px(anchor && anchor.gap)
  const alignEnd = anchor && anchor.align === 'end'
  const x = alignEnd ? px(anchor.right) - width : px(anchor && anchor.left)
  const box = placePopover(
    { x, y: px(anchor && anchor.bottom) + gap, flipFrom: px(anchor && anchor.top) - gap },
    { width, height },
    viewport || readViewport(),
    margin,
  )
  el.style.position = 'fixed'
  /* Clear a stylesheet inset before left/top. Setting inset-inline-start
     after left resets left, and the menu then sticks to the viewport edge. */
  el.style.insetInlineStart = 'auto'
  el.style.insetInlineEnd = 'auto'
  el.style.right = 'auto'
  el.style.bottom = 'auto'
  el.style.left = box.left + 'px'
  el.style.top = box.top + 'px'
  el.style.margin = '0'
  el.style.maxWidth = box.maxWidth + 'px'
  el.style.maxHeight = box.maxHeight + 'px'
  el.style.overflowY = 'auto'
  el.style.overscrollBehavior = 'contain'
  if (anchor && anchor.lockWidth) el.style.width = Math.min(width, box.maxWidth) + 'px'
  el.style.visibility = 'visible'
  return box
}

/** A point anchor (a right-click, or a trigger corner already including its gap). */
export function applyPopoverAtPoint(el, x, y, viewport) {
  return applyPopover(el, {
    left: x,
    right: x,
    top: y,
    bottom: y,
    align: 'start',
    gap: 0,
  }, viewport || readViewport())
}

export function focusWithoutScroll(el) {
  if (!el || typeof el.focus !== 'function') return
  el.focus({ preventScroll: true })
}

/**
 * Headless UI shows and hides its list itself. Whenever that list is on
 * screen, pin it inside the viewport. Returns a stop function, which
 * removes the observer and all three listeners; safe to call twice.
 */
export function observePopover(host, opts) {
  if (!host || typeof MutationObserver === 'undefined') return () => {}
  const run = () => {
    const panel = host.querySelector(opts.panel)
    const anchor = host.querySelector(opts.anchor)
    if (!panel || !anchor) return
    const r = anchor.getBoundingClientRect()
    applyPopover(panel, {
      left: r.left,
      right: r.right,
      top: r.top,
      bottom: r.bottom,
      align: opts.align || 'start',
      gap: opts.gap ?? 4,
      lockWidth: true,
    }, readViewport())
  }
  const later = () => {
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(run)
    else run()
  }
  const obs = new MutationObserver(later)
  obs.observe(host, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['data-headlessui-state', 'hidden', 'class', 'aria-expanded'],
  })
  const ctl = new AbortController()
  const { signal } = ctl
  host.addEventListener('click', later, { signal })
  host.addEventListener('focusin', later, { signal })
  host.addEventListener('keydown', later, { signal })
  return () => {
    obs.disconnect()
    ctl.abort()
  }
}
