// SPL-6605 (owner HUM-10, t1 topic 0e00285a, msg 01140272: "this label should
// be just a small 1.5 s appearing snabar at the top or the bottom, but not a
// permanent lable"): the channel topic list's loaded-topics line ("Sorted: the
// {n} topics loaded" / "Showing new among the {n} topics loaded", spec 150 B6)
// is no longer a line above the cards. It flashes in the shared UndoSnackbar,
// with no Undo, for WINDOW_FLASH_MS, each time the sort, the filter or the
// loaded count changes while the line applies (MessageFeed.vue).

/** How long the loaded-topics snackbar stays (no Undo, so no touch minimum). */
export const WINDOW_FLASH_MS = 1500

/**
 * The flash key: '' while no line applies (no older page, or the defaults),
 * else the filter, the sort and the loaded count. MessageFeed flashes the line
 * on every change of a non-empty key, so a sort from Messages to Priority
 * flashes again although the words are the same.
 * @param {{ line: string, filter: string, sort: string, n: number }} at
 * @returns {string}
 */
export function windowFlashKey({ line, filter, sort, n }) {
  return line ? `${filter}|${sort}|${n}` : ''
}
