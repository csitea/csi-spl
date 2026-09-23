/**
 * Draggable 3-pane widths. The left divider's stop is 35% of the screen,
 * counted from the left edge across the full horizontal width. The topic
 * pane yields before that stop moves. Persist the dragged widths.
 */

import { storageGetJson, storageSetJson } from './prefs.mjs'

export const SIDEBAR_DEFAULT = 260
export const TOPIC_DEFAULT = 380
export const SIDEBAR_MIN = 180
/** The left pane's divider stops at this fraction of the viewport. */
export const SIDEBAR_MAX_RATIO = 0.35
export const TOPIC_MIN = 280
export const TOPIC_MAX = 560
export const MAIN_MIN = 360
export const DIVIDER_W = 6
export const STEP = 16
export const PANE_WIDTHS_KEY = 'spool.pane-widths'
/** Match main.css: sidebar collapses to the 72px rail at this width. */
export const SIDEBAR_NARROW_MAX = 800
/** Match main.css: topic pane overlays below this width. */
export const TOPIC_NARROW_MAX = 1100

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

/**
 * Where the left divider stops, in pixels from the left edge of the screen.
 * 35% of the viewport's horizontal width. The topic pane is not part of
 * this measurement.
 */
export function sidebarMaxPx(viewportW) {
  const px = Math.round(num(viewportW, 1280) * SIDEBAR_MAX_RATIO)
  return Math.max(SIDEBAR_MIN, px)
}

export function topicShown(viewportW, topicOpen) {
  return Boolean(topicOpen) && num(viewportW, 1280) > TOPIC_NARROW_MAX
}

function dividersPx(ctx) {
  const viewportW = num(ctx && ctx.viewportW, 1280)
  const topicOpen = Boolean(ctx && ctx.topicOpen)
  let n = 0
  if (sidebarShown(viewportW)) n += 1
  if (topicShown(viewportW, topicOpen)) n += 1
  return n * DIVIDER_W
}

export function clampSidebar(width, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  /* The stop is a mark on the screen, left to right. A wide topic does not
     pull it back. */
  const max = sidebarMaxPx(viewportW)
  return clamp(Math.round(num(width, SIDEBAR_DEFAULT)), SIDEBAR_MIN, max)
}

export function clampTopic(width, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  const topicOpen = Boolean(ctx.topicOpen)
  if (!topicShown(viewportW, topicOpen)) {
    return clamp(Math.round(num(width, TOPIC_DEFAULT)), TOPIC_MIN, TOPIC_MAX)
  }
  const sidebarW = sidebarShown(viewportW)
    ? clamp(num(ctx.sidebarW, SIDEBAR_DEFAULT), SIDEBAR_MIN, sidebarMaxPx(viewportW))
    : 0
  const maxFit = viewportW - dividersPx(ctx) - sidebarW - MAIN_MIN
  const max = Math.min(TOPIC_MAX, Math.max(TOPIC_MIN, maxFit))
  return clamp(Math.round(num(width, TOPIC_DEFAULT)), TOPIC_MIN, max)
}

export function clampPair(sidebar, topic, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  const topicOpen = Boolean(ctx.topicOpen)
  const sidebarCap = sidebarMaxPx(viewportW)
  let s = clamp(Math.round(num(sidebar, SIDEBAR_DEFAULT)), SIDEBAR_MIN, sidebarCap)
  let t = clamp(Math.round(num(topic, TOPIC_DEFAULT)), TOPIC_MIN, TOPIC_MAX)
  s = clampSidebar(s, { viewportW, topicOpen })
  /* The left edge is already fixed. If both panes are wide, the topic
     gives up width so the divider stays on its 35% mark. */
  if (topicShown(viewportW, topicOpen)) {
    const roomForTopic = viewportW - dividersPx({ viewportW, topicOpen }) - s - MAIN_MIN
    const topicCap = Math.min(TOPIC_MAX, Math.max(TOPIC_MIN, roomForTopic))
    t = clamp(t, TOPIC_MIN, topicCap)
  }
  return { sidebar: s, topic: t }
}

export function sidebarRange(ctx = {}) {
  const cap = sidebarMaxPx(num(ctx.viewportW, 1280))
  const min = clampSidebar(SIDEBAR_MIN, ctx)
  const max = clampSidebar(cap, ctx)
  return { min: Math.min(min, max), max: Math.max(min, max) }
}

export function topicRange(ctx = {}) {
  const min = clampTopic(TOPIC_MIN, ctx)
  const max = clampTopic(TOPIC_MAX, ctx)
  return { min: Math.min(min, max), max: Math.max(min, max) }
}

/**
 * WAI-ARIA APG window splitter: arrows move the separator.
 * Sidebar grows to the right; topic (right pane) grows to the left.
 */
export function applySeparatorKey(pane, key, current, min, max) {
  const dir = pane === 'topic' ? -1 : 1
  const n = num(current, pane === 'topic' ? TOPIC_DEFAULT : SIDEBAR_DEFAULT)
  if (key === 'ArrowLeft') return clamp(Math.round(n - dir * STEP), min, max)
  if (key === 'ArrowRight') return clamp(Math.round(n + dir * STEP), min, max)
  if (key === 'Home') return dir === 1 ? min : max
  if (key === 'End') return dir === 1 ? max : min
  return clamp(Math.round(n), min, max)
}

export function pointerDelta(pane, startWidth, startX, clientX) {
  const dx = num(clientX, 0) - num(startX, 0)
  const start = num(startWidth, pane === 'topic' ? TOPIC_DEFAULT : SIDEBAR_DEFAULT)
  return pane === 'topic' ? start - dx : start + dx
}

export function loadPaneWidths(store) {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null, store)
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { sidebar: SIDEBAR_DEFAULT, topic: TOPIC_DEFAULT }
  }
  return {
    sidebar: num(raw.sidebar, SIDEBAR_DEFAULT),
    topic: num(raw.topic, TOPIC_DEFAULT),
  }
}

export function savePaneWidths(widths, store) {
  const sidebar = Math.round(num(widths && widths.sidebar, SIDEBAR_DEFAULT))
  const topic = Math.round(num(widths && widths.topic, TOPIC_DEFAULT))
  return storageSetJson(PANE_WIDTHS_KEY, { sidebar, topic }, store)
}

export function resetPane(pane) {
  return pane === 'topic' ? TOPIC_DEFAULT : SIDEBAR_DEFAULT
}
