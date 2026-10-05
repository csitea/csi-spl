/**
 * Draggable 3-pane widths. The left divider's stop is 35% of the screen,
 * counted from the left edge across the full horizontal width. The topic
 * pane yields before that stop moves. Persist the dragged widths.
 */

import { storageGetJson, storageSetJson } from './prefs.mjs'

export const SIDEBAR_DEFAULT = 260
/** The topic pane's width before any viewport is known (prerender, tests). */
export const TOPIC_DEFAULT = 380
/** Spec 078 FR-006: an undragged topic pane takes this share of the space
    right of the left pane. */
export const TOPIC_DEFAULT_RATIO = 0.4
export const SIDEBAR_MIN = 180
/** The left pane's divider stops at this fraction of the viewport. */
export const SIDEBAR_MAX_RATIO = 0.35
export const TOPIC_MIN = 280
/** The right pane may take up to this fraction of the viewport. */
export const TOPIC_MAX_RATIO = 0.65
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

/**
 * The widest the topic pane may get: 65% of the viewport. MAIN_MIN still
 * wins when the screen is too narrow for that.
 */
export function topicMaxPx(viewportW) {
  const px = Math.round(num(viewportW, 1280) * TOPIC_MAX_RATIO)
  return Math.max(TOPIC_MIN, px)
}

/**
 * Spec 078 FR-006: the topic pane's default width for a given space right of
 * the left pane (mainWidth): 40% of it, at least TOPIC_MIN, at most
 * TOPIC_MAX_RATIO of it, and leaving MAIN_MIN plus a divider for the middle.
 * A dragged width still wins; this is only the width nobody has set.
 */
export function topicDefaultFor(mainWidth) {
  const main = num(mainWidth, 0)
  if (main <= 0) return TOPIC_DEFAULT
  const max = Math.min(Math.round(main * TOPIC_MAX_RATIO), main - DIVIDER_W - MAIN_MIN)
  return clamp(Math.round(main * TOPIC_DEFAULT_RATIO), TOPIC_MIN, Math.max(TOPIC_MIN, max))
}

/** The space right of the left pane (and its divider) at this viewport. */
export function mainWidthFor(viewportW, sidebarW) {
  const w = num(viewportW, 1280)
  if (!sidebarShown(w)) return w
  return w - clamp(num(sidebarW, SIDEBAR_DEFAULT), SIDEBAR_MIN, sidebarMaxPx(w)) - DIVIDER_W
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
    return clamp(Math.round(num(width, TOPIC_DEFAULT)), TOPIC_MIN, topicMaxPx(viewportW))
  }
  const sidebarW = sidebarShown(viewportW)
    ? clamp(num(ctx.sidebarW, SIDEBAR_DEFAULT), SIDEBAR_MIN, sidebarMaxPx(viewportW))
    : 0
  const maxFit = viewportW - dividersPx(ctx) - sidebarW - MAIN_MIN
  const max = Math.min(topicMaxPx(viewportW), Math.max(TOPIC_MIN, maxFit))
  return clamp(Math.round(num(width, TOPIC_DEFAULT)), TOPIC_MIN, max)
}

export function clampPair(sidebar, topic, ctx = {}) {
  const viewportW = num(ctx.viewportW, 1280)
  const topicOpen = Boolean(ctx.topicOpen)
  const sidebarCap = sidebarMaxPx(viewportW)
  let s = clamp(Math.round(num(sidebar, SIDEBAR_DEFAULT)), SIDEBAR_MIN, sidebarCap)
  let t = clamp(Math.round(num(topic, TOPIC_DEFAULT)), TOPIC_MIN, topicMaxPx(viewportW))
  s = clampSidebar(s, { viewportW, topicOpen })
  /* The left edge is already fixed. If both panes are wide, the topic
     gives up width so the divider stays on its 35% mark. */
  if (topicShown(viewportW, topicOpen)) {
    const roomForTopic = viewportW - dividersPx({ viewportW, topicOpen }) - s - MAIN_MIN
    const topicCap = Math.min(topicMaxPx(viewportW), Math.max(TOPIC_MIN, roomForTopic))
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
  const max = clampTopic(topicMaxPx(num(ctx.viewportW, 1280)), ctx)
  return { min: Math.min(min, max), max: Math.max(min, max) }
}

/**
 * WAI-ARIA APG window splitter: arrows move the separator.
 * Sidebar grows to the right. A right-hand pane (topic, issue detail)
 * grows to the left.
 */
function separatorGrowsLeft(pane) {
  return pane === 'topic' || pane === 'issue'
}

export function applySeparatorKey(pane, key, current, min, max) {
  const dir = separatorGrowsLeft(pane) ? -1 : 1
  const n = num(current, separatorGrowsLeft(pane) ? TOPIC_DEFAULT : SIDEBAR_DEFAULT)
  if (key === 'ArrowLeft') return clamp(Math.round(n - dir * STEP), min, max)
  if (key === 'ArrowRight') return clamp(Math.round(n + dir * STEP), min, max)
  if (key === 'Home') return dir === 1 ? min : max
  if (key === 'End') return dir === 1 ? max : min
  return clamp(Math.round(n), min, max)
}

export function pointerDelta(pane, startWidth, startX, clientX) {
  const dx = num(clientX, 0) - num(startX, 0)
  const start = num(startWidth, separatorGrowsLeft(pane) ? TOPIC_DEFAULT : SIDEBAR_DEFAULT)
  return separatorGrowsLeft(pane) ? start - dx : start + dx
}

/**
 * Spec 078 FR-007: widths are kept per view. channel = channels and DMs; every
 * page that is not one of these views uses default.
 */
export const PANE_VIEWS = ['default', 'channel', 'issues', 'help', 'docs']

/** The view a route (or a path) keeps its widths under. */
export function viewOf(route) {
  const path = String((typeof route === 'string' ? route : route && route.path) || '').split(/[?#]/)[0]
  if (path.startsWith('/channel/') || path.startsWith('/dm/')) return 'channel'
  for (const view of ['issues', 'help', 'docs']) {
    if (path === `/${view}` || path.startsWith(`/${view}/`)) return view
  }
  return 'default'
}

function isObj(v) {
  return Boolean(v) && typeof v === 'object' && !Array.isArray(v)
}

/* One view's set: only finite sidebar / topic numbers; null when it has none. */
function paneSet(v) {
  if (!isObj(v)) return null
  const out = {}
  for (const k of ['sidebar', 'topic']) {
    const n = v[k] == null ? NaN : Number(v[k])
    if (Number.isFinite(n)) out[k] = n
  }
  return Object.keys(out).length ? out : null
}

/**
 * Spec 078 FR-007: a stored value as {view: {sidebar?, topic?}}. Units are the
 * caller's (px in the browser, window fractions on the account). An old flat
 * {sidebar, topic} reads as default; junk reads as {}.
 */
export function paneViews(raw) {
  if (!isObj(raw)) return {}
  if ('sidebar' in raw || 'topic' in raw) {
    const flat = paneSet(raw)
    return flat ? { default: flat } : {}
  }
  const out = {}
  for (const view of PANE_VIEWS) {
    const set = paneSet(raw[view])
    if (set) out[view] = set
  }
  return out
}

/** The set in force for a view: its own, else default, else null. */
export function paneSetFor(views, view = 'default') {
  return (views && (views[view] || views.default)) || null
}

/* The browser copy keeps the views under `views`: the key's top-level
   `issues` is already the issue detail width (issues-view.mjs), so a
   top-level `issues` view would clobber it. A flat old value has none. */
function storedViews(raw) {
  if (!isObj(raw)) return {}
  return paneViews(isObj(raw.views) ? raw.views : raw)
}

export function loadPaneViews(store) {
  return storedViews(storageGetJson(PANE_WIDTHS_KEY, null, store))
}

export function loadPaneWidths(store, view = 'default') {
  const set = paneSetFor(loadPaneViews(store), view) || {}
  return {
    sidebar: num(set.sidebar, SIDEBAR_DEFAULT),
    topic: num(set.topic, TOPIC_DEFAULT),
  }
}

/**
 * The dragged topic width, or null when nobody has set one (spec 078 FR-006:
 * the pane then follows topicDefaultFor).
 */
export function loadStoredTopic(store, view = 'default') {
  const set = paneSetFor(loadPaneViews(store), view)
  return set && set.topic != null ? set.topic : null
}

/** Spec 078 FR-007: write ONE view's widths; the other views stay. */
export function savePaneWidths(widths, store, view = 'default') {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null, store)
  const prev = isObj(raw) ? raw : {}
  const views = storedViews(prev)
  const set = { sidebar: Math.round(num(widths && widths.sidebar, SIDEBAR_DEFAULT)) }
  /* A null topic is "never dragged": leave it out so the default applies. */
  if (!(widths && widths.topic === null)) set.topic = Math.round(num(widths && widths.topic, TOPIC_DEFAULT))
  views[PANE_VIEWS.includes(view) ? view : 'default'] = set
  // Keep keys this helper does not own (the issue detail width); drop the old flat pair.
  const next = { ...prev, views }
  delete next.sidebar
  delete next.topic
  return storageSetJson(PANE_WIDTHS_KEY, next, store)
}

/** "Reset pane sizes": every view back to the default; other keys stay. */
export function clearPaneWidths(store) {
  const raw = storageGetJson(PANE_WIDTHS_KEY, null, store)
  const next = isObj(raw) ? { ...raw } : {}
  for (const k of ['sidebar', 'topic', 'views']) delete next[k]
  return storageSetJson(PANE_WIDTHS_KEY, next, store)
}

export function resetPane(pane) {
  return pane === 'topic' ? TOPIC_DEFAULT : SIDEBAR_DEFAULT
}
