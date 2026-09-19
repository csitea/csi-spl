/** Draggable 3-pane widths: clamp so the main feed never collapses, persist. */

import { storageGetJson, storageSetJson } from './prefs.mjs'

export const SIDEBAR_DEFAULT = 260
export const THREAD_DEFAULT = 380
export const SIDEBAR_MIN = 180
export const SIDEBAR_MAX = 420
export const THREAD_MIN = 280
export const THREAD_MAX = 560
export const MAIN_MIN = 360
export const DIVIDER_W = 6
export const STEP = 16
export const PANE_WIDTHS_KEY = 'spool.pane-widths'
/** Match main.css: sidebar collapses to the 72px rail at this width. */
export const SIDEBAR_NARROW_MAX = 800
/** Match main.css: thread pane overlays below this width. */
export const THREAD_NARROW_MAX = 1100

export function num(v, fallback) {
  const n = Number(v)
  return Number.isFinite(n) ? n : fallback
}

export function clamp(n, min, max) {
  const lo = Math.min(min, max)
  const hi = Math.max(min, max)
  return Math.min(hi, Math.max(lo, n))
}

export function sidebarShown(viewportW) {
  return num(viewportW, 1280) > SIDEBAR_NARROW_MAX
}

export function threadShown(viewportW, threadOpen) {
  return Boolean(threadOpen) && num(viewportW, 1280) > THREAD_NARROW_MAX
}

function dividersPx(ctx) {
  const viewportW = num(ctx && ctx.viewportW, 1280)
  const threadOpen = Boolean(ctx && ctx.threadOpen)
  let n = 0
  if (sidebarShown(viewportW)) n += 1
  if (threadShown(viewportW, threadOpen)) n += 1
  return n * DIVIDER_W
}

export function clampSidebar(width, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  const threadOpen = Boolean(ctx.threadOpen)
  const threadW = threadShown(viewportW, threadOpen)
    ? clamp(num(ctx.threadW, THREAD_DEFAULT), THREAD_MIN, THREAD_MAX)
    : 0
  const maxFit = viewportW - dividersPx(ctx) - threadW - MAIN_MIN
  const max = Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, maxFit))
  return clamp(Math.round(num(width, SIDEBAR_DEFAULT)), SIDEBAR_MIN, max)
}

export function clampThread(width, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  const threadOpen = Boolean(ctx.threadOpen)
  if (!threadShown(viewportW, threadOpen)) {
    return clamp(Math.round(num(width, THREAD_DEFAULT)), THREAD_MIN, THREAD_MAX)
  }
  const sidebarW = sidebarShown(viewportW)
    ? clamp(num(ctx.sidebarW, SIDEBAR_DEFAULT), SIDEBAR_MIN, SIDEBAR_MAX)
    : 0
  const maxFit = viewportW - dividersPx(ctx) - sidebarW - MAIN_MIN
  const max = Math.min(THREAD_MAX, Math.max(THREAD_MIN, maxFit))
  return clamp(Math.round(num(width, THREAD_DEFAULT)), THREAD_MIN, max)
}

export function clampPair(sidebar, thread, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  const threadOpen = Boolean(ctx.threadOpen)
  let s = clamp(Math.round(num(sidebar, SIDEBAR_DEFAULT)), SIDEBAR_MIN, SIDEBAR_MAX)
  let t = clamp(Math.round(num(thread, THREAD_DEFAULT)), THREAD_MIN, THREAD_MAX)
  s = clampSidebar(s, { viewportW, threadW: t, threadOpen })
  t = clampThread(t, { viewportW, sidebarW: s, threadOpen })
  if (threadShown(viewportW, threadOpen)) {
    const budget = viewportW - dividersPx({ viewportW, threadOpen }) - MAIN_MIN
    if (s + t > budget) {
      t = clamp(budget - s, THREAD_MIN, THREAD_MAX)
      s = clamp(budget - t, SIDEBAR_MIN, SIDEBAR_MAX)
    }
  }
  return { sidebar: s, thread: t }
}

export function sidebarRange(ctx = {}) {
  const min = clampSidebar(SIDEBAR_MIN, ctx)
  const max = clampSidebar(SIDEBAR_MAX, ctx)
  return { min: Math.min(min, max), max: Math.max(min, max) }
}

export function threadRange(ctx = {}) {
  const min = clampThread(THREAD_MIN, ctx)
  const max = clampThread(THREAD_MAX, ctx)
  return { min: Math.min(min, max), max: Math.max(min, max) }
}

/**
 * WAI-ARIA APG window splitter: arrows move the separator.
 * Sidebar grows to the right; thread (right pane) grows to the left.
 */
export function applySeparatorKey(pane, key, current, min, max) {
  const dir = pane === 'thread' ? -1 : 1
  const n = num(current, pane === 'thread' ? THREAD_DEFAULT : SIDEBAR_DEFAULT)
  if (key === 'ArrowLeft') return clamp(Math.round(n - dir * STEP), min, max)
  if (key === 'ArrowRight') return clamp(Math.round(n + dir * STEP), min, max)
  if (key === 'Home') return dir === 1 ? min : max
  if (key === 'End') return dir === 1 ? max : min
  return clamp(Math.round(n), min, max)
}

export function pointerDelta(pane, startWidth, startX, clientX) {
  const dx = num(clientX, 0) - num(startX, 0)
  const start = num(startWidth, pane === 'thread' ? THREAD_DEFAULT : SIDEBAR_DEFAULT)
  return pane === 'thread' ? start - dx : start + dx
}

export function loadPaneWidths(store) {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null, store)
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { sidebar: SIDEBAR_DEFAULT, thread: THREAD_DEFAULT }
  }
  return {
    sidebar: num(raw.sidebar, SIDEBAR_DEFAULT),
    thread: num(raw.thread, THREAD_DEFAULT),
  }
}

export function savePaneWidths(widths, store) {
  const sidebar = Math.round(num(widths && widths.sidebar, SIDEBAR_DEFAULT))
  const thread = Math.round(num(widths && widths.thread, THREAD_DEFAULT))
  return storageSetJson(PANE_WIDTHS_KEY, { sidebar, thread }, store)
}

export function resetPane(pane) {
  return pane === 'thread' ? THREAD_DEFAULT : SIDEBAR_DEFAULT
}
