/**
 * SPL-6675 (owner HUM-10, t1 bcfd15e1 msg 2f0259cc): the search panel's width.
 * The sidebar's list is best at 25-30 % of the screen at most; the results
 * need more, so the panel opens at SEARCH_W_FRAC of the window and may be
 * dragged between SEARCH_W_MIN px and SEARCH_W_MAX_FRAC of it (spec 197 v1.2:
 * 48 %, 380 px..65 %). Kept in this browser under SEARCH_W_KEY, apart from
 * the sidebar's --sidebar-w (null = the default, which follows the window).
 */
export const SEARCH_W_KEY = 'spool.us-pane-w'
const SEARCH_W_FRAC = 0.48
const SEARCH_W_MIN = 380
const SEARCH_W_MAX_FRAC = 0.65

export function searchPanelBounds(viewportW: number): { min: number, max: number } {
  const vw = Math.max(0, Number(viewportW) || 0)
  const max = Math.max(SEARCH_W_MIN, Math.round(vw * SEARCH_W_MAX_FRAC))
  return { min: SEARCH_W_MIN, max }
}

export function searchPanelDefault(viewportW: number): number {
  return Math.round((Number(viewportW) || 0) * SEARCH_W_FRAC)
}

export function clampSearchPanel(w: number, viewportW: number): number {
  const { min, max } = searchPanelBounds(viewportW)
  return Math.round(Math.min(max, Math.max(min, Number(w) || 0)))
}
