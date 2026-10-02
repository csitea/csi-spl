/**
 * Gmail / GitHub `/` shortcut: focus the top Omnibox without inserting `/`.
 *
 * Pure helpers so the key policy is unit-tested without Vue. The TopBar
 * listener calls slashFocusAction and then focuses / restores.
 *
 * `/` is ignored while typing (input/textarea/select/contenteditable/
 * role=textbox|searchbox|combobox), with Ctrl/Cmd/Alt, inside an open
 * aria-modal dialog, on a phone (≤ MOBILE_MAX, the Omnibox is folded),
 * or when the Omnibox textarea already has the focus (so `/search` and
 * a literal slash still type). Escape after a `/` jump blurs and
 * returns focus to the previous element; pickers and the ``` composer
 * keep their own Escape.
 */
import { MOBILE_STACK_MAX_PX } from './mobile-stack.mjs'
/* SPL-990: the Omnibox folds at 820 px now, with the mobile layout */
export const MOBILE_MAX = MOBILE_STACK_MAX_PX

const NON_TEXT_INPUT = new Set([
  'button', 'checkbox', 'radio', 'file', 'reset', 'submit', 'image', 'hidden', 'range', 'color',
])

function asElement(node) {
  if (!node) return null
  if (node.nodeType === 3) return node.parentElement || null
  return node
}

export function isTypingTarget(el) {
  const node = asElement(el)
  if (!node || !node.tagName) return false
  const tag = String(node.tagName).toUpperCase()
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true
  if (tag === 'INPUT') {
    const type = String(node.type || 'text').toLowerCase()
    return !NON_TEXT_INPUT.has(type)
  }
  if (node.isContentEditable) return true
  const role = typeof node.getAttribute === 'function' ? (node.getAttribute('role') || '') : (node.role || '')
  if (role === 'textbox' || role === 'searchbox' || role === 'combobox') return true
  if (typeof node.closest === 'function') {
    const host = node.closest('[contenteditable="true"], [contenteditable=""]')
    if (host) return true
  }
  return false
}

export function isOpenModal(root) {
  if (!root || typeof root.querySelector !== 'function') return false
  return Boolean(root.querySelector('[aria-modal="true"], [role="dialog"][aria-modal="true"]'))
}

export function isMobileViewport(width, max = MOBILE_MAX) {
  if (typeof width !== 'number' || !Number.isFinite(width)) return false
  return width <= max
}

export function eventInOmnibox(target, omniboxRoot) {
  if (!omniboxRoot || !target) return false
  const ta = typeof omniboxRoot.querySelector === 'function' ? omniboxRoot.querySelector('textarea') : null
  if (!ta) return false
  const node = asElement(target)
  if (!node) return false
  if (node === ta) return true
  return typeof ta.contains === 'function' && ta.contains(node)
}

/**
 * @returns {'focus' | 'restore' | 'ignore'}
 */
export function slashFocusAction(ev, ctx = {}) {
  if (!ev || ev.defaultPrevented || ev.isComposing || ev.repeat) return 'ignore'
  const key = ev.key
  if (key === 'Escape') {
    if (ctx.inOmnibox && ctx.hasRestore && !ctx.pickerOpen && !ctx.inCode) return 'restore'
    return 'ignore'
  }
  if (key !== '/') return 'ignore'
  if (ev.ctrlKey || ev.metaKey || ev.altKey) return 'ignore'
  if (ctx.isMobile) return 'ignore'
  if (ctx.inModal) return 'ignore'
  if (ctx.inOmnibox) return 'ignore'
  if (ctx.inTypingTarget) return 'ignore'
  return 'focus'
}

export function slashFocusContext(ev, opts = {}) {
  const root = opts.omniboxRoot || null
  const target = ev && ev.target
  const ta = root && typeof root.querySelector === 'function' ? root.querySelector('textarea') : null
  const inCode = Boolean(ta && ta.classList && ta.classList.contains('in-code'))
  const pickerOpen = Boolean(root && typeof root.querySelector === 'function' && root.querySelector('[role="listbox"]'))
  return {
    inOmnibox: eventInOmnibox(target, root),
    inTypingTarget: isTypingTarget(target),
    inModal: isOpenModal(opts.document),
    isMobile: isMobileViewport(opts.viewportWidth),
    pickerOpen,
    inCode,
    hasRestore: Boolean(opts.hasRestore),
  }
}
